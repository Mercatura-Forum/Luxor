import type { PaymentView } from '../api/types'

/** A guest's card as a refund sees it: what it can still give back, its newest capture, and whether its issuer has refused a refund. */
export interface CardState { auth: number; left: bigint; newest: number; refused: boolean }

/**
 * The guest's cards from the guest's own payments, as the contract reads them (src/Reservations.mo
 * guestCards): a card's captures that landed, less its refunds that were not refused; a card with a
 * refused refund is marked, and its refused refund gives nothing back.
 */
export function cardsOf(pays: Pick<PaymentView, 'id' | 'kind' | 'state' | 'amount' | 'gatewayAuth'>[]): CardState[] {
  const m = new Map<number, { cap: bigint; given: bigint; newest: number; refused: boolean }>()
  for (const p of pays) {
    if (p.gatewayAuth === 0) continue
    const c = m.get(p.gatewayAuth) ?? { cap: 0n, given: 0n, newest: 0, refused: false }
    if ((p.kind === 'captured' || p.kind === 'chargedOnFile') && p.state === 'done') { c.cap += p.amount; c.newest = Math.max(c.newest, p.id) }
    else if (p.kind === 'refunded' && p.state === 'failed') c.refused = true
    else if (p.kind === 'refunded') c.given += p.amount
    m.set(p.gatewayAuth, c)
  }
  return [...m].filter(([, c]) => c.cap > 0n).map(([auth, c]) => ({ auth, left: c.cap > c.given ? c.cap - c.given : 0n, newest: c.newest, refused: c.refused }))
}

/**
 * A refund of `back` split across the cards (src/Reservations.mo slices): newest first, each up to what
 * it can still give back, a card that refused a refund passed over. What no card can take is `rest`,
 * paid at the desk.
 */
export function slicesOf(cards: CardState[], back: bigint): { slices: [number, bigint][]; rest: bigint } {
  const slices: [number, bigint][] = []
  let rest = back
  for (const k of cards.filter((c) => !c.refused && c.left > 0n).sort((a, b) => b.newest - a.newest)) {
    if (rest === 0n) break
    const take = rest < k.left ? rest : k.left
    slices.push([k.auth, take]); rest -= take
  }
  return { slices, rest }
}
