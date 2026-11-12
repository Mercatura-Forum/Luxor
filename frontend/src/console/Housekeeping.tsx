import { useCallback, useEffect, useMemo, useState } from 'react'
import * as Dialog from '@radix-ui/react-dialog'
import { X } from 'lucide-react'
import { toast } from '../lib/toast'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import { fromIso, iso, type Day } from '../lib/days'
import { Refused, type BoardRoom, type Cleaning, type RoomTypeView } from '../api/types'
import { StaffOnly } from './StaffOnly'

type Filter = 'all' | 'dirty' | 'clean' | 'inspected' | 'out' | 'none'
const FILTERS: Filter[] = ['all', 'dirty', 'clean', 'inspected', 'out', 'none']

const stateOf = (r: BoardRoom): Exclude<Filter, 'all'> => (r.outOfOrder ? 'out' : r.cleaning === '' ? 'none' : r.cleaning)

/** The colour of a state, by the meaning a housekeeper reads first: what needs work, what is ready. */
const TONE: Record<Exclude<Filter, 'all'>, string> = {
  dirty: 'border-danger text-danger',
  clean: 'border-primary text-ink',
  inspected: 'border-success text-success',
  out: 'border-ink text-ink',
  none: 'border-line text-muted',
}

/**
 * HOUSEKEEPING: every room, what state it is in, and who vouches for it. A guest leaving makes a room
 * dirty; one person cleans it and a second inspects it. A vacant room can go out of order with a reason
 * until a day: its type offers one room fewer only on the nights before it is back.
 */
