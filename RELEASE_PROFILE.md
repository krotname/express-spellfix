# Профиль выпуска eXpress SpellFix

- Репозиторий: `krotname/express-spellfix`, каноническая ветка `main`.
- Источник версии: `VERSION`; исправление ошибки увеличивает patch SemVer.
- Назначение: публичный GitHub Release `v<VERSION>` из проверенного merged SHA.
- Проверки: `node --test tests/patch.test.js tests/guard.test.js` на Windows,
  PowerShell Parser для корневых `.ps1`, `git diff --check`.
- GitHub Actions и обязательных checks на 06.10.2026 нет. Перед выпуском
  перечитать настройки: вновь появившиеся обязательные checks сохранять.
- Артефакты: `express-spellfix.zip` с единственным корнем `express-spellfix/`
  и отдельный ASCII `install-remote.ps1`. В архив входят корневые `.ps1`,
  `guard-launcher.vbs`, `VERSION`, `LICENSE`, README и каталоги `loader`,
  `spellfix`, `src`. Пользовательские config/state/log и `dist` исключены.
- Архив распространяет исходники. C# helper собирается штатным компилятором
  Windows на целевой машине; на ADLER-LENOVO сборку не запускать.
- В архив добавить `release-manifest.json`: версия и точный source SHA.
- Публикация: draft, оба артефакта, проверка размеров и состава, публикация;
  readback API релиза, скачивание обоих опубликованных файлов, проверка
  manifest, состава и ASCII bootstrap. Опубликованный tag и bytes не заменять.
- Checkpoint текущего выпуска: `dist/release-checkpoint.json` (не входит в Git).
- Live update существующей установки: заменить изменённые скрипты/launcher,
  вызвать `register-guard.ps1`, проверить action и завершение задания с кодом 0.
  Не перезапускать работающий eXpress ради изменения фонового launcher.

## Проверенный дефект запуска

Windows Terminal может показать окно до применения `powershell -WindowStyle Hidden`.
Задание запускает `wscript.exe //B //Nologo guard-launcher.vbs`, а VBScript вызывает
PowerShell через `WScript.Shell.Run(command, 0, True)` и передаёт его код возврата.
Пути определяются относительно launcher, XML значения экранируются. Проверка
на Windows включает путь с пробелами, кириллицей и `&`, коды 0 и 37 и повторную
регистрацию расписания без изменения InteractiveToken/IgnoreNew.
