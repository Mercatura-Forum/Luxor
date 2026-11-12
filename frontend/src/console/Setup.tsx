import { useCallback, useEffect, useMemo, useState, type FormEvent, type ReactNode } from 'react'
import { useSearchParams } from 'react-router-dom'
import { toast } from '../lib/toast'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import { parseMoney, toDecimalString } from '../lib/money'
import { photoSlots } from '../api/photos'
import { AMENITY } from '../theme/tenants'
import {
  AMENITIES, Refused,
  type BedKind, type BoardRoom, type EtaProfile, type SetupPlan, type SetupProperty, type SetupRoomType, type SetupTax, type TaxEta, type TaxKindSetting,
  PERS, RHYTHMS, type ExtraView, type InclusionSetting, type InclusionView, type Guarantee, type RulesView,
} from '../api/types'
import { inclusionText } from '../lib/package'
import { ScreenHead } from './Shell'
import { StaffOnly } from './StaffOnly'

const TABS = ['hotel', 'types', 'rooms', 'plans', 'taxes'] as const
type Tab = (typeof TABS)[number]
const BEDS: BedKind[] = ['king', 'queen', 'double', 'twin', 'single']
const TAX_KINDS: TaxKindSetting[] = ['percent', 'perRoomNight', 'perStay']

const field = 'mt-1 block w-full rounded-base border border-field bg-bg px-3 py-2.5 text-ink'
/** A whole number from what was typed, or NaN. */
const whole = (s: string) => (/^\d{1,9}$/.test(s.trim()) ? Number(s.trim()) : NaN)
const within = (s: string, lo: number, hi: number) => { const n = whole(s); return n >= lo && n <= hi }
/** A percentage with at most two decimals as basis points, or NaN: 12.5 → 1250. */
const bpsOf = (s: string) => { const m = /^(\d{1,3})(?:[.,](\d{1,2}))?$/.exec(s.trim()); return m ? Number(m[1]) * 100 + Number((m[2] ?? '').padEnd(2, '0')) : NaN }
const pctOf = (bps: number) => (bps % 100 === 0 ? String(bps / 100) : (bps / 100).toFixed(2).replace(/0$/, ''))

/** A labelled input, with the rule it must meet underneath, in red when it does not. */
function Field({ label, hint, bad, children }: { label: string; hint?: string; bad?: boolean; children: ReactNode }) {
  return (
    <label className="block">
      <span className="font-semibold text-ink">{label}</span>
      {children}
      {hint && <span className={`t-small mt-1 block ${bad ? 'text-danger' : 'text-muted'}`}>{hint}</span>}
    </label>
  )
}
function Check({ label, checked, onChange, disabled }: { label: string; checked: boolean; onChange: (v: boolean) => void; disabled?: boolean }) {
  return <label className={`flex items-center gap-2 text-ink ${disabled ? 'opacity-50' : ''}`}><input type="checkbox" checked={checked} disabled={disabled} onChange={(e) => onChange(e.currentTarget.checked)} />{label}</label>
}
function Actions({ busy, ok, editing, onCancel, label }: { busy: boolean; ok: boolean; editing: boolean; onCancel: () => void; label: string }) {
  const { t } = useApp()
  return (
    <div className="flex gap-2">
      <button type="submit" disabled={busy || !ok} className="flex-1 rounded-base bg-primary px-5 py-3 font-semibold text-primary-ink disabled:opacity-40">{label}</button>
      {editing && <button type="button" onClick={onCancel} className="rounded-base border border-line px-4 py-3 font-semibold text-ink">{t('console.cancel')}</button>}
    </div>
  )
}
function Row({ title, sub, off, onEdit, owner, children }: { title: ReactNode; sub: ReactNode; off?: boolean; onEdit: () => void; owner: boolean; children?: ReactNode }) {
  const { t } = useApp()
  return (
    <li className={`flex flex-wrap items-center justify-between gap-3 rounded-lg border border-line bg-surface p-4 ${off ? 'opacity-60' : ''}`}>
      <div className="min-w-0">
        <p className="font-semibold text-ink">{title}</p>
        <p className="t-small text-muted">{sub}</p>
        {children}
      </div>
      {owner && <button type="button" onClick={onEdit} className="t-small font-semibold text-ink underline underline-offset-4">{t('setup.edit')}</button>}
    </li>
  )
}

/** Runs one setup act: busy while it is in flight, the contract's refusal in the reader's language. */
function useAct() {
  const { t, tr } = useApp()
  const [busy, setBusy] = useState(false)
  const run = async (f: () => Promise<unknown>, ok: string, after: () => Promise<void> | void) => {
    setBusy(true)
    try { await f(); toast.success(ok); await after(); return true }
    catch (e) { toast.error(e instanceof Refused ? tr(e.reason) : t('err.generic')); return false }
    finally { setBusy(false) }
  }
  return { busy, run }
}

/**
 * SETUP: the hotel as the owner set it up. Its name, currency and house rules; the room types it sells;
 * the rooms of each; the rate plans; the taxes. Every member of staff reads it; only the owner changes
 * it (the contract refuses anyone else). Nothing is ever deleted: a room type, plan or tax is taken off
 * sale and can be put back, so the bookings and bills that name it keep reading the same thing.
 */
export default function Setup() {
  const { api, t } = useApp()
  const [q, setQ] = useSearchParams()
  const tab: Tab = (TABS as readonly string[]).includes(q.get('tab') ?? '') ? (q.get('tab') as Tab) : 'hotel'
  const [owner, setOwner] = useState(false)
  const [denied, setDenied] = useState(false)
  const [prop, setProp] = useState<SetupProperty | null | undefined>(undefined)
  const loadProp = useCallback(async () => {
    try { const [p, roles] = await Promise.all([api.setupProperty(), api.myRoles()]); setProp(p); setOwner(roles.includes('owner')); setDenied(false) }
    catch (e) { if (e instanceof Refused && e.kind === 'notAuthorised') setDenied(true); else toast.error(t('err.generic')) }
  }, [api, t])
  useEffect(() => { loadProp() }, [loadProp])

  if (denied) return <div className="mx-auto max-w-[1240px]"><ScreenHead title={t('setup.title')} /><StaffOnly /></div>
  const pick = (x: Tab) => setQ((p) => { const n = new URLSearchParams(p); n.set('tab', x); return n }, { replace: true })
  return (
    <div className="mx-auto max-w-[1240px]">
      <ScreenHead title={t('setup.title')} sub={owner ? t('setup.lead') : t('setup.leadReader')} />
      <div role="tablist" aria-label={t('setup.title')} className="mt-6 flex gap-1 overflow-x-auto border-b border-line">
        {TABS.map((x) => (
          <button key={x} type="button" role="tab" id={`tab-${x}`} aria-selected={tab === x} aria-controls={`panel-${x}`} onClick={() => pick(x)} data-setup-tab={x}
            className={`shrink-0 border-b-2 px-4 py-2.5 font-semibold ${tab === x ? 'border-primary text-ink' : 'border-transparent text-muted hover:text-ink'}`}>{t(`setup.tab.${x}`)}</button>
        ))}
      </div>
      <div role="tabpanel" id={`panel-${tab}`} aria-labelledby={`tab-${tab}`} className="mt-8">
        {prop === undefined ? <div className="skeleton h-64 rounded-lg" aria-hidden />
          : tab === 'hotel' ? <><Hotel prop={prop} owner={owner} reload={loadProp} />{prop && <Registration owner={owner} />}{prop && <BookRules owner={owner} />}</>
          : prop === null ? <p className="rounded-lg border border-dashed border-line p-6 text-muted">{t('setup.notConfigured')}</p>
          : tab === 'types' ? <RoomTypes owner={owner} />
          : tab === 'rooms' ? <Rooms owner={owner} />
          : tab === 'plans' ? <Plans owner={owner} />
          : <Taxes owner={owner} prop={prop} />}
      </div>
    </div>
  )
}