export default function Housekeeping() {
  const { api, t, tr } = useApp()
  const { day, num } = useFormat()
  const [rooms, setRooms] = useState<BoardRoom[] | null>(null)
  const [types, setTypes] = useState<RoomTypeView[]>([])
  const [today, setToday] = useState<Day | null>(null)
  const [denied, setDenied] = useState(false)
  const [filter, setFilter] = useState<Filter>('all')
  const [busy, setBusy] = useState(0)
  const [outFor, setOutFor] = useState<BoardRoom | null>(null)

  const load = useCallback(async () => {
    try {
      const [p, b, rt] = await Promise.all([api.property(), api.housekeeping(), api.roomTypes()])
      setToday(p.businessDate); setRooms(b); setTypes(rt); setDenied(false)
    } catch (e) {
      if (e instanceof Refused && e.kind === 'notAuthorised') setDenied(true); else toast.error(t('err.generic'))
    }
  }, [api, t])
  useEffect(() => { load() }, [load])

  const run = async (id: number, f: () => Promise<void>, ok: string) => {
    setBusy(id)
    try { await f(); toast.success(ok); await load() }
    catch (e) { toast.error(e instanceof Refused ? tr(e.reason) : t('err.generic')) }
    finally { setBusy(0) }
  }

  const counts = useMemo(() => {
    const c: Record<Filter, number> = { all: 0, dirty: 0, clean: 0, inspected: 0, out: 0, none: 0 }
    for (const r of rooms ?? []) { c.all++; c[stateOf(r)]++ }
    return c
  }, [rooms])

  const groups = useMemo(() => {
    const shown = (rooms ?? []).filter((r) => filter === 'all' || stateOf(r) === filter)
    return types.map((ty) => ({ ty, rooms: shown.filter((r) => r.roomTypeId === ty.id) })).filter((g) => g.rooms.length > 0)
  }, [rooms, types, filter])


  const Tile = ({ r }: { r: BoardRoom }) => {
    const s = stateOf(r)
    const leaving = r.occupiedBy !== 0 && today !== null && r.departure !== null && r.departure <= today
    const overdue = r.outOfOrder && r.outUntil !== null && today !== null && r.outUntil <= today
    const mark = (c: Cleaning) => run(r.id, () => api.markRoom(r.id, c), t('hk.marked', { n: r.number, state: t(`hk.state.${c}`) }))
    return (
      <li className="flex flex-col gap-3 rounded-lg border border-line bg-surface p-4 shadow-1">
        <div className="flex items-start justify-between gap-2">
          <p className="font-display text-2xl text-ink nums">{r.number}</p>
          <span className={`rounded-full border px-2 py-0.5 t-small font-semibold ${TONE[s]}`}>{t(`hk.state.${s}`)}</span>
        </div>
        <div className="t-small space-y-0.5 text-muted">
          <p>{r.occupiedBy === 0 ? t('hk.vacant') : leaving ? <span className="font-semibold text-accent">{t('hk.leavingToday')}</span>
            : t('hk.occupied', { day: r.departure !== null ? day(r.departure, 'weekday') : '' })}</p>
          {r.cleaning !== '' && r.cleanedBy !== '' && <p>{t(r.cleanedByMe ? 'hk.cleanedByYou' : 'hk.cleanedByOther')}</p>}
          {r.cleaning === 'inspected' && <p>{t(r.inspectedByMe ? 'hk.inspectedByYou' : 'hk.inspectedByOther')}</p>}
          {r.outOfOrder && (
            <>
              {r.outReason && <p className="text-ink">{r.outReason}</p>}
              <p className={overdue ? 'font-semibold text-danger' : ''}>
                {r.outUntil === null ? t('hk.outNoDate') : overdue ? t('hk.dueBack', { day: day(r.outUntil, 'weekday') }) : t('hk.backOn', { day: day(r.outUntil, 'weekday') })}
              </p>
            </>
          )}
        </div>
        <div className="mt-auto flex flex-wrap gap-2">
          {r.outOfOrder ? (
            <>
              <button type="button" disabled={busy === r.id} onClick={() => run(r.id, () => api.returnRoomToService(r.id), t('hk.returned', { n: r.number }))}
                className="rounded-base bg-primary px-3 py-2 t-small font-semibold text-primary-ink disabled:opacity-50">{t('hk.return')}</button>
              <button type="button" onClick={() => setOutFor(r)} className="rounded-base border border-line px-3 py-2 t-small font-semibold text-ink">{t('hk.changeDates')}</button>
            </>
          ) : (
            <>
              {(r.cleaning === 'dirty' || r.cleaning === '') && (
                <button type="button" disabled={busy === r.id} onClick={() => mark('clean')} className="rounded-base bg-primary px-3 py-2 t-small font-semibold text-primary-ink disabled:opacity-50">{t('hk.markClean')}</button>
              )}
              {r.cleaning === 'clean' && (
                <button type="button" disabled={busy === r.id || r.cleanedByMe} onClick={() => mark('inspected')} title={r.cleanedByMe ? t('hk.notYours') : undefined}
                  className="rounded-base bg-primary px-3 py-2 t-small font-semibold text-primary-ink disabled:opacity-50">{t('hk.inspect')}</button>
              )}
              {r.cleaning !== 'dirty' && (
                <button type="button" disabled={busy === r.id} onClick={() => mark('dirty')} className="rounded-base border border-line px-3 py-2 t-small font-semibold text-ink disabled:opacity-50">{t('hk.markDirty')}</button>
              )}
              {r.occupiedBy === 0 && (
                <button type="button" onClick={() => setOutFor(r)} className="rounded-base border border-line px-3 py-2 t-small font-semibold text-ink">{t('hk.outOfOrder')}</button>
              )}
            </>
          )}
        </div>
        {r.cleaning === 'clean' && r.cleanedByMe && <p className="t-small text-muted">{t('hk.notYours')}</p>}
      </li>
    )
  }

  return (
    <div className="mx-auto max-w-[1240px]">
      <h1 className="t-h1 mt-1 text-ink">{t('hk.title')}</h1>
      <p className="t-small mt-2 max-w-2xl text-muted">{t('hk.lead')}</p>
      {denied ? <StaffOnly /> : (
        <>
          <div role="group" aria-label={t('hk.filter')} className="mt-6 flex flex-wrap gap-2">
            {FILTERS.map((f) => (
              <button key={f} type="button" aria-pressed={filter === f} onClick={() => setFilter(f)}
                className={`rounded-full border px-3 py-1.5 t-small font-semibold ${filter === f ? 'border-primary bg-primary text-primary-ink' : 'border-line text-ink hover:bg-surface-2'}`}>
                {t(f === 'all' ? 'hk.all' : `hk.state.${f}`)} <span className="nums">{num(counts[f])}</span>
              </button>
            ))}
          </div>
          {rooms === null ? <div className="mt-6 grid grid-cols-2 gap-3 md:grid-cols-4" aria-hidden>{[0, 1, 2, 3].map((i) => <div key={i} className="skeleton h-40 rounded-lg" />)}</div>
            : groups.length === 0 ? <p className="mt-6 rounded-lg border border-dashed border-line p-6 text-muted">{t('hk.none')}</p>
            : groups.map(({ ty, rooms: rs }) => (
              <section key={ty.id} className="mt-8" aria-labelledby={`ty${ty.id}`}>
                <h2 id={`ty${ty.id}`} className="t-eyebrow text-muted">{tr(ty.name)} <span className="nums">({num(rs.length)})</span></h2>
                <ul className="mt-3 grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-4">{rs.map((r) => <Tile key={r.id} r={r} />)}</ul>
              </section>
            ))}
        </>
      )}
      <OutOfOrder room={outFor} today={today} onClose={() => setOutFor(null)} onDone={async () => { setOutFor(null); await load() }} />
    </div>
  )
}

