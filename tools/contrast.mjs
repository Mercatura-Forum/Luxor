#!/usr/bin/env node
// WCAG 2.2 AA contrast for every property's theme tokens, light and dark, read from the stylesheet
// the page uses (frontend/src/index.css). Text pairs need 4.5:1 (1.4.3); the focus ring and form
// field borders need 3:1 against what they sit on (1.4.11, non-text contrast).
//
// The formula is checked first against values published with WCAG (black on white 21:1, #767676 on
// white 4.54:1, #777777 on white 4.48:1): a checker whose arithmetic is wrong would pass anything.
//
// Attribution: Thebes Core Team. Licence: Apache 2.0.
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const here = path.dirname(fileURLToPath(import.meta.url))
const css = readFileSync(path.join(here, '../frontend/src/index.css'), 'utf8')

const lin = (c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4 }
const lum = (hex) => { const n = parseInt(hex.slice(1), 16); return 0.2126 * lin(n >> 16) + 0.7152 * lin((n >> 8) & 255) + 0.0722 * lin(n & 255) }
const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05) }

let fail = 0
for (const [a, b, want] of [['#000000', '#ffffff', 21], ['#767676', '#ffffff', 4.54], ['#777777', '#ffffff', 4.48]]) {
  const got = Math.round(ratio(a, b) * 100) / 100
  if (got !== want) { console.log(`FORMULA WRONG: ${a} on ${b} is ${got}, WCAG says ${want}`); fail++ }
}
console.log('count: formula vectors checked = 3')

// the token blocks: [data-tenant='x'] and [data-tenant='x'][data-mode='dark'], dark inheriting light
const blocks = {}
for (const m of css.matchAll(/\[data-tenant='(\w+)'\](\[data-mode='dark'\])?\s*\{([^}]*)\}/g)) {
  const vars = Object.fromEntries([...m[3].matchAll(/--lx-([\w-]+):\s*(#[0-9a-fA-F]{6})\s*;/g)].map((v) => [v[1], v[2].toLowerCase()]))
  blocks[`${m[1]}/${m[2] ? 'dark' : 'light'}`] = vars
}
for (const k of Object.keys(blocks)) if (k.endsWith('/dark')) blocks[k] = { ...blocks[k.replace('/dark', '/light')], ...blocks[k] }

const PAIRS = [
  // [foreground, backgrounds, minimum, what]
  ['text', ['bg', 'surface', 'surface-2'], 4.5, 'body text'],
  ['muted', ['bg', 'surface', 'surface-2'], 4.5, 'secondary text'],
  ['primary-ink', ['primary'], 4.5, 'text on a primary button'],
  ['accent', ['bg', 'surface'], 4.5, 'accent text'],
  ['success', ['bg', 'surface'], 4.5, 'success text'],
  ['danger', ['bg', 'surface'], 4.5, 'danger text'],
  ['ring', ['bg', 'surface'], 3, 'focus ring'],
  ['field', ['bg', 'surface'], 3, 'form field border'],
]
let checked = 0
const themes = Object.keys(blocks).sort()
for (const theme of themes) {
  const t = blocks[theme]
  for (const [fg, bgs, min, what] of PAIRS) {
    for (const bg of bgs) {
      if (!t[fg] || !t[bg]) { console.log(`MISSING TOKEN: ${theme} has no --lx-${t[fg] ? bg : fg}`); fail++; continue }
      const r = ratio(t[fg], t[bg]); checked++
      if (r < min) { console.log(`BELOW AA: ${theme} ${what}: --lx-${fg} ${t[fg]} on --lx-${bg} ${t[bg]} is ${r.toFixed(2)}:1, needs ${min}:1`); fail++ }
    }
  }
}
console.log(`count: themes read = ${themes.length}`)
console.log(`count: token pairs checked = ${checked}`)
if (themes.length !== 4) { console.log(`FAILED: expected two properties in two modes, read ${themes.length}`); fail++ }
if (checked === 0) { console.log('FAILED: nothing was checked'); fail++ }
if (fail) { console.log(`CONTRAST FAILED: ${fail} finding(s)`); process.exit(1) }
console.log('CONTRAST GREEN')
