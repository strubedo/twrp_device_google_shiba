// libshiba_cxx_compat: std::__libcpp_verbose_abort for vendor binaries built
// against a newer libc++ than our recovery's (Android 15+ vendors ship their
// own libc++; citadeld, the Weaver service and libnos_* reference this symbol,
// our Android 14 libc++.so doesn't export it -> "CANNOT LINK EXECUTABLE").
// libc++ documents this function as overridable by programs; it only ever
// runs when the program is already aborting (a failed libc++ assertion).
// Preloaded (LD_PRELOAD) only into twrp.citadeld and twrp.weaver.
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

namespace std {
inline namespace __1 {

[[noreturn]] __attribute__((visibility("default"), format(printf, 1, 2)))
void __libcpp_verbose_abort(const char* format, ...) {
    va_list ap;
    va_start(ap, format);
    vfprintf(stderr, format, ap);
    va_end(ap);
    fputc('\n', stderr);
    abort();
}

}  // namespace __1
}  // namespace std
