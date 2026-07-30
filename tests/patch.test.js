'use strict'

const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const Module = require('module')
const test = require('node:test')

test('исправление слова повторно запускает spellcheck редактора', async () => {
  const originalLoad = Module._load
  const originalAppendFileSync = fs.appendFileSync
  let capturedOptions = null

  const fakeElectron = {
    app: {
      getLocale: () => 'ru',
      on: () => {},
      whenReady: () => ({ then: () => {} }),
    },
    session: { defaultSession: {} },
  }
  const originalContextMenu = options => {
    capturedOptions = options
    return () => {}
  }

  fs.appendFileSync = () => {}
  Module._load = function (request) {
    if (request === 'electron') return fakeElectron
    if (request === 'electron-context-menu') return originalContextMenu
    return originalLoad.apply(this, arguments)
  }

  try {
    const patchPath = path.resolve(__dirname, '..', 'spellfix', 'patch.js')
    delete require.cache[patchPath]
    require(patchPath)

    const contextMenu = require('electron-context-menu')
    contextMenu({ menu: () => [] })
    assert.ok(capturedOptions)

    const calls = []
    const target = {
      executeJavaScript: script => {
        calls.push(['executeJavaScript', script])
        return Promise.resolve(true)
      },
      focus: () => calls.push(['focus']),
      replaceMisspelling: word => calls.push(['replaceMisspelling', word]),
      session: { addWordToSpellCheckerDictionary: () => {} },
    }
    const props = {
      dictionarySuggestions: ['ошибка'],
      isEditable: true,
      misspelledWord: 'ошбка',
      x: 73.4,
      y: 40.6,
    }

    const items = capturedOptions.menu({}, props, { webContents: target }, [])
    assert.equal(items[0].label, 'ошибка')
    items[0].click()
    await new Promise(resolve => setTimeout(resolve, 20))

    assert.deepEqual(calls[0], ['replaceMisspelling', 'ошибка'])
    assert.deepEqual(calls[1], ['focus'])
    assert.equal(calls[2][0], 'executeJavaScript')

    const script = calls[2][1]
    assert.match(script, /document\.elementFromPoint\(73, 41\)/)
    assert.match(script, /setAttribute\('spellcheck', 'false'\)/)
    assert.match(script, /requestAnimationFrame/)
    assert.doesNotThrow(() => new Function(script))
  } finally {
    Module._load = originalLoad
    fs.appendFileSync = originalAppendFileSync
  }
})
