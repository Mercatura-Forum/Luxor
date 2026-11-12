/**
 * The price of a stay, computed the way the contract computes it (src/Quote.mo): exact integers,
 * half-even rounding applied once per stored figure, per-night lines and tax shares by largest
 * remainder so every set of parts sums to its total. The demo data source prices with this; the
 * chain data source reads the contract's own figures and never uses it.
 */
export type TaxKind = 'percent' | 'perRoomNight' | 'perStay'
export type TaxBase = 'room' | 'roomAndPriorTaxes'

export interface TaxRule {
  id: number
  code: string
  name: { en: string; ar: string }
  kind: TaxKind
  bps: number
  amount: bigint
  base: TaxBase
  rank: number
}

export interface PlanPricing {
  kind: 'bar' | 'discountOffBar'
  discountBps: number
}

export interface TaxLine {
  ruleId: number
  amount: bigint
  perNight: bigint[]
}

/** A package's inclusion as a quote prices it: its extra's catalogue price now, how many of it a night
 *  (the inclusion's quantity times the rooms, adults or guests), when it is given, and whether it is taxed. */
export interface IncInput { slot: number; extraId: number; unit: bigint; quantity: number; rhythm: 'everyNight' | 'arrivalNight'; taxed: boolean }

/** One inclusion on one night: `net` is quantity × unit, `taxes` the hotel's percentage taxes on it. */
export interface IncLine { slot: number; extraId: number; night: number; quantity: number; unit: bigint; net: bigint; taxes: { ruleId: number; amount: bigint }[] }

export interface Quote {
  arrival: number
  nights: number
  rooms: number
  nightly: bigint[]
  roomSubtotal: bigint
  taxes: TaxLine[]
  taxTotal: bigint
  /** A package's lines (empty for a plain rate) and what they come to with their taxes: part of `total`,
   *  never of the room's subtotal, its taxes, its guarantee or its penalty. */
  inclusions: IncLine[]
  packageTotal: bigint
  total: bigint
}

const ONE = 10_000n

export function divHalfEven(n: bigint, d: bigint): bigint {
  const q = n / d
  const r = n % d
  if (r * 2n < d) return q
  if (r * 2n > d) return q + 1n
  return q % 2n === 0n ? q : q + 1n
}

export function exactRate(bar: bigint, plan: PlanPricing): bigint {
  return plan.kind === 'bar' ? bar * ONE : bar * (ONE - BigInt(Math.min(plan.discountBps, 10_000)))
}

export function displayRate(bar: bigint, plan: PlanPricing): bigint {
  return divHalfEven(exactRate(bar, plan), ONE)
}

/** The kernel's largest-remainder allocation: parts sum exactly to `total`, ties by order. */
export function allocate(total: bigint, weights: bigint[]): bigint[] {
  const sum = weights.reduce((a, b) => a + b, 0n)
  if (weights.length === 0 || sum === 0n) return weights.map(() => 0n)
  const out = weights.map((w) => (total * w) / sum)
  let remaining = total - out.reduce((a, b) => a + b, 0n)
  const rem = weights.map((w) => (total * w) % sum)
  const taken = weights.map(() => false)
  while (remaining > 0n) {
    let best = -1
    for (let i = 0; i < weights.length; i++) if (!taken[i] && (best < 0 || rem[i] > rem[best])) best = i
    if (best < 0) { out[0] += remaining; break }
    out[best] += 1n
    taken[best] = true
    remaining -= 1n
  }
  return out
}

export function price(plan: PlanPricing, arrival: number, bars: bigint[], rooms: number, taxes: TaxRule[]): Quote {
  const n = bars.length
  const q = BigInt(rooms)
  const weights = bars.map((b) => exactRate(b, plan) * q)
  const exact = weights.reduce((a, b) => a + b, 0n)
  const roomSubtotal = divHalfEven(exact, ONE)
  const nightly = allocate(roomSubtotal, weights)
  const lines: TaxLine[] = []
  let taxTotal = 0n
  for (const t of [...taxes].sort((a, b) => a.rank - b.rank || a.id - b.id)) {
    let amount: bigint
    if (t.kind === 'percent') {
      const base = t.base === 'room' ? roomSubtotal : roomSubtotal + taxTotal
      amount = divHalfEven(base * BigInt(t.bps), ONE)
    } else if (t.kind === 'perRoomNight') {
      amount = t.amount * q * BigInt(n)
    } else {
      amount = t.amount
    }
    lines.push({ ruleId: t.id, amount, perNight: allocate(amount, nightly) })
    taxTotal += amount
  }
  return { arrival, nights: n, rooms, nightly, roomSubtotal, taxes: lines, taxTotal, inclusions: [], packageTotal: 0n, total: roomSubtotal + taxTotal }
}

