/**
 * The shapes the booking engine reads and writes. They mirror the contract's views (flat records of
 * scalar fields, amounts in minor units) so the demo source and the chain source are interchangeable.
 */
import type { Day } from '../lib/days'

export type Bi = { en: string; ar: string }

export interface PropertyView {
  name: Bi
  currency: string
  minorUnits: number
  businessDate: Day
  checkIn: Bi
  checkOut: Bi
  maxStayNights: number
  maxRoomsPerBooking: number
  holdRealSeconds: number
  idRetentionDays: number
  atBlock: number
}

export interface Photo {
  src: string // base path without width suffix, e.g. media/almar/sea-room-1
  alt: string
  width: number
  height: number
  lqip?: string
  credit: string
}

export type BedKind = 'king' | 'queen' | 'double' | 'twin' | 'single'

export interface RoomTypeView {
  id: number
  code: string
  name: Bi
  desc: Bi
  sizeSqm: number
  maxAdults: number
  maxChildren: number
  maxOccupancy: number
  bedKind: BedKind
  bedCount: number
  amenities: string[]
  view: Bi
  photos: Photo[]
  rooms: number
}

/** How a rate is guaranteed: the first night authorised, the stay paid in advance, or a deposit (a share of the room's stay, taken at once). */
export type Guarantee = 'firstNightAuthorised' | 'prepaidInFull' | 'deposit'

export interface PlanView {
  id: number
  code: string
  name: Bi
  refundable: boolean
  freeCancelDaysBefore: number
  penaltyNights: number
  guarantee: Guarantee
  discountBps: number
  /** A deposit plan's share, in basis points (0 for any other plan). */
  depositBps?: number
  /** Whether the hotel keeps the guest's card on file for this rate (the guest agrees to it at payment). */
  keepsCard?: boolean
}

/**
 * A booking's card on file as its guest sees it: never the card or the gateway's token.
 * `wanted`: a booking taken by phone waiting for the guest's card, by `deadline`; `kept`: on file;
 * `forgetDue`/`forgotten`/`forgetFailed`: let go, or being let go, at the gateway; `closed`: no longer needed.
 * `charge`: a no-show charge to the card ('' none), and `amount` what the card link takes now (a wanted card).
 */
export type CardOnFileState = 'wanted' | 'kept' | 'forgetDue' | 'forgotten' | 'forgetFailed' | 'closed'
export interface CardView { state: CardOnFileState; deadline: Day; charge: '' | 'due' | 'done' | 'failed'; chargeAmount: bigint; due: bigint }
/** What the desk acts on: a guarantee due with no card (never cancelled for it), a no-show charge the card declined, a card the gateway would not delete. */
export interface CardDeskRow { bookingId: number; ref: string; guestName: string; arrival: Day; kind: 'unguaranteed' | 'declined' | 'forgetFailed'; day: Day; amount: bigint; outstanding: bigint }

export interface CalendarDay {
  day: Day
  from: bigint | null // the lowest nightly rate on sale that night, or null when nothing is
  bookable: boolean
  closedToArrival: boolean
  closedToDeparture: boolean
  minStay: number
}

export interface StayRequest {
  arrival: Day
  nights: number
  rooms: number
  adults: number
  children: number
  /** A company's or a promotion's rate code the guest gave: it opens rates the public search does not show. */
  code?: string
}

/** What a rate code opens: whose rate it is and the plans the public search does not show. */
export interface CodeView { ok: boolean; kind: string; reason: Bi; name: string; planIds: number[] }
/** A company with negotiated rates: its code is what its bookers type. Off sale, its rates refuse it. */
export interface CompanyView { id: number; code: string; name: string; active: boolean }
/** Who a plan is sold to: everyone (no row, or open), only to one company's bookings (closed, its id), or
 *  only under a promotion's code (closed, company 0). */
export interface PlanAccessView { planId: number; companyId: number; closed: boolean }
/** A promotion: its code opens one plan closed to everyone but codes, booked within its booking window, for
 *  nights within its stay window, up to `maxUses` bookings (0: no limit). A use is counted at the
 *  confirmation or the booking by staff, never at a hold or a change. Days are the hotel's business days. */
export interface PromoView { id: number; code: string; name: string; planId: number; bookFrom: number; bookUntil: number; stayFrom: number; stayUntil: number;
  maxUses: number; used: number; active: boolean }
export type PromoFacts = Omit<PromoView, 'id' | 'used'>
/** A group block: rooms of one type on one plan held off sale for a group from `arrival` to `departure`,
 *  until `cutoff`, the business day the night audit gives what is not picked up back to sale. The desk
 *  picks the group's guests up from it; `companyId` 0 is a block on a plan sold to everyone. */
export interface BlockView { id: number; name: string; companyId: number; roomTypeId: number; planId: number; arrival: Day; departure: Day; rooms: number;
  cutoff: Day; open: boolean; roomNights: number; pickedNights: number; heldNights: number }
