import { describe, expect, it } from 'vitest'
import { cardsOf, slicesOf } from './refunds'

const cap = (id: number, auth: number, amount: bigint) => ({ id, kind: 'captured' as const, state: 'done' as const, amount, gatewayAuth: auth })
const ref = (id: number, auth: number, amount: bigint, state: 'due' | 'done' | 'failed') => ({ id, kind: 'refunded' as const, state, amount, gatewayAuth: auth })

describe('a refund across the guest\'s cards', () => {
  it('draws the newest card to nothing before an older one', () => {
    const cards = cardsOf([cap(1, 10, 14_000n), cap(2, 11, 3_000n), cap(3, 12, 1_000n)])
    expect(slicesOf(cards, 3_000n)).toEqual({ slices: [[12, 1_000n], [11, 2_000n]], rest: 0n })
  })
  it('passes over a card whose issuer refused a refund, and gives the refused amount back to nothing', () => {
    const cards = cardsOf([cap(1, 10, 14_000n), cap(2, 11, 3_000n), cap(3, 12, 1_000n), ref(4, 12, 1_000n, 'done'), ref(5, 11, 2_000n, 'failed')])
    expect(cards.find((c) => c.auth === 11)).toEqual({ auth: 11, left: 3_000n, newest: 2, refused: true })
    expect(slicesOf(cards, 1_000n)).toEqual({ slices: [[10, 1_000n]], rest: 0n })
  })
  it('sends to the desk only what no open card can take', () => {
    const cards = [{ auth: 1, left: 100n, newest: 5, refused: false }, { auth: 2, left: 500n, newest: 9, refused: true }, { auth: 4, left: 250n, newest: 7, refused: false }]
    expect(slicesOf(cards, 400n)).toEqual({ slices: [[4, 250n], [1, 100n]], rest: 50n })
    expect(slicesOf([], 70n)).toEqual({ slices: [], rest: 70n })
    expect(slicesOf(cards, 0n)).toEqual({ slices: [], rest: 0n })
  })
  it('counts a refund still on its way as given back', () => {
    expect(cardsOf([cap(1, 10, 500n), ref(2, 10, 200n, 'due')])).toEqual([{ auth: 10, left: 300n, newest: 1, refused: false }])
  })
})
