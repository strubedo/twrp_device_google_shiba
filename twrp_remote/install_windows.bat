@echo off
rem SPDX-License-Identifier: GPL-3.0-or-later
rem Copyright (C) 2026 strubedo
rem install_windows.bat - install TWRP Remote for this Windows user (double-click).
rem Runs install_windows.ps1 (see its header). Options, from a command prompt:
rem   install_windows.bat -Yes | -NoScrcpy | -Uninstall
rem First build the program with build_windows.bat (makes dist\TWRP Remote.exe).
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_windows.ps1" %*
pause
