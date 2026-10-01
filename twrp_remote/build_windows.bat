@echo off
rem build_windows.bat - build "TWRP Remote.exe" (Windows, run from this folder)
rem
rem Needs: Python 3 from python.org (the "py" launcher). Everything else goes
rem into a private venv here (.venv-win), nothing is installed system-wide.
rem
rem Copy these three files to one folder on the Windows PC and double-click:
rem     twrp_remote.py   twrp_remote.png   build_windows.bat
rem Result: dist\TWRP Remote.exe  (single file, no console window)
rem
rem To run it, the PC also needs:
rem   adb     - Android platform-tools: put the platform-tools folder next to the
rem             .exe, or in C:\platform-tools, or on PATH
rem   scrcpy  - optional, for the phone in Android: C:\scrcpy, next to the .exe,
rem             or on PATH (its zip also contains an adb.exe that works too)
rem   Google USB driver, if Windows doesn't recognize the phone over adb

cd /d "%~dp0"

where py >nul 2>nul || (echo Python 3 not found - install it from python.org first & pause & exit /b 1)

if not exist .venv-win (
    echo === creating build venv
    py -3 -m venv .venv-win || (echo venv creation failed & pause & exit /b 1)
)
echo === installing Pillow + PyInstaller
.venv-win\Scripts\python -m pip install --quiet --upgrade pip pillow pyinstaller || (echo pip install failed & pause & exit /b 1)

echo === making the icon
.venv-win\Scripts\python -c "from PIL import Image; Image.open('twrp_remote.png').save('twrp_remote.ico', sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)])" || (echo icon conversion failed & pause & exit /b 1)

echo === building TWRP Remote.exe
.venv-win\Scripts\pyinstaller --noconfirm --clean --onefile --windowed ^
    --name "TWRP Remote" --icon twrp_remote.ico ^
    --add-data "twrp_remote.png;." ^
    twrp_remote.py || (echo PyInstaller failed & pause & exit /b 1)

echo.
echo === done: dist\TWRP Remote.exe
pause
