import { useEffect, useMemo, useState } from 'react'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom'
import { ArrowLeft, Check } from 'lucide-react'
import { toast } from '../lib/toast'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import { stayFromQuery, stayQuery } from '../lib/stay'
import { setFlow, useFlow } from '../lib/flow'
import { amenityLabel } from '../theme/tenants'
import { Refused, type Offer, type PlanView, type RoomTypeView } from '../api/types'
import { Carousel } from '../components/Carousel'
import { Steps } from '../components/Steps'
import { Summary } from '../components/Summary'
import { policyText } from '../components/policy'

export default function RoomPage() {
  const { id } = useParams()
  const rtId = Number(id)
  const [q, setQ] = useSearchParams()
  const stay = useMemo(() => stayFromQuery(q), [q])
  const { api, t, tr } = useApp()
  const { money, num, day } = useFormat()
  const nav = useNavigate()
  const flow = useFlow()
  const [room, setRoom] = useState<RoomTypeView | null>(null)
  const [plans, setPlans] = useState<PlanView[]>([])
  const [offers, setOffers] = useState<Offer[] | null>(null)
  const [busy, setBusy] = useState(false)
  const planId = Number(q.get('plan')) || flow.offer?.planId || 1

  useEffect(() => {
    let live = true
    Promise.all([api.roomTypes(), api.plans(stay.code), api.search(stay)]).then(([r, p, s]) => {
      if (!live) return
      setRoom(r.find((x) => x.id === rtId) ?? null)
      setPlans(p)
      setOffers(s.offers.filter((o) => o.roomTypeId === rtId))
    }).catch((e) => { if (live) { toast.error(e instanceof Refused ? tr(e.reason) : t('err.generic')); setOffers([]) } })
    return () => { live = false }
  }, [api, stay, rtId, t, tr])

  const offer = offers?.find((o) => o.planId === planId) ?? offers?.[0]
  const plan = plans.find((p) => p.id === offer?.planId)

  const reserve = async () => {
    if (!offer) return
    setBusy(true)
    try {
      if (flow.hold) await api.releaseHold(flow.hold.holdId)
      const hold = await api.placeHold(offer.roomTypeId, offer.planId, stay, offer.quoteHash)
      setFlow({ stay, offer, hold, done: undefined })
      nav('/book/details')
    } catch (e) {
      toast.error(e instanceof Refused ? tr(e.reason) : t('err.generic'))
      if (e instanceof Refused && e.kind === 'priceChanged') setOffers(null)
    } finally {
      setBusy(false)
    }
  }

  if (offers && !room) return <div className="mx-auto max-w-[1240px] px-5 pt-16"><p>{t('nf.title')}</p></div>

  return (
    <div className="mx-auto max-w-[1240px] px-4 pb-32 pt-6 sm:px-8">
      <Link to={`/rooms?${stayQuery(stay)}`} className="inline-flex items-center gap-1.5 t-small font-semibold text-ink no-underline hover:underline">
        <ArrowLeft className="h-4 w-4 rtl:rotate-180" aria-hidden />{t('room.back')}
      </Link>
      <div className="mt-4"><Steps at={0} /></div>

      <div className="mt-6 grid gap-10 lg:grid-cols-[minmax(0,1fr)_340px]">
        <div className="min-w-0">
          {room ? <Carousel photos={room.photos} sizes="(min-width: 1024px) 800px, 100vw" aspect="aspect-[16/10]" /> : <div className="skeleton aspect-[16/10] rounded-lg" />}
          {room && room.photos[0] && <p className="t-small mt-2 text-muted">{t('room.credit', { name: room.photos.map((p) => p.credit).filter((c, i, a) => a.indexOf(c) === i).join(', ') })}</p>}

          <h1 className="t-h1 mt-8 text-ink">{room ? tr(room.name) : ' '}</h1>
          {room && (
            <>
              <p className="mt-2 text-muted nums">{t('results.size', { n: num(room.sizeSqm) })} · {t('results.sleeps', { n: num(room.maxOccupancy) })} · {tr(room.view)}</p>
              <p className="t-body mt-5 max-w-2xl text-ink">{tr(room.desc)}</p>
              <h2 className="t-eyebrow mt-10 text-muted">{t('room.amenities')}</h2>
              <ul className="mt-4 grid gap-x-8 gap-y-3 sm:grid-cols-2">
                {room.amenities.map((a) => (
                  <li key={a} className="flex items-center gap-3 text-ink"><Check className="h-4 w-4 text-accent" aria-hidden />{tr(amenityLabel(a))}</li>
                ))}
              </ul>
            </>
          )}

          <h2 className="t-eyebrow mt-12 text-muted">{t('room.policy')}</h2>
          <fieldset className="mt-4 space-y-3">
            <legend className="sr-only">{t('room.policy')}</legend>
            {offers === null && <div className="skeleton h-24 rounded-lg" aria-hidden />}
            {offers?.map((o) => {
              const p = plans.find((x) => x.id === o.planId)
              if (!p) return null
              const on = o.planId === offer?.planId
              return (
                <label key={o.planId} className={`flex cursor-pointer items-start justify-between gap-4 rounded-lg border p-4 transition ${on ? 'border-ink bg-surface shadow-1' : 'border-line hover:border-muted'}`}>
                  <span className="flex items-start gap-3">
                    <input type="radio" name="plan" checked={on} onChange={() => { const n = new URLSearchParams(q); n.set('plan', String(o.planId)); setQ(n, { replace: true }) }} className="mt-1 accent-[var(--lx-primary)]" />
                    <span>
                      <span className="block font-semibold text-ink">{tr(p.name)}</span>
                      <span className="t-small block text-muted">{policyText(p, o, t, money, day)}</span>
                    </span>
                  </span>
                  <span className="shrink-0 font-display text-xl text-ink nums">{money(o.total)}</span>
                </label>
              )
            })}
          </fieldset>

          <button type="button" onClick={reserve} disabled={!offer || busy}
            className="mt-8 w-full rounded-base bg-primary px-6 py-4 text-lg font-semibold text-primary-ink transition hover:opacity-90 disabled:opacity-50 sm:w-auto">
            {offer ? t('room.reserve', { price: money(offer.total) }) : t('results.select')}
          </button>
        </div>

        <div>
          <Summary stay={stay} room={room ?? undefined} plan={plan} offer={offer} />
        </div>
      </div>
    </div>
  )
}
