import { useEffect, useMemo, useState } from 'react'
import { Link, useNavigate, useSearchParams } from 'react-router-dom'
import { BadgePercent, ChevronDown, Eye, Maximize2, Users, X } from 'lucide-react'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import { stayFromQuery, stayQuery } from '../lib/stay'
import { setFlow } from '../lib/flow'
import { useAccount } from '../lib/account'
import { toast } from '../lib/toast'
import { Refused } from '../api/types'
import type { CodeView, InclusionView, Offer, PlanView, QuoteDetail, RoomTypeView, SearchResult, StayRequest } from '../api/types'
import { inclusionText, itemsText } from '../lib/package'
import { BookingBar } from '../components/BookingBar'
import { Carousel } from '../components/Carousel'
import { RESULT_PHOTO_SIZES } from '../lib/photoSrc'

/** A package's lines for the breakdown: one row per item, its quantity over the stay and its amount with tax. */
function packageRows(d: QuoteDetail) {
  const rows: { extraId: number; name: QuoteDetail['package'][number]['name']; quantity: number; amount: bigint }[] = []
  for (const l of d.package) {
    const r = rows.find((x) => x.extraId === l.extraId)
    if (r) { r.quantity += l.quantity; r.amount += l.net + l.tax } else rows.push({ extraId: l.extraId, name: l.name, quantity: l.quantity, amount: l.net + l.tax })
  }
  return rows
}

function Breakdown({ offer, stay }: { offer: Offer; stay: StayRequest }) {
  const { api, t, tr } = useApp()
  const { money, day, num } = useFormat()
  const [d, setD] = useState<QuoteDetail | null>(null)
  useEffect(() => { let live = true; api.quoteDetail(offer.roomTypeId, offer.planId, stay).then((x) => live && setD(x)); return () => { live = false } }, [api, offer, stay])
  if (!d) return <div className="skeleton mt-3 h-24 rounded-base" aria-hidden />
  return (
    <table className="mt-3 w-full t-small nums">
      <tbody>
        {d.nights.map((n) => (
          <tr key={n.day} className="border-t border-line/70">
            <th scope="row" className="py-1.5 text-start font-normal text-muted">{day(n.day, 'weekday')}</th>
            <td className="py-1.5 text-end text-ink">{money(n.room)}</td>
          </tr>
        ))}
        {d.taxLines.map((x) => (
          <tr key={x.ruleId} className="border-t border-line/70">
            <th scope="row" className="py-1.5 text-start font-normal text-muted">{tr(x.name)}</th>
            <td className="py-1.5 text-end text-ink">{money(x.amount)}</td>
          </tr>
        ))}
        {packageRows(d).map((x) => (
          <tr key={x.extraId} data-package-line className="border-t border-line/70">
            <th scope="row" className="py-1.5 text-start font-normal text-muted">{t('results.pkgLine', { name: tr(x.name), n: num(x.quantity) })}</th>
            <td className="py-1.5 text-end text-ink">{money(x.amount)}</td>
          </tr>
        ))}
        <tr className="border-t border-line">
          <th scope="row" className="py-2 text-start font-semibold text-ink">{t('summary.total')}</th>
          <td className="py-2 text-end font-semibold text-ink">{money(d.total)}</td>
        </tr>
      </tbody>
    </table>
  )
}

