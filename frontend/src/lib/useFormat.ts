import { useCallback } from 'react'
import { useApp } from '../app'
import { formatMoney } from './money'
import { toDate, type Day } from './days'

/** Money and dates in the property's currency and the reader's language. */
export function useFormat() {
  const { tenant, locale } = useApp()
  const money = useCallback(
    (amount: bigint, opts?: { whole?: boolean }) => formatMoney(amount, tenant.currency, tenant.minorUnits, locale, opts),
    [tenant, locale],
  )
  const day = useCallback(
    (d: Day, style: 'short' | 'long' | 'weekday' | 'month' = 'short') => {
      const o: Intl.DateTimeFormatOptions =
        style === 'long' ? { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' }
        : style === 'weekday' ? { weekday: 'short', day: 'numeric', month: 'short' }
        : style === 'month' ? { month: 'long', year: 'numeric' }
        : { day: 'numeric', month: 'short' }
      return new Intl.DateTimeFormat(locale, { ...o, timeZone: 'UTC' }).format(toDate(d))
    },
    [locale],
  )
  const num = useCallback((n: number) => new Intl.NumberFormat(locale).format(n), [locale])
  return { money, day, num }
}
