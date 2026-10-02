# install_windows.ps1 - install TWRP Remote for the current user (run it via install_windows.bat)
#
#   install_windows.bat              install (asks before downloading the optional scrcpy)
#   install_windows.bat -Yes         don't ask
#   install_windows.bat -NoScrcpy    skip scrcpy
#   install_windows.bat -Uninstall   remove TWRP Remote (keeps your screenshots)
#
# What it does:
#   1. copies "TWRP Remote.exe" (from build_windows.bat) to %LOCALAPPDATA%\TWRP Remote
#   2. adb: uses the one on PATH, else downloads Google's official platform-tools
#      next to the program (the remote finds it there)
#   3. optional: scrcpy, the latest official win64 release from GitHub, also next to it
#   4. a Start menu shortcut
# Nothing is installed system-wide; no administrator rights needed.
# NOTE: written on Linux, not yet run on a real Windows PC.
param([switch]$Uninstall, [switch]$Yes, [switch]$NoScrcpy)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'        # Invoke-WebRequest is far faster without its progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Src  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Dest = Join-Path $env:LOCALAPPDATA 'TWRP Remote'
$Lnk  = Join-Path ([Environment]::GetFolderPath('Programs')) 'TWRP Remote.lnk'

function Say($m)  { Write-Host "== $m" }
function Info($m) { Write-Host "   $m" }
function Die($m)  { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }
function Ask($q)  { if ($Yes) { return $true }; $r = Read-Host "   $q [Y/n]"; return ($r -eq '' -or $r -match '^[Yy]') }

if ($Uninstall) {
    Say 'Removing TWRP Remote'
    if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
    if (Test-Path $Lnk)  { Remove-Item -Force $Lnk }
    Info 'removed (screenshots in Pictures\TWRP Remote are kept)'
    exit 0
}

# the program: next to this script, or in dist\ after build_windows.bat
$Exe = @((Join-Path $Src 'TWRP Remote.exe'), (Join-Path $Src 'dist\TWRP Remote.exe')) |
       Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Exe) { Die 'TWRP Remote.exe not found - run build_windows.bat first (or put the .exe next to this script)' }

Say "Installing to $Dest"
New-Item -ItemType Directory -Force $Dest | Out-Null
Copy-Item -Force $Exe (Join-Path $Dest 'TWRP Remote.exe')

function Get-Zip($url, $into) {
    $zip = Join-Path $env:TEMP ([IO.Path]::GetRandomFileName() + '.zip')
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
        Expand-Archive -Force $zip $into
    } finally {
        if (Test-Path $zip) { Remove-Item -Force $zip }
    }
}

# --- adb (required) ---
$adb = Get-Command adb -ErrorAction SilentlyContinue
if ($adb) {
    Info "adb: $($adb.Source)"
} elseif (Test-Path (Join-Path $Dest 'platform-tools\adb.exe')) {
    Info 'adb: already here (platform-tools)'
} else {
    Say 'Downloading Android platform-tools (adb) from Google'
    Get-Zip 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' $Dest
    if (-not (Test-Path (Join-Path $Dest 'platform-tools\adb.exe'))) { Die 'platform-tools download/unpack failed' }
    Info 'adb: installed (platform-tools)'
}

# --- scrcpy (optional) ---
if (-not $NoScrcpy) {
    $sc = Get-Command scrcpy -ErrorAction SilentlyContinue
    if ($sc) {
        Info "scrcpy: $($sc.Source)"
    } elseif (Test-Path (Join-Path $Dest 'scrcpy\scrcpy.exe')) {
        Info 'scrcpy: already here'
    } elseif (Ask 'Download scrcpy too (optional - shows the phone when it is in Android)?') {
        Say 'Downloading scrcpy (latest official release, from GitHub)'
        try {
            $rel = Invoke-RestMethod -UseBasicParsing 'https://api.github.com/repos/Genymobile/scrcpy/releases/latest'
            $asset = $rel.assets | Where-Object { $_.name -match '^scrcpy-win64-.*\.zip$' } | Select-Object -First 1
            if (-not $asset) { throw 'no win64 build in the latest release' }
            $tmp = Join-Path $env:TEMP ('scrcpy-' + [IO.Path]::GetRandomFileName())
            Get-Zip $asset.browser_download_url $tmp
            $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1   # the zip holds scrcpy-win64-vX.Y\
            $from = if ($inner) { $inner.FullName } else { $tmp }
            $to = Join-Path $Dest 'scrcpy'
            if (Test-Path $to) { Remove-Item -Recurse -Force $to }
            Move-Item $from $to
            if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
            if (-not (Test-Path (Join-Path $to 'scrcpy.exe'))) { throw 'scrcpy.exe not found after unpacking' }
            Info "scrcpy: $($rel.tag_name)"
        } catch {
            Info "scrcpy: skipped ($($_.Exception.Message)) - optional, continuing"
        }
    }
}

# --- Start menu shortcut ---
Say 'Adding "TWRP Remote" to the Start menu'
$sh = New-Object -ComObject WScript.Shell
$l = $sh.CreateShortcut($Lnk)
$l.TargetPath = Join-Path $Dest 'TWRP Remote.exe'
$l.WorkingDirectory = $Dest
$l.Description = 'View and control TWRP on the Pixel 8 over USB (adb)'
$l.Save()

Say 'Done'
Info 'Start it from the Start menu ("TWRP Remote"). Screenshots go to Pictures\TWRP Remote.'
Info 'If Windows does not see the phone in adb, install the Google USB Driver:'
Info '  https://developer.android.com/studio/run/win-usb'
Info 'Remove with: install_windows.bat -Uninstall'