function PlanRow({ offer, plan, stay, codeName, inclusions, onChoose }: { offer: Offer; plan: PlanView; stay: StayRequest; codeName?: string; inclusions?: InclusionView[]; onChoose(): void }) {
  const { t, tr, locale } = useApp()
  const included = offer.packageTotal > 0n && inclusions?.length ? inclusions : null
  const { money, day, num } = useFormat()
  const [open, setOpen] = useState(false)
  const policy = plan.refundable && offer.cancelDeadline !== null
    ? <span className="text-success">{t('results.freeCancel', { day: day(offer.cancelDeadline, 'weekday') })}</span>
    : <span className="text-muted">{t('results.nonRefundable')}</span>
  return (
    <div className="border-t border-line py-4">
      <div className="grid items-end gap-x-5 gap-y-3 sm:grid-cols-[minmax(0,1fr)_auto_auto]">
        <div className="min-w-0 self-start">
          <p className="font-semibold text-ink">{tr(plan.name)}</p>
          {codeName && <p data-coded-rate className="t-small mt-0.5 inline-flex items-center gap-1 font-semibold text-accent"><BadgePercent className="h-3.5 w-3.5" aria-hidden />{t('code.rateOf', { name: codeName })}</p>}
          {included && (
            <ul data-package className="t-small mt-0.5 text-ink">
              {included.map((x) => <li key={x.slot}>{inclusionText(x, t, tr, num)}</li>)}
            </ul>
          )}
          <p className="t-small mt-0.5">{policy}</p>
          {plan.refundable && <p className="t-small text-muted">{t('results.payAtHotel')}</p>}
        </div>
        <div className="text-end">
            <p className="font-display text-2xl leading-none text-ink nums">{money(offer.total)}</p>
            {included && <p data-package-price className="t-small mt-1 font-semibold text-ink">{t('results.withPackage', { items: itemsText(included, tr, locale) })}</p>}
            {/* a package's items carry their own tax inside their price: the room's tax figure alone would be short */}
            <p className="t-small mt-1 text-muted nums">{offer.packageTotal > 0n ? t('results.includesAll') : t('results.includes', { taxes: money(offer.taxTotal) })}</p>
            <p className="t-small text-muted nums">{t('results.perNight', { price: money(offer.perNightAvg) })}</p>
        </div>
          <button type="button" onClick={onChoose} className="rounded-base bg-primary px-5 py-3 font-semibold text-primary-ink transition hover:opacity-90">
            {t('results.select')}
          </button>
      </div>
      <button type="button" onClick={() => setOpen(!open)} aria-expanded={open} className="mt-2 flex items-center gap-1 t-small font-semibold text-ink underline underline-offset-4">
        {t('results.breakdown')}<ChevronDown className={`h-3.5 w-3.5 transition ${open ? 'rotate-180' : ''}`} aria-hidden />
      </button>
      {open && <Breakdown offer={offer} stay={stay} />}
      <span className="sr-only">{num(stay.nights)}</span>
    </div>
  )
}

function Facts({ r }: { r: RoomTypeView }) {
  const { t, tr } = useApp()
  const { num } = useFormat()
  return (
    <ul className="flex flex-wrap gap-x-5 gap-y-1 t-small text-muted">
      <li className="flex items-center gap-1.5"><Maximize2 className="h-3.5 w-3.5" aria-hidden /><span className="nums">{t('results.size', { n: num(r.sizeSqm) })}</span></li>
      <li className="flex items-center gap-1.5"><Users className="h-3.5 w-3.5" aria-hidden /><span className="nums">{t('results.sleeps', { n: num(r.maxOccupancy) })}</span></li>
      <li className="flex items-center gap-1.5"><Eye className="h-3.5 w-3.5" aria-hidden />{tr(r.view)}</li>
    </ul>
  )
}

function CardSkeleton() {
  return (
    <div className="grid gap-6 rounded-lg border border-line bg-surface p-4 md:grid-cols-[minmax(0,1fr)_minmax(0,1.25fr)] md:p-5" aria-hidden>
      <div className="skeleton aspect-[4/3] rounded-lg" />
      <div className="space-y-3"><div className="skeleton h-7 w-48 rounded-base" /><div className="skeleton h-4 w-64 rounded-base" /><div className="skeleton mt-6 h-20 rounded-base" /><div className="skeleton h-20 rounded-base" /></div>
    </div>
  )
}