// ── the hotel ───────────────────────────────────────────────────────────────

type HotelDraft = { en: string; ar: string; currency: string; minorUnits: string; checkIn: string; checkOut: string; holdMinutes: string; perMinute: string;
  maxStay: string; horizon: string; maxRooms: string; idDays: string }
const hotelDraft = (p: SetupProperty | null): HotelDraft => p
  ? { en: p.name.en, ar: p.name.ar, currency: p.currency, minorUnits: String(p.minorUnits), checkIn: p.checkInText, checkOut: p.checkOutText,
      holdMinutes: String(Math.round(p.holdTtlHeights / p.heightsPerRealMinute)), perMinute: String(p.heightsPerRealMinute), maxStay: String(p.maxStayNights),
      horizon: String(p.horizonDays), maxRooms: String(p.maxRoomsPerBooking), idDays: String(p.idRetentionDays) }
  : { en: '', ar: '', currency: '', minorUnits: '2', checkIn: '', checkOut: '', holdMinutes: '15', perMinute: '60', maxStay: '21', horizon: '365', maxRooms: '4', idDays: '30' }

function Hotel({ prop, owner, reload }: { prop: SetupProperty | null; owner: boolean; reload: () => Promise<void> }) {
  const { api, t } = useApp()
  const [d, setD] = useState<HotelDraft>(() => hotelDraft(prop))
  useEffect(() => setD(hotelDraft(prop)), [prop])
  const { busy, run } = useAct()
  const set = (k: keyof HotelDraft) => (e: { currentTarget: { value: string } }) => setD({ ...d, [k]: e.currentTarget.value })
  const bad = {
    currency: !/^[A-Z]{3}$/.test(d.currency), hold: !within(d.holdMinutes, 1, 1440), perMinute: !within(d.perMinute, 1, 6000),
    maxStay: !within(d.maxStay, 1, 255), horizon: !within(d.horizon, 1, 1095), idDays: !within(d.idDays, 1, 3650), name: !d.en.trim(),
  }
  const ok = !Object.values(bad).some(Boolean)
  const money = prop !== null && (d.currency !== prop.currency || Number(d.minorUnits) !== prop.minorUnits)
  const save = (e: FormEvent) => {
    e.preventDefault()
    if (!ok) return
    const perMinute = whole(d.perMinute)
    run(() => api.configureProperty({ name: { en: d.en.trim(), ar: d.ar.trim() }, currency: d.currency, minorUnits: whole(d.minorUnits), checkInText: d.checkIn.trim(),
      checkOutText: d.checkOut.trim(), holdTtlHeights: whole(d.holdMinutes) * perMinute, heightsPerRealMinute: perMinute, maxStayNights: whole(d.maxStay),
      horizonDays: whole(d.horizon), maxRoomsPerBooking: whole(d.maxRooms), idRetentionDays: whole(d.idDays) }), t('setup.hotelSaved'), reload)
  }
  return (
    <form onSubmit={save} className="grid max-w-3xl gap-5 sm:grid-cols-2" data-setup-hotel>
      <fieldset disabled={!owner} className="contents">
        <Field label={t('setup.nameEn')} bad={bad.name} hint={bad.name ? t('setup.nameNeeded') : undefined}><input dir="ltr" value={d.en} onChange={set('en')} className={field} /></Field>
        <Field label={t('setup.nameAr')}><input dir="rtl" lang="ar" value={d.ar} onChange={set('ar')} className={field} /></Field>
        <Field label={t('setup.currency')} bad={bad.currency} hint={t('setup.currencyHint')}>
          <input dir="ltr" value={d.currency} maxLength={3} onChange={(e) => setD({ ...d, currency: e.currentTarget.value.toUpperCase() })} className={`${field} uppercase`} /></Field>
        <Field label={t('setup.minorUnits')} hint={t('setup.minorUnitsHint')}>
          <select value={d.minorUnits} onChange={set('minorUnits')} className={field}>{[0, 1, 2, 3].map((n) => <option key={n} value={n}>{n}</option>)}</select></Field>
        {money && <p className="rounded-base border border-danger/50 bg-danger/5 p-3 t-small text-ink sm:col-span-2" role="alert">{t('setup.moneyWarning')}</p>}
        <Field label={t('setup.checkIn')}><input value={d.checkIn} onChange={set('checkIn')} className={field} /></Field>
        <Field label={t('setup.checkOut')}><input value={d.checkOut} onChange={set('checkOut')} className={field} /></Field>
        <Field label={t('setup.maxStay')} bad={bad.maxStay} hint={t('setup.range', { lo: 1, hi: 255 })}><input inputMode="numeric" dir="ltr" value={d.maxStay} onChange={set('maxStay')} className={`${field} nums`} /></Field>
        <Field label={t('setup.maxRooms')}>
          <select value={d.maxRooms} onChange={set('maxRooms')} className={field}>{[1, 2, 3, 4, 5, 6, 7, 8, 9].map((n) => <option key={n} value={n}>{n}</option>)}</select></Field>
        <Field label={t('setup.horizon')} bad={bad.horizon} hint={t('setup.range', { lo: 1, hi: 1095 })}><input inputMode="numeric" dir="ltr" value={d.horizon} onChange={set('horizon')} className={`${field} nums`} /></Field>
        <Field label={t('setup.idDays')} bad={bad.idDays} hint={t('setup.idDaysHint')}><input inputMode="numeric" dir="ltr" value={d.idDays} onChange={set('idDays')} className={`${field} nums`} /></Field>
        <Field label={t('setup.hold')} bad={bad.hold} hint={t('setup.holdHint')}><input inputMode="numeric" dir="ltr" value={d.holdMinutes} onChange={set('holdMinutes')} className={`${field} nums`} /></Field>
        <Field label={t('setup.perMinute')} bad={bad.perMinute} hint={t('setup.perMinuteHint')}><input inputMode="numeric" dir="ltr" value={d.perMinute} onChange={set('perMinute')} className={`${field} nums`} /></Field>
      </fieldset>
      {owner && <div className="sm:col-span-2"><Actions busy={busy} ok={ok} editing={false} onCancel={() => {}} label={prop ? t('setup.saveHotel') : t('setup.openHotel')} /></div>}
    </form>
  )
}

// ── room types ──────────────────────────────────────────────────────────────

type TypeDraft = { id: number; code: string; en: string; ar: string; descEn: string; descAr: string; size: string; adults: string; children: string; occupancy: string;
  bed: BedKind; beds: string; amenities: string[]; photos: string; rank: string; active: boolean }
