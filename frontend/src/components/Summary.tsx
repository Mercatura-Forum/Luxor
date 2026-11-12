import { useEffect, useState } from 'react'
import { ChevronUp } from 'lucide-react'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import type { Offer, PlanView, RoomTypeView, StayRequest } from '../api/types'
import { itemsText } from '../lib/package'

export function useCountdown(until?: number) {
  const [now, setNow] = useState(Date.now())
  useEffect(() => {
    if (!until) return
    const id = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(id)
  }, [until])
  if (!until) return null
  return Math.max(0, Math.floor((until - now) / 1000))
}

export function mmss(s: number, locale: string) {
  const f = new Intl.NumberFormat(locale, { minimumIntegerDigits: 2 })
  return `${f.format(Math.floor(s / 60))}:${f.format(s % 60)}`
}

/**
 * The booking summary that stays with the guest from the results to the payment: the dates, the
 * party, the room, the rate and the total, with the hold's time left once there is a hold. A right
 * rail on a wide screen; a bar at the foot of a phone that opens into the full breakdown.
 */
export function Summary({ stay, room, plan, offer, holdUntil }: { stay: StayRequest; room?: RoomTypeView; plan?: PlanView; offer?: Offer; holdUntil?: number }) {
  const { api, t, tr, locale } = useApp()
  const { money, day, num } = useFormat()
  // a package's items, named under the room's own lines: room, its taxes and the items make the total
  const [included, setIncluded] = useState<string | null>(null)
  const pkgPlan = offer && offer.packageTotal > 0n ? offer.planId : 0
  useEffect(() => {
    let live = true
    setIncluded(null)
    if (pkgPlan) api.packageOf(pkgPlan).then((x) => live && setIncluded(itemsText(x, tr, locale))).catch(() => { /* the line keeps its plain name */ })
    return () => { live = false }
  }, [api, pkgPlan, tr, locale])
  const [open, setOpen] = useState(false)
  const left = useCountdown(holdUntil)

  const holdLine = left === null ? null
    : left === 0 ? <p className="font-semibold text-danger" role="status">{t('summary.expired')}</p>
    : left < 120 ? <p className="font-semibold text-danger" aria-live="polite">{t('summary.holdSoon', { time: mmss(left, locale) })}</p>
    : <p className="text-muted nums" aria-live="off">{t('summary.held', { time: mmss(left, locale) })}</p>

  const body = (
    <div className="space-y-4">
      <div>
        <p className="t-eyebrow text-muted">{t('summary.title')}</p>
        <p className="mt-2 font-semibold text-ink"><bdi>{day(stay.arrival, 'weekday')}</bdi> → <bdi>{day(stay.arrival + stay.nights, 'weekday')}</bdi></p>
        <p className="t-small text-muted nums">{stay.nights === 1 ? t('bar.night') : t('bar.nights', { n: num(stay.nights) })} · {t('guests.summary', { a: num(stay.adults), c: num(stay.children), r: num(stay.rooms) })}</p>
      </div>
      {room && (
        <div className="border-t border-line pt-4">
          <p className="font-display text-lg text-ink">{tr(room.name)}</p>
          {plan && <p className="t-small text-muted">{tr(plan.name)}</p>}
        </div>
      )}
      {offer && (
        <dl className="space-y-1.5 border-t border-line pt-4 t-small nums">
          <div className="flex justify-between gap-4"><dt className="text-muted">{t('summary.room')}</dt><dd className="text-ink">{money(offer.roomSubtotal)}</dd></div>
          <div className="flex justify-between gap-4"><dt className="text-muted">{t('summary.taxes')}</dt><dd className="text-ink">{money(offer.taxTotal)}</dd></div>
          {offer.packageTotal > 0n && <div data-summary-package className="flex justify-between gap-4"><dt className="text-muted">{included ? t('summary.package', { items: included }) : t('results.packageTotal')}</dt><dd className="text-ink">{money(offer.packageTotal)}</dd></div>}
          <div className="flex justify-between gap-4 border-t border-line pt-2 text-base"><dt className="font-semibold text-ink">{t('summary.total')}</dt><dd className="font-semibold text-ink">{money(offer.total)}</dd></div>
        </dl>
      )}
      {holdLine && <div className="t-small">{holdLine}</div>}
    </div>
  )

  return (
    <>
      <aside className="sticky top-24 hidden rounded-lg border border-line bg-surface p-5 shadow-1 lg:block" aria-label={t('summary.title')}>{body}</aside>
      <div className="fixed inset-x-0 bottom-0 z-30 border-t border-line bg-surface/97 shadow-2 backdrop-blur lg:hidden" style={{ paddingBottom: 'env(safe-area-inset-bottom)' }}>
        {open && <div className="max-h-[60vh] overflow-y-auto border-b border-line px-5 py-4">{body}</div>}
        <button type="button" onClick={() => setOpen(!open)} aria-expanded={open} className="flex w-full items-center justify-between gap-4 px-5 py-3 text-start">
          <span>
            <span className="block t-small text-muted"><bdi>{day(stay.arrival)}</bdi> → <bdi>{day(stay.arrival + stay.nights)}</bdi>{left !== null && left > 0 ? ` · ${mmss(left, locale)}` : ''}</span>
            <span className="block font-semibold text-ink nums">{offer ? money(offer.total) : room ? tr(room.name) : t('summary.title')}</span>
          </span>
          <span className="flex items-center gap-1 t-small font-semibold text-ink">{open ? t('summary.hide') : t('summary.show')}<ChevronUp className={`h-4 w-4 transition ${open ? '' : 'rotate-180'}`} aria-hidden /></span>
        </button>
      </div>
    </>
  )
}
