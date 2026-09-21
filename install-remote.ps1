# eXpress SpellFix - one-command installer, no administrator rights required.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://github.com/krotname/express-spellfix/releases/latest/download/install-remote.ps1 | iex"
#
# Downloads the latest release, unpacks it into %LOCALAPPDATA%\Programs\eXpress-SpellFix,
# applies the patch and restarts eXpress, so the suggestions work right away.
# Everything stays inside the user profile.
#
# This file is executed through `irm | iex`, so it must stay ASCII-only and BOM-free:
# Windows PowerShell 5.1 decodes the downloaded body as Latin-1, which would corrupt
# any non-ASCII text. Localized output comes from install.ps1, which runs as a file.
#
# Options are taken from environment variables:
#   SPELLFIX_RESTART=0        - keep eXpress running, the patch applies at its next start
#   SPELLFIX_VERSION=v1.0.0   - install a specific release instead of the latest one
#   SPELLFIX_REPO=owner/name  - use another repository (forks)

$Repository = if ($env:SPELLFIX_REPO) { $env:SPELLFIX_REPO } else { 'krotname/express-spellfix' }
$Version = if ($env:SPELLFIX_VERSION) { $env:SPELLFIX_VERSION } else { 'latest' }
# The patched entry point is read only when eXpress starts, so restarting is the default.
$Restart = $env:SPELLFIX_RESTART -notin @('0', 'false', 'no', 'off')

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$ProgressPreference = 'SilentlyContinue'

function Get-ExpressProcess {
    return @(Get-Process -Name 'eXpress' -ErrorAction SilentlyContinue)
}

function Wait-ExpressExit {
    param([int]$TimeoutSeconds = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-ExpressProcess).Count -gt 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
    return ((Get-ExpressProcess).Count -eq 0)
}

function Restart-Express {
    param([string]$Executable)
    $running = Get-ExpressProcess
    if ($running.Count -eq 0) {
        Write-Host '==> eXpress is not running, the patch applies at its next start'
        return
    }
    foreach ($process in $running) {
        try { if ($process.Path) { $Executable = $process.Path; break } } catch {}
    }
    if (-not $Executable -or -not (Test-Path -LiteralPath $Executable)) {
        Write-Host '==> eXpress.exe not found, restart the messenger manually' -ForegroundColor Yellow
        return
    }
    Write-Host '==> Restarting eXpress'
    # Electron runs several processes and closing the window only hides it to the tray,
    # so the whole group is stopped and the executable is started again.
    $running | Stop-Process -Force -ErrorAction SilentlyContinue
    if (-not (Wait-ExpressExit)) {
        Write-Host '==> eXpress did not stop, restart the messenger manually' -ForegroundColor Yellow
        return
    }
    Start-Sleep -Seconds 1
    Start-Process -FilePath $Executable -WorkingDirectory (Split-Path -Parent $Executable)
    Start-Sleep -Seconds 3
    if ((Get-ExpressProcess).Count -gt 0) {
        Write-Host '==> eXpress restarted' -ForegroundColor Green
    } else {
        Write-Host '==> eXpress did not start, launch the messenger manually' -ForegroundColor Yellow
    }
}

$target = Join-Path $env:LOCALAPPDATA 'Programs\eXpress-SpellFix'
$assetUrl = if ($Version -eq 'latest') {
    "https://github.com/$Repository/releases/latest/download/express-spellfix.zip"
} else {
    "https://github.com/$Repository/releases/download/$Version/express-spellfix.zip"
}

Write-Host 'eXpress SpellFix' -ForegroundColor Cyan

# Nothing to patch unless eXpress is installed.
$expressExe = $null
foreach ($candidate in @((Join-Path $env:LOCALAPPDATA 'Programs\eXpress'), (Join-Path $env:ProgramFiles 'eXpress'))) {
    if (Test-Path (Join-Path $candidate 'resources\app.asar')) {
        $expressExe = Join-Path $candidate 'eXpress.exe'
        break
    }
}
if (-not $expressExe) {
    Write-Host 'eXpress not found - install the messenger first, then run this command again.' -ForegroundColor Yellow
    return
}

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("express-spellfix-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
$archive = Join-Path $temp 'express-spellfix.zip'

try {
    Write-Host "==> Downloading $assetUrl"
    Invoke-WebRequest -Uri $assetUrl -OutFile $archive -UseBasicParsing

    Write-Host '==> Unpacking'
    Expand-Archive -LiteralPath $archive -DestinationPath $temp -Force

    # Program files are refreshed, user config and logs are left untouched.
    $payload = Join-Path $temp 'express-spellfix'
    if (-not (Test-Path $payload)) { $payload = $temp }
    Get-Process -Name 'ExpressSpellHelper' -ErrorAction SilentlyContinue | Stop-Process -Force
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $payload) {
        if ($item.Name -eq 'express-spellfix.zip') { continue }
        Copy-Item -LiteralPath $item.FullName -Destination $target -Recurse -Force
    }

    # install.ps1 and guard.ps1 always run in Windows PowerShell 5.1 with the stock
    # module path - the same environment the scheduled task uses. A PowerShell 7 parent
    # exports its own Modules directory through PSModulePath; Windows PowerShell then
    # loads the Core build of Microsoft.PowerShell.Utility and cmdlets such as
    # Get-FileHash disappear from the session, which used to break the installation.
    $winPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $winPowerShell)) { throw "Windows PowerShell not found: $winPowerShell" }
    $savedModulePath = $env:PSModulePath
    $savedErrorAction = $ErrorActionPreference
    $env:PSModulePath = (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules') + ';' +
        (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules')
    $ErrorActionPreference = 'Continue'
    try {
        & $winPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $target 'install.ps1')
        $installExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorAction
        $env:PSModulePath = $savedModulePath
    }
    if ($installExitCode -ne 0) { throw "install.ps1 finished with exit code $installExitCode" }

    if ($Restart) {
        Restart-Express -Executable $expressExe
    } else {
        Write-Host '==> Restart eXpress to activate the patch'
    }
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
