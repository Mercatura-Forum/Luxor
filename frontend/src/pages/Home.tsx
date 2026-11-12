import { useEffect, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import { defaultStay, stayQuery } from '../lib/stay'
import { photoFor } from '../api/photos'
import type { RoomTypeView } from '../api/types'
import { BookingBar } from '../components/BookingBar'
import { Img } from '../components/Img'
import { HomeHero } from './HomeHero'

/** A slow drift on the hero photograph, at most 40 px, and none at all under reduced motion. */
function useParallax(max = 40) {
  const [y, setY] = useState(0)
  useEffect(() => {
    if (matchMedia('(prefers-reduced-motion: reduce)').matches) return
    let raf = 0
    const on = () => { cancelAnimationFrame(raf); raf = requestAnimationFrame(() => setY(Math.min(max, window.scrollY * 0.12))) }
    window.addEventListener('scroll', on, { passive: true })
    return () => { window.removeEventListener('scroll', on); cancelAnimationFrame(raf) }
  }, [max])
  return y
}

export function Home() {
  const { tenant, tr, api, t, lang } = useApp()
  const { num } = useFormat()
  const drift = useParallax()
  const story = photoFor(tenant.story.slot)
  const [rooms, setRooms] = useState<RoomTypeView[] | null>(null)
  const stay = useRef(defaultStay()).current

  useEffect(() => { let live = true; api.roomTypes().then((r) => live && setRooms(r)); return () => { live = false } }, [api])

  return (
    <>
      <HomeHero tenant={tenant} lang={lang} drift={drift} />

      <div className="relative z-20 mx-auto -mt-16 max-w-[1100px] px-4 sm:-mt-20 sm:px-8">
        <BookingBar initial={stay} />
      </div>

      {/* three facts, set as a quiet band */}
      <section className="mx-auto mt-20 max-w-[1240px] px-5 sm:px-8" aria-label={tr(tenant.name)}>
        <ul className="grid gap-6 border-y border-line py-8 sm:grid-cols-3">
          {tenant.facts.map((f, i) => (
            <li key={i} className="flex items-baseline gap-4">
              <span className="font-display text-3xl text-accent nums" aria-hidden>{num(i + 1).padStart(2, num(0))}</span>
              <span className="text-lg text-ink">{tr(f)}</span>
            </li>
          ))}
        </ul>
      </section>

      {/* the house, in its own words */}
      <section className="mx-auto mt-20 grid max-w-[1240px] items-center gap-10 px-5 sm:px-8 md:grid-cols-[1.15fr_1fr]">
        {story && <Img photo={story} sizes="(min-width: 768px) 55vw, 100vw" className="aspect-[4/3] w-full rounded-lg object-cover shadow-1" />}
        <div className="max-w-md">
          <h2 className="t-h1 text-ink text-balance">{tr(tenant.story.title)}</h2>
          <p className="t-body mt-5 text-muted">{tr(tenant.story.body)}</p>
        </div>
      </section>

      {/* the rooms, as a strip to browse */}
      <section className="mx-auto mt-24 max-w-[1240px] px-5 sm:px-8">
        <div className="flex items-end justify-between gap-4">
          <h2 className="t-h1 text-ink">{t('nav.rooms')}</h2>
          <Link to={`/rooms?${stayQuery(stay)}`} className="font-semibold text-ink underline underline-offset-4">{t('bar.search')}</Link>
        </div>
        <ul className="mt-8 grid gap-6 sm:grid-cols-2 lg:grid-cols-3">
          {(rooms ?? Array.from({ length: 3 }, () => null)).map((r, i) => (
            <li key={r?.id ?? i}>
              {r ? (
                <Link to={`/rooms/${r.id}?${stayQuery(stay)}`} className="group block no-underline">
                  {r.photos[0] && <Img photo={r.photos[0]} sizes="(min-width: 1024px) 33vw, (min-width: 640px) 50vw, 100vw" className="aspect-[4/3] w-full rounded-lg object-cover transition duration-300 group-hover:opacity-90" />}
                  <p className="mt-3 font-display text-xl text-ink">{tr(r.name)}</p>
                  <p className="t-small text-muted nums">{t('results.size', { n: num(r.sizeSqm) })} · {tr(r.view)} · {t('results.sleeps', { n: num(r.maxOccupancy) })}</p>
                </Link>
              ) : (
                <div aria-hidden><div className="skeleton aspect-[4/3] rounded-lg" /><div className="skeleton mt-3 h-6 w-40 rounded-base" /></div>
              )}
            </li>
          ))}
        </ul>
      </section>
    </>
  )
}
