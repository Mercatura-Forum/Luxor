import { useRef, useState } from 'react'
import { ChevronLeft, ChevronRight } from 'lucide-react'
import { useApp } from '../app'
import type { Photo } from '../api/types'
import { Img } from './Img'

/**
 * A room's photographs in a card: swipe on a phone, arrows on a wide screen, a position counter
 * for everyone. Scroll-snap does the motion, so there is no animation code to disagree with the
 * reader's reduced-motion setting. The first photograph is the only one that loads eagerly.
 */
export function Carousel({ photos, sizes, className = '', rounded = 'rounded-lg', aspect = 'aspect-[4/3]', priority = false }: { photos: Photo[]; sizes: string; className?: string; rounded?: string; aspect?: string; priority?: boolean }) {
  const { t, dir, locale } = useApp()
  const track = useRef<HTMLDivElement>(null)
  const [i, setI] = useState(0)
  const f = new Intl.NumberFormat(locale)
  const go = (k: number) => {
    const el = track.current
    if (!el) return
    const next = Math.max(0, Math.min(photos.length - 1, k))
    el.scrollTo({ left: (dir === 'rtl' ? -1 : 1) * next * el.clientWidth, behavior: 'smooth' })
  }
  if (photos.length === 0) return <div className={`${aspect} ${rounded} bg-surface-2 ${className}`} />
  return (
    <div className={`group relative overflow-hidden ${rounded} ${className}`}>
      <div
        ref={track}
        className={`flex snap-x snap-mandatory overflow-x-auto ${aspect} [scrollbar-width:none] [&::-webkit-scrollbar]:hidden`}
        onScroll={(e) => { const el = e.currentTarget; setI(Math.round(Math.abs(el.scrollLeft) / el.clientWidth)) }}
        aria-roledescription="carousel"
      >
        {photos.map((p, k) => (
          <div key={p.src} className="h-full w-full shrink-0 snap-start" aria-label={t('room.photo', { i: f.format(k + 1), n: f.format(photos.length) })} role="group">
            <Img photo={p} sizes={sizes} priority={priority && k === 0} className="h-full w-full object-cover" />
          </div>
        ))}
      </div>
      {photos.length > 1 && (
        <>
          <button type="button" onClick={() => go(i - 1)} disabled={i === 0} aria-label={t('picker.prev')}
            className="absolute start-3 top-1/2 hidden h-9 w-9 -translate-y-1/2 place-items-center rounded-full bg-surface/90 text-ink shadow-1 transition disabled:opacity-0 group-hover:grid">
            <ChevronLeft className="h-4 w-4 rtl:rotate-180" aria-hidden />
          </button>
          <button type="button" onClick={() => go(i + 1)} disabled={i === photos.length - 1} aria-label={t('picker.next')}
            className="absolute end-3 top-1/2 hidden h-9 w-9 -translate-y-1/2 place-items-center rounded-full bg-surface/90 text-ink shadow-1 transition disabled:opacity-0 group-hover:grid">
            <ChevronRight className="h-4 w-4 rtl:rotate-180" aria-hidden />
          </button>
          <span className="absolute bottom-3 end-3 rounded-full bg-black/55 px-2.5 py-1 text-xs font-semibold text-white nums" dir="ltr">{f.format(i + 1)} / {f.format(photos.length)}</span>
        </>
      )}
    </div>
  )
}
