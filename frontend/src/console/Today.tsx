import { useCallback, useEffect, useState } from 'react'
import * as Dialog from '@radix-ui/react-dialog'
import { ArrowLeftRight, DoorOpen, LogOut, Mail, Receipt, X } from 'lucide-react'
import { Link } from 'react-router-dom'
import { toast } from '../lib/toast'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import { Refused, type BoardRoom, type CardDeskRow, type DeskRow, type MailSetupView, type RoomTypeView, type VacantRoom } from '../api/types'
import { StaffOnly } from './StaffOnly'
import { BillSheet } from './Bill'

/**
 * TODAY AT THE DESK: who arrives today and who is in house. A check-in gives the guest one of the
 * free rooms of the type they booked; a check-out shows what is left to pay before it happens.
 */
export default function Today() {
  const { api, t, tr } = useApp()
  const { money, day, num } = useFormat()
  const [today, setToday] = useState<number | null>(null)
  const [types, setTypes] = useState<RoomTypeView[]>([])
  const [arrivals, setArrivals] = useState<DeskRow[] | null>(null)
  const [inHouse, setInHouse] = useState<DeskRow[] | null>(null)
  const [picking, setPicking] = useState<DeskRow | null>(null)
  const [billing, setBilling] = useState<DeskRow | null>(null)
  const [moving, setMoving] = useState<DeskRow | null>(null)
  const [busy, setBusy] = useState(0)
  const [denied, setDenied] = useState(false)
  const [cards, setCards] = useState<CardDeskRow[]>([])
  const [mail, setMail] = useState<MailSetupView | null>(null)

  const load = useCallback(async () => {
    const p = await api.property()
    setToday(p.businessDate)
    try {
      const [a, h, rt] = await Promise.all([api.arrivals(p.businessDate), api.inHouse(), api.roomTypes()])
      setArrivals(a); setInHouse(h); setTypes(rt); setDenied(false)
      setCards(await api.cardDesk(p.businessDate).catch(() => []))
      setMail(await api.mailSetup().catch(() => null))
    } catch (e) {
      if (e instanceof Refused && e.kind === 'notAuthorised') setDenied(true); else toast.error(t('err.generic'))
    }
  }, [api, t])
  useEffect(() => { load() }, [load])

  const typeName = (id: number) => tr(types.find((x) => x.id === id)?.name)

  const out = async (r: DeskRow) => {
    setBusy(r.booking.id)
    try { await api.checkOut(r.booking.id); toast.success(t('desk.doneOut', { name: r.booking.guestName })); await load() }
    catch (e) { toast.error(e instanceof Refused ? tr(e.reason) : t('err.generic')) }
    finally { setBusy(0) }
  }

  const Card = ({ r, action }: { r: DeskRow; action: 'in' | 'out' }) => (
    <li className="flex flex-wrap items-center justify-between gap-4 rounded-lg border border-line bg-surface p-4 shadow-1">
      <div className="min-w-0">
        <p className="flex flex-wrap items-center gap-2 font-display text-lg text-ink">
          {r.booking.guestName}
          {action === 'out' && today !== null && r.booking.departure <= today && (
            <span className="rounded-full border border-accent px-2 py-0.5 font-body t-small font-semibold text-accent">{t('desk.leavingToday')}</span>
          )}
        </p>
        <p className="t-small text-muted">
          {typeName(r.booking.roomTypeId)}{r.roomNumbers.length ? ' · ' + r.roomNumbers.map((n) => t('desk.room', { n })).join(', ') : ''}
        </p>
        <p className="t-small text-muted nums">{t('desk.nights', { n: num(r.booking.departure - r.booking.arrival), day: day(r.booking.departure, 'weekday') })} · <span dir="ltr">{r.booking.ref}</span></p>
        <p className={`t-small mt-1 nums ${r.booking.outstanding > 0n ? 'text-ink' : 'text-success'}`}>
          {r.booking.outstanding > 0n ? t('desk.balance', { amount: money(r.booking.outstanding) }) : t('desk.settled')}
        </p>
      </div>
      {action === 'in' ? (
        <button type="button" onClick={() => setPicking(r)} className="inline-flex items-center gap-2 rounded-base bg-primary px-4 py-2.5 font-semibold text-primary-ink">
          <DoorOpen className="h-4 w-4" aria-hidden />{t('desk.checkIn')}
        </button>
      ) : (
        <div className="flex flex-wrap items-center gap-2">
          <button type="button" onClick={() => setBilling(r)}
            className={`inline-flex items-center gap-2 rounded-base px-4 py-2.5 font-semibold ${r.booking.outstanding > 0n ? 'bg-primary text-primary-ink' : 'border border-line text-ink'}`}>
            <Receipt className="h-4 w-4" aria-hidden />{t('bill.button')}
          </button>
          <button type="button" onClick={() => setMoving(r)} className="inline-flex items-center gap-2 rounded-base border border-line px-4 py-2.5 font-semibold text-ink">
            <ArrowLeftRight className="h-4 w-4" aria-hidden />{t('desk.move')}
          </button>
          <button type="button" disabled={busy === r.booking.id || r.booking.outstanding > 0n} onClick={() => out(r)} title={r.booking.outstanding > 0n ? t('desk.settleFirst') : undefined}
            className="inline-flex items-center gap-2 rounded-base border border-ink px-4 py-2.5 font-semibold text-ink disabled:opacity-40">
            <LogOut className="h-4 w-4 rtl:rotate-180" aria-hidden />{t('desk.checkOut')}
          </button>
        </div>
      )}
    </li>
  )

  const List_ = ({ rows, empty, action }: { rows: DeskRow[] | null; empty: string; action: 'in' | 'out' }) => (
    rows === null ? <div className="space-y-3" aria-hidden>{[0, 1].map((i) => <div key={i} className="skeleton h-24 rounded-lg" />)}</div>
    : rows.length === 0 ? <p className="rounded-lg border border-dashed border-line p-6 text-muted">{empty}</p>
    : <ul className="space-y-3">{rows.map((r) => <Card key={r.booking.id} r={r} action={action} />)}</ul>
  )

  return (
    <div className="mx-auto max-w-[1240px]">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="t-h1 mt-1 text-ink">{t('desk.title')}</h1>
          {today !== null && <p className="mt-1 text-muted">{day(today, 'long')}</p>}
        </div>
      </div>
      {!denied && mail && (!mail.on || mail.waiting > 0) && (
        <p role="status" className="mt-6 flex flex-wrap items-center gap-x-3 gap-y-1 rounded-base border border-accent px-4 py-3 text-ink" data-mail-notice={mail.on ? 'waiting' : 'off'}>
          <Mail className="h-4 w-4 text-muted" aria-hidden />
          <span>{mail.on ? t('mail.today.waiting', { n: mail.more ? `${num(mail.waiting)}+` : num(mail.waiting) }) : t('mail.today.off')}</span>
          <Link to="/console/email" className="t-small font-semibold text-ink underline underline-offset-4">{t('mail.today.open')}</Link>
        </p>
      )}
      {denied ? <StaffOnly /> : (
      <div className="mt-8 grid gap-10 lg:grid-cols-2">
        <section aria-labelledby="arr">
          <h2 id="arr" className="t-eyebrow text-muted">{t('desk.arrivals')} <span className="nums">({num(arrivals?.length ?? 0)})</span></h2>
          <div className="mt-4"><List_ rows={arrivals} empty={t('desk.noArrivals')} action="in" /></div>
        </section>
        <section aria-labelledby="inh">
          <h2 id="inh" className="t-eyebrow text-muted">{t('desk.inHouse')} <span className="nums">({num(inHouse?.length ?? 0)})</span></h2>
          <div className="mt-4"><List_ rows={inHouse} empty={t('desk.noneInHouse')} action="out" /></div>
        </section>
      </div>
      )}
      {!denied && cards.length > 0 && (
        <section aria-labelledby="cardsdue" className="mt-10" data-card-desk>
          <h2 id="cardsdue" className="t-eyebrow text-muted">{t('desk.cards')} <span className="nums">({num(cards.length)})</span></h2>
          <ul className="mt-4 space-y-2">
            {cards.map((c) => (
              <li key={`${c.kind}-${c.bookingId}`} className="flex flex-wrap items-baseline justify-between gap-3 rounded-lg border border-line bg-surface px-4 py-3" data-card-kind={c.kind}>
                <span className="text-ink"><span dir="ltr" className="font-semibold">{c.ref}</span> · {c.guestName} · <bdi>{day(c.arrival)}</bdi></span>
                <span className={`t-small nums ${c.kind === 'declined' ? 'font-semibold text-danger' : 'text-muted'}`}>
                  {c.kind === 'unguaranteed' ? t('desk.card.unguaranteed', { day: day(c.day) })
                    : c.kind === 'declined' ? t('desk.card.declined', { amount: money(c.amount), day: day(c.day), outstanding: money(c.outstanding) })
                    : t('desk.card.forgetFailed')}
                </span>
              </li>
            ))}
          </ul>
        </section>
      )}
      <BillSheet booking={billing ? (inHouse?.find((x) => x.booking.id === billing.booking.id) ?? billing).booking : null} onClose={() => setBilling(null)} onChanged={load} />
      <RoomPicker row={picking} onClose={() => setPicking(null)} onDone={async () => { setPicking(null); await load() }} />
      <MovePicker row={moving} onClose={() => setMoving(null)} onDone={async () => { setMoving(null); await load() }} />
    </div>
  )
}