export interface BlockFacts { name: string; companyId: number; roomTypeId: number; planId: number; arrival: Day; nights: number; rooms: number; cutoff: Day }
/** One night of a block: the rooms picked up and the rooms it still holds. */
export interface BlockNightView { day: Day; picked: number; held: number }
/** A booking on a block's rooming list (cancelled pickups stay on it with their status). */
export interface RoomingRow { id: number; ref: string; status: BookingStatus; arrival: Day; departure: Day; rooms: number; guestName: string; outstanding: bigint }

export interface Offer {
  roomTypeId: number
  planId: number
  total: bigint
  roomSubtotal: bigint
  taxTotal: bigint
  perNightAvg: bigint
  left: number
  cancelDeadline: Day | null
  guarantee: bigint
  quoteHash: string
  /** A package's inclusions with their taxes, part of `total`; 0 for a plain rate. */
  packageTotal: bigint
}

export interface Unavailable {
  roomTypeId: number
  kind: string
  reason: Bi
}

export interface SearchResult {
  offers: Offer[]
  unavailable: Unavailable[]
  atBlock: number
}

export interface NightLine {
  day: Day
  room: bigint
  taxes: { ruleId: number; name: Bi; amount: bigint }[]
}

export interface QuoteDetail {
  nights: NightLine[]
  taxLines: { ruleId: number; name: Bi; amount: bigint }[]
  roomSubtotal: bigint
  /** A package's lines, each inclusion on each night it is given, with its own tax; empty for a plain rate. */
  package: PackageLineView[]
  packageTotal: bigint
  total: bigint
}

/** When an inclusion is given: every night of the stay, or on the arrival night only. */
export type Rhythm = 'everyNight' | 'arrivalNight'
export const RHYTHMS: Rhythm[] = ['everyNight', 'arrivalNight']
/** What an inclusion's quantity is counted per: each room, each adult, or each guest. */
export type Per = 'room' | 'adult' | 'guest'
export const PERS: Per[] = ['room', 'adult', 'guest']
/** An inclusion as the owner sets it: an extra of the catalogue with a set price, how many, when, per what. */
export interface InclusionSetting { extraId: number; quantity: number; rhythm: Rhythm; per: Per }
/** An inclusion of a plan's package, with its extra as the catalogue sells it now. */
export interface InclusionView extends InclusionSetting { slot: number; code: string; name: Bi; category: ExtraCategory; price: bigint }
/** One package line of a quote: an inclusion on one night, its net and its tax. */
export interface PackageLineView { day: Day; slot: number; extraId: number; name: Bi; quantity: number; unit: bigint; net: bigint; tax: bigint }

export interface HoldView {
  holdId: number
  total: bigint
  expiresAtMs: number
  block: number
}

/** The TEST gateway's scenarios. `refundDeclined` authorises and captures, and its issuer refuses every refund. */
export type TestScenario = 'approve' | 'decline' | 'insufficient' | 'refundDeclined' | 'mitDeclined'

/** A gateway merchant reference at or above this names a booking rather than a hold (the contract's BOOKING_REF_BASE). */
export const BOOKING_REF_BASE = 1_000_000_000_000

export interface AuthResult {
  ok: boolean
  authId: number
  reason?: string
}

export interface GuestDetails {
  name: string
  email: string
  note: string
  /** The language the guest's emails are written in (the page's, when the guest booked). */
  lang?: 'en' | 'ar'
}

/** What became of a booking's emails when it was made: queued, the hotel has no guest email yet, or the
 *  address could not be given (the booking stands; the manage page offers it again). */
export type MailAttach = 'queued' | 'notConnected' | 'failed' | 'noAddress'

/** One email a booking is owed, as the contract keeps it (never the address: it is sealed to the relay). */
export type MailKind = 'confirmation' | 'preArrival' | 'receipt' | 'cancellation'
export type MailState = 'due' | 'sent' | 'failed' | 'skipped'
export type MailFailure = '' | 'rejected' | 'unavailable' | 'unreadable' | 'signIn'
export interface MailRow { outboxId: number; kind: MailKind; state: MailState; attempts: number; failure: MailFailure; notBefore: Day }

/** Guest email as the console shows it. `waiting` counts up to 99 (`more`: there are more). */
/** The books' rules: the epoch they are kept under, the newest this build knows, and the sections the
 * night audit checks before the day may close (epoch 0, a hotel deployed before epochs existed: 5). */
export interface RulesView { epoch: number; current: number; walkSections: number; newestSections: number }

export interface MailSetupView { connected: boolean; mailer: string; authorised: string; tested: string; on: boolean; waiting: number; more: boolean; relay: string }

