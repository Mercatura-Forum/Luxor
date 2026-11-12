import { describe, expect, it } from 'vitest'
import { parseMoney, toDecimalString } from './money'

describe('an amount typed at the desk', () => {
  it('reads two decimals with a point or a comma, and whole amounts', () => {
    expect(parseMoney('12.50', 2)).toBe(1250n)
    expect(parseMoney('12,5', 2)).toBe(1250n)
    expect(parseMoney(' 12 ', 2)).toBe(1200n)
    expect(parseMoney('0.05', 2)).toBe(5n)
  })
  it('refuses more decimals than the currency has, signs, and words', () => {
    expect(parseMoney('12.505', 2)).toBeNull()
    expect(parseMoney('-1', 2)).toBeNull()
    expect(parseMoney('12.1', 0)).toBeNull()
    expect(parseMoney('twelve', 2)).toBeNull()
    expect(parseMoney('', 2)).toBeNull()
  })
  it('reads a currency with no minor unit', () => {
    expect(parseMoney('12', 0)).toBe(12n)
  })
  it('round-trips what the screen prints', () => {
    for (const v of [0n, 5n, 1250n, 123456789n]) expect(parseMoney(toDecimalString(v, 2), 2)).toBe(v)
  })
})
