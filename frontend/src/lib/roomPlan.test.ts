import { describe, expect, it } from 'vitest'
import type { BoardRoom } from '../api/types'
import { piecesOf } from './roomPlan'

const room = (o: Partial<BoardRoom>): BoardRoom => ({
  id: 1, number: '101', roomTypeId: 1, outOfOrder: false, cleaning: '', cleanedBy: '', inspectedBy: '', cleanedByMe: false, inspectedByMe: false,
  outReason: '', outFrom: null, outUntil: null, changedDay: null, occupiedBy: 0, departure: null, ...o,
})
const names = new Map([[7, 'Mai']])
const shape = (r: BoardRoom) => piecesOf(r, 100, 114, names).map((p) => [p.kind, p.from, p.to])

describe('the room plan', () => {
  it('draws a free room as one free stretch over the whole span', () => {
    expect(shape(room({}))).toEqual([['free', 100, 114]])
  })
  it('draws a guest from the first night shown to the morning they leave, then free', () => {
    expect(shape(room({ occupiedBy: 7, departure: 103 }))).toEqual([['guest', 100, 103], ['free', 103, 114]])
    expect(piecesOf(room({ occupiedBy: 7, departure: 103 }), 100, 114, names)[0]).toMatchObject({ name: 'Mai', bookingId: 7 })
  })
  it('cuts a guest who stays past the span at its end', () => {
    expect(shape(room({ occupiedBy: 7, departure: 140 }))).toEqual([['guest', 100, 114]])
  })
  it('draws no guest on a room whose guest leaves on the first morning shown', () => {
    expect(shape(room({ occupiedBy: 7, departure: 100 }))).toEqual([['free', 100, 114]])
  })
  it('draws a dated out-of-order window, with free nights either side, and up to its first night back', () => {
    expect(shape(room({ outFrom: 104, outUntil: 107, outReason: 'paint' }))).toEqual([['free', 100, 104], ['out', 104, 107], ['free', 107, 114]])
  })
  it('draws a room out of order with no end date as out to the end of the span', () => {
    expect(shape(room({ outOfOrder: true, outFrom: 90 }))).toEqual([['out', 100, 114]])
  })
  it('never overlaps two stretches and always covers the span exactly', () => {
    for (const r of [room({ occupiedBy: 7, departure: 105, outFrom: 103, outUntil: 109 }), room({ outFrom: 120, outUntil: 125 }), room({ occupiedBy: 7, departure: 101, outOfOrder: true, outFrom: 101 })]) {
      const p = piecesOf(r, 100, 114, names)
      expect(p[0].from).toBe(100)
      expect(p[p.length - 1].to).toBe(114)
      for (let i = 1; i < p.length; i++) expect(p[i].from).toBe(p[i - 1].to)
      for (const x of p) expect(x.to).toBeGreaterThan(x.from)
    }
  })
})
