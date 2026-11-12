import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { EARLY_MAX_AGE_MS, earlyKey, earlyStore, putEarly, takeEarly, type EarlyStore } from './early'
import { firstPhotoSrc } from '../lib/photoSrc'
import { photosFor } from './photos'
import credits from '../../public/media/credits.json'
import type { QueryReply } from './wire'

const ok = (rows: unknown[]): QueryReply => ({ status: 'success', reply: JSON.stringify(rows) })

describe('the early store', () => {
  it('gives a kept reply once, for the same key only', async () => {
    const store: EarlyStore = new Map()
    putEarly(store, earlyKey(7, 'searchView', 'aa'), Promise.resolve(ok([1])), 1_000)
    expect(takeEarly(store, earlyKey(7, 'searchView', 'ab'), 1_001)).toBeNull()
    expect(takeEarly(store, earlyKey(8, 'searchView', 'aa'), 1_001)).toBeNull()
    expect(takeEarly(store, earlyKey(7, 'plansView', 'aa'), 1_001)).toBeNull()
    const first = takeEarly(store, earlyKey(7, 'searchView', 'aa'), 1_002)
    expect(await first).toEqual(ok([1]))
    expect(takeEarly(store, earlyKey(7, 'searchView', 'aa'), 1_003)).toBeNull()
  })

  it('never gives a reply older than the window, and drops it', () => {
    const store: EarlyStore = new Map()
    const key = earlyKey(7, 'roomTypesView', '')
    putEarly(store, key, Promise.resolve(ok([])), 0)
    expect(takeEarly(store, key, EARLY_MAX_AGE_MS + 1)).toBeNull()
    expect(store.size).toBe(0)
  })

  it('preloads the photograph the page shows first, for every slot', () => {
    for (const slot of new Set((credits as { slot: string }[]).map((c) => c.slot))) {
      expect(firstPhotoSrc(slot)).toBe(photosFor(slot)[0].src)
    }
  })
})

// The chain source against a stand-in boundary and gateway: replies are JSON rows, arguments JSON bytes.
describe('a read after this browser has written', () => {
  const fetches: string[] = []
  beforeEach(() => {
    const enc = (v: unknown) => new TextEncoder().encode(JSON.stringify(v, (_, x) => (typeof x === 'bigint' ? x.toString() : x)))
    const w = globalThis as unknown as Record<string, unknown>
    w.window = globalThis
    w.EgyptBoundary = {
      encodeArgs: enc,
      bytesToHex: (b: Uint8Array) => Array.from(b, (x) => x.toString(16).padStart(2, '0')).join(''),
      decodeVecRecord: (reply: string) => JSON.parse(reply),
      identity: () => 'ab'.repeat(28),
      signCall: async () => ({ sender: 'cd'.repeat(32), nonce: 1, signature: 'ef'.repeat(64) }),
    }
    let searches = 0
    vi.stubGlobal('fetch', async (url: string, init?: { body?: string }) => {
      const body = init?.body ? JSON.parse(init.body) : {}
      fetches.push(body.method ?? url)
      const json = (x: unknown) => ({ json: async () => x })
      if (url.endsWith('/api/call')) return json({ message_hash: 'h' })
      if (url.includes('/api/receipt')) return json({ status: 'success', reply: JSON.stringify([{ ok: true, block: 50 }]) })
      if (body.method === 'searchView') { searches += 1; return json(ok([{ roomTypeId: 1, ok: false, kind: 'soldOut', reason: 'x', atBlock: 55, n: searches }])) }
      return json(ok([]))
    })
  })
  afterEach(() => { vi.unstubAllGlobals(); fetches.length = 0; earlyStore().clear(); delete (globalThis as { __luxorEarlyClosed?: boolean }).__luxorEarlyClosed })

  it('closes the store on the app\'s first query, so a late early script does not ask again', async () => {
    const { chainApi } = await import('./chain')
    const { earlyOpen } = await import('./early')
    expect(earlyOpen()).toBe(true)
    await chainApi('almar', { luxorCid: 7, gatewayCid: 8, base: '', tenant: 'almar', mailRelay: '' }).plans()
    expect(earlyOpen()).toBe(false)
  })

  it('passes over a kept reply from before the write and reads again', async () => {
    const { chainApi } = await import('./chain')
    const { queryBody } = await import('./wire')
    const { searchArgs } = await import('./views')
    const api = chainApi('almar', { luxorCid: 7, gatewayCid: 8, base: '', tenant: 'almar', mailRelay: '' })
    const req = { arrival: 20_800, nights: 2, rooms: 1, adults: 2, children: 0 }
    await api.leaveWaitlist('', 3)                                   // this browser's write lands at block 50
    const arg = queryBody(7, 'searchView', searchArgs(req)).arg
    putEarly(earlyStore(), earlyKey(7, 'searchView', arg), Promise.resolve(ok([{ roomTypeId: 1, ok: true, total: 1, atBlock: 40 }])), Date.now())
    const res = await api.search(req)
    expect(res.offers).toHaveLength(0)                                // the kept reply (an offer, block 40) was not used
    expect(fetches.filter((m) => m === 'searchView')).toHaveLength(1) // it was read once more, at block 55
  })

  it('uses a kept reply when nothing has been written', async () => {
    const { chainApi } = await import('./chain')
    const { queryBody } = await import('./wire')
    const api = chainApi('almar', { luxorCid: 7, gatewayCid: 8, base: '', tenant: 'almar', mailRelay: '' })
    const arg = queryBody(7, 'plansView', []).arg
    putEarly(earlyStore(), earlyKey(7, 'plansView', arg), Promise.resolve(ok([{ id: 1, code: 'FLEX', nameEn: 'Flexible', nameAr: 'مرن', refundable: true,
      freeCancelDaysBefore: 3, penaltyNights: 1, prepaid: false, discountBps: 0, active: true }])), Date.now())
    const plans = await api.plans()
    expect(plans.map((p) => p.code)).toEqual(['FLEX'])
    expect(fetches).not.toContain('plansView')
  })
})
