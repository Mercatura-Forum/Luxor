/**
 * The demo's package pricing against the figures the contract's battery works out by hand
 * (test/Hotel.test.mo, "packages"): two nights at 100.00 with 10% VAT and a 2.20 tourist tax a room
 * night, breakfast for three guests every night, the transfer once a room and the spa once an adult on
 * the arrival night.
 */
import { describe, expect, it } from 'vitest'
import { firstNights, price, quoteHash, withPackage, type IncInput, type TaxRule } from './quote'

const taxes: TaxRule[] = [
  { id: 1, code: 'IVA', name: { en: 'VAT', ar: '' }, kind: 'percent', bps: 1_000, amount: 0n, base: 'room', rank: 1 },
  { id: 2, code: 'TOURIST', name: { en: 'Tourist tax', ar: '' }, kind: 'perRoomNight', bps: 0, amount: 220n, base: 'room', rank: 2 },
]
const ARRIVAL = 20_800
const room = price({ kind: 'bar', discountBps: 0 }, ARRIVAL, [10_000n, 10_000n], 1, taxes)
const incs: IncInput[] = [
  { slot: 1, extraId: 1, unit: 1_200n, quantity: 3, rhythm: 'everyNight', taxed: true },
  { slot: 2, extraId: 2, unit: 2_500n, quantity: 1, rhythm: 'arrivalNight', taxed: false },
  { slot: 3, extraId: 3, unit: 4_000n, quantity: 2, rhythm: 'arrivalNight', taxed: true },
]

describe('a package on the rate', () => {
  const q = withPackage(room, incs, taxes, ARRIVAL)
  it('prices the room as a plain rate and adds each inclusion on the nights it is given', () => {
    expect(room.total).toBe(22_440n)
    expect(q.roomSubtotal).toBe(20_000n)
    expect(q.taxTotal).toBe(2_440n)
    expect(q.inclusions.map((l) => [l.extraId, l.night - ARRIVAL, l.net, l.taxes.map((x) => x.amount)])).toEqual([
      [1, 0, 3_600n, [360n]], [2, 0, 2_500n, []], [3, 0, 8_000n, [800n]], [1, 1, 3_600n, [360n]],
    ])
    expect(q.packageTotal).toBe(19_220n)
    expect(q.total).toBe(41_660n)
  })
  it('keeps the guarantee to the room: the first night with its taxes, no breakfast', () => {
    expect(firstNights(q, 1)).toBe(11_220n)
  })
  it('leaves a plain rate unchanged, its hash included', async () => {
    expect(withPackage(room, [], taxes, ARRIVAL)).toBe(room)
    const text = [1, 1, room.arrival, room.rooms, room.nightly.join(','), room.taxes.map((t) => `${t.ruleId}:${t.amount}`).join(','), room.total].join('|')
    const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode('LUXOR-QUOTE-v1|' + text)))
    expect(await quoteHash(1, 1, room)).toBe([...digest].map((b) => b.toString(16).padStart(2, '0')).join(''))
  })
  it('gives a package another hash, and another again when an inclusion\'s price moves', async () => {
    const dearer = withPackage(room, incs.map((x) => (x.extraId === 1 ? { ...x, unit: 1_300n } : x)), taxes, ARRIVAL)
    expect(dearer.total).toBe(q.total + 2n * 330n)
    const hashes = new Set([await quoteHash(1, 1, room), await quoteHash(1, 1, q), await quoteHash(1, 1, dearer)])
    expect(hashes.size).toBe(3)
  })
})
