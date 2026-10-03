// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 strubedo
/*
 * twrp_remote - view and control the recovery screen from a PC over adb.
 *
 *   PC:  adb forward tcp:27183 localabstract:twrp_remote ; python3 twrp_remote.py
 *
 * Screen: the framebuffer on the active CRTC is read straight from DRM
 * (GETFB2 returns a GEM handle to CAP_SYS_ADMIN, then MAP_DUMB or a PRIME
 * dma-buf mmap) - no change to TWRP itself, and it shows exactly what the
 * panel shows. Frames are halved (2x2 average) to RGB888 and sent zlib-
 * compressed only when their checksum changes.
 *
 * Input: events are written into the real touchscreen and gpio_keys evdev
 * nodes (found by capability/name), which TWRP already reads.
 *
 * Wire format (little endian)
 *   phone -> PC  frame:  "TWRF" u16 src_w u16 src_h u16 w u16 h u32 len, zlib(RGB888 w*h)
 *   PC -> phone  8-byte packets: u8 op, u8 0, u16 a, u16 b, u16 0
 *                  'D' touch down x=a y=b   'M' move x=a y=b   'U' touch up
 *                  'K' key code=a value=b (1 down, 0 up)
 *                  'B' keyboard key code=a value=b (virtual uinput keyboard)
 *   (x, y in full-resolution panel pixels)
 */
#include <dirent.h>
#include <drm/drm.h>
#include <drm/drm_fourcc.h>
#include <drm/drm_mode.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/system_properties.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include <zlib.h>

#include <string>
#include <vector>

static const char kSocketName[] = "twrp_remote";   // abstract namespace
static const int kScale = 2;                        // send at half resolution
static const int kFrameIntervalMs = 50;             // poll the screen at ~20 fps

#define LOG(...) do { fprintf(stderr, "twrp_remote: " __VA_ARGS__); fputc('\n', stderr); } while (0)

// ---------------------------------------------------------------- DRM capture

struct Fb {
    uint32_t id = 0, w = 0, h = 0, pitch = 0, fmt = 0, handle = 0;
    int dmabuf = -1;
    uint8_t* map = nullptr;
    size_t len = 0;
};

static int g_drm = -1;
static Fb g_fb;

static void release_fb(Fb* f) {
    if (f->map) munmap(f->map, f->len);
    if (f->dmabuf >= 0) close(f->dmabuf);
    if (f->handle) {
        drm_gem_close gc{};
        gc.handle = f->handle;
        ioctl(g_drm, DRM_IOCTL_GEM_CLOSE, &gc);
    }
    *f = Fb();
}

// fb id currently scanned out (first active CRTC), or 0
static uint32_t active_fb_id() {
    drm_mode_card_res res{};
    if (ioctl(g_drm, DRM_IOCTL_MODE_GETRESOURCES, &res)) return 0;
    std::vector<uint32_t> crtcs(res.count_crtcs);
    drm_mode_card_res res2{};
    res2.count_crtcs = res.count_crtcs;
    res2.crtc_id_ptr = (uint64_t)(uintptr_t)crtcs.data();
    if (ioctl(g_drm, DRM_IOCTL_MODE_GETRESOURCES, &res2)) return 0;
    for (uint32_t i = 0; i < res2.count_crtcs && i < crtcs.size(); i++) {
        drm_mode_crtc c{};
        c.crtc_id = crtcs[i];
        if (ioctl(g_drm, DRM_IOCTL_MODE_GETCRTC, &c) == 0 && c.fb_id) return c.fb_id;
    }
    return 0;
}

