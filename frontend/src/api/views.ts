/**
 * The three queries behind the results page: their arguments and the fields read from each reply.
 * The chain data source and the early-data script both use these, so an early reply is for exactly
 * the bytes the app would have sent.
 */
import { f, nat, type Arg, type Field } from './wire'
import type { StayRequest } from './types'

export const ROOM_TYPE_FIELDS: Field[] = [f('id'), f('code', 'text'), f('nameEn', 'text'), f('nameAr', 'text'), f('descEn', 'text'), f('descAr', 'text'),
  f('sizeSqm'), f('maxAdults'), f('maxChildren'), f('maxOccupancy'), f('bedKind', 'text'), f('bedCount'), f('amenities'), f('photos', 'text'), f('rooms'), f('active', 'bool')]

export const PLAN_FIELDS: Field[] = [f('id'), f('code', 'text'), f('nameEn', 'text'), f('nameAr', 'text'), f('refundable', 'bool'), f('freeCancelDaysBefore'),
  f('penaltyNights'), f('prepaid', 'bool'), f('discountBps'), f('active', 'bool'), f('guarantee', 'text'), f('depositBps'), f('keepsCard', 'bool')]

export const SEARCH_FIELDS: Field[] = [f('roomTypeId'), f('planId'), f('ok', 'bool'), f('kind', 'text'), f('reason', 'text'), f('total'), f('roomSubtotal'),
  f('taxTotal'), f('packageTotal'), f('left'), f('cancelDeadline'), f('refundable', 'bool'), f('guarantee'), f('quoteHash', 'text'), f('atBlock')]

export function searchArgs(req: StayRequest): Arg[] {
  return [nat(req.arrival), nat(req.nights), nat(req.rooms), nat(req.adults), nat(req.children)]
}