/** An email provider the relay connects, and what the owner gives for it. */
export type MailProvider = 'google' | 'microsoft' | 'smtp' | 'sendgrid' | 'postmark' | 'resend' | 'mailgun' | 'brevo' | 'ses'
export interface MailProviderView { name: MailProvider; label: string; fields: string[]; oauth: boolean; available: boolean }
/** The hotel's own account as the owner gives it: the sender, where the test email goes, and the provider's own fields. */
export interface MailAccount { provider: MailProvider; from: string; fromName: string; testTo: string; lang: 'en' | 'ar'; fields: Record<string, string> }
export interface MailAccountSaved { digest: string; provider: MailProvider; from: string }
/** The account the hotel's books name, as the mail service holds it: its provider and sending address only. onFile is false
 *  when none is named, or when the service no longer holds the one named (it must be given again). */
export interface MailAccountInUse { digest: string; onFile: boolean; provider?: MailProvider; from?: string }
export type DnsState = 'pass' | 'missing' | 'wrong'
export interface DnsRecord { type: string; name: string; value: string }
export interface DnsLine { state: DnsState; found?: string[]; add?: DnsRecord; why?: string; note?: string; policy?: string; selector?: string }
export interface DnsCheckView { ok: boolean; error?: string; spf?: DnsLine; dkim?: DnsLine; dmarc?: DnsLine }
export interface MailTestResult { ok: boolean; failure?: MailFailure; recorded?: boolean }

export type BookingStatus = 'confirmed' | 'checkedIn' | 'checkedOut' | 'cancelled' | 'noShow'

export interface BookingView {
  id: number
  ref: string
  /** The plan's name, read with the booking by its own guest (a plan closed to a company is not listed publicly). */
  planName?: Bi
  status: BookingStatus
  roomTypeId: number
  planId: number
  arrival: Day
  departure: Day
  rooms: number
  adults: number
  children: number
  guestName: string
  charged: bigint
  credited: bigint
  paid: bigint
  outstanding: bigint
  penalty: bigint
  cancelDeadline: Day | null
  refundable: boolean
  block: number
}

export interface ConfirmResult {
  booking: BookingView
  manageSecret: string
  captured: boolean
  mail: MailAttach
}

export interface CancelResult {
  booking: BookingView
  fee: bigint
  refund: bigint
}

export interface SealView {
  ok: boolean
  /** 'full' when every invariant was walked over every row; 'cash' when only the cash law was. */
  scope: 'full' | 'cash'
  invariants: number
  examined: number
  violations: string[]
}

export interface GridCell {
  day: Day
  allotment: number
  sold: number
  held: number
  /** Rooms held off sale by open group blocks. */
  blocked: number
  bar: bigint | null
  minStay: number
  closedToArrival: boolean
  closedToDeparture: boolean
  stopSell: boolean
}

export interface GridRow {
  roomTypeId: number
  cells: GridCell[]
}

export interface NightsEdit {
  roomTypeId: number
  fromDay: Day
  toDay: Day
  weekdays: number
  allotment?: number
  bar?: bigint
  minStay?: number
  maxStay?: number
  closedToArrival?: boolean
  closedToDeparture?: boolean
  stopSell?: boolean
}

/** A percentage on each night's own rate, in basis points; the contract rounds half-even once. */
export interface RateAdjust { up: boolean; bps: number }

/** One change in a save of several; no two changes of one save may touch the same night. */
export interface ManyEdit { edit: NightsEdit; adjust?: RateAdjust }

export interface DeskRow {
  booking: BookingView
  roomNumbers: string[]
}

/** A room's cleaning; '' is a room with no housekeeping record yet ("not recorded"). */
export type Cleaning = 'dirty' | 'clean' | 'inspected'
export interface VacantRoom { id: number; number: string; cleaning: Cleaning | '' }

/** One room on the housekeeping board. */
export interface BoardRoom {
  id: number
  number: string
  roomTypeId: number
  outOfOrder: boolean
  cleaning: Cleaning | ''
  /** Who cleaned it and who inspected that cleaning (principals as text), '' when nobody. */
  cleanedBy: string
  inspectedBy: string
  /** The person looking at the board cleaned it, so they cannot inspect it. */
  cleanedByMe: boolean
  inspectedByMe: boolean
  /** Out of order with dates: the reason, the day it went out, and the first night it is back in the count. */
  outReason: string
  outFrom: Day | null
  outUntil: Day | null
  changedDay: Day | null
  /** The booking in the room, 0 when vacant, and the day that guest leaves. */
  occupiedBy: number
  departure: Day | null
}

export interface AuditStatus {
  open: boolean
  completed: boolean
  items: number
  done: number
  failures: number
  walkDone: boolean
  examined: number
  violations: number
  firstViolation: string
  businessDate: Day
}

/** The hotel's own clock: its time zone, the local time the night audit runs at, and whether it runs by itself. */
export interface HotelClock {
  /** False until the owner sets it; the rest are then empty. */
  set: boolean
  zoneName: string
  /** The zone's POSIX TZ rule, which the contract evaluates. */
  zoneRule: string
  /** The audit's local time, in seconds after midnight. */
  auditAt: number
  auto: boolean
  /** The local day and time at the hotel now, and the zone's abbreviation now (EEST, +03). */
  localDay: Day
  localSecond: number
  zoneNow: string
  /** The last business day whose audit is due now, or null. */
  dueThrough: Day | null
  businessDate: Day
  /** What the automatic audit last did, or null when it has not run since the contract last started. */
  last: { at: Date; day: Day; act: string; ok: boolean; reason: string; steps: number } | null
}

