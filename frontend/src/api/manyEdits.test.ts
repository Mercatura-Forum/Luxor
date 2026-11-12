import { describe, expect, it } from 'vitest'
import { adjustedBar, manyEditsHex } from './manyEdits'

const F = 20_723 + 100

describe('the many-night edit list', () => {
  it('writes the vector the contract battery pins, byte for byte', () => {
    const hex = manyEditsHex([{ edit: { roomTypeId: 1, fromDay: F, toDay: F + 2, weekdays: 127 }, adjust: { up: true, bps: 750 } }])
    expect(hex).toBe('00010101025157025159017f0000000000000001010202ee')
  })
  it('writes every option that is set', () => {
    const hex = manyEditsHex([{ edit: { roomTypeId: 2, fromDay: 1, toDay: 2, weekdays: 1, allotment: 0, bar: 18_000n, minStay: 2, maxStay: 0,
      closedToArrival: true, closedToDeparture: false, stopSell: true } }])
    // count 1 · rt 2 · from 1 · to 2 · weekdays 1 · allotment 0 · bar 18,000 (0x4650) · min 2 · max 0 · cta yes · ctd no · stop yes · no percentage
    expect(hex).toBe('0001' + '0102' + '0101' + '0102' + '0101' + '0100' + '01024650' + '010102' + '0100' + '0101' + '0100' + '0101' + '00')
  })
})

describe('a percentage on the rate', () => {
  it('rounds half-even once, as the contract does', () => {
    expect(adjustedBar(88_000n, { up: true, bps: 1_000 })).toBe(96_800n)
    expect(adjustedBar(18_000n, { up: false, bps: 333 })).toBe(17_401n)
    expect(adjustedBar(25n, { up: true, bps: 100 })).toBe(25n)        // 25.25 → 25
    expect(adjustedBar(50n, { up: false, bps: 1_000 })).toBe(45n)
    expect(adjustedBar(5n, { up: false, bps: 1_000 })).toBe(4n)       // 4.5 → 4, the even neighbour
    expect(adjustedBar(7n, { up: false, bps: 5_000 })).toBe(4n)       // 3.5 → 4, the even neighbour
  })
})