const blankType = (rank: number): TypeDraft => ({ id: 0, code: '', en: '', ar: '', descEn: '', descAr: '', size: '', adults: '2', children: '0', occupancy: '2',
  bed: 'king', beds: '1', amenities: [], photos: '', rank: String(rank), active: true })

function RoomTypes({ owner }: { owner: boolean }) {
  const { api, t, tr } = useApp()
  const [rows, setRows] = useState<SetupRoomType[] | null>(null)
  const [d, setD] = useState<TypeDraft>(blankType(1))
  const { busy, run } = useAct()
  const load = useCallback(async () => { try { setRows(await api.setupRoomTypes()) } catch { toast.error(t('err.generic')) } }, [api, t])
  useEffect(() => { load() }, [load])
  const slots = useMemo(() => photoSlots(), [])
  const nextRank = (rows ?? []).reduce((m, r) => Math.max(m, r.rank), 0) + 1
  const reset = () => setD(blankType(nextRank))
  useEffect(() => { if (d.id === 0 && rows) setD((x) => ({ ...x, rank: String(nextRank) })) }, [rows]) // eslint-disable-line react-hooks/exhaustive-deps
  const set = (k: keyof TypeDraft) => (e: { currentTarget: { value: string } }) => setD({ ...d, [k]: e.currentTarget.value })
  const adults = whole(d.adults), children = whole(d.children), occupancy = whole(d.occupancy)
  const bad = {
    code: !d.code.trim(), name: !d.en.trim(), size: !within(d.size, 0, 65535), beds: !within(d.beds, 1, 255), rank: !within(d.rank, 0, 255),
    sleeps: !(adults >= 1 && occupancy >= 1 && children >= 0 && occupancy <= adults + children && occupancy <= 255),
  }
  const ok = !Object.values(bad).some(Boolean)
  const edit = (r: SetupRoomType) => setD({ id: r.id, code: r.code, en: r.name.en, ar: r.name.ar, descEn: r.desc.en, descAr: r.desc.ar, size: String(r.sizeSqm),
    adults: String(r.maxAdults), children: String(r.maxChildren), occupancy: String(r.maxOccupancy), bed: r.bedKind, beds: String(r.bedCount),
    amenities: [...r.amenities], photos: r.photos, rank: String(r.rank), active: r.active })
  const save = (e: FormEvent) => {
    e.preventDefault()
    if (!ok) return
    run(() => api.upsertRoomType(d.id, { code: d.code.trim(), name: { en: d.en.trim(), ar: d.ar.trim() }, desc: { en: d.descEn.trim(), ar: d.descAr.trim() },
      sizeSqm: whole(d.size), maxAdults: adults, maxChildren: children, maxOccupancy: occupancy, bedKind: d.bed, bedCount: whole(d.beds),
      amenities: AMENITIES.filter((a) => d.amenities.includes(a)), photos: d.photos, rank: whole(d.rank), active: d.active }),
    t('setup.typeSaved', { name: d.en.trim() }), async () => { reset(); await load() })
  }
  const toggle = (a: string) => setD({ ...d, amenities: d.amenities.includes(a) ? d.amenities.filter((x) => x !== a) : [...d.amenities, a] })
  return (
    <div className="grid gap-8 lg:grid-cols-[minmax(0,1fr)_420px]">
      <ul className="space-y-2" aria-label={t('setup.tab.types')}>
        {rows === null && [0, 1, 2].map((i) => <li key={i} className="skeleton h-16 rounded-lg" aria-hidden />)}
        {rows?.length === 0 && <li className="rounded-lg border border-dashed border-line p-6 text-muted">{t('setup.noTypes')}</li>}
        {[...(rows ?? [])].sort((a, b) => a.rank - b.rank || a.id - b.id).map((r) => (
          <Row key={r.id} owner={owner} off={!r.active} onEdit={() => edit(r)}
            title={<>{tr(r.name)} <span className="t-small font-normal text-muted" dir="ltr">· {r.code}</span></>}
            sub={<>{t('setup.typeLine', { sleeps: r.maxOccupancy, size: r.sizeSqm, rooms: r.rooms })}{r.active ? '' : ` · ${t('setup.offSale')}`}</>}>
            {r.active && r.rooms === 0 && <p className="t-small mt-1 text-danger">{t('setup.typeNoRooms')}</p>}
          </Row>
        ))}
      </ul>
      {owner && (
        <form onSubmit={save} className="h-fit space-y-4 rounded-lg border border-line bg-surface p-5" data-setup-type-form>
          <h2 className="t-h2 text-ink">{d.id ? t('setup.editTitle', { name: d.en }) : t('setup.addType')}</h2>
          <Field label={t('setup.code')} hint={t('setup.codeHint')}>
            <input dir="ltr" value={d.code} maxLength={16} onChange={(e) => setD({ ...d, code: e.currentTarget.value.toUpperCase() })} className={field} /></Field>
          <Field label={t('setup.nameEn')}><input dir="ltr" value={d.en} onChange={set('en')} className={field} /></Field>
          <Field label={t('setup.nameAr')}><input dir="rtl" lang="ar" value={d.ar} onChange={set('ar')} className={field} /></Field>
          <Field label={t('setup.descEn')}><textarea dir="ltr" rows={3} value={d.descEn} onChange={set('descEn')} className={field} /></Field>
          <Field label={t('setup.descAr')}><textarea dir="rtl" lang="ar" rows={3} value={d.descAr} onChange={set('descAr')} className={field} /></Field>
          <div className="grid grid-cols-3 gap-3">
            <Field label={t('setup.adults')}><input inputMode="numeric" dir="ltr" value={d.adults} onChange={set('adults')} className={`${field} nums`} /></Field>
            <Field label={t('setup.children')}><input inputMode="numeric" dir="ltr" value={d.children} onChange={set('children')} className={`${field} nums`} /></Field>
            <Field label={t('setup.sleeps')}><input inputMode="numeric" dir="ltr" value={d.occupancy} onChange={set('occupancy')} className={`${field} nums`} /></Field>
          </div>
          {bad.sleeps && <p className="t-small text-danger">{t('setup.sleepsBad')}</p>}
          <div className="grid grid-cols-3 gap-3">
            <Field label={t('setup.bed')}><select value={d.bed} onChange={(e) => setD({ ...d, bed: e.currentTarget.value as BedKind })} className={field}>
              {BEDS.map((b) => <option key={b} value={b}>{t(`setup.bed.${b}`)}</option>)}</select></Field>
            <Field label={t('setup.beds')} bad={bad.beds}><input inputMode="numeric" dir="ltr" value={d.beds} onChange={set('beds')} className={`${field} nums`} /></Field>
            <Field label={t('setup.size')} bad={bad.size}><input inputMode="numeric" dir="ltr" value={d.size} onChange={set('size')} className={`${field} nums`} /></Field>
          </div>
          <fieldset>
            <legend className="font-semibold text-ink">{t('setup.amenities')}</legend>
            <div className="mt-2 grid grid-cols-2 gap-x-3 gap-y-1.5">
              {AMENITIES.map((a) => <Check key={a} label={tr(AMENITY[a])} checked={d.amenities.includes(a)} onChange={() => toggle(a)} />)}
            </div>
          </fieldset>
          <Field label={t('setup.photos')} hint={t('setup.photosHint')}>
            <select dir="ltr" value={d.photos} onChange={set('photos')} className={field}>
              <option value="">{t('setup.noPhotos')}</option>
              {[...new Set([...slots, ...(d.photos ? [d.photos] : [])])].map((s) => <option key={s} value={s}>{s}</option>)}
            </select></Field>
          <Field label={t('setup.rank')} bad={bad.rank} hint={t('setup.rankHint')}><input inputMode="numeric" dir="ltr" value={d.rank} onChange={set('rank')} className={`${field} nums`} /></Field>
          <Check label={t('setup.onSale')} checked={d.active} onChange={(v) => setD({ ...d, active: v })} />
          {d.id === 0 && <p className="t-small text-muted">{t('setup.newTypeNote')}</p>}
          <Actions busy={busy} ok={ok} editing={d.id > 0} onCancel={reset} label={t('setup.save')} />
        </form>
      )}
    </div>
  )
}

