# eXpress SpellFix — установка одной командой, без прав администратора.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://github.com/krotname/express-spellfix/releases/latest/download/install-remote.ps1 | iex"
#
# Скачивает последний релиз, распаковывает в %LOCALAPPDATA%\Programs\eXpress-SpellFix
# и применяет патч. Всё происходит в профиле пользователя: ни установка eXpress,
# ни системные каталоги не требуют повышения прав.

# Скрипт запускается через `irm ... | iex`, поэтому параметров у него нет:
# настройки читаются из переменных окружения.
#   SPELLFIX_RESTART=1        — перезапустить eXpress сразу после установки
#   SPELLFIX_VERSION=v1.0.0   — поставить конкретную версию вместо последней
#   SPELLFIX_REPO=owner/name  — другой репозиторий (для форков)

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

Write-Host 'eXpress SpellFix — подсказки орфографии в контекстном меню' -ForegroundColor Cyan

# eXpress должен быть установлен, иначе патчить нечего.
$expressFound = $false
foreach ($candidate in @((Join-Path $env:LOCALAPPDATA 'Programs\eXpress'), (Join-Path $env:ProgramFiles 'eXpress'))) {
    if (Test-Path (Join-Path $candidate 'resources\app.asar')) { $expressFound = $true; break }
}
if (-not $expressFound) {
    Write-Host 'eXpress не найден. Установите мессенджер и повторите команду.' -ForegroundColor Yellow
    return
}

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("express-spellfix-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
$archive = Join-Path $temp 'express-spellfix.zip'

try {
    Write-Host "==> Загрузка пакета: $assetUrl"
    Invoke-WebRequest -Uri $assetUrl -OutFile $archive -UseBasicParsing

    Write-Host '==> Распаковка'
    Expand-Archive -LiteralPath $archive -DestinationPath $temp -Force

    # Файлы фикса обновляем, пользовательские config.json/логи не трогаем.
    $payload = Join-Path $temp 'express-spellfix'
    if (-not (Test-Path $payload)) { $payload = $temp }
    Get-Process -Name 'ExpressSpellHelper' -ErrorAction SilentlyContinue | Stop-Process -Force
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $payload) {
        if ($item.Name -eq 'express-spellfix.zip') { continue }
        Copy-Item -LiteralPath $item.FullName -Destination $target -Recurse -Force
    }

    Write-Host '==> Установка'
    & (Join-Path $target 'install.ps1')

    if ($Restart) {
        $running = Get-Process -Name 'eXpress' -ErrorAction SilentlyContinue
        if ($running) {
            Write-Host '==> Перезапуск eXpress'
            $exe = $running[0].Path
            $running | Stop-Process -Force
            Start-Sleep -Seconds 3
            Start-Process $exe
        }
    } else {
        Write-Host ''
        Write-Host 'Перезапустите eXpress, чтобы подсказки заработали.' -ForegroundColor Green
    }
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
