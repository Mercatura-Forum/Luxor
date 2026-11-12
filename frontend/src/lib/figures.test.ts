import { describe, expect, it } from 'vitest'
import type { DayFiguresView } from '../api/types'
import { periodOf, ratio } from './figures'

const night = (o: Partial<DayFiguresView>): DayFiguresView => ({
  day: 1, roomsTotal: 10, roomsOut: 0, roomsSold: 0, roomRevenue: 0n, arrivals: 0, noShows: 0, pickupBookings: 0, pickupNights: 0, pickupRevenue: 0n, closed: true, ...o,
})

describe('the figures of a run of nights', () => {
  it('sums rooms before dividing, rather than averaging each night', () => {
    // 9 of 10 one night, 1 of 2 in service the next (8 out): 10 of 12 = 83.3 %, where the average of nights would be 70 %
    const p = periodOf([night({ roomsSold: 9, roomRevenue: 90_000n }), night({ roomsOut: 8, roomsSold: 1, roomRevenue: 20_000n })])
    expect(p.sold).toBe(10)
    expect(p.available).toBe(12)
    expect(p.occupancy).toBeCloseTo(10 / 12, 10)
    expect(p.adr).toBe(11_000n)
    expect(p.revpar).toBe(9_167n)   // 110 000 / 12 = 9 166.67, rounded half up to the unit
  })
  it('gives zero, not a division by zero, for nights with nothing sold or nothing in service', () => {
    const p = periodOf([night({ roomsOut: 10 })])
    expect(p).toEqual({ sold: 0, available: 0, revenue: 0n, occupancy: 0, adr: 0n, revpar: 0n })
    expect(ratio(3, 0)).toBe(0)
  })
  it('rounds a half unit up', () => {
    expect(periodOf([night({ roomsTotal: 2, roomsSold: 2, roomRevenue: 3n })]).adr).toBe(2n)
  })
})
