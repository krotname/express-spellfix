'use strict'
// eXpress SpellFix — возвращает в контекстное меню eXpress подсказки по орфографии.
//
// Почему их нет штатно: eXpress передаёт в electron-context-menu собственный
// коллбэк `menu`, который полностью заменяет шаблон меню и игнорирует четвёртый
// аргумент `dictionarySuggestions`. Патч оборачивает вызов библиотеки и
// добавляет подсказки и пункт «Добавить в словарь» в начало меню.
//
// Источник слов: системная проверка орфографии Windows (Windows Spell Checking API,
// те же лексиконы Microsoft, что использует Word) через ExpressSpellHelper,
// плюс собственные подсказки Chromium как дополнение.

const fs = require('fs')
const path = require('path')
const Module = require('module')

// Корень фикса определяется от расположения самого файла (<ROOT>\spellfix\patch.js),
// поэтому каталог можно переносить целиком, не правя пути.
const ROOT = path.dirname(__dirname)
const LOG_FILE = path.join(ROOT, 'spellfix.log')
const CONFIG_FILE = path.join(ROOT, 'config.json')

const DEFAULT_CONFIG = {
  enabled: true,
  languages: ['ru-RU', 'en-US'],
  maxSuggestions: 6,
  preferSystemDictionary: true,
  useSystemDictionary: true,
  importWordCustomDictionary: true,
  syncToWordCustomDictionary: true,
  ensureSpellCheckerLanguages: true,
  logging: true,
}

function readConfig() {
  try {
    const raw = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'))
    return Object.assign({}, DEFAULT_CONFIG, raw)
  } catch (_) {
    return Object.assign({}, DEFAULT_CONFIG)
  }
}

const config = readConfig()

function log(message) {
  if (!config.logging) return
  try {
    const stamp = new Date().toLocaleString('sv-SE') // локальное время, как в guard.log
    try {
      if (fs.statSync(LOG_FILE).size > 512 * 1024) {
        fs.renameSync(LOG_FILE, LOG_FILE + '.1')
      }
    } catch (_) {}
    fs.appendFileSync(LOG_FILE, `${stamp} [${process.pid}] ${message}\n`)
  } catch (_) {}
}

const LABELS = {
  ru: { add: 'Добавить в словарь', none: 'Вариантов нет' },
  en: { add: 'Add to dictionary', none: 'No suggestions' },
}

function labels() {
  try {
    const { app } = require('electron')
    return String(app.getLocale() || '').toLowerCase().startsWith('ru') ? LABELS.ru : LABELS.en
  } catch (_) {
    return LABELS.ru
  }
}

const { WinSpell } = require('./winspell')
const winspell = new WinSpell(log)

// ---------------------------------------------------------------- словари Word

const WORD_CUSTOM_DIC = path.join(process.env.APPDATA || '', 'Microsoft', 'UProof', 'CUSTOM.DIC')
const WINDOWS_SPELLING_DIR = path.join(process.env.APPDATA || '', 'Microsoft', 'Spelling')

// Словари Word/Windows хранятся в UTF-16LE, иногда с BOM.
function readDictionaryFile(file) {
  try {
    const buffer = fs.readFileSync(file)
    if (buffer.length < 2) return []
    const isUtf16 = buffer[0] === 0xff && buffer[1] === 0xfe
    const text = isUtf16 ? buffer.toString('utf16le', 2) : buffer.toString('utf8').replace(/^﻿/, '')
    return text
      .split(/\r?\n/)
      .map(line => line.trim())
      .filter(line => line && !line.startsWith('#'))
  } catch (_) {
    return []
  }
}

function collectUserWords() {
  const words = new Set()
  if (config.importWordCustomDictionary) {
    for (const word of readDictionaryFile(WORD_CUSTOM_DIC)) words.add(word)
  }
  try {
    for (const dir of fs.readdirSync(WINDOWS_SPELLING_DIR)) {
      for (const word of readDictionaryFile(path.join(WINDOWS_SPELLING_DIR, dir, 'default.dic'))) words.add(word)
    }
  } catch (_) {}
  return [...words]
}

function appendToWordCustomDictionary(word) {
  if (!config.syncToWordCustomDictionary) return
  try {
    if (!fs.existsSync(WORD_CUSTOM_DIC)) return
    if (readDictionaryFile(WORD_CUSTOM_DIC).includes(word)) return
    const buffer = fs.readFileSync(WORD_CUSTOM_DIC)
    const isUtf16 = buffer.length >= 2 && buffer[0] === 0xff && buffer[1] === 0xfe
    const tail = isUtf16 ? buffer.toString('utf16le', 2) : buffer.toString('utf8')
    const separator = tail.length === 0 || /\r?\n$/.test(tail) ? '' : '\r\n'
    const updated = tail + separator + word + '\r\n'
    const encoded = isUtf16
      ? Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(updated, 'utf16le')])
      : Buffer.from(updated, 'utf8')
    fs.writeFileSync(WORD_CUSTOM_DIC, encoded)
    log(`word dictionary: added "${word}"`)
  } catch (error) {
    log('word dictionary: append failed: ' + error.message)
  }
}

// ---------------------------------------------------------------- подсказки

