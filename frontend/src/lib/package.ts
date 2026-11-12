/**
 * A package in plain words, as the guest site and the console say it: each inclusion with how many, for
 * whom and when ("Breakfast for each guest, every night"), and the inclusions together as a list in the
 * reader's language ("breakfast and airport transfer").
 */
import type { Bi, InclusionView } from '../api/types'
import type { dict } from '../i18n'

type T = (key: keyof typeof dict, vars?: Record<string, string | number>) => string

export function inclusionText(inc: Pick<InclusionView, 'name' | 'quantity' | 'rhythm' | 'per'>, t: T, tr: (b: Bi) => string, num: (n: number) => string): string {
  const what = inc.quantity === 1 ? tr(inc.name) : t('pkg.times', { n: num(inc.quantity), name: tr(inc.name) })
  return t('pkg.item', { what, per: t(`pkg.per.${inc.per}`), when: t(`pkg.when.${inc.rhythm}`) })
}

/** The inclusions' names as one list in the reader's language. */
export function itemsText(incs: Pick<InclusionView, 'name'>[], tr: (b: Bi) => string, locale: string): string {
  const names = incs.map((x) => tr(x.name))
  try { return new Intl.ListFormat(locale, { style: 'long', type: 'conjunction' }).format(names) } catch { return names.join(', ') }
}
