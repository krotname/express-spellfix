# eXpress SpellFix - one-command installer, no administrator rights required.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://github.com/krotname/express-spellfix/releases/latest/download/install-remote.ps1 | iex"
#
# Downloads the latest release, unpacks it into %LOCALAPPDATA%\Programs\eXpress-SpellFix
# and applies the patch. Everything stays inside the user profile.
#
# This file is executed through `irm | iex`, so it must stay ASCII-only and BOM-free:
# Windows PowerShell 5.1 decodes the downloaded body as Latin-1, which would corrupt
# any non-ASCII text. Localized output comes from install.ps1, which runs as a file.
#
# Options are taken from environment variables:
#   SPELLFIX_RESTART=1        - restart eXpress right after the installation
#   SPELLFIX_VERSION=v1.0.0   - install a specific release instead of the latest one
#   SPELLFIX_REPO=owner/name  - use another repository (forks)

$Repository = if ($env:SPELLFIX_REPO) { $env:SPELLFIX_REPO } else { 'krotname/express-spellfix' }
$Version = if ($env:SPELLFIX_VERSION) { $env:SPELLFIX_VERSION } else { 'latest' }
$Restart = $env:SPELLFIX_RESTART -in @('1', 'true', 'yes')

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$ProgressPreference = 'SilentlyContinue'

$target = Join-Path $env:LOCALAPPDATA 'Programs\eXpress-SpellFix'
$assetUrl = if ($Version -eq 'latest') {
    "https://github.com/$Repository/releases/latest/download/express-spellfix.zip"
} else {
    "https://github.com/$Repository/releases/download/$Version/express-spellfix.zip"
}

Write-Host 'eXpress SpellFix' -ForegroundColor Cyan

# Nothing to patch unless eXpress is installed.
$expressFound = $false
foreach ($candidate in @((Join-Path $env:LOCALAPPDATA 'Programs\eXpress'), (Join-Path $env:ProgramFiles 'eXpress'))) {
    if (Test-Path (Join-Path $candidate 'resources\app.asar')) { $expressFound = $true; break }
}
if (-not $expressFound) {
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

    & (Join-Path $target 'install.ps1')

    if ($Restart) {
        $running = Get-Process -Name 'eXpress' -ErrorAction SilentlyContinue
        if ($running) {
            Write-Host '==> Restarting eXpress'
            $exe = $running[0].Path
            $running | Stop-Process -Force
            Start-Sleep -Seconds 3
            Start-Process $exe
        }
    }
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
