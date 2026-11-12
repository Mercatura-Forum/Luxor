import { useCallback, useEffect, useState, type FormEvent } from 'react'
import { toast } from '../lib/toast'
import { useApp } from '../app'
import { Refused, type CompanyView, type PlanAccessView, type PromoView, type SetupPlan } from '../api/types'
import { fromIso, iso, localToday } from '../lib/days'
import { useFormat } from '../lib/useFormat'
import { StaffOnly } from './StaffOnly'

type Draft = { id: number; code: string; name: string; active: boolean }
const blank: Draft = { id: 0, code: '', name: '', active: true }
/** A plan sold only under a promotion's code: closed, with no company. The select's value for it. */
const CODES_ONLY = -1

/**
 * RATE PRODUCTS: the companies the hotel has negotiated rates with, and who each rate plan is sold to.
 * A plan closed to a company is not shown in the public search, the public calendar or the public plan
 * list; it is sold only when the company's code is given, online or at the desk. A promotion's code opens one
 * plan sold only under codes, within its booking and stay dates and its number of bookings. Revenue's and the owner's.
 */
export default function RateProducts() {
  const { api, t, tr } = useApp()
  const { day } = useFormat()
  const [companies, setCompanies] = useState<CompanyView[] | null>(null)
  const [promos, setPromos] = useState<PromoView[]>([])
  const [access, setAccess] = useState<PlanAccessView[]>([])
  const [plans, setPlans] = useState<SetupPlan[]>([])
  const [draft, setDraft] = useState<Draft>(blank)
  const [busy, setBusy] = useState(false)
  const [denied, setDenied] = useState(false)
  const load = useCallback(async () => {
    try {
      const [c, a, p, pr] = await Promise.all([api.companies(), api.planAccess(), api.setupPlans(), api.promos()])
      setCompanies(c); setAccess(a); setPlans(p); setPromos(pr)
    } catch (e) { if (e instanceof Refused && e.kind === 'notAuthorised') setDenied(true); else toast.error(t('err.generic')) }
  }, [api, t])
  useEffect(() => { load() }, [load])

  const save = async (e: FormEvent) => {
    e.preventDefault()
    setBusy(true)
    try {
      await api.upsertCompany(draft.id, { code: draft.code.trim(), name: draft.name.trim(), active: draft.active })
      toast.success(t('products.saved', { name: draft.name.trim() })); setDraft(blank); await load()
    } catch (err) { toast.error(err instanceof Refused ? tr(err.reason) : t('err.generic')) }
    finally { setBusy(false) }
  }
  const sellTo = async (planId: number, companyId: number) => {
    setBusy(true)
    try {
      await api.setPlanAccess(planId, Math.max(companyId, 0), companyId !== 0)
      toast.success(t('products.accessSaved')); await load()
    } catch (err) { toast.error(err instanceof Refused ? tr(err.reason) : t('err.generic')) }
    finally { setBusy(false) }
  }
  const soldTo = (planId: number) => { const a = access.find((x) => x.planId === planId); return a?.closed ? (a.companyId || CODES_ONLY) : 0 }
  const companyName = (id: number) => companies?.find((c) => c.id === id)?.name ?? `#${id}`
  const field = 'mt-1 block w-full rounded-base border border-field bg-bg px-3 py-2.5 text-ink'
  const codeOk = /^[A-Z0-9-]{1,16}$/.test(draft.code.trim())
  if (denied) return <StaffOnly />
  return (
    <div className="mx-auto max-w-[1240px]">
      <h1 className="t-h1 mt-1 text-ink">{t('products.title')}</h1>
      <p className="t-small mt-2 max-w-2xl text-muted">{t('products.lead')}</p>

      <section className="mt-8" aria-labelledby="companies">
        <h2 id="companies" className="t-h2 text-ink">{t('products.companies')}</h2>
        <div className="mt-4 grid gap-8 lg:grid-cols-[minmax(0,1fr)_360px]">
          <ul className="space-y-2" data-companies>
            {companies === null && [0, 1].map((i) => <li key={i} className="skeleton h-16 rounded-lg" aria-hidden />)}
            {companies?.length === 0 && <li className="rounded-lg border border-dashed border-line p-6 text-muted">{t('products.none')}</li>}
            {companies?.map((c) => (
              <li key={c.id} data-company={c.code} className={`flex flex-wrap items-center justify-between gap-3 rounded-lg border border-line bg-surface p-4 ${c.active ? '' : 'opacity-60'}`}>
                <div className="min-w-0">
                  <p className="font-semibold text-ink">{c.name} <span className="t-small font-mono font-normal text-muted" dir="ltr">· {c.code}</span></p>
                  <p className="t-small text-muted">
                    {c.active ? t('products.onSale') : t('products.offSale')}
                    {' · '}{t('products.plansFor', { n: access.filter((a) => a.closed && a.companyId === c.id).length })}
                  </p>
                </div>
                <button type="button" onClick={() => setDraft({ id: c.id, code: c.code, name: c.name, active: c.active })} className="t-small font-semibold text-ink underline underline-offset-4">{t('extras.edit')}</button>
              </li>
            ))}
          </ul>
          <form onSubmit={save} className="h-fit space-y-4 rounded-lg border border-line bg-surface p-5">
            <h3 className="t-h2 text-ink">{draft.id ? t('extras.editTitle', { name: draft.name }) : t('products.add')}</h3>
            <label className="block"><span className="font-semibold text-ink">{t('products.code')}</span>
              <input name="code" dir="ltr" value={draft.code} maxLength={16} onChange={(e) => setDraft({ ...draft, code: e.currentTarget.value.toUpperCase() })} className={`${field} font-mono`} />
              <span className={`t-small mt-1 block ${draft.code && !codeOk ? 'text-danger' : 'text-muted'}`}>{t('products.codeHint')}</span></label>
            <label className="block"><span className="font-semibold text-ink">{t('products.name')}</span>
              <input name="name" value={draft.name} maxLength={120} onChange={(e) => setDraft({ ...draft, name: e.currentTarget.value })} className={field} /></label>
            <label className="flex items-center gap-2 text-ink"><input type="checkbox" checked={draft.active} onChange={(e) => setDraft({ ...draft, active: e.currentTarget.checked })} />{t('products.activeLabel')}</label>
            {!draft.active && <p className="t-small text-muted">{t('products.offSaleHint')}</p>}
            <div className="flex gap-2">
              <button type="submit" disabled={busy || !codeOk || !draft.name.trim()} className="flex-1 rounded-base bg-primary px-5 py-3 font-semibold text-primary-ink disabled:opacity-40">{t('extras.save')}</button>
              {draft.id > 0 && <button type="button" onClick={() => setDraft(blank)} className="rounded-base border border-line px-4 py-3 font-semibold text-ink">{t('console.cancel')}</button>}
            </div>
          </form>
        </div>
      </section>

      <Promotions promos={promos} plans={plans} soldTo={soldTo} onSaved={load} day={day} />

      <section className="mt-12" aria-labelledby="access">
        <h2 id="access" className="t-h2 text-ink">{t('products.access')}</h2>
        <p className="t-small mt-1 max-w-2xl text-muted">{t('products.accessLead')}</p>
        <ul className="mt-4 space-y-2" data-plan-access>
          {plans.map((p) => {
            const to = soldTo(p.id)
            return (
              <li key={p.id} data-plan={p.code} className={`flex flex-wrap items-center justify-between gap-3 rounded-lg border border-line bg-surface p-4 ${p.active ? '' : 'opacity-60'}`}>
                <div className="min-w-0">
                  <p className="font-semibold text-ink">{tr(p.name)} <span className="t-small font-mono font-normal text-muted" dir="ltr">· {p.code}</span></p>
                  <p className="t-small text-muted" data-sold-to={to}>
                    {to === CODES_ONLY ? t('products.soldOnlyCodes') : to ? t('products.soldOnlyTo', { name: companyName(to) }) : t('products.soldToEveryone')}</p>
                </div>
                <label className="flex items-center gap-2"><span className="sr-only">{t('products.sellTo', { plan: tr(p.name) })}</span>
                  <select value={to} disabled={busy} onChange={(e) => sellTo(p.id, Number(e.currentTarget.value))} className="rounded-base border border-field bg-bg px-3 py-2 text-ink">
                    <option value={0}>{t('products.everyone')}</option>
                    <option value={CODES_ONLY}>{t('products.onlyCodes')}</option>
                    {(companies ?? []).map((c) => <option key={c.id} value={c.id}>{t('products.onlyTo', { name: c.name })}</option>)}
                  </select></label>
              </li>
            )
          })}
        </ul>
      </section>
    </div>
  )
}

