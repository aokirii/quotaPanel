# uninstall.ps1 — full QuotaPanel uninstall for Windows (mirror of install.ps1).
#
# Removes everything install.ps1 set up: the tray app and daemon under
# %LOCALAPPDATA%\QuotaPanel, the config/status directory under
# %APPDATA%\quotapanel, the "Start with Windows" autostart registry value,
# and the %USERPROFILE%\.quotapanel data directory (sign-in credentials and
# oauth-clients.json). Lists what it found and asks once before deleting.
#
# Usage (from the repo, or standalone — it doesn't need the repo):
#   powershell -ExecutionPolicy Bypass -File windows\uninstall.ps1
#
#   -Yes               skip the confirmation prompt
#   -KeepCredentials   preserve %USERPROFILE%\.quotapanel so a later
#                      reinstall picks the sign-ins back up
#
# The CLIs' own credentials (%USERPROFILE%\.claude, .codex, .gemini, …) are
# never touched — QuotaPanel only ever read those. The Swift toolchain and
# Visual Studio components install.ps1 may have added are left alone: they
# are general developer tools, not QuotaPanel remnants.

param([switch]$Yes, [switch]$KeepCredentials)

$ErrorActionPreference = 'Stop'

$installDir = Join-Path $env:LOCALAPPDATA 'QuotaPanel'
$configDir  = Join-Path $env:APPDATA 'quotapanel'
$credsDir   = Join-Path $env:USERPROFILE '.quotapanel'
$runKey     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$coreBuild  = if ($PSScriptRoot) {
    Join-Path (Split-Path -Parent $PSScriptRoot) 'linux\QuotaPanelCore\.build'
} else { $null }

Write-Host '==> QuotaPanel uninstall' -ForegroundColor Cyan

# --- inventory: list only what actually exists --------------------------------

$paths = @($installDir, $configDir)
if ($coreBuild) { $paths += $coreBuild }
if (-not $KeepCredentials) { $paths += $credsDir }
$found = @($paths | Where-Object { Test-Path $_ })

$autostart = $false
try {
    $autostart = $null -ne (Get-ItemProperty -Path $runKey -Name 'QuotaPanel' -ErrorAction SilentlyContinue)
} catch { }

if ($found.Count -eq 0 -and -not $autostart) {
    Write-Host '==> Nothing to remove — no QuotaPanel remnants found.' -ForegroundColor Green
    exit 0
}

Write-Host 'The following will be removed:'
foreach ($p in $found) { Write-Host "    $p" }
if ($autostart) { Write-Host "    $runKey -> QuotaPanel (autostart entry)" }
if ($KeepCredentials) { Write-Host "    (keeping $credsDir - credentials and oauth-clients.json)" }

if (-not $Yes) {
    $answer = Read-Host '    Continue? [y/N]'
    if ($answer -notmatch '^[Yy]$') { Write-Host 'Aborted - nothing deleted.'; exit 1 }
}

# --- stop the running tray and daemon so their exes aren't held open ----------

Write-Host '==> Stopping QuotaPanel processes…' -ForegroundColor Cyan
Get-Process QuotaPanelTray, quotapanel-daemon -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500

# --- autostart registry value -------------------------------------------------

if ($autostart) {
    Remove-ItemProperty -Path $runKey -Name 'QuotaPanel' -ErrorAction SilentlyContinue
    Write-Host '    removed autostart entry'
}

# --- files ---------------------------------------------------------------------

Write-Host '==> Removing files…' -ForegroundColor Cyan
foreach ($p in $found) {
    Remove-Item -Recurse -Force -Path $p -ErrorAction SilentlyContinue
    if (Test-Path $p) {
        Write-Host "    could not fully remove $p - close anything using it and re-run" -ForegroundColor Yellow
    } else {
        Write-Host "    removed $p"
    }
}

Write-Host ''
Write-Host '==> Done - QuotaPanel is fully removed.' -ForegroundColor Green
