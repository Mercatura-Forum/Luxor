/**
 * Day numbers, as the contract keeps them: whole days since 1970-01-01. A day number is a calendar
 * date with no time zone attached, so it is formatted as a UTC date and never shifted.
 */
export type Day = number

const MS = 86_400_000

export function dayOf(y: number, m: number, d: number): Day {
  return Math.floor(Date.UTC(y, m - 1, d) / MS)
}

/** The visitor's own calendar date today, as a day number. */
export function localToday(): Day {
  const now = new Date()
  return dayOf(now.getFullYear(), now.getMonth() + 1, now.getDate())
}

export function toDate(day: Day): Date {
  return new Date(day * MS)
}

export function iso(day: Day): string {
  return toDate(day).toISOString().slice(0, 10)
}

export function fromIso(s: string): Day | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s)
  if (!m) return null
  return dayOf(Number(m[1]), Number(m[2]), Number(m[3]))
}

/** 0 = Monday … 6 = Sunday; 1970-01-01 was a Thursday. */
export function weekday(day: Day): number {
  return (day + 3) % 7
}

export function isWeekend(day: Day): boolean {
  const w = weekday(day)
  return w === 4 || w === 5
}

export function monthStart(day: Day): Day {
  const d = toDate(day)
  return dayOf(d.getUTCFullYear(), d.getUTCMonth() + 1, 1)
}

export function addMonths(day: Day, n: number): Day {
  const d = toDate(day)
  return dayOf(d.getUTCFullYear(), d.getUTCMonth() + 1 + n, 1)
}

export function daysInMonth(day: Day): number {
  const d = toDate(day)
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 0)).getUTCDate()
}
