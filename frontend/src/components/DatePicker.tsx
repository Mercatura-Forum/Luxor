import { useEffect, useMemo, useRef, useState, type KeyboardEvent } from 'react'
import * as Dialog from '@radix-ui/react-dialog'
import { ChevronLeft, ChevronRight, X } from 'lucide-react'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import { addMonths, daysInMonth, monthStart, weekday, type Day } from '../lib/days'
import type { CalendarDay } from '../api/types'

/**
 * The date picker, with the price of each night under its date, the nights that are full struck out,
 * no-arrival days marked, and the minimum stay of the chosen arrival explained in words. Two months
 * side by side on a wide screen, one month at a time on a phone. Keyboard: arrows move a day or a
 * week, Page Up and Page Down a month, Home and End the week, Enter chooses, Escape closes.
 */
export function DatePicker({ open, onOpenChange, arrival, nights, onChoose, focusDay }: {
  open: boolean
  onOpenChange(o: boolean): void
  arrival: Day
  nights: number
  onChoose(arrival: Day, nights: number): void
  focusDay?: Day
}) {
  const { api, t, dir, lang } = useApp()
  const { money, day: fmtDay, num } = useFormat()
  const [today, setToday] = useState<Day | null>(null)
  const [month, setMonth] = useState<Day>(monthStart(focusDay ?? arrival))
  const [cal, setCal] = useState<Map<Day, CalendarDay>>(new Map())
  const [start, setStart] = useState<Day | null>(arrival)
  const [end, setEnd] = useState<Day | null>(arrival + nights)
  const [cursor, setCursor] = useState<Day>(focusDay ?? arrival)
  const [hover, setHover] = useState<Day | null>(null)
  const grid = useRef<HTMLDivElement>(null)
  const wide = typeof matchMedia !== 'undefined' && matchMedia('(min-width: 768px)').matches
  const months = wide ? 2 : 1

  useEffect(() => {
    if (!open) return
    setStart(arrival); setEnd(arrival + nights); setMonth(monthStart(focusDay ?? arrival)); setCursor(focusDay ?? arrival)
    api.property().then((p) => setToday(p.businessDate))
  }, [open, arrival, nights, focusDay, api])

  useEffect(() => {
    if (!open) return
    let live = true
    const from = month
    const to = addMonths(month, months)
    api.calendar(0, from, to - from).then((days) => {
      if (!live) return
      setCal((prev) => { const m = new Map(prev); for (const d of days) m.set(d.day, d); return m })
    })
    return () => { live = false }
  }, [open, month, months, api])

  useEffect(() => { grid.current?.querySelector<HTMLButtonElement>(`[data-day="${cursor}"]`)?.focus() }, [cursor, month])

  const minStay = start !== null ? cal.get(start)?.minStay ?? 1 : 1

  const selectable = (d: Day) => {
    const c = cal.get(d)
    if (today !== null && d < today) return false
    if (start !== null && end === null) {
      // choosing the departure: after the arrival, past the minimum stay, and every night between bookable
      if (d <= start) return c?.bookable ?? false
      if (d < start + minStay) return false
      for (let x = start; x < d; x++) if (!cal.get(x)?.bookable) return false
      return !(c?.closedToDeparture)
    }
    return !!c?.bookable && !c.closedToArrival
  }

  const choose = (d: Day) => {
    if (start === null || end !== null || d <= start) { setStart(d); setEnd(null); return }
    if (!selectable(d)) return
    setEnd(d)
  }

  const onKey = (e: KeyboardEvent<Element>) => {
    const fwd = dir === 'rtl' ? -1 : 1
    const moves: Record<string, number> = { ArrowRight: fwd, ArrowLeft: -fwd, ArrowDown: 7, ArrowUp: -7 }
    if (e.key in moves) { e.preventDefault(); const n = cursor + moves[e.key]; setCursor(n); if (n < month || n >= addMonths(month, months)) setMonth(monthStart(n)) }
    else if (e.key === 'PageDown' || e.key === 'PageUp') { e.preventDefault(); const m = addMonths(month, e.key === 'PageDown' ? 1 : -1); setMonth(m); setCursor(m) }
    else if (e.key === 'Home') { e.preventDefault(); setCursor(cursor - weekday(cursor)) }
    else if (e.key === 'End') { e.preventDefault(); setCursor(cursor + 6 - weekday(cursor)) }
    else if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); choose(cursor) }
  }

  const weekdays = useMemo(() => Array.from({ length: 7 }, (_, i) =>
    new Intl.DateTimeFormat(lang === 'ar' ? 'ar-EG' : 'en-GB', { weekday: 'narrow', timeZone: 'UTC' }).format(new Date(Date.UTC(2026, 0, 5 + i)))), [lang])

  const rangeEnd = end ?? (start !== null && hover !== null && hover > start ? hover : null)
  const instruction = start === null || end !== null ? t('picker.pickArrival') : t('picker.pickDeparture')

  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-40 bg-black/45" />
        <Dialog.Content className="fixed inset-x-0 bottom-0 z-50 max-h-[92vh] overflow-y-auto rounded-t-lg border border-line bg-surface p-5 shadow-2 md:inset-auto md:start-1/2 md:top-1/2 md:w-[760px] md:-translate-y-1/2 md:rounded-lg md:ltr:-translate-x-1/2 md:rtl:translate-x-1/2">
          <div className="flex items-start justify-between gap-4">
            <div>
              <Dialog.Title className="t-h2 text-ink">{t('picker.title')}</Dialog.Title>
              <Dialog.Description className="t-small mt-1 text-muted" aria-live="polite">
                {instruction}{start !== null && end === null && minStay > 1 ? ' ' + t('picker.minStay', { day: fmtDay(start, 'weekday'), n: num(minStay) }) : ''}
              </Dialog.Description>
            </div>
            <Dialog.Close className="grid h-9 w-9 place-items-center rounded-full hover:bg-surface-2" aria-label="Close"><X className="h-4 w-4" aria-hidden /></Dialog.Close>
          </div>

          <div className="mt-4 flex items-center justify-between">
            <button type="button" onClick={() => setMonth(addMonths(month, -1))} disabled={today !== null && month <= monthStart(today)}
              className="grid h-9 w-9 place-items-center rounded-full border border-line disabled:opacity-30" aria-label={t('picker.prev')}>
              <ChevronLeft className="h-4 w-4 rtl:rotate-180" aria-hidden />
            </button>
            <button type="button" onClick={() => setMonth(addMonths(month, 1))} className="grid h-9 w-9 place-items-center rounded-full border border-line" aria-label={t('picker.next')}>
              <ChevronRight className="h-4 w-4 rtl:rotate-180" aria-hidden />
            </button>
          </div>

          <div ref={grid} onKeyDown={onKey} className="mt-2 grid gap-8 md:grid-cols-2" role="application" aria-roledescription="date picker">
            {Array.from({ length: months }, (_, mi) => {
              const m = addMonths(month, mi)
              const lead = weekday(m)
              const len = daysInMonth(m)
              return (
                <div key={m}>
                  <p className="mb-3 text-center font-display text-lg text-ink">{fmtDay(m, 'month')}</p>
                  <div className="grid grid-cols-7 gap-y-1 text-center">
                    {weekdays.map((w, i) => <span key={i} className="t-small pb-1 font-semibold text-muted" aria-hidden>{w}</span>)}
                    {Array.from({ length: lead }, (_, i) => <span key={`l${i}`} />)}
                    {Array.from({ length: len }, (_, i) => {
                      const d = m + i
                      const c = cal.get(d)
                      const ok = selectable(d)
                      const isStart = d === start
                      const isEnd = d === rangeEnd
                      const inRange = start !== null && rangeEnd !== null && d > start && d < rangeEnd
                      const past = today !== null && d < today
                      const full = c && !c.bookable && !past
                      return (
                        <button
                          key={d}
                          type="button"
                          data-day={d}
                          tabIndex={d === cursor ? 0 : -1}
                          disabled={!ok && !(start !== null && end === null && d <= start && c?.bookable)}
                          onClick={() => { setCursor(d); choose(d) }}
                          onMouseEnter={() => setHover(d)}
                          aria-pressed={isStart || isEnd}
                          aria-label={`${fmtDay(d, 'long')}${c?.from != null ? ', ' + money(c.from, { whole: true }) : ''}${full ? ', ' + t('picker.soldOut') : ''}${c?.closedToArrival ? ', ' + t('picker.noArrival') : ''}`}
                          className={[
                            'relative mx-auto flex h-14 w-full max-w-[3.4rem] flex-col items-center justify-center rounded-base leading-tight transition-colors',
                            isStart || isEnd ? 'bg-primary text-primary-ink' : inRange ? 'bg-surface-2 text-ink' : 'text-ink hover:bg-surface-2/60',
                            !ok && !isStart ? 'opacity-40' : '',
                            full ? 'line-through' : '',
                          ].join(' ')}
                        >
                          <span className="nums text-[0.95rem] font-semibold">{num(i + 1)}</span>
                          <span className={`nums text-[0.64rem] ${isStart || isEnd ? 'text-primary-ink/85' : 'text-muted'}`}>
                            {c?.from != null && !past ? money(c.from, { whole: true }) : full ? t('picker.soldOut') : ' '}
                          </span>
                          {c?.closedToArrival && !past && <span className="absolute top-1 end-1 h-1.5 w-1.5 rounded-full bg-accent" aria-hidden />}
                        </button>
                      )
                    })}
                  </div>
                </div>
              )
            })}
          </div>

          <div className="mt-5 flex flex-wrap items-center justify-between gap-3 border-t border-line pt-4">
            <p className="t-small flex items-center gap-4 text-muted">
              <span>{t('picker.lowest')}</span>
              <span className="flex items-center gap-1.5"><span className="h-1.5 w-1.5 rounded-full bg-accent" aria-hidden />{t('picker.noArrival')}</span>
            </p>
            <div className="flex gap-2">
              <button type="button" onClick={() => { setStart(null); setEnd(null) }} className="rounded-base px-4 py-2.5 font-semibold text-ink underline">{t('picker.clear')}</button>
              <button type="button" disabled={start === null || end === null}
                onClick={() => { if (start !== null && end !== null) { onChoose(start, end - start); onOpenChange(false) } }}
                className="rounded-base bg-primary px-5 py-2.5 font-semibold text-primary-ink disabled:opacity-40">
                {t('picker.done')}
              </button>
            </div>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  )
}
