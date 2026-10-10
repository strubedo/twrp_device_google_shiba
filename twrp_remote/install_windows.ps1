# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 strubedo
# install_windows.ps1 - install TWRP Remote for the current user (run it via install_windows.bat)
#
#   install_windows.bat              install (asks before the optional downloads)
#   install_windows.bat -Yes         don't ask
#   install_windows.bat -NoScrcpy    skip scrcpy
#   install_windows.bat -NoUsbDriver skip the Google USB driver check
#   install_windows.bat -Uninstall   remove TWRP Remote (keeps your screenshots)
#
# What it does:
#   1. copies "TWRP Remote.exe" (from build_windows.bat) to %LOCALAPPDATA%\TWRP Remote
#   2. adb: uses the one on PATH, else downloads Google's official platform-tools
#      next to the program (the remote finds it there)
#   3. Google USB driver: if it isn't installed, offers to download it from Google
#      and install it (one administrator prompt). Without it Windows may bind the
#      phone's "ADB Interface" to a generic driver and adb doesn't see the phone.
#   4. optional: scrcpy, the latest official win64 release from GitHub, also next to it
#   5. checks for more than one adb build (ADB variable, PATH): different builds kill
#      each other's adb server ("protocol fault ... connection reset") and the
#      remote can't stay connected. Offers to pin TWRP Remote to the newest one.
#   6. a Start menu shortcut
# Downloads use Windows' own curl.exe with retries (Invoke-WebRequest as fallback).
# Nothing is installed system-wide except the USB driver (only if you agree).
# Tested on Windows 11 (2026-10-09).
param([switch]$Uninstall, [switch]$Yes, [switch]$NoScrcpy, [switch]$NoUsbDriver)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'        # Invoke-WebRequest is far faster without its progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Src  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Dest = Join-Path $env:LOCALAPPDATA 'TWRP Remote'
$Lnk  = Join-Path ([Environment]::GetFolderPath('Programs')) 'TWRP Remote.lnk'
$UsbDriverUrl = 'https://dl.google.com/android/repository/usb_driver_r13-windows.zip'

function Say($m)  { Write-Host "== $m" }
function Info($m) { Write-Host "   $m" }
function Warn($m) { Write-Host "   $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }
function Ask($q)  { if ($Yes) { return $true }; $r = Read-Host "   $q [Y/n]"; return ($r -eq '' -or $r -match '^[Yy]') }

if ($Uninstall) {
    Say 'Removing TWRP Remote'
    if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
    if (Test-Path $Lnk)  { Remove-Item -Force $Lnk }
    if ([Environment]::GetEnvironmentVariable('ADB','User') -like "$Dest\*") {
        [Environment]::SetEnvironmentVariable('ADB', $null, 'User')
    }
    Info 'removed (screenshots in Pictures\TWRP Remote are kept; the Google USB driver stays installed)'
    exit 0
}

# --- downloads: curl.exe (ships with Windows 10 1803+) with retries, else Invoke-WebRequest ---
$Curl = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$CurlRetry = @('--retry', '5', '--retry-delay', '2', '--connect-timeout', '20')
if ($Curl -and ((& $Curl.Source --help all 2>$null) -match 'retry-all-errors')) { $CurlRetry += '--retry-all-errors' }

function Get-File($url, $out) {
    if ($Curl) {
        & $Curl.Source -fsSL @CurlRetry -o $out $url
        if ($LASTEXITCODE -ne 0) { throw "download failed (curl exit $LASTEXITCODE): $url" }
    } else {
        $last = $null
        foreach ($i in 1..5) {
            try { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $out; return } catch { $last = $_; Start-Sleep 2 }
        }
        throw $last
    }
}

function Get-Json($url) {
    $tmp = Join-Path $env:TEMP ([IO.Path]::GetRandomFileName() + '.json')
    try { Get-File $url $tmp; return (Get-Content -Raw $tmp | ConvertFrom-Json) }
    finally { if (Test-Path $tmp) { Remove-Item -Force $tmp } }
}

function Get-Zip($url, $into) {
    $zip = Join-Path $env:TEMP ([IO.Path]::GetRandomFileName() + '.zip')
    try {
        Get-File $url $zip
        Expand-Archive -Force $zip $into
    } finally {
        if (Test-Path $zip) { Remove-Item -Force $zip }
    }
}

# the program: next to this script, or in dist\ after build_windows.bat
$Exe = @((Join-Path $Src 'TWRP Remote.exe'), (Join-Path $Src 'dist\TWRP Remote.exe')) |
       Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Exe) { Die 'TWRP Remote.exe not found - run build_windows.bat first (or put the .exe next to this script)' }

Say "Installing to $Dest"
New-Item -ItemType Directory -Force $Dest | Out-Null
Copy-Item -Force $Exe (Join-Path $Dest 'TWRP Remote.exe')

# --- adb (required) ---
$adb = Get-Command adb -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
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

