# Полное удаление eXpress SpellFix: задача-сторож, прослойка resources\app.
# Сам eXpress не затрагивается — app.asar никогда не модифицировался.

[CmdletBinding()]
param([switch]$KeepFiles)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$taskName = 'eXpress SpellFix Guard'

try {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
    Write-Host "==> Задача «$taskName» удалена"
} catch {
    Write-Host "==> Задача «$taskName» не найдена"
}

& (Join-Path $root 'guard.ps1') -Remove

Get-Process -Name 'ExpressSpellHelper' -ErrorAction SilentlyContinue | Stop-Process -Force

if ($KeepFiles) {
    Write-Host "==> Файлы фикса оставлены в $root"
} else {
    Write-Host "==> Удалите каталог вручную, если он больше не нужен: $root"
}
Write-Host 'Готово. Перезапустите eXpress — вернётся штатное поведение.' -ForegroundColor Green