static bool map_fb(uint32_t id, Fb* f) {
    drm_mode_fb_cmd2 cmd{};
    cmd.fb_id = id;
    if (ioctl(g_drm, DRM_IOCTL_MODE_GETFB2, &cmd) == 0) {
        f->w = cmd.width; f->h = cmd.height; f->pitch = cmd.pitches[0];
        f->fmt = cmd.pixel_format; f->handle = cmd.handles[0];
    } else {
        drm_mode_fb_cmd old{};
        old.fb_id = id;
        if (ioctl(g_drm, DRM_IOCTL_MODE_GETFB, &old)) { LOG("GETFB: %s", strerror(errno)); return false; }
        f->w = old.width; f->h = old.height; f->pitch = old.pitch;
        f->fmt = DRM_FORMAT_ABGR8888;    // TWRP's recovery pixel format
        f->handle = old.handle;
    }
    f->id = id;
    static uint32_t logged_fmt = 0;
    if (f->fmt != logged_fmt) {
        LOG("screen %ux%u pitch %u format %.4s (0x%08x)", f->w, f->h, f->pitch, (const char*)&f->fmt, f->fmt);
        logged_fmt = f->fmt;
    }
    if (!f->handle) { LOG("fb %u: no GEM handle (needs CAP_SYS_ADMIN)", id); return false; }
    f->len = (size_t)f->pitch * f->h;

    drm_mode_map_dumb md{};
    md.handle = f->handle;
    if (ioctl(g_drm, DRM_IOCTL_MODE_MAP_DUMB, &md) == 0) {
        void* p = mmap(nullptr, f->len, PROT_READ, MAP_SHARED, g_drm, md.offset);
        if (p != MAP_FAILED) { f->map = (uint8_t*)p; return true; }
    }
    drm_prime_handle ph{};                 // not a dumb buffer: try PRIME
    ph.handle = f->handle;
    ph.flags = DRM_CLOEXEC;
    if (ioctl(g_drm, DRM_IOCTL_PRIME_HANDLE_TO_FD, &ph) == 0) {
        f->dmabuf = ph.fd;
        void* p = mmap(nullptr, f->len, PROT_READ, MAP_SHARED, f->dmabuf, 0);
        if (p != MAP_FAILED) { f->map = (uint8_t*)p; return true; }
    }
    LOG("fb %u: cannot map (%s)", id, strerror(errno));
    release_fb(f);
    return false;
}

// byte positions of R, G, B inside a 32-bit pixel. Note: Tensor's DPU names
// formats in Android's byte-order convention - its RGBA8888 ("RA24") is R,G,B,A
// in memory, not DRM's A,B,G,R (verified: black showed red, blue showed teal).
static bool channel_order(uint32_t fmt, int* r, int* g, int* b) {
    switch (fmt) {
        case DRM_FORMAT_ABGR8888: case DRM_FORMAT_XBGR8888: *r = 0; *g = 1; *b = 2; return true;
        case DRM_FORMAT_ARGB8888: case DRM_FORMAT_XRGB8888: *r = 2; *g = 1; *b = 0; return true;
        case DRM_FORMAT_RGBA8888: case DRM_FORMAT_RGBX8888: *r = 0; *g = 1; *b = 2; return true;
        case DRM_FORMAT_BGRA8888: case DRM_FORMAT_BGRX8888: *r = 2; *g = 1; *b = 0; return true;
    }
    return false;
}

// grab the current screen as RGB888 at 1/kScale; false if nothing to show
static bool capture(std::vector<uint8_t>* out, uint32_t* src_w, uint32_t* src_h, uint32_t* w, uint32_t* h) {
    uint32_t id = active_fb_id();
    if (!id) return false;
    if (id != g_fb.id) {                   // page flip (double buffering) or first frame
        release_fb(&g_fb);
        if (!map_fb(id, &g_fb)) return false;
    }
    int ri, gi, bi;
    if (!channel_order(g_fb.fmt, &ri, &gi, &bi)) {
        static uint32_t warned = 0;
        if (warned != g_fb.fmt) { LOG("unsupported pixel format 0x%08x", g_fb.fmt); warned = g_fb.fmt; }
        return false;
    }
    *src_w = g_fb.w; *src_h = g_fb.h;
    *w = g_fb.w / kScale; *h = g_fb.h / kScale;
    out->resize((size_t)*w * *h * 3);
    uint8_t* o = out->data();
    for (uint32_t y = 0; y < *h; y++) {
        const uint8_t* row0 = g_fb.map + (size_t)(y * kScale) * g_fb.pitch;
        const uint8_t* row1 = row0 + g_fb.pitch;
        for (uint32_t x = 0; x < *w; x++) {
            const uint8_t* a = row0 + x * kScale * 4;
            const uint8_t* b = row1 + x * kScale * 4;
            *o++ = (a[ri] + a[4 + ri] + b[ri] + b[4 + ri]) >> 2;
            *o++ = (a[gi] + a[4 + gi] + b[gi] + b[4 + gi]) >> 2;
            *o++ = (a[bi] + a[4 + bi] + b[bi] + b[4 + bi]) >> 2;
        }
    }
    return true;
}

// ---------------------------------------------------------------- input

static int g_touch = -1, g_keys = -1;
static int g_tracking_id = 1;

static bool test_bit(const uint8_t* bits, int n) { return bits[n / 8] & (1 << (n % 8)); }

