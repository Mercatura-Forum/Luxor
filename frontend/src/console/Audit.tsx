import { useCallback, useEffect, useState } from 'react'
import { CheckCircle2, MoonStar, TriangleAlert } from 'lucide-react'
import { toast } from '../lib/toast'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import { Refused, type AuditStatus, type HotelClock } from '../api/types'
import { DEFAULT_ZONE, ZONES, hhmmOf, ruleOf, secondsOf } from '../lib/zones'
import { StaffOnly } from './StaffOnly'

/** The night audit, run from the desk: bounded steps with visible progress, then the day closes. */
export default function Audit() {
  const { api, t, tr } = useApp()
  const { day, num } = useFormat()
  const [today, setToday] = useState<number | null>(null)
  const [st, setSt] = useState<AuditStatus | null>(null)
  const [busy, setBusy] = useState(false)
  const [denied, setDenied] = useState(false)
  const [clockTick, setClockTick] = useState(0)

  const load = useCallback(async () => {
    const p = await api.property()
    setToday(p.businessDate)
    try { setSt(await api.auditStatus(p.businessDate)); setDenied(false) }
    catch (e) { if (e instanceof Refused && e.kind === 'notAuthorised') setDenied(true); else toast.error(t('err.generic')) }
  }, [api, t])
  useEffect(() => { load() }, [load])

  const fail = (e: unknown) => toast.error(e instanceof Refused ? tr(e.reason) : t('err.generic'))

  const run = async () => {
    if (today === null) return
    setBusy(true)
    try {
      let s = st
      if (!s?.open) { await api.openAudit(today); s = await api.auditStatus(today); setSt(s) }
      for (let i = 0; i < 400 && s && !(s.completed && s.walkDone); i++) { s = await api.advanceAudit(today); setSt(s) }
    } catch (e) { fail(e) } finally { setBusy(false) }
  }

  const close = async () => {
    if (today === null) return
    setBusy(true)
    try { const next = await api.closeDay(today); toast.success(t('audit.closed', { day: day(next, 'long') })); await load(); setClockTick((n) => n + 1) }
    catch (e) { fail(e) } finally { setBusy(false) }
  }

  const ready = !!st && st.completed && st.walkDone
  return (
    <div className="mx-auto max-w-[1240px]">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="t-h1 mt-1 text-ink">{t('audit.title')}</h1>
          {today !== null && <p className="mt-1 text-muted">{day(today, 'long')}</p>}
        </div>
      </div>
      {denied ? <StaffOnly /> : (
        <div className="mt-8 max-w-2xl rounded-lg border border-line bg-surface p-6 shadow-1">
          <p className="text-ink">{t('audit.lead')}</p>
          {st?.open && (
            <ul className="mt-5 space-y-2 t-small nums">
              <li className="flex items-center gap-2 text-ink">
                <span className="h-1.5 w-24 overflow-hidden rounded-full bg-surface-2"><span className="block h-full bg-primary" style={{ width: `${st.items ? (100 * st.done) / st.items : 0}%` }} /></span>
                {t('audit.jobs', { done: num(st.done), items: num(st.items) })}
              </li>
              {st.completed && <li className="text-ink">{t('audit.books', { n: num(st.examined) })}</li>}
            </ul>
          )}
          {ready && (st.violations === 0
            ? <p className="mt-4 flex items-center gap-2 font-semibold text-success"><CheckCircle2 className="h-4 w-4" aria-hidden />{t('audit.clean')}</p>
            : <p className="mt-4 flex items-start gap-2 font-semibold text-danger" role="alert"><TriangleAlert className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />{t('audit.problem', { n: num(st.violations), first: st.firstViolation })}</p>)}
          <div className="mt-6 flex flex-wrap gap-3">
            {!ready && (
              <button type="button" onClick={run} disabled={busy} className="inline-flex items-center gap-2 rounded-base bg-primary px-5 py-3 font-semibold text-primary-ink disabled:opacity-50">
                <MoonStar className="h-4 w-4" aria-hidden />{t('audit.run')}
              </button>
            )}
            {ready && today !== null && (
              <button type="button" onClick={close} disabled={busy || st.violations > 0} className="rounded-base bg-primary px-5 py-3 font-semibold text-primary-ink disabled:opacity-40">
                {t('audit.close', { day: day(today, 'weekday') })}
              </button>
            )}
          </div>
        </div>
      )}
      {!denied && <AutoAudit reloadKey={clockTick} onClosed={load} />}
    </div>
  )
}

const fieldCls = 'mt-1.5 w-full rounded-base border border-field bg-bg px-3 py-2.5 text-ink'

