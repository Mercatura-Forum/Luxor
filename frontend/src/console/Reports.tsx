import { useCallback, useEffect, useMemo, useState } from 'react'
import { toast } from '../lib/toast'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import { Refused, type DayFiguresView, type NightRevenue, type PlanView, type RoomTypeView } from '../api/types'
import type { Day } from '../lib/days'
import { StaffOnly } from './StaffOnly'
import { periodOf, ratio } from '../lib/figures'

/**
 * REPORTS: the hotel's figures as the night audit wrote them, day by day, over the last nights; room
 * revenue by room type and rate plan over the same nights; and what is on the books for the nights
 * ahead. Occupancy is rooms sold over rooms in service; ADR is room revenue over rooms sold; RevPAR is
 * room revenue over rooms in service. Room revenue is the night's room charges before tax.
 */
const PAST = [7, 30] as const
const AHEAD = [14, 30] as const

export default function Reports() {
  const { api, t, tr, locale } = useApp()
  const { money, day, num } = useFormat()
  const [today, setToday] = useState<Day | null>(null)
  const [past, setPast] = useState<number>(7)
  const [ahead, setAhead] = useState<number>(14)
  const [figs, setFigs] = useState<DayFiguresView[] | null>(null)
  const [revenue, setRevenue] = useState<NightRevenue[]>([])
  const [books, setBooks] = useState<NightRevenue[] | null>(null)
  const [types, setTypes] = useState<RoomTypeView[]>([])
  const [plans, setPlans] = useState<PlanView[]>([])
  const [rooms, setRooms] = useState(0)
  const [denied, setDenied] = useState(false)
  const pct = useMemo(() => new Intl.NumberFormat(locale, { style: 'percent', maximumFractionDigits: 1 }), [locale])

  useEffect(() => { api.property().then((p) => setToday(p.businessDate)) }, [api])
  useEffect(() => { Promise.all([api.roomTypes(), api.staffPlans()]).then(([rt, pl]) => { setTypes(rt); setPlans(pl) }).catch(() => {}) }, [api])

  const fail = useCallback((e: unknown) => {
    if (e instanceof Refused && e.kind === 'notAuthorised') setDenied(true); else toast.error(t('err.generic'))
  }, [t])

  useEffect(() => {
    if (today === null) return
    setFigs(null)
    Promise.all([api.dayFigures(today - past, past), api.dayRevenue(today - past, past)])
      .then(([f, r]) => { setFigs(f); setRevenue(r) }).catch(fail)
  }, [api, today, past, fail])

  useEffect(() => {
    if (today === null) return
    setBooks(null)
    Promise.all([api.onTheBooks(today, ahead), api.dayFigures(today - 1, 1), api.housekeeping()])
      .then(([b, last, board]) => {
        setBooks(b)
        // the rooms in service the forecast is measured against: the last audited night's, or the board's
        setRooms(last.length ? last[0].roomsTotal - last[0].roomsOut : board.filter((x) => !x.outOfOrder).length)
      }).catch(fail)
  }, [api, today, ahead, fail])

  if (denied) return <StaffOnly />
  const closed = (figs ?? []).filter((f) => f.closed)
  const period = periodOf(closed)
  const typeName = (id: number) => tr(types.find((x) => x.id === id)?.name) || `#${id}`
  const planName = (id: number) => tr(plans.find((x) => x.id === id)?.name) || `#${id}`
  const byTypePlan = [...revenue.reduce((m, r) => {
    const k = `${r.roomTypeId}/${r.planId}`
    const was = m.get(k) ?? { roomTypeId: r.roomTypeId, planId: r.planId, roomNights: 0, revenue: 0n }
    m.set(k, { ...was, roomNights: was.roomNights + r.roomNights, revenue: was.revenue + r.revenue })
    return m
  }, new Map<string, { roomTypeId: number; planId: number; roomNights: number; revenue: bigint }>()).values()].sort((a, b) => (b.revenue > a.revenue ? 1 : b.revenue < a.revenue ? -1 : 0))
  const nights = today === null ? [] : Array.from({ length: ahead }, (_, i) => today + i)
  const onBooks = (d: Day) => (books ?? []).filter((r) => r.day === d).reduce((a, r) => ({ n: a.n + r.roomNights, v: a.v + r.revenue }), { n: 0, v: 0n })
  const aheadTotal = nights.reduce((a, d) => { const x = onBooks(d); return { n: a.n + x.n, v: a.v + x.v } }, { n: 0, v: 0n })

  const Toggle = ({ value, options, set, label }: { value: number; options: readonly number[]; set(v: number): void; label: (n: number) => string }) => (
    <div className="inline-flex rounded-base border border-line p-0.5" role="group">
      {options.map((o) => (
        <button key={o} type="button" aria-pressed={value === o} onClick={() => set(o)}
          className={`rounded-[6px] px-3 py-1.5 t-small font-semibold ${value === o ? 'bg-primary text-primary-ink' : 'text-ink'}`}>{label(o)}</button>
      ))}
    </div>
  )
  const Tile = ({ label, value, sub }: { label: string; value: string; sub?: string }) => (
    <div className="rounded-lg border border-line bg-surface p-4">
      <p className="t-small text-muted">{label}</p>
      <p className="mt-1 font-display text-3xl nums text-ink">{value}</p>
      {sub && <p className="t-small mt-1 nums text-muted">{sub}</p>}
    </div>
  )

  return (
    <div className="mx-auto max-w-[1240px]">
      <h1 className="t-h1 mt-1 text-ink">{t('rep.title')}</h1>
      <p className="mt-1 max-w-2xl text-muted">{t('rep.lede')}</p>

      <section aria-labelledby="rep-past" className="mt-8">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <h2 id="rep-past" className="t-h2 text-ink">{t('rep.audited')}</h2>
          <Toggle value={past} options={PAST} set={setPast} label={(n) => t('rep.lastNights', { n })} />
        </div>
        {figs === null ? <div className="skeleton mt-4 h-40 rounded-lg" aria-hidden /> : closed.length === 0 ? (
          <p className="mt-4 rounded-lg border border-dashed border-line p-6 text-muted">{t('rep.noneAudited')}</p>
        ) : (
          <div data-reports={closed.length}>
            <div className="mt-4 grid grid-cols-2 gap-3 lg:grid-cols-4">
              <Tile label={t('rep.occupancy')} value={pct.format(period.occupancy)} sub={t('rep.soldOf', { sold: num(period.sold), rooms: num(period.available) })} />
              <Tile label={t('rep.adr')} value={money(period.adr, { whole: true })} />
              <Tile label={t('rep.revpar')} value={money(period.revpar, { whole: true })} />
              <Tile label={t('rep.revenue')} value={money(period.revenue, { whole: true })} sub={t('rep.beforeTax')} />
            </div>

            <figure className="mt-6 rounded-lg border border-line bg-surface p-4">
              <figcaption className="t-small font-semibold text-ink">{t('rep.occByNight')}</figcaption>
              <div className="mt-3 flex h-36 items-end gap-[2px] border-b border-line" role="img" aria-label={t('rep.occByNight')}>
                {closed.map((f) => {
                  const o = ratio(f.roomsSold, f.roomsTotal - f.roomsOut)
                  return (
                    <div key={f.day} className="group relative flex h-full flex-1 items-end" title={`${day(f.day, 'weekday')}: ${pct.format(o)}`}>
                      <div className="w-full rounded-t-[4px] bg-primary" style={{ height: `${Math.max(1, o * 100)}%` }} />
                    </div>
                  )
                })}
              </div>
              <div className="mt-1 flex justify-between t-small nums text-muted"><span>{day(closed[0].day)}</span><span>{day(closed[closed.length - 1].day)}</span></div>
            </figure>

            <div className="mt-6 overflow-x-auto rounded-lg border border-line bg-surface">
              <table className="w-full min-w-[820px] text-start">
                <thead>
                  <tr className="border-b border-line t-small text-muted">
                    <th scope="col" className="p-3 text-start font-normal">{t('rep.night')}</th>
                    <th scope="col" className="p-3 text-end font-normal">{t('rep.occupancy')}</th>
                    <th scope="col" className="p-3 text-end font-normal">{t('rep.adr')}</th>
                    <th scope="col" className="p-3 text-end font-normal">{t('rep.revpar')}</th>
                    <th scope="col" className="p-3 text-end font-normal">{t('rep.revenue')}</th>
                    <th scope="col" className="p-3 text-end font-normal">{t('rep.arrivals')}</th>
                    <th scope="col" className="p-3 text-end font-normal">{t('rep.noShows')}</th>
                    <th scope="col" className="p-3 text-end font-normal">{t('rep.pickup')}</th>
                  </tr>
                </thead>
                <tbody>
                  {[...closed].reverse().map((f) => {
                    const avail = f.roomsTotal - f.roomsOut
                    return (
                      <tr key={f.day} className="border-t border-line/60 nums">
                        <th scope="row" className="whitespace-nowrap p-3 text-start font-normal text-ink">{day(f.day, 'weekday')}</th>
                        <td className="p-3 text-end text-ink">{pct.format(ratio(f.roomsSold, avail))} <span className="t-small text-muted">({num(f.roomsSold)}/{num(avail)})</span></td>
                        <td className="p-3 text-end text-ink">{f.roomsSold ? money(f.roomRevenue / BigInt(f.roomsSold), { whole: true }) : '–'}</td>
                        <td className="p-3 text-end text-ink">{avail ? money(f.roomRevenue / BigInt(avail), { whole: true }) : '–'}</td>
                        <td className="p-3 text-end text-ink">{money(f.roomRevenue, { whole: true })}</td>
                        <td className="p-3 text-end text-ink">{num(f.arrivals)}</td>
                        <td className="p-3 text-end text-ink">{num(f.noShows)}</td>
                        <td className="p-3 text-end text-ink">{t('rep.pickupCell', { b: num(f.pickupBookings), n: num(f.pickupNights) })} <span className="t-small text-muted">{money(f.pickupRevenue, { whole: true })}</span></td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
            <p className="t-small mt-2 text-muted">{t('rep.pickupHint')}</p>

            <h3 className="t-eyebrow mt-8 text-muted">{t('rep.byTypePlan')}</h3>
            {byTypePlan.length === 0 ? <p className="mt-3 text-muted">{t('rep.noRevenue')}</p> : (
              <div className="mt-3 overflow-x-auto rounded-lg border border-line bg-surface">
                <table className="w-full min-w-[560px]">
                  <thead>
                    <tr className="border-b border-line t-small text-muted">
                      <th scope="col" className="p-3 text-start font-normal">{t('rep.type')}</th>
                      <th scope="col" className="p-3 text-start font-normal">{t('rep.plan')}</th>
                      <th scope="col" className="p-3 text-end font-normal">{t('rep.roomNights')}</th>
                      <th scope="col" className="p-3 text-end font-normal">{t('rep.revenue')}</th>
                      <th scope="col" className="p-3 text-end font-normal">{t('rep.adr')}</th>
                      <th scope="col" className="p-3 text-end font-normal">{t('rep.share')}</th>
                    </tr>
                  </thead>
                  <tbody>
                    {byTypePlan.map((r) => (
                      <tr key={`${r.roomTypeId}/${r.planId}`} className="border-t border-line/60 nums">
                        <th scope="row" className="p-3 text-start font-normal text-ink">{typeName(r.roomTypeId)}</th>
                        <td className="p-3 text-ink">{planName(r.planId)}</td>
                        <td className="p-3 text-end text-ink">{num(r.roomNights)}</td>
                        <td className="p-3 text-end text-ink">{money(r.revenue, { whole: true })}</td>
                        <td className="p-3 text-end text-ink">{money(r.revenue / BigInt(Math.max(1, r.roomNights)), { whole: true })}</td>
                        <td className="p-3 text-end text-ink">{pct.format(period.revenue > 0n ? Number((r.revenue * 10_000n) / period.revenue) / 10_000 : 0)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        )}
      </section>

      <section aria-labelledby="rep-ahead" className="mt-12">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <h2 id="rep-ahead" className="t-h2 text-ink">{t('rep.onBooks')}</h2>
          <Toggle value={ahead} options={AHEAD} set={setAhead} label={(n) => t('rep.nextNights', { n })} />
        </div>
        <p className="mt-1 max-w-2xl t-small text-muted">{t('rep.onBooksHint')}</p>
        {books === null ? <div className="skeleton mt-4 h-40 rounded-lg" aria-hidden /> : (
          <div data-on-books={nights.length}>
            <div className="mt-4 grid grid-cols-2 gap-3 lg:grid-cols-3">
              <Tile label={t('rep.roomNights')} value={num(aheadTotal.n)} sub={t('rep.ofAvailable', { n: num(rooms * nights.length) })} />
              <Tile label={t('rep.occupancy')} value={pct.format(ratio(aheadTotal.n, rooms * nights.length))} />
              <Tile label={t('rep.revenue')} value={money(aheadTotal.v, { whole: true })} sub={aheadTotal.n ? t('rep.adrIs', { v: money(aheadTotal.v / BigInt(aheadTotal.n), { whole: true }) }) : undefined} />
            </div>
            <div className="mt-4 overflow-x-auto rounded-lg border border-line bg-surface">
              <table className="w-full min-w-[520px]">
                <thead>
                  <tr className="border-b border-line t-small text-muted">
                    <th scope="col" className="p-3 text-start font-normal">{t('rep.night')}</th>
                    <th scope="col" className="p-3 text-end font-normal">{t('rep.roomNights')}</th>
                    <th scope="col" className="p-3 text-end font-normal">{t('rep.occupancy')}</th>
                    <th scope="col" className="p-3 text-end font-normal">{t('rep.revenue')}</th>
                    <th scope="col" className="p-3 text-end font-normal">{t('rep.adr')}</th>
                  </tr>
                </thead>
                <tbody>
                  {nights.map((d) => {
                    const x = onBooks(d)
                    return (
                      <tr key={d} className="border-t border-line/60 nums">
                        <th scope="row" className="whitespace-nowrap p-3 text-start font-normal text-ink">{day(d, 'weekday')}</th>
                        <td className="p-3 text-end text-ink">{num(x.n)}</td>
                        <td className="p-3 text-end text-ink">{pct.format(ratio(x.n, rooms))}</td>
                        <td className="p-3 text-end text-ink">{money(x.v, { whole: true })}</td>
                        <td className="p-3 text-end text-ink">{x.n ? money(x.v / BigInt(x.n), { whole: true }) : '–'}</td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
          </div>
        )}
      </section>
    </div>
  )
}
