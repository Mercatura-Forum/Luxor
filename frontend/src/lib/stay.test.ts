import { describe, expect, it } from 'vitest'
import { rateCode, stayFromQuery, stayQuery } from './stay'

describe('a rate code in the address', () => {
  it('is kept in capitals, without the spaces around it', () => {
    expect(rateCode(' acme ')).toBe('ACME')
    expect(rateCode('nile-tours')).toBe('NILE-TOURS')
  })
  it('is no code when it is not letters, digits and dashes of at most 16', () => {
    expect(rateCode('AC ME')).toBe('')
    expect(rateCode('ACME!')).toBe('')
    expect(rateCode('ACME-TRADING-2026')).toBe('')
    expect(rateCode('')).toBe('')
  })
  it('travels with the stay and back', () => {
    const s = { arrival: 20_800, nights: 2, rooms: 1, adults: 2, children: 0, code: 'ACME' }
    expect(stayFromQuery(new URLSearchParams(stayQuery(s)))).toEqual(s)
    const plain = { arrival: 20_800, nights: 2, rooms: 1, adults: 2, children: 0 }
    expect(stayQuery(plain)).not.toContain('code')
    expect(stayFromQuery(new URLSearchParams(stayQuery(plain)))).toEqual(plain)
  })
  it('a malformed code in the address is dropped, not sent', () => {
    expect(stayFromQuery(new URLSearchParams('in=2026-12-01&n=2&a=2&c=0&r=1&code=%3Cscript%3E')).code).toBeUndefined()
  })
})
