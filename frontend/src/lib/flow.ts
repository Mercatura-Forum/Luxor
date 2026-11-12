/**
 * The booking in progress: the stay, the chosen room and rate, the hold, the guest, and the result.
 * Kept in sessionStorage so a reload keeps the guest where they were, and cleared once the booking
 * is confirmed. Amounts stay bigints; they are written as strings with an `n` suffix.
 */
import { useSyncExternalStore } from 'react'
import type { ConfirmResult, GuestDetails, HoldView, Offer, StayRequest } from '../api/types'

export interface Flow {
  stay?: StayRequest
  offer?: Offer
  hold?: HoldView
  guest?: GuestDetails
  done?: ConfirmResult
}

const KEY = 'luxor:flow'
const listeners = new Set<() => void>()

function revive(_k: string, v: unknown) { return typeof v === 'string' && /^-?\d+n$/.test(v) ? BigInt(v.slice(0, -1)) : v }
function replace(_k: string, v: unknown) { return typeof v === 'bigint' ? `${v}n` : v }

let current: Flow = (() => {
  try { return JSON.parse(sessionStorage.getItem(KEY) ?? '{}', revive) as Flow } catch { return {} }
})()

export function setFlow(patch: Partial<Flow> | ((f: Flow) => Flow)) {
  current = typeof patch === 'function' ? patch(current) : { ...current, ...patch }
  try { sessionStorage.setItem(KEY, JSON.stringify(current, replace)) } catch { /* storage blocked: memory only */ }
  for (const l of listeners) l()
}

export function useFlow(): Flow {
  return useSyncExternalStore((l) => { listeners.add(l); return () => listeners.delete(l) }, () => current)
}