type PromoDraft = { id: number; code: string; name: string; planId: number; bookFrom: string; bookUntil: string; stayFrom: string; stayUntil: string; maxUses: string; active: boolean }

/** The promotions: each one's code, plan, dates and bookings counted, and the form that adds or changes one. */
function Promotions({ promos, plans, soldTo, onSaved, day }: {
  promos: PromoView[]; plans: SetupPlan[]; soldTo: (planId: number) => number; onSaved: () => Promise<void>; day: (d: number) => string
}) {
  const { api, t, tr } = useApp()
  const today = localToday()
  const fresh = (): PromoDraft => ({ id: 0, code: '', name: '', planId: plans.find((p) => soldTo(p.id) === CODES_ONLY)?.id ?? plans[0]?.id ?? 0,
    bookFrom: iso(today), bookUntil: iso(today + 30), stayFrom: iso(today), stayUntil: iso(today + 90), maxUses: '0', active: true })
  const [draft, setDraft] = useState<PromoDraft | null>(null)
  const [busy, setBusy] = useState(false)
  const d = draft ?? fresh()
  const set = (x: Partial<PromoDraft>) => setDraft({ ...d, ...x })
  const days = [fromIso(d.bookFrom), fromIso(d.bookUntil), fromIso(d.stayFrom), fromIso(d.stayUntil)]
  const uses = /^\d{1,7}$/.test(d.maxUses.trim()) ? Number(d.maxUses.trim()) : null
  const codeOk = /^[A-Z0-9-]{1,16}$/.test(d.code.trim())
  const ready = codeOk && d.name.trim() !== '' && d.planId > 0 && days.every((x) => x !== null) && uses !== null
  const planName = (id: number) => { const p = plans.find((x) => x.id === id); return p ? tr(p.name) : `#${id}` }
  const save = async (e: FormEvent) => {
    e.preventDefault()
    if (!ready) return
    setBusy(true)
    try {
      await api.upsertPromo(d.id, { code: d.code.trim(), name: d.name.trim(), planId: d.planId, bookFrom: days[0]!, bookUntil: days[1]!, stayFrom: days[2]!,
        stayUntil: days[3]!, maxUses: uses!, active: d.active })
      toast.success(t('products.saved', { name: d.name.trim() })); setDraft(null); await onSaved()
    } catch (err) { toast.error(err instanceof Refused ? tr(err.reason) : t('err.generic')) }
    finally { setBusy(false) }
  }
  const field = 'mt-1 block w-full rounded-base border border-field bg-bg px-3 py-2.5 text-ink'
  return (
    <section className="mt-12" aria-labelledby="promos">
      <h2 id="promos" className="t-h2 text-ink">{t('products.promos')}</h2>
      <p className="t-small mt-1 max-w-2xl text-muted">{t('products.promosLead')}</p>
      <div className="mt-4 grid gap-8 lg:grid-cols-[minmax(0,1fr)_360px]">
        <ul className="space-y-2" data-promos>
          {promos.length === 0 && <li className="rounded-lg border border-dashed border-line p-6 text-muted">{t('products.promosNone')}</li>}
          {promos.map((p) => (
            <li key={p.id} data-promo={p.code} className={`flex flex-wrap items-center justify-between gap-3 rounded-lg border border-line bg-surface p-4 ${p.active ? '' : 'opacity-60'}`}>
              <div className="min-w-0">
                <p className="font-semibold text-ink">{p.name} <span className="t-small font-mono font-normal text-muted" dir="ltr">· {p.code}</span></p>
                <p className="t-small text-muted">{planName(p.planId)} · {p.active ? t('products.promoActive') : t('products.offSale')}</p>
                <p className="t-small text-muted"><bdi>{t('products.promoDates', { b1: day(p.bookFrom), b2: day(p.bookUntil), s1: day(p.stayFrom), s2: day(p.stayUntil) })}</bdi></p>
                <p className="t-small text-ink" data-promo-uses={p.used}>
                  {p.maxUses ? t('products.promoUses', { used: p.used, max: p.maxUses }) : t('products.promoUsesNoLimit', { used: p.used })}</p>
              </div>
              <button type="button" onClick={() => setDraft({ id: p.id, code: p.code, name: p.name, planId: p.planId, bookFrom: iso(p.bookFrom), bookUntil: iso(p.bookUntil),
                stayFrom: iso(p.stayFrom), stayUntil: iso(p.stayUntil), maxUses: String(p.maxUses), active: p.active })}
                className="t-small font-semibold text-ink underline underline-offset-4">{t('extras.edit')}</button>
            </li>
          ))}
        </ul>
        <form onSubmit={save} className="h-fit space-y-4 rounded-lg border border-line bg-surface p-5" data-promo-form>
          <h3 className="t-h2 text-ink">{d.id ? t('extras.editTitle', { name: d.name }) : t('products.promoAdd')}</h3>
          <label className="block"><span className="font-semibold text-ink">{t('products.code')}</span>
            <input name="promoCode" dir="ltr" value={d.code} maxLength={16} onChange={(e) => set({ code: e.currentTarget.value.toUpperCase() })} className={`${field} font-mono`} />
            <span className={`t-small mt-1 block ${d.code && !codeOk ? 'text-danger' : 'text-muted'}`}>{t('products.promoCodeHint')}</span></label>
          <label className="block"><span className="font-semibold text-ink">{t('products.promoName')}</span>
            <input name="promoName" value={d.name} maxLength={120} onChange={(e) => set({ name: e.currentTarget.value })} className={field} /></label>
          <label className="block"><span className="font-semibold text-ink">{t('products.promoPlan')}</span>
            <select name="promoPlan" value={d.planId} disabled={d.id > 0} onChange={(e) => set({ planId: Number(e.currentTarget.value) })} className={field}>
              {plans.map((p) => <option key={p.id} value={p.id}>{tr(p.name)} · {p.code}</option>)}
            </select>
            {d.id > 0 && <span className="t-small mt-1 block text-muted">{t('products.promoPlanKept')}</span>}
            {d.planId > 0 && soldTo(d.planId) !== CODES_ONLY && <span className="t-small mt-1 block text-danger" data-promo-plan-open>{t('products.promoPlanOpen')}</span>}</label>
          <fieldset><legend className="font-semibold text-ink">{t('products.bookWindow')}</legend>
            <div className="grid grid-cols-2 gap-2">
              <input type="date" name="bookFrom" aria-label={t('products.bookWindow')} value={d.bookFrom} onChange={(e) => set({ bookFrom: e.currentTarget.value })} className={field} />
              <input type="date" name="bookUntil" aria-label={t('products.bookWindow')} value={d.bookUntil} onChange={(e) => set({ bookUntil: e.currentTarget.value })} className={field} />
            </div></fieldset>
          <fieldset><legend className="font-semibold text-ink">{t('products.stayWindow')}</legend>
            <div className="grid grid-cols-2 gap-2">
              <input type="date" name="stayFrom" aria-label={t('products.stayWindow')} value={d.stayFrom} onChange={(e) => set({ stayFrom: e.currentTarget.value })} className={field} />
              <input type="date" name="stayUntil" aria-label={t('products.stayWindow')} value={d.stayUntil} onChange={(e) => set({ stayUntil: e.currentTarget.value })} className={field} />
            </div></fieldset>
          <label className="block"><span className="font-semibold text-ink">{t('products.maxUses')}</span>
            <input name="maxUses" inputMode="numeric" dir="ltr" value={d.maxUses} onChange={(e) => set({ maxUses: e.currentTarget.value })} className={field} /></label>
          <label className="flex items-center gap-2 text-ink"><input type="checkbox" checked={d.active} onChange={(e) => set({ active: e.currentTarget.checked })} />{t('products.promoActive')}</label>
          <div className="flex gap-2">
            <button type="submit" disabled={busy || !ready} className="flex-1 rounded-base bg-primary px-5 py-3 font-semibold text-primary-ink disabled:opacity-40">{t('extras.save')}</button>
            {draft !== null && <button type="button" onClick={() => setDraft(null)} className="rounded-base border border-line px-4 py-3 font-semibold text-ink">{t('console.cancel')}</button>}
          </div>
        </form>
      </div>
    </section>
  )
}
