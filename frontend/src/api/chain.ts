/**
 * The chain data source: the booking engine against the Luxor contract, through the boundary's /api.
 * The browser runtime (boundary.js) encodes the arguments and decodes the replies; the calls go to
 * this page's own origin, which proxies /api to the chain in front of it (the dev server, or the chain's
 * gateway). Nothing here ever reaches another chain by default.
 *
 * READ AFTER WRITE. Every update's reply carries the block it wrote; every view carries the block it
 * read. A view older than the last write this browser made is read again, a bounded number of times,
 * so a guest is never shown the state from before their own booking.
 */
import { photosFor } from './photos'
import { bool, boundary, f, nat, postQuery, queryBody, text, type Arg, type ChainConfig, type Field } from './wire'
import { closeEarly, earlyKey, earlyStore, takeEarly } from './early'
import { manyEditsHex } from './manyEdits'
import { PLAN_FIELDS, ROOM_TYPE_FIELDS, SEARCH_FIELDS, searchArgs } from './views'
export { chainConfig, type ChainConfig } from './wire'
import { chunkHash, hex, jwkFromSecret, linkSecret, newKey, publicHexOf, seal, sealCredential, sealFile, sha256Hex, sign } from './keys'
import type { TenantId } from '../theme/tenants'
import { TENANTS } from '../theme/tenants'
import {
  Refused,
  type Api, type Channel, type NightRevenue, type StaffBookResult, type AuthResult, type BedKind, type BookingStatus, type BookingView, type CalendarDay, type CancelResult, type ConfirmResult,
  type BlockView, type RoomingRow, type GridRow, type HoldView, type ManyEdit, type NightsEdit, type Offer, type PlanView, type PropertyView, type QuoteDetail, type RoomTypeView,
  type SealView, type SearchResult, type StayRequest, type TestScenario, type AuditStatus, type DualAct, type WaitView, type FolioLineView, type PaymentView,
  type HotelClock, type BoardRoom, type VacantRoom, type ExtraCategory, type BillLineView, type Role, type StaffRow,
  type SetupProperty, type SetupRoomType, type SetupPlan, type SetupTax, type TaxKindSetting, amenitiesOf, amenityMask,
  type CreditNoteRow, type CreditNoteLineView, type DeskMethod, type EtaProfile, type RefundView, type RefundState,
  type InclusionSetting, type InclusionView, type PackageLineView, type Per, type Rhythm,
  type CardView, type CardOnFileState, type CardDeskRow, type Guarantee,
  type MailAttach, type MailRow, type MailKind, type MailState, type MailFailure, type MailSetupView, type MailProviderView, type MailAccountSaved, type MailAccountInUse, type DnsCheckView,
} from './types'

const CREDIT_NOTE_ROW = [f('number'), f('invoice'), f('bookingId'), f('payerId'), f('issuedDay'), f('net'), f('taxes'), f('total'), f('lines'),
  f('maker', 'text'), f('checker', 'text'), f('atBlock')]
function toNoteRow(r: Record<string, unknown>): CreditNoteRow {
  const big = (v: unknown) => BigInt(v as bigint)
  return { number: Number(r.number), invoice: Number(r.invoice), bookingId: Number(r.bookingId), payerId: Number(r.payerId), issuedDay: Number(r.issuedDay),
    net: big(r.net), taxes: big(r.taxes), total: big(r.total), lines: Number(r.lines), maker: String(r.maker), checker: String(r.checker) }
}
const REFUND_FIELDS = [f('paymentId'), f('payerId'), f('card'), f('amount'), f('state', 'text'), f('attempts'), f('firstSlice'), f('excess'), f('written')]
function refundRows(rows: Record<string, unknown>[]): RefundView[] {
  return rows.map((r) => ({ paymentId: Number(r.paymentId), payerId: Number(r.payerId), card: Number(r.card), amount: BigInt(r.amount as bigint),
    state: String(r.state) as RefundState, attempts: Number(r.attempts), firstSlice: Number(r.firstSlice), excess: BigInt(r.excess as bigint) }))
}
const ETA_PROFILE = ['issuerId', 'activityCode', 'branchId', 'country', 'governate', 'regionCity', 'street', 'buildingNumber'] as const

const BILL_LINE = [f('id'), f('kind', 'text'), f('code'), f('night'), f('amount'), f('payerId'), f('title', 'text'), f('titleAr', 'text'), f('quantity'), f('unitAmount'),
  f('voided', 'bool'), f('voidable', 'bool'), f('atBlock')]
function toBillLine(r: Record<string, unknown>): BillLineView {
  return { id: Number(r.id), kind: String(r.kind) as FolioLineView['kind'], code: Number(r.code), night: Number(r.night), amount: BigInt(r.amount as bigint), payerId: Number(r.payerId),
    title: { en: String(r.title), ar: String(r.titleAr) || String(r.title) }, quantity: Number(r.quantity), unitAmount: BigInt(r.unitAmount as bigint),
    voided: Boolean(r.voided), voidable: Boolean(r.voidable) }
}




const OUTCOME: Field[] = [f('ok', 'bool'), f('kind', 'text'), f('reason', 'text'), f('block'), f('a'), f('b'), f('c')]
const BOOKING: Field[] = [f('ok', 'bool'), f('kind', 'text'), f('reason', 'text'), f('block'), f('fee'), f('refund'), f('id'), f('ref', 'text'), f('status', 'text'),
  f('roomTypeId'), f('planId'), f('arrival'), f('departure'), f('rooms'), f('adults'), f('children'), f('guestName', 'text'), f('charged'), f('credited'),
  f('paid'), f('outstanding'), f('penalty'), f('cancelDeadline'), f('refundable', 'bool'), f('nonce')]
const BOOKING_ROW: Field[] = [f('id'), f('ref', 'text'), f('status', 'text'), f('roomTypeId'), f('planId'), f('arrival'), f('departure'), f('rooms'), f('adults'),
  f('children'), f('guestName', 'text'), f('charged'), f('credited'), f('paid'), f('outstanding'), f('penalty'), f('cancelDeadline'), f('refundable', 'bool'), f('nonce'), f('atBlock')]

/** The contract's refusals are written in English; each kind a guest can meet has its Arabic here. */
const AR_REASON: Record<string, string> = {
  soldOut: 'لم تعد هناك غرف متاحة في إحدى ليالي هذه الإقامة.',
  stopSell: 'إحدى ليالي هذه الإقامة مغلقة للبيع.',
  nightClosed: 'إحدى ليالي هذه الإقامة غير متاحة للحجز.',
  closedToArrival: 'لا يُستقبل الوصول في هذا اليوم.',
  closedToDeparture: 'لا تُقبل المغادرة في هذا اليوم.',
  minStay: 'هذه الإقامة أقصر من الحد الأدنى لعدد الليالي.',
  maxStay: 'هذه الإقامة أطول من الحد الأقصى لعدد الليالي.',
  priceChanged: 'تغيّر السعر للتوّ. يُرجى مراجعة الإجمالي الجديد.',
  holdExpired: 'انتهت مهلة حجزك المؤقت.',
  holdNotLive: 'لم يعد هذا الحجز المؤقت قائماً.',
  tooManyHolds: 'لديك حجوزات مؤقتة كثيرة في هذا المتصفح.',
  holdShareCap: 'كثير من الغرف محجوزة مؤقتاً لهذه الليلة. حاول بعد قليل.',
  rateLimited: 'طلبات كثيرة من هذا المتصفح. انتظر قليلاً.',
  payment: 'لا يطابق الدفع هذا الحجز.',
  authUsed: 'استُخدم هذا الدفع من قبل.',
  notTheOwner: 'لا يمكن لهذا المتصفح أو الرابط تغيير الحجز.',
  bookingState: 'لم يعد هذا الإجراء ممكناً لهذا الحجز.',
  inThePast: 'هذا التاريخ مضى.',
  beyondHorizon: 'لا نستقبل الحجوزات لهذا الموعد بعد.',
  occupancy: 'لا يتّسع هذا النوع من الغرف لهذا العدد من الضيوف.',
  notConfigured: 'لم يُجهَّز الفندق بعد.',
  auditOpen: 'يجري الآن إغلاق يوم الفندق. حاول بعد دقائق.',
  // the setup screens: a member of staff meets these
  notAuthorised: 'ليست لديك صلاحية لهذا الإجراء.',
  codeTaken: 'هذا الرمز أو الرقم مستخدم بالفعل.',
  closedRate: 'هذا السعر متاح فقط برمز شركته أو برمز العرض الخاص به.',
  noSuchCode: 'هذا الرمز غير معروف لدى الفندق أو لم يعد متاحاً.',
  noSuchBlock: 'لا توجد هذه المجموعة المحجوزة.',
  blockReleased: 'أُفرج عن غرف هذه المجموعة وعادت للبيع؛ لم يعد الحجز منها ممكناً.',
  blockFull: 'لم تعد غرف المجموعة تكفي في إحدى ليالي هذه الإقامة.',
  promoClosed: 'عرض هذا الرمز لا ينطبق على هذا الحجز: انتهت مدة الحجز به، أو لا تشمل تواريخه هذه الإقامة، أو نفدت مرات استخدامه.',
  tooManyRoomTypes: 'بلغ الفندق الحد الأقصى لأنواع الغرف.',
  allotmentAboveRooms: 'في إحدى الليالي يزيد المعروض على الغرف المتبقية؛ اخفضه في صفحة الأسعار أولاً.',
  roomNotVacant: 'الغرفة مشغولة.',
  noSuchRoomType: 'نوع الغرفة هذا غير موجود.',
  // credit notes and refunds at the desk
  noSuchInvoice: 'لا توجد هذه الفاتورة في هذا الحجز.',
  otherBill: 'هذا السطر على فاتورة أخرى.',
  creditBeyondLine: 'المبلغ أكبر مما تبقّى من هذا السطر.',
  fourEyes: 'يجب أن يوافق عليه شخص آخر.',
  noSuchPayment: 'لا توجد هذه الدفعة في هذا الحجز.',
  noSuchTaxRule: 'لا توجد هذه الضريبة.',
  tooLong: 'النص أطول من المسموح.',
}

/** The setup views (Luxor.mo, "setup"): every field each setup act takes. */
const SETUP_PROPERTY: Field[] = [f('nameEn', 'text'), f('nameAr', 'text'), f('currency', 'text'), f('minorUnits'), f('checkInText', 'text'), f('checkOutText', 'text'),
  f('holdTtlHeights'), f('heightsPerRealMinute'), f('maxStayNights'), f('horizonDays'), f('maxRoomsPerBooking'), f('idRetentionDays'), f('atBlock')]
const SETUP_ROOM_TYPE: Field[] = [f('id'), f('code', 'text'), f('nameEn', 'text'), f('nameAr', 'text'), f('descEn', 'text'), f('descAr', 'text'), f('sizeSqm'),
  f('maxAdults'), f('maxChildren'), f('maxOccupancy'), f('bedKind', 'text'), f('bedCount'), f('amenities'), f('photos', 'text'), f('rank'), f('active', 'bool'), f('rooms'), f('atBlock')]