/** A quote with a package's inclusions added (the contract's Quote.withPackage): one line per inclusion
 *  per night it is given, every night or only on the stay's arrival night, taxed by the extra's own flag.
 *  The room's lines are as they were; the total grows by the package. */
export function withPackage(q: Quote, incs: IncInput[], taxes: TaxRule[], stayArrival: number): Quote {
  if (incs.length === 0) return q
  const inclusions: IncLine[] = []
  let packageTotal = 0n
  for (let i = 0; i < q.nights; i++) {
    const night = q.arrival + i
    for (const inc of incs) {
      if (inc.rhythm !== 'everyNight' && night !== stayArrival) continue
      const net = inc.unit * BigInt(inc.quantity)
      const tx = inc.taxed ? taxesOn(net, taxes) : []
      inclusions.push({ slot: inc.slot, extraId: inc.extraId, night, quantity: inc.quantity, unit: inc.unit, net, taxes: tx })
      packageTotal += tx.reduce((a, x) => a + x.amount, net)
    }
  }
  return { ...q, inclusions, packageTotal, total: q.roomSubtotal + q.taxTotal + packageTotal }
}

/** The hotel's percentage taxes on an extra, in rank order, compound as for the room, each above zero
 *  (the contract's Bill.taxesOn). */
export function taxesOn(net: bigint, taxes: TaxRule[]): { ruleId: number; amount: bigint }[] {
  const out: { ruleId: number; amount: bigint }[] = []
  let prior = 0n
  for (const t of [...taxes].sort((a, b) => a.rank - b.rank || a.id - b.id)) {
    if (t.kind !== 'percent') continue
    const amount = divHalfEven((t.base === 'room' ? net : net + prior) * BigInt(t.bps), ONE)
    if (amount > 0n) { out.push({ ruleId: t.id, amount }); prior += amount }
  }
  return out
}

/** What the first `k` nights cost with their share of every tax: the penalty and the guarantee. */
export function firstNights(q: Quote, k: number): bigint {
  let s = 0n
  for (let i = 0; i < Math.min(k, q.nights); i++) {
    s += q.nightly[i]
    for (const t of q.taxes) s += t.perNight[i]
  }
  return s
}

/** A deposit: `bps` of the room's stay with its taxes (no package), rounded half to even, as the contract takes it. */
export function depositOf(q: Pick<Quote, 'roomSubtotal' | 'taxTotal'>, bps: number): bigint {
  return halfEven((q.roomSubtotal + q.taxTotal) * BigInt(bps), 10_000n)
}

/** n / d rounded to the nearest whole, a tie to the even one. */
export function halfEven(n: bigint, d: bigint): bigint {
  const q = n / d, r = n % d
  if (r * 2n > d || (r * 2n === d && q % 2n === 1n)) return q + 1n
  return q
}

/** A stable fingerprint of what the guest was shown, compared again when the room is held. */
export async function quoteHash(roomTypeId: number, planId: number, q: Quote): Promise<string> {
  const parts = [roomTypeId, planId, q.arrival, q.rooms, q.nightly.join(','), q.taxes.map((t) => `${t.ruleId}:${t.amount}`).join(','), q.total]
  // a plain rate's hash is what it always was; a package's also covers each inclusion line
  if (q.inclusions.length) parts.push(q.inclusions.map((l) => `${l.slot}:${l.extraId}:${l.night}:${l.quantity}:${l.unit}:${l.taxes.map((x) => `${x.ruleId}=${x.amount}`).join('+')}`).join(','))
  const text = parts.join('|')
  const bytes = new TextEncoder().encode('LUXOR-QUOTE-v1|' + text)
  const digest = await crypto.subtle.digest('SHA-256', bytes)
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('')
}
