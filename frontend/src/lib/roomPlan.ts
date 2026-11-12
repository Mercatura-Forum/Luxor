import type { BoardRoom } from '../api/types'
import type { Day } from './days'

/** A stretch of a room's nights on the room plan: a guest in it, out of order, or free. [from, to) */
export type Piece = { kind: 'guest'; from: Day; to: Day; bookingId: number; name: string } | { kind: 'out'; from: Day; to: Day; reason: string } | { kind: 'free'; from: Day; to: Day }

/** A room's nights in [start, end) cut into pieces: a guest, out of order, or free. */
export function piecesOf(r: BoardRoom, start: Day, end: Day, names: Map<number, string>): Piece[] {
  const marks: Piece[] = []
  if (r.occupiedBy !== 0 && r.departure !== null && r.departure > start) {
    marks.push({ kind: 'guest', from: start, to: Math.min(r.departure, end), bookingId: r.occupiedBy, name: names.get(r.occupiedBy) ?? '' })
  }
  if (r.outOfOrder || r.outFrom !== null) {
    const from = Math.max(r.outFrom ?? start, start)
    const to = Math.min(r.outUntil ?? end, end)
    if (to > from) marks.push({ kind: 'out', from, to, reason: r.outReason })
  }
  marks.sort((a, b) => a.from - b.from)
  const out: Piece[] = []
  let at = start
  for (const m of marks) {
    const from = Math.max(m.from, at)
    if (from >= m.to) continue
    if (from > at) out.push({ kind: 'free', from: at, to: from })
    out.push({ ...m, from })
    at = m.to
  }
  if (at < end) out.push({ kind: 'free', from: at, to: end })
  return out
}
