# eXpress SpellFix

Возвращает в контекстное меню мессенджера [eXpress](https://express.ms) подсказки по орфографии:
правый клик по подчёркнутому слову → варианты замены и «Добавить в словарь».
Слова берутся из системного словаря Windows — того же движка Microsoft, что и в Word.

## Установка

Одна команда, права администратора не нужны. Ничего клонировать и распаковывать вручную не надо.

**PowerShell:**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://github.com/krotname/express-spellfix/releases/latest/download/install-remote.ps1 | iex"
```

**Командная строка (curl, есть в Windows 10/11 из коробки):**

```bat
curl -sL -o "%TEMP%\spellfix.ps1" https://github.com/krotname/express-spellfix/releases/latest/download/install-remote.ps1 && powershell -NoProfile -ExecutionPolicy Bypass -File "%TEMP%\spellfix.ps1"
```

Затем перезапустите eXpress — или добавьте `$env:SPELLFIX_RESTART=1;` перед командой PowerShell,
чтобы установщик перезапустил мессенджер сам.

## Удаление

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\eXpress-SpellFix\uninstall.ps1"
```

## Как это работает

`app.asar` не переупаковывается и файлы eXpress не переписываются. Точка входа приложения
переводится на прослойку `resources\app\index.js` правкой одного поля `main` внутри архива
по месту — длина файла сохраняется побайтово, SHA256 записи в заголовке пересчитывается.
Обновление eXpress стирает патч (мессенджер продолжает работать штатно), задача планировщика
«eXpress SpellFix Guard» возвращает его в течение 10 минут.

Настройки — `config.json` рядом с установкой: языки, число подсказок, синхронизация со словарём Word.

## Требования

Windows 10/11, eXpress для Windows. Ничего скачивать дополнительно не нужно: хелпер к системному
словарю собирается штатным `csc.exe` из состава Windows.

## Дисклеймер

Неофициальный проект, не связан с Unlimited Technology LLC. Используйте на свой риск.
Лицензия MIT.
