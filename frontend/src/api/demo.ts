/**
 * The demo data source: a small, realistic hotel kept in this browser, so the booking engine can be
 * used before the contract runs on a chain. It applies the contract's rules (the stay checks, the
 * hold and its expiry, the money law of a booking, the TEST gateway) to seeded inventory, and every
 * screen says "Demo data" while it is in use. The chain source (./chain.ts) replaces it one for one.
 */
import { adjustedBar } from './manyEdits'
import { dayOf, localToday, weekday, isWeekend, toDate, iso, type Day } from '../lib/days'
import { price, displayRate, depositOf, firstNights, quoteHash, taxesOn, withPackage, type IncInput, type Quote, type TaxRule } from './quote'
import { TENANTS, type Tenant, type TenantId } from '../theme/tenants'
import { photosFor } from './photos'
import { hex, sealFile } from './keys'
import {
  Refused, BOOKING_REF_BASE,
  type Api, type StaffBookResult, type StaffBookingView, type DayFiguresView, type NightRevenue, type AuthResult, type BookingView, type CalendarDay, type CancelResult, type ConfirmResult, type GridRow,
  type HoldView, type ManyEdit, type NightsEdit, type RateAdjust, type Offer, type PlanView, type PropertyView, type QuoteDetail, type RoomTypeView,
  type SealView, type SearchResult, type StayRequest, type TestScenario, type Bi, type DeskRow, type VacantRoom, type IdDocumentView, type AuditStatus, type ProposalView, type DualAct, type WaitView, type BookingQuery, type FolioLineView, type PaymentView, type HistoryAct, type RefundView,
  type HotelClock, type HotelClockSetting, type BoardRoom, type Cleaning, type ExtraCategory, type BillWindowView, type BillLineView, type Role, type StaffRow,
  type SetupProperty, type SetupRoomType, type SetupPlan, type SetupTax, type CompanyView, type PlanAccessView, type PromoView, type CodeView, type BlockView, type RoomingRow,
  type CreditNoteRow, type CreditNoteLineView, type CreditNoteEta, type DeskMethod, type EtaProfile, CREDIT_NOTE_CODE, creditable,
  type InclusionSetting, type InclusionView, type PackageLineView,
  type CardView, type CardOnFileState, type CardDeskRow, type Guarantee,
  type MailAttach, type MailRow, type MailKind, type MailSetupView, type MailProvider, type MailProviderView, type DnsCheckView,
} from './types'
import { cardsOf, slicesOf } from '../lib/refunds'

interface Night {
  allotment: number
  sold: number
  held: number
  bar: bigint
  minStay: number
  maxStay: number
  cta: boolean
  ctd: boolean
  stopSell: boolean
}

interface Hold {
  id: number
  roomTypeId: number
  planId: number
  req: StayRequest
  quote: Quote
  expiresAtMs: number
  state: 'live' | 'confirmed' | 'released' | 'expired'
  /** The company whose code the hold was placed under (0: the public sale). */
  companyId?: number
  /** The promotion whose code the hold was placed under (0: none). */
  promoId?: number
}

// what the contract keeps per booking, kept here too so the console's detail reads the same shape
interface Booking extends BookingView {
  secretHash: string
  authId: number
  authAmount: bigint
  lines: DemoLine[]
  payments: DemoPayment[]
  events: HistoryAct[]
  /** Payers of the bill besides the guest (window 0), as the contract keeps them. */
  payers?: { id: number; name: string }[]
}

/** A folio line on a bill (`payerId` absent: the guest's), and for an extra what was posted. */
type DemoLine = FolioLineView & { payerId?: number; code?: number; charge?: { extraId: number; quantity: number; unit: bigint; taxLines: number; voidLine: number; pkg?: boolean } }
/** A payment; a refund to the guest also names the first slice of its settle and the whole that settle gave back. */
type DemoPayment = PaymentView & { payerId?: number; firstSlice?: number; excess?: bigint }

interface DemoExtra { id: number; code: string; name: Bi; category: ExtraCategory; price: bigint; taxed: boolean; active: boolean }
interface DemoInvoice { number: number; bookingId: number; payerId: number; issuedDay: Day; charges: bigint; credits: bigint; taxes: bigint; paid: bigint }
/** A credit note as the contract keeps it: its figures, its credit lines (each naming the line it takes back), and who made and approved it. */
interface DemoNote {
  number: number; invoice: number; bookingId: number; payerId: number; issuedDay: Day; net: bigint; taxes: bigint; total: bigint
  items: { lineId: number; source: number; amount: bigint; tax: boolean }[]; maker: string; checker: string
  /** The first payment its refund wrote on the guest's cards (absent: it wrote none). */
  refundFrom?: number
}
interface DemoDeskRefund { bookingId: number; paymentId: number; method: DeskMethod; reference: string; day: Day; maker: string; checker: string }
/** The tax authority's codes (absent: none given yet). */
interface DemoEta { profile?: EtaProfile; taxes: Record<number, { taxType: string; subType: string }> }

/** A room, with its housekeeping record as the contract keeps it (absent fields: no record yet). */
interface DemoRoom {
  id: number; roomTypeId: number; number: string; occupiedBy: number
  cleaning?: Cleaning; cleanedBy?: string; inspectedBy?: string; changedDay?: Day
  /** Out of order with dates: the first night back in the count is `until`. */
  out?: { reason: string; from: Day; until: Day }
}

/** `token`: the card kept on file at this payment, when the guest agreed (absent: none); `mitDeclines`: the card refuses any later charge. */
interface GatewayAuth { id: number; amount: bigint; ref: number; captured: bigint; refunded: bigint; voided: boolean; refusesRefunds?: boolean; token?: number; mitDeclines?: boolean }
/** Guest email as the contract keeps it, and the demo's stand-in for the shared relay: the relay is
 *  connected by the owner, accounts are kept by their digest, and while guest email is on every message
 *  due today goes out on the next read (the real relay pulls about once a minute). No address is kept. */
interface DemoMail {
  connected: boolean
  authorised: string
  tested: string
  on: boolean
  accounts: Record<string, { provider: MailProvider; from: string }>
  rows: (MailRow & { bookingId: number })[]
  /** The bookings that have an address, and the language their messages are written in. */
  addressed: Record<number, 'en' | 'ar'>
}

/** A booking's card on file as the contract keeps it: the gateway's token, never the card. */
interface DemoCard { state: CardOnFileState; token: number; firstAuth: number; deadline: Day; chargeId: number; declinedDay: Day }

interface State {
  version: number
  businessDate: Day
  block: number
  nights: Record<string, Night>
  holds: Hold[]
  bookings: Booking[]
  gateway: GatewayAuth[]
  rooms: DemoRoom[]
  nextHold: number
  nextBooking: number
  nextAuth: number
  capturedDone: string
  refundsCommitted: string
  /** The hotel clock, once the owner sets it (absent in a demo saved before it existed). */
  clock?: DemoClock
  extras: DemoExtra[]
  invoices: DemoInvoice[]
  /** The roster (absent in a demo saved before it existed: the seeded staff). */
  staff?: DemoGrant[]
  /** The hotel as its owner set it up (absent in a demo saved before it existed: the sample's own). */
  setup?: DemoSetup
  /** Credit notes, refunds paid at the desk, the tax authority's codes (absent in a demo saved before they existed). */
  notes?: DemoNote[]
  deskRefunds?: DemoDeskRefund[]
  eta?: DemoEta
  /** How each booking staff took came, by booking id (absent in a demo saved before it existed). */
  staffBookings?: Record<number, StaffBookingView>
  /** The night audit's figures by day, its revenue rows, and the first booking the next day's pickup
   *  counts from (absent in a demo saved before they existed: sample nights are made then). */
  figures?: Record<number, DayFiguresView>
  revenue?: NightRevenue[]
  pickupFrom?: number
  /** Companies with negotiated rates, and who each plan is sold to (absent in a demo saved before they existed). */
  companies?: CompanyView[]
  access?: PlanAccessView[]
  /** Promotions (absent in a demo saved before they existed). */
  promos?: PromoView[]
  /** Group blocks, and the block each picked-up booking came from (absent in a demo saved before they existed). */
  blocks?: DemoBlock[]
  pickups?: Record<number, number>
  /** The card rule, deposit shares by plan, and the cards on file by booking (absent in a demo saved before they existed). */
  cardRule?: boolean
  /** The books' rules epoch (absent: a demo hotel installed by this build, which adopts the newest). */
  rulesEpoch?: number
  deposits?: Record<number, number>
  cards?: Record<number, DemoCard>
  /** Each plan's package, by plan id (absent in a demo saved before packages existed: none). */
  inclusions?: Record<number, InclusionSetting[]>
  /** Guest email (absent in a demo saved before it existed: not connected). */
  mail?: DemoMail
}

/** A group block as the contract keeps it: what it holds on a night is its rooms less those picked up
 *  there while it is open, and nothing once released. */
interface DemoBlock { id: number; name: string; companyId: number; roomTypeId: number; planId: number; arrival: Day; departure: Day; rooms: number; cutoff: Day
  open: boolean; picked: Record<number, number> }

/** The setup records, as the contract keeps them: the property, and every room type, plan and tax, active or not. */
interface DemoSetup { property: SetupProperty; roomTypes: Omit<SetupRoomType, 'rooms'>[]; plans: SetupPlan[]; taxes: SetupTax[] }

/** The sample hotel's setup: the tenant's own facts as the setup records a fresh hotel would hold. */
function seedSetup(t: Tenant): DemoSetup {
  return {
    property: { name: t.name, currency: t.currency, minorUnits: t.minorUnits, checkInText: t.checkIn.en, checkOutText: t.checkOut.en,
      holdTtlHeights: HOLD_SECONDS, heightsPerRealMinute: 60, maxStayNights: MAX_STAY, horizonDays: HORIZON, maxRoomsPerBooking: MAX_ROOMS, idRetentionDays: 30 },
    roomTypes: t.rooms.map((r, i) => ({ id: i + 1, code: r.code, name: r.name, desc: r.desc, sizeSqm: r.sizeSqm, maxAdults: r.maxAdults, maxChildren: r.maxChildren,
      maxOccupancy: r.maxOccupancy, bedKind: r.bedKind, bedCount: r.bedCount, amenities: [...r.amenities], photos: r.slot, rank: i + 1, active: true })),
    plans: PLANS(t).map((p) => ({ id: p.id, code: p.code, name: p.name, discountBps: p.discountBps, refundable: p.refundable, freeCancelDaysBefore: p.freeCancelDaysBefore,
      penaltyNights: p.penaltyNights, prepaid: p.guarantee === 'prepaidInFull', modifiable: true, active: true })),
    taxes: t.taxes.map((x) => ({ id: x.id, code: x.code, name: x.name, kind: x.kind, bps: x.bps, amount: x.amount, onPriorTaxes: x.base === 'roomAndPriorTaxes', rank: x.rank, active: true })),
  }
}

interface DemoClock { zoneName: string; zoneRule: string; auditAt: number; auto: boolean }

/** A role held, as the contract's grant table keeps it; `active` false once ended. */
interface DemoGrant { grantId: number; subject: string; role: Role; active: boolean; since: number }

/** A principal's bytes as hex, made up deterministically for the demo's people (29 bytes, as a passkey's). */
function demoId(n: number): string {
  let h = ''
  let x = (n * 2_654_435_761) >>> 0
  for (let i = 0; i < 29; i++) { x = (x * 1_103_515_245 + 12_345) >>> 0; h += ((x >>> 16) & 0xff).toString(16).padStart(2, '0') }
  return h
}
/** The contract itself, which holds the auditor role while the night audit runs by itself. */
const AUTO_RUNNER = demoId(99)
/** The demo's own visitor: the owner of the sample hotel. */
const DEMO_ME = demoId(1)

/** The providers the shared relay connects (mailrelay/providers), as its /v1/providers lists them. */
const DEMO_PROVIDERS: MailProviderView[] = [
  { name: 'google', label: 'Google Workspace', fields: ['from', 'fromName'], oauth: true, available: true },
  { name: 'microsoft', label: 'Microsoft 365', fields: ['from', 'fromName'], oauth: true, available: true },
  { name: 'smtp', label: 'SMTP', fields: ['from', 'fromName', 'host', 'port', 'security', 'username', 'password'], oauth: false, available: true },
  { name: 'sendgrid', label: 'SendGrid', fields: ['from', 'fromName', 'apiKey'], oauth: false, available: true },
  { name: 'postmark', label: 'Postmark', fields: ['from', 'fromName', 'apiKey'], oauth: false, available: true },
  { name: 'resend', label: 'Resend', fields: ['from', 'fromName', 'apiKey'], oauth: false, available: true },
  { name: 'mailgun', label: 'Mailgun', fields: ['from', 'fromName', 'apiKey', 'domain', 'region'], oauth: false, available: true },
  { name: 'brevo', label: 'Brevo', fields: ['from', 'fromName', 'apiKey'], oauth: false, available: true },
  { name: 'ses', label: 'Amazon SES', fields: ['from', 'fromName', 'accessKeyId', 'secretAccessKey', 'region'], oauth: false, available: true },
]
/** The sample hotel's staff, as their owner set them up. */
function seedStaff(): DemoGrant[] {
  return ([[DEMO_ME, 'owner'], [demoId(2), 'owner'], [demoId(3), 'frontDesk'], [demoId(4), 'frontDesk'], [demoId(5), 'revenue'], [demoId(6), 'housekeeping'], [demoId(7), 'auditor']] as const)
    .map(([subject, role], i) => ({ grantId: i + 1, subject, role, active: true, since: 1 }))
}

/** The night audit's sections by rules epoch, as the contract's Rules.SECTIONS_AT. */
const DEMO_RULES = [5, 31]
const VERSION = 10
const HORIZON = 240
const HOLD_SECONDS = 15 * 60
const MAX_STAY = 21
const MAX_ROOMS = 4
const PLANS = (t: Tenant): PlanView[] => [
  { id: 1, code: 'FLEX', name: { en: 'Flexible rate', ar: 'سعر مرن' }, refundable: true, freeCancelDaysBefore: t.freeCancelDays, penaltyNights: 1, guarantee: 'firstNightAuthorised', discountBps: 0 },
  { id: 2, code: 'SAVER', name: { en: 'Pay now, save', ar: 'ادفع الآن ووفّر' }, refundable: false, freeCancelDaysBefore: 0, penaltyNights: 0, guarantee: 'prepaidInFull', discountBps: t.nonRefundableBps },
  { id: 3, code: 'BB', name: { en: 'Bed and breakfast', ar: 'مبيت وإفطار' }, refundable: true, freeCancelDaysBefore: t.freeCancelDays, penaltyNights: 1, guarantee: 'firstNightAuthorised', discountBps: 0 },
]

// ── a deterministic seed, so every visitor sees the same lived-in hotel ─────────

function hash(n: number): number {
  let x = (n ^ 0x9e3779b9) >>> 0
  x = Math.imul(x ^ (x >>> 16), 0x85ebca6b) >>> 0
  x = Math.imul(x ^ (x >>> 13), 0xc2b2ae35) >>> 0
  return ((x ^ (x >>> 16)) >>> 0) / 4294967296
}

function season(t: TenantId, day: Day): number {
  const m = toDate(day).getUTCMonth() + 1
  if (t === 'almar') return m >= 6 && m <= 9 ? 1.35 : m === 4 || m === 5 || m === 10 ? 1.0 : 0.82
  return m >= 11 || m <= 3 ? 1.3 : m === 4 || m === 10 ? 1.0 : 0.78
}

function seed(t: Tenant): State {
  const today = localToday()
  const nights: Record<string, Night> = {}
  t.rooms.forEach((r, i) => {
    const rt = i + 1
    for (let d = today; d < today + HORIZON; d++) {
      const weekend = isWeekend(d)
      const step = t.minorUnits === 2 ? (t.currency === 'EGP' ? 10000 : 500) : 1
      const raw = r.bar * season(t.id, d) * (weekend ? 1.15 : 1)
      const bar = BigInt(Math.round(raw / step) * step)
      const near = Math.max(0, 1 - (d - today) / 120)
      const occ = Math.min(1, 0.1 + near * 0.3 + (weekend ? 0.15 : 0) + hash(rt * 100000 + d) * 0.3)
      const sold = Math.min(r.rooms, Math.floor(r.rooms * occ))
      const stopSell = r.rooms === 1 && hash(d * 7 + rt) < 0.06
      nights[`${rt}:${d}`] = {
        allotment: r.rooms, sold: stopSell ? 0 : sold, held: 0, bar,
        minStay: weekday(d) === 4 || weekday(d) === 5 ? r.minStayWeekend : 1, maxStay: 0,
        cta: r.rooms <= 2 && weekday(d) === 6, ctd: false, stopSell,
      }
    }
  })
  const rooms: DemoRoom[] = []
  t.rooms.forEach((r, i) => { for (let k = 0; k < r.rooms; k++) rooms.push({ id: rooms.length + 1, roomTypeId: i + 1, number: String(100 * (i + 1) + k + 1), occupiedBy: 0 }) })
  // the hotel's extras: a price list in the hotel's currency (an open-priced restaurant bill, untaxed parking)
  const egp = t.currency === 'EGP'
  const extras: DemoExtra[] = ([
    ['WATER', { en: 'Minibar water', ar: 'مياه الميني بار' }, 'minibar', egp ? 5_000n : 300n, true],
    ['BREAKFAST', { en: 'Breakfast', ar: 'الإفطار' }, 'breakfast', egp ? 45_000n : 1_800n, true],
    ['DINNER', { en: 'Restaurant', ar: 'المطعم' }, 'restaurant', 0n, true],
    ['MASSAGE', { en: 'Massage, 60 minutes', ar: 'تدليك، 60 دقيقة' }, 'spa', egp ? 250_000n : 7_500n, true],
    ['PARKING', { en: 'Parking, a night', ar: 'موقف السيارة، ليلة' }, 'parking', egp ? 20_000n : 1_500n, false],
  ] as const).map(([code, name, category, price, taxed], i) => ({ id: i + 1, code, name, category, price, taxed, active: true }))
  const st: State = { version: VERSION, businessDate: today, block: 1, nights, holds: [], bookings: [], gateway: [], rooms, nextHold: 1, nextBooking: 1, nextAuth: 1, capturedDone: '0', refundsCommitted: '0',
    extras, invoices: [],
    // the bed-and-breakfast plan's package: breakfast for every guest, every night (extra 2 is the breakfast)
    inclusions: { 3: [{ extraId: 2, quantity: 1, rhythm: 'everyNight', per: 'guest' }] } }
  // a lived-in front desk: guests arriving today and guests already in house, with their nights sold
  const names = t.id === 'almar'
    ? ['Clara Vidal', 'Tomás Ferrer', 'Hannah Becker', 'Youssef Amrani', 'Marta Puig', 'Oliver Grant']
    : ['Hana Saleh', 'Youssef Farid', 'Laila Fathy', 'James Whitfield', 'Mona Adel', 'Sophie Laurent']
  names.forEach((guestName, k) => {
    const rt = (k % t.rooms.length) + 1
    const inHouse = k >= 3
    const arrival = inHouse ? today - 1 - (k % 2) : today
    const nightsN = 2 + (k % 3)
    let total = 0n
    for (let d = arrival; d < arrival + nightsN; d++) {
      const n = nights[`${rt}:${d}`]
      if (n) { n.sold = Math.min(n.allotment, n.sold + 1); total += n.bar } else total += BigInt(t.rooms[rt - 1].bar)
    }
    const id = st.nextBooking++
    const b: Booking = {
      id, ref: refFor(id), status: inHouse ? 'checkedIn' : 'confirmed', roomTypeId: rt, planId: 1, arrival, departure: arrival + nightsN, rooms: 1,
      adults: 2, children: 0, guestName, charged: total, credited: 0n, paid: 0n, outstanding: total, penalty: total / BigInt(nightsN),
      cancelDeadline: arrival - t.freeCancelDays, refundable: true, block: 0, secretHash: '', authId: 0, authAmount: 0n,
      lines: [], payments: [],
      // newest first, as the contract's history reads
      events: inHouse ? [{ block: 0, day: arrival, act: 'checkIn' }, { block: 0, day: arrival - 20, act: 'confirmHold' }] : [{ block: 0, day: arrival - 20, act: 'confirmHold' }],
    }
    for (let d = arrival; d < arrival + nightsN; d++) {
      const n = nights[`${rt}:${d}`]
      b.lines.push({ id: b.lines.length + 1, kind: 'roomNight', night: d, amount: n ? n.bar : BigInt(t.rooms[rt - 1].bar), block: 0 })
    }
    st.bookings.push(b)
    if (inHouse) { const room = st.rooms.find((x) => x.roomTypeId === rt && x.occupiedBy === 0); if (room) room.occupiedBy = id }
  })
  // a housekeeping morning: rooms left yesterday are dirty, most are clean or inspected by the day's
  // housekeepers, and one room of the largest type is out of order for three nights (its nights offer one room fewer)
  st.rooms.forEach((r) => {
    if (r.occupiedBy) return
    const h = hash(r.id * 31 + today)
    if (h < 0.25) { r.cleaning = 'dirty'; r.changedDay = today }
    else if (h < 0.6) { r.cleaning = 'clean'; r.cleanedBy = 'housekeeping'; r.changedDay = today }
    else if (h < 0.9) { r.cleaning = 'inspected'; r.cleanedBy = 'housekeeping'; r.inspectedBy = 'supervisor'; r.changedDay = today }
  })
  const big = t.rooms.reduce((best, r, i) => (r.rooms > t.rooms[best].rooms ? i : best), 0) + 1
  const outRoom = [...st.rooms].reverse().find((r) => r.roomTypeId === big && !r.occupiedBy)
  if (outRoom && t.rooms[big - 1].rooms > 1) {
    for (let d = today; d < today + 3; d++) {
      const n = nights[`${big}:${d}`]
      if (n) { n.allotment = Math.min(n.allotment, t.rooms[big - 1].rooms - 1); n.sold = Math.min(n.sold, n.allotment) }
    }
    Object.assign(outRoom, { cleaning: 'dirty', cleanedBy: undefined, inspectedBy: undefined, changedDay: today, out: { reason: 'Air conditioning repair', from: today, until: today + 3 } })
  }
  return st
}

// ── storage ─────────────────────────────────────────────────────────────────

function keyOf(t: TenantId) { return `luxor:demo:${t}` }

function reviver(_k: string, v: unknown) { return typeof v === 'string' && /^-?\d+n$/.test(v) ? BigInt(v.slice(0, -1)) : v }
function replacer(_k: string, v: unknown) { return typeof v === 'bigint' ? `${v}n` : v }

function load(t: Tenant): State {
  try {
    const raw = localStorage.getItem(keyOf(t.id))
    if (raw) {
      const s = JSON.parse(raw, reviver) as State
      if (s.version === VERSION && s.businessDate === localToday()) return s
    }
  } catch { /* a private window or cleared storage starts from the seed */ }
  return seed(t)
}

function refuse(kind: string, en: string, ar: string): never { throw new Refused(kind, { en, ar }) }

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms))

