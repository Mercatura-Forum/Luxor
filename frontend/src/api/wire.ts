/**
 * The wire to a Thebes gateway: Candid argument helpers, the SDK's boundary client, and the page's
 * chain configuration. Shared by the chain data source and the early-data script, so both encode a
 * query to the same bytes.
 */

export type Field = { name: string; type: 'nat' | 'int' | 'bool' | 'text' | 'principal' }
export type Arg = { type: string; value?: unknown; inner?: { type: string } }
export interface Boundary {
  encodeArgs(values: Arg[]): Uint8Array
  decodeVecRecord(reply: string | Uint8Array, fields: Field[]): Record<string, unknown>[]
  bytesToHex(b: Uint8Array): string
  identity(): string
  signCall(cid: number, method: string, argHex: string): Promise<{ sender: string; nonce: number; signature: string }>
}

export const nat = (v: number | bigint): Arg => ({ type: 'nat', value: BigInt(v) })
export const text = (v: string): Arg => ({ type: 'text', value: v })
export const bool = (v: boolean): Arg => ({ type: 'bool', value: v })
export const f = (name: string, type: Field['type'] = 'nat'): Field => ({ name, type })

export function boundary(): Boundary {
  const b = (window as unknown as { EgyptBoundary?: Boundary }).EgyptBoundary
  if (!b) throw new Error('boundary.js is not loaded')
  return b
}

/** `mailRelay`: the shared mail relay's https address ('' when this deployment has none: guest email cannot be connected). */
export interface ChainConfig { luxorCid: number; gatewayCid: number; base: string; tenant: string; mailRelay: string }

export function chainConfig(): ChainConfig | null {
  const w = window as unknown as { LUXOR_CID?: number; LUXOR_GATEWAY_CID?: number; LUXOR_API_BASE?: string; LUXOR_TENANT?: string; LUXOR_MAIL_RELAY?: string }
  const env = import.meta.env as Record<string, string | undefined>
  const luxorCid = Number(w.LUXOR_CID ?? env.VITE_LUXOR_CID ?? 0)
  const gatewayCid = Number(w.LUXOR_GATEWAY_CID ?? env.VITE_LUXOR_GATEWAY_CID ?? 0)
  if (!luxorCid || !gatewayCid) return null
  return { luxorCid, gatewayCid, base: w.LUXOR_API_BASE ?? '', tenant: w.LUXOR_TENANT ?? env.VITE_LUXOR_TENANT ?? 'almar',
    mailRelay: (w.LUXOR_MAIL_RELAY ?? env.VITE_LUXOR_MAIL_RELAY ?? '').replace(/\/+$/, '') }
}

export type QueryReply = { status?: string; reply?: string; error?: string }

/** A query's body; the argument's hex is also the key an early reply is kept under. */
export function queryBody(cid: number, method: string, args: Arg[]) {
  const b = boundary()
  return { canister_id: cid, method, arg: b.bytesToHex(b.encodeArgs(args)), sender: querySender(b) }
}

/** A query names this browser's principal (the caller its signed updates carry). On a first visit,
 *  before boundary.js has made the browser's key, it goes out anonymous: a new key has no data yet. */
function querySender(b: Boundary): string {
  try { return b.identity() } catch { return '' }
}

export function postQuery(base: string, body: ReturnType<typeof queryBody>): Promise<QueryReply> {
  return fetch(`${base}/api/query`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) }).then((x) => x.json())
}
