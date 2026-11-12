/**
 * The stay a guest is building, carried in the address (#/rooms?in=2026-10-21&n=3&a=2&c=0&r=1) so a
 * search can be shared, reloaded and gone back to. The gateway in front of the contract delivers the
 * path only, so everything lives after the hash, which never leaves the browser.
 */
import type { StayRequest } from '../api/types'
import { fromIso, iso, localToday } from './days'

export function defaultStay(): StayRequest {
  // two weeks out, three nights, two adults: a common first search
  return { arrival: localToday() + 14, nights: 3, rooms: 1, adults: 2, children: 0 }
}

export function stayFromQuery(q: URLSearchParams): StayRequest {
  const d = defaultStay()
  const arrival = fromIso(q.get('in') ?? '') ?? d.arrival
  const int = (k: string, lo: number, hi: number, fallback: number) => {
    const v = Number(q.get(k))
    return Number.isInteger(v) && v >= lo && v <= hi ? v : fallback
  }
  const code = rateCode(q.get('code') ?? '')
  return { arrival, nights: int('n', 1, 21, d.nights), adults: int('a', 1, 12, d.adults), children: int('c', 0, 8, d.children), rooms: int('r', 1, 4, d.rooms), ...(code ? { code } : {}) }
}

/** A rate code as the hotel keeps it: capitals, digits and dashes, at most 16; anything else is no code. */
export function rateCode(typed: string): string {
  const c = typed.trim().toUpperCase()
  return /^[A-Z0-9-]{1,16}$/.test(c) ? c : ''
}

export function stayQuery(s: StayRequest): string {
  const p = new URLSearchParams({ in: iso(s.arrival), n: String(s.nights), a: String(s.adults), c: String(s.children), r: String(s.rooms) })
  if (s.code) p.set('code', s.code)
  return p.toString()
}