/** The night audit by itself: the hotel's time zone, the local time it runs at, on or off, and what it last did. */
function AutoAudit({ reloadKey, onClosed }: { reloadKey: number; onClosed(): void }) {
  const { api, t, tr } = useApp()
  const { day } = useFormat()
  const [clock, setClock] = useState<HotelClock | null>(null)
  const [zone, setZone] = useState(DEFAULT_ZONE[0])
  const [otherName, setOtherName] = useState('')
  const [otherRule, setOtherRule] = useState('')
  const [at, setAt] = useState('03:00')
  const [auto, setAuto] = useState(true)
  const [busy, setBusy] = useState(false)

  const read = useCallback(async () => {
    try {
      const c = await api.hotelClock()
      setClock((prev) => {
        // the automatic audit closed a day since the last read: the screen above moves with it
        if (prev && c.businessDate !== prev.businessDate) onClosed()
        return c
      })
      return c
    } catch { return null }
  }, [api, onClosed])

  useEffect(() => {
    read().then((c) => {
      if (!c?.set) return
      if (ruleOf(c.zoneName) === c.zoneRule) setZone(c.zoneName)
      else { setZone('other'); setOtherName(c.zoneName); setOtherRule(c.zoneRule) }
      setAt(hhmmOf(c.auditAt)); setAuto(c.auto)
    })
  }, [read, reloadKey])
  // the hotel's time and the automatic audit's progress, kept current while the screen is open
  useEffect(() => { const h = window.setInterval(() => { void read() }, 30_000); return () => window.clearInterval(h) }, [read])

  const zoneName = zone === 'other' ? otherName.trim() : zone
  const zoneRule = zone === 'other' ? otherRule.trim() : (ruleOf(zone) ?? '')
  const auditAt = secondsOf(at)
  const changed = !clock?.set || clock.zoneName !== zoneName || clock.zoneRule !== zoneRule || clock.auditAt !== auditAt || clock.auto !== auto
  const valid = zoneName !== '' && zoneRule !== '' && auditAt !== null

  const save = async () => {
    if (!valid || auditAt === null) return
    setBusy(true)
    try { await api.setHotelClock({ zoneName, zoneRule, auditAt, auto }); toast.success(t('auto.saved')); await read() }
    catch (e) { toast.error(e instanceof Refused ? tr(e.reason) : t('err.generic')) }
    finally { setBusy(false) }
  }

  const hotelTime = (when: Date) => {
    try { return when.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', timeZone: clock?.zoneName || undefined }) }
    catch { return when.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) }
  }
  const status = (() => {
    if (!clock?.set) return t('auto.notSet')
    if (!clock.auto) return t('auto.off')
    if (clock.dueThrough !== null && clock.businessDate <= clock.dueThrough) return t('auto.due', { day: day(clock.businessDate, 'weekday') })
    return t('auto.next', { day: day(clock.businessDate, 'weekday'), time: hhmmOf(clock.auditAt), next: day(clock.businessDate + 1, 'weekday') })
  })()

  return (
    <section aria-labelledby="auto-title" className="mt-6 max-w-2xl rounded-lg border border-line bg-surface p-6 shadow-1">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h2 id="auto-title" className="t-h2 text-ink">{t('auto.title')}</h2>
          <p className="mt-1 t-small text-muted">{t('auto.lead')}</p>
        </div>
        <button type="button" role="switch" aria-checked={auto} aria-label={t('auto.on')} onClick={() => setAuto((v) => !v)}
          className={`relative mt-1 h-7 w-12 shrink-0 rounded-full border transition-colors ${auto ? 'border-primary bg-primary' : 'border-field bg-surface-2'}`}>
          <span className={`absolute top-0.5 h-5 w-5 rounded-full bg-bg shadow-1 transition-all ${auto ? 'start-6' : 'start-0.5'}`} />
        </button>
      </div>
      <div className="mt-5 grid gap-4 sm:grid-cols-2">
        <label className="block t-small text-muted">{t('auto.at')}
          <input type="time" step={60} value={at} onChange={(e) => setAt(e.currentTarget.value)} className={`${fieldCls} nums`} />
        </label>
        <label className="block t-small text-muted">{t('auto.zone')}
          <select value={zone} onChange={(e) => setZone(e.currentTarget.value)} className={fieldCls}>
            {ZONES.map(([n]) => <option key={n} value={n}>{n.replace('_', ' ')}</option>)}
            <option value="other">{t('auto.other')}</option>
          </select>
        </label>
        {zone === 'other' && (<>
          <label className="block t-small text-muted">{t('auto.otherName')}
            <input value={otherName} onChange={(e) => setOtherName(e.currentTarget.value)} placeholder="Asia/Kolkata" className={fieldCls} dir="ltr" />
          </label>
          <label className="block t-small text-muted">{t('auto.otherRule')}
            <input value={otherRule} onChange={(e) => setOtherRule(e.currentTarget.value)} placeholder="IST-5:30" className={`${fieldCls} font-mono`} dir="ltr" />
          </label>
        </>)}
      </div>
      <div className="mt-5 space-y-1.5 t-small" aria-live="polite">
        {clock?.set && <p className="text-ink">{t('auto.now', { when: `${day(clock.localDay, 'weekday')}, ${hhmmOf(clock.localSecond)} ${clock.zoneNow}` })}</p>}
        <p className="text-ink">{status}</p>
        {clock?.last && (clock.last.ok
          ? <p className="text-muted">{t('auto.last', { when: hotelTime(clock.last.at), what: t(`auto.act.${clock.last.act}` as 'auto.act.closeDay', { day: day(clock.last.day, 'weekday') }) })}</p>
          : <p className="flex items-start gap-2 font-semibold text-danger" role="alert"><TriangleAlert className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />{t('auto.stopped', { day: day(clock.last.day, 'weekday'), reason: clock.last.reason })}</p>)}
      </div>
      <div className="mt-5">
        <button type="button" onClick={save} disabled={busy || !valid || !changed} className="rounded-base bg-primary px-5 py-3 font-semibold text-primary-ink disabled:opacity-40">
          {t('auto.save')}
        </button>
      </div>
    </section>
  )
}
