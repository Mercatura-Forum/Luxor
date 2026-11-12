import { useCallback, useEffect, useState, type FormEvent } from 'react'
import { toast } from '../lib/toast'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import { parseMoney, toDecimalString } from '../lib/money'
import { EXTRA_CATEGORIES, Refused, type ExtraCategory, type ExtraView } from '../api/types'
import { StaffOnly } from './StaffOnly'

type Draft = { id: number; code: string; en: string; ar: string; category: ExtraCategory; price: string; taxed: boolean; active: boolean }
const blank: Draft = { id: 0, code: '', en: '', ar: '', category: 'minibar', price: '', taxed: true, active: true }

/** THE EXTRAS CATALOGUE: what the hotel sells beside the room, at what price, and whether it is taxed. */
export default function Extras() {
  const { api, t, tr, tenant } = useApp()
  const { money } = useFormat()
  const [rows, setRows] = useState<ExtraView[] | null>(null)
  const [draft, setDraft] = useState<Draft>(blank)
  const [busy, setBusy] = useState(false)
  const [denied, setDenied] = useState(false)
  const load = useCallback(async () => {
    try { setRows(await api.extras()) } catch (e) { if (e instanceof Refused && e.kind === 'notAuthorised') setDenied(true); else toast.error(t('err.generic')) }
  }, [api, t])
  useEffect(() => { load() }, [load])
  const price = draft.price.trim() === '' ? 0n : parseMoney(draft.price, tenant.minorUnits)
  const save = async (e: FormEvent) => {
    e.preventDefault()
    if (price === null) return
    setBusy(true)
    try {
      await api.upsertExtra(draft.id, { code: draft.code.trim(), name: { en: draft.en.trim(), ar: draft.ar.trim() }, category: draft.category, price, taxed: draft.taxed, active: draft.active })
      toast.success(t('extras.saved', { name: draft.en })); setDraft(blank); await load()
    } catch (err) { toast.error(err instanceof Refused ? tr(err.reason) : t('err.generic')) }
    finally { setBusy(false) }
  }
  const edit = (x: ExtraView) => setDraft({ id: x.id, code: x.code, en: x.name.en, ar: x.name.ar, category: x.category, price: x.price > 0n ? toDecimalString(x.price, tenant.minorUnits) : '',
    taxed: x.taxed, active: x.active })
  const field = 'mt-1 block w-full rounded-base border border-field bg-bg px-3 py-2.5 text-ink'
  if (denied) return <StaffOnly />
  return (
    <div className="mx-auto max-w-[1240px]">
      <h1 className="t-h1 mt-1 text-ink">{t('extras.title')}</h1>
      <p className="t-small mt-2 max-w-2xl text-muted">{t('extras.lead')}</p>
      <div className="mt-8 grid gap-8 lg:grid-cols-[minmax(0,1fr)_360px]">
        <ul className="space-y-2">
          {rows === null && [0, 1, 2].map((i) => <li key={i} className="skeleton h-16 rounded-lg" aria-hidden />)}
          {rows?.length === 0 && <li className="rounded-lg border border-dashed border-line p-6 text-muted">{t('extras.none')}</li>}
          {rows?.map((x) => (
            <li key={x.id} className={`flex flex-wrap items-center justify-between gap-3 rounded-lg border border-line bg-surface p-4 ${x.active ? '' : 'opacity-60'}`}>
              <div className="min-w-0">
                <p className="font-semibold text-ink">{tr(x.name)} <span className="t-small font-normal text-muted" dir="ltr">· {x.code}</span></p>
                <p className="t-small text-muted">{t(`extras.cat.${x.category}`)} · {x.price > 0n ? money(x.price) : t('extras.open')} · {x.taxed ? t('extras.taxed') : t('extras.untaxed')}{x.active ? '' : ` · ${t('extras.inactive')}`}</p>
              </div>
              <button type="button" onClick={() => edit(x)} className="t-small font-semibold text-ink underline underline-offset-4">{t('extras.edit')}</button>
            </li>
          ))}
        </ul>
        <form onSubmit={save} className="h-fit space-y-4 rounded-lg border border-line bg-surface p-5">
          <h2 className="t-h2 text-ink">{draft.id ? t('extras.editTitle', { name: draft.en }) : t('extras.add')}</h2>
          <label className="block"><span className="font-semibold text-ink">{t('extras.code')}</span>
            <input dir="ltr" value={draft.code} maxLength={16} onChange={(e) => setDraft({ ...draft, code: e.currentTarget.value.toUpperCase() })} className={field} /></label>
          <label className="block"><span className="font-semibold text-ink">{t('extras.nameEn')}</span>
            <input dir="ltr" value={draft.en} onChange={(e) => setDraft({ ...draft, en: e.currentTarget.value })} className={field} /></label>
          <label className="block"><span className="font-semibold text-ink">{t('extras.nameAr')}</span>
            <input dir="rtl" lang="ar" value={draft.ar} onChange={(e) => setDraft({ ...draft, ar: e.currentTarget.value })} className={field} /></label>
          <label className="block"><span className="font-semibold text-ink">{t('extras.category')}</span>
            <select value={draft.category} onChange={(e) => setDraft({ ...draft, category: e.currentTarget.value as ExtraCategory })} className={field}>
              {EXTRA_CATEGORIES.map((c) => <option key={c} value={c}>{t(`extras.cat.${c}`)}</option>)}
            </select></label>
          <label className="block"><span className="font-semibold text-ink">{t('extras.price', { currency: tenant.currency })}</span>
            <input inputMode="decimal" dir="ltr" value={draft.price} onChange={(e) => setDraft({ ...draft, price: e.currentTarget.value })} className={`${field} nums`} />
            <span className="t-small mt-1 block text-muted">{t('extras.priceHint')}</span>
            {price === null && <span className="t-small mt-1 block text-danger">{t('extras.priceBad')}</span>}</label>
          <label className="flex items-center gap-2 text-ink"><input type="checkbox" checked={draft.taxed} onChange={(e) => setDraft({ ...draft, taxed: e.currentTarget.checked })} />{t('extras.taxedLabel')}</label>
          <label className="flex items-center gap-2 text-ink"><input type="checkbox" checked={draft.active} onChange={(e) => setDraft({ ...draft, active: e.currentTarget.checked })} />{t('extras.activeLabel')}</label>
          <div className="flex gap-2">
            <button type="submit" disabled={busy || !draft.code.trim() || !draft.en.trim() || price === null} className="flex-1 rounded-base bg-primary px-5 py-3 font-semibold text-primary-ink disabled:opacity-40">{t('extras.save')}</button>
            {draft.id > 0 && <button type="button" onClick={() => setDraft(blank)} className="rounded-base border border-line px-4 py-3 font-semibold text-ink">{t('console.cancel')}</button>}
          </div>
        </form>
      </div>
    </div>
  )
}