export interface HotelClockSetting { zoneName: string; zoneRule: string; auditAt: number; auto: boolean }

export type DualAct = 'staffCancel' | 'waivePenalty' | 'refundOutsidePolicy' | 'compNights' | 'priceOverride' | 'editGuestRecord' | 'voidCharge'
  | 'issueCreditNote' | 'refundAtDesk'

export type ExtraCategory = 'restaurant' | 'minibar' | 'spa' | 'parking' | 'breakfast' | 'other'
export const EXTRA_CATEGORIES: ExtraCategory[] = ['restaurant', 'minibar', 'spa', 'parking', 'breakfast', 'other']

/** An item of the hotel's extras catalogue; `price` 0 is an amount entered when it is posted. */
export interface ExtraView { id: number; code: string; name: Bi; category: ExtraCategory; price: bigint; taxed: boolean; active: boolean }

/** One window of a booking's bill: the guest's (payer 0) or another payer's. `invoice` is its number once invoiced. */
export interface BillWindowView { payerId: number; name: string; charges: bigint; credits: bigint; taxes: bigint; paid: bigint; due: bigint; open: bigint; invoice: number | null }

/** A line of the bill: what it is, on whose bill, and whether it is a voided charge (or the credit that voided one).
 *  `code` tells credits apart: 1 a void's, 2 a credit note's (CREDIT_NOTE_CODE). */
export interface BillLineView {
  id: number; kind: FolioLineView['kind']; code: number; night: Day; amount: bigint; payerId: number; title: Bi; quantity: number; unitAmount: bigint
  voided: boolean; voidable: boolean
}

/** The code of a credit line a credit note wrote (src/CreditNote.mo). */
export const CREDIT_NOTE_CODE = 2
/** A line a credit note wrote: on the invoiced bill, never one of the invoice's own lines. */
export const isNoteLine = (l: Pick<BillLineView, 'kind' | 'code'>) => l.kind === 'credit' && l.code === CREDIT_NOTE_CODE
/** The lines a credit note can take back (their taxes go with them). */
export const creditable = (k: FolioLineView['kind']) => k === 'roomNight' || k === 'extra' || k === 'penalty'

/** A credit note against an invoice: its number in a run of its own, its figures, and who proposed and approved it. */
export interface CreditNoteRow {
  number: number; invoice: number; bookingId: number; payerId: number; issuedDay: Day; net: bigint; taxes: bigint; total: bigint
  lines: number; maker: string; checker: string
}

/** One line of a credit note: the credit, the line it takes back and what that line was. */
export interface CreditNoteLineView { id: number; source: number; sourceKind: FolioLineView['kind']; title: Bi; night: Day; amount: bigint; tax: boolean }

/** A credit note as the hotel prints it. */
export interface CreditNoteView extends CreditNoteRow {
  invoiceDay: Day; ref: string; payerName: string; guestName: string; hotel: Bi; lineItems: CreditNoteLineView[]
}

/** A credit note as the tax authority's document (type C): its JSON, the digest of its serialisation, and what
 *  a submission still needs. Luxor does not submit it. */
export interface CreditNoteEta { json: string; digest: string; total: bigint; missing: string[] }

/** The hotel's registration with the tax authority, as its documents name the issuer. */
export interface EtaProfile {
  issuerId: string; activityCode: string; branchId: string; country: string; governate: string; regionCity: string; street: string; buildingNumber: string
}
/** A tax rule's codes with the authority ('' until given). */
export interface TaxEta { taxRuleId: number; taxType: string; subType: string }

export type DeskMethod = 'cash' | 'transfer'

/** How a booking staff took reached the hotel: a call, or a guest at the desk (checked in at once). */
export type Channel = 'phone' | 'walkIn' | 'group'
export interface StaffBookingView { channel: Channel; madeBy: string; day: Day }
export interface StaffBookResult { booking: BookingView; manageSecret: string; mail?: MailAttach }
export interface StaffGuest { name: string; email: string; note: string; lang?: 'en' | 'ar' }
/** A refund the gateway would not make, paid at the desk. */
export interface DeskRefundView { paymentId: number; method: DeskMethod; reference: string; day: Day; maker: string; checker: string }
/**
 * A refund: the card it goes back to as the gateway names it (`card` 0: no card, the desk pays it), the
 * bill it is on, and where it stands. A refund to the guest is split across the guest's own cards,
 * newest first; each slice names the first slice of its settle and the whole that settle gave back.
 */
export type RefundState = 'due' | 'done' | 'failed' | 'paidAtDesk'
export interface RefundView { paymentId: number; payerId: number; card: number; amount: bigint; state: RefundState; attempts: number; firstSlice: number; excess: bigint }

