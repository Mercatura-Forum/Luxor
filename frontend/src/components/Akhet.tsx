import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type KeyboardEvent, type PointerEvent } from 'react'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import { isWeekend, type Day } from '../lib/days'
import type { CalendarDay } from '../api/types'

/**
 * AKHET, the rate horizon: the next nights drawn as a horizon line. Each night is one stroke whose
 * height is its price and whose tone is its availability; a sold-out night is a broken hairline.
 * Dragging across it chooses a stay, and a sun rises over the chosen nights. Before the data arrives
 * it is a flat baseline, which is its loading state; the strokes rise when the reply lands.
 *
 * The drawing is decoration for sighted pointer users. Everyone else gets the same instrument as a
 * row of buttons, one tab stop, moved with the arrow keys, that selects a stay the same way.
 */
export function Akhet({ days, arrival, nights, onChange, onOpenDay, height = 88 }: {
  days: CalendarDay[] | null
  arrival: Day
  nights: number
  onChange(arrival: Day, nights: number): void
  onOpenDay?(day: Day): void
  height?: number
}) {
  const { dir, t, tenant } = useApp()
  const { money, day: fmtDay } = useFormat()
  const canvas = useRef<HTMLCanvasElement>(null)
  const host = useRef<HTMLDivElement>(null)
  const [width, setWidth] = useState(0)
  const [rise, setRise] = useState(0)
  const drag = useRef<{ start: number; end: number } | null>(null)
  const [dragView, setDragView] = useState<{ start: number; end: number } | null>(null)
  const [focus, setFocus] = useState(0)

  const n = days?.length ?? 60
  const prices = useMemo(() => (days ?? []).map((d) => (d.from === null ? null : Number(d.from))), [days])
  const lo = Math.min(...prices.filter((p): p is number => p !== null), Infinity)
  const hi = Math.max(...prices.filter((p): p is number => p !== null), 0)

  useLayoutEffect(() => {
    const el = host.current
    if (!el) return
    const ro = new ResizeObserver(() => setWidth(el.clientWidth))
    ro.observe(el)
    setWidth(el.clientWidth)
    return () => ro.disconnect()
  }, [])

  // the strokes rise once, when real data replaces the baseline
  useEffect(() => {
    if (!days) { setRise(0); return }
    if (matchMedia('(prefers-reduced-motion: reduce)').matches) { setRise(1); return }
    let raf = 0
    const t0 = performance.now()
    const step = (now: number) => {
      const k = Math.min(1, (now - t0) / 420)
      setRise(1 - Math.pow(1 - k, 3))
      if (k < 1) raf = requestAnimationFrame(step)
    }
    raf = requestAnimationFrame(step)
    return () => cancelAnimationFrame(raf)
  }, [days])

  const first = days?.[0]?.day ?? arrival
  const sel = dragView ?? { start: arrival - first, end: arrival - first + nights - 1 }

  const xOf = useCallback((i: number) => {
    const pad = 6
    const w = width - pad * 2
    const x = pad + (w * (i + 0.5)) / n
    return dir === 'rtl' ? width - x : x
  }, [width, n, dir])

  useEffect(() => {
    const c = canvas.current
    if (!c || !width) return
    const dpr = window.devicePixelRatio || 1
    c.width = Math.round(width * dpr)
    c.height = Math.round(height * dpr)
    const g = c.getContext('2d')!
    g.setTransform(dpr, 0, 0, dpr, 0, 0)
    g.clearRect(0, 0, width, height)
    const css = getComputedStyle(document.documentElement)
    const ink = css.getPropertyValue('--lx-text').trim()
    const accent = css.getPropertyValue('--lx-accent').trim()
    const line = css.getPropertyValue('--lx-border').trim()
    const base = height - 14
    const top = 26
    const step = (width - 12) / n
    const stroke = Math.max(2, Math.min(6, step * 0.42))

    // the weekend bands, faint
    // weekends: a short tick under the horizon, enough to read the week without boxing the night
    g.globalAlpha = 0.35
    g.fillStyle = ink
    for (let i = 0; i < n; i++) {
      const d = days?.[i]?.day ?? first + i
      if (isWeekend(d)) g.fillRect(xOf(i) - 1, base + 4, 2, 4)
    }
    // the horizon itself
    g.globalAlpha = 1
    g.strokeStyle = line
    g.lineWidth = 1
    g.beginPath(); g.moveTo(0, base + 0.5); g.lineTo(width, base + 0.5); g.stroke()

    const inSel = (i: number) => i >= Math.min(sel.start, sel.end) && i <= Math.max(sel.start, sel.end)
    for (let i = 0; i < n; i++) {
      const p = prices[i]
      const x = xOf(i)
      if (!days) continue
      if (p === null || p === undefined || !days[i].bookable) {
        g.globalAlpha = 0.5
        g.strokeStyle = ink
        g.setLineDash([2, 3])
        g.beginPath(); g.moveTo(x, base - 10); g.lineTo(x, base); g.stroke()
        g.setLineDash([])
        continue
      }
      const floor = lo * 0.7
      const k = hi > floor ? (p - floor) / (hi - floor) : 0.5
      const h = (10 + k * (base - top - 10)) * rise
      g.globalAlpha = inSel(i) ? 1 : 0.5 + 0.3 * k
      g.strokeStyle = inSel(i) ? accent : ink
      g.lineWidth = stroke
      g.lineCap = 'round'
      g.beginPath(); g.moveTo(x, base - 1); g.lineTo(x, base - h); g.stroke()
    }
    // the sun over the chosen nights
    if (days) {
      const a = Math.min(sel.start, sel.end), b = Math.max(sel.start, sel.end)
      const cx = (xOf(a) + xOf(b)) / 2
      g.globalAlpha = rise
      g.fillStyle = accent
      g.beginPath(); g.arc(cx, 10, 5.5, 0, Math.PI * 2); g.fill()
      g.globalAlpha = 0.35 * rise
      g.strokeStyle = accent
      g.lineWidth = 1
      g.beginPath(); g.moveTo(xOf(a), 20); g.lineTo(xOf(b), 20); g.stroke()
    }
    g.globalAlpha = 1
  }, [width, height, days, prices, lo, hi, rise, sel.start, sel.end, xOf, n, first])

  const indexAt = (clientX: number) => {
    const r = host.current!.getBoundingClientRect()
    let x = clientX - r.left
    if (dir === 'rtl') x = r.width - x
    return Math.max(0, Math.min(n - 1, Math.floor(((x - 6) / (r.width - 12)) * n)))
  }

  const commit = (s: number, e: number) => {
    const a = Math.min(s, e), b = Math.max(s, e)
    onChange(first + a, b - a + 1)
  }

  const onDown = (e: PointerEvent<Element>) => {
    if (!days) return
    const i = indexAt(e.clientX)
    drag.current = { start: i, end: i }
    setDragView({ start: i, end: i })
    ;(e.target as Element).setPointerCapture(e.pointerId)
  }
  const onMove = (e: PointerEvent<Element>) => {
    if (!drag.current) return
    drag.current.end = indexAt(e.clientX)
    setDragView({ ...drag.current })
  }
  const onUp = () => {
    if (!drag.current) return
    const { start, end } = drag.current
    drag.current = null
    setDragView(null)
    if (start === end) { if (onOpenDay) onOpenDay(first + start); else commit(start, start) }
    else commit(start, end)
  }

  const onKey = (e: KeyboardEvent<Element>) => {
    const fwd = dir === 'rtl' ? 'ArrowLeft' : 'ArrowRight'
    const back = dir === 'rtl' ? 'ArrowRight' : 'ArrowLeft'
    if (e.key === fwd || e.key === back) {
      e.preventDefault()
      const next = Math.max(0, Math.min(n - 1, focus + (e.key === fwd ? 1 : -1)))
      setFocus(next)
      if (e.shiftKey) commit(arrival - first, next)
    } else if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault()
      commit(focus, focus + Math.max(0, nights - 1))
    }
  }

  const selFrom = Math.min(sel.start, sel.end)
  let total = 0n, priced = true
  for (let i = selFrom; i <= Math.max(sel.start, sel.end); i++) {
    const p = days?.[i]?.from
    if (p === null || p === undefined) priced = false
    else total += p
  }
  const count = Math.abs(sel.end - sel.start) + 1

  return (
    <div className="select-none">
      <div className="mb-1 flex items-baseline justify-between gap-3">
        <p className="t-small text-muted">{t('akhet.label')}</p>
        <p className="t-small nums font-semibold text-ink" aria-live="polite">
          {days && priced ? (count === 1 ? t('bar.fromOne', { price: money(total, { whole: true }) }) : t('bar.from', { price: money(total, { whole: true }), n: count })) : ' '}
        </p>
      </div>
      <div
        ref={host}
        className="relative touch-none cursor-crosshair"
        style={{ height }}
        onPointerDown={onDown}
        onPointerMove={onMove}
        onPointerUp={onUp}
        onPointerCancel={() => { drag.current = null; setDragView(null) }}
        aria-hidden
      >
        <canvas ref={canvas} style={{ width: '100%', height }} />
      </div>
      <div
        role="group"
        tabIndex={0}
        onKeyDown={onKey}
        aria-label={t('akhet.label')}
        className="sr-only focus:not-sr-only focus:block focus:t-small focus:mt-1 focus:text-muted"
      >
        {days && (
          <span aria-live="polite">
            {fmtDay(days[focus]?.day ?? first, 'weekday')}: {days[focus]?.from != null ? money(days[focus].from as bigint, { whole: true }) : t('akhet.sold')}
          </span>
        )}
      </div>
      <span className="sr-only">{tenant.currency}</span>
    </div>
  )
}
