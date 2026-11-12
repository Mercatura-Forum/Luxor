/**
 * The two demo properties. A property is its tokens (src/index.css, keyed by `data-tenant`), its
 * words, its photographs and its inventory. The second property exists to prove the white-label:
 * the same screens, a different house.
 */
import type { Bi, BedKind } from '../api/types'
import type { TaxRule } from '../api/quote'

export type TenantId = 'almar' | 'karnak'

export interface RoomSeed {
  code: string
  slot: string
  name: Bi
  desc: Bi
  view: Bi
  sizeSqm: number
  maxAdults: number
  maxChildren: number
  maxOccupancy: number
  bedKind: BedKind
  bedCount: number
  amenities: string[]
  rooms: number
  bar: number // minor units, a weekday in the shoulder season
  minStayWeekend: number
}

export interface Tenant {
  id: TenantId
  name: Bi
  place: Bi
  currency: string
  minorUnits: number
  locale: { en: string; ar: string }
  hero: { slot: string; kicker: Bi; title: Bi; body: Bi }
  story: { title: Bi; body: Bi; slot: string }
  facts: Bi[]
  checkIn: Bi
  checkOut: Bi
  address: Bi
  phone: string
  email: string
  freeCancelDays: number
  nonRefundableBps: number
  taxes: TaxRule[]
  rooms: RoomSeed[]
}

export const AMENITY: Record<string, Bi> = {
  balcony: { en: 'Balcony', ar: 'شرفة' },
  terrace: { en: 'Private terrace', ar: 'تراس خاص' },
  seaView: { en: 'Sea view', ar: 'إطلالة على البحر' },
  gardenView: { en: 'Garden view', ar: 'إطلالة على الحديقة' },
  plungePool: { en: 'Plunge pool', ar: 'مسبح صغير خاص' },
  privatePool: { en: 'Private pool', ar: 'مسبح خاص' },
  bath: { en: 'Deep bath', ar: 'حوض استحمام عميق' },
  rainShower: { en: 'Rain shower', ar: 'دُش مطري' },
  outdoorShower: { en: 'Outdoor shower', ar: 'دُش خارجي' },
  kitchen: { en: 'Kitchen', ar: 'مطبخ' },
  lounge: { en: 'Sitting room', ar: 'غرفة جلوس' },
  wifi: { en: 'Fast wifi', ar: 'واي فاي سريع' },
  aircon: { en: 'Air conditioning', ar: 'تكييف' },
  espresso: { en: 'Espresso machine', ar: 'آلة إسبريسو' },
  nileView: { en: 'Nile view', ar: 'إطلالة على النيل' },
  courtyard: { en: 'Courtyard view', ar: 'إطلالة على الفناء' },
  workDesk: { en: 'Writing desk', ar: 'مكتب للكتابة' },
}

