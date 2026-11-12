import { useCallback, useEffect, useMemo, useRef, useState, type KeyboardEvent, type PointerEvent, type ReactNode } from 'react'
import * as Dialog from '@radix-ui/react-dialog'
import { ChevronLeft, ChevronRight, Info, RotateCcw, SlidersHorizontal, X } from 'lucide-react'
import { toast } from '../lib/toast'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import { dayOf, isWeekend, weekday, type Day } from '../lib/days'
import { Refused, type GridCell, type GridRow, type ManyEdit, type PlanView, type RateAdjust, type RoomTypeView } from '../api/types'
import { adjustedBar } from '../api/manyEdits'
import { displayRate } from '../api/quote'
import { ScreenHead } from './Shell'
import { StaffOnly } from './StaffOnly'

const NAME_COL_WIDE_PX = 200
const NAME_COL_NARROW_PX = 124
const NIGHT_COL_PX = 92
const VIEWS = [7, 14, 30] as const
type ViewLen = (typeof VIEWS)[number]
const WEEKDAYS_ALL = 0b1111111
const MAX_UNDO_EDITS = 256

/** A rectangle of the grid: room types `r0..r1` (in the grid's order) by nights `c0..c1`, inclusive. */
type Sel = { r0: number; r1: number; c0: number; c1: number }
type Pt = { r: number; c: number }
type Tri = 'same' | 'on' | 'off'
type KeyRow = 'rooms' | 'rate'

/** What the hotelier has typed so far: the quick bar and the full panel edit the same draft. */
interface Draft { rate: string; pct: string; allot: string; minStay: string; cta: Tri; ctd: Tri; stop: Tri; mask: number }
const EMPTY: Draft = { rate: '', pct: '', allot: '', minStay: '', cta: 'same', ctd: 'same', stop: 'same', mask: WEEKDAYS_ALL }

/** One night as a save would leave it. */
interface After { allotment: number; bar: bigint | null; minStay: number; cta: boolean; ctd: boolean; stopSell: boolean }
interface NightChange { rt: number; day: Day; before: GridCell; after: After; changed: boolean }
interface Plan { edits: ManyEdit[]; changes: NightChange[]; changed: number; error: string | null }

const norm = (r: Sel): Sel => ({ r0: Math.min(r.r0, r.r1), r1: Math.max(r.r0, r.r1), c0: Math.min(r.c0, r.c1), c1: Math.max(r.c0, r.c1) })
const rect = (a: Pt, b: Pt): Sel => norm({ r0: a.r, r1: b.r, c0: a.c, c1: b.c })
const single = (s: Sel | null) => !!s && s.r0 === s.r1 && s.c0 === s.c1
const triOf = (v: Tri) => (v === 'same' ? undefined : v === 'on')

/**
 * RATES AND AVAILABILITY: room types down, nights across, each room type in four labelled rows: how
 * full it is, the rooms still to sell, the price, and the rules. Select nights like a spreadsheet (drag,
 * Shift-click, arrow keys; a date selects that night for every room type, a room name its whole row; on a
 * phone, tap the first night and then the last) and change them from the bar that appears: a price, the
 * rooms for sale, open or stop the sale. Everything else is under "More options". Every save lands whole
 * or not at all, shows what it will change before it is made, and can be undone.
 */
