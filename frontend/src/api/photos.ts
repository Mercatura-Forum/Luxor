/** The photographs of a property, by slot, from the credits the fetch script wrote. */
import photoCredits from '../../public/media/credits.json'
import type { Photo } from './types'

type Credit = { slot: string; index: number; alt: string; width: number; height: number; lqip: string; photographer: string }

export function photosFor(slot: string): Photo[] {
  return (photoCredits as Credit[])
    .filter((c) => c.slot === slot)
    .sort((a, b) => a.index - b.index)
    .map((c) => ({ src: `media/${c.slot}-${c.index}`, alt: c.alt, width: c.width, height: c.height, lqip: c.lqip, credit: c.photographer }))
}

export function photoFor(slotIndex: string): Photo | undefined {
  const m = /^(.*)-(\d+)$/.exec(slotIndex)
  if (!m) return undefined
  return photosFor(m[1]).find((p) => p.src.endsWith(`-${m[2]}`))
}

/** Every photograph set the media credits hold, by slot name, in order: what a room type can show. */
export function photoSlots(): string[] {
  return [...new Set((photoCredits as Credit[]).map((c) => c.slot))].sort()
}