// ── rooms ───────────────────────────────────────────────────────────────────

type RoomDraft = { id: number; number: string; type: number; out: boolean }

function Rooms({ owner }: { owner: boolean }) {
  const { api, t, tr } = useApp()
  const { day } = useFormat()
  const [rooms, setRooms] = useState<BoardRoom[] | null>(null)
  const [types, setTypes] = useState<SetupRoomType[]>([])
  const [d, setD] = useState<RoomDraft>({ id: 0, number: '', type: 0, out: false })
  const { busy, run } = useAct()
  const load = useCallback(async () => {
    try { const [r, ty] = await Promise.all([api.housekeeping(), api.setupRoomTypes()]); setRooms(r); setTypes(ty) } catch { toast.error(t('err.generic')) }
  }, [api, t])
  useEffect(() => { load() }, [load])
  const type = d.type || types[0]?.id || 0
  const editing = rooms?.find((r) => r.id === d.id)
  const occupied = !!editing?.occupiedBy
  const bytes = new TextEncoder().encode(d.number.trim()).length
  const taken = rooms?.some((r) => r.number === d.number.trim() && r.id !== d.id) ?? false
  const ok = bytes >= 1 && bytes <= 8 && !taken && type > 0 && !(occupied && (d.out || type !== editing?.roomTypeId))
  const reset = () => setD({ id: 0, number: '', type: 0, out: false })
  const save = (e: FormEvent) => {
    e.preventDefault()
    if (!ok) return
    run(() => api.upsertRoom(d.id, type, d.number.trim(), d.out), t('setup.roomSaved', { number: d.number.trim() }), async () => { reset(); await load() })
  }
  const byType = types.map((ty) => ({ ty, rooms: (rooms ?? []).filter((r) => r.roomTypeId === ty.id).sort((a, b) => a.number.localeCompare(b.number, undefined, { numeric: true })) }))
  return (
    <div className="grid gap-8 lg:grid-cols-[minmax(0,1fr)_360px]">
      <div className="space-y-6">
        {rooms === null && <div className="skeleton h-40 rounded-lg" aria-hidden />}
        {rooms !== null && byType.map(({ ty, rooms: rs }) => (
          <section key={ty.id} aria-labelledby={`rt-${ty.id}`}>
            <h2 id={`rt-${ty.id}`} className="font-semibold text-ink">{tr(ty.name)} <span className="t-small font-normal text-muted">· {t('setup.roomsInService', { n: ty.rooms })}</span></h2>
            {rs.length === 0 ? <p className="t-small mt-2 text-muted">{t('setup.noRooms')}</p> : (
              <ul className="mt-2 flex flex-wrap gap-2">
                {rs.map((r) => (
                  <li key={r.id}>
                    <button type="button" disabled={!owner} onClick={() => setD({ id: r.id, number: r.number, type: r.roomTypeId, out: r.outOfOrder })} data-setup-room={r.number}
                      title={r.outOfOrder ? (r.outUntil ? t('setup.outUntil', { day: day(r.outUntil) }) : t('setup.outNoDate')) : r.occupiedBy ? t('setup.occupied') : t('setup.inService')}
                      className={`min-w-16 rounded-base border px-3 py-2 text-start nums ${d.id === r.id ? 'border-primary bg-primary/5' : 'border-line bg-surface'} ${r.outOfOrder ? 'border-dashed text-muted' : 'text-ink'}`}>
                      <span className="block font-semibold">{r.number}</span>
                      <span className="t-small block text-muted">{r.outOfOrder ? t('setup.out') : r.occupiedBy ? t('setup.occupied') : t('setup.inService')}</span>
                    </button>
                  </li>
                ))}
              </ul>
            )}
          </section>
        ))}
      </div>
      {owner && (
        <form onSubmit={save} className="h-fit space-y-4 rounded-lg border border-line bg-surface p-5" data-setup-room-form>
          <h2 className="t-h2 text-ink">{d.id ? t('setup.editRoom', { number: editing?.number ?? '' }) : t('setup.addRoom')}</h2>
          <Field label={t('setup.roomNumber')} bad={taken || bytes > 8} hint={taken ? t('setup.numberTaken') : t('setup.roomNumberHint')}>
            <input dir="ltr" value={d.number} onChange={(e) => setD({ ...d, number: e.currentTarget.value })} className={`${field} nums`} /></Field>
          <Field label={t('setup.roomType')}>
            <select value={type} disabled={occupied} onChange={(e) => setD({ ...d, type: Number(e.currentTarget.value) })} className={field}>
              {types.map((ty) => <option key={ty.id} value={ty.id}>{tr(ty.name)}{ty.active ? '' : ` (${t('setup.offSale')})`}</option>)}
            </select></Field>
          <Check label={t('setup.outOfOrder')} checked={d.out} disabled={occupied} onChange={(v) => setD({ ...d, out: v })} />
          <p className="t-small text-muted">{occupied ? t('setup.occupiedNote') : editing?.outUntil ? t('setup.outDatedNote') : t('setup.outNote')}</p>
          <Actions busy={busy} ok={ok} editing={d.id > 0} onCancel={reset} label={t('setup.save')} />
        </form>
      )}
    </div>
  )
}

// ── rate plans ──────────────────────────────────────────────────────────────

type PlanDraft = { id: number; code: string; en: string; ar: string; discount: string; refundable: boolean; freeDays: string; penalty: string; guarantee: Guarantee;
  deposit: string; was: Guarantee; modifiable: boolean; active: boolean }
const blankPlan: PlanDraft = { id: 0, code: '', en: '', ar: '', discount: '0', refundable: true, freeDays: '2', penalty: '1', guarantee: 'firstNightAuthorised', deposit: '30',
  was: 'firstNightAuthorised', modifiable: true, active: true }

/**
 * What a rate includes: items of the extras catalogue, each with how many, for each room, adult or guest,
 * every night or on arrival. Saved whole; the contract refuses an item with no set price, off sale, twice,
 * or past eight. The guest sees one price; the bill carries each item as its own line.
 */
