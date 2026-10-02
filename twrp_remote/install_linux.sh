#!/usr/bin/env bash
# install_linux.sh - install TWRP Remote for the current user, with everything it needs.
#
#   ./install_linux.sh               install (asks before installing system packages)
#   ./install_linux.sh --yes         don't ask (also installs scrcpy if available)
#   ./install_linux.sh --no-scrcpy   skip the optional scrcpy
#   ./install_linux.sh --uninstall   remove TWRP Remote (keeps your screenshots)
#
# What it does:
#   1. system packages, only the missing ones (apt / dnf / pacman / zypper, one sudo):
#      adb, Python's venv module, Tk
#   2. optional: scrcpy, to see the phone when it's in Android
#   3. the app + a private Python environment with Pillow in
#      ~/.local/share/twrp-remote (nothing touches the system Python; the menu
#      entry keeps working after you delete the download)
#   4. "TWRP Remote" in the application menu (KDE, GNOME, ...)
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
HOME_DIR="$DATA/twrp-remote"
APPS="$DATA/applications"
ICONS="$DATA/icons"
DESKTOP="$APPS/twrp-remote.desktop"
ICON="$ICONS/twrp-remote.png"

YES=0; SCRCPY=1; SKIP_PACKAGES=0; UNINSTALL=0
for a in "$@"; do
    case "$a" in
        --yes|-y)        YES=1 ;;
        --no-scrcpy)     SCRCPY=0 ;;
        --skip-packages) SKIP_PACKAGES=1 ;;      # testing / no sudo: only the per-user part
        --uninstall)     UNINSTALL=1 ;;
        -h|--help)       sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "unknown option: $a (see --help)"; exit 2 ;;
    esac
done

say()  { echo "== $*"; }
info() { echo "   $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
ask()  { [[ $YES == 1 ]] && return 0; local r; read -r -p "   $1 [Y/n] " r; [[ -z "$r" || "$r" =~ ^[Yy] ]]; }

refresh_menu() {
    command -v update-desktop-database >/dev/null && update-desktop-database "$APPS" 2>/dev/null || true
    command -v kbuildsycoca6 >/dev/null && kbuildsycoca6 >/dev/null 2>&1 || true
    command -v kbuildsycoca5 >/dev/null && kbuildsycoca5 >/dev/null 2>&1 || true
}

# ---- uninstall ---------------------------------------------------------------
if [[ $UNINSTALL == 1 ]]; then
    say "Removing TWRP Remote"
    rm -rf "$HOME_DIR"; rm -f "$DESKTOP" "$ICON"
    refresh_menu
    info "removed $HOME_DIR and the menu entry (screenshots in Pictures/TWRP Remote are kept;"
    info "system packages like adb are left installed)"
    exit 0
fi

[[ -f "$SRC/twrp_remote.py" && -f "$SRC/twrp_remote.png" ]] || die "run this from the twrp_remote folder"

# ---- 1. system packages ------------------------------------------------------
PM=""
for p in apt-get dnf pacman zypper; do command -v "$p" >/dev/null && { PM="$p"; break; }; done

pkgs_for() {   # pkgs_for adb|venv|tk|scrcpy -> package name(s) for this distro ("" = none)
    case "$PM:$1" in
        apt-get:adb) echo adb ;;          apt-get:venv) echo python3-venv ;;
        apt-get:tk) echo python3-tk ;;    apt-get:scrcpy) echo scrcpy ;;
        dnf:adb) echo android-tools ;;    dnf:venv) echo "" ;;           # venv is part of python3
        dnf:tk) echo python3-tkinter ;;   dnf:scrcpy) echo "" ;;         # not in Fedora's repos
        pacman:adb) echo android-tools ;; pacman:venv) echo "" ;;
        pacman:tk) echo tk ;;             pacman:scrcpy) echo scrcpy ;;
        zypper:adb) echo android-tools ;; zypper:venv) echo "" ;;
        zypper:tk) echo python3-tk ;;     zypper:scrcpy) echo scrcpy ;;
        *) echo "" ;;
    esac
}
install_pkgs() {
    case "$PM" in
        apt-get) sudo apt-get update -qq || info "(apt-get update had errors - trying the install anyway)"
                 sudo apt-get install -y "$@" ;;
        dnf)     sudo dnf install -y "$@" ;;
        pacman)  sudo pacman -S --needed --noconfirm "$@" ;;
        zypper)  sudo zypper --non-interactive install "$@" ;;
    esac
}

PY="$(command -v python3 || true)"
have_venv() { [[ -n "$PY" ]] && "$PY" -c 'import venv, ensurepip' 2>/dev/null; }
have_tk()   { [[ -n "$PY" ]] && "$PY" -c 'import tkinter' 2>/dev/null; }