export function refFor(id: number): string {
  const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
  let n = id * 7919 + 104_729
  let body = ''
  for (let i = 0; i < 6; i++) { body = alphabet[n % 32] + body; n = Math.floor(n / 32) }
  let check = 0
  for (const c of body) check = (check * 31 + alphabet.indexOf(c)) % 32
  return `LX-${body.slice(0, 3)}${body.slice(3)}-${alphabet[check]}`
}

async function sha(text: string): Promise<string> {
  const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, '0')).join('')
}

// ── the source ──────────────────────────────────────────────────────────────

export function demoApi(tenantId: TenantId): Api {
  const t = TENANTS[tenantId]
  let st = load(t)
  const save = () => { try { localStorage.setItem(keyOf(t.id), JSON.stringify(st, replacer)) } catch { /* storage full or blocked: the session still works */ } }
  const bump = () => { st.block += 1; save(); return st.block }
  /** One act on a booking: a block, and the event, folio lines and payments it wrote, stamped with it. */
  /** The night audit's figures of `day`, as the contract writes them: the rooms, those out of order,
   *  the guests in house who stay the night with their rooms and that night's room charges, the
   *  arrivals among them, the no-shows, and the bookings made since the last figures. */
  const writeFigures = (day: Day) => {
    history()
    let sold = 0, revenue = 0n, arrivals = 0
    const rows = new Map<string, NightRevenue>()
    for (const b of st.bookings) {
      if (b.status !== 'checkedIn' || b.arrival > day || b.departure <= day) continue
      const night = b.lines.filter((l) => l.kind === 'roomNight' && l.night === day).reduce((a, l) => a + l.amount, 0n)
      sold += b.rooms; revenue += night
      if (b.arrival === day) arrivals++
      const k = `${b.roomTypeId}/${b.planId}`
      const was = rows.get(k) ?? { day, roomTypeId: b.roomTypeId, planId: b.planId, roomNights: 0, revenue: 0n }
      rows.set(k, { ...was, roomNights: was.roomNights + b.rooms, revenue: was.revenue + night })
    }
    const from = st.pickupFrom ?? 1
    const made = st.bookings.filter((b) => b.id >= from)
    st.figures![day] = {
      day, roomsTotal: st.rooms.length, roomsOut: st.rooms.filter((r) => r.out && r.out.from <= day).length, roomsSold: sold, roomRevenue: revenue, arrivals,
      noShows: st.bookings.filter((b) => b.status === 'noShow' && b.arrival === day).length,
      pickupBookings: made.length, pickupNights: made.reduce((a, b) => a + b.rooms * (b.departure - b.arrival), 0),
      pickupRevenue: made.reduce((a, b) => a + b.lines.filter((l) => l.kind === 'roomNight').reduce((x, l) => x + l.amount, 0n), 0n), closed: true,
    }
    st.revenue = [...(st.revenue ?? []).filter((r) => r.day !== day), ...rows.values()]
    st.pickupFrom = st.nextBooking
  }

  /** A demo has no audited past of its own: the 28 nights before its first day are sample nights, the
   *  same for every visitor, so the reports have a history to show. Days the demo closes are real. */
  const history = (): Record<number, DayFiguresView> => {
    if (st.figures) return st.figures
    const figs: Record<number, DayFiguresView> = {}
    const revenue: NightRevenue[] = []
    const total = st.rooms.length
    for (let d = st.businessDate - 28; d < st.businessDate; d++) {
      let sold = 0, rev = 0n
      t.rooms.forEach((rt, i) => {
        const n = Math.round(rt.rooms * (0.5 + 0.42 * hash(d * 7 + i)))
        if (!n) return
        const rate = BigInt(Math.round(Number(rt.bar) * (0.88 + 0.2 * hash(d * 13 + i))))
        sold += n; rev += rate * BigInt(n)
        revenue.push({ day: d, roomTypeId: i + 1, planId: 1, roomNights: n, revenue: rate * BigInt(n) })
      })
      const made = 2 + Math.floor(7 * hash(d * 31))
      const nights = made * (1 + Math.floor(3 * hash(d * 37)))
      figs[d] = { day: d, roomsTotal: total, roomsOut: sold < total && hash(d * 41) < 0.2 ? 1 : 0, roomsSold: sold, roomRevenue: rev,
        arrivals: Math.round(sold * 0.3), noShows: hash(d * 43) < 0.15 ? 1 : 0, pickupBookings: made, pickupNights: nights,
        pickupRevenue: BigInt(nights) * BigInt(t.rooms[0].bar), closed: true }
    }
    st.figures = figs
    st.revenue = revenue
    st.pickupFrom = st.nextBooking
    return figs
  }

  const act = (b: Booking, name: string, lines: Omit<DemoLine, 'id' | 'block'>[] = [], pays: Omit<DemoPayment, 'id' | 'block'>[] = []) => {
    const block = bump()
    b.events.unshift({ block, day: st.businessDate, act: name })
    for (const l of lines) b.lines.push({ ...l, id: b.lines.length + 1, block })
    for (const x of pays) b.payments.push({ ...x, id: b.payments.length + 1, block })
    save()
    return block
  }

  const night = (rt: number, d: Day) => st.nights[`${rt}:${d}`]
  /** The roster, seeded on first use; the automatic night audit holds the auditor role while it runs, as on the chain. */
  const roster = (): DemoGrant[] => {
    st.staff ??= seedStaff()
    const auto = !!st.clock?.auto
    const held = st.staff.find((g) => g.active && g.subject === AUTO_RUNNER && g.role === 'auditor')
    if (auto && !held) st.staff.push({ grantId: st.staff.length + 1, subject: AUTO_RUNNER, role: 'auditor', active: true, since: st.block })
    if (!auto && held) held.active = false
    return st.staff
  }
  // ── setup: what the owner set, read the way the contract's quote, search and bill read it ──
  const setup = (): DemoSetup => (st.setup ??= seedSetup(t))
  const prop = () => setup().property
  const holdSeconds = () => Math.floor(prop().holdTtlHeights * 60 / prop().heightsPerRealMinute)
  /** A room type by id, active or not; the guest pages see only the active ones. */
  const typeOf = (id: number) => setup().roomTypes.find((x) => x.id === id)
  const activeTypes = () => setup().roomTypes.filter((x) => x.active)
  const guaranteeKind = (p: SetupPlan): Guarantee => p.prepaid ? 'prepaidInFull' : p.guarantee === 'deposit' ? 'deposit' : 'firstNightAuthorised'
  const planView = (p: SetupPlan): PlanView => {
    const guarantee = guaranteeKind(p)
    return { id: p.id, code: p.code, name: p.name, refundable: p.refundable, freeCancelDaysBefore: p.freeCancelDaysBefore,
      penaltyNights: p.penaltyNights, guarantee, discountBps: p.discountBps, depositBps: guarantee === 'deposit' ? st.deposits?.[p.id] ?? 0 : 0,
      keepsCard: Boolean(st.cardRule) && guarantee !== 'prepaidInFull' }
  }
  /** What a rate's guarantee takes at confirmation: the stay, a deposit of the room's stay, or its first night. */
  const guaranteeFor = (plan: PlanView, q: Quote): bigint =>
    plan.guarantee === 'prepaidInFull' ? q.total : plan.guarantee === 'deposit' ? depositOf(q, plan.depositBps ?? 0) : firstNights(q, 1)
  /** The same from a booking's bill: its room nights and their taxes. */
  const guaranteeOfBill = (b: Booking, plan: PlanView): bigint => {
    const room = (l: DemoLine) => l.kind === 'roomNight' || l.kind === 'tax'
    if (plan.guarantee === 'deposit') {
      const base = b.lines.filter(room).reduce((s, l) => s + l.amount, 0n)
      return depositOf({ roomSubtotal: base, taxTotal: 0n }, plan.depositBps ?? 0)
    }
    if (plan.guarantee === 'prepaidInFull') return b.charged
    return b.lines.filter((l) => room(l) && l.night === b.arrival).reduce((s, l) => s + l.amount, 0n)
  }
  const cards = () => (st.cards ??= {})

  // ── guest email, as Mail.mo keeps it ──
  const mail = () => (st.mail ??= { connected: false, authorised: '', tested: '', on: false, accounts: {}, rows: [], addressed: {} })
  const mailQueue = (bookingId: number, kind: MailKind, notBefore: Day) => {
    const m = mail()
    m.rows.push({ outboxId: m.rows.length + 1, bookingId, kind, state: 'due', attempts: 0, failure: '', notBefore })
  }
  const mailRowOf = (bookingId: number, kind: MailKind) => mail().rows.find((r) => r.bookingId === bookingId && r.kind === kind)
  const skip = (r: MailRow | undefined) => { if (r && r.state === 'due') r.state = 'skipped' }
  /** The hooks the contract runs at each change of a booking with an address. */
  const mailHook = (b: Booking, event: 'cancelled' | 'arrivedOrNot' | 'checkedOut') => {
    if (!(b.id in mail().addressed)) return
    if (event === 'cancelled') { skip(mailRowOf(b.id, 'confirmation')); skip(mailRowOf(b.id, 'preArrival')); mailQueue(b.id, 'cancellation', 0) }
    if (event === 'arrivedOrNot') skip(mailRowOf(b.id, 'preArrival'))
    if (event === 'checkedOut') mailQueue(b.id, 'receipt', 0)
  }
  /** The relay's pass: while guest email is on, every message due today is sent. */
  const relayPass = () => {
    const m = mail()
    if (!m.on) return
    let sent = 0
    for (const r of m.rows) if (r.state === 'due' && r.notBefore <= st.businessDate) { r.state = 'sent'; r.attempts += 1; sent++ }
    if (sent) bump()
  }
  const mailAttach = (b: Booking, email: string, lang: 'en' | 'ar'): MailAttach => {
    if (!email.trim()) return 'noAddress'
    const m = mail()
    if (!m.connected) return 'notConnected'
    if (b.id in m.addressed || (b.status !== 'confirmed' && b.status !== 'checkedIn')) return 'failed'
    m.addressed[b.id] = lang
    mailQueue(b.id, 'confirmation', 0)
    if (b.status === 'confirmed' && b.arrival >= st.businessDate + 3) mailQueue(b.id, 'preArrival', b.arrival - 2)
    act(b, 'attachMail')
    return 'queued'
  }
  const mailRows = (bookingId: number): MailRow[] => {
    relayPass()
    return mail().rows.filter((r) => r.bookingId === bookingId).map(({ bookingId: _, ...r }) => r)
  }
  /** A settled booking lets its card go: the gateway deletes the token (the demo gateway at once); a card still awaited is no longer. */
  const letGo = (id: number) => {
    const k = cards()[id]
    if (k?.state === 'kept') k.state = 'forgotten'
    else if (k?.state === 'wanted') k.state = 'closed'
  }
  /** A no-show's penalty, from its card on file: the guarantee's authorisation captured as far as it goes, the rest charged
   *  once to the card; a decline stays outstanding for the desk and is never tried again. The card is then let go. */
  const noShowCard = (b: Booking, day: Day) => {
    const k = cards()[b.id]
    if (!k) return
    if (k.state === 'wanted') { k.state = 'closed'; return }
    if (k.state !== 'kept') return
    const a = st.gateway.find((x) => x.id === k.firstAuth)
    const take = a ? (b.outstanding < a.amount - a.captured ? b.outstanding : a.amount - a.captured) : 0n
    const pays: Omit<DemoPayment, 'id' | 'block'>[] = []
    if (a && take > 0n) {
      a.captured += take; b.paid += take; b.outstanding -= take; st.capturedDone = (BigInt(st.capturedDone) + take).toString()
      pays.push({ kind: 'captured', state: 'done', amount: take, gatewayAuth: a.id, attempts: 1 })
    }
    if (b.outstanding > 0n) {
      const ok = !a?.mitDeclines
      const rest = b.outstanding
      const charge = ok ? st.nextAuth++ : 0
      if (ok) {
        st.gateway.push({ id: charge, amount: rest, ref: BOOKING_REF_BASE + b.id, captured: rest, refunded: 0n, voided: false })
        b.paid += rest; b.outstanding = 0n; st.capturedDone = (BigInt(st.capturedDone) + rest).toString()
      } else k.declinedDay = day
      pays.push({ kind: 'chargedOnFile', state: ok ? 'done' : 'failed', amount: rest, gatewayAuth: charge, attempts: 1 })
    }
    if (pays.length) {
      act(b, 'chargeOnFile', [], pays)
      const c = b.payments.find((p) => p.kind === 'chargedOnFile')
      if (c) k.chargeId = c.id
    }
    k.state = 'forgotten'
  }
  const activePlans = () => setup().plans.filter((p) => p.active).map(planView)
  // who a rate is sold to, as Access.mo keeps it: a plan closed to a company only under its code, while the
  // company is on sale; a plan closed to everyone but codes only under a promotion that names it, within the
  // promotion's windows and uses
  type Grant = { companyId: number; promoId: number }
  const PUBLIC: Grant = { companyId: 0, promoId: 0 }
  type Sale = { arrival: Day; nights: number; counts: boolean }
  const accessOf = (planId: number) => (st.access ?? []).find((a) => a.planId === planId)
  const onPublicSale = (planId: number) => !accessOf(planId)?.closed
  const promoOf = (id: number) => (st.promos ?? []).find((p) => p.id === id)
  const closedRate = (planId: number): never => refuse('closedRate', `Rate plan ${planId} is sold only under its company's or its promotion's code.`, 'هذا السعر متاح فقط برمز شركته أو برمز العرض الخاص به.')
  const promoClosed = (code: string, why: string): never =>
    refuse('promoClosed', `The promotion ${code} ${why}`, 'عرض هذا الرمز لا ينطبق على هذا الحجز: انتهت مدة الحجز به، أو لا تشمل تواريخه هذه الإقامة، أو نفدت مرات استخدامه.')
  /** Refuses unless the access admits the plan (Access.admits); with a sale, a promotion's windows and uses too. */
  const admit = (planId: number, g: Grant, sale?: Sale) => {
    const a = accessOf(planId)
    if (a?.closed && a.companyId !== 0) {
      if (g.companyId !== a.companyId || !(st.companies ?? []).find((c) => c.id === a.companyId)?.active) closedRate(planId)
      return
    }
    const toCodes = Boolean(a?.closed)
    const pr = g.promoId ? promoOf(g.promoId) : undefined
    if (!pr || pr.planId !== planId) { if (toCodes) closedRate(planId); return }
    if (!pr.active) { if (toCodes) closedRate(planId); promoClosed(pr.code, 'is off sale.') }
    if (!sale) return
    if (sale.counts && (st.businessDate < pr.bookFrom || st.businessDate > pr.bookUntil)) promoClosed(pr.code, `is booked from ${iso(pr.bookFrom)} to ${iso(pr.bookUntil)}.`)
    if (sale.arrival < pr.stayFrom || sale.arrival + sale.nights > pr.stayUntil + 1) promoClosed(pr.code, `is for nights from ${iso(pr.stayFrom)} to ${iso(pr.stayUntil)}.`)
    if (sale.counts && pr.maxUses > 0 && pr.used >= pr.maxUses) promoClosed(pr.code, `has been used ${pr.used} times, all it may be.`)
  }
  const admits = (planId: number, g: Grant) => { try { admit(planId, g); return true } catch (e) { if (e instanceof Refused) return false; throw e } }
  /** A promotion counts only on the plan it names while that plan is closed to everyone but codes (Access.forPlan). */
  const forPlan = (g: Grant, planId: number): Grant => {
    if (!g.promoId) return g
    const a = accessOf(planId)
    return a?.closed && a.companyId === 0 && promoOf(g.promoId)?.planId === planId ? g : PUBLIC
  }
  /** The access a typed code grants: a company's or a promotion's, while on sale; the public sale for no code. */
  const resolveCode = (typed?: string): Grant => {
    const code = (typed ?? '').trim().toUpperCase()
    if (!code) return PUBLIC
    const c = (st.companies ?? []).find((x) => x.code === code)
    if (c?.active) return { companyId: c.id, promoId: 0 }
    const p = c ? undefined : (st.promos ?? []).find((x) => x.code === code)
    if (p?.active) return { companyId: 0, promoId: p.id }
    return refuse('noSuchCode', `The code ${code} is not one the hotel offers.`, 'هذا الرمز غير معروف لدى الفندق أو لم يعد متاحاً.')
  }
  const isPublic = (g: Grant) => g.companyId === 0 && g.promoId === 0
  /** The plans a search under this access shows: those on public sale and those it opens. */
  const plansFor = (g: Grant) => activePlans().filter((p) => onPublicSale(p.id) || (!isPublic(g) && admits(p.id, g)))
  /** The quote of a new sale under the access a code grants: a closed plan is refused unless the code opens it. */
  const checkFor = (rt: number, planId: number, req: StayRequest) => {
    const grant = forPlan(resolveCode(req.code), planId)
    admit(planId, grant, { arrival: req.arrival, nights: req.nights, counts: true })
    return { q: check(rt, planId, req), grant }
  }
  /** A booking made under a promotion counts its use (Access.keepForBooking). */
  const countUse = (g: Grant) => { const p = g.promoId ? promoOf(g.promoId) : undefined; if (p) p.used += 1 }
  /** The active tax rules in the order they apply: by rank, then by id (Store.taxes). */
  const activeTaxes = (): TaxRule[] => setup().taxes.filter((x) => x.active).sort((a, b) => a.rank - b.rank || a.id - b.id)
    .map((x) => ({ id: x.id, code: x.code, name: x.name, kind: x.kind, bps: x.bps, amount: x.amount, base: x.onPriorTaxes ? 'roomAndPriorTaxes' : 'room', rank: x.rank }))
  const taxName = (id: number) => setup().taxes.find((x) => x.id === id)?.name
  const idDocs = new Map<number, IdDocumentView[]>()
  const idBlobs = new Map<string, { ciphertext: Uint8Array; fileKey: string }>()
  // the demo's night audit and four-eyes queue live in this page's memory
  let audit: AuditStatus | null = null
  const proposals: (ProposalView & { maker: string; credit?: { invoice: number; lineIds: number[]; amounts: bigint[] };
    desk?: { paymentId: number; method: DeskMethod; reference: string } })[] = []
  let nextProposal = 1
  /** A proposal waits for the other member of staff, who is the one who can approve it. */
  const queue = (b: Booking, dual: DualAct, amount: bigint, text: string, payload: { credit?: (typeof proposals)[number]['credit']; desk?: (typeof proposals)[number]['desk'] } = {}) => {
    const id = nextProposal++
    proposals.push({ id, act: dual, bookingId: b.id, ref: b.ref, amount, text, mine: true, maker: deskUser, ...payload })
    act(b, `propose:${dual}`)
    deskUser = deskUser === 'maker' ? 'checker' : 'maker'
    return id
  }
  // the demo has two members of staff at the desk, so a proposal can be approved by the other one
  let deskUser = 'maker'
  const free = (n: Night) => Math.max(0, n.allotment - n.sold - n.held)
  // ── group blocks (src/Blocks.mo): rooms held off sale for a group until its cut-off ──
  const blocks = () => (st.blocks ??= [])
  const heldBy = (k: DemoBlock, d: Day) => (k.open && d >= k.arrival && d < k.departure ? Math.max(0, k.rooms - (k.picked[d] ?? 0)) : 0)
  const blockedOn = (rt: number, d: Day) => blocks().reduce((a, k) => a + (k.roomTypeId === rt ? heldBy(k, d) : 0), 0)
  /** A night's rooms free to sell: what is not sold, held, or held by open blocks (Store.freeOn). */
  const freeAt = (rt: number, d: Day, n: Night) => Math.max(0, free(n) - blockedOn(rt, d))
  /** A picked-up booking gives back nights from..to: off the block's pickup, so back to it while it is open (Blocks.giveBack). */
  const giveBack = (b: Booking, from: Day, to: Day) => {
    const k = blocks().find((x) => x.id === st.pickups?.[b.id])
    if (k) for (let d = from; d < to; d++) k.picked[d] = Math.max(0, (k.picked[d] ?? 0) - b.rooms)
  }
  const blockView = (k: DemoBlock): BlockView => {
    let picked = 0, held = 0
    for (let d = k.arrival; d < k.departure; d++) { picked += k.picked[d] ?? 0; held += heldBy(k, d) }
    return { id: k.id, name: k.name, companyId: k.companyId, roomTypeId: k.roomTypeId, planId: k.planId, arrival: k.arrival, departure: k.departure, rooms: k.rooms,
      cutoff: k.cutoff, open: k.open, roomNights: k.rooms * (k.departure - k.arrival), pickedNights: picked, heldNights: held }
  }
  const blockOf = (id: number) => blocks().find((x) => x.id === id) ?? refuse('noSuchBlock', `There is no group block ${id}.`, 'لا توجد هذه المجموعة المحجوزة.')
  /** Can these rooms be picked up from the block for these nights (Blocks.checkPickup)? */
  const checkPickup = (k: DemoBlock, req: StayRequest) => {
    if (!k.open) refuse('blockReleased', `Group block ${k.id} has been released; its rooms are back on sale.`, 'أُفرج عن غرف هذه المجموعة وعادت للبيع؛ لم يعد الحجز منها ممكناً.')
    if (req.arrival < k.arrival || req.arrival + req.nights > k.departure) refuse('invalid', "A pickup's nights are within the block's dates.", 'ليالي الحجز من المجموعة داخل تواريخها.')
    for (let d = req.arrival; d < req.arrival + req.nights; d++) {
      if (heldBy(k, d) < req.rooms) refuse('blockFull', `Group block ${k.id} holds ${heldBy(k, d)} room(s) on ${fmt(d)}; ${req.rooms} were asked for.`, 'لم تعد غرف المجموعة تكفي في إحدى ليالي هذه الإقامة.')
    }
  }

  function sweep() {
    const now = Date.now()
    let moved = false
    for (const h of st.holds) {
      if (h.state === 'live' && h.expiresAtMs <= now) {
        for (let i = 0; i < h.req.nights; i++) { const n = night(h.roomTypeId, h.req.arrival + i); if (n) n.held = Math.max(0, n.held - h.req.rooms) }
        h.state = 'expired'
        moved = true
      }
    }
    if (moved) bump()
  }

  function check(rt: number, planId: number, req: StayRequest, fromBlock = false): Quote {
    const room = typeOf(rt)
    const plan = activePlans().find((p) => p.id === planId)
    if (!room || !room.active) refuse('noSuchRoomType', 'That room type does not exist.', 'نوع الغرفة هذا غير موجود.')
    if (!plan) refuse('noSuchPlan', 'That rate does not exist.', 'هذا السعر غير موجود.')
    const { maxStayNights, maxRoomsPerBooking, horizonDays } = prop()
    if (req.nights < 1 || req.nights > maxStayNights) refuse('stayLength', `A stay is 1 to ${maxStayNights} nights.`, `الإقامة من ليلة إلى ${maxStayNights} ليلة.`)
    if (req.rooms < 1 || req.rooms > maxRoomsPerBooking) refuse('rooms', `One booking holds 1 to ${maxRoomsPerBooking} rooms.`, `الحجز الواحد من غرفة إلى ${maxRoomsPerBooking} غرف.`)
    if (req.adults < 1 || req.adults > room.maxAdults * req.rooms || req.children > room.maxChildren * req.rooms || req.adults + req.children > room.maxOccupancy * req.rooms)
      refuse('occupancy', `Sleeps ${room.maxOccupancy} per room.`, `تتّسع لـ${room.maxOccupancy} في الغرفة.`)
    if (req.arrival < st.businessDate) refuse('inThePast', 'That date has passed.', 'هذا التاريخ مضى.')
    if (req.arrival + req.nights > st.businessDate + horizonDays) refuse('beyondHorizon', `We take bookings up to ${horizonDays} days ahead.`, `نستقبل الحجوزات حتى ${horizonDays} يوماً مقدّماً.`)
    const bars: bigint[] = []
    for (let i = 0; i < req.nights; i++) {
      const d = req.arrival + i
      const n = night(rt, d)
      if (!n) refuse('nightClosed', `Closed on ${fmt(d)}.`, `مغلقة في ${fmt(d, 'ar')}.`)
      // a pickup's rooms were taken off sale when the block was made: it is not asked for free rooms or the night's restrictions
      if (!fromBlock && n.stopSell) refuse('stopSell', `Closed on ${fmt(d)}.`, `مغلقة في ${fmt(d, 'ar')}.`)
      if (!fromBlock && freeAt(rt, d, n) < req.rooms) refuse('soldOut', `Sold out on ${fmt(d)}.`, `محجوزة بالكامل في ${fmt(d, 'ar')}.`)
      bars.push(n.bar)
    }
    const first = night(rt, req.arrival)
    const incs = incsOf(planId, req)
    if (fromBlock) return withPackage(price({ kind: plan.discountBps ? 'discountOffBar' : 'bar', discountBps: plan.discountBps }, req.arrival, bars, req.rooms, activeTaxes()), incs, activeTaxes(), req.arrival)
    if (first.cta) refuse('closedToArrival', `No arrivals on ${fmt(req.arrival)}.`, `لا وصول في ${fmt(req.arrival, 'ar')}.`)
    const dep = night(rt, req.arrival + req.nights)
    if (dep?.ctd) refuse('closedToDeparture', `No departures on ${fmt(req.arrival + req.nights)}.`, `لا مغادرة في ${fmt(req.arrival + req.nights, 'ar')}.`)
    if (req.nights < first.minStay) refuse('minStay', `Stays from ${fmt(req.arrival)} are at least ${first.minStay} nights.`, `الإقامات من ${fmt(req.arrival, 'ar')} لا تقلّ عن ${first.minStay} ليالٍ.`)
    return withPackage(price({ kind: plan.discountBps ? 'discountOffBar' : 'bar', discountBps: plan.discountBps }, req.arrival, bars, req.rooms, activeTaxes()), incs, activeTaxes(), req.arrival)
  }

  /** A plan's package as a quote prices it now (the contract's Res.packageOf): an inclusion whose extra is
   *  gone, off sale or priced when posted refuses the stay; its quantity is counted per room, adult or guest. */
  function incsOf(planId: number, req: StayRequest): IncInput[] {
    return (st.inclusions?.[planId] ?? []).map((inc, i) => {
      const e = st.extras.find((x) => x.id === inc.extraId)
      if (!e) refuse('noSuchExtra', 'There is no such extra.', 'لا يوجد هذا البند.')
      if (!e.active) refuse('inactive', 'This extra is no longer sold.', 'لم يعد هذا البند يُباع.')
      if (e.price === 0n) refuse('invalid', 'An extra in a package needs a set price.', 'البند في الباقة يحتاج إلى سعر محدد.')
      const per = inc.per === 'room' ? req.rooms : inc.per === 'adult' ? req.adults : req.adults + req.children
      return { slot: i + 1, extraId: e.id, unit: e.price, quantity: inc.quantity * per, rhythm: inc.rhythm, taxed: e.taxed }
    })
  }

  /** A quote's package lines as the guest's breakdown shows them, each named from the catalogue. */
  function packageLines(q: Quote): PackageLineView[] {
    return q.inclusions.map((l) => ({ day: l.night, slot: l.slot, extraId: l.extraId, name: st.extras.find((e) => e.id === l.extraId)?.name ?? { en: '', ar: '' },
      quantity: l.quantity, unit: l.unit, net: l.net, tax: l.taxes.reduce((a, x) => a + x.amount, 0n) }))
  }

  /** A quote's lines as the bill holds them: each night's room and its taxes, then each inclusion of the
   *  package as its own extra line with its taxes after it, posted by the package and never voided alone. */
  function quoteLines(q: Quote): Omit<DemoLine, 'id' | 'block'>[] {
    return [
      ...q.nightly.map((amount, i) => ({ kind: 'roomNight' as const, night: q.arrival + i, amount })),
      ...q.taxes.flatMap((tl) => tl.perNight.map((amount, i) => ({ kind: 'tax' as const, night: q.arrival + i, amount, code: tl.ruleId }))),
      ...q.inclusions.flatMap((l) => [
        { kind: 'extra' as const, night: l.night, amount: l.net, charge: { extraId: l.extraId, quantity: l.quantity, unit: l.unit, taxLines: l.taxes.length, voidLine: 0, pkg: true } },
        ...l.taxes.map((x) => ({ kind: 'extraTax' as const, night: l.night, amount: x.amount, code: x.ruleId })),
      ]),
    ]
  }

  function fmt(d: Day, lang: 'en' | 'ar' = 'en') {
    return new Intl.DateTimeFormat(lang === 'en' ? 'en-GB' : t.locale.ar, { day: 'numeric', month: 'short', timeZone: 'UTC' }).format(toDate(d))
  }

  /** One edit's checks, as the contract makes them, and the nights it would write; writes nothing.
   *  `touched` holds the nights earlier edits of the same save write: meeting one again is refused. */
  function planEdit(e: NightsEdit, adjust: RateAdjust | undefined, touched: Set<string>): [string, Night][] {
    const room = typeOf(e.roomTypeId)
    if (!room) refuse('noSuchRoomType', 'That room type does not exist.', 'نوع الغرفة هذا غير موجود.')
    if (e.fromDay < st.businessDate) refuse('inThePast', 'Past nights cannot be changed.', 'لا يمكن تغيير الليالي الماضية.')
    if (e.toDay <= e.fromDay) refuse('invalid', 'An edit covers at least one night.', 'التعديل يغطي ليلة واحدة على الأقل.')
    if (e.toDay - e.fromDay > 366) refuse('editTooWide', 'One change covers at most 366 nights.', 'التعديل الواحد يغطي 366 ليلة على الأكثر.')
    if (adjust) {
      if (e.bar !== undefined) refuse('invalid', 'Set a rate or change it by a percentage, not both.', 'حدّد السعر أو غيّره بنسبة، لا الاثنين معاً.')
      if (adjust.bps <= 0) refuse('invalid', 'A percentage change is above zero.', 'نسبة التغيير أكبر من صفر.')
      if (!adjust.up && adjust.bps >= 10_000) refuse('invalid', 'A rate cannot fall by 100% or more.', 'لا يمكن أن ينخفض السعر بنسبة 100% أو أكثر.')
      if (adjust.up && adjust.bps > 100_000) refuse('invalid', 'A rate rises by at most 1000% in one change.', 'يرتفع السعر بنسبة 1000% على الأكثر في تغيير واحد.')
    }
    const out: [string, Night][] = []
    for (let d = e.fromDay; d < e.toDay; d++) {
      if (!(e.weekdays & (1 << weekday(d)))) continue
      const k = `${e.roomTypeId}:${d}`
      if (touched.has(k)) refuse('invalid', `Two changes in one save touch ${fmt(d)}.`, `تغييران في حفظ واحد يمسّان ${fmt(d, 'ar')}.`)
      const n = night(e.roomTypeId, d)
      if (!n && e.bar === undefined) refuse('invalid', 'Set a rate for nights that are not open yet.', 'حدّد سعراً للّيالي غير المفتوحة بعد.')
      const base: Night = n ?? { allotment: 0, sold: 0, held: 0, bar: 0n, minStay: 1, maxStay: 0, cta: false, ctd: false, stopSell: false }
      const allotment = e.allotment ?? base.allotment
      const rooms = roomsOn(e.roomTypeId, d)
      if (e.allotment !== undefined && allotment > rooms)
        refuse('allotmentAboveRooms', `On ${fmt(d)} the ${room.name.en} has ${rooms} rooms in service.`, `في ${fmt(d, 'ar')} في ${room.name.ar} ${rooms} غرف في الخدمة.`)
      if (allotment < base.sold + base.held + blockedOn(e.roomTypeId, d)) refuse('allotmentBelowSold', `On ${fmt(d)} ${base.sold} rooms are sold and ${base.held} on hold.`, `في ${fmt(d, 'ar')} بيعت ${base.sold} غرف و${base.held} محجوزة مؤقتاً.`)
      const bar = e.bar ?? (adjust ? adjustedBar(base.bar, adjust) : base.bar)
      if (bar <= 0n) refuse('invalid', `The change would bring the rate on ${fmt(d)} to nothing.`, `سيجعل التغيير سعر ${fmt(d, 'ar')} صفراً.`)
      out.push([k, { ...base, bar, allotment, minStay: e.minStay ?? base.minStay, maxStay: e.maxStay ?? base.maxStay,
        cta: e.closedToArrival ?? base.cta, ctd: e.closedToDeparture ?? base.ctd, stopSell: e.stopSell ?? base.stopSell }])
    }
    if (out.length === 0) refuse('invalid', 'None of the chosen days of the week fall in this range.', 'لا يقع أي من أيام الأسبوع المختارة في هذه الفترة.')
    for (const [k] of out) touched.add(k)
    return out
  }
  // ── the bill: the contract's rules (src/Bill.mo, src/Windows.mo), on the demo's bookings ──
  const isTax = (k: FolioLineView['kind']) => k === 'tax' || k === 'extraTax'
  const winOfLine = (l: DemoLine) => l.payerId ?? 0
  const winOfPay = (p: DemoPayment) => p.payerId ?? 0
  /**
   * A refund of `back` to the guest, as the contract writes it (src/Reservations.mo refundGuest): split
   * across the guest's own cards, newest first, each up to what it can still give back, a card that has
   * refused a refund passed over; what no card can take is the desk's, as a refund the gateway would
   * not make. The demo's TEST gateway answers at once: a slice is made, or refused three times when the
   * card's issuer refuses refunds. Written first in the act, so the first slice's id is the next one.
   */
  function guestSlices(b: Booking, back: bigint): Omit<DemoPayment, 'id' | 'block'>[] {
    if (back <= 0n) return []
    const { slices, rest } = slicesOf(cardsOf(b.payments.filter((p) => winOfPay(p) === 0)), back)
    const firstSlice = b.payments.length + 1
    const out: Omit<DemoPayment, 'id' | 'block'>[] = slices.map(([auth, take]) => {
      const a = st.gateway.find((x) => x.id === auth)
      const made = !!a && !a.refusesRefunds
      if (made) a.refunded += take
      return { kind: 'refunded', state: made ? 'done' : 'failed', amount: take, gatewayAuth: auth, attempts: made ? 1 : 3, firstSlice, excess: back }
    })
    if (rest > 0n) out.push({ kind: 'refunded', state: 'failed', amount: rest, gatewayAuth: 0, attempts: 0, firstSlice, excess: back })
    return out
  }
  const refundOf = (b: Booking, p: DemoPayment): RefundView => ({
    paymentId: p.id, payerId: winOfPay(p), card: p.gatewayAuth, amount: p.amount, attempts: p.attempts, firstSlice: p.firstSlice ?? 0, excess: p.excess ?? 0n,
    state: p.state === 'failed' ? (desks().some((d) => d.bookingId === b.id && d.paymentId === p.id) ? 'paidAtDesk' : 'failed') : p.state,
  })
  /** Every window of a booking's bill; the guest's is the booking less the others. */
  function windowsOf(b: Booking): BillWindowView[] {
    const ids = [0, ...(b.payers ?? []).map((p) => p.id)]
    const ws = ids.map((payerId) => {
      let charges = 0n, credits = 0n, taxes = 0n, paid = 0n
      for (const l of b.lines) if (winOfLine(l) === payerId) { if (l.kind === 'credit') credits += l.amount; else charges += l.amount; if (isTax(l.kind)) taxes += l.amount }
      for (const p of b.payments) if (winOfPay(p) === payerId) { if (p.kind === 'captured' && p.state === 'done') paid += p.amount; if (p.kind === 'refunded') paid -= p.amount }
      const name = payerId === 0 ? b.guestName : b.payers!.find((x) => x.id === payerId)!.name
      const invoice = st.invoices.find((i) => i.bookingId === b.id && i.payerId === payerId)?.number ?? null
      return { payerId, name, charges, credits, taxes, paid, due: 0n, open: 0n, invoice }
    })
    // the guest's window from the booking's own figures, as the contract reads it
    const others = ws.slice(1)
    const sum = (f: (w: BillWindowView) => bigint) => others.reduce((a, w) => a + f(w), 0n)
    ws[0].charges = b.charged - sum((w) => w.charges)
    ws[0].credits = b.credited - sum((w) => w.credits)
    ws[0].paid = b.paid - sum((w) => w.paid)
    for (const w of ws) { const owes = w.charges - w.credits - w.paid; w.open = owes > 0n ? owes : 0n }
    return ws
  }
  const invoiced = (b: Booking, payerId: number) => st.invoices.some((i) => i.bookingId === b.id && i.payerId === payerId)
  const refuseInvoiced = (payerId: number) => refuse('invoiced', `${payerId === 0 ? "The guest's bill" : "This payer's bill"} is invoiced; nothing more goes on it or comes off it.`,
    `${payerId === 0 ? 'فاتورة الضيف' : 'فاتورة هذا الدافع'} صدرت؛ لا يُضاف إليها شيء ولا يُحذف منها.`)
  function billLines(b: Booking): BillLineView[] {
    const voided = new Set<number>()
    for (const l of b.lines) if (l.charge?.voidLine) { for (let i = l.id; i <= l.id + l.charge.taxLines; i++) voided.add(i); voided.add(l.charge.voidLine) }
    return b.lines.map((l) => {
      const ex = l.charge ? st.extras.find((e) => e.id === l.charge!.extraId) : undefined
      const tax = isTax(l.kind) ? taxName(l.code ?? 0) : undefined
      return { id: l.id, kind: l.kind, code: l.code ?? 0, night: l.night, amount: l.amount, payerId: winOfLine(l), title: ex?.name ?? tax ?? { en: '', ar: '' },
        quantity: l.charge?.quantity ?? 1, unitAmount: l.charge?.unit ?? l.amount, voided: voided.has(l.id),
        voidable: !!l.charge && !l.charge.pkg && !l.charge.voidLine && !invoiced(b, winOfLine(l)) }
    })
  }
  // ── credit notes: the contract's rules (src/CreditNote.mo), on the demo's bills ──
  const notes = () => (st.notes ??= [])
  const desks = () => (st.deskRefunds ??= [])
  const etaOf = () => (st.eta ??= { taxes: {} })
  /** How much of a line credit notes have taken back. */
  const creditedOf = (b: Booking, lineId: number) =>
    notes().filter((n) => n.bookingId === b.id).flatMap((n) => n.items).filter((x) => x.source === lineId).reduce((a, x) => a + x.amount, 0n)
  /** A line's taxes: an extra's are the lines that follow it; a night's are that night's tax lines. */
  const taxLinesOf = (b: Booking, l: DemoLine): DemoLine[] =>
    l.charge ? b.lines.filter((x) => x.id > l.id && x.id <= l.id + l.charge!.taxLines)
      : l.kind === 'roomNight' ? b.lines.filter((x) => x.kind === 'tax' && x.night === l.night) : []
  const divHalfEven = (n: bigint, d: bigint) => {
    const q = n / d, r2 = 2n * (n % d)
    return r2 > d || (r2 === d && q % 2n === 1n) ? q + 1n : q
  }
  /** Every check a credit note makes, at its proposal and again at its approval; the lines it would write. */
  function checkNote(b: Booking, invoice: number, lineIds: number[], amounts: bigint[]) {
    const inv = st.invoices.find((i) => i.number === invoice)
    if (!inv || inv.bookingId !== b.id) refuse('noSuchInvoice', `There is no invoice ${invoice} on this booking.`, `لا توجد الفاتورة ${invoice} في هذا الحجز.`)
    if (lineIds.length === 0 || lineIds.length > 16) refuse('invalid', 'A credit note names 1 to 16 lines.', 'يذكر إشعار الدائن من سطر إلى 16 سطراً.')
    if (lineIds.length !== amounts.length) refuse('invalid', 'Each line a credit note names needs its amount.', 'كل سطر يذكره إشعار الدائن يحتاج إلى مبلغه.')
    const items: { source: number; amount: bigint; tax: boolean }[] = []
    let net = 0n, taxes = 0n
    lineIds.forEach((id, i) => {
      const amount = amounts[i]
      if (lineIds.indexOf(id) !== i) refuse('invalid', `Line ${id} is named twice.`, `السطر ${id} مذكور مرتين.`)
      const l = b.lines.find((x) => x.id === id)
      if (!l || winOfLine(l) !== inv.payerId) refuse('otherBill', `Line ${id} is not on the bill of invoice ${invoice}.`, `السطر ${id} ليس على فاتورة رقم ${invoice}.`)
      if (!creditable(l.kind)) refuse('invalid', `Line ${id} cannot be taken back; a credit note takes back a night, an extra or a penalty, with its taxes.`,
        `لا يمكن استرداد السطر ${id}؛ يسترد إشعار الدائن ليلة أو بنداً إضافياً أو غرامة مع ضرائبها.`)
      if (l.charge?.voidLine) refuse('invalid', `Line ${id} is voided.`, `السطر ${id} ملغى.`)
      if (amount <= 0n) refuse('invalid', `Take back more than nothing of line ${id}.`, `استرد مبلغاً أكبر من صفر من السطر ${id}.`)
      const before = creditedOf(b, id)
      const left = l.amount > before ? l.amount - before : 0n
      if (amount > left) refuse('creditBeyondLine', `Line ${id} has ${left} left to take back.`, `تبقّى من السطر ${id} ${left} للاسترداد.`)
      items.push({ source: id, amount, tax: false })
      net += amount
      for (const tl of taxLinesOf(b, l)) {
        if (winOfLine(tl) !== inv.payerId) continue
        const target = divHalfEven(tl.amount * (before + amount), l.amount)
        const already = creditedOf(b, tl.id)
        if (target > already) { items.push({ source: tl.id, amount: target - already, tax: true }); taxes += target - already }
      }
    })
    const w = windowsOf(b).find((x) => x.payerId === inv.payerId)!
    if (net + taxes > w.charges - w.credits) refuse('invalid', 'This note would take back more than the bill is charged after its credits.', 'سيسترد هذا الإشعار أكثر مما على الفاتورة بعد أرصدتها.')
    return { inv, items, net, taxes }
  }
  /** A refund the gateway would not make, as the desk may pay it. */
  function checkDesk(b: Booking, paymentId: number, reference: string) {
    const p = b.payments.find((x) => x.id === paymentId)
    if (!p) refuse('noSuchPayment', `There is no payment ${paymentId} on this booking.`, `لا توجد الدفعة ${paymentId} في هذا الحجز.`)
    if (p.kind !== 'refunded') refuse('invalid', `Payment ${paymentId} is not a refund.`, `الدفعة ${paymentId} ليست استرداداً.`)
    if (p.state !== 'failed') refuse('invalid', `Refund ${paymentId} is ${p.state}; only a refund the gateway would not make is paid at the desk.`,
      `الاسترداد ${paymentId} ليس مرفوضاً؛ لا يُدفع في المكتب إلا استرداد رفضته بوابة الدفع.`)
    if (desks().some((d) => d.bookingId === b.id && d.paymentId === paymentId)) refuse('invalid', `Refund ${paymentId} was already paid at the desk.`, `دُفع الاسترداد ${paymentId} في المكتب من قبل.`)
    const n = new TextEncoder().encode(reference).length
    if (n === 0) refuse('invalid', 'Give the receipt number or the transfer reference.', 'أدخل رقم الإيصال أو مرجع التحويل.')
    if (n > 64) refuse('tooLong', 'A reference is at most 64 bytes.', 'المرجع 64 بايت على الأكثر.')
  }
  /** Who receives a note: the guest, or the payer of the bill it credits. */
  const receiverOf = (b: Booking, payerId: number) => payerId === 0 ? b.guestName : b.payers?.find((x) => x.id === payerId)?.name ?? ''
  /** A note's lines as the console reads them: the credit, the line it takes back, and what that line was. */
  function noteItems(b: Booking, n: DemoNote): CreditNoteLineView[] {
    return n.items.map((x) => {
      const src = b.lines.find((l) => l.id === x.source)!
      const ex = src.charge ? st.extras.find((e) => e.id === src.charge!.extraId) : undefined
      const title = ex?.name ?? (isTax(src.kind) ? taxName(src.code ?? 0) : undefined) ?? { en: '', ar: '' }
      return { id: x.lineId, source: x.source, sourceKind: src.kind, title, night: src.night, amount: x.amount, tax: x.tax }
    })
  }
  const noteRow = (n: DemoNote): CreditNoteRow => ({ number: n.number, invoice: n.invoice, bookingId: n.bookingId, payerId: n.payerId, issuedDay: n.issuedDay,
    net: n.net, taxes: n.taxes, total: n.total, lines: n.items.length, maker: n.maker, checker: n.checker })
  /** The note as the tax authority's credit note (type C, 1.0), built as src/Eta.mo builds it: the same members in the same
   *  order, numbers written as decimal text at the currency's places, and the digest of the authority's serialisation. */
  async function etaDocument(n: DemoNote, b: Booking): Promise<CreditNoteEta> {
    const e = etaOf(), p = prop(), places = p.minorUnits
    const missing: string[] = []
    const dec = (v: bigint, scale: number) => {
      const neg = v < 0n, m = neg ? -v : v, d = 10n ** BigInt(scale)
      return `${neg ? '-' : ''}${m / d}${scale ? '.' + (m % d).toString().padStart(scale, '0') : ''}`
    }
    type J = string | { num: string } | J[] | [string, J][] & { obj: true }
    const num = (v: bigint, scale: number) => ({ num: dec(v, scale) })
    const obj = (ms: [string, J][]) => Object.assign(ms, { obj: true as const })
    const prof = e.profile
    if (!prof) missing.push("the hotel's registration with the authority: its registration number, branch, address and activity code")
    const receiver = receiverOf(b, n.payerId)
    if (n.payerId !== 0) missing.push(`the registration number and address of ${receiver}, who receives this note`)
    const lines: { description: string; internalCode: string; amount: bigint; taxes: { taxType: string; subType: string; rate: bigint; amount: bigint }[] }[] = []
    const unnamed: string[] = []
    for (const x of n.items) {
      const src = b.lines.find((l) => l.id === x.source)!
      if (x.tax) {
        const rule = setup().taxes.find((r) => r.id === src.code)
        const codes = rule ? e.taxes[rule.id] : undefined
        if (!codes && rule && !unnamed.includes(rule.code)) unnamed.push(rule.code)
        lines.at(-1)?.taxes.push({ taxType: codes?.taxType ?? '', subType: codes?.subType ?? '', rate: rule?.kind === 'percent' ? BigInt(rule.bps) * 100n : 0n, amount: x.amount })
      } else {
        const ex = src.charge ? st.extras.find((q) => q.id === src.charge!.extraId) : undefined
        const rt = typeOf(b.roomTypeId)
        const [description, internalCode] = src.kind === 'roomNight' ? [`${rt?.name.en ?? 'Room'}, night of ${toDate(src.night).toISOString().slice(0, 10)}`, `ROOM-${rt?.code ?? ''}`]
          : ex ? [ex.name.en, `EXTRA-${ex.code}`] : src.kind === 'penalty' ? ['Cancellation charge', 'PENALTY'] : ['', '']
        lines.push({ description, internalCode, amount: x.amount, taxes: [] })
      }
    }
    for (const c of unnamed) missing.push(`the authority's tax type and sub-type of tax ${c}`)
    missing.push('the EGS item code of each line, as registered with the authority')
    missing.push(`the authority's identifier of invoice INV-${n.invoice}, which replaces INV-${n.invoice} in references once that invoice is submitted`)
    if (n.payerId === 0 && p.currency === 'EGP' && n.total >= 50_000n * 10n ** BigInt(places))
      missing.push("the guest's national id, which the authority asks for on a document of 50000 EGP and above")
    const address = (withBranch: boolean): J => obj([
      ...(withBranch ? [['branchID', prof?.branchId ?? ''] as [string, J]] : []),
      ['country', withBranch ? prof?.country ?? '' : ''], ['governate', withBranch ? prof?.governate ?? '' : ''], ['regionCity', withBranch ? prof?.regionCity ?? '' : ''],
      ['street', withBranch ? prof?.street ?? '' : ''], ['buildingNumber', withBranch ? prof?.buildingNumber ?? '' : '']])
    const lineTax = (l: (typeof lines)[number]) => l.taxes.reduce((a, x) => a + x.amount, 0n)
    const sales = lines.reduce((a, l) => a + l.amount, 0n), tax = lines.reduce((a, l) => a + lineTax(l), 0n)
    const totals: [string, bigint][] = []
    for (const l of lines) for (const x of l.taxes) { const i = totals.findIndex(([k]) => k === x.taxType); if (i < 0) totals.push([x.taxType, x.amount]); else totals[i][1] += x.amount }
    const z = num(0n, places)
    const doc = obj([
      ['issuer', obj([['address', address(true)], ['type', 'B'], ['id', prof?.issuerId ?? ''], ['name', p.name.en]])],
      ['receiver', obj([['address', address(false)], ['type', n.payerId === 0 ? 'P' : 'B'], ['id', ''], ['name', receiver]])],
      ['documentType', 'C'], ['documentTypeVersion', '1.0'], ['dateTimeIssued', `${toDate(n.issuedDay).toISOString().slice(0, 10)}T00:00:00Z`],
      ['taxpayerActivityCode', prof?.activityCode ?? ''], ['internalID', `CN-${n.number}`], ['references', [`INV-${n.invoice}`]],
      ['invoiceLines', lines.map((l) => obj([
        ['description', l.description], ['itemType', 'EGS'], ['itemCode', ''], ['unitType', 'EA'], ['quantity', num(1000n, 3)], ['internalCode', l.internalCode],
        ['salesTotal', num(l.amount, places)], ['total', num(l.amount + lineTax(l), places)], ['valueDifference', z], ['totalTaxableFees', z], ['netTotal', num(l.amount, places)],
        ['itemsDiscount', z], ['unitValue', obj([['currencySold', p.currency], ['amountEGP', num(l.amount, places)]])],
        ['discount', obj([['rate', num(0n, 2)], ['amount', z]])],
        ['taxableItems', l.taxes.map((x) => obj([['taxType', x.taxType], ['amount', num(x.amount, places)], ['subType', x.subType], ['rate', num(x.rate, 4)]]))],
      ]))],
      ['totalDiscountAmount', z], ['totalSalesAmount', num(sales, places)], ['netAmount', num(sales, places)],
      ['taxTotals', totals.map(([k, a]) => obj([['taxType', k], ['amount', num(a, places)]]))],
      ['totalAmount', num(sales + tax, places)], ['extraDiscountAmount', z], ['totalItemsDiscountAmount', z],
    ])
    const isObj = (j: J): j is [string, J][] & { obj: true } => Array.isArray(j) && 'obj' in j
    const emit = (j: J): string => typeof j === 'string' ? JSON.stringify(j) : isObj(j) ? `{${j.map(([k, v]) => `${JSON.stringify(k)}:${emit(v)}`).join(',')}}`
      : Array.isArray(j) ? `[${j.map(emit).join(',')}]` : j.num
    const q = (x: string) => `"${x}"`
    const serialize = (j: J): string => typeof j === 'string' ? q(j) : isObj(j)
      ? j.map(([k, v]) => Array.isArray(v) && !isObj(v) ? q(k.toUpperCase()) + v.map((x) => q(k.toUpperCase()) + serialize(x)).join('') : q(k.toUpperCase()) + serialize(v)).join('')
      : Array.isArray(j) ? j.map(serialize).join('') : q(j.num)
    const digest = hex(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(serialize(doc)))))
    return { json: emit(doc), digest, total: sales + tax, missing }
  }

  const bookingOf = (id: number) => {
    const b = st.bookings.find((x) => x.id === id)
    if (!b) refuse('noSuchBooking', 'There is no such booking.', 'لا يوجد هذا الحجز.')
    return b
  }

  // ── housekeeping: the contract's rules (src/Housekeeping.mo), on the demo's rooms ──
  /** Whether a room counts among its type's rooms on night `d`: in service, or out with dates ending by `d`. */
  const countsOn = (r: DemoRoom, d: Day) => !r.out || (r.out.until > 0 && r.out.until <= d)
  const roomsOn = (rt: number, d: Day) => st.rooms.filter((r) => r.roomTypeId === rt && countsOn(r, d)).length
  /** A type's rooms in service now (Store.activeRooms). */
  const inService = (rt: number) => st.rooms.filter((r) => r.roomTypeId === rt && !r.out).length
  const readiness = (r: DemoRoom) => (r.cleaning === 'inspected' ? 0 : r.cleaning === 'clean' ? 1 : r.cleaning === undefined ? 2 : 3)
  const roomOf = (id: number) => {
    const r = st.rooms.find((x) => x.id === id)
    if (!r) refuse('noSuchRoom', `There is no room ${id}.`, `لا توجد الغرفة ${id}.`)
    return r
  }
  /** Setup.codeOk and Setup.textsOk: a code of 1 to 16 bytes, each text at most 2,000 bytes. */
  const codeFits = (code: string) => {
    const n = new TextEncoder().encode(code).length
    if (n === 0) refuse('invalid', 'A code is required.', 'الرمز مطلوب.')
    if (n > 16) refuse('tooLong', 'The code is at most 16 bytes.', 'الرمز 16 بايت على الأكثر.')
  }
  const textsFit = (texts: string[]) => {
    for (const x of texts) if (new TextEncoder().encode(x).length > 2000) refuse('invalid', 'A text is at most 2,000 bytes.', 'النص 2,000 بايت على الأكثر.')
  }
  const cleaningAr: Record<Cleaning | '', string> = { dirty: 'غير نظيفة', clean: 'نظيفة', inspected: 'مُعاينة', '': 'بلا سجل' }

  function commit(writes: [string, Night][]) {
    for (const [k, n] of writes) st.nights[k] = n
    bump()
  }

  function view(b: Booking): BookingView {
    const { secretHash: _s, authId: _a, authAmount: _m, lines: _l, payments: _p, events: _e, ...rest } = b
    return { ...rest, block: st.block }
  }

  // ── the hotel clock ──
  // The demo reads the hotel's local time from the browser's own time-zone database (Intl) by the zone's
  // name, a different reading from the contract's, which evaluates the zone's rule; so the demo keeps the
  // zones Intl knows, and the automatic audit runs here on this page's minute timer.
  let autoLast: HotelClock['last'] = null
  function localNow(zone: string): { day: Day; second: number; abbr: string } | null {
    try {
      const parts = Object.fromEntries(new Intl.DateTimeFormat('en-US', { timeZone: zone, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit',
        minute: '2-digit', second: '2-digit', hourCycle: 'h23', timeZoneName: 'short' }).formatToParts(new Date()).map((x) => [x.type, x.value]))
      return { day: dayOf(+parts.year, +parts.month, +parts.day), second: +parts.hour * 3600 + +parts.minute * 60 + +parts.second, abbr: parts.timeZoneName ?? '' }
    } catch { return null }
  }
  const dueThrough = (c: DemoClock): Day | null => {
    const n = localNow(c.zoneName)
    if (!n) return null
    const last = n.second >= c.auditAt ? n.day - 1 : n.day - 2
    return last < 0 ? null : last
  }
  async function autoTick(api: Api) {
    const c = st.clock
    if (!c?.auto) return
    const due = dueThrough(c)
    if (due === null || st.businessDate > due) return
    let steps = 0, act = '', day = st.businessDate
    try {
      while (steps < 24 && st.businessDate <= due) {
        day = st.businessDate
        const a = await api.auditStatus(day)
        if (!a.open) { act = 'openAudit'; await api.openAudit(day) }
        else if (a.completed && a.walkDone) { act = 'closeDay'; await api.closeDay(day) }
        else { act = 'advanceAudit'; await api.advanceAudit(day) }
        steps++
      }
      autoLast = { at: new Date(), day, act, ok: true, reason: '', steps }
    } catch (e) {
      autoLast = { at: new Date(), day, act, ok: false, reason: e instanceof Refused ? e.reason.en : String(e), steps: steps + 1 }
    }
  }

  const api: Api = {
    source: 'demo',

    async hotelClock(): Promise<HotelClock> {
      const c = st.clock
      if (!c) return { set: false, zoneName: '', zoneRule: '', auditAt: 0, auto: false, localDay: 0, localSecond: 0, zoneNow: '', dueThrough: null, businessDate: st.businessDate, last: autoLast }
      const n = localNow(c.zoneName)
      return { set: true, ...c, localDay: n?.day ?? 0, localSecond: n?.second ?? 0, zoneNow: n?.abbr ?? '', dueThrough: dueThrough(c), businessDate: st.businessDate, last: autoLast }
    },

    async setHotelClock(c: HotelClockSetting) {
      await wait(300)
      if (!c.zoneName) refuse('invalid', 'Name the time zone, such as Africa/Cairo.', 'سمِّ المنطقة الزمنية، مثل Africa/Cairo.')
      if (!localNow(c.zoneName)) refuse('invalid', 'The demo desk keeps the zones this browser knows by name; another zone is kept on the hotel\'s own contract.',
        'مكتب العرض يحفظ المناطق التي يعرفها هذا المتصفح بالاسم؛ تُحفظ المناطق الأخرى في عقد الفندق نفسه.')
      if (!c.zoneRule) refuse('invalid', 'The time-zone rule is empty.', 'قاعدة المنطقة الزمنية فارغة.')
      if (!Number.isInteger(c.auditAt) || c.auditAt < 0 || c.auditAt >= 86_400) refuse('invalid', 'The audit time is a time of day, before 24:00.', 'وقت التدقيق وقتٌ من اليوم قبل 24:00.')
      if (c.auditAt % 60 !== 0) refuse('invalid', 'The audit time is set to the minute.', 'يُضبط وقت التدقيق بالدقيقة.')
      st.clock = { zoneName: c.zoneName, zoneRule: c.zoneRule, auditAt: c.auditAt, auto: c.auto }
      bump()
      save()
      void autoTick(api)
    },

    async property(): Promise<PropertyView> {
      sweep()
      return {
        name: prop().name, currency: prop().currency, minorUnits: prop().minorUnits, businessDate: st.businessDate,
        checkIn: t.checkIn, checkOut: t.checkOut, maxStayNights: prop().maxStayNights, maxRoomsPerBooking: prop().maxRoomsPerBooking,
        holdRealSeconds: holdSeconds(), idRetentionDays: prop().idRetentionDays, atBlock: st.block,
      }
    },

    async roomTypes(): Promise<RoomTypeView[]> {
      return activeTypes().map((r) => ({
        id: r.id, code: r.code, name: r.name, desc: r.desc, sizeSqm: r.sizeSqm, maxAdults: r.maxAdults,
        maxChildren: r.maxChildren, maxOccupancy: r.maxOccupancy, bedKind: r.bedKind, bedCount: r.bedCount,
        amenities: r.amenities, view: t.rooms.find((x) => x.code === r.code)?.view ?? { en: '', ar: '' }, photos: photosFor(r.photos), rooms: inService(r.id),
      }))
    },

    async plans(code) {
      let g = PUBLIC
      try { g = resolveCode(code) } catch { /* a code that opens nothing lists the public plans */ }
      return plansFor(g)
    },

    async staffPlans() { return activePlans() },

    async codeInfo(code): Promise<CodeView> {
      try {
        const g = resolveCode(code)
        const name = g.companyId ? (st.companies ?? []).find((x) => x.id === g.companyId)!.name : promoOf(g.promoId)!.name
        return { ok: true, kind: g.companyId ? 'company' : 'promotion', reason: { en: '', ar: '' }, name,
          planIds: (st.access ?? []).filter((a) => a.closed && admits(a.planId, g) && setup().plans.some((p) => p.id === a.planId && p.active)).map((a) => a.planId) }
      } catch (e) {
        if (e instanceof Refused) return { ok: false, kind: e.kind, reason: e.reason, name: '', planIds: [] }
        throw e
      }
    },

    async calendar(rt, from, days): Promise<CalendarDay[]> {
      sweep()
      await wait(120)
      const out: CalendarDay[] = []
      // the lowest rate on public sale: the deepest discount among the active plans no code is needed for
      const deepest = plansFor(PUBLIC).reduce((m, p) => Math.max(m, p.discountBps), 0)
      for (let d = from; d < from + days; d++) {
        let best: bigint | null = null
        let cta = true, ctd = true, minStay = 99
        const types = rt ? [rt] : activeTypes().map((x) => x.id)
        for (const r of types) {
          const n = night(r, d)
          if (!n || n.stopSell || freeAt(r, d, n) < 1) continue
          const rate = deepest ? displayRate(n.bar, { kind: 'discountOffBar', discountBps: deepest }) : n.bar
          if (best === null || rate < best) best = rate
          cta = cta && n.cta
          ctd = ctd && n.ctd
          minStay = Math.min(minStay, n.minStay)
        }
        out.push({ day: d, from: best, bookable: best !== null && d >= st.businessDate, closedToArrival: best !== null && cta, closedToDeparture: best !== null && ctd, minStay: best === null ? 1 : minStay })
      }
      return out
    },

    async search(req): Promise<SearchResult> {
      sweep()
      await wait(260)
      const offers: Offer[] = []
      const unavailable: SearchResult['unavailable'] = []
      const grant = resolveCode(req.code)
      for (const type of activeTypes()) {
        const rt = type.id
        let reason: { kind: string; reason: Bi } | null = null
        for (const plan of plansFor(grant)) {
          try {
            admit(plan.id, forPlan(grant, plan.id), { arrival: req.arrival, nights: req.nights, counts: true })
            const q = check(rt, plan.id, req)
            let left = Infinity
            for (let k = 0; k < req.nights; k++) left = Math.min(left, freeAt(rt, req.arrival + k, night(rt, req.arrival + k)))
            offers.push({
              roomTypeId: rt, planId: plan.id, total: q.total, roomSubtotal: q.roomSubtotal, taxTotal: q.taxTotal,
              perNightAvg: q.total / BigInt(q.nights * req.rooms), left: left === Infinity ? 0 : left,
              cancelDeadline: plan.refundable ? req.arrival - plan.freeCancelDaysBefore : null,
              guarantee: guaranteeFor(plan, q),
              quoteHash: await quoteHash(rt, plan.id, q), packageTotal: q.packageTotal,
            })
          } catch (e) {
            if (e instanceof Refused) reason = { kind: e.kind, reason: e.reason }
            else throw e
          }
        }
        if (!offers.some((o) => o.roomTypeId === rt) && reason) unavailable.push({ roomTypeId: rt, ...reason })
      }
      return { offers, unavailable, atBlock: st.block }
    },

    async quoteDetail(rt, planId, req): Promise<QuoteDetail> {
      const { q } = checkFor(rt, planId, req)
      const nameOf = (id: number) => taxName(id) ?? { en: '', ar: '' }
      return {
        nights: q.nightly.map((room, i) => ({ day: req.arrival + i, room, taxes: q.taxes.map((x) => ({ ruleId: x.ruleId, name: nameOf(x.ruleId), amount: x.perNight[i] })) })),
        taxLines: q.taxes.map((x) => ({ ruleId: x.ruleId, name: nameOf(x.ruleId), amount: x.amount })),
        roomSubtotal: q.roomSubtotal, package: packageLines(q), packageTotal: q.packageTotal, total: q.total,
      }
    },

    async placeHold(rt, planId, req, shown): Promise<HoldView> {
      sweep()
      await wait(350)
      const { q, grant } = checkFor(rt, planId, req)
      if ((await quoteHash(rt, planId, q)) !== shown) refuse('priceChanged', 'The price has just changed. Please check the new total.', 'تغيّر السعر للتوّ. يُرجى مراجعة الإجمالي الجديد.')
      for (let i = 0; i < req.nights; i++) night(rt, req.arrival + i).held += req.rooms
      const h: Hold = { id: st.nextHold++, roomTypeId: rt, planId, req, quote: q, expiresAtMs: Date.now() + holdSeconds() * 1000, state: 'live',
        ...(grant.companyId ? { companyId: grant.companyId } : {}), ...(grant.promoId ? { promoId: grant.promoId } : {}) }
      st.holds.push(h)
      return { holdId: h.id, total: q.total, expiresAtMs: h.expiresAtMs, block: bump() }
    },

    async releaseHold(holdId) {
      const h = st.holds.find((x) => x.id === holdId)
      if (!h || h.state !== 'live') return
      for (let i = 0; i < h.req.nights; i++) { const n = night(h.roomTypeId, h.req.arrival + i); n.held = Math.max(0, n.held - h.req.rooms) }
      h.state = 'released'
      bump()
    },

    // The TEST gateway: the card number stays in the browser; only a scenario reaches it.
    async authorise(scenario: TestScenario, amount, ref, keepOnFile = false): Promise<AuthResult> {
      await wait(700)
      if (scenario === 'decline') return { ok: false, authId: 0, reason: 'The card was declined.' }
      if (scenario === 'insufficient') return { ok: false, authId: 0, reason: 'Not enough funds on this card.' }
      const id = st.nextAuth++
      const a: GatewayAuth = { id, amount, ref, captured: 0n, refunded: 0n, voided: false, ...(scenario === 'refundDeclined' ? { refusesRefunds: true } : {}),
        ...(keepOnFile ? { token: 900_000 + id } : {}), ...(scenario === 'mitDeclined' ? { mitDeclines: true } : {}) }
      st.gateway.push(a)
      save()
      return { ok: true, authId: a.id }
    },

    async confirmHold(holdId, guest, authId): Promise<ConfirmResult> {
      sweep()
      await wait(450)
      const h = st.holds.find((x) => x.id === holdId)
      if (!h) refuse('noSuchHold', 'This hold no longer exists.', 'هذا الحجز المؤقت لم يعد موجوداً.')
      if (h.state !== 'live') refuse('holdExpired', 'Your hold has expired.', 'انتهت مهلة حجزك المؤقت.')
      // the access the hold was placed under must still admit its rate: a company or a promotion taken off sale
      // since is refused, and a promotion's last use is taken by the first confirmation
      const held: Grant = { companyId: h.companyId ?? 0, promoId: h.promoId ?? 0 }
      admit(h.planId, held, { arrival: h.req.arrival, nights: h.req.nights, counts: true })
      const plan = planView(setup().plans.find((p) => p.id === h.planId)!)
      const guarantee = guaranteeFor(plan, h.quote)
      if (guarantee === 0n) refuse('invalid', "The rate's deposit is not set.", 'لم تُحدَّد نسبة العربون لهذا السعر.')
      const a = st.gateway.find((x) => x.id === authId)
      if (!a || a.ref !== holdId || a.amount !== guarantee) refuse('payment', 'The payment does not match this booking.', 'الدفع لا يطابق هذا الحجز.')
      if (a.token && plan.guarantee === 'prepaidInFull') refuse('payment', 'A rate paid in advance keeps no card on file.', 'السعر المدفوع مقدماً لا يحتفظ بالبطاقة.')
      if (!a.token && plan.keepsCard) refuse('payment', "This rate keeps the guest's card on file, and the guest has not agreed to it.", 'هذا السعر يحتفظ ببطاقة الضيف، ولم يوافق الضيف على ذلك.')
      if (st.bookings.some((b) => b.authId === authId)) refuse('authUsed', 'This payment was already used.', 'استُخدم هذا الدفع من قبل.')
      if (!guest.name.trim()) refuse('invalid', "The guest's name is required.", 'اسم الضيف مطلوب.')
      for (let i = 0; i < h.req.nights; i++) { const n = night(h.roomTypeId, h.req.arrival + i); n.held -= h.req.rooms; n.sold += h.req.rooms }
      h.state = 'confirmed'
      const secretBytes = crypto.getRandomValues(new Uint8Array(16))
      const secret = [...secretBytes].map((b) => b.toString(16).padStart(2, '0')).join('')
      const id = st.nextBooking++
      const prepaid = plan.guarantee === 'prepaidInFull'
      // a stay paid in advance is captured whole; a deposit is captured at once; a first night stays authorised
      const now = prepaid || plan.guarantee === 'deposit' ? guarantee : 0n
      if (now > 0n) { a.captured = now; st.capturedDone = (BigInt(st.capturedDone) + now).toString() }
      const b: Booking = {
        id, ref: refFor(id), status: 'confirmed', roomTypeId: h.roomTypeId, planId: h.planId,
        arrival: h.req.arrival, departure: h.req.arrival + h.req.nights, rooms: h.req.rooms,
        adults: h.req.adults, children: h.req.children, guestName: guest.name.trim(),
        charged: h.quote.total, credited: 0n, paid: now, outstanding: h.quote.total - now,
        penalty: plan.refundable ? firstNights(h.quote, Math.max(1, plan.penaltyNights)) : h.quote.total - h.quote.packageTotal,
        cancelDeadline: plan.refundable ? h.req.arrival - plan.freeCancelDaysBefore : null, refundable: plan.refundable,
        block: 0, secretHash: await sha(secret), authId, authAmount: a.amount, lines: [], payments: [], events: [],
      }
      st.bookings.push(b)
      countUse(held)
      const q = h.quote
      act(b, 'confirmHold', quoteLines(q), [
        { kind: 'authorised' as const, state: 'done', amount: a.amount, gatewayAuth: authId, attempts: 1 },
        ...(now > 0n ? [{ kind: 'captured' as const, state: 'done' as const, amount: now, gatewayAuth: authId, attempts: 1 }] : []),
      ])
      if (a.token) cards()[id] = { state: 'kept', token: a.token, firstAuth: authId, deadline: 0, chargeId: 0, declinedDay: 0 }
      const sent = mailAttach(b, guest.email, guest.lang ?? 'en')
      return { booking: view(b), manageSecret: secret, captured: now > 0n, mail: sent }
    },

    // a booking for a guest on the phone or at the desk, as the contract takes it: the same stay and price
    // a guest books online, its nights sold at once, no card; a walk-in is checked in to its rooms in the same act
    async bookByStaff(channel, offer, req, guest, roomIds): Promise<StaffBookResult> {
      sweep()
      await wait(400)
      if (channel === 'walkIn' && req.arrival !== st.businessDate) refuse('notTheDay', 'A walk-in arrives today.', 'الضيف الحاضر يصل اليوم.')
      if (channel === 'phone' && roomIds.length) refuse('invalid', 'A booking by phone is given its rooms at check-in.', 'تُعطى غرف الحجز الهاتفي عند الوصول.')
      const { q, grant } = checkFor(offer.roomTypeId, offer.planId, req)
      if ((await quoteHash(offer.roomTypeId, offer.planId, q)) !== offer.quoteHash) refuse('priceChanged', 'The price has just changed. Please check the new total.', 'تغيّر السعر للتوّ. يُرجى مراجعة الإجمالي الجديد.')
      if (!guest.name.trim()) refuse('invalid', "The guest's name is required.", 'اسم الضيف مطلوب.')
      if (channel === 'walkIn') {
        if (roomIds.length !== req.rooms) refuse('invalid', `Choose ${req.rooms} room(s).`, `اختر ${req.rooms} غرفة.`)
        if (new Set(roomIds).size !== roomIds.length) refuse('invalid', 'A room is chosen twice.', 'اختيرت غرفة مرتين.')
        for (const id of roomIds) {
          const r = st.rooms.find((x) => x.id === id)
          if (!r) refuse('noSuchRoom', 'There is no such room.', 'لا توجد هذه الغرفة.')
          if (r.roomTypeId !== offer.roomTypeId) refuse('roomWrongType', 'That room is of another type.', 'هذه الغرفة من نوع آخر.')
          if (r.occupiedBy !== 0 || r.out) refuse('roomNotVacant', 'That room is not free.', 'هذه الغرفة غير متاحة.')
        }
      }
      for (let i = 0; i < req.nights; i++) night(offer.roomTypeId, req.arrival + i).sold += req.rooms
      const plan = planView(setup().plans.find((p) => p.id === offer.planId)!)
      const secretBytes = crypto.getRandomValues(new Uint8Array(16))
      const secret = [...secretBytes].map((x) => x.toString(16).padStart(2, '0')).join('')
      const id = st.nextBooking++
      const b: Booking = {
        id, ref: refFor(id), status: channel === 'walkIn' ? 'checkedIn' : 'confirmed', roomTypeId: offer.roomTypeId, planId: offer.planId,
        arrival: req.arrival, departure: req.arrival + req.nights, rooms: req.rooms, adults: req.adults, children: req.children, guestName: guest.name.trim(),
        charged: q.total, credited: 0n, paid: 0n, outstanding: q.total,
        penalty: plan.refundable ? firstNights(q, Math.max(1, plan.penaltyNights)) : q.total - q.packageTotal,
        cancelDeadline: plan.refundable ? req.arrival - plan.freeCancelDaysBefore : null, refundable: plan.refundable,
        block: 0, secretHash: await sha(secret), authId: 0, authAmount: 0n, lines: [], payments: [], events: [],
      }
      st.bookings.push(b)
      for (const rid of roomIds) st.rooms.find((x) => x.id === rid)!.occupiedBy = id
      ;(st.staffBookings ??= {})[id] = { channel, madeBy: DEMO_ME, day: st.businessDate }
      countUse(grant)
      act(b, 'bookByStaff', quoteLines(q))
      // a booking by phone on a rate that keeps a card waits for the guest's card, by its last free day
      if (channel !== 'walkIn' && plan.keepsCard)
        cards()[id] = { state: 'wanted', token: 0, firstAuth: 0, deadline: plan.refundable ? req.arrival - plan.freeCancelDaysBefore : st.businessDate, chargeId: 0, declinedDay: 0 }
      return { booking: view(b), manageSecret: secret, mail: mailAttach(b, guest.email, guest.lang ?? 'en') }
    },

    async staffBooking(bookingId) {
      await wait(80)
      return st.staffBookings?.[bookingId] ?? null
    },

    async dayFigures(fromDay, days) {
      await wait(120)
      const figs = history()
      const out: DayFiguresView[] = []
      for (let d = fromDay; d < fromDay + Math.min(Math.max(days, 1), 62); d++) if (figs[d]) out.push({ ...figs[d], closed: d < st.businessDate })
      return out
    },

    async dayRevenue(fromDay, days) {
      await wait(120)
      history()
      const to = fromDay + Math.min(Math.max(days, 1), 62)
      return (st.revenue ?? []).filter((r) => r.day >= fromDay && r.day < to).map((r) => ({ ...r }))
    },

    async onTheBooks(fromDay, days) {
      await wait(160)
      const to = fromDay + Math.min(Math.max(days, 1), 62)
      const sums = new Map<string, NightRevenue>()
      for (const b of st.bookings) {
        if (b.status !== 'confirmed' && b.status !== 'checkedIn') continue
        for (const l of b.lines) {
          if (l.kind !== 'roomNight' || l.night < fromDay || l.night >= to) continue
          const k = `${l.night}/${b.roomTypeId}/${b.planId}`
          const was = sums.get(k) ?? { day: l.night, roomTypeId: b.roomTypeId, planId: b.planId, roomNights: 0, revenue: 0n }
          sums.set(k, { ...was, roomNights: was.roomNights + b.rooms, revenue: was.revenue + l.amount })
        }
      }
      return [...sums.values()].sort((a, b) => a.day - b.day || a.roomTypeId - b.roomTypeId || a.planId - b.planId)
    },

    async manage(ref, secret): Promise<BookingView> {
      await wait(200)
      const b = st.bookings.find((x) => x.ref === ref)
      if (!b || b.secretHash !== (await sha(secret))) refuse('notFound', 'No booking matches this link.', 'لا يوجد حجز يطابق هذا الرابط.')
      const plan = setup().plans.find((p) => p.id === b.planId)
      return { ...view(b), ...(plan ? { planName: plan.name } : {}) }
    },

    async cancel(ref, secret): Promise<CancelResult> {
      await wait(400)
      const b = st.bookings.find((x) => x.ref === ref)
      if (!b || b.secretHash !== (await sha(secret))) refuse('notFound', 'No booking matches this link.', 'لا يوجد حجز يطابق هذا الرابط.')
      if (b.status !== 'confirmed') refuse('bookingState', 'This booking can no longer be cancelled.', 'لم يعد إلغاء هذا الحجز ممكناً.')
      const free = b.refundable && b.cancelDeadline !== null && st.businessDate <= b.cancelDeadline
      const liability = free ? 0n : b.penalty
      const credit = b.charged - b.credited - liability
      b.credited += credit > 0n ? credit : 0n
      let refund = 0n, take = 0n
      if (b.paid > liability) { refund = b.paid - liability; b.paid = liability; st.refundsCommitted = (BigInt(st.refundsCommitted) + refund).toString() }
      // a booking staff took carries no card: its fee stays outstanding, to pay at the desk, as on the contract
      const card = st.gateway.find((x) => x.id === b.authId)
      if (b.paid < liability && card) {
        const a = card
        take = liability - b.paid
        a.captured += take; b.paid += take; st.capturedDone = (BigInt(st.capturedDone) + take).toString()
      }
      b.outstanding = b.charged - b.credited - b.paid
      b.status = 'cancelled'
      mailHook(b, 'cancelled')
      letGo(b.id)
      for (let d = b.arrival; d < b.departure; d++) { const n = night(b.roomTypeId, d); if (n) n.sold = Math.max(0, n.sold - b.rooms) }
      giveBack(b, b.arrival, b.departure)
      // as the contract settles: a refund of what was paid over the fee, a capture of a fee not yet paid, or the authorisation let go
      act(b, 'cancelBooking', credit > 0n ? [{ kind: 'credit', night: b.arrival, amount: credit }] : [], [
        ...guestSlices(b, refund),
        ...(take > 0n ? [{ kind: 'captured' as const, state: 'done' as const, amount: take, gatewayAuth: b.authId, attempts: 1 }] : []),
        ...(b.paid === 0n && b.authId !== 0 ? [{ kind: 'voided' as const, state: 'done' as const, amount: b.authAmount, gatewayAuth: b.authId, attempts: 1 }] : []),
      ])
      return { booking: view(b), fee: liability, refund }
    },

    // The same laws the contract's oracle checks, over this browser's data.
    async seal(): Promise<SealView> {
      const violations: string[] = []
      let examined = 0
      for (const [k, n] of Object.entries(st.nights)) {
        examined++
        const [rt, d] = k.split(':').map(Number)
        if (n.sold + n.held + blockedOn(rt, d) > n.allotment) violations.push(`capacity ${k}`)
      }
      for (const b of st.bookings) {
        examined++
        if (b.charged !== b.paid + b.credited + b.outstanding) violations.push(`money ${b.ref}`)
        if (b.outstanding < 0n) violations.push(`outstanding ${b.ref}`)
      }
      const paid = st.bookings.reduce((a, b) => a + b.paid, 0n)
      if (paid !== BigInt(st.capturedDone) - BigInt(st.refundsCommitted)) violations.push('cash')
      return { ok: violations.length === 0, scope: 'full', invariants: 4, examined, violations }
    },

    async grid(from, days): Promise<GridRow[]> {
      sweep()
      await wait(150)
      return setup().roomTypes.map((type) => {
        const rt = type.id
        const cells = []
        for (let d = from; d < from + days; d++) {
          const n = night(rt, d)
          cells.push(n
            ? { day: d, allotment: n.allotment, sold: n.sold, held: n.held, blocked: blockedOn(rt, d), bar: n.bar, minStay: n.minStay, closedToArrival: n.cta, closedToDeparture: n.ctd, stopSell: n.stopSell }
            : { day: d, allotment: 0, sold: 0, held: 0, blocked: 0, bar: null, minStay: 1, closedToArrival: false, closedToDeparture: false, stopSell: false })
        }
        return { roomTypeId: rt, cells }
      })
    },

    async auditStatus(day) {
      if (audit && audit.businessDate === day) return audit
      return { open: false, completed: false, items: 0, done: 0, failures: 0, walkDone: false, examined: 0, violations: 0, firstViolation: '', businessDate: st.businessDate }
    },

    async openAudit(day) {
      await wait(300)
      if (day !== st.businessDate) refuse('notTheDay', 'The audit is for the hotel\'s current day.', 'التدقيق لليوم الحالي للفندق.')
      const arrivals = st.bookings.filter((b) => b.status === 'confirmed' && b.arrival === day).length
      const holds = st.holds.filter((h) => h.state === 'live' && h.expiresAtMs <= Date.now()).length
      audit = { open: true, completed: false, items: Math.max(1, Math.ceil(arrivals / 16)) + Math.max(1, Math.ceil(holds / 16)) + 1, done: 0, failures: 0,
        walkDone: false, examined: 0, violations: 0, firstViolation: '', businessDate: day }
    },

    async advanceAudit(day) {
      await wait(450)
      if (!audit || audit.businessDate !== day) refuse('audit', 'Open the audit first.', 'افتح التدقيق أولاً.')
      if (!audit.completed) {
        sweep()
        // arrivals of the day who never checked in become no-shows: the first night stands, the nights go back
        for (const b of st.bookings.filter((x) => x.status === 'confirmed' && x.arrival === day)) {
          const credit = b.charged - b.credited - b.penalty
          if (credit > 0n) b.credited += credit
          b.outstanding = b.charged - b.credited - b.paid
          b.status = 'noShow'
          mailHook(b, 'arrivedOrNot')
          for (let d = b.arrival; d < b.departure; d++) { const n = night(b.roomTypeId, d); if (n) n.sold = Math.max(0, n.sold - b.rooms) }
      giveBack(b, b.arrival, b.departure)
          act(b, 'advanceAudit', credit > 0n ? [{ kind: 'credit', night: b.arrival, amount: credit }] : [])
          noShowCard(b, day)
        }
        // the blocks whose cut-off has come give what is not picked up back to sale (the audit's blocks job)
        for (const k of blocks()) if (k.open && k.cutoff <= day) k.open = false
        audit = { ...audit, done: audit.items, completed: true }
      } else if (!audit.walkDone) {
        const s = await this.seal()
        audit = { ...audit, walkDone: true, examined: s.examined, violations: s.violations.length, firstViolation: s.violations[0] ?? '' }
      }
      bump()
      return audit
    },

    async closeDay(day) {
      await wait(300)
      if (!audit || !audit.completed || !audit.walkDone) refuse('audit', 'Finish the audit before closing the day.', 'أنهِ التدقيق قبل إغلاق اليوم.')
      if (audit.violations > 0) refuse('audit', 'The books show a problem; the day stays open.', 'تُظهر الحسابات مشكلة؛ يبقى اليوم مفتوحاً.')
      writeFigures(day)
      st.businessDate = day + 1
      audit = null
      bump()
      return st.businessDate
    },

    async creditNotes(bookingId) {
      await wait(100)
      return notes().filter((n) => n.bookingId === bookingId).map(noteRow)
    },

    async creditNote(number) {
      await wait(120)
      const n = notes().find((x) => x.number === number)
      if (!n) return null
      const b = bookingOf(n.bookingId)
      const inv = st.invoices.find((i) => i.number === n.invoice)!
      return { ...noteRow(n), invoiceDay: inv.issuedDay, ref: b.ref, payerName: receiverOf(b, n.payerId), guestName: b.guestName, hotel: t.name, lineItems: noteItems(b, n) }
    },

    async creditNoteEta(number) {
      await wait(120)
      const n = notes().find((x) => x.number === number)
      if (!n) return null
      return etaDocument(n, bookingOf(n.bookingId))
    },

    async creditedLines(bookingId) {
      const out = new Map<number, bigint>()
      for (const n of notes()) if (n.bookingId === bookingId) for (const x of n.items) out.set(x.source, (out.get(x.source) ?? 0n) + x.amount)
      return out
    },

    async proposeCreditNote(bookingId, invoice, lineIds, amounts, justification) {
      await wait(300)
      if (!justification.trim()) refuse('invalid', 'Say why, for the person who will approve it.', 'اذكر السبب لمن سيوافق عليه.')
      const b = bookingOf(bookingId)
      checkNote(b, invoice, lineIds, amounts)
      return queue(b, 'issueCreditNote', amounts.reduce((a, x) => a + x, 0n), `INV-${invoice}`, { credit: { invoice, lineIds, amounts } })
    },

    async proposeDeskRefund(bookingId, paymentId, method, reference, justification) {
      await wait(300)
      if (!justification.trim()) refuse('invalid', 'Say why, for the person who will approve it.', 'اذكر السبب لمن سيوافق عليه.')
      const b = bookingOf(bookingId)
      checkDesk(b, paymentId, reference)
      return queue(b, 'refundAtDesk', BigInt(paymentId), `${method} ${reference}`, { desk: { paymentId, method, reference } })
    },

    async deskRefunds(bookingId) {
      return desks().filter((d) => d.bookingId === bookingId).map(({ bookingId: _b, ...d }) => d)
    },

    async refunds(bookingId) {
      const b = st.bookings.find((x) => x.id === bookingId)
      return b ? b.payments.filter((p) => p.kind === 'refunded').map((p) => refundOf(b, p)) : []
    },

    async creditNoteRefund(number) {
      const n = notes().find((x) => x.number === number)
      const b = n && st.bookings.find((x) => x.id === n.bookingId)
      if (!n || !b || n.refundFrom === undefined) return []
      return b.payments.filter((p) => p.kind === 'refunded' && p.firstSlice === n.refundFrom).map((p) => refundOf(b, p))
    },

    async etaProfile() {
      return etaOf().profile ?? { issuerId: '', activityCode: '', branchId: '', country: '', governate: '', regionCity: '', street: '', buildingNumber: '' }
    },

    async setEtaProfile(p) {
      await wait(250)
      const alnum = (x: string, max: number) => /^[0-9A-Za-z]+$/.test(x) && x.length <= max
      if (!alnum(p.issuerId, 32)) refuse('invalid', 'The registration number is 1 to 32 letters and digits.', 'رقم التسجيل من حرف إلى 32 حرفاً ورقماً.')
      if (!/^[0-9]{4}$/.test(p.activityCode)) refuse('invalid', 'The activity code is the four digits the authority registered.', 'رمز النشاط هو الأرقام الأربعة المسجلة لدى المصلحة.')
      if (!alnum(p.branchId, 8)) refuse('invalid', 'The branch is the code the authority registered (0 for the main one).', 'الفرع هو الرمز المسجل لدى المصلحة (0 للرئيسي).')
      if (!/^[A-Z]{2}$/.test(p.country)) refuse('invalid', 'The country is its two-letter code, such as EG.', 'الدولة برمزها من حرفين، مثل EG.')
      for (const x of [p.governate, p.regionCity, p.street, p.buildingNumber]) {
        const n = new TextEncoder().encode(x).length
        if (n === 0) refuse('invalid', 'The address needs its governorate, city, street and building number.', 'يحتاج العنوان إلى المحافظة والمدينة والشارع ورقم المبنى.')
        if (n > 200) refuse('tooLong', 'An address field is at most 200 bytes.', 'حقل العنوان 200 بايت على الأكثر.')
      }
      etaOf().profile = { ...p }
      bump()
    },

    async taxEta() {
      const e = etaOf()
      return setup().taxes.map((x) => ({ taxRuleId: x.id, taxType: e.taxes[x.id]?.taxType ?? '', subType: e.taxes[x.id]?.subType ?? '' }))
    },

    async setTaxEta(taxRuleId, taxType, subType) {
      await wait(200)
      if (!setup().taxes.some((x) => x.id === taxRuleId)) refuse('noSuchTaxRule', `There is no tax rule ${taxRuleId}.`, `لا توجد الضريبة ${taxRuleId}.`)
      const code = (x: string) => /^[0-9A-Za-z]{1,8}$/.test(x)
      if (!code(taxType) || !code(subType)) refuse('invalid', "A tax type and its sub-type are 1 to 8 letters and digits, as the authority's tables write them.",
        'نوع الضريبة ونوعها الفرعي من حرف إلى 8 أحرف وأرقام كما تكتبها جداول المصلحة.')
      etaOf().taxes[taxRuleId] = { taxType, subType }
      bump()
    },

    async proposals() {
      return proposals.map(({ maker, credit: _c, desk: _d, ...p }) => ({ ...p, mine: maker === deskUser }))
    },

    async propose(dual: DualAct, bookingId, amount, text, justification) {
      await wait(300)
      if (!justification.trim()) refuse('invalid', 'Say why, for the person who will approve it.', 'اذكر السبب لمن سيوافق عليه.')
      const b = st.bookings.find((x) => x.id === bookingId)
      if (!b) refuse('noSuchBooking', 'There is no such booking.', 'لا يوجد هذا الحجز.')
      if (dual === 'voidCharge') {
        const l = b.lines.find((x) => x.id === Number(amount))
        if (!l?.charge) refuse('noSuchCharge', 'That line is not an extra on this booking.', 'هذا السطر ليس خدمة إضافية في الحجز.')
        if (l.charge.voidLine) refuse('invalid', 'This charge is already voided.', 'أُلغيت هذه الرسوم بالفعل.')
        if (invoiced(b, winOfLine(l))) refuseInvoiced(winOfLine(l))
      }
      return queue(b, dual, amount, text)
    },

    async approve(id) {
      await wait(350)
      const i = proposals.findIndex((x) => x.id === id)
      if (i < 0) refuse('noSuchProposal', 'There is no such proposal.', 'لا يوجد هذا الاقتراح.')
      const p = proposals[i]
      if (p.maker === deskUser) refuse('fourEyes', 'Someone else has to approve this.', 'يجب أن يوافق عليه شخص آخر.')
      const b = st.bookings.find((x) => x.id === p.bookingId)!
      if (p.act === 'issueCreditNote' && p.credit) {
        // checked whole again, as the contract checks at the approval
        const { inv, items, net, taxes } = checkNote(b, p.credit.invoice, p.credit.lineIds, p.credit.amounts)
        const total = net + taxes
        const window = inv.payerId
        // the bill's card refunds what the bill is then paid beyond what it owes
        const w = windowsOf(b).find((x) => x.payerId === window)!
        const owesAfter = w.charges - w.credits - total
        const refund = w.paid > owesAfter ? w.paid - (owesAfter > 0n ? owesAfter : 0n) : 0n
        // the guest's refund split across the guest's cards; another payer's back on that payer's own card
        const card = b.payments.filter((x) => winOfPay(x) === window && x.kind === 'captured' && x.state === 'done').at(-1)?.gatewayAuth ?? 0
        const a = st.gateway.find((x) => x.id === card)
        const made = !!a && !a.refusesRefunds && a.refunded + refund <= a.captured
        const pays: Omit<DemoPayment, 'id' | 'block'>[] = window === 0 ? guestSlices(b, refund)
          : refund > 0n ? [{ kind: 'refunded', state: made ? 'done' : 'failed', amount: refund, gatewayAuth: card, attempts: made ? 1 : 3, payerId: window }] : []
        if (refund > 0n) { b.paid -= refund; st.refundsCommitted = (BigInt(st.refundsCommitted) + refund).toString(); if (window !== 0 && made) a!.refunded += refund }
        b.credited += total
        b.outstanding = b.charged - b.credited - b.paid
        const first = b.lines.length + 1
        proposals.splice(i, 1)
        notes().push({ number: notes().length + 1, invoice: inv.number, bookingId: b.id, payerId: window, issuedDay: st.businessDate, net, taxes, total,
          items: items.map((x, k) => ({ lineId: first + k, ...x })), maker: p.maker, checker: deskUser,
          ...(window === 0 && pays.length > 0 ? { refundFrom: b.payments.length + 1 } : {}) })
        act(b, 'approve', items.map((x) => ({ kind: 'credit' as const, night: st.businessDate, amount: x.amount, payerId: window || undefined, code: CREDIT_NOTE_CODE })), pays)
        return
      }
      if (p.act === 'refundAtDesk' && p.desk) {
        checkDesk(b, p.desk.paymentId, p.desk.reference)
        proposals.splice(i, 1)
        desks().push({ bookingId: b.id, paymentId: p.desk.paymentId, method: p.desk.method, reference: p.desk.reference, day: st.businessDate, maker: p.maker, checker: deskUser })
        act(b, 'approve')
        return
      }
      if (p.act === 'voidCharge') {
        // the charge and its taxes credited on the charge's own bill; that bill refunded if it was paid for more than it now owes
        const l = b.lines.find((x) => x.id === Number(p.amount))
        if (!l?.charge || l.charge.voidLine) refuse('invalid', 'This charge is already voided.', 'أُلغيت هذه الرسوم بالفعل.')
        const window = winOfLine(l)
        if (invoiced(b, window)) refuseInvoiced(window)
        let amount = l.amount
        for (let i = l.id + 1; i <= l.id + l.charge.taxLines; i++) amount += b.lines.find((x) => x.id === i)!.amount
        // the bill as it was, less the credit: what it would owe, and so what it has paid over that
        const w = windowsOf(b).find((x) => x.payerId === window)!
        const owesAfter = w.charges - w.credits - amount
        const refund = w.paid > owesAfter ? w.paid - (owesAfter > 0n ? owesAfter : 0n) : 0n
        proposals.splice(i, 1)
        l.charge.voidLine = b.lines.length + 1
        b.credited += amount
        if (refund > 0n) { b.paid -= refund; st.refundsCommitted = (BigInt(st.refundsCommitted) + refund).toString() }
        b.outstanding = b.charged - b.credited - b.paid
        act(b, 'approve', [{ kind: 'credit', night: st.businessDate, amount, payerId: window || undefined, code: 1 }],
          window === 0 ? guestSlices(b, refund)
            : refund > 0n ? [{ kind: 'refunded', state: 'done', amount: refund, gatewayAuth: b.payments.filter((x) => winOfPay(x) === window && x.kind === 'captured').at(-1)?.gatewayAuth ?? 0, attempts: 1, payerId: window }] : [])
        return
      }
      const liability = b.charged - b.credited
      const credit = p.act === 'refundOutsidePolicy' ? p.amount : p.act === 'priceOverride' ? liability - p.amount
        : p.act === 'editGuestRecord' ? 0n : liability
      if (p.act === 'editGuestRecord') b.guestName = p.text
      if (p.act === 'staffCancel') {
        b.status = 'cancelled'
        mailHook(b, 'cancelled')
        for (let d = b.arrival; d < b.departure; d++) { const n = night(b.roomTypeId, d); if (n) n.sold = Math.max(0, n.sold - b.rooms) }
      giveBack(b, b.arrival, b.departure)
      }
      let back = 0n
      if (credit > 0n) {
        b.credited += credit
        const owed = b.charged - b.credited
        if (b.paid > owed) { back = b.paid - owed; b.paid = owed; st.refundsCommitted = (BigInt(st.refundsCommitted) + back).toString() }
        b.outstanding = b.charged - b.credited - b.paid
      }
      proposals.splice(i, 1)
      act(b, 'approve', credit > 0n ? [{ kind: 'credit', night: b.arrival, amount: credit }] : [], guestSlices(b, back))
    },

    async reject(id, reason) {
      await wait(250)
      if (!reason.trim()) refuse('invalid', 'Say why it is rejected.', 'اذكر سبب الرفض.')
      const i = proposals.findIndex((x) => x.id === id)
      if (i >= 0) proposals.splice(i, 1)
    },

    // the demo has no passkeys, so it has no guest accounts; the chain source has both
    async identity() { return 'demo' as const },
    async openSession() {},
    async myStays(): Promise<BookingView[]> { return [] },
    async myWaitlist(): Promise<WaitView[]> { return [] },
    async joinWaitlist(): Promise<number> { refuse('notAuthorised', 'Accounts need passkeys, which the demo does not have.', 'تحتاج الحسابات إلى مفاتيح مرور، وهي غير متاحة في العرض التجريبي.') },
    async leaveWaitlist() {},

    async bookings(beforeId, limit) {
      await wait(150)
      const all = [...st.bookings].sort((a, b) => b.id - a.id).filter((b) => beforeId === 0 || b.id < beforeId)
      const rows = all.slice(0, limit).map(view)
      return { rows, next: all.length > limit ? rows[rows.length - 1].id : null }
    },

    async bookingsFiltered(q: BookingQuery, cursor: string, limit: number) {
      await wait(150)
      // arrival order, then id, as the contract's arrival index reads; the cursor is the last id returned
      const all = st.bookings
        .filter((b) => b.arrival >= q.from && b.arrival <= q.to && (q.status === '' || b.status === q.status))
        .sort((a, b) => a.arrival - b.arrival || a.id - b.id)
      const start = cursor ? all.findIndex((b) => String(b.id) === cursor) + 1 : 0
      const rows = all.slice(start, start + limit)
      return { rows: rows.map(view), next: start + limit < all.length ? String(rows[rows.length - 1].id) : null }
    },

    async bookingByRef(ref: string) {
      await wait(100)
      const b = st.bookings.find((x) => x.ref === ref.trim().toUpperCase())
      return b ? view(b) : null
    },

    async folio(bookingId: number): Promise<FolioLineView[]> { return st.bookings.find((x) => x.id === bookingId)?.lines ?? [] },
    async payments(bookingId: number): Promise<PaymentView[]> { return st.bookings.find((x) => x.id === bookingId)?.payments ?? [] },
    async history(bookingId: number, beforeBlock: number): Promise<{ acts: HistoryAct[]; more: number | null }> {
      const events = st.bookings.find((x) => x.id === bookingId)?.events ?? []
      return { acts: events.filter((e) => beforeBlock === 0 || e.block < beforeBlock), more: null }
    },

    async arrivals(day): Promise<DeskRow[]> {
      await wait(150)
      return st.bookings.filter((b) => b.status === 'confirmed' && b.arrival === day).map((b) => ({ booking: view(b), roomNumbers: [] }))
    },

    async inHouse(): Promise<DeskRow[]> {
      await wait(150)
      return st.bookings.filter((b) => b.status === 'checkedIn')
        .map((b) => ({ booking: view(b), roomNumbers: st.rooms.filter((r) => r.occupiedBy === b.id).map((r) => r.number) }))
    },

    async vacantRooms(rt): Promise<VacantRoom[]> {
      return st.rooms.filter((r) => r.roomTypeId === rt && r.occupiedBy === 0 && !r.out)
        .sort((a, b) => readiness(a) - readiness(b) || a.id - b.id)
        .map((r) => ({ id: r.id, number: r.number, cleaning: r.cleaning ?? '' }))
    },

    async housekeeping(): Promise<BoardRoom[]> {
      await wait(150)
      return st.rooms.map((r) => {
        const b = r.occupiedBy ? st.bookings.find((x) => x.id === r.occupiedBy) : undefined
        return { id: r.id, number: r.number, roomTypeId: r.roomTypeId, outOfOrder: !!r.out, cleaning: r.cleaning ?? '', cleanedBy: r.cleanedBy ?? '',
          inspectedBy: r.inspectedBy ?? '', cleanedByMe: r.cleanedBy === deskUser, inspectedByMe: r.inspectedBy === deskUser, outReason: r.out?.reason ?? '', outFrom: r.out?.from ?? null,
          outUntil: r.out?.until || null, changedDay: r.changedDay ?? null, occupiedBy: r.occupiedBy, departure: b ? b.departure : null }
      })
    },

    async markRoom(roomId, cleaning) {
      await wait(250)
      const r = roomOf(roomId)
      if (r.out) refuse('invalid', `Room ${r.number} is out of order; put it back in service first.`, `الغرفة ${r.number} خارج الخدمة؛ أعِدها إلى الخدمة أولاً.`)
      if (r.cleaning === cleaning) refuse('invalid', `Room ${r.number} is already ${cleaning}.`, `الغرفة ${r.number} ${cleaningAr[cleaning]} بالفعل.`)
      if (cleaning === 'inspected') {
        if (r.cleaning !== 'clean') refuse('invalid', `Only a clean room is inspected; room ${r.number} is ${r.cleaning ?? 'not recorded'}.`,
          `لا تُعايَن إلا الغرفة النظيفة؛ الغرفة ${r.number} ${cleaningAr[r.cleaning ?? '']}.`)
        if (r.cleanedBy === deskUser) refuse('invalid', 'A room is inspected by someone other than the person who cleaned it.', 'يعاين الغرفةَ شخصٌ غير الذي نظّفها.')
        r.inspectedBy = deskUser
      } else if (cleaning === 'clean') { r.cleanedBy = deskUser; r.inspectedBy = undefined }
      else { r.cleanedBy = undefined; r.inspectedBy = undefined }
      r.cleaning = cleaning
      r.changedDay = st.businessDate
      bump()
    },

    async takeRoomOutOfOrder(roomId, reason, untilDay) {
      await wait(300)
      const r = roomOf(roomId)
      if (r.occupiedBy) refuse('roomNotVacant', `Room ${r.number} is occupied.`, `الغرفة ${r.number} مشغولة.`)
      const bytes = new TextEncoder().encode(reason).length
      if (bytes === 0) refuse('invalid', 'Say why the room is out of order.', 'اذكر سبب خروج الغرفة من الخدمة.')
      if (bytes > 160) refuse('tooLong', 'The reason is at most 160 bytes.', 'السبب 160 بايت على الأكثر.')
      if (untilDay <= st.businessDate) refuse('invalid', 'A room out of order is back on a day after today.', 'تعود الغرفة الخارجة من الخدمة في يوم بعد اليوم.')
      if (untilDay > st.businessDate + prop().horizonDays) refuse('beyondHorizon', 'That day is past the hotel\'s horizon.', 'هذا اليوم أبعد من أفق الفندق.')
      if (r.out && r.out.reason === reason && r.out.until === untilDay) refuse('invalid', `Room ${r.number} is already out of order until that day, for that reason.`, `الغرفة ${r.number} خارج الخدمة حتى ذلك اليوم ولهذا السبب بالفعل.`)
      for (let d = st.businessDate; d < untilDay; d++) {
        const n = night(r.roomTypeId, d)
        if (!n || !countsOn(r, d)) continue
        const left = roomsOn(r.roomTypeId, d) - 1
        if (n.allotment > left) refuse('allotmentAboveRooms', `On ${fmt(d)} the allotment of ${n.allotment} is more than the ${left} rooms left; lower it first.`,
          `في ${fmt(d, 'ar')} المخصّص ${n.allotment} أكثر من الغرف المتبقية ${left}؛ اخفضه أولاً.`)
      }
      r.out = { reason, from: r.out?.from ?? st.businessDate, until: untilDay }
      r.cleaning = 'dirty'; r.cleanedBy = undefined; r.inspectedBy = undefined; r.changedDay = st.businessDate
      bump()
    },

    async returnRoomToService(roomId) {
      await wait(250)
      const r = roomOf(roomId)
      if (!r.out) refuse('invalid', `Room ${r.number} is in service.`, `الغرفة ${r.number} في الخدمة.`)
      r.out = undefined
      r.cleaning = 'dirty'; r.cleanedBy = undefined; r.inspectedBy = undefined; r.changedDay = st.businessDate
      bump()
    },

    async checkIn(bookingId, roomIds) {
      await wait(300)
      const b = st.bookings.find((x) => x.id === bookingId)
      if (!b || b.status !== 'confirmed') refuse('bookingState', 'This booking is not waiting to check in.', 'هذا الحجز لا ينتظر تسجيل الوصول.')
      if (b.arrival !== st.businessDate) refuse('notTheDay', 'This guest arrives on another day.', 'يصل هذا الضيف في يوم آخر.')
      if (roomIds.length !== b.rooms) refuse('invalid', `Choose ${b.rooms} room(s).`, `اختر ${b.rooms} غرفة.`)
      for (const id of roomIds) {
        const r = st.rooms.find((x) => x.id === id)
        if (!r || r.occupiedBy !== 0 || r.out || r.roomTypeId !== b.roomTypeId) refuse('roomNotVacant', 'That room is not free.', 'هذه الغرفة غير متاحة.')
      }
      for (const id of roomIds) st.rooms.find((x) => x.id === id)!.occupiedBy = b.id
      b.status = 'checkedIn'
      mailHook(b, 'arrivedOrNot')
      const k = cards()[b.id]
      if (k?.state === 'wanted') k.state = 'closed'
      act(b, 'checkIn')
    },

    async moveRoom(bookingId, fromRoomId, toRoomId) {
      await wait(300)
      const b = st.bookings.find((x) => x.id === bookingId)
      if (!b) refuse('noSuchBooking', 'There is no such booking.', 'لا يوجد هذا الحجز.')
      if (b.status !== 'checkedIn') refuse('bookingState', 'This guest is not in house.', 'هذا الضيف ليس مقيماً.')
      const from = st.rooms.find((x) => x.id === fromRoomId)
      if (!from) refuse('noSuchRoom', 'There is no such room.', 'لا توجد هذه الغرفة.')
      if (from.occupiedBy !== b.id) refuse('invalid', `This guest is not in room ${from.number}.`, `هذا الضيف ليس في الغرفة ${from.number}.`)
      if (fromRoomId === toRoomId) refuse('invalid', 'The guest is already in that room.', 'الضيف في هذه الغرفة بالفعل.')
      const to = st.rooms.find((x) => x.id === toRoomId)
      if (!to) refuse('noSuchRoom', 'There is no such room.', 'لا توجد هذه الغرفة.')
      if (to.roomTypeId !== b.roomTypeId) refuse('roomWrongType', 'That room is of another type.', 'هذه الغرفة من نوع آخر.')
      if (to.occupiedBy !== 0 || to.out) refuse('roomNotVacant', 'That room is not free.', 'هذه الغرفة غير متاحة.')
      Object.assign(from, { occupiedBy: 0, cleaning: 'dirty', cleanedBy: undefined, inspectedBy: undefined, changedDay: st.businessDate })
      to.occupiedBy = b.id
      act(b, 'moveRoom')
    },

    // rate products, as RateProducts.mo checks them: a code is capitals, digits and dashes, one company's
    // alone; a company has a name; a plan named for a company is closed to it
    async companies() { return (st.companies ?? []).map((c) => ({ ...c })) },

    async upsertCompany(id, c) {
      await wait(200)
      const list = (st.companies ??= [])
      if (!/^[A-Z0-9-]{1,16}$/.test(c.code)) refuse('invalid', 'A code is capital letters, digits and dashes, at most 16.', 'الرمز حروف كبيرة وأرقام وشرطات، 16 على الأكثر.')
      if (id !== 0 && !list.some((x) => x.id === id)) refuse('invalid', `There is no company ${id}.`, `لا توجد شركة ${id}.`)
      const target = id || list.length + 1
      const other = list.find((x) => x.code === c.code)
      if (other && other.id !== target) refuse('codeTaken', `The code ${c.code} is already used by ${other.id}.`, 'هذا الرمز أو الرقم مستخدم بالفعل.')
      const promo = (st.promos ?? []).find((x) => x.code === c.code)
      if (promo) refuse('codeTaken', `The code ${c.code} is already used by ${promo.id}.`, 'هذا الرمز أو الرقم مستخدم بالفعل.')
      const bytes = new TextEncoder().encode(c.name.trim()).length
      if (bytes === 0) refuse('invalid', 'A company needs a name.', 'الشركة تحتاج اسماً.')
      if (bytes > 120) refuse('tooLong', 'The company name is longer than 120 bytes.', 'اسم الشركة أطول من المسموح.')
      const row = { id: target, code: c.code, name: c.name.trim(), active: c.active }
      if (id) list[list.findIndex((x) => x.id === id)] = row; else list.push(row)
      bump()
      return target
    },

    async planAccess() { return (st.access ?? []).map((a) => ({ ...a })) },

    // promotions, as RateProducts.upsertPromo checks them: a code no company or other promotion has, a plan
    // that exists and is kept on a change, windows in order and within 550 days, a limit not below the uses
    async promos() { return (st.promos ?? []).map((p) => ({ ...p })) },

    async upsertPromo(id, f) {
      await wait(200)
      const list = (st.promos ??= [])
      if (!/^[A-Z0-9-]{1,16}$/.test(f.code)) refuse('invalid', 'A code is capital letters, digits and dashes, at most 16.', 'الرمز حروف كبيرة وأرقام وشرطات، 16 على الأكثر.')
      if (id === 0 && list.length >= 500) refuse('invalid', 'A hotel has at most 500 promotions.', 'للفندق 500 عرض على الأكثر.')
      const was = id ? list.find((x) => x.id === id) : undefined
      if (id !== 0 && !was) refuse('invalid', `There is no promotion ${id}.`, `لا يوجد عرض ${id}.`)
      const target = id || list.length + 1
      const other = list.find((x) => x.code === f.code)
      if (other && other.id !== target) refuse('codeTaken', `The code ${f.code} is already used by ${other.id}.`, 'هذا الرمز أو الرقم مستخدم بالفعل.')
      const company = (st.companies ?? []).find((x) => x.code === f.code)
      if (company) refuse('codeTaken', `The code ${f.code} is already used by ${company.id}.`, 'هذا الرمز أو الرقم مستخدم بالفعل.')
      if (!setup().plans.some((p) => p.id === f.planId)) refuse('noSuchPlan', `There is no rate plan ${f.planId}.`, `لا توجد خطة سعر ${f.planId}.`)
      if (was && was.planId !== f.planId) refuse('invalid', 'A promotion keeps its plan; add a new promotion for another.', 'يبقى العرض على خطته؛ أضف عرضاً جديداً لخطة أخرى.')
      if (f.bookFrom > f.bookUntil) refuse('invalid', 'The booking window ends before it begins.', 'تنتهي مدة الحجز قبل أن تبدأ.')
      if (f.stayFrom > f.stayUntil) refuse('invalid', 'The stay window ends before it begins.', 'تنتهي مدة الإقامة قبل أن تبدأ.')
      if (f.bookUntil > st.businessDate + 550 || f.stayUntil > st.businessDate + 550) refuse('invalid', "A promotion's windows end within 550 days.", 'تنتهي مدد العرض خلال 550 يوماً.')
      if (f.maxUses > 1_000_000) refuse('invalid', 'A promotion is used at most 1000000 times; 0 is no limit.', 'يُستخدم العرض مليون مرة على الأكثر؛ 0 بلا حد.')
      const used = was?.used ?? 0
      if (f.maxUses !== 0 && f.maxUses < used) refuse('invalid', `The promotion has been used ${used} times already.`, `استُخدم العرض ${used} مرة بالفعل.`)
      const bytes = new TextEncoder().encode(f.name.trim()).length
      if (bytes === 0) refuse('invalid', 'A promotion needs a name the guest is shown.', 'العرض يحتاج اسماً يراه الضيف.')
      if (bytes > 120) refuse('tooLong', 'The promotion name is longer than 120 bytes.', 'اسم العرض أطول من المسموح.')
      const row: PromoView = { ...f, name: f.name.trim(), id: target, used }
      if (was) list[list.indexOf(was)] = row; else list.push(row)
      bump()
      return target
    },

    async blocks() {
      await wait(150)
      return blocks().map(blockView)
    },

    async upsertBlock(id, f) {
      await wait(250)
      const list = blocks()
      if (id === 0 && list.length >= 500) refuse('invalid', 'A hotel has at most 500 group blocks.', 'للفندق 500 مجموعة على الأكثر.')
      const was = id ? list.find((x) => x.id === id) ?? refuse('noSuchBlock', `There is no group block ${id}.`, 'لا توجد هذه المجموعة المحجوزة.') : undefined
      const room = typeOf(f.roomTypeId)
      if (!room || !room.active) refuse('noSuchRoomType', 'That room type does not exist.', 'نوع الغرفة هذا غير موجود.')
      if (!activePlans().some((p) => p.id === f.planId)) refuse('noSuchPlan', 'That rate does not exist.', 'هذا السعر غير موجود.')
      if (f.companyId !== 0 && !(st.companies ?? []).some((c) => c.id === f.companyId)) refuse('invalid', `There is no company ${f.companyId}.`, `لا توجد شركة ${f.companyId}.`)
      const a = accessOf(f.planId)
      if (a?.closed && (a.companyId === 0 || a.companyId !== f.companyId)) refuse('closedRate', 'That rate is sold only under its own code.', 'هذا السعر متاح فقط برمز شركته أو برمز العرض الخاص به.')
      if (f.nights < 1 || f.nights > 31) refuse('stayLength', 'A block is 1 to 31 nights.', 'المجموعة من ليلة إلى 31 ليلة.')
      if (f.rooms < 1) refuse('invalid', 'A block holds at least one room.', 'المجموعة غرفة واحدة على الأقل.')
      const departure = f.arrival + f.nights
      if (was) {
        if (!was.open) refuse('blockReleased', `Group block ${id} has been released; its rooms are back on sale.`, 'أُفرج عن غرف هذه المجموعة وعادت للبيع.')
        if (was.roomTypeId !== f.roomTypeId || was.planId !== f.planId || was.companyId !== f.companyId || was.arrival !== f.arrival || was.departure !== departure)
          refuse('invalid', 'A block keeps its room type, plan, company and dates; release it and add a new one.', 'تبقى المجموعة على نوع غرفتها وسعرها وشركتها وتواريخها؛ أفرج عنها وأضف مجموعة جديدة.')
      } else {
        if (f.arrival < st.businessDate) refuse('inThePast', 'That date has passed.', 'هذا التاريخ مضى.')
        if (departure > st.businessDate + prop().horizonDays) refuse('beyondHorizon', `We take bookings up to ${prop().horizonDays} days ahead.`, `نستقبل الحجوزات حتى ${prop().horizonDays} يوماً مقدّماً.`)
      }
      if (f.cutoff < st.businessDate) refuse('inThePast', 'The cut-off has passed.', 'مضى موعد الإفراج.')
      if (f.cutoff > f.arrival) refuse('invalid', "The cut-off is on or before the group's arrival.", 'موعد الإفراج في يوم وصول المجموعة أو قبله.')
      const bytes = new TextEncoder().encode(f.name.trim()).length
      if (bytes === 0) refuse('invalid', "A block needs the group's name.", 'المجموعة تحتاج اسماً.')
      if (bytes > 120) refuse('tooLong', 'The group name is longer than 120 bytes.', 'اسم المجموعة أطول من المسموح.')
      const had = was?.rooms ?? 0
      for (let d = f.arrival; d < departure; d++) {
        const n = night(f.roomTypeId, d)
        if (!n) refuse('nightClosed', `Closed on ${fmt(d)}.`, `مغلقة في ${fmt(d, 'ar')}.`)
        const picked = was?.picked[d] ?? 0
        if (f.rooms < picked) refuse('invalid', `${picked} room(s) are already picked up from the block on ${fmt(d)}.`, `حُجزت ${picked} غرفة من المجموعة بالفعل في ${fmt(d, 'ar')}.`)
        if (f.rooms > had && freeAt(f.roomTypeId, d, n) < f.rooms - had) refuse('soldOut', `Sold out on ${fmt(d)}.`, `محجوزة بالكامل في ${fmt(d, 'ar')}.`)
      }
      const row: DemoBlock = { id: was?.id ?? list.length + 1, name: f.name.trim(), companyId: f.companyId, roomTypeId: f.roomTypeId, planId: f.planId,
        arrival: f.arrival, departure, rooms: f.rooms, cutoff: f.cutoff, open: true, picked: was?.picked ?? {} }
      if (was) list[list.indexOf(was)] = row; else list.push(row)
      bump()
      return row.id
    },

    async releaseBlock(id) {
      await wait(200)
      const k = blockOf(id)
      if (!k.open) refuse('blockReleased', `Group block ${id} has been released; its rooms are back on sale.`, 'أُفرج عن غرف هذه المجموعة وعادت للبيع.')
      k.open = false
      bump()
    },

    async blockNights(id) {
      await wait(100)
      const k = blocks().find((x) => x.id === id)
      if (!k) return []
      const out = []
      for (let d = k.arrival; d < k.departure; d++) out.push({ day: d, picked: k.picked[d] ?? 0, held: heldBy(k, d) })
      return out
    },

    async roomingList(id): Promise<RoomingRow[]> {
      await wait(100)
      return st.bookings.filter((b) => st.pickups?.[b.id] === id)
        .map((b) => ({ id: b.id, ref: b.ref, status: b.status, arrival: b.arrival, departure: b.departure, rooms: b.rooms, guestName: b.guestName, outstanding: b.outstanding }))
    },

    async blockQuote(id, req): Promise<Offer> {
      await wait(150)
      const k = blockOf(id)
      checkPickup(k, req)
      const grant: Grant = { companyId: k.companyId, promoId: 0 }
      admit(k.planId, grant, { arrival: req.arrival, nights: req.nights, counts: true })
      const q = check(k.roomTypeId, k.planId, req, true)
      const plan = planView(setup().plans.find((p) => p.id === k.planId)!)
      let left = Infinity
      for (let d = req.arrival; d < req.arrival + req.nights; d++) left = Math.min(left, heldBy(k, d))
      return { roomTypeId: k.roomTypeId, planId: k.planId, total: q.total, roomSubtotal: q.roomSubtotal, taxTotal: q.taxTotal, perNightAvg: q.total / BigInt(req.nights * req.rooms),
        left, cancelDeadline: plan.refundable ? req.arrival - plan.freeCancelDaysBefore : null,
        guarantee: guaranteeFor(plan, q), quoteHash: await quoteHash(k.roomTypeId, k.planId, q), packageTotal: q.packageTotal }
    },

    // a pickup is a booking taken by staff from the group's list: its rooms move from the block to sold
    async pickUp(blockId, offer, req, guest): Promise<StaffBookResult> {
      await wait(400)
      const k = blockOf(blockId)
      checkPickup(k, req)
      const grant: Grant = { companyId: k.companyId, promoId: 0 }
      admit(k.planId, grant, { arrival: req.arrival, nights: req.nights, counts: true })
      const q = check(k.roomTypeId, k.planId, req, true)
      if ((await quoteHash(k.roomTypeId, k.planId, q)) !== offer.quoteHash) refuse('priceChanged', 'The price has just changed. Please check the new total.', 'تغيّر السعر للتوّ. يُرجى مراجعة الإجمالي الجديد.')
      if (!guest.name.trim()) refuse('invalid', "The guest's name is required.", 'اسم الضيف مطلوب.')
      for (let d = req.arrival; d < req.arrival + req.nights; d++) { night(k.roomTypeId, d).sold += req.rooms; k.picked[d] = (k.picked[d] ?? 0) + req.rooms }
      const plan = planView(setup().plans.find((p) => p.id === k.planId)!)
      const secret = [...crypto.getRandomValues(new Uint8Array(16))].map((x) => x.toString(16).padStart(2, '0')).join('')
      const id = st.nextBooking++
      const b: Booking = {
        id, ref: refFor(id), status: 'confirmed', roomTypeId: k.roomTypeId, planId: k.planId,
        arrival: req.arrival, departure: req.arrival + req.nights, rooms: req.rooms, adults: req.adults, children: req.children, guestName: guest.name.trim(),
        charged: q.total, credited: 0n, paid: 0n, outstanding: q.total,
        penalty: plan.refundable ? firstNights(q, Math.max(1, plan.penaltyNights)) : q.total - q.packageTotal,
        cancelDeadline: plan.refundable ? req.arrival - plan.freeCancelDaysBefore : null, refundable: plan.refundable,
        block: 0, secretHash: await sha(secret), authId: 0, authAmount: 0n, lines: [], payments: [], events: [],
      }
      st.bookings.push(b)
      ;(st.staffBookings ??= {})[id] = { channel: 'group', madeBy: DEMO_ME, day: st.businessDate }
      ;(st.pickups ??= {})[id] = k.id
      act(b, 'pickUpFromBlock', quoteLines(q))
      return { booking: view(b), manageSecret: secret, mail: mailAttach(b, guest.email, guest.lang ?? 'en') }
    },

    async setPlanAccess(planId, companyId, closed) {
      await wait(200)
      if (!setup().plans.some((p) => p.id === planId)) refuse('noSuchPlan', `There is no rate plan ${planId}.`, `لا توجد خطة سعر ${planId}.`)
      if (companyId !== 0 && !(st.companies ?? []).some((c) => c.id === companyId)) refuse('invalid', `There is no company ${companyId}.`, `لا توجد شركة ${companyId}.`)
      if (companyId !== 0 && !closed) refuse('invalid', 'A plan named for a company is closed to it; open it to everyone with no company.', 'الخطة المسماة لشركة مغلقة عليها.')
      const list = (st.access ??= [])
      const row = { planId, companyId, closed }
      const i = list.findIndex((a) => a.planId === planId)
      if (i >= 0) list[i] = row; else list.push(row)
      bump()
    },

    async extras() { return st.extras.map((e) => ({ ...e })) },

    async upsertExtra(id, e) {
      await wait(300)
      if (!e.code.trim()) refuse('invalid', 'An extra needs a code.', 'يحتاج البند إلى رمز.')
      if (!e.name.en.trim()) refuse('invalid', 'An extra needs a name.', 'يحتاج البند إلى اسم.')
      const other = st.extras.find((x) => x.code === e.code && x.id !== id)
      if (other) refuse('codeTaken', `The code ${e.code} is already used.`, `الرمز ${e.code} مستخدم بالفعل.`)
      if (id === 0) { const n = st.extras.length + 1; st.extras.push({ ...e, id: n }); bump(); return n }
      const i = st.extras.findIndex((x) => x.id === id)
      if (i < 0) refuse('noSuchExtra', 'There is no such extra.', 'لا يوجد هذا البند.')
      st.extras[i] = { ...e, id }
      bump()
      return id
    },

    // ── setup: the contract's checks (src/Setup.mo), on the demo's own records ──

    async setupProperty() { return { ...prop(), name: { ...prop().name } } },

    async configureProperty(p) {
      await wait(300)
      if (!/^[A-Z]{3}$/.test(p.currency)) refuse('invalid', 'A currency code is three capital letters.', 'رمز العملة ثلاثة أحرف لاتينية كبيرة.')
      if (p.minorUnits > 3) refuse('invalid', 'A currency has at most three minor units.', 'للعملة ثلاث خانات عشرية على الأكثر.')
      if (p.holdTtlHeights < 1) refuse('invalid', 'A hold must last at least one block.', 'يدوم الحجز المؤقت كتلة واحدة على الأقل.')
      if (p.heightsPerRealMinute < 1) refuse('invalid', 'The clock ratio must be at least one block per minute.', 'نسبة الساعة كتلة واحدة في الدقيقة على الأقل.')
      if (p.maxStayNights < 1 || p.maxStayNights > 255) refuse('invalid', 'The longest stay is 1 to 255 nights.', 'أطول إقامة من ليلة إلى 255 ليلة.')
      if (p.horizonDays < 1 || p.horizonDays > 1095) refuse('invalid', 'Bookings open 1 to 1,095 days ahead.', 'تُفتح الحجوزات من يوم إلى 1,095 يوماً مقدّماً.')
      if (p.maxRoomsPerBooking < 1 || p.maxRoomsPerBooking > 9) refuse('invalid', 'One booking holds 1 to 9 rooms.', 'الحجز الواحد من غرفة إلى 9 غرف.')
      if (p.idRetentionDays < 1 || p.idRetentionDays > 3650) refuse('invalid', 'Identity documents are kept 1 to 3,650 days.', 'تُحفظ وثائق الهوية من يوم إلى 3,650 يوماً.')
      if (!p.name.en.trim()) refuse('invalid', 'The property needs a name.', 'يحتاج الفندق إلى اسم.')
      textsFit([p.name.en, p.name.ar, p.checkInText, p.checkOutText])
      setup().property = { ...p, name: { ...p.name } }
      bump()
    },

    async setupRoomTypes() { return setup().roomTypes.map((x) => ({ ...x, amenities: [...x.amenities], rooms: inService(x.id) })) },

    async upsertRoomType(id, x) {
      await wait(300)
      const all = setup().roomTypes
      codeFits(x.code)
      const target = id === 0 ? all.reduce((m, r) => Math.max(m, r.id), 0) + 1 : id
      if (id === 0 && target > 64) refuse('tooManyRoomTypes', 'A property can have at most 64 room types.', 'للفندق 64 نوعاً من الغرف على الأكثر.')
      if (id !== 0 && !typeOf(id)) refuse('noSuchRoomType', 'That room type does not exist.', 'نوع الغرفة هذا غير موجود.')
      const other = all.find((r) => r.code === x.code && r.id !== target)
      if (other) refuse('codeTaken', `The code ${x.code} is already used by ${other.id}.`, `الرمز ${x.code} مستخدم بالفعل.`)
      if (x.maxAdults < 1 || x.maxOccupancy < 1 || x.maxOccupancy > x.maxAdults + x.maxChildren || x.maxOccupancy > 255)
        refuse('invalid', 'A room sleeps at least one adult, and no more than its adults and children together.', 'تتّسع الغرفة لبالغ واحد على الأقل، ولا تتجاوز مجموع البالغين والأطفال.')
      if (x.bedCount < 1 || x.bedCount > 255 || x.sizeSqm > 65535 || x.rank > 255) refuse('invalid', "A room's beds, size, rank or amenities are out of range.", 'عدد الأسرّة أو المساحة أو الترتيب خارج النطاق.')
      textsFit([x.name.en, x.name.ar, x.desc.en, x.desc.ar, x.photos])
      const row = { ...x, id: target, name: { ...x.name }, desc: { ...x.desc }, amenities: [...x.amenities] }
      const i = all.findIndex((r) => r.id === target)
      if (i < 0) all.push(row); else all[i] = row
      bump()
      return target
    },

    async upsertRoom(id, roomTypeId, number, outOfOrder) {
      await wait(300)
      if (!typeOf(roomTypeId)) refuse('noSuchRoomType', 'That room type does not exist.', 'نوع الغرفة هذا غير موجود.')
      const n = new TextEncoder().encode(number).length
      if (n === 0 || n > 8) refuse('tooLong', 'A room number is 1 to 8 bytes.', 'رقم الغرفة من 1 إلى 8 بايت.')
      const target = id === 0 ? st.rooms.reduce((m, r) => Math.max(m, r.id), 0) + 1 : id
      const holder = st.rooms.find((r) => r.number === number && r.id !== target)
      if (holder) refuse('codeTaken', `The code ${number} is already used by ${holder.id}.`, `الرقم ${number} مستخدم بالفعل.`)
      const old = id === 0 ? undefined : roomOf(id)
      if (old && old.occupiedBy && (outOfOrder || old.roomTypeId !== roomTypeId)) refuse('roomNotVacant', `Room ${old.number} is occupied.`, `الغرفة ${old.number} مشغولة.`)
      // a room leaving its type's count (moved, or taken out of service) must not leave a night offering more rooms than are left
      if (old && (old.roomTypeId !== roomTypeId || (outOfOrder && !old.out))) {
        for (let d = st.businessDate; d < st.businessDate + prop().horizonDays; d++) {
          const nt = night(old.roomTypeId, d)
          if (!nt || !countsOn(old, d)) continue
          const left = Math.max(0, roomsOn(old.roomTypeId, d) - 1)
          if (nt.allotment > left) refuse('allotmentAboveRooms', `On ${fmt(d)} the allotment of ${nt.allotment} is more than the ${left} rooms left; lower it first.`,
            `في ${fmt(d, 'ar')} المخصّص ${nt.allotment} أكثر من الغرف المتبقية ${left}؛ اخفضه أولاً.`)
        }
      }
      if (!old) { st.rooms.push({ id: target, roomTypeId, number, occupiedBy: 0, ...(outOfOrder ? { out: { reason: '', from: st.businessDate, until: 0 } } : {}) }); bump(); return target }
      old.number = number
      old.roomTypeId = roomTypeId
      // out of order with dates keeps them through an edit that keeps it out; back in service drops them
      if (outOfOrder && !old.out) old.out = { reason: '', from: st.businessDate, until: 0 }
      if (!outOfOrder) old.out = undefined
      bump()
      return target
    },

    async setupPlans() {
      return setup().plans.map((p) => {
        const guarantee = guaranteeKind(p)
        return { ...p, name: { ...p.name }, guarantee, depositBps: guarantee === 'deposit' ? st.deposits?.[p.id] ?? 0 : 0 }
      })
    },

    async setPlanDeposit(planId, bps) {
      await wait(250)
      const p = setup().plans.find((x) => x.id === planId)
      if (!p) refuse('noSuchPlan', 'That rate does not exist.', 'هذا السعر غير موجود.')
      if (p.prepaid) refuse('invalid', 'A rate paid in advance takes no deposit.', 'السعر المدفوع مقدماً لا يأخذ عربوناً.')
      if (bps === 0 && guaranteeKind(p) !== 'deposit') refuse('invalid', 'The plan takes no deposit.', 'هذه الخطة لا تأخذ عربوناً.')
      if (bps !== 0 && (bps < 100 || bps > 9_900 || bps % 100 !== 0)) refuse('invalid', 'A deposit is a whole percentage, from 1% to 99%.', 'العربون نسبة مئوية صحيحة من 1% إلى 99%.')
      p.guarantee = bps === 0 ? 'firstNightAuthorised' : 'deposit'
      ;(st.deposits ??= {})[planId] = bps
      bump()
    },

    async cardRule() { await wait(60); return Boolean(st.cardRule) },

    async manageMail(ref, secret) {
      await wait(120)
      const b = st.bookings.find((x) => x.ref === ref)
      if (!b || b.secretHash !== (await sha(secret))) refuse('notFound', 'No booking matches this link.', 'لا يوجد حجز يطابق هذا الرابط.')
      return { rows: mailRows(b.id), connected: mail().connected }
    },

    async attachMailFromLink(ref, secret, email, lang) {
      await wait(300)
      const b = st.bookings.find((x) => x.ref === ref)
      if (!b || b.secretHash !== (await sha(secret))) refuse('notFound', 'No booking matches this link.', 'لا يوجد حجز يطابق هذا الرابط.')
      if (!/^[^\s@<>",;]+@[^\s@<>",;]+\.[^\s@<>",;]+$/.test(email.trim())) refuse('invalid', 'That is not an email address.', 'هذا ليس عنوان بريد إلكتروني.')
      const out = mailAttach(b, email, lang)
      if (out === 'notConnected') refuse('notConfigured', 'The hotel does not send emails yet.', 'لا يرسل الفندق رسائل بريد بعد.')
      if (out !== 'queued') refuse('invalid', 'This booking already has an address for its emails.', 'لهذا الحجز عنوان لرسائله بالفعل.')
    },

    async bookingMail(bookingId) { await wait(80); return mailRows(bookingId) },

    async mailSetup(): Promise<MailSetupView> {
      await wait(80)
      relayPass()
      const m = mail()
      const waiting = m.rows.filter((r) => r.state === 'due' && r.notBefore <= st.businessDate).length
      return { connected: m.connected, mailer: m.connected ? 'demo-relay' : '', authorised: m.authorised, tested: m.tested, on: m.on,
        waiting: Math.min(waiting, 99), more: waiting > 99, relay: 'demo' }
    },

    async connectMailRelay() {
      await wait(300)
      const m = mail()
      if (m.connected) refuse('invalid', 'The mail service is already connected.', 'خدمة البريد متصلة بالفعل.')
      m.connected = true; m.authorised = ''; m.tested = ''; m.on = false
      bump()
    },

    async mailProviders(): Promise<MailProviderView[]> {
      await wait(60)
      return DEMO_PROVIDERS
    },

    async saveMailAccount(account) {
      await wait(400)
      if (!mail().connected) refuse('relay', 'connect this relay to the hotel first (Guest email, step 1)', 'اربط خدمة البريد بالفندق أولاً (بريد الضيوف، الخطوة ١)')
      const p = DEMO_PROVIDERS.find((x) => x.name === account.provider)
      if (!p || p.oauth) refuse('relay', 'this provider connects by signing in, not by a key', 'هذا المزوّد يُربط بتسجيل الدخول لا بمفتاح')
      for (const f of p.fields) if (!['fromName', 'region', 'domain', 'security'].includes(f) && !(f === 'from' ? account.from : account.fields[f])?.trim())
        refuse('relay', `${f} is missing`, `الحقل ${f} ناقص`)
      const digest = await sha(JSON.stringify(account))
      mail().accounts[digest] = { provider: account.provider, from: account.from.trim() }
      save()
      return { digest, provider: account.provider, from: account.from.trim() }
    },

    async startMailSignIn(account) {
      // the demo has no Google or Microsoft: it returns as the relay's callback does, with the account kept
      await wait(400)
      if (!mail().connected) refuse('relay', 'connect this relay to the hotel first (Guest email, step 1)', 'اربط خدمة البريد بالفندق أولاً (بريد الضيوف، الخطوة ١)')
      const digest = await sha(JSON.stringify(account) + st.block)
      mail().accounts[digest] = { provider: account.provider, from: account.from.trim() }
      save()
      return `${location.origin}${location.pathname}#${new URLSearchParams({ mailCredential: digest, account: account.from.trim(), provider: account.provider })}`
    },

    async approveMailAccount(digest) {
      await wait(300)
      const m = mail()
      if (!m.connected) refuse('invalid', 'Connect the mail service first.', 'اربط خدمة البريد أولاً.')
      if (!/^[0-9a-f]{64}$/.test(digest) || m.authorised === digest) refuse('invalid', 'That account is already approved.', 'هذا الحساب معتمد بالفعل.')
      m.authorised = digest; m.tested = ''; m.on = false
      bump()
    },

    async mailAccountInUse() {
      await wait(80)
      const m = mail()
      const a = m.authorised ? m.accounts[m.authorised] : undefined
      return a ? { digest: m.authorised, onFile: true, provider: a.provider, from: a.from } : { digest: m.authorised, onFile: false }
    },

    async checkMailDomain(domain, provider, selector): Promise<DnsCheckView> {
      // the sample hotel's domain as a fresh one usually is: sending set up, no DMARC record yet
      await wait(500)
      if (!/^([a-z0-9-]+\.)+[a-z]{2,}$/i.test(domain)) return { ok: false, error: 'not a domain name' }
      const d = domain.toLowerCase()
      return { ok: false, spf: { state: 'pass', found: [`v=spf1 include:${provider === 'microsoft' ? 'spf.protection.outlook.com' : '_spf.google.com'} ~all`] },
        dkim: { state: 'pass', selector: selector || (provider === 'microsoft' ? 'selector1' : 'google'), found: ['v=DKIM1; k=rsa; p=MIIBIjANBg…'] },
        dmarc: { state: 'missing', add: { type: 'TXT', name: `_dmarc.${d}`, value: 'v=DMARC1; p=none; adkim=r; aspf=r' } } }
    },

    async sendMailTest(digest) {
      await wait(600)
      const m = mail()
      if (m.authorised !== digest) refuse('relay', 'authorise this account on the chain first (Guest email, step 3)', 'اعتمد هذا الحساب أولاً (بريد الضيوف، الخطوة ٣)')
      m.tested = digest
      bump()
      return { ok: true, recorded: true }
    },

    async setGuestEmail(on) {
      await wait(250)
      const m = mail()
      if (on && (!m.connected || !m.authorised)) refuse('invalid', 'Connect and approve an email account first.', 'اربط حساب بريد واعتمده أولاً.')
      if (on && m.tested !== m.authorised) refuse('invalid', 'Send the test email first.', 'أرسل الرسالة التجريبية أولاً.')
      m.on = on
      bump()
    },

    async rules() {
      await wait(60)
      const epoch = st.rulesEpoch ?? DEMO_RULES.length - 1
      return { epoch, current: DEMO_RULES.length - 1, walkSections: DEMO_RULES[epoch], newestSections: DEMO_RULES[DEMO_RULES.length - 1] }
    },

    async adoptRules(epoch) {
      await wait(250)
      const now = st.rulesEpoch ?? DEMO_RULES.length - 1
      if (epoch !== now + 1) refuse('invalid', `The hotel's rules are at epoch ${now}; the next is ${now + 1}.`, `قواعد الفندق في الإصدار ${now}؛ والتالي هو ${now + 1}.`)
      if (epoch > DEMO_RULES.length - 1) refuse('invalid', `This build knows the rules up to epoch ${DEMO_RULES.length - 1}.`, `يعرف هذا الإصدار القواعد حتى الإصدار ${DEMO_RULES.length - 1}.`)
      st.rulesEpoch = epoch
      bump()
    },

    async requireCardOnFile() {
      await wait(250)
      if (st.cardRule) refuse('invalid', 'The card rule is already on.', 'قاعدة البطاقة مفعّلة بالفعل.')
      st.cardRule = true
      bump()
    },

    async manageCard(ref, secret): Promise<CardView | null> {
      await wait(150)
      const b = st.bookings.find((x) => x.ref === ref)
      if (!b || b.secretHash !== (await sha(secret))) refuse('notFound', 'No booking matches this link.', 'لا يوجد حجز يطابق هذا الرابط.')
      const k = cards()[b.id]
      if (!k) return null
      const charge = k.chargeId ? b.payments.find((p) => p.id === k.chargeId) : undefined
      const plan = planView(setup().plans.find((p) => p.id === b.planId)!)
      return { state: k.state, deadline: k.deadline, charge: charge?.state ?? '', chargeAmount: charge?.amount ?? 0n,
        due: k.state === 'wanted' && b.status === 'confirmed' ? guaranteeOfBill(b, plan) : 0n }
    },

    async putCardOnFile(ref, secret, authId) {
      await wait(400)
      const b = st.bookings.find((x) => x.ref === ref)
      if (!b || b.secretHash !== (await sha(secret))) refuse('notFound', 'No booking matches this link.', 'لا يوجد حجز يطابق هذا الرابط.')
      if (b.status !== 'confirmed') refuse('bookingState', 'This booking is no longer waiting for a card.', 'لم يعد هذا الحجز ينتظر بطاقة.')
      const plan = planView(setup().plans.find((p) => p.id === b.planId)!)
      if (plan.guarantee === 'prepaidInFull') refuse('payment', 'A rate paid in advance keeps no card on file.', 'السعر المدفوع مقدماً لا يحتفظ بالبطاقة.')
      const k = cards()[b.id]
      if (k && k.state !== 'wanted') refuse('invalid', `The booking's card is ${k.state}.`, 'بطاقة هذا الحجز مسجّلة بالفعل.')
      if (b.paid > 0n || b.authId) refuse('invalid', 'The booking is already guaranteed.', 'هذا الحجز مضمون بالفعل.')
      const a = st.gateway.find((x) => x.id === authId)
      if (!a?.token) refuse('payment', 'The card was not kept on file.', 'لم تُحفظ البطاقة.')
      if (st.bookings.some((x) => x.authId === authId)) refuse('authUsed', 'This payment was already used.', 'استُخدم هذا الدفع من قبل.')
      const due = guaranteeOfBill(b, plan)
      if (a.ref !== BOOKING_REF_BASE + b.id || a.amount !== due) refuse('payment', 'The payment does not match this booking.', 'الدفع لا يطابق هذا الحجز.')
      b.authId = authId; b.authAmount = a.amount
      const now = plan.guarantee === 'deposit' ? due : 0n
      if (now > 0n) { a.captured = now; b.paid += now; b.outstanding -= now; st.capturedDone = (BigInt(st.capturedDone) + now).toString() }
      cards()[b.id] = { state: 'kept', token: a.token, firstAuth: authId, deadline: k?.deadline ?? 0, chargeId: 0, declinedDay: 0 }
      act(b, 'putCardOnFile', [], [{ kind: 'authorised', state: 'done', amount: a.amount, gatewayAuth: authId, attempts: 1 },
        ...(now > 0n ? [{ kind: 'captured' as const, state: 'done' as const, amount: now, gatewayAuth: authId, attempts: 1 }] : [])])
    },

    async cardDesk(day): Promise<CardDeskRow[]> {
      await wait(120)
      const out: CardDeskRow[] = []
      for (const [bid, k] of Object.entries(cards())) {
        const b = st.bookings.find((x) => x.id === Number(bid))
        if (!b) continue
        const row = { bookingId: b.id, ref: b.ref, guestName: b.guestName, arrival: b.arrival, outstanding: b.outstanding }
        if (k.state === 'wanted' && k.deadline <= day) out.push({ ...row, kind: 'unguaranteed', day: k.deadline, amount: 0n })
        if (k.declinedDay && k.declinedDay <= day && k.declinedDay + 6 >= day)
          out.push({ ...row, kind: 'declined', day: k.declinedDay, amount: b.payments.find((p) => p.id === k.chargeId)?.amount ?? 0n })
        if (k.state === 'forgetFailed') out.push({ ...row, kind: 'forgetFailed', day: 0, amount: 0n })
      }
      return out.sort((x, y) => x.day - y.day || x.bookingId - y.bookingId)
    },

    async upsertRatePlan(id, x) {
      await wait(300)
      const all = setup().plans
      codeFits(x.code)
      const target = id === 0 ? all.reduce((m, p) => Math.max(m, p.id), 0) + 1 : id
      if (id === 0 && target > 16) refuse('invalid', 'A property has at most 16 rate plans.', 'للفندق 16 خطة أسعار على الأكثر.')
      if (id !== 0 && !all.some((p) => p.id === id)) refuse('noSuchPlan', 'That rate does not exist.', 'هذا السعر غير موجود.')
      const other = all.find((p) => p.code === x.code && p.id !== target)
      if (other) refuse('codeTaken', `The code ${x.code} is already used by ${other.id}.`, `الرمز ${x.code} مستخدم بالفعل.`)
      if (x.discountBps > 9000) refuse('invalid', 'A discount is at most 90%.', 'الخصم 90% على الأكثر.')
      if (x.freeCancelDaysBefore > 255 || x.penaltyNights > 255) refuse('invalid', 'The cancellation terms are out of range.', 'شروط الإلغاء خارج النطاق.')
      textsFit([x.name.en, x.name.ar])
      if (x.guarantee === 'deposit' && all.find((p) => p.id === target)?.guarantee !== 'deposit')
        refuse('invalid', 'A deposit is set with its share, from the deposit setting.', 'يُحدَّد العربون بنسبته من إعداد العربون.')
      // a plan not paid in advance keeps the deposit it has, as the contract does
      const was = all.find((p) => p.id === target)
      const guarantee: Guarantee = x.prepaid ? 'prepaidInFull' : was?.guarantee === 'deposit' ? 'deposit' : 'firstNightAuthorised'
      const row = { ...x, id: target, name: { ...x.name }, guarantee, depositBps: guarantee === 'deposit' ? st.deposits?.[target] ?? 0 : 0 }
      const i = all.findIndex((p) => p.id === target)
      if (i < 0) all.push(row); else all[i] = row
      bump()
      return target
    },

    async packageOf(planId): Promise<InclusionView[]> {
      await wait(80)
      return (st.inclusions?.[planId] ?? []).flatMap((inc, i) => {
        const e = st.extras.find((x) => x.id === inc.extraId)
        return e ? [{ ...inc, slot: i + 1, code: e.code, name: { ...e.name }, category: e.category, price: e.price }] : []
      })
    },

    // the contract's checks (src/RateProducts.mo setPlanInclusions), all before the package is written whole
    async setPlanInclusions(planId, inclusions) {
      await wait(300)
      if (!setup().plans.some((p) => p.id === planId)) refuse('noSuchPlan', 'That rate does not exist.', 'هذا السعر غير موجود.')
      if (inclusions.length > 8) refuse('invalid', 'A package has at most 8 inclusions.', 'للباقة 8 بنود على الأكثر.')
      inclusions.forEach((inc, i) => {
        const e = st.extras.find((x) => x.id === inc.extraId)
        if (!e) refuse('noSuchExtra', 'There is no such extra.', 'لا يوجد هذا البند.')
        if (!e.active) refuse('inactive', 'This extra is no longer sold.', 'لم يعد هذا البند يُباع.')
        if (e.price === 0n) refuse('invalid', 'An extra in a package needs a set price.', 'البند في الباقة يحتاج إلى سعر محدد.')
        if (!Number.isInteger(inc.quantity) || inc.quantity < 1 || inc.quantity > 9) refuse('invalid', 'An inclusion gives 1 to 9 of its extra.', 'يعطي البند من 1 إلى 9 من صنفه.')
        if (inclusions.slice(0, i).some((x) => x.extraId === inc.extraId)) refuse('invalid', 'An extra is in a package once.', 'يُضاف البند إلى الباقة مرة واحدة.')
      })
      ;(st.inclusions ??= {})[planId] = inclusions.map((x) => ({ ...x }))
      bump()
    },

    async setupTaxes() { return setup().taxes.map((x) => ({ ...x, name: { ...x.name } })) },

    async upsertTaxRule(id, x) {
      await wait(300)
      const all = setup().taxes
      codeFits(x.code)
      const target = id === 0 ? all.reduce((m, r) => Math.max(m, r.id), 0) + 1 : id
      if (id === 0 && target > 8) refuse('invalid', 'A property has at most 8 tax rules.', 'للفندق 8 قواعد ضريبية على الأكثر.')
      if (id !== 0 && !all.some((r) => r.id === id)) refuse('noSuchTaxRule', 'There is no such tax rule.', 'لا توجد هذه القاعدة الضريبية.')
      const other = all.find((r) => r.code === x.code && r.id !== target)
      if (other) refuse('codeTaken', `The code ${x.code} is already used by ${other.id}.`, `الرمز ${x.code} مستخدم بالفعل.`)
      if (x.kind === 'percent' && (x.bps < 1 || x.bps > 10000)) refuse('invalid', 'A percentage tax is between 0.01% and 100%.', 'الضريبة النسبية بين 0.01% و100%.')
      if (x.kind !== 'percent' && x.amount <= 0n) refuse('invalid', 'A fixed tax needs an amount.', 'تحتاج الضريبة الثابتة إلى مبلغ.')
      if (x.rank > 255) refuse('invalid', 'The tax rule is out of range.', 'القاعدة الضريبية خارج النطاق.')
      textsFit([x.name.en, x.name.ar])
      const row = { ...x, id: target, name: { ...x.name } }
      const i = all.findIndex((r) => r.id === target)
      if (i < 0) all.push(row); else all[i] = row
      bump()
      return target
    },

    async bill(bookingId) {
      await wait(120)
      const b = bookingOf(bookingId)
      return { windows: windowsOf(b), lines: billLines(b) }
    },

    async postCharge(bookingId, extraId, quantity, amount, payerId) {
      await wait(300)
      const b = bookingOf(bookingId)
      if (b.status !== 'checkedIn') refuse('bookingState', 'Charges go on the bill of a guest in house.', 'تُضاف الرسوم إلى فاتورة ضيف مقيم.')
      const e = st.extras.find((x) => x.id === extraId)
      if (!e) refuse('noSuchExtra', 'There is no such extra.', 'لا يوجد هذا البند.')
      if (!e.active) refuse('inactive', 'This extra is no longer sold.', 'لم يعد هذا البند يُباع.')
      if (!Number.isInteger(quantity) || quantity < 1 || quantity > 99) refuse('invalid', 'A quantity is 1 to 99.', 'الكمية من 1 إلى 99.')
      let unit = e.price
      if (unit > 0n) { if (amount !== 0n && amount !== unit) refuse('invalid', 'This extra has a set price.', 'لهذا البند سعر محدد.') }
      else { if (amount <= 0n) refuse('invalid', 'Enter the amount of this charge.', 'أدخل مبلغ هذه الرسوم.'); unit = amount }
      if (payerId !== 0 && !(b.payers ?? []).some((p) => p.id === payerId)) refuse('noSuchPayer', 'There is no such payer on this booking.', 'لا يوجد هذا الدافع في الحجز.')
      if (invoiced(b, payerId)) refuseInvoiced(payerId)
      const net = unit * BigInt(quantity)
      const taxes = e.taxed ? taxesOn(net, activeTaxes()) : []
      const total = taxes.reduce((a, x) => a + x.amount, net)
      const p = payerId || undefined
      act(b, 'postCharge', [
        { kind: 'extra', night: st.businessDate, amount: net, payerId: p, charge: { extraId, quantity, unit, taxLines: taxes.length, voidLine: 0 } },
        ...taxes.map((x) => ({ kind: 'extraTax' as const, night: st.businessDate, amount: x.amount, payerId: p, code: x.ruleId })),
      ])
      b.charged += total; b.outstanding += total
      save()
    },

    async addPayer(bookingId, name) {
      await wait(250)
      const b = bookingOf(bookingId)
      if (b.status !== 'confirmed' && b.status !== 'checkedIn') refuse('bookingState', 'A payer is added to a stay to come or in house.', 'يُضاف الدافع إلى حجز قادم أو ضيف مقيم.')
      const bytes = new TextEncoder().encode(name.trim()).length
      if (bytes === 0) refuse('invalid', 'Name who pays.', 'سمِّ من يدفع.')
      if (bytes > 80) refuse('tooLong', 'A payer name is at most 80 bytes.', 'اسم الدافع 80 بايت على الأكثر.')
      if ((b.payers ?? []).length >= 7) refuse('invalid', 'A bill has at most 7 payers besides the guest.', 'للفاتورة 7 دافعين على الأكثر بجانب الضيف.')
      const id = st.bookings.reduce((n, x) => n + (x.payers?.length ?? 0), 0) + 1
      b.payers = [...(b.payers ?? []), { id, name: name.trim() }]
      act(b, 'addPayer')
      return id
    },

    async routeLines(bookingId, lineIds, payerId) {
      await wait(300)
      const b = bookingOf(bookingId)
      if (payerId !== 0 && !(b.payers ?? []).some((p) => p.id === payerId)) refuse('noSuchPayer', 'There is no such payer on this booking.', 'لا يوجد هذا الدافع في الحجز.')
      if (invoiced(b, payerId)) refuseInvoiced(payerId)
      const moving: DemoLine[] = []
      for (const id of lineIds) {
        const l = b.lines.find((x) => x.id === id)
        if (!l) refuse('invalid', `There is no line ${id} on this booking.`, `لا يوجد السطر ${id} في هذا الحجز.`)
        if (l.kind === 'extraTax') refuse('invalid', 'A tax on an extra moves with the extra.', 'تنتقل ضريبة البند معه.')
        if (winOfLine(l) === payerId) refuse('invalid', `Line ${id} is already on that bill.`, `السطر ${id} على تلك الفاتورة بالفعل.`)
        if (invoiced(b, winOfLine(l))) refuseInvoiced(winOfLine(l))
        moving.push(l)
        if (l.charge) for (let i = l.id + 1; i <= l.id + l.charge.taxLines; i++) moving.push(b.lines.find((x) => x.id === i)!)
      }
      // no bill may end up paid for more than it owes
      for (const w of windowsOf(b)) {
        let owes = w.charges - w.credits
        for (const l of moving) {
          const sign = l.kind === 'credit' ? -1n : 1n
          if (w.payerId === payerId) owes += sign * l.amount
          if (w.payerId === winOfLine(l)) owes -= sign * l.amount
        }
        if (w.paid > owes) refuse('invalid', 'Paid lines stay where they were paid.', 'تبقى السطور المدفوعة حيث دُفعت.')
      }
      for (const l of moving) l.payerId = payerId || undefined
      act(b, 'routeLines')
    },

    async settleShare(bookingId, payerId, authId) {
      await wait(350)
      const b = bookingOf(bookingId)
      if (payerId === 0) refuse('invalid', "The guest's own share is taken with the guest's payment at the desk.", 'تُحصَّل حصة الضيف مع دفعه في المكتب.')
      const w = windowsOf(b).find((x) => x.payerId === payerId)
      if (!w) refuse('noSuchPayer', 'There is no such payer on this booking.', 'لا يوجد هذا الدافع في الحجز.')
      if (w.open === 0n) refuse('invalid', 'Nothing is left to pay on this bill.', 'لم يتبقَّ شيء للدفع على هذه الفاتورة.')
      const a = st.gateway.find((x) => x.id === authId)
      if (!a || a.ref !== BOOKING_REF_BASE + b.id) refuse('payment', 'The payment authorisation is for another reservation.', 'تفويض الدفع لحجز آخر.')
      if (a.amount !== w.open) refuse('payment', 'The payment authorisation is not for what is due.', 'تفويض الدفع لا يساوي المبلغ المستحق.')
      if (b.payments.some((p) => p.gatewayAuth === authId)) refuse('authUsed', 'This payment was already used.', 'استُخدم هذا الدفع من قبل.')
      a.captured = w.open
      b.paid += w.open; b.outstanding -= w.open
      st.capturedDone = (BigInt(st.capturedDone) + w.open).toString()
      act(b, 'settleShare', [], [{ kind: 'authorised', state: 'done', amount: w.open, gatewayAuth: authId, attempts: 1, payerId },
        { kind: 'captured', state: 'done', amount: w.open, gatewayAuth: authId, attempts: 1, payerId }])
    },

    async issueInvoice(bookingId, payerId) {
      await wait(300)
      const b = bookingOf(bookingId)
      if (b.status !== 'checkedIn' && b.status !== 'checkedOut') refuse('bookingState', 'A bill is invoiced while the guest is in house or after.', 'تصدر الفاتورة أثناء الإقامة أو بعدها.')
      const w = windowsOf(b).find((x) => x.payerId === payerId)
      if (!w) refuse('noSuchPayer', 'There is no such payer on this booking.', 'لا يوجد هذا الدافع في الحجز.')
      if (w.invoice) refuse('invalid', `This bill is already invoice ${w.invoice}.`, `هذه الفاتورة صدرت برقم ${w.invoice}.`)
      if (!b.lines.some((l) => winOfLine(l) === payerId)) refuse('invalid', 'There is nothing on this bill to invoice.', 'لا يوجد ما يُفوتَر على هذه الفاتورة.')
      const number = st.invoices.length + 1
      st.invoices.push({ number, bookingId, payerId, issuedDay: st.businessDate, charges: w.charges, credits: w.credits, taxes: w.taxes, paid: w.paid })
      act(b, 'issueInvoice')
      return number
    },

    async invoice(number) {
      await wait(120)
      const inv = st.invoices.find((i) => i.number === number)
      if (!inv) return null
      const b = bookingOf(inv.bookingId)
      const w = windowsOf(b).find((x) => x.payerId === inv.payerId)!
      return { number, bookingId: b.id, ref: b.ref, payerId: inv.payerId, payerName: w.name, guestName: b.guestName, issuedDay: inv.issuedDay,
        charges: inv.charges, credits: inv.credits, taxes: inv.taxes, paid: inv.paid, hotel: t.name, lines: billLines(b).filter((l) => l.payerId === inv.payerId) }
    },

    async settleAtDesk(bookingId, authId) {
      await wait(350)
      const b = st.bookings.find((x) => x.id === bookingId)
      if (!b) refuse('noSuchBooking', 'There is no such booking.', 'لا يوجد هذا الحجز.')
      if (b.status !== 'checkedIn' && b.status !== 'confirmed') refuse('bookingState', 'Only a stay to come or in house is settled at the desk.', 'لا يُسدَّد في المكتب إلا حجز قادم أو ضيف مقيم.')
      // the guest's own window: the booking less the other payers' windows
      const amount = windowsOf(b)[0].open
      if (amount === 0n) refuse('invalid', 'Nothing is left to pay.', 'لم يتبقَّ شيء للدفع.')
      const a = st.gateway.find((x) => x.id === authId)
      if (!a || a.ref !== BOOKING_REF_BASE + b.id) refuse('payment', 'The payment authorisation is for another reservation.', 'تفويض الدفع لحجز آخر.')
      if (a.amount !== amount) refuse('payment', 'The payment authorisation is not for what is due.', 'تفويض الدفع لا يساوي المبلغ المستحق.')
      if (st.bookings.some((x) => x.authId === authId) || b.payments.some((p) => p.gatewayAuth === authId)) refuse('authUsed', 'This payment was already used.', 'استُخدم هذا الدفع من قبل.')
      // the demo gateway captures at once; the chain's capture lands through its gateway queue
      a.captured = amount
      b.paid += amount; b.outstanding -= amount
      st.capturedDone = (BigInt(st.capturedDone) + amount).toString()
      act(b, 'settleAtDesk', [], [{ kind: 'authorised', state: 'done', amount, gatewayAuth: authId, attempts: 1 }, { kind: 'captured', state: 'done', amount, gatewayAuth: authId, attempts: 1 }])
    },

    async checkOut(bookingId) {
      await wait(300)
      const b = st.bookings.find((x) => x.id === bookingId)
      if (!b || b.status !== 'checkedIn') refuse('bookingState', 'This guest is not in house.', 'هذا الضيف ليس مقيماً.')
      if (b.outstanding > 0n) refuse('balanceOutstanding', 'There is a balance to pay before check-out.', 'يوجد رصيد مستحق قبل المغادرة.')
      // the rooms the guest leaves are dirty until housekeeping cleans them
      for (const r of st.rooms) if (r.occupiedBy === b.id) Object.assign(r, { occupiedBy: 0, cleaning: 'dirty', cleanedBy: undefined, inspectedBy: undefined, changedDay: st.businessDate })
      b.status = 'checkedOut'
      mailHook(b, 'checkedOut')
      letGo(b.id)
      act(b, 'checkOut')
    },

    // the demo hotel's guest-data key is made in this browser; the document is sealed to it and the
    // ciphertext and sealed key are kept in this page's memory (the chain source files them on the chain)
    async captureId(bookingId, file) {
      await wait(400)
      const b = st.bookings.find((x) => x.id === bookingId)
      if (!b) refuse('noSuchBooking', 'There is no such booking.', 'لا يوجد هذا الحجز.')
      const pair = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits'])
      const raw = hex(new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey)))
      const sealed = await sealFile(new Uint8Array(await file.arrayBuffer()), raw)
      const day = b.departure + 30   // the demo property keeps documents 30 days
      const list = idDocs.get(bookingId) ?? []
      list.push({ documentId: list.length + 1, erased: false, eraseDay: day, plainSize: file.size })
      idDocs.set(bookingId, list)
      idBlobs.set(`${bookingId}:${list.length}`, { ciphertext: sealed.ciphertext, fileKey: sealed.fileKey })
      act(b, 'fileIdDocument')
    },

    async idDocuments(bookingId): Promise<IdDocumentView[]> { return idDocs.get(bookingId) ?? [] },

    async staff(): Promise<StaffRow[]> {
      return roster().filter((g) => g.active).map((g) => ({ grantId: g.grantId, subject: g.subject, role: g.role, mine: g.subject === DEMO_ME,
        automatic: g.subject === AUTO_RUNNER && g.role === 'auditor', since: g.since }))
    },
    async myRoles(): Promise<Role[]> { return roster().filter((g) => g.active && g.subject === DEMO_ME).map((g) => g.role) },
    async myId() { return DEMO_ME },
    async grantRole(subject, role) {
      await wait(250)
      const who = subject.trim().toLowerCase()
      if (!/^[0-9a-f]{2,58}$/.test(who) || who.length % 2) refuse('invalid', 'A staff id is the hex they see under Staff on their own screen.', 'معرّف الموظف هو الرمز الست عشري الظاهر له في صفحة الموظفين.')
      const list = roster()
      if (list.some((g) => g.active && g.subject === who && g.role === role)) refuse('roleHeld', 'They already hold that role.', 'لديه هذا الدور بالفعل.')
      list.push({ grantId: list.length + 1, subject: who, role, active: true, since: bump() })
      save()
    },
    async revokeRole(subject, role) {
      await wait(250)
      const list = roster()
      const g = list.find((x) => x.active && x.subject === subject && x.role === role)
      if (!g) refuse('roleNotHeld', 'They do not hold that role.', 'ليس لديه هذا الدور.')
      if (g.subject === AUTO_RUNNER && role === 'auditor') refuse('invalid', 'The automatic night audit holds this role; turn it off under Night audit.', 'يحمل التدقيق الليلي التلقائي هذا الدور؛ أوقفه من صفحة التدقيق الليلي.')
      if (role === 'owner' && list.filter((x) => x.active && x.role === 'owner').length <= 1) refuse('invalid', 'The last owner cannot be removed.', 'لا يمكن إزالة المالك الأخير.')
      g.active = false
      bump()
    },

    async setNights(e: NightsEdit): Promise<number> {
      await wait(300)
      const writes = planEdit(e, undefined, new Set())
      commit(writes)
      return writes.length
    },
    async setNightsMany(edits: ManyEdit[]): Promise<number> {
      await wait(300)
      if (edits.length === 0) refuse('invalid', 'A save carries at least one change.', 'الحفظ يحمل تغييراً واحداً على الأقل.')
      if (edits.length > 256) refuse('invalid', 'One save carries at most 256 changes.', 'الحفظ الواحد يحمل 256 تغييراً على الأكثر.')
      // every edit is checked against the nights as they stand before any is written: the save lands whole
      const touched = new Set<string>()
      const writes = edits.flatMap((m) => planEdit(m.edit, m.adjust, touched))
      commit(writes)
      return writes.length
    },
  }
  // the automatic night audit's minute tick, as the contract's timer. Switching sources builds a new
  // instance from storage; an instance that is no longer the tenant's latest stops its tick, so a stale
  // copy of the state can never be saved over the live one.
  latest.set(tenantId, api)
  if (typeof window !== 'undefined') {
    const tick = window.setInterval(() => { if (latest.get(tenantId) !== api) window.clearInterval(tick); else void autoTick(api) }, 60_000)
  }
  return api
}

const latest = new Map<TenantId, Api>()

export { dayOf }
