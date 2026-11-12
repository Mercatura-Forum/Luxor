/**
 * The time zones the console offers, each with the POSIX TZ rule the contract keeps (the footer of the
 * zone's own tzdata file, copied from the system zone files on 12 October 2026). The contract evaluates
 * the rule itself (kernel time/Zone.mo), so the rule is the whole of what it knows about the zone.
 *
 * A zone whose offset tzdata changes by table rather than by rule cannot be kept as a rule and is left
 * out: Africa/Casablanca's footer says +01 all year, but tzdata moves it to +00 for every Ramadan.
 * Any other zone can be entered as its rule under "Another zone".
 */
export const ZONES: [name: string, rule: string][] = [
  ['Africa/Cairo', 'EET-2EEST,M4.5.5/0,M10.5.4/24'],
  ['Asia/Riyadh', '<+03>-3'],
  ['Asia/Dubai', '<+04>-4'],
  ['Asia/Qatar', '<+03>-3'],
  ['Asia/Kuwait', '<+03>-3'],
  ['Asia/Amman', '<+03>-3'],
  ['Asia/Beirut', 'EET-2EEST,M3.5.0/0,M10.5.0/0'],
  ['Europe/Istanbul', '<+03>-3'],
  ['Europe/Athens', 'EET-2EEST,M3.5.0/3,M10.5.0/4'],
  ['Europe/Paris', 'CET-1CEST,M3.5.0,M10.5.0/3'],
  ['Europe/Berlin', 'CET-1CEST,M3.5.0,M10.5.0/3'],
  ['Europe/London', 'GMT0BST,M3.5.0/1,M10.5.0'],
  ['America/New_York', 'EST5EDT,M3.2.0,M11.1.0'],
  ['Asia/Tokyo', 'JST-9'],
  ['UTC', 'UTC0'],
]

export const DEFAULT_ZONE = ZONES[0]

/** The rule for a zone the list offers, or null. */
export function ruleOf(name: string): string | null {
  return ZONES.find(([n]) => n === name)?.[1] ?? null
}

/** Seconds after midnight from an <input type="time"> value ("03:00"), or null. */
export function secondsOf(hhmm: string): number | null {
  const m = /^(\d{2}):(\d{2})$/.exec(hhmm)
  if (!m) return null
  const h = Number(m[1]), mi = Number(m[2])
  return h < 24 && mi < 60 ? h * 3600 + mi * 60 : null
}

/** "03:00" from seconds after midnight. */
export function hhmmOf(seconds: number): string {
  const h = Math.floor(seconds / 3600), m = Math.floor((seconds % 3600) / 60)
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`
}
