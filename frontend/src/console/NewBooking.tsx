import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { BadgePercent, Copy, Phone, DoorOpen } from 'lucide-react'
import { toast } from '../lib/toast'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import { fromIso, iso, type Day } from '../lib/days'
import { Refused, type Channel, type CodeView, type Offer, type PlanView, type RoomTypeView, type StaffBookResult, type StayRequest, type VacantRoom } from '../api/types'
import { rateCode } from '../lib/stay'
import { cardLink, manageLink } from '../pages/Confirmation'
import { StaffOnly } from './StaffOnly'

/**
 * A BOOKING TAKEN AT THE DESK: a guest on the phone, or a guest standing at the desk with no booking.
 * The stay is searched as a guest's is (the same rooms, rates, restrictions and price), and the booking
 * carries no card: what it costs is outstanding until the guest pays at the desk. A walk-in arrives
 * today and is given its rooms in the same act. The manage link is made here, to give the guest.
 */
export default function NewBooking() {
  const { api, t, tr, lang } = useApp()
  const { money, day } = useFormat()
  const [today, setToday] = useState<Day | null>(null)
  const [types, setTypes] = useState<RoomTypeView[]>([])
  const [plans, setPlans] = useState<PlanView[]>([])
  const [channel, setChannel] = useState<Channel>('phone')
  const [arrival, setArrival] = useState('')
  const [nights, setNights] = useState(1)
  const [rooms, setRooms] = useState(1)
  const [adults, setAdults] = useState(2)
  const [children, setChildren] = useState(0)
  // a company's or a promotion's code the caller gives: it opens the rate the public search does not show
  const [codeText, setCodeText] = useState('')
  const [codeInfo, setCodeInfo] = useState<CodeView | null>(null)
  const [offers, setOffers] = useState<Offer[] | null>(null)
  const [unavailable, setUnavailable] = useState<string[]>([])
  const [offer, setOffer] = useState<Offer | null>(null)
  const [vacant, setVacant] = useState<VacantRoom[] | null>(null)
  const [chosen, setChosen] = useState<number[]>([])
  const [name, setName] = useState('')
  const [email, setEmail] = useState('')
  const [note, setNote] = useState('')
  const [mailLang, setMailLang] = useState<'en' | 'ar' | null>(null)
  const [busy, setBusy] = useState(false)
  const [done, setDone] = useState<StaffBookResult | null>(null)
  // the card the booking waits for, when the hotel keeps cards on file for its rate (read from the booking itself)
  const [cardDue, setCardDue] = useState<{ deadline: Day } | null>(null)
  const [denied, setDenied] = useState(false)

  useEffect(() => {
    api.property().then((p) => { setToday(p.businessDate); setArrival(iso(p.businessDate)) }).catch(() => toast.error(t('err.generic')))
    api.roomTypes().then(setTypes).catch(() => setTypes([]))
    api.staffPlans().then(setPlans).catch(() => setPlans([]))
  }, [api, t])

  const arrivalDay = channel === 'walkIn' ? today : fromIso(arrival)
  const code = rateCode(codeText)
  const codeBad = codeText.trim() !== '' && code === ''
  const req: StayRequest | null = arrivalDay === null || codeBad ? null : { arrival: arrivalDay, nights, rooms, adults, children, ...(code ? { code } : {}) }
  const reqKey = JSON.stringify([channel, arrivalDay, nights, rooms, adults, children, code])
  // a change to the stay asks again: an offer found for other dates is not this stay's price
  useEffect(() => { setOffers(null); setOffer(null); setUnavailable([]); setCodeInfo(null) }, [reqKey])
  useEffect(() => { setVacant(null); setChosen([]) }, [offer, channel])
  useEffect(() => {
    if (channel !== 'walkIn' || !offer) return
    let live = true
    api.vacantRooms(offer.roomTypeId).then((v) => { if (live) { setVacant(v); setChosen(v.slice(0, rooms).map((r) => r.id)) } })
      .catch((e) => { if (e instanceof Refused && e.kind === 'notAuthorised') setDenied(true); else toast.error(t('err.generic')) })
    return () => { live = false }
  }, [api, channel, offer, rooms, t])

  const find = useCallback(async () => {
    if (!req) return
    setBusy(true)
    try {
      const [r, info] = await Promise.all([api.search(req), req.code ? api.codeInfo(req.code) : Promise.resolve(null)])
      setCodeInfo(info)
      setOffers(r.offers)
      setUnavailable(r.unavailable.map((u) => `${tr(types.find((x) => x.id === u.roomTypeId)?.name)}: ${tr(u.reason)}`))
    } catch (e) { toast.error(e instanceof Refused ? tr(e.reason) : t('err.generic')) }
    finally { setBusy(false) }
  }, [api, req, t, tr, types])

  const book = async () => {
    if (!req || !offer) return
    setBusy(true)
    try {
      const r = await api.bookByStaff(channel, offer, req, { name, email, note, lang: mailLang ?? lang }, channel === 'walkIn' ? chosen : [])
      setDone(r)
      toast.success(t('book.done', { ref: r.booking.ref }))
      const c = await api.manageCard(r.booking.ref, r.manageSecret).catch(() => null)
      setCardDue(c?.state === 'wanted' ? { deadline: c.deadline } : null)
    } catch (e) {
      if (e instanceof Refused && e.kind === 'notAuthorised') setDenied(true)
      else toast.error(e instanceof Refused ? tr(e.reason) : t('err.generic'))
    } finally { setBusy(false) }
  }

  const fieldCls = 'rounded-base border border-field bg-surface px-3 py-2.5 text-ink'
  const typeName = (id: number) => tr(types.find((x) => x.id === id)?.name)
  const planName = (id: number) => tr(plans.find((x) => x.id === id)?.name)
  const roomsReady = channel === 'phone' || chosen.length === rooms
  const canBook = !!offer && name.trim().length > 0 && roomsReady && !busy

  if (denied) return <StaffOnly />
  if (done) {
    const link = manageLink(done.booking.ref, done.manageSecret)
    return (
      <div className="mx-auto max-w-2xl">
        <h1 className="t-h1 text-ink">{t('book.doneTitle')}</h1>
        <div className="mt-6 rounded-lg border border-line bg-surface p-6 shadow-1" data-staff-booking={done.booking.id}>
          <p className="font-display text-2xl text-ink" dir="ltr">{done.booking.ref}</p>
          <p className="mt-1 text-ink">{done.booking.guestName} · {typeName(done.booking.roomTypeId)} · <bdi>{day(done.booking.arrival)}</bdi> → <bdi>{day(done.booking.departure)}</bdi></p>
          <p className="t-small mt-3 text-ink nums">{t('book.owes', { amount: money(done.booking.outstanding) })}</p>
          <p className="t-small mt-1 text-muted">{done.booking.status === 'checkedIn' ? t('book.inHouse') : t('book.payAtDesk')}</p>
          {done.mail && done.mail !== 'noAddress' && (
            <p className={`t-small mt-3 ${done.mail === 'queued' ? 'text-ink' : 'font-semibold text-ink'}`} role="status" data-mail-attach={done.mail}>{t(`mail.desk.${done.mail}`)}</p>
          )}
          <div className="mt-5">
            <p className="t-small font-semibold text-ink">{t('book.link')}</p>
            <p className="t-small mt-1 text-muted">{t('book.linkLead')}</p>
            <div className="mt-2 flex flex-wrap items-center gap-2">
              <code dir="ltr" className="min-w-0 flex-1 break-all rounded-base border border-line bg-surface-2 px-3 py-2 text-xs text-ink">{link}</code>
              <button type="button" onClick={() => { navigator.clipboard?.writeText(link).then(() => toast.success(t('book.copied')), () => toast.error(t('err.generic'))) }}
                className="inline-flex items-center gap-2 rounded-base border border-line px-3 py-2 t-small font-semibold text-ink"><Copy className="h-4 w-4" aria-hidden />{t('book.copy')}</button>
            </div>
          </div>
          {cardDue && (
            <div className="mt-5 rounded-base border border-accent p-4" data-card-link>
              <p className="t-small font-semibold text-ink">{t('book.cardLink')}</p>
              <p className="t-small mt-1 text-muted">{t('book.cardLinkLead', { day: day(cardDue.deadline) })}</p>
              <div className="mt-2 flex flex-wrap items-center gap-2">
                <code dir="ltr" className="min-w-0 flex-1 break-all rounded-base border border-line bg-surface-2 px-3 py-2 text-xs text-ink">{cardLink(done.booking.ref, done.manageSecret)}</code>
                <button type="button" onClick={() => { navigator.clipboard?.writeText(cardLink(done.booking.ref, done.manageSecret)).then(() => toast.success(t('book.copied')), () => toast.error(t('err.generic'))) }}
                  className="inline-flex items-center gap-2 rounded-base border border-line px-3 py-2 t-small font-semibold text-ink"><Copy className="h-4 w-4" aria-hidden />{t('book.copy')}</button>
              </div>
            </div>
          )}
        </div>
        <div className="mt-6 flex flex-wrap gap-3">
          <button type="button" onClick={() => { setCardDue(null); setDone(null); setOffers(null); setOffer(null); setName(''); setEmail(''); setNote('') }}
            className="rounded-base bg-primary px-4 py-2.5 font-semibold text-primary-ink">{t('book.another')}</button>
          <Link to="/console/bookings" className="rounded-base border border-ink px-4 py-2.5 font-semibold text-ink">{t('book.toBookings')}</Link>
        </div>
      </div>
    )
  }

  return (
    <div className="mx-auto max-w-3xl">
      <h1 className="t-h1 text-ink">{t('book.title')}</h1>
      <p className="t-small mt-2 max-w-xl text-muted">{t('book.lead')}</p>

      <fieldset className="mt-6">
        <legend className="t-small font-semibold text-ink">{t('book.channel')}</legend>
        <div className="mt-2 grid gap-2 sm:grid-cols-2" role="radiogroup">
          {([['phone', Phone], ['walkIn', DoorOpen]] as const).map(([c, Icon]) => (
            <label key={c} className={`flex cursor-pointer items-start gap-3 rounded-lg border p-4 ${channel === c ? 'border-ink bg-surface-2' : 'border-line bg-surface'}`}>
              <input type="radio" name="channel" value={c} checked={channel === c} onChange={() => setChannel(c)} className="mt-1" />
              <span><span className="flex items-center gap-2 font-semibold text-ink"><Icon className="h-4 w-4" aria-hidden />{t(`book.${c}` as 'book.phone')}</span>
                <span className="t-small mt-0.5 block text-muted">{t(`book.${c}Lead` as 'book.phoneLead')}</span></span>
            </label>
          ))}
        </div>
      </fieldset>

      <section className="mt-6 grid grid-cols-2 gap-3 sm:grid-cols-5">
        <label className="col-span-2 flex flex-col gap-1.5 sm:col-span-1"><span className="t-small font-semibold text-ink">{t('book.arrival')}</span>
          {channel === 'walkIn'
            ? <span className={`${fieldCls} nums text-muted`}><bdi>{today !== null ? day(today) : ''}</bdi></span>
            : <input type="date" value={arrival} min={today !== null ? iso(today) : undefined} onChange={(e) => setArrival(e.currentTarget.value)} className={`${fieldCls} nums`} dir="ltr" />}
        </label>
        {([['book.nights', nights, setNights, 1], ['book.rooms', rooms, setRooms, 1], ['book.adults', adults, setAdults, 1], ['book.children', children, setChildren, 0]] as const).map(([k, v, set, min]) => (
          <label key={k} className="flex flex-col gap-1.5"><span className="t-small font-semibold text-ink">{t(k)}</span>
            <input type="number" inputMode="numeric" min={min} max={30} value={v} onChange={(e) => set(Math.max(min, Number(e.currentTarget.value) || min))} className={`${fieldCls} nums`} /></label>
        ))}
      </section>
      <label className="mt-3 flex max-w-sm flex-col gap-1.5"><span className="t-small font-semibold text-ink">{t('code.field')}</span>
        <input data-rate-code value={codeText} maxLength={16} onChange={(e) => setCodeText(e.currentTarget.value.toUpperCase())} autoComplete="off" className={`${fieldCls} font-mono`} dir="ltr" placeholder={t('code.example')} />
        <span className={`t-small ${codeBad ? 'text-danger' : 'text-muted'}`}>{codeBad ? t('code.shape') : t('code.deskLead')}</span></label>
      <button type="button" onClick={find} disabled={!req || busy} className="mt-4 rounded-base bg-primary px-4 py-2.5 font-semibold text-primary-ink disabled:opacity-40">{t('book.find')}</button>

      {offers !== null && (
        <section className="mt-6" aria-labelledby="offers">
          <h2 id="offers" className="t-h2 text-ink">{t('book.offers')}</h2>
          {offers.length === 0 && <p className="t-small mt-2 text-muted">{t('book.noOffers')}</p>}
          <ul className="mt-3 space-y-2">{offers.map((o) => {
            const on = offer?.roomTypeId === o.roomTypeId && offer.planId === o.planId
            return (
              <li key={`${o.roomTypeId}:${o.planId}`}>
                <label className={`flex cursor-pointer flex-wrap items-center justify-between gap-3 rounded-lg border p-4 ${on ? 'border-ink bg-surface-2' : 'border-line bg-surface'}`}>
                  <span className="flex items-center gap-3">
                    <input type="radio" name="offer" checked={on} onChange={() => setOffer(o)} />
                    <span><span className="font-semibold text-ink">{typeName(o.roomTypeId)}</span> <span className="text-muted">· {planName(o.planId)}</span>
                      {codeInfo?.ok && codeInfo.planIds.includes(o.planId) && <span data-coded-rate className="t-small ms-2 inline-flex items-center gap-1 font-semibold text-accent"><BadgePercent className="h-3.5 w-3.5" aria-hidden />{t('code.rateOf', { name: codeInfo.name })}</span>}
                      <span className="t-small block text-muted">{t('book.left', { n: o.left })}</span></span>
                  </span>
                  <span className="font-semibold text-ink nums">{money(o.total)}</span>
                </label>
              </li>
            )
          })}</ul>
          {unavailable.length > 0 && <ul className="t-small mt-3 space-y-0.5 text-muted">{unavailable.map((u) => <li key={u}>{u}</li>)}</ul>}
        </section>
      )}

      {offer && channel === 'walkIn' && (
        <section className="mt-6" aria-labelledby="rooms">
          <h2 id="rooms" className="t-h2 text-ink">{t('book.chooseRooms', { n: rooms })}</h2>
          {vacant === null ? <div className="skeleton mt-3 h-12 rounded-base" aria-hidden /> : vacant.length === 0 ? <p className="t-small mt-2 text-muted">{t('book.noVacant')}</p> : (
            <div className="mt-3 flex flex-wrap gap-2">{vacant.map((r) => {
              const on = chosen.includes(r.id)
              return (
                <label key={r.id} className={`flex cursor-pointer items-center gap-2 rounded-base border px-3 py-2 ${on ? 'border-ink bg-surface-2' : 'border-line'}`}>
                  <input type="checkbox" checked={on} onChange={() => setChosen((c) => (on ? c.filter((x) => x !== r.id) : [...c, r.id]))} />
                  <span className="font-semibold text-ink nums">{r.number}</span>
                  <span className={`t-small ${r.cleaning === 'dirty' ? 'text-danger' : 'text-muted'}`}>{t(`hk.state.${r.cleaning === '' ? 'none' : r.cleaning}`)}</span>
                </label>
              )
            })}</div>
          )}
        </section>
      )}

      {offer && (
        <section className="mt-6 grid gap-3" aria-labelledby="guest">
          <h2 id="guest" className="t-h2 text-ink">{t('book.guest')}</h2>
          <label className="flex flex-col gap-1.5"><span className="t-small font-semibold text-ink">{t('book.name')}</span>
            <input value={name} onChange={(e) => setName(e.currentTarget.value)} maxLength={120} autoComplete="off" className={fieldCls} /></label>
          <label className="flex flex-col gap-1.5"><span className="t-small font-semibold text-ink">{t('book.email')}</span>
            <input type="email" value={email} onChange={(e) => setEmail(e.currentTarget.value)} autoComplete="off" className={fieldCls} dir="ltr" />
            <span className="t-small text-muted">{t('book.emailLead')}</span></label>
          {email.trim() && (
            <fieldset className="flex flex-wrap items-center gap-3">
              <legend className="t-small font-semibold text-ink">{t('mail.desk.lang')}</legend>
              {(['en', 'ar'] as const).map((l) => (
                <label key={l} className="inline-flex items-center gap-2 t-small text-ink">
                  <input type="radio" name="mail-lang" checked={(mailLang ?? lang) === l} onChange={() => setMailLang(l)} />{l === 'en' ? 'English' : 'العربية'}
                </label>
              ))}
            </fieldset>
          )}
          <label className="flex flex-col gap-1.5"><span className="t-small font-semibold text-ink">{t('book.note')}</span>
            <textarea value={note} onChange={(e) => setNote(e.currentTarget.value)} maxLength={500} rows={2} className={fieldCls} /></label>
          <p className="t-small text-ink nums">{t('book.summary', { total: money(offer.total) })}</p>
          <div><button type="button" onClick={book} disabled={!canBook} className="rounded-base bg-primary px-4 py-2.5 font-semibold text-primary-ink disabled:opacity-40">
            {channel === 'walkIn' ? t('book.checkIn') : t('book.confirm')}</button></div>
        </section>
      )}
    </div>
  )
}