export interface BillView { windows: BillWindowView[]; lines: BillLineView[] }

/** An invoice as the hotel prints it, with the lines of the bill it closed. */
export interface InvoiceView {
  number: number; bookingId: number; ref: string; payerId: number; payerName: string; guestName: string; issuedDay: Day
  charges: bigint; credits: bigint; taxes: bigint; paid: bigint; hotel: Bi; lines: BillLineView[]
}

export interface ProposalView {
  id: number
  act: DualAct
  bookingId: number
  ref: string
  amount: bigint
  text: string
  mine: boolean
}

export interface WaitView {
  id: number
  roomTypeId: number
  arrival: Day
  nights: number
  rooms: number
  state: 'waiting' | 'offered' | 'left'
  offeredHold: number
  offerTotal: bigint
}

export interface IdDocumentView { documentId: number; erased: boolean; eraseDay: Day; plainSize: number }

/** The hotel's staff roles. The owner gives and ends them; each opens its own part of the console. */
export type Role = 'owner' | 'revenue' | 'frontDesk' | 'auditor' | 'housekeeping'

/** A business day's figures, as the night audit wrote them. `closed` is false while the day's audit is
 *  still open (its figures are partial). Occupancy = roomsSold / (roomsTotal − roomsOut); ADR =
 *  roomRevenue / roomsSold; RevPAR = roomRevenue / (roomsTotal − roomsOut). Pickup: the bookings made
 *  since the day before's figures, with their room nights and room revenue. */
export interface DayFiguresView {
  day: Day
  roomsTotal: number
  roomsOut: number
  roomsSold: number
  roomRevenue: bigint
  arrivals: number
  noShows: number
  pickupBookings: number
  pickupNights: number
  pickupRevenue: bigint
  closed: boolean
}

/** Room nights and room revenue of one night (audited, or on the books) for one room type and plan. */
export interface NightRevenue {
  day: Day
  roomTypeId: number
  planId: number
  roomNights: number
  revenue: bigint
}
export const ROLES: Role[] = ['owner', 'revenue', 'frontDesk', 'auditor', 'housekeeping']

/** One role held by one person: `subject` is the hex of their principal, the id they send the owner. */
export interface StaffRow { grantId: number; subject: string; role: Role; mine: boolean; automatic: boolean; since: number }

export class Refused extends Error {
  kind: string
  reason: Bi
  constructor(kind: string, reason: Bi) {
    super(reason.en)
    this.kind = kind
    this.reason = reason
  }
}

/** The amenities a room type can have, in the order of their bits in the contract's mask (frozen: a new one goes last). */
export const AMENITIES = ['balcony', 'terrace', 'seaView', 'gardenView', 'plungePool', 'privatePool', 'bath', 'rainShower', 'outdoorShower',
  'kitchen', 'lounge', 'wifi', 'aircon', 'espresso', 'nileView', 'courtyard', 'workDesk'] as const
export const amenityMask = (names: readonly string[]) => AMENITIES.reduce((m, a, i) => (names.includes(a) ? m | (1 << i) : m), 0)
export const amenitiesOf = (mask: number) => AMENITIES.filter((_, i) => mask & (1 << i)) as string[]

/**
 * SETUP: each record as the owner edits it, every field its setup act takes (Setup.mo). These are the
 * console's own reads: inactive records included, so what is off sale can be put back on.
 */
export interface SetupProperty {
  name: Bi; currency: string; minorUnits: number; checkInText: string; checkOutText: string
  /** How long a hold lasts, in blocks, and how many blocks the chain makes a minute: together, the hold in real time. */
  holdTtlHeights: number; heightsPerRealMinute: number
  maxStayNights: number; horizonDays: number; maxRoomsPerBooking: number; idRetentionDays: number
}
export interface SetupRoomType {
  id: number; code: string; name: Bi; desc: Bi; sizeSqm: number; maxAdults: number; maxChildren: number; maxOccupancy: number
  bedKind: BedKind; bedCount: number; amenities: string[]
  /** The photograph set, by its slot name in the media credits ('' for none). */
  photos: string
  rank: number; active: boolean
  /** Rooms of this type in service (read only: rooms are their own records). */
  rooms: number
}
export type SetupRoomTypeEdit = Omit<SetupRoomType, 'id' | 'rooms'>
export interface SetupPlan {
  id: number; code: string; name: Bi; discountBps: number; refundable: boolean; freeCancelDaysBefore: number; penaltyNights: number
  prepaid: boolean; modifiable: boolean; active: boolean
  /** The plan's guarantee; a deposit is set apart from the plan, with its share (`setPlanDeposit`). */
  guarantee?: Guarantee; depositBps?: number
}
export type TaxKindSetting = 'percent' | 'perRoomNight' | 'perStay'
export interface SetupTax {
  id: number; code: string; name: Bi; kind: TaxKindSetting; bps: number; amount: bigint; onPriorTaxes: boolean; rank: number; active: boolean
}

