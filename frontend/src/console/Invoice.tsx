import { useEffect, useMemo, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { Printer } from 'lucide-react'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import { Refused, isNoteLine, type CreditNoteRow, type InvoiceView } from '../api/types'
import { StaffOnly } from './StaffOnly'
import { useLineTitle } from './Bill'

/**
 * AN INVOICE, AS THE HOTEL PRINTS IT: one bill of one stay, under its number. A voided charge and the
 * credit that voided it net to nothing and are left off; the figures are the ones the contract fixed
 * when the invoice was issued, and the lines are the bill's, which its invoice closed. A credit note
 * amends it without changing it: the note's lines are its own document's, and the notes are listed
 * under the invoice.
 */
export default function Invoice() {
  const { api, t, tr } = useApp()
  const { money, day, num } = useFormat()
  const title = useLineTitle()
  const { number } = useParams()
  const [inv, setInv] = useState<InvoiceView | null | undefined>(undefined)
  const [denied, setDenied] = useState(false)
  const [notes, setNotes] = useState<CreditNoteRow[]>([])
  useEffect(() => {
    api.invoice(Number(number)).then((x) => {
      setInv(x)
      if (x) api.creditNotes(x.bookingId).then((ns) => setNotes(ns.filter((n) => n.invoice === x.number))).catch(() => setNotes([]))
    }).catch((e) => { if (e instanceof Refused && e.kind === 'notAuthorised') setDenied(true); else setInv(null) })
  }, [api, number])
  const lines = useMemo(() => (inv?.lines ?? []).filter((l) => !l.voided && !isNoteLine(l)), [inv])
  // the taxes by name: each tax line's own name, summed
  const taxes = useMemo(() => {
    const m = new Map<string, bigint>()
    for (const l of lines) if (l.kind === 'tax' || l.kind === 'extraTax') { const k = title(l); m.set(k, (m.get(k) ?? 0n) + l.amount) }
    return [...m.entries()]
  }, [lines, title])
  if (denied) return <StaffOnly />
  if (inv === undefined) return <div className="skeleton mx-auto h-96 max-w-3xl rounded-lg" aria-hidden />
  if (inv === null) return <p className="mx-auto max-w-3xl text-ink">{t('invoice.none', { n: number ?? '' })}</p>
  const charged = lines.filter((l) => l.kind !== 'credit').reduce((a, l) => a + l.amount, 0n)
  const credited = lines.filter((l) => l.kind === 'credit').reduce((a, l) => a + l.amount, 0n)
  const total = charged - credited
  const balance = total - inv.paid
  return (
    <div className="mx-auto max-w-3xl">
      <div className="mb-4 flex flex-wrap items-center justify-between gap-3 print:hidden">
        <Link to="/console/bookings" className="t-small font-semibold text-ink underline underline-offset-4">{t('invoice.back')}</Link>
        <button type="button" onClick={() => window.print()} className="inline-flex items-center gap-2 rounded-base bg-primary px-4 py-2.5 font-semibold text-primary-ink">
          <Printer className="h-4 w-4" aria-hidden />{t('invoice.print')}</button>
      </div>
      <article className="rounded-lg border border-line bg-surface p-6 shadow-1 sm:p-10 print:border-0 print:shadow-none" data-invoice={inv.number}>
        {api.source === 'demo' && <p className="mb-6 rounded-base border border-accent px-3 py-2 t-small font-semibold text-accent">{t('invoice.demo')}</p>}
        <header className="flex flex-wrap items-start justify-between gap-6 border-b border-line pb-6">
          <div>
            <p className="font-display text-3xl text-ink">{tr(inv.hotel)}</p>
            <p className="t-eyebrow mt-1 text-muted">{t('invoice.title')}</p>
          </div>
          <dl className="grid grid-cols-[auto_auto] gap-x-4 gap-y-1 t-small">
            <dt className="text-muted">{t('invoice.number')}</dt><dd className="font-semibold text-ink nums">{num(inv.number)}</dd>
            <dt className="text-muted">{t('invoice.date')}</dt><dd className="text-ink"><bdi>{day(inv.issuedDay, 'long')}</bdi></dd>
            <dt className="text-muted">{t('invoice.ref')}</dt><dd className="text-ink" dir="ltr">{inv.ref}</dd>
          </dl>
        </header>
        <section className="mt-6 grid gap-4 sm:grid-cols-2">
          <div><p className="t-eyebrow text-muted">{t('invoice.billTo')}</p><p className="mt-1 font-semibold text-ink">{inv.payerName}</p></div>
          {inv.payerId !== 0 && <div><p className="t-eyebrow text-muted">{t('invoice.guest')}</p><p className="mt-1 text-ink">{inv.guestName}</p></div>}
        </section>
        <table className="mt-8 w-full text-sm nums">
          <thead><tr className="border-b border-line t-small text-muted">
            <th className="py-2 text-start font-semibold">{t('detail.night')}</th>
            <th className="py-2 text-start font-semibold">{t('detail.line')}</th>
            <th className="py-2 text-end font-semibold">{t('detail.amount')}</th>
          </tr></thead>
          <tbody>{lines.map((l) => (
            <tr key={l.id} className="border-b border-line/60">
              <td className="py-2 text-muted"><bdi>{day(l.night)}</bdi></td>
              <td className="py-2 text-ink">{title(l)}</td>
              <td className={`py-2 text-end ${l.kind === 'credit' ? 'text-success' : 'text-ink'}`}>{l.kind === 'credit' ? '−' : ''}{money(l.amount)}</td>
            </tr>
          ))}</tbody>
        </table>
        <dl className="ms-auto mt-6 grid max-w-xs grid-cols-[1fr_auto] gap-x-6 gap-y-1.5 text-sm nums">
          {taxes.map(([name, amount]) => <div key={name} className="contents"><dt className="text-muted">{t('invoice.ofWhichTax', { name })}</dt><dd className="text-end text-muted">{money(amount)}</dd></div>)}
          <dt className="font-semibold text-ink">{t('invoice.total')}</dt><dd className="text-end font-semibold text-ink">{money(total)}</dd>
          <dt className="text-muted">{t('invoice.paid')}</dt><dd className="text-end text-ink">{money(inv.paid)}</dd>
          <dt className="font-semibold text-ink">{t('invoice.balance')}</dt><dd className="text-end font-semibold text-ink">{money(balance)}</dd>
        </dl>
        {notes.length > 0 && (
          <section className="mt-8 border-t border-line pt-4" aria-labelledby="inv-notes">
            <p id="inv-notes" className="t-eyebrow text-muted">{t('invoice.notes')}</p>
            <ul className="mt-2 space-y-1 text-sm nums">
              {notes.map((n) => (
                <li key={n.number} className="flex justify-between gap-4">
                  <Link to={`/console/credit-note/${n.number}`} className="text-ink underline underline-offset-4">CN-{num(n.number)} · <bdi>{day(n.issuedDay)}</bdi></Link>
                  <span className="text-ink">−{money(n.total)}</span>
                </li>
              ))}
            </ul>
          </section>
        )}
      </article>
    </div>
  )
}