static void find_input_devices() {
    DIR* d = opendir("/dev/input");
    if (!d) return;
    while (dirent* e = readdir(d)) {
        if (strncmp(e->d_name, "event", 5)) continue;
        std::string path = std::string("/dev/input/") + e->d_name;
        int fd = open(path.c_str(), O_RDWR | O_CLOEXEC);
        if (fd < 0) continue;
        char name[128] = {};
        ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name);
        uint8_t abs[(ABS_MAX + 8) / 8] = {};
        ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(abs)), abs);
        if (g_touch < 0 && test_bit(abs, ABS_MT_POSITION_X)) {
            g_touch = fd; LOG("touchscreen: %s (%s)", path.c_str(), name);
        } else if (g_keys < 0 && strcmp(name, "gpio_keys") == 0) {
            g_keys = fd; LOG("buttons: %s (%s)", path.c_str(), name);
        } else {
            close(fd);
        }
    }
    closedir(d);
}

static void emit(int fd, uint16_t type, uint16_t code, int32_t value) {
    input_event ev{};
    ev.type = type; ev.code = code; ev.value = value;
    if (write(fd, &ev, sizeof(ev)) != (ssize_t)sizeof(ev)) LOG("input write: %s", strerror(errno));
}

static void touch(char op, int x, int y) {
    if (g_touch < 0) find_input_devices();   // driver may have loaded since
    if (g_touch < 0) return;
    emit(g_touch, EV_ABS, ABS_MT_SLOT, 0);
    if (op == 'D') {
        emit(g_touch, EV_ABS, ABS_MT_TRACKING_ID, g_tracking_id++ & 0xffff);
        emit(g_touch, EV_ABS, ABS_MT_POSITION_X, x);
        emit(g_touch, EV_ABS, ABS_MT_POSITION_Y, y);
        emit(g_touch, EV_KEY, BTN_TOUCH, 1);
        emit(g_touch, EV_KEY, BTN_TOOL_FINGER, 1);
    } else if (op == 'M') {
        emit(g_touch, EV_ABS, ABS_MT_POSITION_X, x);
        emit(g_touch, EV_ABS, ABS_MT_POSITION_Y, y);
    } else {
        emit(g_touch, EV_ABS, ABS_MT_TRACKING_ID, -1);
        emit(g_touch, EV_KEY, BTN_TOUCH, 0);
        emit(g_touch, EV_KEY, BTN_TOOL_FINGER, 0);
    }
    emit(g_touch, EV_SYN, SYN_REPORT, 0);
}

static void key(int code, int value) {
    LOG("key %d %s", code, value ? "down" : "up");
    if (g_keys < 0) find_input_devices();
    if (g_keys < 0) return;
    emit(g_keys, EV_KEY, code, value);
    emit(g_keys, EV_SYN, SYN_REPORT, 0);
}

// A virtual keyboard: the PC's typing keys reach TWRP like a USB keyboard
// (TWRP's hardwarekeyboard.cpp maps them to characters, Shift included).
// Typing keys only - no power/volume, so it can't act as the phone's buttons.
static int g_kbd = -1;

static void create_keyboard() {
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) { LOG("keyboard: /dev/uinput: %s", strerror(errno)); return; }
    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    ioctl(fd, UI_SET_EVBIT, EV_SYN);
    for (int k = KEY_ESC; k <= KEY_KPDOT; k++) ioctl(fd, UI_SET_KEYBIT, k);   // main block + keypad
    for (int k = KEY_102ND; k <= KEY_F12; k++) ioctl(fd, UI_SET_KEYBIT, k);
    for (int k = KEY_KPENTER; k <= KEY_DELETE; k++) ioctl(fd, UI_SET_KEYBIT, k); // arrows, home/end, ins/del
    uinput_setup us{};
    us.id.bustype = BUS_VIRTUAL;
    us.id.vendor = 0x18d1;          // Google
    us.id.product = 0x7277;         // "rw"
    strncpy(us.name, "twrp_remote keyboard", UINPUT_MAX_NAME_SIZE - 1);
    if (ioctl(fd, UI_DEV_SETUP, &us) || ioctl(fd, UI_DEV_CREATE)) {
        LOG("keyboard: uinput setup: %s", strerror(errno));
        close(fd);
        return;
    }
    g_kbd = fd;
    LOG("keyboard: virtual uinput keyboard created");
}

static void board(int code, int value) {
    if (g_kbd < 0) return;
    emit(g_kbd, EV_KEY, code, value);
    emit(g_kbd, EV_SYN, SYN_REPORT, 0);
}

// ---------------------------------------------------------------- server

static bool send_all(int fd, const void* buf, size_t len) {
    const uint8_t* p = (const uint8_t*)buf;
    while (len) {
        ssize_t n = send(fd, p, len, MSG_NOSIGNAL);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        p += n; len -= n;
    }
    return true;
}