export interface Api {
  source: 'demo' | 'chain'
  property(): Promise<PropertyView>
  roomTypes(): Promise<RoomTypeView[]>
  /** The plans on public sale, and those a rate code opens when one is given. */
  plans(code?: string): Promise<PlanView[]>
  /** Every active plan, closed ones included, for the console's grids and reports (staff). */
  staffPlans(): Promise<PlanView[]>
  /** What a rate code opens, or why it opens nothing. */
  codeInfo(code: string): Promise<CodeView>
  calendar(roomTypeId: number | 0, from: Day, days: number): Promise<CalendarDay[]>
  search(req: StayRequest): Promise<SearchResult>
  quoteDetail(roomTypeId: number, planId: number, req: StayRequest): Promise<QuoteDetail>
  placeHold(roomTypeId: number, planId: number, req: StayRequest, quoteHash: string): Promise<HoldView>
  releaseHold(holdId: number): Promise<void>
  /** `keepOnFile`: the guest agreed to keep the card on file; the gateway keeps it and the hotel holds only its token. */
  authorise(scenario: TestScenario, amount: bigint, ref: number, keepOnFile?: boolean): Promise<AuthResult>
  confirmHold(holdId: number, guest: GuestDetails, authId: number, session?: string): Promise<ConfirmResult>
  /** How this hotel knows who a guest or a member of staff is: passkeys, a Thebes subnet's key, or the demo. */
  identity(): Promise<'memphis' | 'transportKey' | 'demo'>
  openSession(session: string): Promise<void>
  myStays(session: string): Promise<BookingView[]>
  myWaitlist(session: string): Promise<WaitView[]>
  joinWaitlist(session: string, roomTypeId: number, req: StayRequest): Promise<number>
  leaveWaitlist(session: string, entryId: number): Promise<void>
  manage(ref: string, secret: string): Promise<BookingView>
  cancel(ref: string, secret: string): Promise<CancelResult>
  /** The booking's card on file, read with its link (null: the booking keeps no card). */
  manageCard(ref: string, secret: string): Promise<CardView | null>
  /** The card link of a booking taken by phone: the guarantee authorised on a card the guest agreed to keep on file. */
  putCardOnFile(ref: string, secret: string, authId: number): Promise<void>
  /** The desk's card list for a day: unguaranteed bookings, declined no-show charges, cards the gateway would not delete. */
  cardDesk(day: Day): Promise<CardDeskRow[]>
  /** Whether the hotel keeps guests' cards on file for rates guaranteed by the first night or a deposit. */
  cardRule(): Promise<boolean>
  /** Turns the card rule on (the owner; once). */
  requireCardOnFile(): Promise<void>
  /** The rules the hotel's books are kept under (the night audit's checks), and the newest this build knows. */
  rules(): Promise<RulesView>
  /** The owner moves the books to the next rules; refused unless it is exactly the next and this build knows it. */
  adoptRules(epoch: number): Promise<void>
  /** Guest email: the booking's messages read with its link, and the address given from it (sealed to the relay). */
  manageMail(ref: string, secret: string): Promise<{ rows: MailRow[]; connected: boolean }>
  attachMailFromLink(ref: string, secret: string, email: string, lang: 'en' | 'ar'): Promise<void>
  /** A booking's messages as staff read them. */
  bookingMail(bookingId: number): Promise<MailRow[]>
  /** The console's Guest email screen: the state on chain, and each step of connecting the hotel's own account. */
  mailSetup(): Promise<MailSetupView>
  connectMailRelay(): Promise<void>
  mailProviders(): Promise<MailProviderView[]>
  /** Sealed in this browser to the relay's transport key, then sent to the relay; the answer is the digest to approve. */
  saveMailAccount(account: MailAccount): Promise<MailAccountSaved>
  /** Google or Microsoft: where to send the owner to sign in; they come back to the console with the digest. */
  startMailSignIn(account: Omit<MailAccount, 'fields'>): Promise<string>
  approveMailAccount(digest: string): Promise<void>
  mailAccountInUse(): Promise<MailAccountInUse>
  checkMailDomain(domain: string, provider: MailProvider, selector: string): Promise<DnsCheckView>
  sendMailTest(digest: string): Promise<MailTestResult>
  setGuestEmail(on: boolean): Promise<void>
  /** A deposit plan's share in basis points, a whole percentage from 1% to 99% (0 takes a deposit plan back to the first night). */
  setPlanDeposit(planId: number, bps: number): Promise<void>
  seal(): Promise<SealView>
  grid(from: Day, days: number): Promise<GridRow[]>
  setNights(edit: NightsEdit): Promise<number>
  /** Several edits saved together, all or nothing: room types side by side, a percentage, an undo. */
  setNightsMany(edits: ManyEdit[]): Promise<number>
  /** The front desk: today's arrivals, the guests in house, the rooms free to give. */
  arrivals(day: Day): Promise<DeskRow[]>
  inHouse(): Promise<DeskRow[]>
  /** The vacant rooms of a type, readiest first: inspected, clean, not recorded, dirty. */
  vacantRooms(roomTypeId: number): Promise<VacantRoom[]>
  checkIn(bookingId: number, roomIds: number[]): Promise<void>
  /** Moves a guest in house from one room of their booking to a free room of the same type; the room they leave is dirty. */
  moveRoom(bookingId: number, fromRoomId: number, toRoomId: number): Promise<void>
  checkOut(bookingId: number): Promise<void>
  /** What is left to pay, taken at the desk: a TEST gateway authorisation for exactly that amount, against the booking's reference. */
  settleAtDesk(bookingId: number, authId: number): Promise<void>
  /** Every booking, newest first, a page at a time; `next` is where the following page starts. */
  bookings(beforeId: number, limit: number): Promise<{ rows: BookingView[]; next: number | null }>
  /** Bookings by arrival window and status, in arrival order, a page at a time: `next` resumes, null when done. */
  bookingsFiltered(q: BookingQuery, cursor: string, limit: number): Promise<{ rows: BookingView[]; next: string | null }>
  /** The booking a reference names, or null. */
  bookingByRef(ref: string): Promise<BookingView | null>
  /** A booking's folio lines, payments, and the acts that touched it (newest first, `more` resumes lower down). */
  folio(bookingId: number): Promise<FolioLineView[]>
  payments(bookingId: number): Promise<PaymentView[]>
  history(bookingId: number, beforeBlock: number): Promise<{ acts: HistoryAct[]; more: number | null }>
  /** The night audit for the business day: open it, advance it a bounded step at a time, close it. */
  auditStatus(day: Day): Promise<AuditStatus>
  openAudit(day: Day): Promise<void>
  advanceAudit(day: Day): Promise<AuditStatus>
  closeDay(day: Day): Promise<Day>
  /** The hotel clock and the night audit that runs by itself at a local time. */
  hotelClock(): Promise<HotelClock>
  setHotelClock(c: HotelClockSetting): Promise<void>
  /** Housekeeping: the board of every room, and the three acts on a room. */
  housekeeping(): Promise<BoardRoom[]>
  markRoom(roomId: number, cleaning: Cleaning): Promise<void>
  takeRoomOutOfOrder(roomId: number, reason: string, untilDay: Day): Promise<void>
  returnRoomToService(roomId: number): Promise<void>
  /** The bill: the extras catalogue, a booking's bill by payer, charges, payers, moves, shares and invoices. */
  extras(): Promise<ExtraView[]>
  /** A plan's package: what the rate includes, read by everyone (the guest site shows it under the plan). */
  packageOf(planId: number): Promise<InclusionView[]>
  /** The owner sets a plan's package whole; an empty list makes it a plain rate again. */
  setPlanInclusions(planId: number, inclusions: InclusionSetting[]): Promise<void>
  upsertExtra(id: number, e: Omit<ExtraView, 'id'>): Promise<number>
  bill(bookingId: number): Promise<BillView>
  postCharge(bookingId: number, extraId: number, quantity: number, amount: bigint, payerId: number): Promise<void>
  addPayer(bookingId: number, name: string): Promise<number>
  routeLines(bookingId: number, lineIds: number[], payerId: number): Promise<void>
  settleShare(bookingId: number, payerId: number, authId: number): Promise<void>
  issueInvoice(bookingId: number, payerId: number): Promise<number>
  invoice(number: number): Promise<InvoiceView | null>
  /** Credit notes: those of a booking, one as printed, its tax-authority document, and how much of each line notes took back. */
  creditNotes(bookingId: number): Promise<CreditNoteRow[]>
  creditNote(number: number): Promise<CreditNoteView | null>
  creditNoteEta(number: number): Promise<CreditNoteEta | null>
  creditedLines(bookingId: number): Promise<Map<number, bigint>>
  /** Proposed by one member of staff, approved by another under Approvals. `amounts` are before tax, in the order of `lineIds`. */
  proposeCreditNote(bookingId: number, invoice: number, lineIds: number[], amounts: bigint[], justification: string): Promise<number>
  /** A refund the gateway would not make, recorded as paid at the desk; approved by a second member of staff. */
  proposeDeskRefund(bookingId: number, paymentId: number, method: DeskMethod, reference: string, justification: string): Promise<number>
  deskRefunds(bookingId: number): Promise<DeskRefundView[]>
  /** Every refund of a booking, in the order written. */
  refunds(bookingId: number): Promise<RefundView[]>
  /** Where a credit note's refund went: the slices its approval wrote across the guest's cards (none for a note on another payer's bill). */
  creditNoteRefund(number: number): Promise<RefundView[]>
  /**
   * A booking taken for a guest on the phone or at the desk, at an offer's price: no card, paid at the desk
   * or later. A walk-in arrives today and is checked in to `roomIds` in the same act. The manage link's
   * secret is made here, to give the guest; the email, if given, is sealed here.
   */
  bookByStaff(channel: Channel, offer: Pick<Offer, 'roomTypeId' | 'planId' | 'quoteHash'>, req: StayRequest, guest: StaffGuest, roomIds: number[]): Promise<StaffBookResult>
  /** How a booking came when staff took it; null for a booking a guest made online. */
  staffBooking(bookingId: number): Promise<StaffBookingView | null>
  /** The audited days' figures from `fromDay`, at most 62 days (owner, revenue, auditor). */
  dayFigures(fromDay: Day, days: number): Promise<DayFiguresView[]>
  /** The audited nights' room nights and revenue by room type and plan, from `fromDay`, at most 62. */
  dayRevenue(fromDay: Day, days: number): Promise<NightRevenue[]>
  /** What is on the books for the nights from `fromDay`, at most 62: by night, room type and plan. */
  onTheBooks(fromDay: Day, days: number): Promise<NightRevenue[]>
  /** The tax authority's codes: the hotel's registration and each tax's type and sub-type. The owner's. */
  etaProfile(): Promise<EtaProfile>
  setEtaProfile(p: EtaProfile): Promise<void>
  taxEta(): Promise<TaxEta[]>
  setTaxEta(taxRuleId: number, taxType: string, subType: string): Promise<void>
  /** Acts that need a second member of staff. */
  proposals(): Promise<ProposalView[]>
  propose(act: DualAct, bookingId: number, amount: bigint, text: string, justification: string): Promise<number>
  approve(id: number): Promise<void>
  reject(id: number, reason: string): Promise<void>
  /** The staff: who holds which role, the roles of the person signed in, their own id, and the owner's two acts. */
  staff(): Promise<StaffRow[]>
  myRoles(): Promise<Role[]>
  myId(): Promise<string>
  grantRole(subject: string, role: Role): Promise<void>
  revokeRole(subject: string, role: Role): Promise<void>
  /** Setup: the hotel, its room types, rooms, rate plans and taxes, read and written as the owner edits them. */
  setupProperty(): Promise<SetupProperty | null>
  configureProperty(p: SetupProperty): Promise<void>
  setupRoomTypes(): Promise<SetupRoomType[]>
  upsertRoomType(id: number, t: SetupRoomTypeEdit): Promise<number>
  /** A room by its number, its type, and whether it is out of order (a new room has id 0). */
  upsertRoom(id: number, roomTypeId: number, number: string, outOfOrder: boolean): Promise<number>
  /** Rate products: companies with negotiated rates, and who each plan is sold to (owner, revenue). */
  companies(): Promise<CompanyView[]>
  upsertCompany(id: number, c: Omit<CompanyView, 'id'>): Promise<number>
  planAccess(): Promise<PlanAccessView[]>
  setPlanAccess(planId: number, companyId: number, closed: boolean): Promise<void>
  /** Promotions: their codes, windows and the uses each has counted (owner, revenue). */
  promos(): Promise<PromoView[]>
  upsertPromo(id: number, p: PromoFacts): Promise<number>
  /** Group blocks (revenue makes, changes and releases them; the desk picks guests up from them). */
  blocks(): Promise<BlockView[]>
  upsertBlock(id: number, f: BlockFacts): Promise<number>
  releaseBlock(id: number): Promise<void>
  blockNights(id: number): Promise<BlockNightView[]>
  roomingList(id: number): Promise<RoomingRow[]>
  /** The price of a pickup from a block: the block's room type and plan for these nights, at its company's rate. */
  blockQuote(id: number, req: StayRequest): Promise<Offer>
  pickUp(blockId: number, offer: Pick<Offer, 'quoteHash'>, req: StayRequest, guest: StaffGuest): Promise<StaffBookResult>
  setupPlans(): Promise<SetupPlan[]>
  upsertRatePlan(id: number, p: Omit<SetupPlan, 'id'>): Promise<number>
  setupTaxes(): Promise<SetupTax[]>
  upsertTaxRule(id: number, t: Omit<SetupTax, 'id'>): Promise<number>
  /** An identity document at check-in: encrypted in this browser, filed against the booking. */
  captureId(bookingId: number, file: Blob): Promise<void>
  idDocuments(bookingId: number): Promise<IdDocumentView[]>
}

export interface BookingQuery { status: BookingStatus | ''; from: Day; to: Day }
export interface FolioLineView { id: number; kind: 'roomNight' | 'tax' | 'penalty' | 'credit' | 'adjustment' | 'extra' | 'extraTax'; night: Day; amount: bigint; block: number }
export interface PaymentView { id: number; kind: 'authorised' | 'captured' | 'refunded' | 'voided' | 'chargedOnFile'; state: 'due' | 'done' | 'failed'; amount: bigint; gatewayAuth: number; attempts: number; block: number }
/** One act on a booking: the block it is in, the business day, and the command (a proposal as `propose:<act>`). */
export interface HistoryAct { block: number; day: Day; act: string }
