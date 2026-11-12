import { useCallback, useEffect, useMemo, useState } from 'react'
import * as Dialog from '@radix-ui/react-dialog'
import { X } from 'lucide-react'
import { toast } from '../lib/toast'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import { dict } from '../i18n'
import { fromIso, type Day } from '../lib/days'
import { Refused, type BookingStatus, type BookingView, type DualAct, type HistoryAct, type MailRow, type PaymentView, type RoomTypeView, type StaffBookingView } from '../api/types'
import { MailList } from '../components/MailList'
import { StaffOnly } from './StaffOnly'
import { BillPanel } from './Bill'

const PAGE = 25
const STATUSES: BookingStatus[] = ['confirmed', 'checkedIn', 'checkedOut', 'cancelled', 'noShow']
const REF = /^LX-[0-9A-Z]{6}-[0-9A-Z]$/i
// an open end of the arrival window: day 0 and a day far past any horizon the contract takes bookings for
const FIRST_DAY = 0
const LAST_DAY = 99_999

/**
 * Every booking, a page at a time (a cursor, never an offset). Unfiltered, the newest first; with a
 * status or an arrival window, in arrival order through the contract's arrival index. A full reference
 * is looked up on the chain; anything else narrows the loaded page by name. A row opens the booking's
 * folio, payments and history.
 */
