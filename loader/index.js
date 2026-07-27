'use strict'
// Точка входа-прослойка eXpress SpellFix.
//
// В app.asar правится единственное поле package.json: "main" переводится
// с "./electron/src/main/index.js" на "../app/index.js" (то есть на этот файл),
// длина файла при этом сохраняется побайтово — архив не переупаковывается.
// Здесь подключается патч и управление передаётся штатной точке входа eXpress.
//
// Любая ошибка патча не должна мешать запуску eXpress: всё в try/catch,
// а оригинальный main вызывается в любом случае.

const fs = require('fs')
const path = require('path')

const ASAR_PATH = path.join(process.resourcesPath, 'app.asar')

// Путь к фиксу сторож кладёт рядом с этим файлом; по умолчанию фикс живёт
// соседней папкой с самим eXpress (…\Programs\eXpress-SpellFix).
function resolveFixRoot() {
  try {
    const pointer = fs.readFileSync(path.join(__dirname, 'spellfix-root.txt'), 'utf8').trim()
    if (pointer && fs.existsSync(path.join(pointer, 'spellfix', 'patch.js'))) return pointer
  } catch (_) {}
  return path.resolve(process.resourcesPath, '..', '..', 'eXpress-SpellFix')
}

const FIX_ROOT = resolveFixRoot()
const LOG_FILE = path.join(FIX_ROOT, 'spellfix.log')
const STATE_FILE = path.join(FIX_ROOT, 'state.json')
const DEFAULT_MAIN = './electron/src/main/index.js'

function log(message) {
  try {
    const stamp = new Date().toLocaleString('sv-SE') // локальное время, как в guard.log
    fs.appendFileSync(LOG_FILE, `${stamp} [${process.pid}] loader: ${message}\n`)
  } catch (_) {}
}

// Оригинальное значение main сохраняет сторож при установке патча.
function originalMain() {
  try {
    const state = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'))
    if (state && typeof state.originalMain === 'string' && state.originalMain.length > 0) {
      return state.originalMain
    }
  } catch (_) {}
  return DEFAULT_MAIN
}

const entryPoint = path.join(ASAR_PATH, originalMain())

// Если Electron когда-нибудь начнёт предпочитать каталог resources\app самому
// архиву, appPath нужно вернуть на app.asar — иначе поедут getAppPath/версия.
try {
  const { app } = require('electron')
  if (typeof app.getAppPath === 'function' && app.getAppPath() !== ASAR_PATH) {
    if (typeof app.setAppPath === 'function') {
      app.setAppPath(ASAR_PATH)
      log('appPath redirected to app.asar')
    }
  }
} catch (error) {
  log('appPath check failed: ' + error.message)
}

try {
  require(path.join(FIX_ROOT, 'spellfix', 'patch.js'))
} catch (error) {
  log('patch failed to load: ' + error.message)
}

require(entryPoint)