function PackageEditor({ plan, onSaved }: { plan: SetupPlan; onSaved: () => Promise<void> }) {
  const { api, t, tr } = useApp()
  const { money } = useFormat()
  const [extras, setExtras] = useState<ExtraView[] | null>(null)
  const [items, setItems] = useState<InclusionSetting[] | null>(null)
  const { busy, run } = useAct()
  useEffect(() => {
    let live = true
    setItems(null)
    Promise.all([api.extras(), api.packageOf(plan.id)]).then(([e, p]) => {
      if (!live) return
      setExtras(e)
      setItems(p.map((x) => ({ extraId: x.extraId, quantity: x.quantity, rhythm: x.rhythm, per: x.per })))
    }).catch(() => toast.error(t('err.generic')))
    return () => { live = false }
  }, [api, plan.id, t])
  const sellable = (extras ?? []).filter((e) => e.active && e.price > 0n)
  const put = (i: number, x: Partial<InclusionSetting>) => setItems((items ?? []).map((y, j) => (j === i ? { ...y, ...x } : y)))
  const taken = new Set((items ?? []).map((x) => x.extraId))
  const free = sellable.filter((e) => !taken.has(e.id))
  const add = () => { if (items && free.length && items.length < 8) setItems([...items, { extraId: free[0].id, quantity: 1, rhythm: 'everyNight', per: 'guest' }]) }
  const ok = items !== null && items.every((x) => x.quantity >= 1 && x.quantity <= 9) && new Set(items.map((x) => x.extraId)).size === items.length
  const save = (e: FormEvent) => {
    e.preventDefault()
    if (!ok || !items) return
    run(() => api.setPlanInclusions(plan.id, items), t('setup.packageSaved', { name: tr(plan.name), n: items.length }), onSaved)
  }
  return (
    <form onSubmit={save} className="h-fit space-y-4 rounded-lg border border-line bg-surface p-5" data-setup-package-form>
      <h2 className="t-h2 text-ink">{t('setup.package')}</h2>
      <p className="t-small text-muted">{t('setup.packageHint')}</p>
      {items === null && <div className="skeleton h-16 rounded-base" aria-hidden />}
      {items?.length === 0 && <p className="text-muted">{t('setup.packageNone')}</p>}
      <ul className="space-y-3">
        {items?.map((x, i) => (
          <li key={i} data-package-item className="space-y-2 rounded-base border border-line p-3">
            <Field label={t('setup.packageExtra')}>
              <select value={x.extraId} onChange={(e) => put(i, { extraId: Number(e.currentTarget.value) })} className={field}>
                {sellable.filter((e) => e.id === x.extraId || !taken.has(e.id)).map((e) => <option key={e.id} value={e.id}>{tr(e.name)} · {money(e.price)}</option>)}
              </select>
            </Field>
            <div className="grid grid-cols-[5.5rem_minmax(0,1fr)] gap-2">
              <Field label={t('setup.packageQty')} bad={!(x.quantity >= 1 && x.quantity <= 9)} hint={t('setup.packageQtyHint')}>
                <input inputMode="numeric" dir="ltr" value={Number.isNaN(x.quantity) ? '' : String(x.quantity)} onChange={(e) => put(i, { quantity: whole(e.currentTarget.value) })} className={`${field} nums`} />
              </Field>
              <Field label={t('setup.packagePer')}>
                <select value={x.per} onChange={(e) => put(i, { per: e.currentTarget.value as InclusionSetting['per'] })} className={field}>
                  {PERS.map((p) => <option key={p} value={p}>{t(`pkg.per.${p}`)}</option>)}
                </select>
              </Field>
            </div>
            <Field label={t('setup.packageWhen')}>
                <select value={x.rhythm} onChange={(e) => put(i, { rhythm: e.currentTarget.value as InclusionSetting['rhythm'] })} className={field}>
                  {RHYTHMS.map((r) => <option key={r} value={r}>{t(`pkg.when.${r}`)}</option>)}
                </select>
            </Field>
            <button type="button" onClick={() => setItems(items.filter((_, j) => j !== i))} className="t-small font-semibold text-ink underline underline-offset-4">{t('setup.packageRemove')}</button>
          </li>
        ))}
      </ul>
      {extras !== null && sellable.length === 0 && <p className="t-small text-muted">{t('setup.packageNoExtras')}</p>}
      {items !== null && items.length >= 8 && <p className="t-small text-muted">{t('setup.packageMax')}</p>}
      {items !== null && free.length > 0 && items.length < 8 && (
        <button type="button" onClick={add} className="rounded-base border border-line px-4 py-2.5 font-semibold text-ink">{t('setup.packageAdd')}</button>
      )}
      <Actions busy={busy} ok={ok} editing={false} onCancel={() => undefined} label={t('setup.packageSave')} />
    </form>
  )
}

const guaranteeOf = (p: SetupPlan): Guarantee => p.prepaid ? 'prepaidInFull' : p.guarantee === 'deposit' ? 'deposit' : 'firstNightAuthorised'

/**
 * The hotel's card rule: once the owner turns it on, every rate guaranteed by its first night or a deposit
 * keeps the guest's card on file (the gateway's token, never the card), agreed by the guest at payment; a
 * booking taken by phone gets a card link. It is turned on once and stays on, so a guest who agreed under
 * it is never asked to agree to less.
 */
function CardRule({ owner }: { owner: boolean }) {
  const { api, t } = useApp()
  const [on, setOn] = useState<boolean | null>(null)
  const [asking, setAsking] = useState(false)
  const { busy, run } = useAct()
  const load = useCallback(async () => { setOn(await api.cardRule().catch(() => null)) }, [api])
  useEffect(() => { load() }, [load])
  if (on === null) return null
  return (
    <section aria-labelledby="cardrule" className="rounded-lg border border-line bg-surface p-5" data-card-rule={on ? 'on' : 'off'}>
      <h2 id="cardrule" className="font-semibold text-ink">{t('setup.cardRule')}</h2>
      <p className="t-small mt-1 text-ink">{on ? t('setup.cardRuleOn') : t('setup.cardRuleOff')}</p>
      {owner && !on && !asking && (
        <button type="button" onClick={() => setAsking(true)} className="mt-3 rounded-base border border-ink px-4 py-2 font-semibold text-ink">{t('setup.cardRuleTurnOn')}</button>
      )}
      {owner && !on && asking && (
        <div className="mt-3">
          <p className="t-small font-semibold text-ink">{t('setup.cardRuleSure')}</p>
          <div className="mt-2 flex flex-wrap gap-3">
            <button type="button" disabled={busy} onClick={() => run(() => api.requireCardOnFile(), t('setup.cardRuleDone'), async () => { setAsking(false); await load() })}
              className="rounded-base bg-primary px-4 py-2 font-semibold text-primary-ink disabled:opacity-50">{t('setup.cardRuleConfirm')}</button>
            <button type="button" onClick={() => setAsking(false)} className="rounded-base px-4 py-2 font-semibold text-ink underline">{t('setup.cardRuleNo')}</button>
          </div>
        </div>
      )}
    </section>
  )
}

