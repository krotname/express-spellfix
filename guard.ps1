# eXpress SpellFix Guard — применяет и восстанавливает патч.
#
# Патч состоит из двух частей:
#   1) resources\app\index.js — прослойка, которая подключает фикс и передаёт
#      управление штатной точке входа eXpress;
#   2) поле "main" в корневом package.json внутри app.asar, переведённое на эту
#      прослойку (правка выполняется по месту, длина файла сохраняется).
#
# Обновление eXpress переустанавливает каталог resources и стирает обе части —
# сторож возвращает их обратно. Скрипт идемпотентен и совместим с PowerShell 5.1.

[CmdletBinding()]
param(
    [switch]$Quiet,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFile = Join-Path $root 'guard.log'
$stateFile = Join-Path $root 'state.json'
$helper = Join-Path $root 'bin\ExpressSpellHelper.exe'
$loaderSource = Join-Path $root 'loader\index.js'
$patchedMain = '../app/index.js'
$defaultMain = './electron/src/main/index.js'

# Отметка о каждом запуске (в том числе из планировщика) — файл перезаписывается,
# поэтому лог не растёт, но всегда видно, дошёл ли сторож до выполнения.
try {
    Set-Content -LiteralPath (Join-Path $root 'guard-lastrun.txt') `
        -Value ("$((Get-Date).ToString('s')) pid=$PID ps=$($PSVersionTable.PSVersion) user=$env:USERNAME") `
        -Encoding UTF8
} catch {}

function Write-GuardLog {
    param([string]$Message)
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    try { Add-Content -LiteralPath $logFile -Value "$stamp $Message" -Encoding UTF8 } catch {}
    if (-not $Quiet) { Write-Host $Message }
}

function Get-ExpressInstallPath {
    $candidates = @()
    $registryPaths = @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($registryPath in $registryPaths) {
        try {
            $entries = Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like '*eXpress*' -and $_.InstallLocation }
            foreach ($entry in $entries) { $candidates += $entry.InstallLocation }
        } catch {}
    }
    $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\eXpress')
    $candidates += (Join-Path $env:ProgramFiles 'eXpress')
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path (Join-Path $candidate 'resources\app.asar'))) { return $candidate }
    }
    return $null
}