function RoomPicker({ row, onClose, onDone }: { row: DeskRow | null; onClose(): void; onDone(): void }) {
  const { api, t, tr } = useApp()
  const [rooms, setRooms] = useState<VacantRoom[] | null>(null)
  const [chosen, setChosen] = useState<number | null>(null)
  const [busy, setBusy] = useState(false)
  const [doc, setDoc] = useState<File | null>(null)
  const [retention, setRetention] = useState(0)
  useEffect(() => { api.property().then((p) => setRetention(p.idRetentionDays)) }, [api])
  useEffect(() => { setRooms(null); setChosen(null); setDoc(null); if (row) api.vacantRooms(row.booking.roomTypeId).then((r) => { setRooms(r); setChosen(r[0]?.id ?? null) }) }, [row, api])
  if (!row) return null
  const go = async () => {
    if (chosen === null) return
    setBusy(true)
    try {
      if (doc) { await api.captureId(row.booking.id, doc); toast.success(t('desk.idFiled')) }
      await api.checkIn(row.booking.id, [chosen])
      toast.success(t('desk.doneIn', { name: row.booking.guestName, n: rooms?.find((r) => r.id === chosen)?.number ?? '' }))
      onDone()
    } catch (e) { toast.error(e instanceof Refused ? tr(e.reason) : t('err.generic')) }
    finally { setBusy(false) }
  }
  return (
    <Dialog.Root open onOpenChange={(o) => !o && onClose()}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-40 bg-black/40" />
        <Dialog.Content className="fixed inset-x-4 top-1/2 z-50 mx-auto max-w-md -translate-y-1/2 rounded-lg border border-line bg-surface p-6 shadow-2">
          <div className="flex items-start justify-between gap-3">
            <Dialog.Title className="t-h2 text-ink">{t('desk.chooseRoom', { name: row.booking.guestName })}</Dialog.Title>
            <Dialog.Close className="grid h-9 w-9 place-items-center rounded-full hover:bg-surface-2" aria-label={t('console.cancel')}><X className="h-4 w-4" aria-hidden /></Dialog.Close>
          </div>
          <Dialog.Description className="sr-only">{t('desk.chooseRoom', { name: row.booking.guestName })}</Dialog.Description>
          {rooms === null ? <div className="skeleton mt-5 h-20 rounded-base" aria-hidden />
            : rooms.length === 0 ? <p className="mt-5 text-ink">{t('desk.noRoom')}</p>
            : (
              <fieldset className="mt-5 grid grid-cols-3 gap-2">
                <legend className="sr-only">{t('desk.chooseRoom', { name: row.booking.guestName })}</legend>
                <p className="t-small col-span-3 text-muted">{t('desk.ready')}</p>
                {rooms.map((r) => (
                  <label key={r.id} className={`cursor-pointer rounded-base border p-3 text-center ${chosen === r.id ? 'border-primary bg-primary text-primary-ink' : 'border-line text-ink'}`}>
                    <input type="radio" name="room" className="sr-only" checked={chosen === r.id} onChange={() => setChosen(r.id)} />
                    <span className="block font-display text-xl nums">{r.number}</span>
                    <span className={`block t-small ${chosen === r.id ? '' : r.cleaning === 'dirty' ? 'text-danger' : r.cleaning === 'inspected' ? 'text-success' : 'text-muted'}`}>{t(`hk.state.${r.cleaning === '' ? 'none' : r.cleaning}`)}</span>
                  </label>
                ))}
              </fieldset>
            )}
          <div className="mt-5 border-t border-line pt-4">
            <label htmlFor="iddoc" className="block font-semibold text-ink">{t('desk.idLabel')}</label>
            <p className="t-small mt-0.5 text-muted">{t('desk.idHint', { n: retention })}</p>
            <input id="iddoc" type="file" accept="image/*" capture="environment" onChange={(e) => setDoc(e.currentTarget.files?.[0] ?? null)}
              className="mt-2 block w-full t-small text-ink file:me-3 file:rounded-base file:border file:border-line file:bg-bg file:px-3 file:py-2 file:font-semibold file:text-ink" />
            {doc && <p className="t-small mt-1 text-success">{t('desk.idTaken', { name: doc.name })}</p>}
          </div>
          <button type="button" disabled={busy || chosen === null} onClick={go} className="mt-6 w-full rounded-base bg-primary px-5 py-3.5 font-semibold text-primary-ink disabled:opacity-40">
            {t('desk.confirmIn', { n: rooms?.find((r) => r.id === chosen)?.number ?? '' })}
          </button>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  )
}