export default function Bookings() {
  const { api, t, tr } = useApp()
  const { money, day } = useFormat()
  const [rows, setRows] = useState<BookingView[] | null>(null)
  const [next, setNext] = useState<number | string | null>(null)
  const [types, setTypes] = useState<RoomTypeView[]>([])
  const [search, setSearch] = useState('')
  const [status, setStatus] = useState<BookingStatus | ''>('')
  const [from, setFrom] = useState('')
  const [to, setTo] = useState('')
  const [byRef, setByRef] = useState<BookingView | null | undefined>(undefined)   // undefined: no reference searched
  const [denied, setDenied] = useState(false)
  const [proposing, setProposing] = useState<BookingView | null>(null)
  const [open, setOpen] = useState<BookingView | null>(null)
  const filtered = status !== '' || from !== '' || to !== ''

  const fail = useCallback((e: unknown) => {
    if (e instanceof Refused && e.kind === 'notAuthorised') setDenied(true); else toast.error(t('err.generic'))
  }, [t])

  const page = useCallback(async (cursor: number | string | null) => {
    try {
      if (filtered) {
        const q = { status, from: fromIso(from) ?? FIRST_DAY, to: fromIso(to) ?? LAST_DAY }
        const r = await api.bookingsFiltered(q, typeof cursor === 'string' ? cursor : '', PAGE)
        setRows((old) => (cursor === null ? r.rows : [...(old ?? []), ...r.rows])); setNext(r.next)
      } else {
        const r = await api.bookings(typeof cursor === 'number' ? cursor : 0, PAGE)
        setRows((old) => (cursor === null ? r.rows : [...(old ?? []), ...r.rows])); setNext(r.next)
      }
    } catch (e) { fail(e) }
  }, [api, fail, filtered, status, from, to])
  useEffect(() => { setRows(null); page(null) }, [page])
  useEffect(() => { api.roomTypes().then(setTypes) }, [api])

  // a full reference is looked up on the chain as it is completed
  useEffect(() => {
    if (!REF.test(search.trim())) { setByRef(undefined); return }
    let live = true
    api.bookingByRef(search).then((b) => live && setByRef(b)).catch(fail)
    return () => { live = false }
  }, [api, search, fail])

  const shown = useMemo(() => {
    if (byRef !== undefined) return byRef ? [byRef] : []
    const f = search.trim().toLowerCase()
    return (rows ?? []).filter((b) => !f || b.ref.toLowerCase().includes(f) || b.guestName.toLowerCase().includes(f))
  }, [rows, search, byRef])
  const empty = byRef === null ? t('bookings.noRef') : rows?.length === 0 ? (filtered ? t('bookings.noneFiltered') : t('bookings.none')) : t('bookings.noMatch')
  const fieldCls = 'rounded-base border border-field bg-surface px-3 py-2.5 text-ink'

  return (
    <div className="mx-auto max-w-[1240px]">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="t-h1 mt-1 text-ink">{t('bookings.title')}</h1>
        </div>
      </div>
      {denied ? <StaffOnly /> : (
        <>
          <div className="mt-6 flex flex-wrap items-end gap-3">
            <label className="flex min-w-[16rem] flex-1 flex-col gap-1.5 sm:max-w-sm"><span className="t-small font-semibold text-ink">{t('bookings.filter')}</span>
              <input type="search" value={search} onChange={(e) => setSearch(e.currentTarget.value)} className={fieldCls} /></label>
            <label className="flex flex-col gap-1.5"><span className="t-small font-semibold text-ink">{t('bookings.status')}</span>
              <select value={status} onChange={(e) => setStatus(e.currentTarget.value as BookingStatus | '')} className={fieldCls}>
                <option value="">{t('bookings.anyStatus')}</option>
                {STATUSES.map((x) => <option key={x} value={x}>{t(`manage.status.${x}` as 'manage.status.confirmed')}</option>)}
              </select></label>
            <label className="flex flex-col gap-1.5"><span className="t-small font-semibold text-ink">{t('bookings.arrivingFrom')}</span>
              <input type="date" value={from} max={to || undefined} onChange={(e) => setFrom(e.currentTarget.value)} className={`${fieldCls} nums`} dir="ltr" /></label>
            <label className="flex flex-col gap-1.5"><span className="t-small font-semibold text-ink">{t('bookings.arrivingTo')}</span>
              <input type="date" value={to} min={from || undefined} onChange={(e) => setTo(e.currentTarget.value)} className={`${fieldCls} nums`} dir="ltr" /></label>
            {filtered && <button type="button" onClick={() => { setStatus(''); setFrom(''); setTo('') }} className="px-2 py-2.5 t-small font-semibold text-ink underline underline-offset-4">{t('bookings.clear')}</button>}
          </div>
          <p className="t-small mt-3 text-muted" aria-live="polite">{filtered ? t('bookings.byArrival') : t('bookings.newest')}</p>
          <div className="relative mt-2 overflow-x-auto rounded-lg border border-line bg-surface shadow-1">
            <table className="w-full min-w-[760px] text-sm nums">
              <thead>
                <tr className="border-b border-line text-start t-small text-muted">
                  {(['bookings.ref', 'bookings.guest', 'bookings.room', 'bookings.stay', 'bookings.status', 'bookings.total', 'bookings.balance'] as const).map((k, i) => (
                    <th key={k} scope="col" className={`px-4 py-3 font-semibold ${i >= 5 ? 'text-end' : 'text-start'}`}>{t(k)}</th>
                  ))}
                  <th scope="col" className="px-4 py-3"><span className="sr-only">{t('propose.button')}</span></th>
                </tr>
              </thead>
              <tbody>
                {rows === null && [0, 1, 2, 3].map((i) => <tr key={i}><td colSpan={8} className="px-4 py-2"><div className="skeleton h-6 rounded-base" aria-hidden /></td></tr>)}
                {rows !== null && shown.length === 0 && <tr><td colSpan={8} className="px-4 py-8 text-center text-muted">{empty}</td></tr>}
                {shown.map((b) => (
                  <tr key={b.id} className="border-t border-line/70 hover:bg-surface-2/40">
                    <td className="px-4 py-3 font-semibold" dir="ltr">
                      <button type="button" onClick={() => setOpen(b)} className="text-ink underline decoration-line underline-offset-4 hover:decoration-ink" aria-label={t('bookings.open', { ref: b.ref })}>{b.ref}</button>
                    </td>
                    <td className="px-4 py-3 text-ink">{b.guestName}</td>
                    <td className="px-4 py-3 text-muted">{tr(types.find((x) => x.id === b.roomTypeId)?.name)}</td>
                    <td className="px-4 py-3 text-muted"><bdi>{day(b.arrival)}</bdi> → <bdi>{day(b.departure)}</bdi></td>
                    <td className="px-4 py-3"><StatusPill status={b.status} /></td>
                    <td className="px-4 py-3 text-end text-ink">{money(b.charged - b.credited)}</td>
                    <td className={`px-4 py-3 text-end ${b.outstanding > 0n ? 'text-ink' : 'text-muted'}`}>{money(b.outstanding)}</td>
                    <td className="px-4 py-3 text-end">
                      <button type="button" onClick={() => setProposing(b)} className="t-small font-semibold text-ink underline underline-offset-4">{t('propose.button')}</button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {next !== null && byRef === undefined && (
            <button type="button" onClick={() => page(next)} className="mt-4 rounded-base border border-ink px-4 py-2.5 font-semibold text-ink">{filtered ? t('bookings.keepLooking') : t('bookings.more')}</button>
          )}
        </>
      )}
      {proposing && <Propose booking={proposing} onClose={() => setProposing(null)} />}
      {open && <Detail key={`${open.id}:${open.paid}`} booking={open} roomName={tr(types.find((x) => x.id === open.roomTypeId)?.name)} onClose={() => setOpen(null)}
        onPropose={() => { setProposing(open); setOpen(null) }}
        onSettled={async () => { const nb = await api.bookingByRef(open.ref); if (nb) setOpen(nb); setRows(null); await page(null) }} />}
    </div>
  )
}

function StatusPill({ status }: { status: BookingStatus }) {
  const { t } = useApp()
  return (
    <span className={`rounded-full px-2.5 py-0.5 t-small font-semibold ${status === 'confirmed' || status === 'checkedIn' ? 'bg-primary text-primary-ink' : 'border border-line text-muted'}`}>
      {t(`manage.status.${status}` as 'manage.status.confirmed')}
    </span>
  )
}

/** One booking as the contract keeps it: its money, its folio night by night, its payments, and what happened to it. */
function Detail({ booking: b, roomName, onClose, onPropose, onSettled }: { booking: BookingView; roomName: string; onClose(): void; onPropose(): void; onSettled(): void }) {
  const { api, t } = useApp()

  const { money, day, num } = useFormat()
  const [payments, setPayments] = useState<PaymentView[] | null>(null)
  const [origin, setOrigin] = useState<StaffBookingView | null>(null)
  const [acts, setActs] = useState<HistoryAct[] | null>(null)
  const [more, setMore] = useState<number | null>(null)
  const [mail, setMail] = useState<MailRow[] | null>(null)
  useEffect(() => {
    let live = true
    Promise.all([api.payments(b.id), api.history(b.id, 0), api.staffBooking(b.id)]).then(([p, h, o]) => {
      if (!live) return
      setPayments(p); setActs(h.acts); setMore(h.more); setOrigin(o)
    }).catch(() => toast.error(t('err.generic')))
    api.bookingMail(b.id).then((m) => live && setMail(m)).catch(() => live && setMail([]))
    return () => { live = false }
  }, [api, b.id, t])
  const earlier = async () => {
    if (more === null) return
    const h = await api.history(b.id, more)
    setActs((old) => [...(old ?? []), ...h.acts]); setMore(h.more)
  }
  // a command this screen has no words for is shown by its own name rather than hidden
  const known = (k: string): k is keyof typeof dict => k in dict
  const actLabel = (a: string) => {
    const [name, dual] = a.split(':')
    if (name === 'propose' && known(`dual.${dual}`)) return t('hist.propose', { act: t(`dual.${dual}` as keyof typeof dict) })
    const key = `hist.${name}`
    return known(key) ? t(key) : a
  }
  const dayOrBlank = (d: Day) => (d ? day(d) : '')
  const Section = ({ title, children }: { title: string; children: React.ReactNode }) => (
    <section className="mt-7"><h3 className="t-eyebrow text-muted">{title}</h3><div className="mt-2">{children}</div></section>
  )
  return (
    <Dialog.Root open onOpenChange={(o) => !o && onClose()}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-40 bg-black/35" />
        <Dialog.Content className="fixed inset-y-0 end-0 z-50 w-[min(100vw,560px)] overflow-y-auto border-s border-line bg-surface p-6 shadow-2">
          <div className="flex items-start justify-between gap-3">
            <div>
              <Dialog.Title className="t-h2 text-ink" dir="ltr">{b.ref}</Dialog.Title>
              <Dialog.Description className="t-small mt-1 text-muted">{b.guestName} · {roomName} · <bdi>{day(b.arrival)}</bdi> → <bdi>{day(b.departure)}</bdi></Dialog.Description>
            </div>
            <Dialog.Close className="grid h-9 w-9 place-items-center rounded-full hover:bg-surface-2" aria-label={t('console.cancel')}><X className="h-4 w-4" aria-hidden /></Dialog.Close>
          </div>
          <div className="mt-4 flex flex-wrap items-center gap-3">
            <StatusPill status={b.status} />
            <button type="button" onClick={onPropose} className="t-small font-semibold text-ink underline underline-offset-4">{t('propose.button')}</button>
          </div>
          {origin && <p className="t-small mt-3 text-muted">{t(origin.channel === 'walkIn' ? 'detail.walkIn' : origin.channel === 'group' ? 'detail.fromGroup' : 'detail.byPhone', { day: day(origin.day) })}</p>}
          <p className="t-small mt-3 text-ink nums">{t('detail.money', { charged: money(b.charged), credited: money(b.credited), paid: money(b.paid), outstanding: money(b.outstanding) })}</p>

          <Section title={t('detail.bill')}>
            <BillPanel booking={b} onChanged={onSettled} />
          </Section>

          <Section title={t('detail.payments')}>
            {payments === null ? <div className="skeleton h-10 rounded-base" aria-hidden /> : payments.length === 0 ? <p className="t-small text-muted">{t('detail.none')}</p> : (
              <ul className="space-y-1.5 text-sm nums">{payments.map((p) => (
                <li key={p.id} className="flex items-baseline justify-between gap-3 border-t border-line/70 pt-1.5">
                  <span className="text-ink">{t(`pay.${p.kind}` as 'pay.captured')} <span className="text-muted">· {t(`pay.${p.state}` as 'pay.done')}</span></span>
                  <span className="text-ink">{money(p.amount)}</span>
                </li>
              ))}</ul>
            )}
          </Section>

          <Section title={t('mail.title')}>
            {mail === null ? <div className="skeleton h-10 rounded-base" aria-hidden /> : <MailList rows={mail} />}
          </Section>

          <Section title={t('detail.history')}>
            {acts === null ? <div className="skeleton h-16 rounded-base" aria-hidden /> : acts.length === 0 ? <p className="t-small text-muted">{t('detail.none')}</p> : (
              <ol className="space-y-1.5 text-sm">{acts.map((a, i) => (
                <li key={`${a.block}-${i}`} className="flex items-baseline justify-between gap-3 border-t border-line/70 pt-1.5">
                  <span className="text-ink">{actLabel(a.act)}</span>
                  <span className="t-small text-muted nums">{dayOrBlank(a.day)}{a.block ? ` · ${t('detail.block', { n: num(a.block) })}` : ''}</span>
                </li>
              ))}</ol>
            )}
            {more !== null && <button type="button" onClick={earlier} className="mt-3 t-small font-semibold text-ink underline underline-offset-4">{t('detail.earlier')}</button>}
          </Section>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  )
}

function Propose({ booking, onClose }: { booking: BookingView; onClose(): void }) {
  const { api, t, tr } = useApp()
  const [act, setAct] = useState<DualAct>(booking.status === 'confirmed' ? 'staffCancel' : 'refundOutsidePolicy')
  const [amount, setAmount] = useState('')
  const [name, setName] = useState(booking.guestName)
  const [why, setWhy] = useState('')
  const [busy, setBusy] = useState(false)
  const acts: DualAct[] = ['staffCancel', 'waivePenalty', 'refundOutsidePolicy', 'compNights', 'priceOverride', 'editGuestRecord']
  const needsAmount = act === 'refundOutsidePolicy' || act === 'priceOverride'
  const minor = () => { const m = /^(\d+)(?:[.,](\d{1,2}))?$/.exec(amount.trim()); return m ? BigInt(m[1]) * 100n + BigInt((m[2] ?? '0').padEnd(2, '0')) : null }
  const label = (a: DualAct) => t(`act.${a === 'staffCancel' ? 'staffCancel' : a}` as 'act.staffCancel', { ref: booking.ref, amount: '…', text: '…' })
  const send = async () => {
    const amt = needsAmount ? minor() : 0n
    if (amt === null) return
    setBusy(true)
    try { await api.propose(act, booking.id, amt, act === 'editGuestRecord' ? name : '', why); toast.success(t('propose.sent')); onClose() }
    catch (e) { toast.error(e instanceof Refused ? tr(e.reason) : t('err.generic')) }
    finally { setBusy(false) }
  }
  return (
    <Dialog.Root open onOpenChange={(o) => !o && onClose()}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-40 bg-black/40" />
        <Dialog.Content className="fixed inset-x-4 top-1/2 z-50 mx-auto max-w-md -translate-y-1/2 rounded-lg border border-line bg-surface p-6 shadow-2">
          <div className="flex items-start justify-between gap-3">
            <Dialog.Title className="t-h2 text-ink">{t('propose.title', { ref: booking.ref })}</Dialog.Title>
            <Dialog.Close className="grid h-9 w-9 place-items-center rounded-full hover:bg-surface-2" aria-label={t('console.cancel')}><X className="h-4 w-4" aria-hidden /></Dialog.Close>
          </div>
          <Dialog.Description className="t-small mt-1 text-muted">{t('approvals.lead')}</Dialog.Description>
          <form className="mt-5 space-y-4" onSubmit={(e) => { e.preventDefault(); send() }}>
            <label className="block"><span className="font-semibold text-ink">{t('propose.act')}</span>
              <select value={act} onChange={(e) => setAct(e.currentTarget.value as DualAct)} className="mt-1.5 w-full rounded-base border border-field bg-bg px-3 py-2.5 text-ink">
                {acts.map((a) => <option key={a} value={a}>{label(a)}</option>)}
              </select>
            </label>
            {needsAmount && (
              <label className="block"><span className="font-semibold text-ink">{t('propose.amount')}</span>
                <input inputMode="decimal" dir="ltr" value={amount} onChange={(e) => setAmount(e.currentTarget.value)} className="mt-1.5 w-full rounded-base border border-field bg-bg px-3 py-2.5 nums text-ink" /></label>
            )}
            {act === 'editGuestRecord' && (
              <label className="block"><span className="font-semibold text-ink">{t('propose.name')}</span>
                <input value={name} onChange={(e) => setName(e.currentTarget.value)} className="mt-1.5 w-full rounded-base border border-field bg-bg px-3 py-2.5 text-ink" /></label>
            )}
            <label className="block"><span className="font-semibold text-ink">{t('propose.why')}</span>
              <textarea rows={3} value={why} onChange={(e) => setWhy(e.currentTarget.value)} className="mt-1.5 w-full rounded-base border border-field bg-bg px-3 py-2.5 text-ink" /></label>
            <button type="submit" disabled={busy || !why.trim() || (needsAmount && minor() === null)} className="w-full rounded-base bg-primary px-5 py-3.5 font-semibold text-primary-ink disabled:opacity-40">{t('propose.send')}</button>
          </form>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  )
}