# --- Google USB driver ---
if (-not $NoUsbDriver) {
    $haveDriver = $false
    try { $haveDriver = [bool]((pnputil /enum-drivers 2>$null) -match 'android_winusb\.inf') } catch {}
    $generic = @()
    try {
        # the phone's adb function bound to anything but Google's driver (class AndroidUsbDeviceClass)
        $generic = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
                     Where-Object { $_.FriendlyName -match 'ADB Interface' -and $_.Class -ne 'AndroidUsbDeviceClass' })
    } catch {}
    if ($haveDriver -and $generic.Count -eq 0) {
        Info 'USB driver: Google USB driver installed'
    } else {
        if ($generic.Count -gt 0) { Warn "USB driver: the phone's ADB interface uses a generic driver - adb won't see the phone" }
        else                      { Info 'USB driver: Google USB driver not installed (adb may not see the phone without it)' }
        if (Ask 'Download the Google USB driver and install it (one administrator prompt)?') {
            $drv = Join-Path $Dest 'usb_driver'
            $inf = Join-Path $drv 'usb_driver\android_winusb.inf'
            try {
                if (-not (Test-Path $inf)) {
                    Say 'Downloading the Google USB driver'
                    Get-Zip $UsbDriverUrl $drv
                }
                if (-not (Test-Path $inf)) { throw 'android_winusb.inf not found after unpacking' }
                Say 'Installing the Google USB driver (approve the administrator prompt)'
                $p = Start-Process pnputil -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
                                   -ArgumentList @('/add-driver', "`"$inf`"", '/install')
                if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) {
                    Info 'USB driver: installed - unplug the phone and plug it back in'
                } else {
                    Warn "USB driver: pnputil exit code $($p.ExitCode) - see https://developer.android.com/studio/run/win-usb"
                }
            } catch {
                Warn "USB driver: skipped ($($_.Exception.Message)) - see https://developer.android.com/studio/run/win-usb"
            }
        }
    }
}

# --- scrcpy (optional) ---
if (-not $NoScrcpy) {
    $sc = Get-Command scrcpy -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($sc) {
        Info "scrcpy: $($sc.Source)"
    } elseif (Test-Path (Join-Path $Dest 'scrcpy\scrcpy.exe')) {
        Info 'scrcpy: already here'
    } elseif (Ask 'Download scrcpy too (optional - shows the phone when it is in Android)?') {
        Say 'Downloading scrcpy (latest official release, from GitHub)'
        try {
            $rel = Get-Json 'https://api.github.com/repos/Genymobile/scrcpy/releases/latest'
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
            Info "scrcpy: skipped ($($_.Exception.Message)) - optional; run install_windows.bat again to retry"
        }
    }
}

# --- more than one adb build? ---
# TWRP Remote picks adb from the ADB variable, then PATH, then next to the program,
# and hands the same adb to scrcpy. Any other adb of a different build (another tool,
# the one you type) kills that adb server, so the remote keeps losing the phone.
function Get-AdbBuild($path) {
    try {
        $out = & $path version 2>$null
        $v = $out | Select-String '^Version\s+(\S+)' | Select-Object -First 1
        if ($v) { return $v.Matches[0].Groups[1].Value }
        return (($out | Select-Object -First 1) -replace '^Android Debug Bridge version\s*', '')
    } catch { return $null }
}
function Get-BuildKey($b) {
    try { return [version](($b -split '-')[0]) } catch { return [version]'0.0' }
}
$cands = @()
$envAdb = [Environment]::GetEnvironmentVariable('ADB', 'User')
if (-not $envAdb) { $envAdb = $env:ADB }
if ($envAdb -and (Test-Path $envAdb)) { $cands += $envAdb }
$cands += @(Get-Command adb -All -CommandType Application -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
if ($cands.Count -eq 0) {
    $local = Join-Path $Dest 'platform-tools\adb.exe'
    if (Test-Path $local) { $cands += $local }
}
$adbs = @($cands | Where-Object { $_ } | ForEach-Object { (Resolve-Path $_).Path } | Select-Object -Unique |
          ForEach-Object { [pscustomobject]@{ Path = $_; Build = (Get-AdbBuild $_) } })
$builds = @($adbs | Where-Object { $_.Build } | ForEach-Object { $_.Build } | Select-Object -Unique)
if ($builds.Count -gt 1) {
    Warn 'adb: more than one adb build found - they kill each other''s adb server:'
    foreach ($a in $adbs) { Warn ('     {0,-24} {1}' -f $a.Build, $a.Path) }
    $newest = $adbs | Where-Object { $_.Build } | Sort-Object { Get-BuildKey $_.Build } -Descending | Select-Object -First 1
    if (Ask "Pin TWRP Remote (and its scrcpy) to the newest, $($newest.Build) (sets the ADB user variable)?") {
        [Environment]::SetEnvironmentVariable('ADB', $newest.Path, 'User')
        Info "ADB = $($newest.Path)"
    }
    Warn 'Best fix: keep only one platform-tools folder on PATH (System and User PATH),'
    Warn 'and close other tools that start their own adb while you use the remote.'
} elseif ($adbs.Count -gt 0) {
    Info "adb build: $($adbs[0].Build)"
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
Info 'If adb does not see the phone: Google USB driver - https://developer.android.com/studio/run/win-usb'
Info 'Remove with: install_windows.bat -Uninstall'
