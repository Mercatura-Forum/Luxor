import { useCallback, useEffect, useState, type FormEvent } from 'react'
import { useSearchParams } from 'react-router-dom'
import { Copy, UsersRound } from 'lucide-react'
import { toast } from '../lib/toast'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import { fromIso, iso, type Day } from '../lib/days'
import { Refused, type BlockNightView, type BlockView, type CompanyView, type Offer, type PlanView, type RoomTypeView, type RoomingRow, type StaffBookResult, type StayRequest } from '../api/types'
import { manageLink } from '../pages/Confirmation'
import { StaffOnly } from './StaffOnly'

type Draft = { id: number; name: string; companyId: number; roomTypeId: number; planId: number; arrival: string; nights: number; rooms: number; cutoff: string }

/**
 * GROUPS: rooms of one type on one rate held off sale for a group (a wedding, a tour, a conference)
 * until a cut-off day, when the night audit gives what is not picked up back to sale. Revenue makes,
 * grows and releases a block; the desk picks the group's guests up from it, through the night's
 * restrictions, at the block's rate. A cancelled pickup goes back to the block while it is open.
 */
export default function Groups() {
  const { api, t, tr } = useApp()
  const { day, num } = useFormat()
  const [today, setToday] = useState<Day | null>(null)
  const [blocks, setBlocks] = useState<BlockView[] | null>(null)
  const [types, setTypes] = useState<RoomTypeView[]>([])
  const [plans, setPlans] = useState<PlanView[]>([])
  const [companies, setCompanies] = useState<CompanyView[]>([])
  const [draft, setDraft] = useState<Draft | null>(null)
  // `?open=<id>` opens a block's guests and nights, so a link can point at one group
  const [params] = useSearchParams()
  const [open, setOpen] = useState<number | null>(Number(params.get('open')) || null)
  const [busy, setBusy] = useState(false)
  const [denied, setDenied] = useState(false)

  const load = useCallback(async () => {
    try { setBlocks(await api.blocks()) }
    catch (e) { if (e instanceof Refused && e.kind === 'notAuthorised') setDenied(true); else toast.error(t('err.generic')) }
  }, [api, t])
  useEffect(() => {
    load()
    api.property().then((p) => setToday(p.businessDate)).catch(() => {})
    api.roomTypes().then(setTypes).catch(() => setTypes([]))
    api.staffPlans().then(setPlans).catch(() => setPlans([]))
    // the desk may not read the companies: a block then shows the company by number
    api.companies().then(setCompanies).catch(() => setCompanies([]))
  }, [api, load])

  const fresh = (): Draft => ({ id: 0, name: '', companyId: 0, roomTypeId: types[0]?.id ?? 0, planId: plans[0]?.id ?? 0,
    arrival: today !== null ? iso(today + 30) : '', nights: 2, rooms: 5, cutoff: today !== null ? iso(today + 16) : '' })
  const d = draft ?? fresh()
  const set = (x: Partial<Draft>) => setDraft({ ...d, ...x })
  const arrival = fromIso(d.arrival)
  const cutoff = fromIso(d.cutoff)
  const ready = d.name.trim() !== '' && d.roomTypeId > 0 && d.planId > 0 && arrival !== null && cutoff !== null && d.nights >= 1 && d.rooms >= 1
  const save = async (e: FormEvent) => {
    e.preventDefault()
    if (!ready) return
    setBusy(true)
    try {
      await api.upsertBlock(d.id, { name: d.name.trim(), companyId: d.companyId, roomTypeId: d.roomTypeId, planId: d.planId, arrival: arrival!, nights: d.nights, rooms: d.rooms, cutoff: cutoff! })
      toast.success(t('groups.saved', { name: d.name.trim() })); setDraft(null); await load()
    } catch (err) { toast.error(err instanceof Refused ? tr(err.reason) : t('err.generic')) }
    finally { setBusy(false) }
  }
  const release = async (b: BlockView) => {
    if (!window.confirm(t('groups.releaseAsk', { name: b.name }))) return
    setBusy(true)
    try { await api.releaseBlock(b.id); toast.success(t('groups.released', { name: b.name })); await load() }
    catch (err) { toast.error(err instanceof Refused ? tr(err.reason) : t('err.generic')) }
    finally { setBusy(false) }
  }
  const typeName = (id: number) => tr(types.find((x) => x.id === id)?.name) || `#${id}`
  const planName = (id: number) => tr(plans.find((x) => x.id === id)?.name) || `#${id}`
  const companyName = (id: number) => companies.find((c) => c.id === id)?.name ?? `#${id}`
  const field = 'mt-1 block w-full rounded-base border border-field bg-bg px-3 py-2.5 text-ink'
  if (denied) return <StaffOnly />
  return (
    <div className="mx-auto max-w-[1240px]">
      <h1 className="t-h1 mt-1 text-ink">{t('groups.title')}</h1>
      <p className="t-small mt-2 max-w-2xl text-muted">{t('groups.lead')}</p>
      <div className="mt-8 grid gap-8 lg:grid-cols-[minmax(0,1fr)_360px]">
        <ul className="space-y-3" data-blocks>
          {blocks === null && [0, 1].map((i) => <li key={i} className="skeleton h-24 rounded-lg" aria-hidden />)}
          {blocks?.length === 0 && <li className="rounded-lg border border-dashed border-line p-6 text-muted">{t('groups.none')}</li>}
          {blocks?.map((b) => (
            <li key={b.id} data-block={b.id} data-block-open={b.open ? 'yes' : 'no'} className={`rounded-lg border border-line bg-surface p-4 ${b.open ? '' : 'opacity-70'}`}>
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div className="min-w-0">
                  <p className="font-semibold text-ink">{b.name}</p>
                  <p className="t-small text-muted">{typeName(b.roomTypeId)} · {planName(b.planId)}{b.companyId ? ` · ${companyName(b.companyId)}` : ''}</p>
                  <p className="t-small text-muted"><bdi>{t('groups.dates', { from: day(b.arrival), to: day(b.departure), n: num(b.rooms) })}</bdi></p>
                  <p className="t-small text-ink" data-block-picked={b.pickedNights}>
                    {t('groups.progress', { picked: num(b.pickedNights), all: num(b.roomNights), held: num(b.heldNights) })}</p>
                  <p className={`t-small ${b.open ? 'text-muted' : 'font-semibold text-ink'}`}>
                    {b.open ? <bdi>{t('groups.cutoff', { day: day(b.cutoff) })}</bdi> : t('groups.releasedState')}</p>
                </div>
                <div className="flex flex-wrap gap-3">
                  <button type="button" onClick={() => setOpen(open === b.id ? null : b.id)} aria-expanded={open === b.id}
                    className="t-small font-semibold text-ink underline underline-offset-4">{open === b.id ? t('groups.hide') : t('groups.openList')}</button>
                  {b.open && <button type="button" onClick={() => setDraft({ id: b.id, name: b.name, companyId: b.companyId, roomTypeId: b.roomTypeId, planId: b.planId,
                    arrival: iso(b.arrival), nights: b.departure - b.arrival, rooms: b.rooms, cutoff: iso(b.cutoff) })}
                    className="t-small font-semibold text-ink underline underline-offset-4">{t('extras.edit')}</button>}
                  {b.open && <button type="button" disabled={busy} onClick={() => release(b)} className="t-small font-semibold text-danger underline underline-offset-4">{t('groups.release')}</button>}
                </div>
              </div>
              {open === b.id && <BlockDetail block={b} onChanged={load} />}
            </li>
          ))}
        </ul>
        <form onSubmit={save} className="h-fit space-y-4 rounded-lg border border-line bg-surface p-5" data-block-form>
          <h3 className="t-h2 text-ink">{d.id ? t('extras.editTitle', { name: d.name }) : t('groups.add')}</h3>
          <label className="block"><span className="font-semibold text-ink">{t('groups.name')}</span>
            <input name="blockName" value={d.name} maxLength={120} onChange={(e) => set({ name: e.currentTarget.value })} className={field} /></label>
          <label className="block"><span className="font-semibold text-ink">{t('groups.company')}</span>
            <select name="blockCompany" value={d.companyId} disabled={d.id > 0} onChange={(e) => set({ companyId: Number(e.currentTarget.value) })} className={field}>
              <option value={0}>{t('groups.noCompany')}</option>
              {companies.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
            </select></label>
          <label className="block"><span className="font-semibold text-ink">{t('groups.roomType')}</span>
            <select name="blockType" value={d.roomTypeId} disabled={d.id > 0} onChange={(e) => set({ roomTypeId: Number(e.currentTarget.value) })} className={field}>
              {types.map((x) => <option key={x.id} value={x.id}>{tr(x.name)}</option>)}
            </select></label>
          <label className="block"><span className="font-semibold text-ink">{t('groups.plan')}</span>
            <select name="blockPlan" value={d.planId} disabled={d.id > 0} onChange={(e) => set({ planId: Number(e.currentTarget.value) })} className={field}>
              {plans.map((p) => <option key={p.id} value={p.id}>{tr(p.name)} · {p.code}</option>)}
            </select></label>
          <div className="grid grid-cols-2 gap-2">
            <label className="block"><span className="font-semibold text-ink">{t('groups.arrival')}</span>
              <input type="date" name="blockArrival" value={d.arrival} disabled={d.id > 0} onChange={(e) => set({ arrival: e.currentTarget.value })} className={field} dir="ltr" /></label>
            <label className="block"><span className="font-semibold text-ink">{t('book.nights')}</span>
              <input type="number" name="blockNights" min={1} max={31} value={d.nights} disabled={d.id > 0} onChange={(e) => set({ nights: Math.max(1, Number(e.currentTarget.value) || 1) })} className={`${field} nums`} /></label>
          </div>
          {d.id > 0 && <p className="t-small text-muted">{t('groups.kept')}</p>}
          <label className="block"><span className="font-semibold text-ink">{t('groups.rooms')}</span>
            <input type="number" name="blockRooms" min={1} value={d.rooms} onChange={(e) => set({ rooms: Math.max(1, Number(e.currentTarget.value) || 1) })} className={`${field} nums`} /></label>
          <label className="block"><span className="font-semibold text-ink">{t('groups.cutoffField')}</span>
            <input type="date" name="blockCutoff" value={d.cutoff} onChange={(e) => set({ cutoff: e.currentTarget.value })} className={field} dir="ltr" />
            <span className="t-small mt-1 block text-muted">{t('groups.cutoffHint')}</span></label>
          <div className="flex gap-2">
            <button type="submit" disabled={busy || !ready} className="flex-1 rounded-base bg-primary px-5 py-3 font-semibold text-primary-ink disabled:opacity-40">{t('extras.save')}</button>
            {draft !== null && <button type="button" onClick={() => setDraft(null)} className="rounded-base border border-line px-4 py-3 font-semibold text-ink">{t('console.cancel')}</button>}
          </div>
        </form>
      </div>
    </div>
  )
}

/** One block opened: its nights, its rooming list, and the desk's form to pick a guest up from it. */
function BlockDetail({ block, onChanged }: { block: BlockView; onChanged: () => Promise<void> }) {
  const { api, t, tr, lang } = useApp()
  const { money, day, num } = useFormat()
  const [nights, setNights] = useState<BlockNightView[] | null>(null)
  const [list, setList] = useState<RoomingRow[] | null>(null)
  const [arrival, setArrival] = useState(iso(block.arrival))
  const [stay, setStay] = useState(block.departure - block.arrival)
  const [rooms, setRooms] = useState(1)
  const [adults, setAdults] = useState(2)
  const [children, setChildren] = useState(0)
  const [offer, setOffer] = useState<Offer | null>(null)
  const [name, setName] = useState('')
  const [email, setEmail] = useState('')
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)
  const [done, setDone] = useState<StaffBookResult | null>(null)
  const read = useCallback(async () => {
    try { const [n, l] = await Promise.all([api.blockNights(block.id), api.roomingList(block.id)]); setNights(n); setList(l) }
    catch (e) { toast.error(e instanceof Refused ? tr(e.reason) : t('err.generic')) }
  }, [api, block.id, t, tr])
  useEffect(() => { read() }, [read])
  const from = fromIso(arrival)
  const req: StayRequest | null = from === null ? null : { arrival: from, nights: stay, rooms, adults, children }
  const reqKey = JSON.stringify(req)
  useEffect(() => { setOffer(null) }, [reqKey])
  const price = async () => {
    if (!req) return
    setBusy(true)
    try { setOffer(await api.blockQuote(block.id, req)) }
    catch (e) { toast.error(e instanceof Refused ? tr(e.reason) : t('err.generic')) }
    finally { setBusy(false) }
  }
  const pick = async () => {
    if (!req || !offer) return
    setBusy(true)
    try {
      const r = await api.pickUp(block.id, offer, req, { name, email, note, lang })
      setDone(r); setOffer(null); setName(''); setEmail(''); setNote('')
      toast.success(t('book.done', { ref: r.booking.ref }))
      await Promise.all([read(), onChanged()])
    } catch (e) { toast.error(e instanceof Refused ? tr(e.reason) : t('err.generic')) }
    finally { setBusy(false) }
  }
  const fieldCls = 'rounded-base border border-field bg-bg px-3 py-2 text-ink'
  const link = done ? manageLink(done.booking.ref, done.manageSecret) : ''
  return (
    <div className="mt-4 space-y-5 border-t border-line pt-4">
      <div className="overflow-x-auto">
        <table className="t-small w-full min-w-[320px] text-start" data-block-nights>
          <caption className="sr-only">{t('groups.nightsCaption', { name: block.name })}</caption>
          <thead><tr className="text-muted"><th scope="col" className="py-1 text-start font-semibold">{t('groups.night')}</th>
            <th scope="col" className="py-1 text-end font-semibold">{t('groups.picked')}</th><th scope="col" className="py-1 text-end font-semibold">{t('groups.held')}</th></tr></thead>
          <tbody>
            {nights === null && <tr><td colSpan={3}><div className="skeleton h-6 rounded-base" aria-hidden /></td></tr>}
            {nights?.map((n) => (
              <tr key={n.day} className="border-t border-line/60"><td className="py-1 text-ink"><bdi>{day(n.day, 'weekday')}</bdi></td>
                <td className="py-1 text-end text-ink nums">{num(n.picked)}</td><td className="py-1 text-end text-ink nums">{num(n.held)}</td></tr>
            ))}
          </tbody>
        </table>
      </div>

      <section aria-labelledby={`rooming-${block.id}`}>
        <h4 id={`rooming-${block.id}`} className="font-semibold text-ink">{t('groups.rooming')}</h4>
        <ul className="mt-2 space-y-1" data-rooming-list>
          {list?.length === 0 && <li className="t-small text-muted">{t('groups.roomingNone')}</li>}
          {list?.map((r) => (
            <li key={r.id} data-rooming={r.ref} className="t-small flex flex-wrap items-center justify-between gap-2 rounded-base border border-line/70 px-3 py-2">
              <span className="text-ink"><span className="font-mono" dir="ltr">{r.ref}</span> · {r.guestName} · <bdi>{day(r.arrival)}</bdi> → <bdi>{day(r.departure)}</bdi> · {t('groups.nRooms', { n: num(r.rooms) })}</span>
              <span className="text-muted">{t(`manage.status.${r.status}` as 'manage.status.confirmed')}{r.outstanding > 0n ? ` · ${t('book.owes', { amount: money(r.outstanding) })}` : ''}</span>
            </li>
          ))}
        </ul>
      </section>

      {done && (
        <div className="rounded-base border border-line bg-surface-2 p-3" data-pickup-done={done.booking.ref}>
          <p className="t-small font-semibold text-ink">{t('groups.pickedUp', { ref: done.booking.ref, name: done.booking.guestName })}</p>
          <p className="t-small mt-1 text-muted">{t('book.linkLead')}</p>
          <div className="mt-2 flex flex-wrap items-center gap-2">
            <code dir="ltr" className="min-w-0 flex-1 break-all rounded-base border border-line bg-surface px-3 py-2 text-xs text-ink">{link}</code>
            <button type="button" onClick={() => { navigator.clipboard?.writeText(link).then(() => toast.success(t('book.copied')), () => toast.error(t('err.generic'))) }}
              className="inline-flex items-center gap-2 rounded-base border border-line px-3 py-2 t-small font-semibold text-ink"><Copy className="h-4 w-4" aria-hidden />{t('book.copy')}</button>
          </div>
        </div>
      )}

      {block.open && (
        <section aria-labelledby={`pickup-${block.id}`} data-pickup-form>
          <h4 id={`pickup-${block.id}`} className="flex items-center gap-2 font-semibold text-ink"><UsersRound className="h-4 w-4" aria-hidden />{t('groups.pickUp')}</h4>
          <p className="t-small mt-1 text-muted">{t('groups.pickUpLead')}</p>
          <div className="mt-3 grid grid-cols-2 gap-2 sm:grid-cols-5">
            <label className="col-span-2 flex flex-col gap-1 sm:col-span-1"><span className="t-small font-semibold text-ink">{t('book.arrival')}</span>
              <input type="date" value={arrival} min={iso(block.arrival)} max={iso(block.departure - 1)} onChange={(e) => setArrival(e.currentTarget.value)} className={`${fieldCls} nums`} dir="ltr" /></label>
            {([['book.nights', stay, setStay, 1], ['book.rooms', rooms, setRooms, 1], ['book.adults', adults, setAdults, 1], ['book.children', children, setChildren, 0]] as const).map(([k, v, setV, min]) => (
              <label key={k} className="flex flex-col gap-1"><span className="t-small font-semibold text-ink">{t(k)}</span>
                <input type="number" inputMode="numeric" min={min} max={31} value={v} onChange={(e) => setV(Math.max(min, Number(e.currentTarget.value) || min))} className={`${fieldCls} nums`} /></label>
            ))}
          </div>
          <button type="button" onClick={price} disabled={!req || busy} className="mt-3 rounded-base border border-ink px-4 py-2 font-semibold text-ink disabled:opacity-40">{t('groups.price')}</button>
          {offer && (
            <div className="mt-3 grid gap-2" data-pickup-offer>
              <p className="t-small text-ink nums">{t('groups.offer', { total: money(offer.total), left: num(offer.left) })}</p>
              <label className="flex flex-col gap-1"><span className="t-small font-semibold text-ink">{t('book.name')}</span>
                <input value={name} onChange={(e) => setName(e.currentTarget.value)} maxLength={120} autoComplete="off" className={fieldCls} /></label>
              <label className="flex flex-col gap-1"><span className="t-small font-semibold text-ink">{t('book.email')}</span>
                <input type="email" value={email} onChange={(e) => setEmail(e.currentTarget.value)} autoComplete="off" className={fieldCls} dir="ltr" /></label>
              <label className="flex flex-col gap-1"><span className="t-small font-semibold text-ink">{t('book.note')}</span>
                <input value={note} onChange={(e) => setNote(e.currentTarget.value)} maxLength={500} className={fieldCls} /></label>
              <div><button type="button" onClick={pick} disabled={busy || !name.trim()} className="rounded-base bg-primary px-4 py-2.5 font-semibold text-primary-ink disabled:opacity-40">{t('groups.pickUpGo')}</button></div>
            </div>
          )}
        </section>
      )}
    </div>
  )
}