export const TENANTS: Record<TenantId, Tenant> = {
  almar: {
    id: 'almar',
    name: { en: 'Almar', ar: 'الـمار' },
    place: { en: 'Cala Verde', ar: 'كالا ڤيردي' },
    currency: 'EUR',
    minorUnits: 2,
    locale: { en: 'en-GB', ar: 'ar' },
    hero: {
      slot: 'almar/bay-1',
      kicker: { en: 'Cala Verde, on the bay', ar: 'كالا ڤيردي، على الخليج' },
      title: { en: 'A quiet bay, kept for you.', ar: 'خليجٌ هادئ، محفوظٌ لك.' },
      body: {
        en: 'Twenty-four rooms, suites and villas in the pines above a private cove. The sea is two minutes from your door.',
        ar: 'أربعٌ وعشرون غرفةً وجناحاً وفيلا بين الصنوبر فوق خليجٍ خاص. البحر على بُعد دقيقتين من بابك.',
      },
    },
    story: {
      slot: 'almar/pool-1',
      title: { en: 'One restaurant, one pool, one path to the water', ar: 'مطعمٌ واحد، ومسبحٌ واحد، وممرٌّ واحد إلى الماء' },
      body: {
        en: 'The same family has run Almar since 1996. Dinner follows the market and the boats that tie up below. The terrace doors are rarely closed.',
        ar: 'تدير العائلة نفسها الـمار منذ 1996. العشاء يتبع السوق والقوارب التي ترسو في الأسفل، وأبواب الشرفة نادراً ما تُغلق.',
      },
    },
    facts: [
      { en: 'Family-run since 1996', ar: 'بإدارة عائلية منذ 1996' },
      { en: '24 rooms, suites and villas', ar: '24 غرفة وجناحاً وفيلا' },
      { en: 'Two minutes to the water', ar: 'دقيقتان إلى الماء' },
    ],
    checkIn: { en: 'Check-in from 15:00', ar: 'تسجيل الوصول من الساعة 15:00' },
    checkOut: { en: 'Check-out by 11:00', ar: 'المغادرة قبل الساعة 11:00' },
    address: { en: 'Bahía de Almar, Cala Verde', ar: 'خليج الـمار، كالا ڤيردي' },
    phone: '+34 971 30 88 40',
    email: 'stay@almar.example',
    freeCancelDays: 3,
    nonRefundableBps: 1500,
    taxes: [
      { id: 1, code: 'IVA', name: { en: 'VAT (10%)', ar: 'ضريبة القيمة المضافة (10%)' }, kind: 'percent', bps: 1000, amount: 0n, base: 'room', rank: 1 },
      { id: 2, code: 'TOURIST', name: { en: 'Tourist tax', ar: 'ضريبة السياحة' }, kind: 'perRoomNight', bps: 0, amount: 220n, base: 'room', rank: 2 },
    ],
    rooms: [
      {
        code: 'GARDEN', slot: 'almar/garden-room',
        name: { en: 'Garden Room', ar: 'غرفة الحديقة' },
        desc: { en: 'A calm ground-floor room onto the herb garden, with a deep bath and a shaded terrace.', ar: 'غرفةٌ هادئة في الطابق الأرضي تطلّ على حديقة الأعشاب، مع حوضٍ عميق وتراسٍ مظلَّل.' },
        view: { en: 'Garden view', ar: 'إطلالة على الحديقة' },
        sizeSqm: 38, maxAdults: 2, maxChildren: 1, maxOccupancy: 3, bedKind: 'queen', bedCount: 1,
        amenities: ['terrace', 'gardenView', 'bath', 'aircon', 'wifi'], rooms: 6, bar: 18000, minStayWeekend: 1,
      },
      {
        code: 'SEA', slot: 'almar/sea-room',
        name: { en: 'Sea-View Room', ar: 'غرفة بإطلالة على البحر' },
        desc: { en: 'A bright room above the bay, with a balcony that catches the morning light off the water.', ar: 'غرفةٌ مشرقة فوق الخليج، بشرفةٍ تلتقط ضوء الصباح المنعكس عن الماء.' },
        view: { en: 'Sea view', ar: 'إطلالة على البحر' },
        sizeSqm: 42, maxAdults: 2, maxChildren: 1, maxOccupancy: 3, bedKind: 'king', bedCount: 1,
        amenities: ['balcony', 'seaView', 'rainShower', 'aircon', 'wifi'], rooms: 8, bar: 24000, minStayWeekend: 2,
      },
      {
        code: 'JUNIOR', slot: 'almar/junior-suite',
        name: { en: 'Junior Suite', ar: 'جناح جونيور' },
        desc: { en: 'A corner suite with a sitting area, a wide balcony over the water and a marble bath for two.', ar: 'جناحٌ في الزاوية بمنطقة جلوس، وشرفةٍ واسعة فوق الماء، وحمّامٍ رخاميّ لشخصين.' },
        view: { en: 'Sea view', ar: 'إطلالة على البحر' },
        sizeSqm: 64, maxAdults: 3, maxChildren: 1, maxOccupancy: 3, bedKind: 'king', bedCount: 1,
        amenities: ['balcony', 'seaView', 'lounge', 'bath', 'espresso', 'wifi'], rooms: 4, bar: 36000, minStayWeekend: 2,
      },
      {
        code: 'POOL', slot: 'almar/pool-suite',
        name: { en: 'Pool Suite', ar: 'جناح المسبح' },
        desc: { en: 'Steps from your terrace into a private plunge pool, screened by olive trees and quiet all day.', ar: 'خطواتٌ من تراسك إلى مسبحٍ صغير خاص، تحجبه أشجار الزيتون ويبقى هادئاً طوال اليوم.' },
        view: { en: 'Garden and pool', ar: 'الحديقة والمسبح' },
        sizeSqm: 70, maxAdults: 3, maxChildren: 1, maxOccupancy: 3, bedKind: 'king', bedCount: 1,
        amenities: ['terrace', 'plungePool', 'gardenView', 'outdoorShower', 'espresso', 'wifi'], rooms: 3, bar: 42000, minStayWeekend: 2,
      },
      {
        code: 'TERRACE', slot: 'almar/terrace-suite',
        name: { en: 'Terrace Suite', ar: 'جناح التراس' },
        desc: { en: 'The top-floor suite, wrapped in a sea-facing terrace with a daybed, an outdoor shower and the best sunset on the bay.', ar: 'جناح الطابق العلوي، يحيط به تراسٌ مطلّ على البحر بسريرٍ نهاري ودُشٍّ خارجي وأجمل غروبٍ على الخليج.' },
        view: { en: 'Sea view', ar: 'إطلالة على البحر' },
        sizeSqm: 96, maxAdults: 4, maxChildren: 2, maxOccupancy: 4, bedKind: 'king', bedCount: 1,
        amenities: ['terrace', 'seaView', 'lounge', 'outdoorShower', 'bath', 'espresso'], rooms: 2, bar: 52000, minStayWeekend: 3,
      },
      {
        code: 'VILLA', slot: 'almar/bay-villa',
        name: { en: 'Bay Villa', ar: 'فيلا الخليج' },
        desc: { en: 'Two bedrooms at the quiet end of the bay, with its own pool, a kitchen and a path down to the water.', ar: 'غرفتا نوم في الطرف الهادئ من الخليج، مع مسبحٍ خاص ومطبخ وممرٍّ ينزل إلى الماء.' },
        view: { en: 'Sea view', ar: 'إطلالة على البحر' },
        sizeSqm: 160, maxAdults: 6, maxChildren: 3, maxOccupancy: 6, bedKind: 'king', bedCount: 2,
        amenities: ['privatePool', 'kitchen', 'seaView', 'lounge', 'terrace', 'wifi'], rooms: 1, bar: 88000, minStayWeekend: 3,
      },
    ],
  },
  karnak: {
    id: 'karnak',
    name: { en: 'Karnak House', ar: 'بيت الكرنك' },
    place: { en: 'Luxor', ar: 'الأقصر' },
    currency: 'EGP',
    minorUnits: 2,
    locale: { en: 'en-GB', ar: 'ar-EG' },
    hero: {
      slot: 'karnak/hero-1',
      kicker: { en: 'Luxor, on the east bank', ar: 'الأقصر، على الضفة الشرقية' },
      title: { en: 'Twelve rooms between the temple and the Nile.', ar: 'اثنتا عشرة غرفة بين المعبد والنيل.' },
      body: {
        en: 'A 1920s merchant house, restored around its courtyard. Karnak Temple is a ten-minute walk; the felucca landing is at the end of the street.',
        ar: 'بيتُ تاجرٍ من عشرينيات القرن الماضي، رُمِّم حول فنائه. معبد الكرنك على بُعد عشر دقائق سيراً، ومرسى الفلوكة في آخر الشارع.',
      },
    },
    story: {
      slot: 'karnak/courtyard-1',
      title: { en: 'Breakfast in the courtyard, dinner on the roof', ar: 'الفطور في الفناء، والعشاء على السطح' },
      body: {
        en: 'The kitchen bakes its own bread each morning. At dusk the roof looks across the river to the west bank hills.',
        ar: 'يخبز المطبخ خبزه كل صباح. وعند الغروب يطلّ السطح عبر النهر على تلال البرّ الغربي.',
      },
    },
    facts: [
      { en: 'Restored in 2019', ar: 'رُمِّم في 2019' },
      { en: '12 rooms and suites', ar: '12 غرفة وجناحاً' },
      { en: '10 minutes to Karnak Temple', ar: '10 دقائق إلى معبد الكرنك' },
    ],
    checkIn: { en: 'Check-in from 14:00', ar: 'تسجيل الوصول من الساعة 14:00' },
    checkOut: { en: 'Check-out by 12:00', ar: 'المغادرة قبل الساعة 12:00' },
    address: { en: 'Sharia al-Karnak, Luxor', ar: 'شارع الكرنك، الأقصر' },
    phone: '+20 95 237 0418',
    email: 'stay@karnakhouse.example',
    freeCancelDays: 2,
    nonRefundableBps: 1200,
    taxes: [
      { id: 1, code: 'SERVICE', name: { en: 'Service charge (12%)', ar: 'رسوم الخدمة (12%)' }, kind: 'percent', bps: 1200, amount: 0n, base: 'room', rank: 1 },
      { id: 2, code: 'VAT', name: { en: 'VAT (14%)', ar: 'ضريبة القيمة المضافة (14%)' }, kind: 'percent', bps: 1400, amount: 0n, base: 'roomAndPriorTaxes', rank: 2 },
    ],
    rooms: [
      {
        code: 'COURT', slot: 'karnak/courtyard-room',
        name: { en: 'Courtyard Room', ar: 'غرفة الفناء' },
        desc: { en: 'Arched windows onto the lemon trees of the courtyard, cool tiled floors and a writing desk.', ar: 'نوافذ مقوّسة تطلّ على أشجار الليمون في الفناء، وأرضيةٌ من البلاط البارد، ومكتبٌ للكتابة.' },
        view: { en: 'Courtyard view', ar: 'إطلالة على الفناء' },
        sizeSqm: 30, maxAdults: 2, maxChildren: 1, maxOccupancy: 3, bedKind: 'queen', bedCount: 1,
        amenities: ['courtyard', 'workDesk', 'rainShower', 'aircon', 'wifi'], rooms: 6, bar: 520000, minStayWeekend: 1,
      },
      {
        code: 'NILE', slot: 'karnak/nile-room',
        name: { en: 'Nile Room', ar: 'غرفة النيل' },
        desc: { en: 'Upstairs, with a balcony over the street to the river and the west bank beyond.', ar: 'في الطابق العلوي، بشرفةٍ فوق الشارع تطلّ على النهر والبرّ الغربي خلفه.' },
        view: { en: 'Nile view', ar: 'إطلالة على النيل' },
        sizeSqm: 34, maxAdults: 2, maxChildren: 1, maxOccupancy: 3, bedKind: 'king', bedCount: 1,
        amenities: ['balcony', 'nileView', 'rainShower', 'aircon', 'wifi'], rooms: 4, bar: 680000, minStayWeekend: 2,
      },
      {
        code: 'RIVER', slot: 'karnak/river-suite',
        name: { en: 'River Suite', ar: 'جناح النهر' },
        desc: { en: 'The corner suite under the roof: a sitting room, a deep bath and windows on two sides of the river.', ar: 'جناح الزاوية تحت السطح: غرفة جلوس، وحوضٌ عميق، ونوافذ على جهتين من النهر.' },
        view: { en: 'Nile view', ar: 'إطلالة على النيل' },
        sizeSqm: 58, maxAdults: 3, maxChildren: 1, maxOccupancy: 3, bedKind: 'king', bedCount: 1,
        amenities: ['nileView', 'lounge', 'bath', 'espresso', 'aircon', 'wifi'], rooms: 2, bar: 1240000, minStayWeekend: 2,
      },
    ],
  },
}

/** An amenity's name in both languages; a key this list does not know is shown as itself. */
export const amenityLabel = (key: string): Bi => AMENITY[key] ?? { en: key, ar: key }