say "Checking what's needed"
need=()
command -v adb >/dev/null && info "adb: $(adb version 2>/dev/null | head -1)" \
                          || { info "adb: missing"; need+=("$(pkgs_for adb)"); }
[[ -n "$PY" ]] || die "python3 not found - install Python 3 with your package manager first"
info "python: $("$PY" --version 2>&1)"
have_venv && info "python venv: ok" || { info "python venv: missing"; need+=("$(pkgs_for venv)"); }
have_tk   && info "python Tk: ok"   || { info "python Tk: missing";   need+=("$(pkgs_for tk)"); }
want_scrcpy=0
if [[ $SCRCPY == 1 ]]; then
    if command -v scrcpy >/dev/null; then info "scrcpy: $(scrcpy --version 2>/dev/null | head -1)"
    else info "scrcpy: not installed (optional - shows the phone when it's in Android)"; want_scrcpy=1; fi
fi

missing=()
for x in "${need[@]}"; do [[ -n "$x" ]] && missing+=("$x"); done
if [[ ${#missing[@]} -gt 0 || ${#need[@]} -gt 0 ]]; then
    [[ $SKIP_PACKAGES == 0 ]] || die "missing system packages and --skip-packages given: ${missing[*]:-?}"
    [[ -n "$PM" ]] || die "no supported package manager (apt/dnf/pacman/zypper) - install adb and Python Tk/venv yourself"
    [[ ${#missing[@]} -gt 0 ]] || die "something is missing but there's no package for it on $PM (see above)"
    say "Installing: ${missing[*]} (with $PM; sudo will ask for your password)"
    ask "Install now?" || die "cancelled - nothing was installed"
    install_pkgs "${missing[@]}" || die "installing ${missing[*]} failed (see the messages above)"
    command -v adb >/dev/null || die "adb is still missing after installing"
    have_venv || die "python venv is still missing after installing"
    have_tk   || die "python Tk is still missing after installing"
fi
if [[ $want_scrcpy == 1 && $SKIP_PACKAGES == 0 ]]; then
    p="$(pkgs_for scrcpy)"
    if [[ -n "$p" && -n "$PM" ]] && ask "Install scrcpy too (optional)?"; then
        install_pkgs "$p" || info "scrcpy install failed - optional, continuing"
    elif [[ -z "$p" ]]; then
        info "scrcpy isn't in your distro's repositories: https://github.com/Genymobile/scrcpy"
    fi
fi

# ---- 2. the app + its private Python environment -----------------------------
say "Installing the app to $HOME_DIR"
mkdir -p "$HOME_DIR/app"
cp "$SRC/twrp_remote.py" "$SRC/twrp_remote.png" "$HOME_DIR/app/"
if [[ ! -x "$HOME_DIR/venv/bin/python" ]]; then
    "$PY" -m venv "$HOME_DIR/venv" || die "creating the Python environment failed"
fi
"$HOME_DIR/venv/bin/python" -m pip install --quiet --disable-pip-version-check --upgrade pillow \
    || die "installing Pillow failed (network?)"
"$HOME_DIR/venv/bin/python" -c 'import tkinter, PIL.ImageTk' 2>/dev/null \
    || die "the Python environment can't load Tk + Pillow"
info "Python environment: Pillow $("$HOME_DIR/venv/bin/python" -c 'import PIL; print(PIL.__version__)')"

# ---- 3. menu entry -------------------------------------------------------------
say "Adding \"TWRP Remote\" to the application menu"
mkdir -p "$APPS" "$ICONS"
cp "$SRC/twrp_remote.png" "$ICON"
cat > "$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=TWRP Remote
GenericName=Phone recovery remote
Comment=View and control TWRP on the Pixel 8 over USB (adb)
Exec="$HOME_DIR/venv/bin/python" "$HOME_DIR/app/twrp_remote.py"
Icon=$ICON
Terminal=false
Categories=Development;Utility;
Keywords=twrp;recovery;android;pixel;adb;
StartupWMClass=TWRPRemote
EOF
refresh_menu

say "Done"
info "Start it from the menu (\"TWRP Remote\"), or: \"$HOME_DIR/venv/bin/python\" \"$HOME_DIR/app/twrp_remote.py\""
info "Screenshots go to Pictures/TWRP Remote.  Remove with: $0 --uninstall"
info "If adb shows \"no permissions\" for the phone, your distro needs Android udev rules"
info "(Debian/Ubuntu: they come with the adb package; then unplug and replug the phone)."