const SETUP_PLAN: Field[] = [f('id'), f('code', 'text'), f('nameEn', 'text'), f('nameAr', 'text'), f('discountBps'), f('refundable', 'bool'), f('freeCancelDaysBefore'),
  f('penaltyNights'), f('prepaid', 'bool'), f('modifiable', 'bool'), f('active', 'bool'), f('guarantee', 'text'), f('depositBps'), f('atBlock')]
/** A plan's guarantee as the contract names it (firstNight, prepaid, deposit). */
function guaranteeOf(r: Record<string, unknown>): Guarantee {
  return r.guarantee === 'deposit' ? 'deposit' : r.guarantee === 'prepaid' || r.prepaid ? 'prepaidInFull' : 'firstNightAuthorised'
}
const SETUP_TAX: Field[] = [f('id'), f('code', 'text'), f('nameEn', 'text'), f('nameAr', 'text'), f('kind', 'text'), f('bps'), f('amount'), f('onPriorTaxes', 'bool'),
  f('rank'), f('active', 'bool'), f('atBlock')]

const AUDIT: Field[] = [f('open', 'bool'), f('completed', 'bool'), f('items'), f('done'), f('failures'), f('walkDone', 'bool'), f('examined'), f('violations'),
  f('firstViolation', 'text'), f('businessDate')]

const CLOCK: Field[] = [f('set', 'bool'), f('zoneName', 'text'), f('zoneRule', 'text'), f('auditAt'), f('auto', 'bool'), f('runnerIsSelf', 'bool'),
  f('localDay', 'int'), f('localSecond'), f('zoneNow', 'text'), f('dueThrough', 'int'), f('businessDate'),
  f('lastUtc'), f('lastDay'), f('lastAct', 'text'), f('lastOk', 'bool'), f('lastReason', 'text'), f('lastSteps')]

function toClock(r: Record<string, unknown> | undefined): HotelClock {
  const due = Number(r?.dueThrough ?? -1)
  const lastUtc = Number(r?.lastUtc ?? 0)
  return { set: Boolean(r?.set), zoneName: String(r?.zoneName ?? ''), zoneRule: String(r?.zoneRule ?? ''), auditAt: Number(r?.auditAt ?? 0), auto: Boolean(r?.auto),
    localDay: Number(r?.localDay ?? 0), localSecond: Number(r?.localSecond ?? 0), zoneNow: String(r?.zoneNow ?? ''), dueThrough: due < 0 ? null : due,
    businessDate: Number(r?.businessDate ?? 0),
    last: lastUtc > 0 ? { at: new Date(lastUtc * 1000), day: Number(r?.lastDay ?? 0), act: String(r?.lastAct ?? ''), ok: Boolean(r?.lastOk), reason: String(r?.lastReason ?? ''),
      steps: Number(r?.lastSteps ?? 0) } : null }
}

function toAudit(r: Record<string, unknown> | undefined): AuditStatus {
  return { open: Boolean(r?.open), completed: Boolean(r?.completed), items: Number(r?.items ?? 0), done: Number(r?.done ?? 0), failures: Number(r?.failures ?? 0),
    walkDone: Boolean(r?.walkDone), examined: Number(r?.examined ?? 0), violations: Number(r?.violations ?? 0), firstViolation: String(r?.firstViolation ?? ''),
    businessDate: Number(r?.businessDate ?? 0) }
}

const STATUS: Record<string, BookingStatus> = { confirmed: 'confirmed', 'checked-in': 'checkedIn', 'checked-out': 'checkedOut', cancelled: 'cancelled', 'no-show': 'noShow' }
/** The contract's word for each status, for a filter sent to it. */
const STATUS_TEXT = Object.fromEntries(Object.entries(STATUS).map(([k, v]) => [v, k])) as Record<BookingStatus, string>


/** The contract's word for each role (Enums.roleText), and a principal sent as the hex of its bytes. */
const ROLE_OF: Record<string, Role> = { owner: 'owner', revenue: 'revenue', 'front-desk': 'frontDesk', auditor: 'auditor', housekeeping: 'housekeeping' }
const principalArg = (hexId: string): Arg => ({ type: 'principal', value: hexId })

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms))

