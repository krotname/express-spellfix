'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { execFileSync, spawnSync } = require('node:child_process')
const test = require('node:test')

test('Windows guard: silent launcher, Unicode paths, task XML and exit codes', {
  skip: process.platform !== 'win32',
}, () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'SpellFix тест & '))
  const source = path.resolve(__dirname, '..')
  const powershell = path.join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
  const wscript = path.join(process.env.SystemRoot, 'System32', 'wscript.exe')
  const writeScript = (name, text) => fs.writeFileSync(path.join(root, name), '\ufeff' + text)
  try {
    for (const name of ['register-guard.ps1', 'guard-launcher.vbs']) {
      fs.copyFileSync(path.join(source, name), path.join(root, name))
    }
    writeScript('test-registration.ps1', `
$ErrorActionPreference = 'Stop'
function Register-ScheduledTask {
  param($TaskName, $Xml, [switch]$Force)
  if ($TaskName -ne 'eXpress SpellFix Guard' -or -not $Force) { throw 'Registration contract' }
  [xml]$definition = $Xml
  $ns = [Xml.XmlNamespaceManager]::new($definition.NameTable)
  $ns.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
  $expected = '//B //Nologo "' + (Join-Path $PSScriptRoot 'guard-launcher.vbs') + '"'
  if ($definition.SelectSingleNode('//t:Exec/t:Arguments', $ns).InnerText -ne $expected) { throw 'Arguments lost' }
  if ($definition.SelectSingleNode('//t:Exec/t:Command', $ns).InnerText -ne (Join-Path $env:SystemRoot 'System32\\wscript.exe')) { throw 'Console executable' }
  if ($definition.SelectSingleNode('//t:Repetition/t:Interval', $ns).InnerText -ne 'PT7M') { throw 'Interval lost' }
  if ($definition.SelectSingleNode('//t:LogonType', $ns).InnerText -ne 'InteractiveToken') { throw 'Account changed' }
  if ($definition.SelectSingleNode('//t:MultipleInstancesPolicy', $ns).InnerText -ne 'IgnoreNew') { throw 'Overlap policy changed' }
  $global:registrations++
}
$global:registrations = 0
& (Join-Path $PSScriptRoot 'register-guard.ps1') -GuardIntervalMinutes 7
& (Join-Path $PSScriptRoot 'register-guard.ps1') -GuardIntervalMinutes 7
if ($global:registrations -ne 2) { throw 'Not registered twice' }
`)
    execFileSync(powershell, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'test-registration.ps1')], { windowsHide: true })
    for (const code of [0, 37]) {
      writeScript('guard.ps1', `param([switch]$Quiet)\nif (-not $Quiet) { exit 91 }\n[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'ran.txt'), $PSScriptRoot)\nexit ${code}\n`)
      const result = spawnSync(wscript, ['//B', '//Nologo', path.join(root, 'guard-launcher.vbs')], { windowsHide: true, timeout: 15000 })
      assert.ifError(result.error)
      assert.equal(result.status, code)
      assert.equal(fs.readFileSync(path.join(root, 'ran.txt'), 'utf8'), root)
    }
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
  }
})
