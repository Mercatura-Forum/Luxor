import type { Offer, PlanView } from '../api/types'
import type { Day } from '../lib/days'
import type { dict } from '../i18n'

type T = (key: keyof typeof dict, vars?: Record<string, string | number>) => string

/** The cancellation terms of an offer in one plain sentence, with the date and the fee in it. */
export function policyText(plan: PlanView, offer: Offer, t: T, money: (a: bigint) => string, day: (d: Day, s?: 'weekday') => string): string {
  if (plan.guarantee === 'deposit') {
    return plan.refundable && offer.cancelDeadline !== null
      ? t('pay.depositFreeUntil', { deposit: money(offer.guarantee), day: day(offer.cancelDeadline, 'weekday'), nights: Math.max(1, plan.penaltyNights) })
      : t('pay.depositNoRefund', { deposit: money(offer.guarantee) })
  }
  if (plan.refundable && offer.cancelDeadline !== null) {
    return t('pay.freeUntil', { day: day(offer.cancelDeadline, 'weekday'), fee: money(offer.guarantee) })
  }
  return t('pay.noRefund', { fee: money(offer.total) })
}