export function chainApi(tenantId: TenantId, cfg: ChainConfig): Api {
  const tenant = TENANTS[tenantId]
  let lastBlock = 0
  let contract: { principalHex: string; guestDataKey: string } | null = null
  let property: PropertyView | null = null
  const holdKeys = new Map<number, JsonWebKey>()

  async function post(path: string, cid: number, method: string, args: Arg[]) {
    const b = boundary()
    const arg = b.bytesToHex(b.encodeArgs(args))
    // signed by this browser's key (boundary.js): the chain refuses an unsigned call that names a sender
    const body = { canister_id: cid, method, arg, ...(await b.signCall(cid, method, arg)) }
    const r = await fetch(`${cfg.base}${path}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) }).then((x) => x.json())
    return r as { status?: string; reply?: string; error?: string; message_hash?: string }
  }

  async function q(method: string, args: Arg[], fields: Field[], cid = cfg.luxorCid) {
    const body = queryBody(cid, method, args)
    closeEarly()
    // a reply the early script already asked for, taken once; a failed or missing one is asked again here
    const early = takeEarly(earlyStore(), earlyKey(cid, method, body.arg), Date.now())
    const kept = early ? await early.catch(() => null) : null
    const r = kept && kept.status === 'success' && kept.reply ? kept : await postQuery(cfg.base, body)
    if (r.status !== 'success' || !r.reply) throw new Error(`${method}: ${r.error ?? 'no reply'}`)
    return boundary().decodeVecRecord(r.reply, fields)
  }

  /** A view that carries atBlock is read again until it has seen this browser's last write. */
  async function fresh(method: string, args: Arg[], fields: Field[]) {
    for (let i = 0; i < 12; i++) {
      const rows = await q(method, args, fields)
      const at = rows.length ? Number(rows[0].atBlock ?? lastBlock) : lastBlock
      if (at >= lastBlock) return rows
      await wait(250)
    }
    return q(method, args, fields)
  }

  async function u(method: string, args: Arg[], fields: Field[], cid = cfg.luxorCid) {
    const r = await post('/api/call', cid, method, args)
    if (r.error || !r.message_hash) throw new Error(`${method}: ${r.error ?? 'rejected'}`)
    const end = Date.now() + 30_000
    while (Date.now() < end) {
      await wait(200)
      const rec = await fetch(`${cfg.base}/api/receipt?hash=${r.message_hash}`).then((x) => x.json()).catch(() => ({}))
      if (rec.status === 'success') {
        const rows = boundary().decodeVecRecord(rec.reply, fields)
        const blk = rows.length ? Number(rows[0].block ?? 0) : 0
        if (blk > lastBlock) lastBlock = blk
        return rows
      }
      if (rec.status === 'error') throw new Error(`${method}: ${rec.error ?? 'failed'}`)
    }
    throw new Error(`${method}: no receipt`)
  }

  function refuse(row: Record<string, unknown>): never {
    const kind = String(row.kind ?? 'refused')
    const reason = String(row.reason ?? '')
    throw new Refused(kind, { en: reason, ar: AR_REASON[kind] ?? reason })
  }

  async function contractInfo() {
    if (!contract) {
      const rows = await q('contractView', [], [f('principalHex', 'text'), f('guestDataKey', 'text'), f('identity', 'text'), f('atBlock')])
      contract = { principalHex: String(rows[0].principalHex), guestDataKey: String(rows[0].guestDataKey) }
    }
    return contract
  }

  const toBooking = (r: Record<string, unknown>): BookingView => ({
    id: Number(r.id), ref: String(r.ref), status: STATUS[String(r.status)] ?? 'confirmed', roomTypeId: Number(r.roomTypeId), planId: Number(r.planId),
    arrival: Number(r.arrival), departure: Number(r.departure), rooms: Number(r.rooms), adults: Number(r.adults), children: Number(r.children),
    guestName: String(r.guestName), charged: BigInt(r.charged as bigint), credited: BigInt(r.credited as bigint), paid: BigInt(r.paid as bigint),
    outstanding: BigInt(r.outstanding as bigint), penalty: BigInt(r.penalty as bigint),
    cancelDeadline: r.refundable ? Number(r.cancelDeadline) : null, refundable: Boolean(r.refundable), block: Number(r.block ?? r.atBlock ?? 0),
  })

  async function nonceOf(ref: string) {
    const rows = await q('manageNonceView', [text(ref)], [f('nonce'), f('key', 'text')])
    if (!rows.length) throw new Refused('notFound', { en: 'No booking matches this link.', ar: 'لا يوجد حجز يطابق هذا الرابط.' })
    return { nonce: Number(rows[0].nonce), key: String(rows[0].key) }
  }

  async function signManage(ref: string, secret: string, act: string, argsHash = '') {
    const jwk = jwkFromSecret(secret)
    if (!jwk) throw new Refused('notFound', { en: 'This link is incomplete.', ar: 'هذا الرابط غير مكتمل.' })
    const c = await contractInfo()
    const { nonce, key } = await nonceOf(ref)
    if (publicHexOf(jwk) !== key) throw new Refused('notFound', { en: 'This link does not match the booking.', ar: 'هذا الرابط لا يطابق الحجز.' })
    const id = parseRef(ref)
    return sign(jwk, `LUXOR-MANAGE-v1|${c.principalHex}|${id}|${act}|${argsHash}|${nonce}`)
  }

  // ── guest email: the contract keeps an outbox and makes no outbound request; the shared mail relay
  //    pulls it and sends through the hotel's own account. The relay's address is this page's setting. ──

  const MAIL_ROW = [f('outboxId'), f('kind', 'text'), f('state', 'text'), f('attempts'), f('failure', 'text'), f('notBefore'), f('atBlock')]
  const toMailRow = (r: Record<string, unknown>): MailRow => ({ outboxId: Number(r.outboxId), kind: String(r.kind) as MailKind, state: String(r.state) as MailState,
    attempts: Number(r.attempts), failure: String(r.failure) as MailFailure, notBefore: Number(r.notBefore) })

  /** The relay's key a guest's address is sealed to, '' while the hotel has connected no relay. */
  async function mailKey() {
    const rows = await fresh('mailKeyView', [], [f('mailKey', 'text'), f('on', 'bool'), f('atBlock')])
    return String(rows[0]?.mailKey ?? '')
  }

  function noRelay(): never {
    throw new Refused('notConfigured', { en: 'This site has no mail service set up. Ask whoever runs it to add the mail relay address.', ar: 'لا توجد خدمة بريد مُعدّة لهذا الموقع. اطلب ممن يديره إضافة عنوان خدمة البريد.' })
  }

  /** A request to the relay: its answer, or a refusal in its own words (the relay answers {ok: false, why}). */
  async function relay<T>(path: string, body?: unknown): Promise<T> {
    if (!cfg.mailRelay) noRelay()
    let r: Response
    try {
      r = await fetch(`${cfg.mailRelay}${path}`, body === undefined ? {} : { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) })
    } catch {
      throw new Refused('unavailable', { en: 'The mail service did not answer. Try again in a minute.', ar: 'لم تستجب خدمة البريد. حاول مرة أخرى بعد دقيقة.' })
    }
    const j = await r.json().catch(() => ({})) as { why?: string }
    if (!r.ok) throw new Refused(r.status === 429 ? 'tooMany' : 'relay', { en: j.why ?? `The mail service refused (${r.status}).`, ar: j.why ?? `رفضت خدمة البريد (${r.status}).` })
    return j as T
  }

  async function relayKeys() {
    return relay<{ contract: string; mailer: string; mailKey: string; transportKey: string }>(`/v1/hotels/${cfg.luxorCid}/key`)
  }

  /** Seal the address to the relay's mail key and give it to the booking: by its manage key (a guest) or by the desk. */
  async function attachMailTo(by: { ref: string; secret: string } | { bookingId: number }, email: string, lang: 'en' | 'ar'): Promise<MailAttach> {
    if (!email.trim()) return 'noAddress'
    try {
      const key = await mailKey()
      if (!key) return 'notConnected'
      const sealed = await seal(email.trim(), key)
      const rows = 'ref' in by
        ? await u('attachMail', [text(by.ref), text(await signManage(by.ref, by.secret, 'mail', await sha256Hex(sealed))), text(''), text(sealed), text(lang)], OUTCOME)
        : await u('attachMailByStaff', [text(''), nat(by.bookingId), text(sealed), text(lang)], OUTCOME)
      return rows[0]?.ok ? 'queued' : 'failed'
    } catch {
      return 'failed'      // the booking stands; its manage page offers the address again
    }
  }

  return {
    source: 'chain',

    async property(): Promise<PropertyView> {
      const rows = await fresh('propertyView', [], [f('nameEn', 'text'), f('nameAr', 'text'), f('currency', 'text'), f('minorUnits'), f('businessDate'),
        f('checkInEn', 'text'), f('checkOutEn', 'text'), f('maxStayNights'), f('maxRoomsPerBooking'), f('holdRealSeconds'), f('height'), f('atBlock'), f('identity', 'text'), f('idRetentionDays')])
      if (!rows.length) throw new Refused('notConfigured', { en: 'The hotel is not set up yet.', ar: 'لم يُجهَّز الفندق بعد.' })
      const r = rows[0]
      property = {
        name: { en: String(r.nameEn), ar: String(r.nameAr) }, currency: String(r.currency), minorUnits: Number(r.minorUnits), businessDate: Number(r.businessDate),
        checkIn: tenant.checkIn, checkOut: tenant.checkOut, maxStayNights: Number(r.maxStayNights), maxRoomsPerBooking: Number(r.maxRoomsPerBooking),
        holdRealSeconds: Number(r.holdRealSeconds), idRetentionDays: Number(r.idRetentionDays), atBlock: Number(r.atBlock),
      }
      return property
    },

    async roomTypes(): Promise<RoomTypeView[]> {
      const rows = await q('roomTypesView', [], ROOM_TYPE_FIELDS)
      return rows.filter((r) => r.active).map((r) => {
        const seed = tenant.rooms.find((x) => x.code === r.code)
        const mask = Number(r.amenities)
        return {
          id: Number(r.id), code: String(r.code), name: { en: String(r.nameEn), ar: String(r.nameAr) }, desc: { en: String(r.descEn), ar: String(r.descAr) },
          sizeSqm: Number(r.sizeSqm), maxAdults: Number(r.maxAdults), maxChildren: Number(r.maxChildren), maxOccupancy: Number(r.maxOccupancy),
          bedKind: String(r.bedKind) as BedKind, bedCount: Number(r.bedCount), amenities: amenitiesOf(mask),
          view: seed?.view ?? { en: '', ar: '' }, photos: photosFor(String(r.photos)), rooms: Number(r.rooms),
        }
      })
    },

    async plans(code?: string): Promise<PlanView[]> {
      const rows = code ? await q('plansCodedView', [text(code)], PLAN_FIELDS) : await q('plansView', [], PLAN_FIELDS)
      return rows.filter((r) => r.active).map((r) => ({
        id: Number(r.id), code: String(r.code), name: { en: String(r.nameEn), ar: String(r.nameAr) }, refundable: Boolean(r.refundable),
        freeCancelDaysBefore: Number(r.freeCancelDaysBefore), penaltyNights: Number(r.penaltyNights),
        guarantee: guaranteeOf(r), discountBps: Number(r.discountBps), depositBps: Number(r.depositBps ?? 0), keepsCard: Boolean(r.keepsCard),
      }))
    },

    async calendar(rt, from, days): Promise<CalendarDay[]> {
      const rows = await q('calendarView', [nat(rt), nat(from), nat(days)], [f('day'), f('lowest'), f('bookable', 'bool'), f('closedToArrival', 'bool'), f('closedToDeparture', 'bool'), f('minStay')])
      return rows.map((r) => ({ day: Number(r.day), from: Number(r.lowest) ? BigInt(r.lowest as bigint) : null, bookable: Boolean(r.bookable),
        closedToArrival: Boolean(r.closedToArrival), closedToDeparture: Boolean(r.closedToDeparture), minStay: Number(r.minStay) }))
    },

    async search(req: StayRequest): Promise<SearchResult> {
      const rows = req.code ? await fresh('searchCodedView', [...searchArgs(req), text(req.code)], SEARCH_FIELDS) : await fresh('searchView', searchArgs(req), SEARCH_FIELDS)
      // a code that opens nothing is one row for room type 0: the whole search is refused for it
      if (rows.length === 1 && Number(rows[0].roomTypeId) === 0 && !rows[0].ok) refuse(rows[0])
      const offers: Offer[] = []
      const unavailable: SearchResult['unavailable'] = []
      for (const r of rows) {
        if (r.ok) {
          const total = BigInt(r.total as bigint)
          offers.push({ roomTypeId: Number(r.roomTypeId), planId: Number(r.planId), total, roomSubtotal: BigInt(r.roomSubtotal as bigint), taxTotal: BigInt(r.taxTotal as bigint),
            perNightAvg: total / BigInt(req.nights * req.rooms), left: Number(r.left), cancelDeadline: r.refundable ? Number(r.cancelDeadline) : null,
            guarantee: BigInt(r.guarantee as bigint), quoteHash: String(r.quoteHash), packageTotal: BigInt(r.packageTotal as bigint) })
        }
      }
      for (const r of rows) {
        const rt = Number(r.roomTypeId)
        if (!r.ok && !offers.some((o) => o.roomTypeId === rt) && !unavailable.some((x) => x.roomTypeId === rt)) {
          unavailable.push({ roomTypeId: rt, kind: String(r.kind), reason: { en: String(r.reason), ar: AR_REASON[String(r.kind)] ?? String(r.reason) } })
        }
      }
      return { offers, unavailable, atBlock: rows.length ? Number(rows[0].atBlock) : 0 }
    },

    async quoteDetail(rt, planId, req): Promise<QuoteDetail> {
      const [lines, taxes] = await Promise.all([
        req.code
          ? q('quoteNightsCodedView', [nat(rt), nat(planId), nat(req.arrival), nat(req.nights), nat(req.rooms), nat(req.adults), nat(req.children), text(req.code)], [f('day'), f('ruleId'), f('amount')])
          : q('quoteNightsView', [nat(rt), nat(planId), nat(req.arrival), nat(req.nights), nat(req.rooms), nat(req.adults), nat(req.children)], [f('day'), f('ruleId'), f('amount')]),
        q('taxesView', [], [f('id'), f('code', 'text'), f('nameEn', 'text'), f('nameAr', 'text')]),
      ])
      // the package's lines, named from the plan's package (read side by side)
      const [pkgRows, incs] = await Promise.all([
        q('quotePackageView', [nat(rt), nat(planId), nat(req.arrival), nat(req.nights), nat(req.rooms), nat(req.adults), nat(req.children), text(req.code ?? '')],
          [f('day'), f('slot'), f('extraId'), f('quantity'), f('unit'), f('net'), f('tax')]),
        this.packageOf(planId),
      ])
      const pkg: PackageLineView[] = pkgRows.map((l) => ({ day: Number(l.day), slot: Number(l.slot), extraId: Number(l.extraId),
        name: incs.find((x) => x.extraId === Number(l.extraId))?.name ?? { en: '', ar: '' }, quantity: Number(l.quantity),
        unit: BigInt(l.unit as bigint), net: BigInt(l.net as bigint), tax: BigInt(l.tax as bigint) }))
      const name = (id: number) => { const t = taxes.find((x) => Number(x.id) === id); return { en: String(t?.nameEn ?? ''), ar: String(t?.nameAr ?? '') } }
      const nights: QuoteDetail['nights'] = []
      for (let d = req.arrival; d < req.arrival + req.nights; d++) {
        const of = lines.filter((l) => Number(l.day) === d)
        nights.push({ day: d, room: of.filter((l) => Number(l.ruleId) === 0).reduce((a, l) => a + BigInt(l.amount as bigint), 0n),
          taxes: of.filter((l) => Number(l.ruleId) !== 0).map((l) => ({ ruleId: Number(l.ruleId), name: name(Number(l.ruleId)), amount: BigInt(l.amount as bigint) })) })
      }
      const taxLines = taxes.map((t) => ({ ruleId: Number(t.id), name: name(Number(t.id)),
        amount: lines.filter((l) => Number(l.ruleId) === Number(t.id)).reduce((a, l) => a + BigInt(l.amount as bigint), 0n) }))
      const roomSubtotal = nights.reduce((a, n) => a + n.room, 0n)
      const packageTotal = pkg.reduce((a, l) => a + l.net + l.tax, 0n)
      return { nights, taxLines, roomSubtotal, package: pkg, packageTotal, total: roomSubtotal + taxLines.reduce((a, t) => a + t.amount, 0n) + packageTotal }
    },

    async packageOf(planId: number): Promise<InclusionView[]> {
      const rows = await fresh('packageView', [nat(planId)], [f('slot'), f('extraId'), f('code', 'text'), f('nameEn', 'text'), f('nameAr', 'text'), f('category', 'text'),
        f('price'), f('quantity'), f('rhythm', 'text'), f('per', 'text'), f('atBlock')])
      return rows.map((r) => ({ slot: Number(r.slot), extraId: Number(r.extraId), code: String(r.code), name: { en: String(r.nameEn), ar: String(r.nameAr) },
        category: String(r.category) as ExtraCategory, price: BigInt(r.price as bigint), quantity: Number(r.quantity), rhythm: String(r.rhythm) as Rhythm, per: String(r.per) as Per }))
    },

    async setPlanInclusions(planId: number, inclusions: InclusionSetting[]) {
      const wire = inclusions.map((x) => `${x.extraId}:${x.quantity}:${x.rhythm}:${x.per}`).join(';')
      const rows = await u('setPlanInclusions', [text(''), nat(planId), text(wire)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async placeHold(rt, planId, req, quoteHash): Promise<HoldView> {
      const key = await newKey()
      const args = [nat(rt), nat(planId), nat(req.arrival), nat(req.nights), nat(req.rooms), nat(req.adults), nat(req.children), text(quoteHash), text(key.publicHex)]
      const rows = req.code ? await u('placeHoldWithCode', [...args, text(req.code)], OUTCOME) : await u('placeHold', args, OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
      const holdId = Number(rows[0].a)
      holdKeys.set(holdId, key.jwk)
      try { sessionStorage.setItem(`luxor:holdkey:${holdId}`, JSON.stringify(key.jwk)) } catch { /* the key lives in memory for this page */ }
      const p = property ?? (await this.property())
      return { holdId, total: BigInt(rows[0].c as bigint), expiresAtMs: Date.now() + p.holdRealSeconds * 1000, block: Number(rows[0].block) }
    },

    async releaseHold(holdId) {
      const jwk = holdKeyOf(holdId)
      if (!jwk) return
      const c = await contractInfo()
      await u('releaseHold', [nat(holdId), text(await sign(jwk, `LUXOR-HOLD-v1|${c.principalHex}|${holdId}|release`))], OUTCOME)
    },

    // the TEST gateway: only a scenario is sent, never a card number
    async authorise(scenario: TestScenario, amount, ref, keepOnFile = false): Promise<AuthResult> {
      const c = await contractInfo()
      const p = property ?? (await this.property())
      const rows = await u(keepOnFile ? 'authorizeOnFile' : 'authorize', [text(scenario), nat(amount), text(p.currency), { type: 'principal', value: c.principalHex }, nat(ref)],
        [f('ok', 'bool'), f('authId'), f('reason', 'text'), f('testMode', 'bool')], cfg.gatewayCid)
      const r = rows[0]
      return { ok: Boolean(r?.ok), authId: Number(r?.authId ?? 0), reason: String(r?.reason ?? '') || undefined }
    },

    async confirmHold(holdId, guest, authId, session = ''): Promise<ConfirmResult> {
      const c = await contractInfo()
      if (!c.guestDataKey) throw new Refused('notConfigured', { en: 'The hotel has not set up its key for guest details yet.', ar: 'لم يُعِدّ الفندق مفتاح بيانات الضيوف بعد.' })
      const jwk = holdKeyOf(holdId)
      if (!jwk) throw new Refused('notTheOwner', { en: 'This hold was made in another window.', ar: 'تم هذا الحجز المؤقت في نافذة أخرى.' })
      const manage = await newKey()
      const rows = await u('confirmHold', [nat(holdId), text(await sign(jwk, `LUXOR-HOLD-v1|${c.principalHex}|${holdId}|confirm`)), text(guest.name),
        text(await seal(guest.email, c.guestDataKey)), text(guest.note), text(manage.publicHex), text(tokenHex(session)), nat(authId)], BOOKING)
      const r = rows[0]
      if (!r?.ok) refuse(r ?? {})
      const booking = toBooking(r)
      const manageSecret = linkSecret(manage.jwk)
      const mail = await attachMailTo({ ref: booking.ref, secret: manageSecret }, guest.email, guest.lang ?? 'en')
      return { booking, manageSecret, captured: BigInt(r.paid as bigint) > 0n, mail }
    },

    async manage(ref, secret): Promise<BookingView> {
      for (let i = 0; i < 6; i++) {
        const sig = await signManage(ref, secret, 'view')
        const [rows, plan] = await Promise.all([fresh('manageView', [text(ref), text(sig)], BOOKING_ROW), q('managePlanView', [text(ref), text(sig)], PLAN_FIELDS)])
        if (rows.length) return { ...toBooking(rows[0]), ...(plan.length ? { planName: { en: String(plan[0].nameEn), ar: String(plan[0].nameAr) } } : {}) }
        await wait(300)   // the nonce may have moved between the two reads; sign again
      }
      throw new Refused('notFound', { en: 'No booking matches this link.', ar: 'لا يوجد حجز يطابق هذا الرابط.' })
    },

    async manageCard(ref, secret): Promise<CardView | null> {
      const rows = await fresh('manageCardView', [text(ref), text(await signManage(ref, secret, 'view'))],
        [f('state', 'text'), f('deadline'), f('agreedBlock'), f('charge', 'text'), f('chargeAmount'), f('due'), f('atBlock')])
      const r = rows[0]
      if (!r) return null
      return { state: String(r.state) as CardOnFileState, deadline: Number(r.deadline), charge: String(r.charge) as CardView['charge'],
        chargeAmount: BigInt(r.chargeAmount as bigint), due: BigInt(r.due as bigint) }
    },

    async manageMail(ref, secret) {
      const [rows, key] = await Promise.all([fresh('manageMailView', [text(ref), text(await signManage(ref, secret, 'view'))], MAIL_ROW), mailKey()])
      return { rows: rows.map(toMailRow), connected: key !== '' }
    },

    async attachMailFromLink(ref, secret, email, lang) {
      const out = await attachMailTo({ ref, secret }, email, lang)
      if (out === 'notConnected') throw new Refused('notConfigured', { en: 'The hotel does not send emails yet.', ar: 'لا يرسل الفندق رسائل بريد بعد.' })
      if (out !== 'queued') throw new Refused('invalid', { en: 'The address could not be saved. Check it and try again.', ar: 'تعذّر حفظ العنوان. تحقق منه وحاول مرة أخرى.' })
    },

    async bookingMail(bookingId) {
      await requireStaff()
      return (await fresh('bookingMailView', [text(''), nat(bookingId)], MAIL_ROW)).map(toMailRow)
    },

    async mailSetup(): Promise<MailSetupView> {
      await requireStaff()
      const rows = await fresh('mailSetupView', [text('')], [f('connected', 'bool'), f('mailer', 'text'), f('authorised', 'text'), f('tested', 'text'), f('on', 'bool'),
        f('waiting'), f('more', 'bool'), f('atBlock')])
      const r = rows[0] ?? {}
      return { connected: Boolean(r.connected), mailer: String(r.mailer ?? ''), authorised: String(r.authorised ?? ''), tested: String(r.tested ?? ''), on: Boolean(r.on),
        waiting: Number(r.waiting ?? 0), more: Boolean(r.more), relay: cfg.mailRelay }
    },

    async connectMailRelay() {
      const k = await relayKeys()
      const rows = await u('setMailRelay', [text(''), text(k.mailer), text(k.mailKey)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async mailProviders(): Promise<MailProviderView[]> {
      return (await relay<{ providers: MailProviderView[] }>('/v1/providers')).providers
    },

    async saveMailAccount(account): Promise<MailAccountSaved> {
      const k = await relayKeys()
      const credential = { ...account.fields, provider: account.provider, from: account.from.trim(), fromName: account.fromName.trim(), testTo: account.testTo.trim(), lang: account.lang }
      const envelope = await sealCredential(JSON.stringify(credential), k.transportKey)
      const saved = await relay<MailAccountSaved>(`/v1/hotels/${cfg.luxorCid}/credential`, { envelope })
      // the digest the owner approves is the one this browser computes over what it sent, never the relay's word alone
      if (saved.digest !== (await sha256Hex(envelope))) throw new Refused('relay', { en: 'The mail service answered for another account. Try again.', ar: 'ردّت خدمة البريد بحساب آخر. حاول مرة أخرى.' })
      return saved
    },

    async mailAccountInUse(): Promise<MailAccountInUse> {
      const a = await relay<MailAccountInUse>(`/v1/hotels/${cfg.luxorCid}/account`)
      // the console shows only what the hotel's own books name: the relay's answer for another digest is not believed
      const named = (await this.mailSetup()).authorised
      return a.digest === named ? a : { digest: named, onFile: false }
    },

    async startMailSignIn(account) {
      const r = await relay<{ url: string }>(`/v1/hotels/${cfg.luxorCid}/oauth/${account.provider}/start`,
        { from: account.from.trim(), fromName: account.fromName.trim(), testTo: account.testTo.trim(), lang: account.lang, returnTo: location.origin + location.pathname })
      return r.url
    },

    async approveMailAccount(digest) {
      const rows = await u('authoriseMailCredential', [text(''), text(digest)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async checkMailDomain(domain, provider, selector): Promise<DnsCheckView> {
      return relay<DnsCheckView>(`/v1/dns?${new URLSearchParams({ domain, provider, selector })}`)
    },

    async sendMailTest(digest) {
      return relay(`/v1/hotels/${cfg.luxorCid}/test`, { digest })
    },

    async setGuestEmail(on) {
      const rows = await u('setMailOn', [text(''), bool(on)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async putCardOnFile(ref, secret, authId) {
      const rows = await u('putCardOnFile', [text(ref), text(await signManage(ref, secret, 'card', String(authId))), text(''), nat(authId)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async cardDesk(day): Promise<CardDeskRow[]> {
      await requireStaff()
      const rows = await fresh('cardsView', [text(''), nat(day)], [f('bookingId'), f('ref', 'text'), f('guestName', 'text'), f('arrival'), f('kind', 'text'),
        f('day'), f('amount'), f('outstanding'), f('atBlock')])
      return rows.map((r) => ({ bookingId: Number(r.bookingId), ref: String(r.ref), guestName: String(r.guestName), arrival: Number(r.arrival),
        kind: String(r.kind) as CardDeskRow['kind'], day: Number(r.day), amount: BigInt(r.amount as bigint), outstanding: BigInt(r.outstanding as bigint) }))
    },

    async cardRule() {
      const rows = await fresh('cardRuleView', [], [f('on', 'bool'), f('fromBlock'), f('atBlock')])
      return Boolean(rows[0]?.on)
    },

    async rules() {
      const r = (await fresh('rulesView', [], [f('epoch'), f('current'), f('walkSections'), f('newestSections'), f('atBlock')]))[0] ?? {}
      return { epoch: Number(r.epoch ?? 0), current: Number(r.current ?? 0), walkSections: Number(r.walkSections ?? 0), newestSections: Number(r.newestSections ?? 0) }
    },

    async adoptRules(epoch) {
      const rows = await u('adoptRules', [text(''), nat(epoch)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async requireCardOnFile() {
      const rows = await u('requireCardOnFile', [text('')], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async setPlanDeposit(planId, bps) {
      const rows = await u('setPlanDeposit', [text(''), nat(planId), nat(bps)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async cancel(ref, secret): Promise<CancelResult> {
      const rows = await u('cancelBooking', [text(ref), text(await signManage(ref, secret, 'cancel')), text('')], BOOKING)
      const r = rows[0]
      if (!r?.ok) refuse(r ?? {})
      return { booking: toBooking(r), fee: BigInt(r.fee as bigint), refund: BigInt(r.refund as bigint) }
    },

    async seal(): Promise<SealView> {
      const rows = await q('sealView', [], [f('cashOk', 'bool'), f('paid'), f('captured'), f('refunds'), f('invariants'), f('lastAuditDay'), f('lastAuditExamined'),
        f('lastAuditViolations'), f('closedDays'), f('atBlock')])
      const r = rows[0]
      const ok = Boolean(r.cashOk) && Number(r.lastAuditViolations) === 0
      const examined = Number(r.lastAuditExamined)
      return { ok, scope: examined > 0 ? 'full' : 'cash', invariants: Number(r.invariants), examined, violations: ok ? [] : ['see the audit'] }
    },

    async grid(from, days): Promise<GridRow[]> {
      await requireStaff()
      const rows = await fresh('gridView', [text(''), nat(from), nat(Math.min(days, 31)), nat(1), nat(16)], [f('roomTypeId'), f('day'), f('allotment'), f('sold'), f('held'), f('blocked'),
        f('bar'), f('minStay'), f('maxStay'), f('closedToArrival', 'bool'), f('closedToDeparture', 'bool'), f('stopSell', 'bool'), f('exists', 'bool')])
      const by = new Map<number, GridRow>()
      for (const r of rows) {
        const rt = Number(r.roomTypeId)
        if (!by.has(rt)) by.set(rt, { roomTypeId: rt, cells: [] })
        by.get(rt)!.cells.push({ day: Number(r.day), allotment: Number(r.allotment), sold: Number(r.sold), held: Number(r.held), blocked: Number(r.blocked),
          bar: r.exists ? BigInt(r.bar as bigint) : null, minStay: Number(r.minStay), closedToArrival: Boolean(r.closedToArrival),
          closedToDeparture: Boolean(r.closedToDeparture), stopSell: Boolean(r.stopSell) })
      }
      if (by.size === 0) throw new Refused('notAuthorised', { en: 'Sign in as hotel staff to see rates and availability.', ar: 'سجّل الدخول بصفتك من موظفي الفندق لعرض الأسعار والتوفّر.' })
      return [...by.values()]
    },

    async auditStatus(day): Promise<AuditStatus> {
      await requireStaff()
      const rows = await fresh('auditView', [text(''), nat(day)], AUDIT)
      return toAudit(rows[0])
    },

    async openAudit(day) {
      const rows = await u('openAudit', [text(''), nat(day)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async advanceAudit(day) {
      const rows = await u('advanceAudit', [text(''), nat(day), nat(8)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
      return toAudit((await fresh('auditView', [text(''), nat(day)], AUDIT))[0])
    },

    async closeDay(day) {
      const rows = await u('closeDay', [text(''), nat(day)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
      property = null
      return Number(rows[0].a)
    },

    async hotelClock() {
      return toClock((await q('hotelClockView', [], CLOCK))[0])
    },

    async setHotelClock(c) {
      const rows = await u('setHotelClock', [text(''), text(c.zoneName), text(c.zoneRule), nat(c.auditAt), bool(c.auto)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async staffPlans() {
      const rows = await this.setupPlans()
      return rows.filter((p) => p.active).map((p) => ({ id: p.id, code: p.code, name: p.name, refundable: p.refundable, freeCancelDaysBefore: p.freeCancelDaysBefore,
        penaltyNights: p.penaltyNights, guarantee: p.guarantee ?? (p.prepaid ? 'prepaidInFull' as const : 'firstNightAuthorised' as const), discountBps: p.discountBps,
        depositBps: p.depositBps ?? 0 }))
    },

    async codeInfo(code) {
      const rows = await q('codeView', [text(code)], [f('ok', 'bool'), f('kind', 'text'), f('reason', 'text'), f('name', 'text'), f('planId'), f('atBlock')])
      const r = rows[0]
      if (!r) return { ok: false, kind: 'noSuchCode', reason: { en: '', ar: AR_REASON.noSuchCode }, name: '', planIds: [] }
      return { ok: Boolean(r.ok), kind: String(r.kind), reason: { en: String(r.reason), ar: AR_REASON[String(r.kind)] ?? String(r.reason) }, name: String(r.name),
        planIds: rows.map((x) => Number(x.planId)).filter((x) => x > 0) }
    },

    async companies() {
      await requireStaff()
      const rows = await fresh('companiesView', [text('')], [f('id'), f('code', 'text'), f('name', 'text'), f('active', 'bool'), f('atBlock')])
      return rows.map((r) => ({ id: Number(r.id), code: String(r.code), name: String(r.name), active: Boolean(r.active) }))
    },

    async upsertCompany(id, co) {
      const rows = await u('upsertCompany', [text(''), nat(id), text(co.code), text(co.name), bool(co.active)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
      return Number(rows[0].a)
    },

    async planAccess() {
      await requireStaff()
      const rows = await fresh('planAccessView', [text('')], [f('planId'), f('companyId'), f('closed', 'bool'), f('atBlock')])
      return rows.map((r) => ({ planId: Number(r.planId), companyId: Number(r.companyId), closed: Boolean(r.closed) }))
    },

    async setPlanAccess(planId, companyId, closed) {
      const rows = await u('setPlanAccess', [text(''), nat(planId), nat(companyId), bool(closed)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async promos() {
      await requireStaff()
      const rows = await fresh('promosView', [text('')], [f('id'), f('code', 'text'), f('name', 'text'), f('planId'), f('bookFrom'), f('bookUntil'), f('stayFrom'),
        f('stayUntil'), f('maxUses'), f('used'), f('active', 'bool'), f('atBlock')])
      return rows.map((r) => ({ id: Number(r.id), code: String(r.code), name: String(r.name), planId: Number(r.planId), bookFrom: Number(r.bookFrom),
        bookUntil: Number(r.bookUntil), stayFrom: Number(r.stayFrom), stayUntil: Number(r.stayUntil), maxUses: Number(r.maxUses), used: Number(r.used),
        active: Boolean(r.active) }))
    },

    async upsertPromo(id, p) {
      const rows = await u('upsertPromo', [text(''), nat(id), text(p.code), text(p.name), nat(p.planId), nat(p.bookFrom), nat(p.bookUntil), nat(p.stayFrom),
        nat(p.stayUntil), nat(p.maxUses), bool(p.active)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
      return Number(rows[0].a)
    },

    async blocks() {
      await requireStaff()
      const all: BlockView[] = []
      // the blocks a page at a time, 50 to a page, from the id after the last one read
      for (let from = 1; ; ) {
        const rows = await fresh('blocksView', [text(''), nat(from)], [f('id'), f('name', 'text'), f('companyId'), f('roomTypeId'), f('planId'), f('arrival'),
          f('departure'), f('rooms'), f('cutoff'), f('open', 'bool'), f('roomNights'), f('pickedNights'), f('heldNights'), f('atBlock')])
        for (const r of rows) all.push({ id: Number(r.id), name: String(r.name), companyId: Number(r.companyId), roomTypeId: Number(r.roomTypeId), planId: Number(r.planId),
          arrival: Number(r.arrival), departure: Number(r.departure), rooms: Number(r.rooms), cutoff: Number(r.cutoff), open: Boolean(r.open),
          roomNights: Number(r.roomNights), pickedNights: Number(r.pickedNights), heldNights: Number(r.heldNights) })
        if (rows.length < 50) return all
        from = Number(rows[rows.length - 1].id) + 1
      }
    },

    async upsertBlock(id, b) {
      const rows = await u('upsertBlock', [text(''), nat(id), text(b.name), nat(b.companyId), nat(b.roomTypeId), nat(b.planId), nat(b.arrival), nat(b.nights),
        nat(b.rooms), nat(b.cutoff)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
      return Number(rows[0].a)
    },

    async releaseBlock(id) {
      const rows = await u('releaseBlock', [text(''), nat(id)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async blockNights(id) {
      await requireStaff()
      const rows = await fresh('blockNightsView', [text(''), nat(id)], [f('day'), f('picked'), f('held'), f('atBlock')])
      return rows.map((r) => ({ day: Number(r.day), picked: Number(r.picked), held: Number(r.held) }))
    },

    async roomingList(id) {
      await requireStaff()
      const all: RoomingRow[] = []
      for (let after = 0; ; ) {
        const rows = await fresh('roomingListView', [text(''), nat(id), nat(after)], BOOKING_ROW)
        for (const r of rows) { const b = toBooking(r); all.push({ id: b.id, ref: b.ref, status: b.status, arrival: b.arrival, departure: b.departure, rooms: b.rooms, guestName: b.guestName, outstanding: b.outstanding }) }
        if (rows.length < 50) return all
        after = Number(rows[rows.length - 1].id)
      }
    },

    async blockQuote(id, req) {
      await requireStaff()
      const rows = await fresh('blockQuoteView', [text(''), nat(id), nat(req.arrival), nat(req.nights), nat(req.rooms), nat(req.adults), nat(req.children)], SEARCH_FIELDS)
      const r = rows[0]
      if (!r?.ok) refuse(r ?? {})
      const total = BigInt(r.total as bigint)
      return { roomTypeId: Number(r.roomTypeId), planId: Number(r.planId), total, roomSubtotal: BigInt(r.roomSubtotal as bigint), taxTotal: BigInt(r.taxTotal as bigint),
        perNightAvg: total / BigInt(req.nights * req.rooms), left: Number(r.left), cancelDeadline: r.refundable ? Number(r.cancelDeadline) : null,
        guarantee: BigInt(r.guarantee as bigint), quoteHash: String(r.quoteHash), packageTotal: BigInt(r.packageTotal as bigint) }
    },

    async pickUp(blockId, offer, req, guest): Promise<StaffBookResult> {
      const c = await contractInfo()
      const email = guest.email.trim()
      if (email && !c.guestDataKey) throw new Refused('notConfigured', { en: 'The hotel has not set up its key for guest details yet.', ar: 'لم يُعِدّ الفندق مفتاح بيانات الضيوف بعد.' })
      const manage = await newKey()
      const rows = await u('pickUpFromBlock', [text(''), nat(blockId), nat(req.arrival), nat(req.nights), nat(req.rooms), nat(req.adults), nat(req.children),
        text(offer.quoteHash), text(guest.name), text(email ? await seal(email, c.guestDataKey) : ''), text(guest.note), text(manage.publicHex)], OUTCOME)
      const r = rows[0]
      if (!r?.ok) refuse(r ?? {})
      const id = Number(r.a)
      const found = await fresh('bookingsView', [text(''), nat(id + 1), nat(1)], BOOKING_ROW)
      const booking = found.map(toBooking).find((b) => b.id === id)
      if (!booking) throw new Refused('notFound', { en: 'The booking was made; reload to see it.', ar: 'تم الحجز؛ أعد التحميل لعرضه.' })
      return { booking, manageSecret: linkSecret(manage.jwk), mail: await attachMailTo({ bookingId: id }, email, guest.lang ?? 'en') }
    },

    async extras() {
      const rows = await fresh('extrasView', [], [f('id'), f('code', 'text'), f('nameEn', 'text'), f('nameAr', 'text'), f('category', 'text'), f('price'),
        f('taxed', 'bool'), f('active', 'bool'), f('atBlock')])
      return rows.map((r) => ({ id: Number(r.id), code: String(r.code), name: { en: String(r.nameEn), ar: String(r.nameAr) }, category: String(r.category) as ExtraCategory,
        price: BigInt(r.price as bigint), taxed: Boolean(r.taxed), active: Boolean(r.active) }))
    },

    async upsertExtra(id, e) {
      const rows = await u('upsertExtra', [text(''), nat(id), text(e.code), text(e.name.en), text(e.name.ar), text(e.category), nat(e.price), bool(e.taxed), bool(e.active)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
      return Number(rows[0].a)
    },

    async setupProperty() {
      await requireStaff()
      const rows = await fresh('setupPropertyView', [text('')], SETUP_PROPERTY)
      if (!rows.length) return null
      const r = rows[0]
      return { name: { en: String(r.nameEn), ar: String(r.nameAr) }, currency: String(r.currency), minorUnits: Number(r.minorUnits),
        checkInText: String(r.checkInText), checkOutText: String(r.checkOutText), holdTtlHeights: Number(r.holdTtlHeights),
        heightsPerRealMinute: Number(r.heightsPerRealMinute), maxStayNights: Number(r.maxStayNights), horizonDays: Number(r.horizonDays),
        maxRoomsPerBooking: Number(r.maxRoomsPerBooking), idRetentionDays: Number(r.idRetentionDays) }
    },

    async configureProperty(p: SetupProperty) {
      const rows = await u('configureProperty', [text(''), text(p.currency), nat(p.minorUnits), text(p.name.en), text(p.name.ar), text(p.checkInText), text(p.checkOutText),
        nat(p.holdTtlHeights), nat(p.heightsPerRealMinute), nat(p.maxStayNights), nat(p.horizonDays), nat(p.maxRoomsPerBooking), nat(p.idRetentionDays)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
      property = null
    },

    async setupRoomTypes(): Promise<SetupRoomType[]> {
      await requireStaff()
      const rows = await fresh('setupRoomTypesView', [text('')], SETUP_ROOM_TYPE)
      return rows.map((r) => ({ id: Number(r.id), code: String(r.code), name: { en: String(r.nameEn), ar: String(r.nameAr) }, desc: { en: String(r.descEn), ar: String(r.descAr) },
        sizeSqm: Number(r.sizeSqm), maxAdults: Number(r.maxAdults), maxChildren: Number(r.maxChildren), maxOccupancy: Number(r.maxOccupancy),
        bedKind: String(r.bedKind) as BedKind, bedCount: Number(r.bedCount), amenities: amenitiesOf(Number(r.amenities)), photos: String(r.photos),
        rank: Number(r.rank), active: Boolean(r.active), rooms: Number(r.rooms) }))
    },

    async upsertRoomType(id, x) {
      const rows = await u('upsertRoomType', [text(''), nat(id), text(x.code), text(x.name.en), text(x.name.ar), text(x.desc.en), text(x.desc.ar), nat(x.sizeSqm),
        nat(x.maxAdults), nat(x.maxChildren), nat(x.maxOccupancy), text(x.bedKind), nat(x.bedCount), nat(amenityMask(x.amenities)), text(x.photos), nat(x.rank), bool(x.active)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
      return Number(rows[0].a)
    },

    async upsertRoom(id, roomTypeId, number, outOfOrder) {
      const rows = await u('upsertRoom', [text(''), nat(id), nat(roomTypeId), text(number), bool(outOfOrder)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
      return Number(rows[0].a)
    },

    async setupPlans(): Promise<SetupPlan[]> {
      await requireStaff()
      const rows = await fresh('setupPlansView', [text('')], SETUP_PLAN)
      return rows.map((r) => ({ id: Number(r.id), code: String(r.code), name: { en: String(r.nameEn), ar: String(r.nameAr) }, discountBps: Number(r.discountBps),
        refundable: Boolean(r.refundable), freeCancelDaysBefore: Number(r.freeCancelDaysBefore), penaltyNights: Number(r.penaltyNights), prepaid: Boolean(r.prepaid),
        modifiable: Boolean(r.modifiable), active: Boolean(r.active), guarantee: guaranteeOf(r), depositBps: Number(r.depositBps ?? 0) }))
    },

    async upsertRatePlan(id, x) {
      const rows = await u('upsertRatePlan', [text(''), nat(id), text(x.code), text(x.name.en), text(x.name.ar), nat(x.discountBps), bool(x.refundable),
        nat(x.freeCancelDaysBefore), nat(x.penaltyNights), bool(x.prepaid), bool(x.modifiable), bool(x.active)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
      return Number(rows[0].a)
    },

    async setupTaxes(): Promise<SetupTax[]> {
      await requireStaff()
      const rows = await fresh('setupTaxesView', [text('')], SETUP_TAX)
      return rows.map((r) => ({ id: Number(r.id), code: String(r.code), name: { en: String(r.nameEn), ar: String(r.nameAr) }, kind: String(r.kind) as TaxKindSetting,
        bps: Number(r.bps), amount: BigInt(r.amount as bigint), onPriorTaxes: Boolean(r.onPriorTaxes), rank: Number(r.rank), active: Boolean(r.active) }))
    },

    async upsertTaxRule(id, x) {
      const rows = await u('upsertTaxRule', [text(''), nat(id), text(x.code), text(x.name.en), text(x.name.ar), text(x.kind), nat(x.bps), nat(x.amount),
        bool(x.onPriorTaxes), nat(x.rank), bool(x.active)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
      return Number(rows[0].a)
    },

    async bill(bookingId) {
      await requireStaff()
      const [ws, ls] = await Promise.all([
        fresh('billView', [text(''), nat(bookingId)], [f('payerId'), f('name', 'text'), f('charges'), f('credits'), f('taxes'), f('paid'), f('due'), f('open'), f('invoice'), f('atBlock')]),
        fresh('billLinesView', [text(''), nat(bookingId)], BILL_LINE),
      ])
      const big = (v: unknown) => BigInt(v as bigint)
      return {
        windows: ws.map((w) => ({ payerId: Number(w.payerId), name: String(w.name), charges: big(w.charges), credits: big(w.credits), taxes: big(w.taxes), paid: big(w.paid),
          due: big(w.due), open: big(w.open), invoice: Number(w.invoice) || null })),
        lines: ls.map(toBillLine),
      }
    },

    async postCharge(bookingId, extraId, quantity, amount, payerId) {
      const rows = await u('postCharge', [text(''), nat(bookingId), nat(extraId), nat(quantity), nat(amount), nat(payerId)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async addPayer(bookingId, name) {
      const rows = await u('addPayer', [text(''), nat(bookingId), text(name)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
      return Number(rows[0].a)
    },

    async routeLines(bookingId, lineIds, payerId) {
      const rows = await u('routeLines', [text(''), nat(bookingId), { type: 'vec', inner: { type: 'nat' }, value: lineIds.map((x) => BigInt(x)) }, nat(payerId)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async settleShare(bookingId, payerId, authId) {
      const rows = await u('settleShare', [text(''), nat(bookingId), nat(payerId), nat(authId)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async issueInvoice(bookingId, payerId) {
      const rows = await u('issueInvoice', [text(''), nat(bookingId), nat(payerId)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
      return Number(rows[0].a)
    },

    async invoice(number) {
      await requireStaff()
      const rows = await fresh('invoiceView', [text(''), nat(number)], [f('number'), f('bookingId'), f('ref', 'text'), f('payerId'), f('payerName', 'text'),
        f('guestName', 'text'), f('issuedDay'), f('charges'), f('credits'), f('taxes'), f('paid'), f('hotelEn', 'text'), f('hotelAr', 'text'), f('currency', 'text'), f('minorUnits')])
      const r = rows[0]
      if (!r) return null
      const lines = (await fresh('billLinesView', [text(''), nat(Number(r.bookingId))], BILL_LINE)).map(toBillLine).filter((l) => l.payerId === Number(r.payerId))
      const big = (v: unknown) => BigInt(v as bigint)
      return { number: Number(r.number), bookingId: Number(r.bookingId), ref: String(r.ref), payerId: Number(r.payerId), payerName: String(r.payerName), guestName: String(r.guestName),
        issuedDay: Number(r.issuedDay), charges: big(r.charges), credits: big(r.credits), taxes: big(r.taxes), paid: big(r.paid), hotel: { en: String(r.hotelEn), ar: String(r.hotelAr) }, lines }
    },

    async creditNotes(bookingId) {
      await requireStaff()
      return (await fresh('creditNotesView', [text(''), nat(bookingId)], CREDIT_NOTE_ROW)).map(toNoteRow)
    },

    async creditNote(number) {
      await requireStaff()
      const rows = await fresh('creditNoteView', [text(''), nat(number)], [f('number'), f('invoice'), f('invoiceDay'), f('bookingId'), f('ref', 'text'), f('payerId'),
        f('payerName', 'text'), f('guestName', 'text'), f('issuedDay'), f('net'), f('taxes'), f('total'), f('maker', 'text'), f('checker', 'text'), f('hotelEn', 'text'),
        f('hotelAr', 'text'), f('currency', 'text'), f('minorUnits'), f('atBlock')])
      const r = rows[0]
      if (!r) return null
      const items = await q('creditNoteLinesView', [text(''), nat(number)], [f('id'), f('source'), f('sourceKind', 'text'), f('title', 'text'), f('titleAr', 'text'),
        f('night'), f('amount'), f('tax', 'bool')])
      const lineItems: CreditNoteLineView[] = items.map((x) => ({ id: Number(x.id), source: Number(x.source), sourceKind: String(x.sourceKind) as FolioLineView['kind'],
        title: { en: String(x.title), ar: String(x.titleAr) || String(x.title) }, night: Number(x.night), amount: BigInt(x.amount as bigint), tax: Boolean(x.tax) }))
      return { ...toNoteRow({ ...r, lines: lineItems.length }), invoiceDay: Number(r.invoiceDay), ref: String(r.ref), payerName: String(r.payerName),
        guestName: String(r.guestName), hotel: { en: String(r.hotelEn), ar: String(r.hotelAr) }, lineItems }
    },

    async creditNoteEta(number) {
      await requireStaff()
      const rows = await fresh('creditNoteEtaView', [text(''), nat(number)], [f('json', 'text'), f('digest', 'text'), f('total'), f('missing', 'text'), f('atBlock')])
      const r = rows[0]
      if (!r) return null
      return { json: String(r.json), digest: String(r.digest), total: BigInt(r.total as bigint), missing: String(r.missing).split('\n').filter(Boolean) }
    },

    async creditedLines(bookingId) {
      await requireStaff()
      const rows = await fresh('creditedLinesView', [text(''), nat(bookingId)], [f('lineId'), f('credited'), f('atBlock')])
      return new Map(rows.map((r) => [Number(r.lineId), BigInt(r.credited as bigint)]))
    },

    async proposeCreditNote(bookingId, invoice, lineIds, amounts, justification) {
      const nats = (xs: (number | bigint)[]) => ({ type: 'vec', inner: { type: 'nat' }, value: xs.map((x) => BigInt(x)) })
      const rows = await u('proposeCreditNote', [text(''), nat(bookingId), nat(invoice), nats(lineIds), nats(amounts), text(justification)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
      return Number(rows[0].a)
    },

    async proposeDeskRefund(bookingId, paymentId, method, reference, justification) {
      const rows = await u('proposeDeskRefund', [text(''), nat(bookingId), nat(paymentId), text(method), text(reference), text(justification)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
      return Number(rows[0].a)
    },

    async deskRefunds(bookingId) {
      await requireStaff()
      const rows = await fresh('deskRefundsView', [text(''), nat(bookingId)], [f('paymentId'), f('method', 'text'), f('reference', 'text'), f('day'),
        f('maker', 'text'), f('checker', 'text'), f('atBlock')])
      return rows.map((r) => ({ paymentId: Number(r.paymentId), method: String(r.method) as DeskMethod, reference: String(r.reference), day: Number(r.day),
        maker: String(r.maker), checker: String(r.checker) }))
    },

    async refunds(bookingId) {
      await requireStaff()
      return refundRows(await fresh('refundsView', [text(''), nat(bookingId)], REFUND_FIELDS))
    },

    async creditNoteRefund(number) {
      await requireStaff()
      return refundRows(await fresh('creditNoteRefundView', [text(''), nat(number)], REFUND_FIELDS))
    },

    async etaProfile() {
      await requireStaff()
      const rows = await fresh('etaProfileView', [text('')], [...ETA_PROFILE.map((k) => f(k, 'text')), f('atBlock')])
      const r = rows[0] ?? {}
      return Object.fromEntries(ETA_PROFILE.map((k) => [k, String(r[k] ?? '')])) as unknown as EtaProfile
    },

    async setEtaProfile(p) {
      const rows = await u('setEtaProfile', [text(''), ...ETA_PROFILE.map((k) => text(p[k]))], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async taxEta() {
      await requireStaff()
      const rows = await fresh('taxEtaView', [text('')], [f('taxRuleId'), f('taxType', 'text'), f('subType', 'text'), f('atBlock')])
      return rows.map((r) => ({ taxRuleId: Number(r.taxRuleId), taxType: String(r.taxType), subType: String(r.subType) }))
    },

    async setTaxEta(taxRuleId, taxType, subType) {
      const rows = await u('setTaxEta', [text(''), nat(taxRuleId), text(taxType), text(subType)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async proposals() {
      await requireStaff()
      const rows = await fresh('proposalsView', [text('')], [f('id'), f('act', 'text'), f('bookingId'), f('ref', 'text'), f('amount'), f('text', 'text'),
        f('maker', 'text'), f('mine', 'bool'), f('expiresAt'), f('height')])
      return rows.map((r) => ({ id: Number(r.id), act: String(r.act) as DualAct, bookingId: Number(r.bookingId), ref: String(r.ref),
        amount: BigInt(r.amount as bigint), text: String(r.text), mine: Boolean(r.mine) }))
    },

    async propose(act, bookingId, amount, words, justification) {
      const rows = await u('propose', [text(''), text(act), nat(bookingId), nat(amount), text(words), text(justification)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
      return Number(rows[0].a)
    },

    async approve(id) {
      const rows = await u('approve', [text(''), nat(id)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async reject(id, reason) {
      const rows = await u('reject', [text(''), nat(id), text(reason)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async identity() {
      const rows = await q('contractView', [], [f('principalHex', 'text'), f('guestDataKey', 'text'), f('identity', 'text'), f('atBlock')])
      return String(rows[0]?.identity) === 'memphis' ? 'memphis' : 'transportKey'
    },

    async openSession(session) {
      const rows = await u('openSession', [text(tokenHex(session))], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async myStays(session) {
      const rows = await fresh('myStaysView', [text(tokenHex(session))], BOOKING_ROW)
      return rows.map(toBooking).sort((a, b) => b.arrival - a.arrival)
    },

    async myWaitlist(session): Promise<WaitView[]> {
      const rows = await q('myWaitlistView', [text(tokenHex(session))], [f('id'), f('roomTypeId'), f('arrival'), f('nights'), f('rooms'), f('adults'), f('children'),
        f('state', 'text'), f('offeredHold'), f('offerTotal'), f('offerExpiresAt'), f('height')])
      return rows.map((r) => ({ id: Number(r.id), roomTypeId: Number(r.roomTypeId), arrival: Number(r.arrival), nights: Number(r.nights), rooms: Number(r.rooms),
        state: String(r.state) as WaitView['state'], offeredHold: Number(r.offeredHold), offerTotal: BigInt(r.offerTotal as bigint) }))
    },

    async joinWaitlist(session, rt, req) {
      const rows = await u('joinWaitlist', [text(tokenHex(session)), nat(rt), nat(req.arrival), nat(req.nights), nat(req.rooms), nat(req.adults), nat(req.children)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
      return Number(rows[0].a)
    },

    async leaveWaitlist(session, id) {
      const rows = await u('leaveWaitlist', [text(tokenHex(session)), nat(id)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async bookings(beforeId, limit) {
      await requireStaff()
      const rows = await fresh('bookingsView', [text(''), nat(beforeId), nat(limit)], BOOKING_ROW)
      const list = rows.map(toBooking)
      return { rows: list, next: list.length === limit && list[list.length - 1].id > 1 ? list[list.length - 1].id : null }
    },

    async bookingsFiltered(q, cursor, limit) {
      await requireStaff()
      const rows = await fresh('bookingsPageView', [text(''), text(q.status ? STATUS_TEXT[q.status] : ''), nat(q.from), nat(q.to), text(cursor), nat(limit)],
        [...BOOKING_ROW, f('kind', 'text'), f('next', 'text')])
      const next = rows.length ? String(rows[0].next) : ''
      // a "more" row says the scan budget ran out before a match; it carries only where to resume
      return { rows: rows.filter((r) => r.kind === 'booking').map(toBooking), next: next || null }
    },

    async bookingByRef(ref) {
      await requireStaff()
      const rows = await fresh('bookingByRefView', [text(''), text(ref.trim().toUpperCase())], BOOKING_ROW)
      return rows.length ? toBooking(rows[0]) : null
    },

    async folio(bookingId) {
      await requireStaff()
      const rows = await q('folioView', [text(''), nat(bookingId)], [f('id'), f('kind', 'text'), f('night'), f('amount'), f('block')])
      return rows.map((r) => ({ id: Number(r.id), kind: String(r.kind) as FolioLineView['kind'], night: Number(r.night), amount: BigInt(r.amount as bigint), block: Number(r.block) }))
    },

    async payments(bookingId) {
      await requireStaff()
      const rows = await q('paymentsView', [text(''), nat(bookingId)], [f('id'), f('kind', 'text'), f('state', 'text'), f('amount'), f('gatewayAuth'), f('attempts'), f('block')])
      return rows.map((r) => ({ id: Number(r.id), kind: String(r.kind) as PaymentView['kind'], state: String(r.state) as PaymentView['state'], amount: BigInt(r.amount as bigint),
        gatewayAuth: Number(r.gatewayAuth), attempts: Number(r.attempts), block: Number(r.block) }))
    },

    async history(bookingId, beforeBlock) {
      await requireStaff()
      const rows = await q('bookingHistoryView', [text(''), nat(bookingId), nat(beforeBlock)], [f('kind', 'text'), f('block'), f('day'), f('act', 'text')])
      const more = rows.find((r) => r.kind === 'more')
      return { acts: rows.filter((r) => r.kind === 'act').map((r) => ({ block: Number(r.block), day: Number(r.day), act: String(r.act) })), more: more ? Number(more.block) : null }
    },

    async arrivals(day) {
      await requireStaff()
      const rows = await fresh('arrivalsView', [text(''), nat(day)], BOOKING_ROW)
      return rows.map((r) => ({ booking: toBooking(r), roomNumbers: [] }))
    },

    async inHouse() {
      await requireStaff()
      const rows = await fresh('inHouseView', [text('')], [...BOOKING_ROW, f('roomNumbers', 'text')])
      return rows.map((r) => ({ booking: toBooking(r), roomNumbers: String(r.roomNumbers).split(',').filter(Boolean) }))
    },

    async vacantRooms(rt) {
      const rows = await fresh('vacantRoomsView', [text(''), nat(rt)], [f('id'), f('number', 'text'), f('cleaning', 'text'), f('atBlock')])
      return rows.map((r) => ({ id: Number(r.id), number: String(r.number), cleaning: String(r.cleaning) as VacantRoom['cleaning'] }))
    },

    async housekeeping() {
      await requireStaff(['housekeeping'])
      const out: BoardRoom[] = []
      let after = 0
      for (;;) {
        const rows = await fresh('housekeepingView', [text(''), nat(after), nat(200)], [f('id'), f('number', 'text'), f('roomTypeId'), f('outOfOrder', 'bool'),
          f('cleaning', 'text'), f('cleanedBy', 'text'), f('inspectedBy', 'text'), f('cleanedByMe', 'bool'), f('inspectedByMe', 'bool'), f('outReason', 'text'), f('outFrom'), f('outUntil'),
          f('changedDay'), f('occupiedBy'), f('departure'), f('atBlock')])
        const day = (v: unknown) => (Number(v) === 0 ? null : Number(v))
        for (const r of rows) {
          out.push({ id: Number(r.id), number: String(r.number), roomTypeId: Number(r.roomTypeId), outOfOrder: Boolean(r.outOfOrder),
            cleaning: String(r.cleaning) as BoardRoom['cleaning'], cleanedBy: String(r.cleanedBy), inspectedBy: String(r.inspectedBy), cleanedByMe: Boolean(r.cleanedByMe), inspectedByMe: Boolean(r.inspectedByMe),
            outReason: String(r.outReason), outFrom: day(r.outFrom), outUntil: day(r.outUntil), changedDay: day(r.changedDay), occupiedBy: Number(r.occupiedBy), departure: day(r.departure) })
        }
        if (rows.length < 200) return out
        after = Number(rows[rows.length - 1].id)
      }
    },

    async markRoom(roomId, cleaning) {
      const rows = await u('markRoom', [text(''), nat(roomId), text(cleaning)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async takeRoomOutOfOrder(roomId, reason, untilDay) {
      const rows = await u('takeRoomOutOfOrder', [text(''), nat(roomId), text(reason), nat(untilDay)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async returnRoomToService(roomId) {
      const rows = await u('returnRoomToService', [text(''), nat(roomId)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async checkIn(bookingId, roomIds) {
      const rows = await u('checkIn', [text(''), nat(bookingId), { type: 'vec', inner: { type: 'nat' }, value: roomIds.map((x) => BigInt(x)) }], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async moveRoom(bookingId, fromRoomId, toRoomId) {
      const rows = await u('moveRoom', [text(''), nat(bookingId), nat(fromRoomId), nat(toRoomId)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async bookByStaff(channel, offer, req, guest, roomIds): Promise<StaffBookResult> {
      const c = await contractInfo()
      const email = guest.email.trim()
      if (email && !c.guestDataKey) throw new Refused('notConfigured', { en: 'The hotel has not set up its key for guest details yet.', ar: 'لم يُعِدّ الفندق مفتاح بيانات الضيوف بعد.' })
      const manage = await newKey()
      const args = [text(''), text(channel), nat(offer.roomTypeId), nat(offer.planId), nat(req.arrival), nat(req.nights), nat(req.rooms),
        nat(req.adults), nat(req.children), text(offer.quoteHash), text(guest.name), text(email ? await seal(email, c.guestDataKey) : ''), text(guest.note),
        text(manage.publicHex), { type: 'vec', inner: { type: 'nat' }, value: roomIds.map((x) => BigInt(x)) } as Arg]
      const rows = req.code ? await u('bookByStaffWithCode', [...args, text(req.code)], OUTCOME) : await u('bookByStaff', args, OUTCOME)
      const r = rows[0]
      if (!r?.ok) refuse(r ?? {})
      const id = Number(r.a)
      const found = await fresh('bookingsView', [text(''), nat(id + 1), nat(1)], BOOKING_ROW)
      const booking = found.map(toBooking).find((b) => b.id === id)
      if (!booking) throw new Refused('notFound', { en: 'The booking was made; reload to see it.', ar: 'تم الحجز؛ أعد التحميل لعرضه.' })
      return { booking, manageSecret: linkSecret(manage.jwk), mail: await attachMailTo({ bookingId: id }, email, guest.lang ?? 'en') }
    },

    async staffBooking(bookingId) {
      await requireStaff()
      const rows = await q('staffBookingView', [text(''), nat(bookingId)], [f('channel', 'text'), f('madeBy', 'text'), f('day')])
      return rows.length ? { channel: String(rows[0].channel) as Channel, madeBy: String(rows[0].madeBy), day: Number(rows[0].day) } : null
    },

    async dayFigures(fromDay, days) {
      await requireFigures()
      const rows = await fresh('dayFiguresView', [text(''), nat(fromDay), nat(days)], [f('day'), f('roomsTotal'), f('roomsOut'), f('roomsSold'), f('roomRevenue'),
        f('arrivals'), f('noShows'), f('pickupBookings'), f('pickupNights'), f('pickupRevenue'), f('pickupFrom'), f('closed', 'bool'), f('atBlock')])
      return rows.map((r) => ({ day: Number(r.day), roomsTotal: Number(r.roomsTotal), roomsOut: Number(r.roomsOut), roomsSold: Number(r.roomsSold),
        roomRevenue: BigInt(r.roomRevenue as bigint), arrivals: Number(r.arrivals), noShows: Number(r.noShows), pickupBookings: Number(r.pickupBookings),
        pickupNights: Number(r.pickupNights), pickupRevenue: BigInt(r.pickupRevenue as bigint), closed: Boolean(r.closed) }))
    },

    async dayRevenue(fromDay, days) {
      await requireFigures()
      const rows = await fresh('dayRevenueView', [text(''), nat(fromDay), nat(days)], [f('day'), f('roomTypeId'), f('planId'), f('roomNights'), f('revenue'), f('atBlock')])
      return rows.map((r) => ({ day: Number(r.day), roomTypeId: Number(r.roomTypeId), planId: Number(r.planId), roomNights: Number(r.roomNights), revenue: BigInt(r.revenue as bigint) }))
    },

    async onTheBooks(fromDay, days) {
      await requireFigures()
      // the view reads the bookings in pages of 50 in arrival order; each page names where the next starts
      const sums = new Map<string, NightRevenue>()
      let afterArrival = 0
      let afterId = 0
      for (let pages = 0; ; pages++) {
        if (pages >= 400) throw new Refused('tooMany', { en: 'Too many bookings to add up here.', ar: 'عدد الحجوزات أكبر من أن يُجمع هنا.' })
        const rows = await fresh('onTheBooksView', [text(''), nat(fromDay), nat(days), nat(afterArrival), nat(afterId), nat(50)],
          [f('night'), f('roomTypeId'), f('planId'), f('roomNights'), f('revenue'), f('nextArrival'), f('nextId'), f('done', 'bool'), f('atBlock')])
        if (!rows.length) break
        for (const r of rows) {
          if (Number(r.roomNights) === 0) continue
          const k = `${r.night}/${r.roomTypeId}/${r.planId}`
          const was = sums.get(k) ?? { day: Number(r.night), roomTypeId: Number(r.roomTypeId), planId: Number(r.planId), roomNights: 0, revenue: 0n }
          sums.set(k, { ...was, roomNights: was.roomNights + Number(r.roomNights), revenue: was.revenue + BigInt(r.revenue as bigint) })
        }
        if (rows[0].done) break
        afterArrival = Number(rows[0].nextArrival); afterId = Number(rows[0].nextId)
      }
      return [...sums.values()].sort((a, b) => a.day - b.day || a.roomTypeId - b.roomTypeId || a.planId - b.planId)
    },

    async settleAtDesk(bookingId, authId) {
      const rows = await u('settleAtDesk', [text(''), nat(bookingId), nat(authId)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async checkOut(bookingId) {
      const rows = await u('checkOut', [text(''), nat(bookingId)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async captureId(bookingId, file) {
      const c = await contractInfo()
      if (!c.guestDataKey) throw new Refused('notConfigured', { en: 'The hotel has not set up its key for guest details yet.', ar: 'لم يُعِدّ الفندق مفتاح بيانات الضيوف بعد.' })
      const plain = new Uint8Array(await file.arrayBuffer())
      const sealed = await sealFile(plain, c.guestDataKey)
      const PART = 48 * 1024
      const parts: Uint8Array[] = []
      for (let i = 0; i < sealed.ciphertext.length; i += PART) parts.push(sealed.ciphertext.slice(i, i + PART))
      const hashes = await Promise.all(parts.map(chunkHash))
      const begin = await u('beginIdUpload', [text(''), nat(bookingId), nat(sealed.ciphertext.length), text(hashes.join(','))],
        [f('ok', 'bool'), f('kind', 'text'), f('reason', 'text'), f('block'), f('blobId', 'text')])
      if (!begin[0]?.ok) refuse(begin[0] ?? {})
      const blobId = String(begin[0].blobId)
      for (let i = 0; i < parts.length; i++) {
        const r = await u('putIdChunk', [text(''), text(blobId), nat(i), text(hex(parts[i]))], OUTCOME)
        if (!r[0]?.ok) refuse(r[0] ?? {})
      }
      const done = await u('fileIdDocument', [text(''), nat(bookingId), text(blobId), text(sealed.plainHash), nat(plain.length), text(file.type || 'image/jpeg'), text(sealed.fileKey)], OUTCOME)
      if (!done[0]?.ok) refuse(done[0] ?? {})
    },

    async idDocuments(bookingId) {
      const rows = await fresh('idDocumentsView', [text(''), nat(bookingId)], [f('documentId'), f('blobId', 'text'), f('chunks'), f('mime', 'text'), f('plainSize'),
        f('fileKey', 'text'), f('erased', 'bool'), f('eraseDay')])
      return rows.map((r) => ({ documentId: Number(r.documentId), erased: Boolean(r.erased), eraseDay: Number(r.eraseDay), plainSize: Number(r.plainSize) }))
    },

    async staff() {
      await requireStaff(['housekeeping'])
      const out: StaffRow[] = []
      let after = 0
      for (;;) {
        const rows = await fresh('rosterView', [text(''), nat(after), nat(200)], [f('kind', 'text'), f('grantId'), f('subject', 'text'), f('role', 'text'), f('mine', 'bool'),
          f('automatic', 'bool'), f('since'), f('next'), f('atBlock')])
        for (const r of rows) {
          if (r.kind !== 'grant') continue
          out.push({ grantId: Number(r.grantId), subject: String(r.subject), role: ROLE_OF[String(r.role)] ?? 'frontDesk', mine: Boolean(r.mine), automatic: Boolean(r.automatic), since: Number(r.since) })
        }
        const next = rows.length ? Number(rows[rows.length - 1].next) : 0
        if (next === 0) return out
        after = next
      }
    },

    async myRoles() { return roles() },

    async myId() {
      const rows = await q('whoAmIView', [text('')], [f('principalHex', 'text'), f('atBlock')])
      return rows.length ? String(rows[0].principalHex) : ''
    },

    async grantRole(subject, role) {
      const rows = await u('grantRole', [text(''), principalArg(subject), text(role)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async revokeRole(subject, role) {
      const rows = await u('revokeRole', [text(''), principalArg(subject), text(role)], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
    },

    async setNights(e: NightsEdit): Promise<number> {
      const tri = (v?: boolean) => (v === undefined ? 0 : v ? 1 : 2)
      const rows = await u('setNights', [text(''), nat(e.roomTypeId), nat(e.fromDay), nat(e.toDay), nat(e.weekdays),
        bool(e.allotment !== undefined), nat(e.allotment ?? 0), bool(e.bar !== undefined), nat(e.bar ?? 0n), bool(e.minStay !== undefined), nat(e.minStay ?? 0),
        bool(e.maxStay !== undefined), nat(e.maxStay ?? 0), nat(tri(e.closedToArrival)), nat(tri(e.closedToDeparture)), nat(tri(e.stopSell))], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
      return Number(rows[0].a)
    },
    async setNightsMany(edits: ManyEdit[]): Promise<number> {
      const rows = await u('setNightsMany', [text(''), text(manyEditsHex(edits))], OUTCOME)
      if (!rows[0]?.ok) refuse(rows[0] ?? {})
      return Number(rows[0].a)
    },
  }

  async function roles(): Promise<Role[]> {
    const rows = await q('rolesView', [text('')], [f('role', 'text')])
    return rows.map((r) => ROLE_OF[String(r.role)]).filter((r): r is Role => !!r)
  }

  /** The console's views answer a stranger with nothing; the roles the contract names tell a refusal from
   *  an empty hotel. The desk's screens want a desk role (owner, revenue, front desk, auditor); the
   *  housekeeping board and the staff list take housekeeping as well. */
  /** The night audit's figures are for the owner, revenue management and the auditor. */
  async function requireFigures() {
    const held = await roles()
    if (!held.some((r) => r === 'owner' || r === 'revenue' || r === 'auditor')) throw new Refused('notAuthorised', { en: 'The figures are for the owner, revenue management and the auditor.', ar: 'الأرقام للمالك وإدارة الإيرادات والمدقق.' })
  }

  async function requireStaff(also: Role[] = []) {
    const held = await roles()
    if (!held.some((r) => r !== 'housekeeping' || also.includes(r))) throw new Refused('notAuthorised', { en: 'Sign in as hotel staff to see the console.', ar: 'سجّل الدخول بصفتك من موظفي الفندق لعرض لوحة الفندق.' })
  }

  function holdKeyOf(holdId: number): JsonWebKey | undefined {
    const m = holdKeys.get(holdId)
    if (m) return m
    try { const s = sessionStorage.getItem(`luxor:holdkey:${holdId}`); return s ? JSON.parse(s) : undefined } catch { return undefined }
  }
}

/** A Memphis token as the contract reads it: hex text. The connect runtime may hand back hex or base64. */
export function tokenHex(token: string): string {
  if (!token) return ''
  if (/^[0-9a-f]+$/i.test(token) && token.length % 2 === 0) return token.toLowerCase()
  const bin = atob(token.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((token.length + 3) % 4))
  return [...bin].map((c) => c.charCodeAt(0).toString(16).padStart(2, '0')).join('')
}

/** The id a reference names (the contract's Ref.of, inverted). */
export function parseRef(ref: string): number {
  const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
  const m = /^LX-([0-9A-Z]{6})-([0-9A-Z])$/.exec(ref.toUpperCase())
  if (!m) return 0
  let n = 0
  for (const c of m[1]) n = n * 32 + alphabet.indexOf(c)
  return (n - 104_729) / 7_919
}

