/**
 * Early data: the results page's queries are sent by a small script while the app's own script is still
 * downloading, and the replies are kept here for the app to pick up. A reply is taken once, only for the
 * same contract, method and argument bytes, and only while it is fresh; otherwise the app asks as usual.
 */
import type { QueryReply } from './wire'

/** From the page's first bytes to the app asking for the same data is well under this on a slow phone. */
export const EARLY_MAX_AGE_MS = 10_000

export type EarlyEntry = { at: number; reply: Promise<QueryReply> }
export type EarlyStore = Map<string, EarlyEntry>

export function earlyKey(cid: number, method: string, argHex: string): string {
  return `${cid}|${method}|${argHex}`
}

/** The page's one store, shared by the early script and the app through the window. */
export function earlyStore(): EarlyStore {
  const w = window as unknown as EarlyWindow
  return (w.__luxorEarly ??= new Map())
}

type EarlyWindow = { __luxorEarly?: EarlyStore; __luxorEarlyClosed?: boolean }

/** The app's first query closes the store: an early script that has not started by then does not start,
 *  so no query is sent twice. */
export function closeEarly(): void {
  (window as unknown as EarlyWindow).__luxorEarlyClosed = true
}

export function earlyOpen(): boolean {
  return !(window as unknown as EarlyWindow).__luxorEarlyClosed
}

export function putEarly(store: EarlyStore, key: string, reply: Promise<QueryReply>, now: number): void {
  store.set(key, { at: now, reply })
}

/** The kept reply for exactly this key, removed as it is taken; nothing when absent or too old. */
export function takeEarly(store: EarlyStore, key: string, now: number, maxAgeMs = EARLY_MAX_AGE_MS): Promise<QueryReply> | null {
  const e = store.get(key)
  if (!e) return null
  store.delete(key)
  return now - e.at <= maxAgeMs ? e.reply : null
}
