# install.ps1 — one-shot QuotaPanel install for Windows.
#
# Builds the shared Swift daemon (linux/QuotaPanelCore — the "linux" folder
# holds the portable core, which also compiles on Windows), compiles the tray
# app with the C# compiler Windows ships in-box, installs both under
# %LOCALAPPDATA%\QuotaPanel, creates Desktop + Start Menu shortcuts, writes the
# default OAuth client ids so in-app sign-in works out of the box, fetches first
# data, and starts the tray.
#
# Usage (from the repo):
#   powershell -ExecutionPolicy Bypass -File windows\install.ps1
#
#   -SkipDaemon   reuse the already-installed daemon (tray-only iteration)

param([switch]$SkipDaemon)

$ErrorActionPreference = 'Stop'

function Import-VcVars($vcvars) {
    cmd /c "`"$vcvars`" && set" | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($matches[1])" -Value $matches[2] }
    }
}

# Swift's linker needs the Windows SDK import libraries (kernel32.lib / ucrt.lib);
# they only land on $env:LIB once a Windows SDK component is installed. The MSVC
# toolset (VC.Tools) alone does not provide them.
function Test-HasWindowsSdk {
    if (-not $env:LIB) { return $false }
    foreach ($d in $env:LIB.Split(';')) {
        if ($d -and (Test-Path (Join-Path $d 'kernel32.lib'))) { return $true }
    }
    return $false
}

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

    # Swift on Windows links against the MSVC toolset and the Windows SDK, so the
    # build needs the Visual Studio developer environment (INCLUDE/LIB/PATH) and a
    # Windows SDK. Locate VS, import vcvars64.bat unless we're already inside a
    # developer prompt (VCToolsInstallDir is set there), then make sure the SDK is
    # actually present before building.
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $vsPath  = $null
    if (Test-Path $vswhere) {
        $vsPath = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath 2>$null | Select-Object -First 1
    }
    $vcvars = if ($vsPath) { Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat' } else { $null }

    if (-not $env:VCToolsInstallDir) {
        if ($vcvars -and (Test-Path $vcvars)) {
            Write-Host '==> Importing Visual Studio build environment…' -ForegroundColor Cyan
            Import-VcVars $vcvars
        } else {
            Write-Host 'Visual Studio C++ build tools were not found.' -ForegroundColor Red
            Write-Host 'Install Visual Studio 2022 (or the Build Tools) with the'
            Write-Host '"Desktop development with C++" workload — it provides the MSVC'
            Write-Host 'compiler and the Windows SDK that the Swift compiler links against —'
            Write-Host 'then re-run this script. See https://www.swift.org/install/windows/.'
            exit 1
        }
    }

    # MSVC alone isn't enough: swift build's linker fails with "cannot open input
    # file 'kernel32.lib' / 'ucrt.lib'" when no Windows SDK is installed (this is
    # the "Swift build failed" you hit on a machine that only has the compiler).
    # If it's missing, add it through the VS installer, then re-import so the
    # freshly installed SDK's LIB/INCLUDE paths take effect — and only then build.
    if (-not (Test-HasWindowsSdk)) {
        $setup = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\setup.exe'
        if (-not ($vsPath -and (Test-Path $setup))) {
            Write-Host 'The Windows SDK is missing and cannot be installed automatically.' -ForegroundColor Red
            Write-Host 'Open the Visual Studio Installer, choose Modify, enable the'
            Write-Host '"Desktop development with C++" workload, then re-run this script.'
            exit 1
        }
        Write-Host '==> Windows SDK not found — installing it via the Visual Studio installer…' -ForegroundColor Yellow
        Write-Host '    A UAC prompt will appear; this can take a few minutes.'
        $sdkArgs = @(
            'modify', '--installPath', $vsPath,
            '--add', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
            '--add', 'Microsoft.VisualStudio.Component.Windows11SDK.26100',
            '--quiet', '--norestart'
        )
        try {
            $proc = Start-Process -FilePath $setup -ArgumentList $sdkArgs -Verb RunAs -Wait -PassThru
        } catch {
            Write-Host 'Windows SDK install was cancelled (UAC declined).' -ForegroundColor Red
            exit 1
        }
        # 0 = success, 3010 = success but a reboot is pending; anything else fails.
        if ($proc.ExitCode -and $proc.ExitCode -ne 3010) {
            Write-Host "Windows SDK install failed (exit $($proc.ExitCode))." -ForegroundColor Red
            Write-Host 'Install the "Desktop development with C++" workload manually, then re-run.'
            exit 1
        }
        if ($vcvars -and (Test-Path $vcvars)) { Import-VcVars $vcvars }
        if (-not (Test-HasWindowsSdk)) {
            Write-Host 'Windows SDK still not detected after the install.' -ForegroundColor Red
            Write-Host 'Open "Developer PowerShell for VS 2022" and re-run this script.'
            exit 1
        }
        Write-Host '    Windows SDK installed.' -ForegroundColor Green
    }

    Write-Host '==> Building quotapanel-daemon (swift build -c release)…' -ForegroundColor Cyan
    & swift build -c release --package-path $coreDir
    if ($LASTEXITCODE -ne 0) { Write-Host 'Swift build failed.' -ForegroundColor Red; exit 1 }

    # SwiftPM can't create the `.build\release` symlink without Developer Mode on
    # Windows, so resolve the real per-triple bin directory instead of guessing.
    $binPath = (& swift build -c release --package-path $coreDir --show-bin-path | Select-Object -Last 1).Trim()
    $daemonSrc = Join-Path $binPath 'quotapanel-daemon.exe'
    if (-not (Test-Path $daemonSrc)) {
        Write-Host "Built daemon not found at $daemonSrc" -ForegroundColor Red; exit 1
    }
    Copy-Item $daemonSrc (Join-Path $installDir 'quotapanel-daemon.exe') -Force
    Write-Host "    installed $installDir\quotapanel-daemon.exe"
}

# --- 2. Brand icons (same SVG glyphs the macOS app / GNOME extension use) ----

$iconsDir = Join-Path $installDir 'icons'
New-Item -ItemType Directory -Force -Path $iconsDir | Out-Null
Copy-Item (Join-Path $repoRoot 'Resources\ProviderIcon-*.svg') $iconsDir -Force
Write-Host "    installed provider icons to $iconsDir"

# --- 3. Tray app (in-box C# compiler, no SDK needed) --------------------------

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

# --- 4. Desktop + Start Menu shortcuts ---------------------------------------
# QuotaPanel is a system-tray app (no window — it lives next to the clock), and
# the exe is buried under %LOCALAPPDATA%. These shortcuts let you launch it like
# any normal app: double-click the Desktop icon or find it in the Start menu.
# Launching again while it's already running is harmless — the single-instance
# mutex makes the second copy exit immediately.
Write-Host '==> Creating Desktop and Start Menu shortcuts…' -ForegroundColor Cyan
$shell = New-Object -ComObject WScript.Shell
foreach ($lnk in @(
    (Join-Path ([Environment]::GetFolderPath('Desktop'))  'QuotaPanel.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'QuotaPanel.lnk')
)) {
    try {
        $sc = $shell.CreateShortcut($lnk)
        $sc.TargetPath       = $trayExe
        $sc.WorkingDirectory = $installDir
        $sc.IconLocation     = $trayExe
        $sc.Description       = 'QuotaPanel - AI usage quotas in the system tray'
        $sc.Save()
        Write-Host "    $lnk"
    } catch {
        Write-Host "    could not create $lnk ($($_.Exception.Message))" -ForegroundColor Yellow
    }
}

# --- 5. Default OAuth client ids (in-app sign-in with no manual setup) --------
# Gemini / Codex / Copilot public client ids (the ones the upstream CLIs
# publish; the tray also bundles them in code). Writing them to
# oauth-clients.json makes in-app sign-in work regardless of build state and
# gives you a file you can inspect/edit. Claude is intentionally left out
# (Anthropic restricts its OAuth to Claude Code / Claude.ai). Any existing
# entries — a claude entry, your own overrides — are preserved; only missing or
# PASTE_ placeholder ones are filled. Wrapped so a failure never aborts install.
$oauthFile = Join-Path $configDir 'oauth-clients.json'
try {
    $config = [ordered]@{}
    if (Test-Path $oauthFile) {
        try {
            (Get-Content -Raw -Path $oauthFile | ConvertFrom-Json).PSObject.Properties |
                ForEach-Object { $config[$_.Name] = $_.Value }
        } catch {
            Write-Host '    existing oauth-clients.json was unreadable - rewriting it' -ForegroundColor Yellow
        }
    }
    $defaults = [ordered]@{
        gemini  = [ordered]@{
            clientId     = '681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com'
            clientSecret = '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'
        }
        codex   = [ordered]@{ clientId = 'app_EMoamEEZ73f0CkXaXp7hrann' }
        copilot = [ordered]@{ clientId = 'Iv1.b507a08c87ecfe98' }
    }
    foreach ($name in $defaults.Keys) {
        $cur = $config[$name]
        $needs = -not $cur
        if ($cur) {
            foreach ($field in $defaults[$name].Keys) {
                $v = [string]$cur.$field
                if ([string]::IsNullOrEmpty($v) -or $v.StartsWith('PASTE_')) { $needs = $true; break }
            }
        }
        if ($needs) { $config[$name] = $defaults[$name] }
    }
    ($config | ConvertTo-Json -Depth 5) | Set-Content -Path $oauthFile -Encoding UTF8
    Write-Host "==> Wrote default client ids to $oauthFile" -ForegroundColor Cyan
} catch {
    Write-Host "    could not write $oauthFile ($($_.Exception.Message))" -ForegroundColor Yellow
}

# --- 6. First data + launch ----------------------------------------------------

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
Write-Host '  - QuotaPanel has no window - look for its icon in the system tray (bottom-right,'
Write-Host '    next to the clock; click the ^ arrow if hidden). Click the icon to open the panel.'
Write-Host '  - To launch it again later: double-click the QuotaPanel icon on your Desktop'
Write-Host '    or find QuotaPanel in the Start menu.'
Write-Host '  - Start with Windows (auto-launch at login): right-click the tray icon and enable it.'
Write-Host '  - In-app sign-in for Gemini, Codex and Copilot works out of the box - their client'
Write-Host "    ids were written to $configDir\oauth-clients.json. Add a 'claude' entry there for"
Write-Host '    Claude in-app sign-in (see README); Antigravity reads its own credentials.'
Write-Host "  - Config and status live in $configDir"