function Plans({ owner }: { owner: boolean }) {
  const { api, t, tr } = useApp()
  const { num } = useFormat()
  const [rows, setRows] = useState<SetupPlan[] | null>(null)
  const [packages, setPackages] = useState<Record<number, InclusionView[]>>({})
  const [d, setD] = useState<PlanDraft>(blankPlan)
  const { busy, run } = useAct()
  const load = useCallback(async () => {
    try {
      const plans = await api.setupPlans()
      setRows(plans)
      setPackages(Object.fromEntries(await Promise.all(plans.map(async (p) => [p.id, await api.packageOf(p.id)] as const))))
    } catch { toast.error(t('err.generic')) }
  }, [api, t])
  useEffect(() => { load() }, [load])
  const set = (k: keyof PlanDraft) => (e: { currentTarget: { value: string } }) => setD({ ...d, [k]: e.currentTarget.value })
  const bps = bpsOf(d.discount)
  const depositBps = whole(d.deposit) * 100
  const bad = { code: !d.code.trim(), name: !d.en.trim(), discount: !(bps >= 0 && bps <= 9000), freeDays: !within(d.freeDays, 0, 255), penalty: !within(d.penalty, 0, 255),
    deposit: d.guarantee === 'deposit' && !within(d.deposit, 1, 99) }
  const ok = !Object.values(bad).some(Boolean)
  const edit = (p: SetupPlan) => setD({ id: p.id, code: p.code, en: p.name.en, ar: p.name.ar, discount: pctOf(p.discountBps), refundable: p.refundable,
    freeDays: String(p.freeCancelDaysBefore), penalty: String(p.penaltyNights), guarantee: guaranteeOf(p), deposit: p.depositBps ? String(p.depositBps / 100) : '30',
    was: guaranteeOf(p), modifiable: p.modifiable, active: p.active })
  const save = (e: FormEvent) => {
    e.preventDefault()
    if (!ok) return
    // the plan, then its deposit: a deposit is its own act with its share, and a plan that leaves the deposit goes back to the first night
    run(async () => {
      const id = await api.upsertRatePlan(d.id, { code: d.code.trim(), name: { en: d.en.trim(), ar: d.ar.trim() }, discountBps: bps, refundable: d.refundable,
        freeCancelDaysBefore: whole(d.freeDays), penaltyNights: whole(d.penalty), prepaid: d.guarantee === 'prepaidInFull', modifiable: d.modifiable, active: d.active })
      if (d.guarantee === 'deposit') await api.setPlanDeposit(id, depositBps)
      else if (d.was === 'deposit' && d.guarantee === 'firstNightAuthorised') await api.setPlanDeposit(id, 0)
    }, t('setup.planSaved', { name: d.en.trim() }), async () => { setD(blankPlan); await load() })
  }
  const terms = (p: SetupPlan) => [
    p.discountBps ? t('setup.planDiscount', { pct: pctOf(p.discountBps) }) : t('setup.planBar'),
    p.refundable ? t('setup.planFree', { days: p.freeCancelDaysBefore, nights: p.penaltyNights }) : t('setup.planNonRefundable'),
    p.prepaid ? t('setup.planPrepaid') : guaranteeOf(p) === 'deposit' ? t('setup.planDeposit', { pct: pctOf(p.depositBps ?? 0) }) : t('setup.planFirstNight'),
  ].join(' · ')
  return (
    <div className="grid gap-8 lg:grid-cols-[minmax(0,1fr)_380px]">
      <div className="space-y-6">
      <CardRule owner={owner} />
      <ul className="space-y-2" aria-label={t('setup.tab.plans')}>
        {rows === null && [0, 1].map((i) => <li key={i} className="skeleton h-16 rounded-lg" aria-hidden />)}
        {rows?.length === 0 && <li className="rounded-lg border border-dashed border-line p-6 text-muted">{t('setup.noPlans')}</li>}
        {rows?.map((p) => (
          <Row key={p.id} owner={owner} off={!p.active} onEdit={() => edit(p)} title={<>{tr(p.name)} <span className="t-small font-normal text-muted" dir="ltr">· {p.code}</span></>}
            sub={<>{terms(p)}{p.active ? '' : ` · ${t('setup.offSale')}`}</>}>
            {(packages[p.id] ?? []).length > 0 && (
              <ul data-plan-package className="t-small mt-1 text-ink">{packages[p.id].map((x) => <li key={x.slot}>{inclusionText(x, t, tr, num)}</li>)}</ul>
            )}
          </Row>
        ))}
      </ul>
      </div>
      {owner && (
        <form onSubmit={save} className="h-fit space-y-4 rounded-lg border border-line bg-surface p-5" data-setup-plan-form>
          <h2 className="t-h2 text-ink">{d.id ? t('setup.editTitle', { name: d.en }) : t('setup.addPlan')}</h2>
          <Field label={t('setup.code')} hint={t('setup.codeHint')}><input dir="ltr" value={d.code} maxLength={16} onChange={(e) => setD({ ...d, code: e.currentTarget.value.toUpperCase() })} className={field} /></Field>
          <Field label={t('setup.nameEn')}><input dir="ltr" value={d.en} onChange={set('en')} className={field} /></Field>
          <Field label={t('setup.nameAr')}><input dir="rtl" lang="ar" value={d.ar} onChange={set('ar')} className={field} /></Field>
          <Field label={t('setup.discount')} bad={bad.discount} hint={t('setup.discountHint')}><input inputMode="decimal" dir="ltr" value={d.discount} onChange={set('discount')} className={`${field} nums`} /></Field>
          <Check label={t('setup.refundable')} checked={d.refundable} onChange={(v) => setD({ ...d, refundable: v })} />
          <div className="grid grid-cols-2 gap-3">
            <Field label={t('setup.freeDays')} bad={bad.freeDays}><input inputMode="numeric" dir="ltr" disabled={!d.refundable} value={d.freeDays} onChange={set('freeDays')} className={`${field} nums`} /></Field>
            <Field label={t('setup.penalty')} bad={bad.penalty}><input inputMode="numeric" dir="ltr" disabled={!d.refundable} value={d.penalty} onChange={set('penalty')} className={`${field} nums`} /></Field>
          </div>
          <Field label={t('setup.guarantee')}>
            <select value={d.guarantee} onChange={(e) => setD({ ...d, guarantee: e.currentTarget.value as Guarantee })} className={field} data-plan-guarantee>
              <option value="firstNightAuthorised">{t('setup.planFirstNight')}</option>
              <option value="deposit">{t('setup.guaranteeDeposit')}</option>
              <option value="prepaidInFull">{t('setup.prepaid')}</option>
            </select>
          </Field>
          {d.guarantee === 'deposit' && (
            <Field label={t('setup.depositPct')} bad={bad.deposit} hint={t('setup.depositHint')}>
              <input inputMode="numeric" dir="ltr" value={d.deposit} onChange={set('deposit')} className={`${field} nums`} data-plan-deposit />
            </Field>
          )}
          <Check label={t('setup.modifiable')} checked={d.modifiable} onChange={(v) => setD({ ...d, modifiable: v })} />
          <Check label={t('setup.onSale')} checked={d.active} onChange={(v) => setD({ ...d, active: v })} />
          <Actions busy={busy} ok={ok} editing={d.id > 0} onCancel={() => setD(blankPlan)} label={t('setup.save')} />
        </form>
      )}
      {owner && d.id > 0 && rows?.find((p) => p.id === d.id) && (
        <div className="lg:col-start-2"><PackageEditor plan={rows.find((p) => p.id === d.id)!} onSaved={load} /></div>
      )}
    </div>
  )
}