export default function Rates() {
  const { api, t, tr, locale, dir } = useApp()
  const { money, day, num } = useFormat()
  const [today, setToday] = useState<Day | null>(null)
  const [start, setStart] = useState<Day | null>(null)
  const [minorUnits, setMinorUnits] = useState(2)
  const [rows, setRows] = useState<GridRow[] | null>(null)
  const [types, setTypes] = useState<RoomTypeView[]>([])
  const [plans, setPlans] = useState<PlanView[]>([])
  const [shownPlan, setShownPlan] = useState(0)
  const [view, setView] = useState<ViewLen>(14)
  const [sel, setSel] = useState<Sel | null>(null)
  const [anchor, setAnchor] = useState<Pt | null>(null)
  const [draft, setDraft] = useState<Draft>(EMPTY)
  const [panel, setPanel] = useState(false)
  const [busy, setBusy] = useState(false)
  const [undo, setUndo] = useState<{ edits: ManyEdit[]; nights: number } | null>(null)
  const [legend, setLegend] = useState(false)
  const [denied, setDenied] = useState(false)
  const [width, setWidth] = useState(0)
  const dragging = useRef(false)
  const pointer = useRef<string>('mouse')
  const quickRate = useRef<HTMLInputElement>(null)
  const quickAllot = useRef<HTMLInputElement>(null)

  const observer = useRef<ResizeObserver | null>(null)
  const wrap = useCallback((el: HTMLDivElement | null) => {
    observer.current?.disconnect(); observer.current = null
    if (!el) return
    setWidth(Math.floor(el.getBoundingClientRect().width))
    observer.current = new ResizeObserver(([e]) => setWidth(Math.floor(e.contentRect.width)))
    observer.current.observe(el)
  }, [])
  const narrow = width > 0 && width < 640
  const NAME_COL_PX = narrow ? NAME_COL_NARROW_PX : NAME_COL_WIDE_PX
  // a phone opens on a week; the choice is the hotelier's after that
  const firstView = useRef(true)
  useEffect(() => { if (width > 0 && firstView.current) { firstView.current = false; if (width < 640) setView(7) } }, [width])
  const span = view

  // a new source (the chain, or the demo desk) brings its own hotel day, so the grid opens on that day
  useEffect(() => {
    api.property().then((p) => { setToday(p.businessDate); setStart(p.businessDate); setMinorUnits(p.minorUnits); setSel(null); setUndo(null) })
    api.roomTypes().then(setTypes)
    api.staffPlans().then(setPlans).catch(() => setPlans([]))
  }, [api])
  const load = useCallback(() => {
    if (start !== null) api.grid(start, span).then((r) => { setDenied(false); setRows(r) }).catch((e) => { if (e instanceof Refused && e.kind === 'notAuthorised') setDenied(true); else toast.error(t('err.generic')) })
  }, [api, start, span, t])
  useEffect(() => { setRows(null); load() }, [load])

  const days = useMemo(() => (start === null ? [] : Array.from({ length: span }, (_, i) => start + i)), [start, span])
  const order = rows?.map((r) => r.roomTypeId) ?? []
  const typeOf = (rt: number) => types.find((x) => x.id === rt)
  const plan = plans.find((p) => p.id === shownPlan)
  const shown = (bar: bigint | null) => (bar === null ? null : plan && plan.discountBps > 0 ? displayRate(bar, { kind: 'discountOffBar', discountBps: plan.discountBps }) : bar)
  const inSel = (r: number, c: number) => !!sel && r >= sel.r0 && r <= sel.r1 && c >= sel.c0 && c <= sel.c1

  // ── selection ───────────────────────────────────────────────────────────────
  const choose = (s: Sel | null, a: Pt | null) => { setSel(s); setAnchor(a) }
  const down = (r: number, c: number, e: PointerEvent<Element>) => {
    pointer.current = e.pointerType
    if (e.pointerType !== 'mouse') return   // a finger scrolls; a tap is handled on click
    if (e.shiftKey && anchor) { setSel(rect(anchor, { r, c })); return }
    dragging.current = true
    choose({ r0: r, r1: r, c0: c, c1: c }, { r, c })
  }
  const enter = (r: number, c: number) => { if (dragging.current && anchor) setSel(rect(anchor, { r, c })) }
  const tap = (r: number, c: number) => {
    if (pointer.current === 'mouse') return
    // the first tap marks a night, the second the other corner; tapping the one marked night clears it
    if (sel && anchor && single(sel)) {
      if (anchor.r === r && anchor.c === c) choose(null, null)
      else setSel(rect(anchor, { r, c }))
    } else choose({ r0: r, r1: r, c0: c, c1: c }, { r, c })
  }
  useEffect(() => { const up = () => { dragging.current = false }; window.addEventListener('pointerup', up); return () => window.removeEventListener('pointerup', up) }, [])
  const pickNight = (c: number, extend: boolean) => {
    if (!rows?.length) return
    if (extend && sel && sel.r0 === 0 && sel.r1 === rows.length - 1) setSel(norm({ ...sel, c1: c }))
    else choose({ r0: 0, r1: rows.length - 1, c0: c, c1: c }, { r: 0, c })
  }
  const pickType = (r: number) => choose({ r0: r, r1: r, c0: 0, c1: span - 1 }, { r, c: 0 })

  const key = (r: number, c: number, e: KeyboardEvent<Element>, row: KeyRow) => {
    const fwd = dir === 'rtl' ? 'ArrowLeft' : 'ArrowRight'
    const back = dir === 'rtl' ? 'ArrowRight' : 'ArrowLeft'
    const focus = (rr: number, cc: number, kr: KeyRow) => document.querySelector<HTMLElement>(`[data-cell="${rr}-${cc}-${kr}"]`)?.focus()
    const move = (rr: number, cc: number, kr: KeyRow) => {
      if (e.shiftKey && anchor) setSel(rect(anchor, { r: rr, c: cc }))
      else choose({ r0: rr, r1: rr, c0: cc, c1: cc }, { r: rr, c: cc })
      focus(rr, cc, kr)
    }
    if (e.key === fwd || e.key === back) { e.preventDefault(); move(r, Math.max(0, Math.min(span - 1, c + (e.key === fwd ? 1 : -1))), row) }
    else if (e.key === 'ArrowDown') { e.preventDefault(); if (row === 'rooms') focus(r, c, 'rate'); else if (r + 1 < order.length) move(r + 1, c, 'rooms') }
    else if (e.key === 'ArrowUp') { e.preventDefault(); if (row === 'rate') focus(r, c, 'rooms'); else if (r > 0) move(r - 1, c, 'rate') }
    else if (e.key === 'Escape') { choose(null, null); setDraft(EMPTY) }
    else if (e.key === 'Enter') { e.preventDefault(); if (!inSel(r, c)) choose({ r0: r, r1: r, c0: c, c1: c }, { r, c }); setPanel(true) }
    else if (/^[0-9]$/.test(e.key) && !e.ctrlKey && !e.metaKey && !e.altKey) {
      // typing a number on a cell starts that value in the bar below, with the cursor after it
      e.preventDefault()
      if (!inSel(r, c)) choose({ r0: r, r1: r, c0: c, c1: c }, { r, c })
      setDraft({ ...EMPTY, [row === 'rooms' ? 'allot' : 'rate']: e.key })
      requestAnimationFrame(() => (row === 'rooms' ? quickAllot : quickRate).current?.focus())
    }
  }

  // ── what a save would change ────────────────────────────────────────────────
  const minor = (s: string): bigint | undefined => {
    const m = /^(\d+)(?:[.,](\d+))?$/.exec(s.trim())
    if (!m || (m[2] ?? '').length > minorUnits) return undefined
    return BigInt(m[1]) * 10n ** BigInt(minorUnits) + BigInt((m[2] ?? '').padEnd(minorUnits, '0') || '0')
  }
  const adjustOf = (s: string): RateAdjust | undefined => {
    const m = /^([+-]?)(\d+)(?:[.,](\d{1,2}))?\s*%?$/.exec(s.trim())
    if (!m) return undefined
    const bps = Number(m[2]) * 100 + Number((m[3] ?? '').padEnd(2, '0') || '0')
    return bps > 0 ? { up: m[1] !== '-', bps } : undefined
  }
  const plan_: Plan = useMemo(() => {
    const none: Plan = { edits: [], changes: [], changed: 0, error: null }
    if (!sel || !rows) return none
    const rate = draft.rate ? minor(draft.rate) : undefined
    const adjust = !draft.rate && draft.pct ? adjustOf(draft.pct) : undefined
    if (draft.rate && rate === undefined) return { ...none, error: t('rates.badRate') }
    if (rate === 0n) return { ...none, error: t('rates.badRate') }
    if (!draft.rate && draft.pct && !adjust) return { ...none, error: t('rates.badPct') }
    if (adjust && !adjust.up && adjust.bps >= 10_000) return { ...none, error: t('rates.badPct') }
    const allot = draft.allot !== '' ? Number(draft.allot) : undefined
    const minStay = draft.minStay !== '' ? Number(draft.minStay) : undefined
    if (minStay !== undefined && (!Number.isInteger(minStay) || minStay < 1 || minStay > 255)) return { ...none, error: t('rates.badMinStay') }
    const cta = triOf(draft.cta), ctd = triOf(draft.ctd), stop = triOf(draft.stop)
    const nothing = rate === undefined && !adjust && allot === undefined && minStay === undefined && cta === undefined && ctd === undefined && stop === undefined
    if (nothing) return none
    const edits: ManyEdit[] = []
    const changes: NightChange[] = []
    let error: string | null = null
    for (let r = sel.r0; r <= sel.r1; r++) {
      const row = rows[r]
      const rt = typeOf(row.roomTypeId)
      if (allot !== undefined && rt && allot > rt.rooms && !error) error = t('console.aboveRooms', { name: tr(rt.name), n: num(rt.rooms) })
      let any = false
      for (let c = sel.c0; c <= sel.c1; c++) {
        const cell = row.cells[c]
        if (!(draft.mask & (1 << weekday(cell.day)))) continue
        any = true
        if (cell.bar === null && rate === undefined && !error) error = t('rates.notOpen', { day: day(cell.day, 'weekday') })
        const allotment = allot ?? cell.allotment
        if (allotment < cell.sold + cell.held + cell.blocked && !error) error = t('console.belowTaken', { day: day(cell.day, 'weekday'), n: num(cell.sold + cell.held + cell.blocked) })
        const bar = rate ?? (adjust && cell.bar !== null ? adjustedBar(cell.bar, adjust) : cell.bar)
        if (bar !== null && bar <= 0n && !error) error = t('rates.toNothing', { day: day(cell.day, 'weekday') })
        const after: After = { allotment, bar, minStay: minStay ?? cell.minStay, cta: cta ?? cell.closedToArrival, ctd: ctd ?? cell.closedToDeparture, stopSell: stop ?? cell.stopSell }
        const changed = after.allotment !== cell.allotment || after.bar !== cell.bar || after.minStay !== cell.minStay || after.cta !== cell.closedToArrival || after.ctd !== cell.closedToDeparture || after.stopSell !== cell.stopSell
        changes.push({ rt: row.roomTypeId, day: cell.day, before: cell, after, changed })
      }
      if (any) edits.push({
        edit: { roomTypeId: row.roomTypeId, fromDay: days[sel.c0], toDay: days[sel.c1] + 1, weekdays: draft.mask, allotment: allot, bar: rate, minStay,
          closedToArrival: cta, closedToDeparture: ctd, stopSell: stop },
        adjust,
      })
    }
    if (edits.length === 0) error = error ?? t('rates.noWeekday')
    return { edits, changes, changed: changes.filter((x) => x.changed).length, error }
  }, [sel, rows, draft, days, minorUnits, t, tr, num, day, types])

  /** The save that puts every night the last save changed back as it was: one edit per run of equal nights. */
  const undoOf = (changes: NightChange[]): ManyEdit[] => {
    const out: ManyEdit[] = []
    const same = (a: GridCell, b: GridCell) => a.allotment === b.allotment && a.bar === b.bar && a.minStay === b.minStay && a.closedToArrival === b.closedToArrival && a.closedToDeparture === b.closedToDeparture && a.stopSell === b.stopSell
    for (const x of changes.filter((c) => c.changed)) {
      const last = out[out.length - 1]
      const prev = changes.find((c) => c.changed && c.rt === x.rt && c.day === x.day - 1)
      if (last && last.edit.roomTypeId === x.rt && last.edit.toDay === x.day && prev && same(prev.before, x.before)) { last.edit.toDay = x.day + 1; continue }
      const b = x.before
      out.push({ edit: { roomTypeId: x.rt, fromDay: x.day, toDay: x.day + 1, weekdays: WEEKDAYS_ALL, allotment: b.allotment, bar: b.bar ?? undefined, minStay: b.minStay,
        closedToArrival: b.closedToArrival, closedToDeparture: b.closedToDeparture, stopSell: b.stopSell } })
    }
    return out
  }

  const save = async () => {
    if (!plan_.edits.length || plan_.error || plan_.changed === 0) return
    setBusy(true)
    try {
      const n = await api.setNightsMany(plan_.edits)
      const back = undoOf(plan_.changes)
      setUndo(back.length <= MAX_UNDO_EDITS ? { edits: back, nights: plan_.changed } : null)
      toast.success(t('console.applied', { n: num(n) }))
      setDraft(EMPTY); setPanel(false)
      load()
    } catch (x) { toast.error(x instanceof Refused ? tr(x.reason) : t('err.generic')) }
    finally { setBusy(false) }
  }
  const runUndo = async () => {
    if (!undo) return
    setBusy(true)
    try { await api.setNightsMany(undo.edits); toast.success(t('rates.undone', { n: num(undo.nights) })); setUndo(null); load() }
    catch (x) { toast.error(x instanceof Refused ? tr(x.reason) : t('err.generic')) }
    finally { setBusy(false) }
  }

  const shift = (k: number) => { if (start !== null && today !== null) setStart(Math.max(today, start + k)) }
  const jump = (iso: string) => {
    const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso)
    if (!m || today === null) return
    setStart(Math.max(today, dayOf(Number(m[1]), Number(m[2]), Number(m[3])))); choose(null, null)
  }
  const fmtDayMonth = (d: Day) => new Intl.DateTimeFormat(locale, { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(new Date(d * 86400000))
  const iso = (d: Day) => new Date(d * 86400000).toISOString().slice(0, 10)

  // month labels above the dates: one span per month in view
  const months = useMemo(() => {
    const out: { label: string; n: number }[] = []
    for (const d of days) {
      const m = fmtDayMonth(d)
      if (out.length && out[out.length - 1].label === m) out[out.length - 1].n += 1
      else out.push({ label: m, n: 1 })
    }
    return out
  }, [days, locale])

  const selSummary = (): string => {
    if (!sel || !rows) return ''
    const names = sel.r0 === sel.r1 ? tr(typeOf(rows[sel.r0].roomTypeId)?.name) : t('rates.nTypes', { n: num(sel.r1 - sel.r0 + 1) })
    const span_ = sel.c0 === sel.c1 ? day(days[sel.c0], 'weekday') : `${day(days[sel.c0], 'weekday')} → ${day(days[sel.c1], 'weekday')}`
    return `${names} · ${span_}`
  }

  return (
    <div className="mx-auto max-w-[1600px]">
      <ScreenHead
        title={t('console.title')}
        sub={!denied && t('rates.hint')}
        actions={!denied && (
          <>
            <div className="flex overflow-hidden rounded-base border border-line t-small" role="group" aria-label={t('rates.view')}>
              {VIEWS.map((v) => (
                <button key={v} type="button" onClick={() => setView(v)} aria-pressed={view === v}
                  className={`px-3 py-2 font-semibold ${view === v ? 'bg-primary text-primary-ink' : 'text-ink hover:bg-surface-2'}`}>
                  {v === 7 ? t('rates.week') : v === 14 ? t('rates.twoWeeks') : t('rates.month')}
                </button>
              ))}
            </div>
            <button type="button" onClick={() => today !== null && setStart(today)} className="rounded-base border border-line px-3 py-2 t-small font-semibold text-ink">{t('console.today')}</button>
            <button type="button" onClick={() => shift(-span)} className="grid h-9 w-9 place-items-center rounded-base border border-line" aria-label={t('picker.prev')}><ChevronLeft className="h-4 w-4 rtl:rotate-180" aria-hidden /></button>
            <button type="button" onClick={() => shift(span)} className="grid h-9 w-9 place-items-center rounded-base border border-line" aria-label={t('picker.next')}><ChevronRight className="h-4 w-4 rtl:rotate-180" aria-hidden /></button>
            <label className="flex items-center gap-2 t-small text-muted">
              <span>{t('rates.goTo')}</span>
              <input type="date" min={today !== null ? iso(today) : undefined} value={start !== null ? iso(start) : ''} onChange={(e) => e.currentTarget.value && jump(e.currentTarget.value)}
                className="rounded-base border border-field bg-bg px-2 py-1.5 text-ink nums" />
            </label>
          </>
        )}
      />

      {denied ? <StaffOnly /> : (
        <>
          <div className="mt-5 flex flex-wrap items-center justify-between gap-3">
            {plans.length > 1 ? (
              <div className="flex flex-wrap items-center gap-2 t-small">
                <span className="text-muted">{t('rates.priceShown')}</span>
                <div className="flex overflow-hidden rounded-base border border-line" role="group" aria-label={t('rates.priceShown')}>
                  {[{ id: 0, label: t('rates.planBase') }, ...plans.filter((p) => p.discountBps > 0).map((p) => ({ id: p.id, label: tr(p.name) }))].map((x) => (
                    <button key={x.id} type="button" onClick={() => setShownPlan(x.id)} aria-pressed={shownPlan === x.id}
                      className={`px-3 py-1.5 font-semibold ${shownPlan === x.id ? 'bg-primary text-primary-ink' : 'text-ink hover:bg-surface-2'}`}>{x.label}</button>
                  ))}
                </div>
                {plan && <span className="text-muted">{t('rates.planNote', { pct: num(plan.discountBps / 100) })}</span>}
              </div>
            ) : <span />}
            <div className="flex items-center gap-2">
              {undo && (
                <button type="button" onClick={runUndo} disabled={busy} className="flex items-center gap-2 rounded-base border border-ink px-3 py-1.5 t-small font-semibold text-ink disabled:opacity-40">
                  <RotateCcw className="h-4 w-4" aria-hidden />{t('rates.undo', { n: num(undo.nights) })}
                </button>
              )}
              <button type="button" onClick={() => setLegend(!legend)} aria-expanded={legend} className="flex items-center gap-2 rounded-base px-2 py-1.5 t-small font-semibold text-ink hover:bg-surface-2">
                <Info className="h-4 w-4" aria-hidden />{t('rates.legendToggle')}
              </button>
            </div>
          </div>
          {legend && (
            <dl className="mt-3 grid gap-x-8 gap-y-2 rounded-lg border border-line bg-surface p-4 t-small sm:grid-cols-2 lg:grid-cols-3">
              <Legend k={<span className="block h-1.5 w-10 rounded-full bg-ink/60" />} v={t('rates.lgFull')} />
              <Legend k={<span className="nums"><b className="text-ink">2</b> <span className="text-muted">{t('rates.of', { n: '6' })}</span></span>} v={t('rates.lgLeft')} />
              <Legend k={<span className="font-semibold text-danger">{t('rates.closed')}</span>} v={t('rates.lgClosed')} />
              <Legend k={<Chip>{t('rates.chipMin', { n: '2' })}</Chip>} v={t('rates.lgMin')} />
              <Legend k={<Chip>{t('rates.chipNoArr')}</Chip>} v={t('rates.lgNoArr')} />
              <Legend k={<Chip>{t('rates.chipNoDep')}</Chip>} v={t('rates.lgNoDep')} />
            </dl>
          )}

          <div ref={wrap} className="relative mt-4 overflow-hidden rounded-lg border border-line bg-surface shadow-1">
            <div className="overflow-x-auto">
              <table className="w-full table-fixed border-collapse text-sm nums" role="grid" aria-label={t('console.title')} aria-multiselectable
                style={{ minWidth: NAME_COL_PX + span * NIGHT_COL_PX }}>
                <colgroup><col style={{ width: NAME_COL_PX }} />{days.map((d) => <col key={d} style={{ width: NIGHT_COL_PX }} />)}</colgroup>
                <thead>
                  <tr>
                    <th className="sticky start-0 z-10 bg-surface" />
                    {months.map((m, i) => <th key={i} colSpan={m.n} scope="colgroup" className="border-s border-line px-2 pt-2 text-start t-eyebrow font-semibold text-muted">{m.label}</th>)}
                  </tr>
                  <tr>
                    <th scope="col" className="sticky start-0 z-10 bg-surface p-3 text-start t-small font-normal text-muted">{t('rates.clickDate')}</th>
                    {days.map((d, c) => (
                      <th key={d} scope="col" className={`border-s border-line p-0 ${isWeekend(d) ? 'bg-surface-2/50' : ''}`}>
                        <button type="button" onClick={(e) => pickNight(c, e.shiftKey)} className={`w-full px-1 py-2 text-center hover:bg-surface-2 ${d === today ? 'text-accent' : 'text-muted'}`}
                          aria-label={t('rates.pickNight', { day: day(d, 'long') })}>
                          <span className="block t-small">{new Intl.DateTimeFormat(locale, { weekday: 'short', timeZone: 'UTC' }).format(new Date(d * 86400000))}</span>
                          <span className={`block font-semibold ${d === today ? 'text-accent' : 'text-ink'}`}>{num(new Date(d * 86400000).getUTCDate())}</span>
                        </button>
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {!rows && types.map((r) => (
                    <tr key={r.id}><th className="sticky start-0 bg-surface p-3 text-start">{tr(r.name)}</th><td colSpan={span} className="p-2"><div className="skeleton h-24 rounded-base" /></td></tr>
                  ))}
                  {rows?.map((row, r) => {
                    const rt = typeOf(row.roomTypeId)
                    const cls = (c: number, extra = '') =>
                      `border-s border-line px-1 text-center select-none cursor-cell outline-none [touch-action:pan-x_pan-y] ${isWeekend(days[c]) ? 'bg-surface-2/40' : ''} ${inSel(r, c) ? '!bg-primary/15' : ''} ${extra}`
                    const on = (c: number) => ({ onPointerDown: (e: PointerEvent<Element>) => down(r, c, e), onPointerEnter: () => enter(r, c), onClick: () => tap(r, c) })
                    const label = (text: string) => <th scope="row" className="sticky start-0 z-10 bg-surface px-3 py-1 text-start t-small font-normal text-muted">{text}</th>
                    return (
                      <RowGroup key={row.roomTypeId}>
                        <tr className="border-t-2 border-line">
                          <th scope="rowgroup" className="sticky start-0 z-10 bg-surface p-0 text-start align-bottom">
                            <button type="button" onClick={() => pickType(r)} className="block w-full px-3 pb-1 pt-3 text-start hover:bg-surface-2" aria-label={t('rates.pickType', { name: tr(rt?.name) })}>
                              <span className="block font-display text-base leading-tight text-ink">{tr(rt?.name)}</span>
                              <span className="t-small text-muted">{t('rates.nRooms', { n: num(rt?.rooms ?? 0) })}</span>
                            </button>
                          </th>
                          {row.cells.map((cell, c) => {
                            const k = cell.allotment ? (cell.sold + cell.held + cell.blocked) / cell.allotment : 0
                            return (
                              <td key={cell.day} className={cls(c, 'px-2 pb-1 pt-3 align-bottom')} {...on(c)} title={t('console.sold', { sold: num(cell.sold), held: num(cell.held), blocked: num(cell.blocked), all: num(cell.allotment) })}>
                                <span className="block h-1.5 w-full overflow-hidden rounded-full bg-line/60" aria-hidden>
                                  <span className="block h-full rounded-full bg-ink/70" style={{ width: `${Math.round(k * 100)}%` }} />
                                </span>
                              </td>
                            )
                          })}
                        </tr>
                        <tr>
                          {label(t('rates.rowLeft'))}
                          {row.cells.map((cell, c) => {
                            const left = Math.max(0, cell.allotment - cell.sold - cell.held - cell.blocked)
                            return (
                              <td key={cell.day} data-cell={`${r}-${c}-rooms`} tabIndex={r === 0 && c === 0 ? 0 : -1} onKeyDown={(e) => key(r, c, e, 'rooms')} aria-selected={inSel(r, c)}
                                className={cls(c, 'py-1.5')} {...on(c)} title={t('console.sold', { sold: num(cell.sold), held: num(cell.held), blocked: num(cell.blocked), all: num(cell.allotment) })}>
                                {cell.bar === null ? <span className="text-muted">{t('rates.notOpenShort')}</span>
                                  : cell.stopSell ? <span className="font-semibold text-danger">{t('rates.closed')}</span>
                                  : <><span className={`font-semibold ${left === 0 ? 'text-danger' : 'text-ink'}`}>{num(left)}</span> <span className="t-small text-muted">{t('rates.of', { n: num(cell.allotment) })}</span></>}
                              </td>
                            )
                          })}
                        </tr>
                        <tr>
                          {label(plan && plan.discountBps > 0 ? tr(plan.name) : t('rates.rowPrice'))}
                          {row.cells.map((cell, c) => {
                            const p = shown(cell.bar)
                            return (
                              <td key={cell.day} data-cell={`${r}-${c}-rate`} tabIndex={-1} onKeyDown={(e) => key(r, c, e, 'rate')} aria-selected={inSel(r, c)}
                                className={cls(c, `py-1.5 ${cell.day === today ? 'font-semibold' : ''}`)} {...on(c)}>
                                <span className="text-ink">{p === null ? '·' : money(p, { whole: true })}</span>
                              </td>
                            )
                          })}
                        </tr>
                        <tr>
                          {label(t('rates.rowRules'))}
                          {row.cells.map((cell, c) => (
                            <td key={cell.day} className={cls(c, 'pb-2 pt-0.5 align-top')} {...on(c)}>
                              <span className="flex flex-col items-center gap-0.5">
                                {cell.minStay > 1 && <Chip>{t('rates.chipMin', { n: num(cell.minStay) })}</Chip>}
                                {cell.closedToArrival && <Chip>{t('rates.chipNoArr')}</Chip>}
                                {cell.closedToDeparture && <Chip>{t('rates.chipNoDep')}</Chip>}
                              </span>
                            </td>
                          ))}
                        </tr>
                      </RowGroup>
                    )
                  })}
                </tbody>
              </table>
            </div>
            {NAME_COL_PX + span * NIGHT_COL_PX > width && (
              <div className="pointer-events-none absolute inset-y-0 end-0 w-10 bg-gradient-to-l from-surface to-transparent rtl:bg-gradient-to-r" aria-hidden />
            )}
          </div>
          {start !== null && <p className="t-small mt-3 text-muted">{day(start, 'long')} → {day(start + span - 1, 'long')}</p>}
        </>
      )}

      {/* the bar: what is selected, the three changes hoteliers make most, and what saving would do */}
      {sel && rows && !denied && (
        <div className="fixed inset-x-0 bottom-0 z-30 border-t border-line bg-surface/97 shadow-2 backdrop-blur lg:start-[240px]" data-quick-bar>
          <div className="mx-auto flex max-w-[1600px] flex-wrap items-end gap-3 px-4 py-3 sm:px-8">
            <div className="min-w-0 basis-full sm:basis-auto sm:me-2">
              <p className="t-small font-semibold text-ink">{selSummary()}</p>
              <Preview plan={plan_} t={t} num={num} money={money} />
            </div>
            <label className="block w-[7.5rem]"><span className="t-small text-muted">{t('rates.quickPrice')}</span>
              <input ref={quickRate} inputMode="decimal" dir="ltr" value={draft.rate} onChange={(e) => setDraft({ ...draft, rate: e.currentTarget.value, pct: '' })}
                onKeyDown={(e) => e.key === 'Enter' && save()} className="mt-1 w-full rounded-base border border-field bg-bg px-3 py-2 nums" placeholder={t('rates.pricePh')} /></label>
            <label className="hidden w-[6.5rem] sm:block"><span className="t-small text-muted">{t('rates.quickRooms')}</span>
              <input ref={quickAllot} type="number" min={0} value={draft.allot} onChange={(e) => setDraft({ ...draft, allot: e.currentTarget.value })}
                onKeyDown={(e) => e.key === 'Enter' && save()} className="mt-1 w-full rounded-base border border-field bg-bg px-3 py-2 nums" /></label>
            <div className="hidden sm:block">
              <Segmented label={t('rates.quickSale')} value={draft.stop} onChange={(v) => setDraft({ ...draft, stop: v })}
                options={[['same', t('rates.keep')], ['off', t('rates.open')], ['on', t('rates.stop')]]} />
            </div>
            <div className="flex items-center gap-2 sm:ms-auto">
              <button type="button" onClick={() => setPanel(true)} className="flex items-center gap-2 rounded-base border border-line px-3 py-2.5 t-small font-semibold text-ink">
                <SlidersHorizontal className="h-4 w-4" aria-hidden />{t('rates.more')}
              </button>
              <button type="button" onClick={save} disabled={busy || !!plan_.error || plan_.changed === 0}
                className="rounded-base bg-primary px-5 py-2.5 font-semibold text-primary-ink disabled:opacity-40">
                {plan_.changed === 1 ? t('console.applyOne') : t('console.apply', { n: num(plan_.changed) })}
              </button>
              <button type="button" onClick={() => { choose(null, null); setDraft(EMPTY) }} className="grid h-10 w-10 place-items-center rounded-full hover:bg-surface-2" aria-label={t('rates.clear')}>
                <X className="h-4 w-4" aria-hidden />
              </button>
            </div>
          </div>
        </div>
      )}
      {sel && <div className="h-32" aria-hidden />}

      <Panel open={panel} onOpenChange={setPanel} title={selSummary()} draft={draft} setDraft={setDraft} plan={plan_} busy={busy} onSave={save}
        nameOf={sel && sel.r1 > sel.r0 ? (rt) => tr(typeOf(rt)?.name) : undefined} />
    </div>
  )
}

function RowGroup({ children }: { children: ReactNode }) { return <>{children}</> }

function Chip({ children }: { children: ReactNode }) {
  return <span className="whitespace-nowrap rounded-sm border border-line px-1 text-[11px] leading-4 text-muted">{children}</span>
}

function Legend({ k, v }: { k: ReactNode; v: string }) {
  return <div className="flex items-center gap-3"><dt className="flex w-24 shrink-0 justify-center">{k}</dt><dd className="text-muted">{v}</dd></div>
}

function Segmented<V extends string>({ label, value, onChange, options }: { label: string; value: V; onChange(v: V): void; options: [V, string][] }) {
  return (
    <fieldset className="block">
      <legend className="t-small text-muted">{label}</legend>
      <span className="mt-1 flex overflow-hidden rounded-base border border-line t-small">
        {options.map(([v, text]) => (
          <label key={v} className={`cursor-pointer px-3 py-2 font-semibold ${value === v ? 'bg-primary text-primary-ink' : 'text-ink hover:bg-surface-2'}`}>
            <input type="radio" className="sr-only" checked={value === v} onChange={() => onChange(v)} />{text}
          </label>
        ))}
      </span>
    </fieldset>
  )
}

type T = ReturnType<typeof useApp>['t']

/** One line on what saving would do: how many nights change, a price before and after, or the reason it cannot. */
function Preview({ plan, t, num, money }: { plan: Plan; t: T; num(n: number): string; money(a: bigint, o?: { whole?: boolean }): string }) {
  if (plan.error) return <p className="t-small font-semibold text-danger" aria-live="polite">{plan.error}</p>
  if (!plan.edits.length) return <p className="t-small text-muted" aria-live="polite">{t('console.chooseChange')}</p>
  if (plan.changed === 0) return <p className="t-small text-muted" aria-live="polite">{t('console.noChange')}</p>
  const priced = plan.changes.find((x) => x.changed && x.before.bar !== x.after.bar && x.after.bar !== null)
  return (
    <p className="t-small text-muted" aria-live="polite">
      {t('console.changes', { n: num(plan.changed), m: num(plan.changes.length) })}
      {priced && <> {t('rates.priceFromTo', { from: priced.before.bar === null ? '·' : money(priced.before.bar, { whole: true }), to: money(priced.after.bar!, { whole: true }) })}</>}
    </p>
  )
}

/** Everything a save can change, in words, with the nights it changes listed before it is made. */
function Panel({ open, onOpenChange, title, draft, setDraft, plan, busy, onSave, nameOf }: {
  open: boolean; onOpenChange(o: boolean): void; title: string; draft: Draft; setDraft(d: Draft): void; plan: Plan; busy: boolean; onSave(): void
  /** Set when the save covers several room types, so each listed night says which. */
  nameOf?: (rt: number) => string
}) {
  const { t, locale } = useApp()
  const { day, num, money } = useFormat()
  const weekdayName = (i: number) => new Intl.DateTimeFormat(locale, { weekday: 'short', timeZone: 'UTC' }).format(new Date(Date.UTC(2026, 0, 5 + i)))
  const shownChanges = plan.changes.filter((x) => x.changed).slice(0, 40)
  const cellText = (a: { allotment: number; bar: bigint | null; minStay: number; stopSell: boolean }) =>
    `${a.stopSell ? t('rates.closed') : t('rates.forSale', { n: num(a.allotment) })} · ${a.bar === null ? '·' : money(a.bar, { whole: true })}${a.minStay > 1 ? ' · ' + t('rates.chipMin', { n: num(a.minStay) }) : ''}`
  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-40 bg-black/35" />
        <Dialog.Content className="fixed inset-x-0 bottom-0 z-50 max-h-[88dvh] overflow-y-auto rounded-t-xl border-t border-line bg-surface p-6 shadow-2 sm:inset-y-0 sm:start-auto sm:end-0 sm:max-h-none sm:w-[440px] sm:rounded-none sm:border-s sm:border-t-0">
          <div className="flex items-start justify-between gap-3">
            <div>
              <Dialog.Title className="t-h2 text-ink">{t('rates.panelTitle')}</Dialog.Title>
              <Dialog.Description className="t-small mt-1 text-muted">{title}</Dialog.Description>
            </div>
            <Dialog.Close className="grid h-9 w-9 place-items-center rounded-full hover:bg-surface-2" aria-label={t('console.cancel')}><X className="h-4 w-4" aria-hidden /></Dialog.Close>
          </div>
          <form className="mt-6 space-y-5" onSubmit={(e) => { e.preventDefault(); onSave() }}>
            <div className="grid grid-cols-2 gap-3">
              <label className="block"><span className="font-semibold text-ink">{t('console.setRate')}</span>
                <input inputMode="decimal" dir="ltr" value={draft.rate} onChange={(e) => setDraft({ ...draft, rate: e.currentTarget.value, pct: '' })} className="mt-1.5 w-full rounded-base border border-field bg-bg px-3 py-2.5 nums" placeholder={t('rates.pricePh')} /></label>
              <label className="block"><span className="font-semibold text-ink">{t('console.adjust')}</span>
                <input inputMode="decimal" dir="ltr" value={draft.pct} disabled={!!draft.rate} onChange={(e) => setDraft({ ...draft, pct: e.currentTarget.value })} className="mt-1.5 w-full rounded-base border border-field bg-bg px-3 py-2.5 nums disabled:opacity-40" placeholder={t('rates.pctPh')} /></label>
            </div>
            <div className="grid grid-cols-2 gap-3">
              <label className="block"><span className="font-semibold text-ink">{t('console.allotment')}</span>
                <input type="number" min={0} value={draft.allot} onChange={(e) => setDraft({ ...draft, allot: e.currentTarget.value })} className="mt-1.5 w-full rounded-base border border-field bg-bg px-3 py-2.5 nums" /></label>
              <label className="block"><span className="font-semibold text-ink">{t('console.minStay')}</span>
                <input type="number" min={1} max={255} value={draft.minStay} onChange={(e) => setDraft({ ...draft, minStay: e.currentTarget.value })} className="mt-1.5 w-full rounded-base border border-field bg-bg px-3 py-2.5 nums" /></label>
            </div>
            <div className="space-y-4 border-t border-line pt-4">
              <Segmented label={t('rates.sale')} value={draft.stop} onChange={(v) => setDraft({ ...draft, stop: v })} options={[['same', t('rates.keep')], ['off', t('rates.open')], ['on', t('rates.stop')]]} />
              <Segmented label={t('rates.arrivals')} value={draft.cta} onChange={(v) => setDraft({ ...draft, cta: v })} options={[['same', t('rates.keep')], ['off', t('rates.allowed')], ['on', t('rates.notAllowed')]]} />
              <Segmented label={t('rates.departures')} value={draft.ctd} onChange={(v) => setDraft({ ...draft, ctd: v })} options={[['same', t('rates.keep')], ['off', t('rates.allowed')], ['on', t('rates.notAllowed')]]} />
            </div>
            <fieldset className="border-t border-line pt-4">
              <legend className="font-semibold text-ink">{t('console.weekdays')}</legend>
              <div className="mt-2 flex flex-wrap gap-1.5">
                {Array.from({ length: 7 }, (_, i) => (
                  <label key={i} className={`cursor-pointer rounded-base border px-2.5 py-1.5 t-small ${draft.mask & (1 << i) ? 'border-primary bg-primary text-primary-ink' : 'border-line text-ink'}`}>
                    <input type="checkbox" className="sr-only" checked={!!(draft.mask & (1 << i))} onChange={() => setDraft({ ...draft, mask: draft.mask ^ (1 << i) })} />{weekdayName(i)}
                  </label>
                ))}
              </div>
            </fieldset>
            <div className="border-t border-line pt-4">
              <Preview plan={plan} t={t} num={num} money={money} />
              {shownChanges.length > 0 && !plan.error && (
                <ol className="mt-3 max-h-64 space-y-1.5 overflow-y-auto t-small" aria-label={t('rates.whatChanges')}>
                  {shownChanges.map((x) => (
                    <li key={`${x.rt}:${x.day}`} className="grid grid-cols-[6.5rem_1fr] gap-2">
                      <span className="font-semibold text-ink">{day(x.day, 'weekday')}{nameOf && <span className="block font-normal text-muted">{nameOf(x.rt)}</span>}</span>
                      <span className="text-muted"><s>{cellText(x.before)}</s> {t('rates.arrow')} <span className="text-ink">{cellText(x.after)}</span></span>
                    </li>
                  ))}
                  {plan.changed > shownChanges.length && <li className="text-muted">{t('rates.andMore', { n: num(plan.changed - shownChanges.length) })}</li>}
                </ol>
              )}
            </div>
            <button type="submit" disabled={busy || !!plan.error || plan.changed === 0} className="w-full rounded-base bg-primary px-5 py-3.5 font-semibold text-primary-ink disabled:opacity-40">
              {plan.changed === 1 ? t('console.applyOne') : t('console.apply', { n: num(plan.changed) })}
            </button>
          </form>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  )
}
