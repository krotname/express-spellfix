# Установка eXpress SpellFix: сборка хелпера, прослойка resources\app,
# задача-сторож, которая возвращает патч после обновлений eXpress.
# Права администратора не нужны — eXpress установлен в профиль пользователя.

[CmdletBinding()]
param(
    [ValidateRange(1, 1440)][int]$GuardIntervalMinutes = 10
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$taskName = 'eXpress SpellFix Guard'

function Write-Step { param([string]$Message) Write-Host "==> $Message" }

# ------------------------------------------------------------------ 1. хелпер
$helper = Join-Path $root 'bin\ExpressSpellHelper.exe'
$helperSource = Join-Path $root 'src\SpellHelper.cs'
$needBuild = -not (Test-Path -LiteralPath $helper)
if (-not $needBuild) {
    $needBuild = (Get-Item -LiteralPath $helperSource).LastWriteTimeUtc -gt (Get-Item -LiteralPath $helper).LastWriteTimeUtc
}
if ($needBuild) {
    Write-Step 'Сборка ExpressSpellHelper.exe'
    $csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc)) { throw "Не найден компилятор C#: $csc" }
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'bin') | Out-Null
    # Запущенный хелпер держит exe и не даст его перезаписать.
    Get-Process -Name 'ExpressSpellHelper' -ErrorAction SilentlyContinue | Stop-Process -Force
    & $csc /nologo /target:exe /platform:anycpu /optimize+ /out:$helper $helperSource
    if ($LASTEXITCODE -ne 0) { throw "Сборка хелпера завершилась с кодом $LASTEXITCODE" }
} else {
    Write-Step 'ExpressSpellHelper.exe актуален'
}

$check = & $helper suggest ru-RU 'превет' | ConvertFrom-Json
if (-not $check.ok) { throw 'Хелпер не отвечает на suggest' }
Write-Step "Системный словарь отвечает: превет -> $($check.suggestions[0])"

# ------------------------------------------------------------- 2. проверки
$installPath = $null
foreach ($candidate in @((Join-Path $env:LOCALAPPDATA 'Programs\eXpress'), (Join-Path $env:ProgramFiles 'eXpress'))) {
    if (Test-Path (Join-Path $candidate 'resources\app.asar')) { $installPath = $candidate; break }
}
if (-not $installPath) { throw 'Установка eXpress не найдена' }
Write-Step "eXpress найден: $installPath"

$asarInfo = & $helper asar-info (Join-Path $installPath 'resources\app.asar') | ConvertFrom-Json
if (-not $asarInfo.ok) { throw "Не удалось прочитать app.asar: $($asarInfo.error)" }
Write-Step "Точка входа приложения: $($asarInfo.main)"

# Каталог прослойки от предыдущей схемы патча больше не нужен.
$staleManifest = Join-Path $installPath 'resources\app\package.json'
if (Test-Path -LiteralPath $staleManifest) { Remove-Item -LiteralPath $staleManifest -Force }
$staleLoaderManifest = Join-Path $root 'loader\package.json'
if (Test-Path -LiteralPath $staleLoaderManifest) { Remove-Item -LiteralPath $staleLoaderManifest -Force }

# --------------------------------------------------------------- 3. конфиг
$configPath = Join-Path $root 'config.json'
if (-not (Test-Path -LiteralPath $configPath)) {
    $config = [ordered]@{
        enabled                      = $true
        languages                    = @('ru-RU', 'en-US')
        maxSuggestions               = 6
        preferSystemDictionary       = $true
        useSystemDictionary          = $true
        importWordCustomDictionary   = $true
        syncToWordCustomDictionary   = $true
        ensureSpellCheckerLanguages  = $true
        logging                      = $true
        notifyOnRestore              = $true
    }
    ($config | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $configPath -Encoding UTF8
    Write-Step 'Создан config.json'
}

# ------------------------------------------------------- 4. установка патча
& (Join-Path $root 'guard.ps1')

# Windows PowerShell 5.1 (именно он запускает задачу) читает файлы без BOM
# как ANSI и ломается на кириллице — держим скрипты в UTF-8 с BOM.
foreach ($script in @('guard.ps1', 'install.ps1', 'uninstall.ps1', 'register-guard.ps1')) {
    $scriptPath = Join-Path $root $script
    if (-not (Test-Path -LiteralPath $scriptPath)) { continue }
    $bytes = [System.IO.File]::ReadAllBytes($scriptPath)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    if (-not $hasBom) {
        $text = [System.IO.File]::ReadAllText($scriptPath, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText($scriptPath, $text, (New-Object System.Text.UTF8Encoding($true)))
        Write-Step "Кодировка $script приведена к UTF-8 с BOM"
    }
}

# --------------------------------------------------------- 5. задача-сторож
& (Join-Path $root 'register-guard.ps1') -GuardIntervalMinutes $GuardIntervalMinutes

Write-Host ''
Write-Host 'Готово. Перезапустите eXpress, чтобы патч заработал.' -ForegroundColor Green
