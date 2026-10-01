#!/usr/bin/env bash
# install_linux.sh - add "TWRP Remote" to the desktop's application menu
# (KDE, GNOME, ...) for the current user, pointing at this folder.
#
#   ./install_linux.sh                 uses python3 from PATH
#   PYTHON=/path/to/python ./install_linux.sh    e.g. a venv with Pillow
#
# Needs: adb, Python 3 with Tk + Pillow (Debian/Ubuntu:
#   sudo apt install adb python3-tk python3-pil python3-pil.imagetk)
set -euo pipefail
dir="$(cd "$(dirname "$0")" && pwd)"
python="${PYTHON:-$(command -v python3)}"
apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
icons="${XDG_DATA_HOME:-$HOME/.local/share}/icons"
mkdir -p "$apps" "$icons"

"$python" -c 'import tkinter, PIL.ImageTk' 2>/dev/null || {
    echo "Python at $python lacks Tk or Pillow (ImageTk) - see the header of this script"; exit 1; }
cp "$dir/twrp_remote.png" "$icons/twrp-remote.png"
cat > "$apps/twrp-remote.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=TWRP Remote
GenericName=Phone recovery remote
Comment=View and control TWRP on the Pixel 8 over USB (adb)
Exec="$python" "$dir/twrp_remote.py"
Icon=$icons/twrp-remote.png
Terminal=false
Categories=Development;Utility;
Keywords=twrp;recovery;android;pixel;adb;
StartupWMClass=TWRPRemote
EOF
command -v update-desktop-database >/dev/null && update-desktop-database "$apps" 2>/dev/null || true
command -v kbuildsycoca6 >/dev/null && kbuildsycoca6 >/dev/null 2>&1 || true
echo "Installed: $apps/twrp-remote.desktop (look for \"TWRP Remote\" in your menu)"