function Read-State {
    if (Test-Path -LiteralPath $stateFile) {
        try { return Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    }
    return $null
}

function Write-State {
    param([string]$OriginalMain, [string]$InstallPath)
    $state = [ordered]@{
        originalMain = $OriginalMain
        installPath  = $InstallPath
        patchedAt    = (Get-Date).ToString('s')
    }
    ($state | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $stateFile -Encoding UTF8
}

function Invoke-Helper {
    param([string[]]$Arguments)
    $output = & $helper @Arguments
    if (-not $output) { throw "Хелпер не вернул ответ: $($Arguments -join ' ')" }
    $result = $output | ConvertFrom-Json
    if (-not $result.ok) { throw "Хелпер: $($result.error)" }
    return $result
}

$installPath = Get-ExpressInstallPath
if (-not $installPath) {
    Write-GuardLog 'eXpress не найден — нечего патчить'
    exit 0
}
$asar = Join-Path $installPath 'resources\app.asar'
$appDir = Join-Path $installPath 'resources\app'

if (-not (Test-Path -LiteralPath $helper)) {
    Write-GuardLog "ОШИБКА: не собран $helper (запустите install.ps1)"
    exit 1
}

# ------------------------------------------------------------------- удаление
if ($Remove) {
    $state = Read-State
    $restoreMain = $defaultMain
    if ($state -and $state.originalMain) { $restoreMain = $state.originalMain }
    try {
        $info = Invoke-Helper @('asar-info', $asar)
        if ($info.main -eq $patchedMain) {
            $result = Invoke-Helper @('asar-set-main', $asar, $restoreMain)
            Write-GuardLog "app.asar: main возвращён на $($result.main)"
        } else {
            Write-GuardLog "app.asar: правок нет (main = $($info.main))"
        }
    } catch {
        Write-GuardLog "ОШИБКА отката app.asar: $($_.Exception.Message)"
    }
    if (Test-Path -LiteralPath $appDir) {
        Remove-Item -LiteralPath $appDir -Recurse -Force
        Write-GuardLog "Прослойка удалена: $appDir"
    }
    exit 0
}

# ------------------------------------------------------------------ установка
if (-not (Test-Path -LiteralPath $loaderSource)) {
    Write-GuardLog "ОШИБКА: нет прослойки $loaderSource"
    exit 1
}

$restored = @()

if (-not (Test-Path -LiteralPath $appDir)) {
    New-Item -ItemType Directory -Path $appDir -Force | Out-Null
}
$loaderTarget = Join-Path $appDir 'index.js'
$sourceHash = (Get-FileHash -LiteralPath $loaderSource -Algorithm SHA256).Hash
$targetHash = $null
if (Test-Path -LiteralPath $loaderTarget) {
    $targetHash = (Get-FileHash -LiteralPath $loaderTarget -Algorithm SHA256).Hash
}
if ($sourceHash -ne $targetHash) {
    Copy-Item -LiteralPath $loaderSource -Destination $loaderTarget -Force
    $restored += 'прослойка resources\app\index.js'
}

# Указатель на каталог фикса — чтобы прослойка нашла его при любом размещении.
$pointerFile = Join-Path $appDir 'spellfix-root.txt'
$pointerNeeded = $true
if (Test-Path -LiteralPath $pointerFile) {
    $pointerNeeded = ((Get-Content -LiteralPath $pointerFile -Raw -Encoding UTF8).Trim() -ne $root)
}
if ($pointerNeeded) {
    Set-Content -LiteralPath $pointerFile -Value $root -Encoding UTF8 -NoNewline
    $restored += 'указатель spellfix-root.txt'
}

# Прослойка должна лежать на месте раньше, чем на неё переключится main.
$info = Invoke-Helper @('asar-info', $asar)
if ($info.main -ne $patchedMain) {
    if ($info.main -and $info.main -ne $patchedMain) {
        Write-State -OriginalMain $info.main -InstallPath $installPath
    }
    $result = Invoke-Helper @('asar-set-main', $asar, $patchedMain)
    if ($result.changed) {
        $restored += "app.asar: main $($result.previousMain) -> $($result.main)"
    }
} else {
    $state = Read-State
    if (-not $state -or -not $state.originalMain) { Write-State -OriginalMain $defaultMain -InstallPath $installPath }
}

if ($restored.Count -gt 0) {
    Write-GuardLog ("Патч восстановлен [$installPath]: " + ($restored -join '; '))
    $running = Get-Process -Name 'eXpress' -ErrorAction SilentlyContinue
    if ($running) {
        Write-GuardLog 'eXpress запущен — подсказки появятся после его перезапуска'
        try {
            $notify = $true
            $configPath = Join-Path $root 'config.json'
            if (Test-Path -LiteralPath $configPath) {
                $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($null -ne $config.notifyOnRestore) { $notify = [bool]$config.notifyOnRestore }
            }
            if ($notify) {
                Add-Type -AssemblyName System.Windows.Forms
                Add-Type -AssemblyName System.Drawing
                $icon = New-Object System.Windows.Forms.NotifyIcon
                $icon.Icon = [System.Drawing.SystemIcons]::Information
                $icon.Visible = $true
                $icon.ShowBalloonTip(10000, 'eXpress SpellFix',
                    'Подсказки орфографии восстановлены после обновления eXpress. Перезапустите eXpress.',
                    [System.Windows.Forms.ToolTipIcon]::Info)
                Start-Sleep -Seconds 6
                $icon.Dispose()
            }
        } catch {
            Write-GuardLog "Уведомление не показано: $($_.Exception.Message)"
        }
    }
} else {
    Write-GuardLog 'Патч на месте'
}
exit 0