static long now_ms() {
    timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

static void serve(int client) {
    std::vector<uint8_t> rgb, z;
    uLong last_sum = 0;
    bool sent_any = false;
    uint8_t pkt[8];
    size_t have = 0;
    long next = 0;
    long last_full = 0;
    for (;;) {
        long wait = next - now_ms();
        pollfd p{client, POLLIN, 0};
        int r = poll(&p, 1, wait > 0 ? (int)wait : 0);
        if (r < 0 && errno != EINTR) { LOG("end: poll: %s", strerror(errno)); return; }
        if (r > 0) {
            if (p.revents & (POLLHUP | POLLERR)) { LOG("end: poll revents 0x%x", p.revents); return; }
            ssize_t n = recv(client, pkt + have, sizeof(pkt) - have, 0);
            if (n <= 0) { LOG("end: recv %zd: %s", n, n ? strerror(errno) : "peer closed"); return; }
            have += n;
            if (have == sizeof(pkt)) {
                have = 0;
                int a = pkt[2] | pkt[3] << 8, b = pkt[4] | pkt[5] << 8;
                if (pkt[0] == 'K') key(a, b);
                else if (pkt[0] == 'B') board(a, b);
                else touch(pkt[0], a, b);
            }
            continue;
        }
        next = now_ms() + kFrameIntervalMs;
        // Idle screen: TWRP double-buffers and flips on every redraw, so an
        // unchanged active framebuffer id means nothing was redrawn. Skip the
        // expensive read (~10 MB of display memory per frame - it kept a core
        // at ~96%) except for a safety capture once a second.
        uint32_t id = active_fb_id();
        if (sent_any && id && id == g_fb.id && now_ms() - last_full < 1000) continue;
        last_full = now_ms();
        uint32_t sw, sh, w, h;
        if (!capture(&rgb, &sw, &sh, &w, &h)) continue;
        uLong sum = adler32(adler32(0, nullptr, 0), rgb.data(), rgb.size());
        if (sent_any && sum == last_sum) continue;
        uLongf zlen = compressBound(rgb.size());
        z.resize(zlen);
        if (compress2(z.data(), &zlen, rgb.data(), rgb.size(), 1) != Z_OK) continue;
        uint8_t hdr[16] = {'T', 'W', 'R', 'F'};
        uint16_t dims[4] = {(uint16_t)sw, (uint16_t)sh, (uint16_t)w, (uint16_t)h};
        memcpy(hdr + 4, dims, 8);
        uint32_t zl = (uint32_t)zlen;
        memcpy(hdr + 12, &zl, 4);
        if (!send_all(client, hdr, sizeof(hdr)) || !send_all(client, z.data(), zlen)) {
            LOG("end: send: %s", strerror(errno));
            return;
        }
        last_sum = sum;
        sent_any = true;
    }
}

// The display is opened only while a client is connected, and DRM master is
// dropped at once: the first opener of card0 becomes master, and if that were
// us (we start at late-init, before TWRP's GUI) TWRP could not set its mode -
// the boot stopped on the Google logo. Reading framebuffers needs no master.
static bool open_display() {
    if (g_drm >= 0) return true;
    g_drm = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    if (g_drm < 0) { LOG("open /dev/dri/card0: %s", strerror(errno)); return false; }
    ioctl(g_drm, DRM_IOCTL_DROP_MASTER, 0);   // EINVAL if TWRP is master: fine
    return true;
}

static void close_display() {
    release_fb(&g_fb);
    if (g_drm >= 0) close(g_drm);
    g_drm = -1;
}

int main() {
    signal(SIGPIPE, SIG_IGN);
    find_input_devices();
    create_keyboard();

    int srv = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    memcpy(addr.sun_path + 1, kSocketName, sizeof(kSocketName) - 1);   // abstract
    socklen_t alen = offsetof(sockaddr_un, sun_path) + 1 + sizeof(kSocketName) - 1;
    if (bind(srv, (sockaddr*)&addr, alen) || listen(srv, 1)) {
        LOG("socket @%s: %s", kSocketName, strerror(errno));
        return 1;
    }
    LOG("listening on @%s", kSocketName);
    // TWRP's blank timer stays awake while this is 1 (gui/blanktimer.cpp)
    __system_property_set("twrp.remote.connected", "0");
    for (;;) {
        int c = accept4(srv, nullptr, nullptr, SOCK_CLOEXEC);
        if (c < 0) { if (errno == EINTR) continue; LOG("accept: %s", strerror(errno)); sleep(1); continue; }
        LOG("client connected");
        __system_property_set("twrp.remote.connected", "1");
        // the touchscreen driver loads after we start (late-init): rescan
        // for anything still missing on every connect
        if (g_touch < 0 || g_keys < 0) find_input_devices();
        if (open_display()) serve(c);
        close(c);
        close_display();        // never keep card0 open while idle
        __system_property_set("twrp.remote.connected", "0");
        LOG("client disconnected");
    }
}