// ── taxes ───────────────────────────────────────────────────────────────────

type TaxDraft = { id: number; code: string; en: string; ar: string; kind: TaxKindSetting; rate: string; amount: string; prior: boolean; rank: string; active: boolean }
const blankTax = (rank: number): TaxDraft => ({ id: 0, code: '', en: '', ar: '', kind: 'percent', rate: '', amount: '', prior: false, rank: String(rank), active: true })

function Taxes({ owner, prop }: { owner: boolean; prop: SetupProperty }) {
  const { api, t, tr } = useApp()
  const { money } = useFormat()
  const [rows, setRows] = useState<SetupTax[] | null>(null)
  const [codes, setCodes] = useState<TaxEta[]>([])
  const [d, setD] = useState<TaxDraft>(blankTax(1))
  const { busy, run } = useAct()
  const load = useCallback(async () => {
    try { const [r, c] = await Promise.all([api.setupTaxes(), api.taxEta()]); setRows(r); setCodes(c) } catch { toast.error(t('err.generic')) }
  }, [api, t])
  useEffect(() => { load() }, [load])
  const nextRank = (rows ?? []).reduce((m, r) => Math.max(m, r.rank), 0) + 1
  useEffect(() => { if (d.id === 0 && rows) setD((x) => ({ ...x, rank: String(nextRank) })) }, [rows]) // eslint-disable-line react-hooks/exhaustive-deps
  const set = (k: keyof TaxDraft) => (e: { currentTarget: { value: string } }) => setD({ ...d, [k]: e.currentTarget.value })
  const pct = d.kind === 'percent'
  const bps = bpsOf(d.rate)
  const amount = parseMoney(d.amount, prop.minorUnits)
  const bad = { code: !d.code.trim(), name: !d.en.trim(), rate: pct && !(bps >= 1 && bps <= 10000), amount: !pct && !(amount !== null && amount > 0n), rank: !within(d.rank, 0, 255) }
  const ok = !Object.values(bad).some(Boolean)
  const edit = (x: SetupTax) => setD({ id: x.id, code: x.code, en: x.name.en, ar: x.name.ar, kind: x.kind, rate: x.kind === 'percent' ? pctOf(x.bps) : '',
    amount: x.kind === 'percent' ? '' : toDecimalString(x.amount, prop.minorUnits), prior: x.onPriorTaxes, rank: String(x.rank), active: x.active })
  const save = (e: FormEvent) => {
    e.preventDefault()
    if (!ok) return
    run(() => api.upsertTaxRule(d.id, { code: d.code.trim(), name: { en: d.en.trim(), ar: d.ar.trim() }, kind: d.kind, bps: pct ? bps : 0, amount: pct ? 0n : amount ?? 0n,
      onPriorTaxes: d.prior, rank: whole(d.rank), active: d.active }), t('setup.taxSaved', { name: d.en.trim() }), async () => { setD(blankTax(nextRank)); await load() })
  }
  const what = (x: SetupTax) => x.kind === 'percent' ? t('setup.taxPct', { pct: pctOf(x.bps) }) : t(x.kind === 'perStay' ? 'setup.taxFixed.perStay' : 'setup.taxFixed.perRoomNight', { amount: money(x.amount) })
  return (
    <div className="grid gap-8 lg:grid-cols-[minmax(0,1fr)_380px]">
      <div>
        <ul className="space-y-2" aria-label={t('setup.tab.taxes')}>
          {rows === null && [0, 1].map((i) => <li key={i} className="skeleton h-16 rounded-lg" aria-hidden />)}
          {rows?.length === 0 && <li className="rounded-lg border border-dashed border-line p-6 text-muted">{t('setup.noTaxes')}</li>}
          {[...(rows ?? [])].sort((a, b) => a.rank - b.rank || a.id - b.id).map((x) => (
            <Row key={x.id} owner={owner} off={!x.active} onEdit={() => edit(x)} title={<>{tr(x.name)} <span className="t-small font-normal text-muted" dir="ltr">· {x.code}</span></>}
              sub={<>{what(x)}{x.onPriorTaxes ? ` · ${t('setup.taxOnPrior')}` : ''}{x.active ? '' : ` · ${t('setup.offSale')}`}</>}>
              <TaxCodes owner={owner} rule={x} codes={codes.find((c) => c.taxRuleId === x.id)} reload={load} />
            </Row>
          ))}
        </ul>
        <p className="t-small mt-4 text-muted">{t('setup.taxNote')}</p>
      </div>
      {owner && (
        <form onSubmit={save} className="h-fit space-y-4 rounded-lg border border-line bg-surface p-5" data-setup-tax-form>
          <h2 className="t-h2 text-ink">{d.id ? t('setup.editTitle', { name: d.en }) : t('setup.addTax')}</h2>
          <Field label={t('setup.code')} hint={t('setup.codeHint')}><input dir="ltr" value={d.code} maxLength={16} onChange={(e) => setD({ ...d, code: e.currentTarget.value.toUpperCase() })} className={field} /></Field>
          <Field label={t('setup.nameEn')}><input dir="ltr" value={d.en} onChange={set('en')} className={field} /></Field>
          <Field label={t('setup.nameAr')}><input dir="rtl" lang="ar" value={d.ar} onChange={set('ar')} className={field} /></Field>
          <fieldset>
            <legend className="font-semibold text-ink">{t('setup.taxKind')}</legend>
            <div className="mt-2 space-y-1.5">
              {TAX_KINDS.map((k) => (
                <label key={k} className="flex items-center gap-2 text-ink"><input type="radio" name="tax-kind" checked={d.kind === k} onChange={() => setD({ ...d, kind: k })} />{t(`setup.taxKind.${k}`)}</label>
              ))}
            </div>
          </fieldset>
          {pct
            ? <Field label={t('setup.taxRate')} bad={bad.rate && d.rate !== ''} hint={t('setup.taxRateHint')}><input inputMode="decimal" dir="ltr" value={d.rate} onChange={set('rate')} className={`${field} nums`} /></Field>
            : <Field label={t('setup.taxAmount', { currency: prop.currency })} bad={bad.amount && d.amount !== ''} hint={t('setup.taxAmountHint')}><input inputMode="decimal" dir="ltr" value={d.amount} onChange={set('amount')} className={`${field} nums`} /></Field>}
          <Check label={t('setup.taxPrior')} checked={d.prior} onChange={(v) => setD({ ...d, prior: v })} />
          <Field label={t('setup.taxRank')} bad={bad.rank} hint={t('setup.taxRankHint')}><input inputMode="numeric" dir="ltr" value={d.rank} onChange={set('rank')} className={`${field} nums`} /></Field>
          <Check label={t('setup.taxActive')} checked={d.active} onChange={(v) => setD({ ...d, active: v })} />
          <Actions busy={busy} ok={ok} editing={d.id > 0} onCancel={() => setD(blankTax(nextRank))} label={t('setup.save')} />
        </form>
      )}
    </div>
  )
}

// ── the tax authority ───────────────────────────────────────────────────────

/** A tax's type and sub-type as the authority's tables list them (T1 and V009 for VAT): shown under the tax,
 *  set by the owner. A credit note's document names each tax by them. */