function languagesFor(word) {
  const isCyrillic = /[Ѐ-ӿ]/.test(word)
  const matching = config.languages.filter(lang => (isCyrillic ? /^ru/i : /^en/i).test(lang))
  return matching.length > 0 ? matching : config.languages
}

function systemSuggestions(word) {
  if (!config.useSystemDictionary) return []
  const result = []
  for (const lang of languagesFor(word)) {
    for (const suggestion of winspell.suggest(lang, word)) result.push(suggestion)
    if (result.length > 0) break
  }
  return result
}

function collectSuggestions(word, chromiumSuggestions) {
  const system = systemSuggestions(word)
  const chromium = Array.isArray(chromiumSuggestions) ? chromiumSuggestions : []
  const ordered = config.preferSystemDictionary ? [...system, ...chromium] : [...chromium, ...system]

  const seen = new Set()
  const unique = []
  for (const suggestion of ordered) {
    const key = suggestion.toLowerCase()
    if (suggestion && suggestion !== word && !seen.has(key)) {
      seen.add(key)
      unique.push(suggestion)
    }
  }
  log(`suggest "${word}": system=${system.length} chromium=${chromium.length} shown=${Math.min(unique.length, config.maxSuggestions)}`)
  return unique.slice(0, config.maxSuggestions)
}

function webContentsOf(win) {
  if (!win) return null
  return win.webContents || win
}

function buildSpellItems(props, win) {
  if (!props || !props.misspelledWord || !props.isEditable) return []

  const word = props.misspelledWord
  const target = webContentsOf(win)
  const text = labels()
  const suggestions = collectSuggestions(word, props.dictionarySuggestions)

  const items = suggestions.map(suggestion => ({
    label: suggestion,
    click: () => {
      try {
        target.replaceMisspelling(suggestion)
      } catch (error) {
        log('replaceMisspelling failed: ' + error.message)
      }
    },
  }))

  if (items.length === 0) items.push({ label: text.none, enabled: false })

  items.push({ type: 'separator' })
  items.push({
    label: text.add,
    click: () => {
      const lang = languagesFor(word)[0]
      winspell.addAsync(lang, word)
      appendToWordCustomDictionary(word)
      try {
        target.session.addWordToSpellCheckerDictionary(word)
      } catch (error) {
        log('addWordToSpellCheckerDictionary failed: ' + error.message)
      }
    },
  })
  items.push({ type: 'separator' })
  return items
}

// ------------------------------------------------- перехват electron-context-menu

function wrapContextMenu(original) {
  const wrapped = function (options) {
    const opts = Object.assign({}, options || {})
    const userMenu = opts.menu

    opts.menu = (actions, props, win, dictionarySuggestions) => {
      let items = []
      try {
        items = userMenu ? userMenu(actions, props, win, dictionarySuggestions) : []
      } catch (error) {
        log('original menu callback failed: ' + error.message)
      }
      if (!Array.isArray(items)) items = []

      try {
        const spellItems = buildSpellItems(props, win)
        if (spellItems.length > 0) items = [...spellItems, ...items]
      } catch (error) {
        log('buildSpellItems failed: ' + error.message)
      }
      return items
    }

    log('context menu installed (spellcheck suggestions enabled)')
    return original(opts)
  }
  wrapped.__spellfix = true
  return wrapped
}

function installModuleHook() {
  const originalLoad = Module._load
  Module._load = function (request, parent, isMain) {
    const exported = originalLoad.apply(this, arguments)
    if (request === 'electron-context-menu' && typeof exported === 'function' && !exported.__spellfix) {
      log('hooking electron-context-menu')
      return wrapContextMenu(exported)
    }
    return exported
  }
}

// ------------------------------------------------- настройка проверки орфографии

function configureSession() {
  const { app, session } = require('electron')

  app.whenReady().then(() => {
    try {
      const defaultSession = session.defaultSession
      const available = defaultSession.availableSpellCheckerLanguages || []
      const current = defaultSession.getSpellCheckerLanguages()
      log(`spellchecker: enabled=${defaultSession.spellCheckerEnabled} current=[${current}] available=${available.length}`)

      if (config.ensureSpellCheckerLanguages && available.length > 0) {
        const wanted = config.languages.filter(lang => available.includes(lang))
        const missing = wanted.filter(lang => !current.includes(lang))
        if (missing.length > 0) {
          const next = [...new Set([...current, ...wanted])].filter(lang => available.includes(lang))
          defaultSession.setSpellCheckerLanguages(next)
          log(`spellchecker: languages set to [${next}]`)
        }
      }

      const userWords = collectUserWords()
      if (userWords.length > 0) {
        let added = 0
        for (const word of userWords) {
          try {
            defaultSession.addWordToSpellCheckerDictionary(word)
            added++
          } catch (_) {}
        }
        log(`spellchecker: imported ${added}/${userWords.length} words from Word/Windows dictionaries`)
      }
    } catch (error) {
      log('configureSession failed: ' + error.message)
    }
  })

  app.on('will-quit', () => winspell.stop())
}

// ------------------------------------------------------------------ старт

function start() {
  if (!config.enabled) {
    log('spellfix disabled by config')
    return
  }
  log(`spellfix loading (electron ${process.versions.electron}, exe ${process.execPath})`)
  installModuleHook()
  configureSession()
  winspell.start()
}

start()

module.exports = { start, config }