/** A room out of order: the reason, and the first night it is back in the count. */
function OutOfOrder({ room, today, onClose, onDone }: { room: BoardRoom | null; today: Day | null; onClose(): void; onDone(): void }) {
  const { api, t, tr } = useApp()
  const [reason, setReason] = useState('')
  const [until, setUntil] = useState('')
  const [busy, setBusy] = useState(false)
  useEffect(() => {
    if (!room) return
    setReason(room.outReason)
    setUntil(room.outUntil !== null ? iso(room.outUntil) : today !== null ? iso(today + 1) : '')
  }, [room, today])
  if (!room) return null
  const d = fromIso(until)
  const tooLong = new TextEncoder().encode(reason).length > 160
  const go = async () => {
    if (d === null) return
    setBusy(true)
    try { await api.takeRoomOutOfOrder(room.id, reason.trim(), d); toast.success(t('hk.isOut', { n: room.number })); onDone() }
    catch (e) { toast.error(e instanceof Refused ? tr(e.reason) : t('err.generic')) }
    finally { setBusy(false) }
  }
  return (
    <Dialog.Root open onOpenChange={(o) => !o && onClose()}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-40 bg-black/40" />
        <Dialog.Content className="fixed inset-x-4 top-1/2 z-50 mx-auto max-w-md -translate-y-1/2 rounded-lg border border-line bg-surface p-6 shadow-2">
          <div className="flex items-start justify-between gap-3">
            <Dialog.Title className="t-h2 text-ink">{t('hk.outTitle', { n: room.number })}</Dialog.Title>
            <Dialog.Close className="grid h-9 w-9 place-items-center rounded-full hover:bg-surface-2" aria-label={t('console.cancel')}><X className="h-4 w-4" aria-hidden /></Dialog.Close>
          </div>
          <Dialog.Description className="t-small mt-2 text-muted">{t('hk.outLead')}</Dialog.Description>
          <label htmlFor="hk-reason" className="mt-5 block font-semibold text-ink">{t('hk.reason')}</label>
          <textarea id="hk-reason" rows={2} value={reason} onChange={(e) => setReason(e.currentTarget.value)}
            className="mt-1 block w-full rounded-base border border-field bg-bg px-3 py-2 text-ink" />
          {tooLong && <p className="t-small mt-1 text-danger">{t('hk.reasonLong')}</p>}
          <label htmlFor="hk-until" className="mt-4 block font-semibold text-ink">{t('hk.until')}</label>
          <input id="hk-until" type="date" value={until} min={today !== null ? iso(today + 1) : undefined} onChange={(e) => setUntil(e.currentTarget.value)}
            className="mt-1 block w-full rounded-base border border-field bg-bg px-3 py-2 text-ink" />
          <button type="button" disabled={busy || !reason.trim() || tooLong || d === null} onClick={go}
            className="mt-6 w-full rounded-base bg-primary px-5 py-3.5 font-semibold text-primary-ink disabled:opacity-40">{t('hk.takeOut')}</button>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  )
}
