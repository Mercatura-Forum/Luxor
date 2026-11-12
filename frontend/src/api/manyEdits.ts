/**
 * The edits of a many-night save, as the contract reads them (`Encoding.manyEdits`): a two-byte count,
 * then per edit the grid fields and an optional percentage. The kernel's canonical forms: a natural is
 * 0 alone or a byte count then big-endian bytes; an option is 0, or 1 and the value; a bool is 0 or 1.
 * The battery pins one vector both sides must write byte for byte.
 *
 * Attribution: Thebes Core Team. Licence: Apache 2.0.
 */
import type { ManyEdit } from './types'

function nat(out: number[], v: number | bigint) {
  let n = BigInt(v)
  if (n < 0n) throw new RangeError('a natural is not negative')
  if (n === 0n) { out.push(0); return }
  const bytes: number[] = []
  while (n > 0n) { bytes.unshift(Number(n & 0xffn)); n >>= 8n }
  out.push(bytes.length, ...bytes)
}
const optNat = (out: number[], v: number | bigint | undefined) => { if (v === undefined) out.push(0); else { out.push(1); nat(out, v) } }
const optBool = (out: number[], v: boolean | undefined) => { if (v === undefined) out.push(0); else out.push(1, v ? 1 : 0) }

export function manyEditsHex(edits: ManyEdit[]): string {
  if (edits.length > 0xffff) throw new RangeError('too many edits')
  const out: number[] = [edits.length >> 8, edits.length & 0xff]
  for (const { edit: e, adjust } of edits) {
    nat(out, e.roomTypeId); nat(out, e.fromDay); nat(out, e.toDay); nat(out, e.weekdays)
    optNat(out, e.allotment); optNat(out, e.bar); optNat(out, e.minStay); optNat(out, e.maxStay)
    optBool(out, e.closedToArrival); optBool(out, e.closedToDeparture); optBool(out, e.stopSell)
    if (adjust === undefined) out.push(0); else { out.push(1, adjust.up ? 1 : 0); nat(out, adjust.bps) }
  }
  return out.map((b) => b.toString(16).padStart(2, '0')).join('')
}

/** The rate after a percentage, as the contract computes it: exact, rounded half-even once. */
export function adjustedBar(bar: bigint, adjust: { up: boolean; bps: number }): bigint {
  const factor = BigInt(adjust.up ? 10_000 + adjust.bps : 10_000 - adjust.bps)
  const n = bar * factor, d = 10_000n
  const q = n / d, r = n % d
  if (r * 2n < d) return q
  if (r * 2n > d) return q + 1n
  return q % 2n === 0n ? q : q + 1n
}