function TaxCodes({ owner, rule, codes, reload }: { owner: boolean; rule: SetupTax; codes?: TaxEta; reload: () => Promise<void> }) {
  const { api, t } = useApp()
  const [open, setOpen] = useState(false)
  const [type, setType] = useState(codes?.taxType ?? '')
  const [sub, setSub] = useState(codes?.subType ?? '')
  const { busy, run } = useAct()
  const code = (x: string) => /^[0-9A-Za-z]{1,8}$/.test(x)
  const has = !!codes?.taxType
  if (!open) return (
    <p className="t-small mt-1 text-muted" data-tax-codes={rule.id}>
      {has ? t('eta.taxCodes', { type: codes!.taxType, sub: codes!.subType }) : t('eta.taxCodesNone')}
      {owner && <button type="button" onClick={() => setOpen(true)} className="ms-2 font-semibold text-ink underline underline-offset-4">{t('eta.setCodes')}</button>}
    </p>
  )
  return (
    <form className="mt-2 flex flex-wrap items-end gap-2" onSubmit={(e) => { e.preventDefault(); if (code(type) && code(sub)) run(() => api.setTaxEta(rule.id, type, sub), t('eta.codesSaved'), async () => { setOpen(false); await reload() }) }}>
      <label className="t-small text-ink">{t('eta.taxType')}<input dir="ltr" value={type} maxLength={8} onChange={(e) => setType(e.currentTarget.value.toUpperCase())} className="mt-1 block w-24 rounded-base border border-field bg-bg px-2 py-1.5 text-ink" /></label>
      <label className="t-small text-ink">{t('eta.subType')}<input dir="ltr" value={sub} maxLength={8} onChange={(e) => setSub(e.currentTarget.value.toUpperCase())} className="mt-1 block w-24 rounded-base border border-field bg-bg px-2 py-1.5 text-ink" /></label>
      <button type="submit" disabled={busy || !code(type) || !code(sub)} className="rounded-base bg-primary px-3 py-2 t-small font-semibold text-primary-ink disabled:opacity-40">{t('setup.save')}</button>
      <button type="button" onClick={() => setOpen(false)} className="rounded-base border border-line px-3 py-2 t-small font-semibold text-ink">{t('console.cancel')}</button>
    </form>
  )
}

const ETA_FIELDS = ['issuerId', 'activityCode', 'branchId', 'country', 'governate', 'regionCity', 'street', 'buildingNumber'] as const

/** The hotel's registration with the Egyptian Tax Authority, as a credit note's document names its issuer. The owner's. */
/**
 * The rules the books are kept under (src/Rules.mo). A hotel deployed before the rules were numbered
 * is at epoch 0: its night audit walks the checks it had then. The owner moves it to the next epoch, one
 * at a time; the act is a block in the log, so the books replay to the same state under any later build.
 */
function BookRules({ owner }: { owner: boolean }) {
  const { api, t } = useApp()
  const { num } = useFormat()
  const [r, setR] = useState<RulesView | null>(null)
  const [asking, setAsking] = useState(false)
  const { busy, run } = useAct()
  const load = useCallback(async () => { setR(await api.rules().catch(() => null)) }, [api])
  useEffect(() => { load() }, [load])
  if (r === null) return null
  const behind = r.epoch < r.current
  return (
    <section aria-labelledby="bookrules" className="mt-8 rounded-lg border border-line bg-surface p-5" data-rules={`${r.epoch}/${r.current}`}>
      <h2 id="bookrules" className="font-semibold text-ink">{t('setup.rules')}</h2>
      <p className="t-small mt-1 text-ink">{behind ? t('setup.rulesOlder', { n: num(r.walkSections), m: num(r.newestSections) }) : t('setup.rulesNewest', { n: num(r.walkSections) })}</p>
      {owner && behind && !asking && (
        <button type="button" onClick={() => setAsking(true)} className="mt-3 rounded-base border border-ink px-4 py-2 font-semibold text-ink">{t('setup.rulesAdopt')}</button>
      )}
      {owner && behind && asking && (
        <div className="mt-3">
          <p className="t-small font-semibold text-ink">{t('setup.rulesSure')}</p>
          <div className="mt-2 flex flex-wrap gap-3">
            <button type="button" disabled={busy} onClick={() => run(() => api.adoptRules(r.epoch + 1), t('setup.rulesDone'), async () => { setAsking(false); await load() })}
              className="rounded-base bg-primary px-4 py-2 font-semibold text-primary-ink disabled:opacity-50">{t('setup.rulesConfirm')}</button>
            <button type="button" onClick={() => setAsking(false)} className="rounded-base px-4 py-2 font-semibold text-ink underline">{t('setup.rulesNo')}</button>
          </div>
        </div>
      )}
    </section>
  )
}

function Registration({ owner }: { owner: boolean }) {
  const { api, t } = useApp()
  const [d, setD] = useState<EtaProfile | null>(null)
  const { busy, run } = useAct()
  const load = useCallback(async () => { try { setD(await api.etaProfile()) } catch { setD(null) } }, [api])
  useEffect(() => { load() }, [load])
  if (!d) return null
  const bytes = (x: string) => new TextEncoder().encode(x).length
  const bad = {
    issuerId: !/^[0-9A-Za-z]{1,32}$/.test(d.issuerId), activityCode: !/^[0-9]{4}$/.test(d.activityCode), branchId: !/^[0-9A-Za-z]{1,8}$/.test(d.branchId),
    country: !/^[A-Z]{2}$/.test(d.country), governate: !(bytes(d.governate) >= 1 && bytes(d.governate) <= 200), regionCity: !(bytes(d.regionCity) >= 1 && bytes(d.regionCity) <= 200),
    street: !(bytes(d.street) >= 1 && bytes(d.street) <= 200), buildingNumber: !(bytes(d.buildingNumber) >= 1 && bytes(d.buildingNumber) <= 200),
  }
  const ok = !Object.values(bad).some(Boolean)
  return (
    <form onSubmit={(e) => { e.preventDefault(); if (ok) run(() => api.setEtaProfile(d), t('eta.saved'), load) }}
      className="mt-10 grid max-w-3xl gap-5 border-t border-line pt-8 sm:grid-cols-2" data-setup-eta aria-labelledby="eta-head">
      <div className="sm:col-span-2">
        <h2 id="eta-head" className="t-h2 text-ink">{t('eta.title')}</h2>
        <p className="t-small mt-1 text-muted">{t('eta.lead')}</p>
      </div>
      <fieldset disabled={!owner} className="contents">
        {ETA_FIELDS.map((k) => (
          <Field key={k} label={t(`eta.${k}`)} bad={bad[k] && d[k] !== ''} hint={t(`eta.${k}Hint`)}>
            <input dir={k === 'governate' || k === 'regionCity' || k === 'street' ? 'auto' : 'ltr'} value={d[k]}
              onChange={(e) => { const v = e.currentTarget.value; setD({ ...d, [k]: k === 'country' ? v.toUpperCase() : v }) }} className={field} />
          </Field>
        ))}
      </fieldset>
      {owner && <div className="sm:col-span-2"><Actions busy={busy} ok={ok} editing={false} onCancel={() => {}} label={t('eta.save')} /></div>}
    </form>
  )
}