export default function Results() {
  const { api, t, tr } = useApp()
  const { day, num } = useFormat()
  const [q] = useSearchParams()
  const asked = useMemo(() => stayFromQuery(q), [q])
  const nav = useNavigate()
  // a code that opens nothing is said so above the results, which are then the public ones
  const [code, setCode] = useState<CodeView | null>(null)
  const stay = useMemo(() => (asked.code && code && !code.ok ? { ...asked, code: undefined } : asked), [asked, code])
  const [rooms, setRooms] = useState<RoomTypeView[]>([])
  const [plans, setPlans] = useState<PlanView[]>([])
  const [packages, setPackages] = useState<Record<number, InclusionView[]>>({})
  const [res, setRes] = useState<SearchResult | null>(null)
  const [nearby, setNearby] = useState<StayRequest[]>([])
  const acct = useAccount()
  const [joined, setJoined] = useState<number | null>(null)
  const join = async (rt: number) => {
    try { await api.joinWaitlist(acct.token, rt, stay); setJoined(rt); toast.success(t('waitlist.joined')) }
    catch (e) { toast.error(e instanceof Refused ? tr(e.reason) : t('err.generic')) }
  }

  useEffect(() => {
    let live = true
    setCode(null)
    if (asked.code) {
      api.codeInfo(asked.code).then((c) => live && setCode(c))
        .catch(() => live && setCode({ ok: false, kind: 'unreachable', reason: { en: '', ar: '' }, name: '', planIds: [] }))
    }
    return () => { live = false }
  }, [api, asked.code])

  useEffect(() => {
    let live = true
    if (asked.code && code === null) return
    setRes(null); setNearby([])
    Promise.all([api.roomTypes(), api.plans(stay.code), api.search(stay)]).then(async ([r, p, s]) => {
      if (!live) return
      setRooms(r); setPlans(p); setRes(s)
      // what each package plan on offer includes, read once a plan for the page
      const withPackage = p.filter((x) => s.offers.some((o) => o.planId === x.id && o.packageTotal > 0n))
      Promise.all(withPackage.map((x) => api.packageOf(x.id).then((incs) => [x.id, incs] as const)))
        .then((all) => { if (live) setPackages(Object.fromEntries(all)) }).catch(() => { /* the price stands; the items are named in its breakdown */ })
      if (s.offers.length === 0) {
        const tries = [1, 2, 7, -1, 14].map((k) => ({ ...stay, arrival: stay.arrival + k }))
        const ok: StayRequest[] = []
        for (const x of tries) { const y = await api.search(x); if (y.offers.length) ok.push(x); if (ok.length === 3) break }
        if (live) setNearby(ok)
      }
    }).catch((e) => { if (live) toast.error(e instanceof Refused ? tr(e.reason) : t('err.generic')) })
    return () => { live = false }
  }, [api, stay, asked.code, code, t, tr])

  const byRoom = useMemo(() => {
    const m = new Map<number, Offer[]>()
    for (const o of res?.offers ?? []) m.set(o.roomTypeId, [...(m.get(o.roomTypeId) ?? []), o])
    return m
  }, [res])
  const available = rooms.filter((r) => byRoom.has(r.id))
  const unavailable = rooms.filter((r) => !byRoom.has(r.id))

  const choose = (o: Offer) => {
    setFlow({ stay, offer: o, hold: undefined, guest: undefined, done: undefined })
    nav(`/rooms/${o.roomTypeId}?${stayQuery(stay)}&plan=${o.planId}`)
  }

  return (
    <div className="mx-auto max-w-[1240px] px-4 pt-8 sm:px-8">
      <BookingBar key={stayQuery(stay)} initial={stay} withHorizon={false} className="shadow-1" />

      <h1 className="t-h1 mt-10 text-ink" aria-live="polite">
        {res ? (available.length === 1 ? t('results.titleOne', { total: num(rooms.length) }) : available.length ? t('results.title', { n: num(available.length), total: num(rooms.length) }) : t('results.none')) : '\u00a0'}
      </h1>
      <p className="mt-1 text-muted"><bdi>{day(stay.arrival, 'long')}</bdi> → <bdi>{day(stay.arrival + stay.nights, 'long')}</bdi></p>
      {asked.code && code && (
        <div data-code-banner={code.ok ? 'ok' : 'refused'} data-code-kind={code.kind} className={`mt-4 flex flex-wrap items-center justify-between gap-3 rounded-lg border p-4 ${code.ok ? 'border-accent/60 bg-accent/5' : 'border-line bg-surface'}`}>
          <p className="flex items-center gap-2 text-ink">
            <BadgePercent className="h-4 w-4 shrink-0 text-accent" aria-hidden />
            {code.ok
              ? (code.planIds.length ? t('code.opens', { name: code.name, code: asked.code }) : t('code.opensNothing', { name: code.name }))
              : <span>{tr(code.reason)} {t('code.showingPublic')}</span>}
          </p>
          <Link to={`/rooms?${stayQuery({ ...asked, code: undefined })}`} className="inline-flex items-center gap-1 t-small font-semibold text-ink underline underline-offset-4">
            <X className="h-3.5 w-3.5" aria-hidden />{t('code.remove')}
          </Link>
        </div>
      )}

      {res && available.length === 0 && nearby.length > 0 && (
        <div className="mt-6">
          <p className="text-ink">{t('results.tryNearby')}</p>
          <ul className="mt-3 flex flex-wrap gap-3">
            {nearby.map((x) => (
              <li key={x.arrival}><Link to={`/rooms?${stayQuery(x)}`} className="inline-block rounded-base border border-line bg-surface px-4 py-2.5 font-semibold text-ink no-underline hover:border-ink"><bdi>{day(x.arrival, 'weekday')}</bdi> → <bdi>{day(x.arrival + x.nights, 'weekday')}</bdi></Link></li>
            ))}
          </ul>
        </div>
      )}

      <ul className="mt-8 space-y-6">
        {!res && [0, 1, 2].map((i) => <li key={i}><CardSkeleton /></li>)}
        {res && available.map((r, i) => (
          <li key={r.id} className="grid gap-6 rounded-lg border border-line bg-surface p-4 shadow-1 md:grid-cols-[minmax(0,1fr)_minmax(0,1.25fr)] md:p-5">
            <Carousel photos={r.photos} sizes={RESULT_PHOTO_SIZES} priority={i === 0} className="self-start" />
            <div className="min-w-0">
              <div className="flex items-start justify-between gap-3">
                <h2 className="t-h2 text-ink"><Link to={`/rooms/${r.id}?${stayQuery(stay)}`} className="no-underline hover:underline">{tr(r.name)}</Link></h2>
                {Math.min(...(byRoom.get(r.id) ?? []).map((o) => o.left)) <= 3 && (
                  <span className="shrink-0 rounded-full border border-accent px-2.5 py-0.5 t-small font-semibold text-accent nums">
                    {t('results.left', { n: num(Math.min(...(byRoom.get(r.id) ?? []).map((o) => o.left))) })}
                  </span>
                )}
              </div>
              <div className="mt-2"><Facts r={r} /></div>
              <p className="t-small mt-3 text-muted">{tr(r.desc)}</p>
              <div className="mt-3">
                {(byRoom.get(r.id) ?? []).map((o) => {
                  const plan = plans.find((p) => p.id === o.planId)
                  const coded = code?.ok && code.planIds.includes(o.planId) ? code.name : undefined
                  return plan ? <PlanRow key={o.planId} offer={o} plan={plan} stay={stay} codeName={coded} inclusions={packages[o.planId]} onChoose={() => choose(o)} /> : null
                })}
              </div>
            </div>
          </li>
        ))}
      </ul>

      {res && unavailable.length > 0 && (
        <section className="mt-12">
          <h2 className="t-eyebrow text-muted">{t('results.unavailable')}</h2>
          <ul className="mt-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            {unavailable.map((r) => {
              const why = res.unavailable.find((u) => u.roomTypeId === r.id)
              return (
                <li key={r.id} className="flex gap-4 rounded-lg border border-line p-3">
                  <div className="w-28 shrink-0 opacity-70 grayscale-[40%]"><Carousel photos={r.photos.slice(0, 1)} sizes="120px" rounded="rounded-base" /></div>
                  <div className="min-w-0">
                    <p className="font-display text-lg text-ink">{tr(r.name)}</p>
                    <p className="t-small text-muted">{why ? tr(why.reason) : ''}</p>
                    {acct.available && why?.kind === 'soldOut' && joined !== r.id && (
                      acct.signedIn
                        ? <button type="button" onClick={() => join(r.id)} className="mt-1 t-small font-semibold text-ink underline">{t('waitlist.join')}</button>
                        : <button type="button" onClick={() => acct.signIn()} className="mt-1 t-small font-semibold text-ink underline">{t('waitlist.signIn')}</button>
                    )}
                  </div>
                </li>
              )
            })}
          </ul>
        </section>
      )}
    </div>
  )
}