/** Moves a guest in house to another free room of the type they booked. The room they leave becomes dirty. */
function MovePicker({ row, onClose, onDone }: { row: DeskRow | null; onClose(): void; onDone(): void }) {
  const { api, t, tr } = useApp()
  const [theirs, setTheirs] = useState<BoardRoom[] | null>(null)
  const [rooms, setRooms] = useState<VacantRoom[] | null>(null)
  const [from, setFrom] = useState<number | null>(null)
  const [to, setTo] = useState<number | null>(null)
  const [busy, setBusy] = useState(false)
  useEffect(() => {
    setTheirs(null); setRooms(null); setFrom(null); setTo(null)
    if (!row) return
    Promise.all([api.housekeeping(), api.vacantRooms(row.booking.roomTypeId)]).then(([board, free]) => {
      const mine = board.filter((r) => r.occupiedBy === row.booking.id)
      setTheirs(mine); setFrom(mine[0]?.id ?? null); setRooms(free); setTo(free[0]?.id ?? null)
    }).catch(() => { setTheirs([]); setRooms([]) })
  }, [row, api])
  if (!row) return null
  const numberOf = (id: number | null) => rooms?.find((r) => r.id === id)?.number ?? ''
  const go = async () => {
    if (from === null || to === null) return
    setBusy(true)
    try {
      await api.moveRoom(row.booking.id, from, to)
      toast.success(t('desk.moved', { name: row.booking.guestName, n: numberOf(to) }))
      onDone()
    } catch (e) { toast.error(e instanceof Refused ? tr(e.reason) : t('err.generic')) }
    finally { setBusy(false) }
  }
  return (
    <Dialog.Root open onOpenChange={(o) => !o && onClose()}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-40 bg-black/40" />
        <Dialog.Content className="fixed inset-x-4 top-1/2 z-50 mx-auto max-h-[90vh] max-w-md -translate-y-1/2 overflow-y-auto rounded-lg border border-line bg-surface p-6 shadow-2" data-move-room={row.booking.id}>
          <div className="flex items-start justify-between gap-3">
            <Dialog.Title className="t-h2 text-ink">{t('desk.moveTitle', { name: row.booking.guestName })}</Dialog.Title>
            <Dialog.Close className="grid h-9 w-9 place-items-center rounded-full hover:bg-surface-2" aria-label={t('console.cancel')}><X className="h-4 w-4" aria-hidden /></Dialog.Close>
          </div>
          <Dialog.Description className="t-small mt-1 text-muted">{t('desk.moveHint')}</Dialog.Description>
          {theirs === null || rooms === null ? <div className="skeleton mt-5 h-20 rounded-base" aria-hidden /> : (
            <>
              {theirs.length > 1 && (
                <fieldset className="mt-5 grid grid-cols-3 gap-2">
                  <legend className="t-small col-span-3 mb-1 font-semibold text-ink">{t('desk.moveFrom')}</legend>
                  {theirs.map((r) => (
                    <label key={r.id} className={`cursor-pointer rounded-base border p-3 text-center ${from === r.id ? 'border-primary bg-primary text-primary-ink' : 'border-line text-ink'}`}>
                      <input type="radio" name="from" className="sr-only" checked={from === r.id} onChange={() => setFrom(r.id)} />
                      <span className="block font-display text-xl nums">{r.number}</span>
                    </label>
                  ))}
                </fieldset>
              )}
              {theirs.length === 1 && <p className="mt-5 text-ink">{t('desk.moveFromOne', { n: theirs[0].number })}</p>}
              {rooms.length === 0 ? <p className="mt-5 text-ink">{t('desk.moveNoRoom')}</p> : (
                <fieldset className="mt-5 grid grid-cols-3 gap-2">
                  <legend className="t-small col-span-3 mb-1 font-semibold text-ink">{t('desk.moveTo')}</legend>
                  {rooms.map((r) => (
                    <label key={r.id} className={`cursor-pointer rounded-base border p-3 text-center ${to === r.id ? 'border-primary bg-primary text-primary-ink' : 'border-line text-ink'}`}>
                      <input type="radio" name="to" className="sr-only" checked={to === r.id} onChange={() => setTo(r.id)} />
                      <span className="block font-display text-xl nums">{r.number}</span>
                      <span className={`block t-small ${to === r.id ? '' : r.cleaning === 'dirty' ? 'text-danger' : r.cleaning === 'inspected' ? 'text-success' : 'text-muted'}`}>{t(`hk.state.${r.cleaning === '' ? 'none' : r.cleaning}`)}</span>
                    </label>
                  ))}
                </fieldset>
              )}
            </>
          )}
          <button type="button" disabled={busy || from === null || to === null} onClick={go} className="mt-6 w-full rounded-base bg-primary px-5 py-3.5 font-semibold text-primary-ink disabled:opacity-40">
            {to === null ? t('desk.move') : t('desk.moveConfirm', { n: numberOf(to) })}
          </button>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  )
}
