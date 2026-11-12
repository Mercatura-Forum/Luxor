import type { DayFiguresView } from '../api/types'

/** a / b, or 0 when there is nothing to divide by. */
export function ratio(a: number, b: number): number { return b > 0 ? a / b : 0 }

/**
 * A run of audited nights summed the way the industry sums them: occupancy is all the rooms sold over
 * all the rooms in service (not the average of each night's occupancy), ADR is all the room revenue
 * over all the rooms sold, RevPAR all the room revenue over all the rooms in service. Money stays in
 * minor units; a division rounds half up to the unit.
 */
export function periodOf(days: DayFiguresView[]): { sold: number; available: number; revenue: bigint; occupancy: number; adr: bigint; revpar: bigint } {
  let sold = 0
  let available = 0
  let revenue = 0n
  for (const f of days) { sold += f.roomsSold; available += Math.max(0, f.roomsTotal - f.roomsOut); revenue += f.roomRevenue }
  const div = (a: bigint, b: number) => (b > 0 ? (a * 2n + BigInt(b)) / (2n * BigInt(b)) : 0n)
  return { sold, available, revenue, occupancy: ratio(sold, available), adr: div(revenue, sold), revpar: div(revenue, available) }
}
