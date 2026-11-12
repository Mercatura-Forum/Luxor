/**
 * Money is a count of the currency's minor units, carried as a bigint from the contract to the
 * screen. Formatting is arithmetic: the decimal string is built from the integer with the sign kept,
 * and only then handed to Intl, so −0.50 stays negative and no float ever holds an amount.
 */
export type Minor = bigint

export function toDecimalString(amount: Minor, minorUnits: number): string {
  const neg = amount < 0n
  const abs = neg ? -amount : amount
  const scale = 10n ** BigInt(minorUnits)
  const whole = abs / scale
  const frac = abs % scale
  const body = minorUnits === 0 ? whole.toString() : `${whole}.${frac.toString().padStart(minorUnits, '0')}`
  return neg ? `-${body}` : body
}

export function formatMoney(
  amount: Minor,
  currency: string,
  minorUnits: number,
  locale: string,
  opts: { whole?: boolean } = {},
): string {
  const whole = opts.whole && amount % 10n ** BigInt(minorUnits) === 0n
  const fmt = new Intl.NumberFormat(locale, {
    style: 'currency',
    currency,
    minimumFractionDigits: whole ? 0 : minorUnits,
    maximumFractionDigits: whole ? 0 : minorUnits,
  })
  // Intl accepts an exact decimal string; the amount never passes through a float
  return fmt.format(toDecimalString(amount, minorUnits) as unknown as number)
}

/** An amount typed by a person ("12.50", "12,5", "12"), in minor units, or null if it does not read as
 *  one with at most `minorUnits` decimals. */
export function parseMoney(text: string, minorUnits: number): bigint | null {
  const m = /^(\d{1,15})(?:[.,](\d+))?$/.exec(text.trim())
  if (!m) return null
  const frac = m[2] ?? ''
  if (frac.length > minorUnits) return null
  return BigInt(m[1]) * 10n ** BigInt(minorUnits) + BigInt((frac || '0').padEnd(minorUnits, '0') || '0')
}
