# install.ps1 — one-shot QuotaPanel install for Windows.
#
# Builds the shared Swift daemon (linux/QuotaPanelCore — the "linux" folder
# holds the portable core, which also compiles on Windows), compiles the tray
# app with the C# compiler Windows ships in-box, installs both under
# %LOCALAPPDATA%\QuotaPanel, fetches first data, and starts the tray.
#
# Usage (from the repo):
#   powershell -ExecutionPolicy Bypass -File windows\install.ps1
#
#   -SkipDaemon   reuse the already-installed daemon (tray-only iteration)

param([switch]$SkipDaemon)

$ErrorActionPreference = 'Stop'

$repoRoot   = Split-Path -Parent $PSScriptRoot
$coreDir    = Join-Path $repoRoot 'linux\QuotaPanelCore'
$trayCs     = Join-Path $PSScriptRoot 'tray\QuotaPanelTray.cs'
$installDir = Join-Path $env:LOCALAPPDATA 'QuotaPanel'
$configDir  = Join-Path $env:APPDATA 'quotapanel'

Write-Host '==> QuotaPanel for Windows' -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
New-Item -ItemType Directory -Force -Path $configDir | Out-Null

# --- 1. Swift daemon ---------------------------------------------------------

if (-not $SkipDaemon) {
    $swift = Get-Command swift -ErrorAction SilentlyContinue
    if (-not $swift) {
        Write-Host '==> Swift toolchain not found — trying winget…' -ForegroundColor Yellow
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($winget) {
            & winget install --id Swift.Toolchain -e --accept-source-agreements --accept-package-agreements
            # winget updates PATH for new shells only; probe the default location
            $swiftBin = Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Toolchains\*\usr\bin\swift.exe" -ErrorAction SilentlyContinue |
                Sort-Object FullName -Descending | Select-Object -First 1
            if ($swiftBin) { $env:Path = "$($swiftBin.DirectoryName);$env:Path" }
            $swift = Get-Command swift -ErrorAction SilentlyContinue
        }
        if (-not $swift) {
            Write-Host 'Could not install Swift automatically.' -ForegroundColor Red
            Write-Host 'Install it from https://www.swift.org/install/windows/ (the installer'
            Write-Host 'pulls in the required Visual Studio Build Tools), reopen the terminal,'
            Write-Host 'and re-run this script.'
            exit 1
        }
    }

    Write-Host '==> Building quotapanel-daemon (swift build -c release)…' -ForegroundColor Cyan
    & swift build -c release --package-path $coreDir
    if ($LASTEXITCODE -ne 0) { Write-Host 'Swift build failed.' -ForegroundColor Red; exit 1 }

    $daemonSrc = Join-Path $coreDir '.build\release\quotapanel-daemon.exe'
    if (-not (Test-Path $daemonSrc)) {
        Write-Host "Built daemon not found at $daemonSrc" -ForegroundColor Red; exit 1
    }
    Copy-Item $daemonSrc (Join-Path $installDir 'quotapanel-daemon.exe') -Force
    Write-Host "    installed $installDir\quotapanel-daemon.exe"
}

# --- 2. Tray app (in-box C# compiler, no SDK needed) --------------------------

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { Write-Host '.NET Framework 4.x compiler (csc.exe) not found.' -ForegroundColor Red; exit 1 }

# A running tray holds its exe open — stop it before overwriting.
Get-Process QuotaPanelTray -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 300

Write-Host '==> Compiling QuotaPanelTray.exe…' -ForegroundColor Cyan
$trayExe = Join-Path $installDir 'QuotaPanelTray.exe'
& $csc /nologo /target:winexe /platform:anycpu `
    "/out:$trayExe" `
    /r:System.dll /r:System.Core.dll /r:System.Drawing.dll `
    /r:System.Windows.Forms.dll /r:System.Web.Extensions.dll `
    $trayCs
if ($LASTEXITCODE -ne 0) { Write-Host 'C# compile failed.' -ForegroundColor Red; exit 1 }
Write-Host "    installed $trayExe"

# --- 3. First data + launch ----------------------------------------------------

$daemon = Join-Path $installDir 'quotapanel-daemon.exe'
if (Test-Path $daemon) {
    Write-Host '==> Fetching first data (quotapanel-daemon --once)…' -ForegroundColor Cyan
    & $daemon --once | Out-Null
}
Start-Process $trayExe

Write-Host ''
Write-Host '==> Done. QuotaPanel is running in the system tray.' -ForegroundColor Green
Write-Host ''
Write-Host 'Notes:'
Write-Host "  - OAuth clients (Gemini/Codex refresh): copy oauth-clients.sample.json to"
Write-Host "    $configDir\oauth-clients.json and fill in the values (see README)."
Write-Host '  - Start with Windows: right-click the tray icon and enable it there.'
Write-Host "  - Config and status live in $configDir"
