import { useCallback, useEffect, useMemo, useState } from 'react'
import { ChevronLeft, ChevronRight } from 'lucide-react'
import { toast } from '../lib/toast'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import { Refused, type BoardRoom, type DeskRow, type GridRow, type RoomTypeView } from '../api/types'
import type { Day } from '../lib/days'
import { StaffOnly } from './StaffOnly'
import { piecesOf } from '../lib/roomPlan'

/**
 * THE ROOM PLAN: every physical room down, the nights across, from the business date on. A guest in
 * house is drawn on the room they hold until the morning they leave; a room out of order is drawn
 * over the nights it is out. A booking that has not arrived holds a night of its type, not a room:
 * rooms are given at check-in, so each type has a row counting the bookings still to be given one,
 * and a row of the nights left to sell, both from the type's own night rows.
 */
const SPAN = 14

export default function RoomPlan() {
  const { api, t, tr } = useApp()
  const { day, num } = useFormat()
  const [today, setToday] = useState<Day | null>(null)
  const [start, setStart] = useState<Day | null>(null)
  const [types, setTypes] = useState<RoomTypeView[]>([])
  const [board, setBoard] = useState<BoardRoom[] | null>(null)
  const [house, setHouse] = useState<DeskRow[]>([])
  const [grid, setGrid] = useState<GridRow[]>([])
  const [denied, setDenied] = useState(false)

  useEffect(() => { api.property().then((p) => { setToday(p.businessDate); setStart(p.businessDate) }) }, [api])

  const load = useCallback(async (from: Day) => {
    setBoard(null)
    try {
      const [b, h, rt, g] = await Promise.all([api.housekeeping(), api.inHouse(), api.roomTypes(), api.grid(from, SPAN)])
      setBoard(b); setHouse(h); setTypes(rt); setGrid(g); setDenied(false)
    } catch (e) {
      if (e instanceof Refused && e.kind === 'notAuthorised') setDenied(true); else toast.error(t('err.generic'))
    }
  }, [api, t])
  useEffect(() => { if (start !== null) load(start) }, [start, load])

  const days = useMemo(() => (start === null ? [] : Array.from({ length: SPAN }, (_, i) => start + i)), [start])
  const names = useMemo(() => new Map(house.map((r) => [r.booking.id, r.booking.guestName])), [house])

  if (denied) return <StaffOnly />
  const end = start === null ? 0 : start + SPAN
  const byType = types.map((rt) => ({ rt, rooms: (board ?? []).filter((r) => r.roomTypeId === rt.id).sort((a, b) => a.number.localeCompare(b.number, undefined, { numeric: true })) })).filter((x) => x.rooms.length)

  return (
    <div className="mx-auto max-w-[1240px]">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="t-h1 mt-1 text-ink">{t('plan.title')}</h1>
          <p className="mt-1 max-w-2xl text-muted">{t('plan.lede')}</p>
        </div>
        {start !== null && today !== null && (
          <div className="flex items-center gap-2">
            <button type="button" disabled={start <= today} onClick={() => setStart(Math.max(today, start - SPAN))} aria-label={t('plan.earlier')}
              className="grid h-10 w-10 place-items-center rounded-base border border-line text-ink disabled:opacity-40"><ChevronLeft className="h-4 w-4 rtl:rotate-180" aria-hidden /></button>
            <span className="t-small nums text-ink">{day(start)} – {day(end - 1)}</span>
            <button type="button" onClick={() => setStart(start + SPAN)} aria-label={t('plan.later')}
              className="grid h-10 w-10 place-items-center rounded-base border border-line text-ink"><ChevronRight className="h-4 w-4 rtl:rotate-180" aria-hidden /></button>
          </div>
        )}
      </div>
      <div className="mt-4 flex flex-wrap gap-4 t-small text-muted">
        <span className="inline-flex items-center gap-2"><span className="h-3 w-6 rounded-sm bg-primary" aria-hidden />{t('plan.keyGuest')}</span>
        <span className="inline-flex items-center gap-2"><span className="h-3 w-6 rounded-sm border border-danger/60 bg-danger/10" aria-hidden />{t('plan.keyOut')}</span>
        <span className="inline-flex items-center gap-2"><span className="h-3 w-6 rounded-sm border border-line" aria-hidden />{t('plan.keyFree')}</span>
      </div>
      {board === null || start === null ? <div className="skeleton mt-6 h-72 rounded-lg" aria-hidden /> : byType.length === 0 ? (
        <p className="mt-6 rounded-lg border border-dashed border-line p-6 text-muted">{t('plan.noRooms')}</p>
      ) : (
        <div className="mt-6 overflow-x-auto rounded-lg border border-line bg-surface" data-room-plan={start}>
          <table className="w-full min-w-[900px] table-fixed border-collapse">
            <colgroup><col className="w-28" />{days.map((d) => <col key={d} />)}</colgroup>
            <thead>
              <tr className="border-b border-line">
                <th scope="col" className="sticky start-0 z-10 bg-surface p-2 text-start t-small font-normal text-muted">{t('plan.room')}</th>
                {days.map((d) => (
                  <th key={d} scope="col" className={`p-1 text-center t-small font-normal nums ${d === today ? 'text-accent' : 'text-muted'}`}>{day(d, 'weekday')}</th>
                ))}
              </tr>
            </thead>
            {byType.map(({ rt, rooms }) => {
              const cells = new Map((grid.find((g) => g.roomTypeId === rt.id)?.cells ?? []).map((c) => [c.day, c]))
              const inRoom = (d: Day) => rooms.filter((r) => r.occupiedBy !== 0 && r.departure !== null && r.departure > d).length
              return (
                <tbody key={rt.id} className="border-b border-line">
                  <tr><th colSpan={SPAN + 1} scope="rowgroup" className="sticky start-0 bg-surface-2 px-2 py-1.5 text-start font-semibold text-ink">{tr(rt.name)}</th></tr>
                  {rooms.map((r) => (
                    <tr key={r.id} className="border-t border-line/60">
                      <th scope="row" className="sticky start-0 z-10 bg-surface px-2 py-1 text-start font-display nums text-ink">{r.number}</th>
                      {piecesOf(r, start, end, names).map((p) => (
                        <td key={p.from} colSpan={p.to - p.from} className="p-0.5">
                          {p.kind === 'guest' ? (
                            <div className="truncate rounded-sm bg-primary px-2 py-1 t-small font-semibold text-primary-ink" title={p.name} data-plan-guest={p.bookingId}>{p.name || t('plan.guest')}</div>
                          ) : p.kind === 'out' ? (
                            <div className="truncate rounded-sm border border-danger/60 bg-danger/10 px-2 py-1 t-small text-danger" title={p.reason}>{t('plan.out')}{p.reason ? ` · ${p.reason}` : ''}</div>
                          ) : <div className="h-7" aria-hidden />}
                        </td>
                      ))}
                    </tr>
                  ))}
                  <tr className="border-t border-line/60">
                    <th scope="row" className="sticky start-0 z-10 bg-surface px-2 py-1 text-start t-small font-normal text-muted">{t('plan.toGive')}</th>
                    {days.map((d) => {
                      const c = cells.get(d)
                      const waiting = c ? Math.max(0, c.sold - inRoom(d)) : 0
                      return <td key={d} className={`p-1 text-center t-small nums ${waiting ? 'font-semibold text-ink' : 'text-muted'}`}>{c ? num(waiting) : '·'}</td>
                    })}
                  </tr>
                  <tr className="border-t border-line/60">
                    <th scope="row" className="sticky start-0 z-10 bg-surface px-2 py-1 text-start t-small font-normal text-muted">{t('plan.toSell')}</th>
                    {days.map((d) => {
                      const c = cells.get(d)
                      const left = c ? Math.max(0, c.allotment - c.sold - c.held) : 0
                      return <td key={d} className={`p-1 text-center t-small nums ${c && left === 0 ? 'text-danger' : 'text-muted'}`}>{c ? (c.stopSell ? t('plan.stop') : num(left)) : '·'}</td>
                    })}
                  </tr>
                </tbody>
              )
            })}
          </table>
        </div>
      )}
    </div>
  )
}
