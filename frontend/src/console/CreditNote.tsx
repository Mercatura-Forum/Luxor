import { useEffect, useMemo, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { Download, Printer } from 'lucide-react'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import { Refused, type CreditNoteEta, type CreditNoteLineView, type CreditNoteView, type RefundView } from '../api/types'
import { RefundList } from './RefundList'
import { StaffOnly } from './StaffOnly'
import { shortId } from './Staff'

/**
 * A CREDIT NOTE, AS THE HOTEL PRINTS IT: a document of its own, under a number of its own, naming the
 * invoice it amends, which is never changed. Its lines are what it takes back, each line's taxes with
 * it; it was proposed by one member of staff and approved by another. Below the page (not printed),
 * the note as the tax authority's credit note, and what a submission of it still needs. On the page, where
 * its refund goes: each part on the card it goes back to, and where it stands, so the guest knows to look
 * on every card listed.
 */
export default function CreditNote() {
  const { api, t, tr } = useApp()
  const { money, day, num } = useFormat()
  const { number } = useParams()
  const [note, setNote] = useState<CreditNoteView | null | undefined>(undefined)
  const [eta, setEta] = useState<CreditNoteEta | null>(null)
  const [refund, setRefund] = useState<RefundView[] | null>(null)
  const [denied, setDenied] = useState(false)
  useEffect(() => {
    const n = Number(number)
    api.creditNote(n).then(setNote).catch((e) => { if (e instanceof Refused && e.kind === 'notAuthorised') setDenied(true); else setNote(null) })
    api.creditNoteEta(n).then(setEta).catch(() => setEta(null))
    api.creditNoteRefund(n).then(setRefund).catch(() => setRefund([]))
  }, [api, number])
  const lineTitle = (l: CreditNoteLineView) => (l.title.en ? tr(l.title) : t(`folio.${l.sourceKind}` as 'folio.tax'))
  // the taxes taken back, by name
  const taxes = useMemo(() => {
    const m = new Map<string, bigint>()
    for (const l of note?.lineItems ?? []) if (l.tax) { const k = lineTitle(l); m.set(k, (m.get(k) ?? 0n) + l.amount) }
    return [...m.entries()]
  }, [note]) // eslint-disable-line react-hooks/exhaustive-deps
  if (denied) return <StaffOnly />
  if (note === undefined) return <div className="skeleton mx-auto h-96 max-w-3xl rounded-lg" aria-hidden />
  if (note === null) return <p className="mx-auto max-w-3xl text-ink">{t('creditNote.none', { n: number ?? '' })}</p>
  const download = () => {
    if (!eta) return
    const url = URL.createObjectURL(new Blob([eta.json], { type: 'application/json' }))
    const a = document.createElement('a')
    a.href = url; a.download = `CN-${note.number}.json`; a.click()
    URL.revokeObjectURL(url)
  }
  return (
    <div className="mx-auto max-w-3xl">
      <div className="mb-4 flex flex-wrap items-center justify-between gap-3 print:hidden">
        <Link to={`/console/invoice/${note.invoice}`} className="t-small font-semibold text-ink underline underline-offset-4">{t('creditNote.back', { n: note.invoice })}</Link>
        <button type="button" onClick={() => window.print()} className="inline-flex items-center gap-2 rounded-base bg-primary px-4 py-2.5 font-semibold text-primary-ink">
          <Printer className="h-4 w-4" aria-hidden />{t('invoice.print')}</button>
      </div>
      <article className="rounded-lg border border-line bg-surface p-6 shadow-1 sm:p-10 print:border-0 print:shadow-none" data-credit-note={note.number}>
        {api.source === 'demo' && <p className="mb-6 rounded-base border border-accent px-3 py-2 t-small font-semibold text-accent">{t('invoice.demo')}</p>}
        <header className="flex flex-wrap items-start justify-between gap-6 border-b border-line pb-6">
          <div>
            <p className="font-display text-3xl text-ink">{tr(note.hotel)}</p>
            <p className="t-eyebrow mt-1 text-muted">{t('creditNote.title')}</p>
          </div>
          <dl className="grid grid-cols-[auto_auto] gap-x-4 gap-y-1 t-small">
            <dt className="text-muted">{t('creditNote.number')}</dt><dd className="font-semibold text-ink nums">CN-{num(note.number)}</dd>
            <dt className="text-muted">{t('invoice.date')}</dt><dd className="text-ink"><bdi>{day(note.issuedDay, 'long')}</bdi></dd>
            <dt className="text-muted">{t('creditNote.amends')}</dt><dd className="text-ink nums">INV-{num(note.invoice)} · <bdi>{day(note.invoiceDay)}</bdi></dd>
            <dt className="text-muted">{t('invoice.ref')}</dt><dd className="text-ink" dir="ltr">{note.ref}</dd>
          </dl>
        </header>
        <section className="mt-6 grid gap-4 sm:grid-cols-2">
          <div><p className="t-eyebrow text-muted">{t('creditNote.to')}</p><p className="mt-1 font-semibold text-ink">{note.payerName}</p></div>
          {note.payerId !== 0 && <div><p className="t-eyebrow text-muted">{t('invoice.guest')}</p><p className="mt-1 text-ink">{note.guestName}</p></div>}
        </section>
        <table className="mt-8 w-full text-sm nums">
          <thead><tr className="border-b border-line t-small text-muted">
            <th className="py-2 text-start font-semibold">{t('detail.night')}</th>
            <th className="py-2 text-start font-semibold">{t('creditNote.takenBack')}</th>
            <th className="py-2 text-end font-semibold">{t('detail.amount')}</th>
          </tr></thead>
          <tbody>{note.lineItems.map((l) => (
            <tr key={l.id} className="border-b border-line/60">
              <td className="py-2 text-muted"><bdi>{day(l.night)}</bdi></td>
              <td className={`py-2 ${l.tax ? 'ps-4 text-muted' : 'text-ink'}`}>{lineTitle(l)}</td>
              <td className="py-2 text-end text-ink">{money(l.amount)}</td>
            </tr>
          ))}</tbody>
        </table>
        <dl className="ms-auto mt-6 grid max-w-xs grid-cols-[1fr_auto] gap-x-6 gap-y-1.5 text-sm nums">
          <dt className="text-muted">{t('creditNote.net')}</dt><dd className="text-end text-ink">{money(note.net)}</dd>
          {taxes.map(([name, amount]) => <div key={name} className="contents"><dt className="text-muted">{name}</dt><dd className="text-end text-muted">{money(amount)}</dd></div>)}
          <dt className="font-semibold text-ink">{t('creditNote.total')}</dt><dd className="text-end font-semibold text-ink">{money(note.total)}</dd>
        </dl>
        <section className="mt-8 border-t border-line pt-6" aria-labelledby="cn-refund" data-note-refund={note.number}>
          <h2 id="cn-refund" className="t-eyebrow text-muted">{t('creditNote.refund')}</h2>
          {refund === null ? <div className="skeleton mt-2 h-8 rounded-base" aria-hidden />
            : note.payerId !== 0 ? <p className="t-small mt-2 text-ink">{t('creditNote.refundPayer', { name: note.payerName })}</p>
            : refund.length === 0 ? <p className="t-small mt-2 text-ink">{t('creditNote.refundNone')}</p>
            : <><p className="t-small mt-1 mb-3 text-muted">{t('creditNote.refundLead')}</p><RefundList refunds={refund} /></>}
        </section>
        <p className="t-small mt-8 text-muted">{t('creditNote.approvedBy', { maker: shortId(note.maker), checker: shortId(note.checker) })}</p>
      </article>

      <section className="mt-8 rounded-lg border border-line bg-surface p-5 print:hidden" aria-labelledby="eta-title">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h2 id="eta-title" className="t-h2 text-ink">{t('creditNote.eta')}</h2>
            <p className="t-small mt-1 max-w-xl text-muted">{t('creditNote.etaLead')}</p>
          </div>
          <button type="button" disabled={!eta} onClick={download} className="inline-flex items-center gap-2 rounded-base border border-line px-3 py-2 t-small font-semibold text-ink disabled:opacity-40">
            <Download className="h-4 w-4" aria-hidden />{t('creditNote.etaDownload')}</button>
        </div>
        {eta && (
          <>
            {eta.missing.length > 0 && (
              <div className="mt-4">
                <p className="t-small font-semibold text-ink">{t('creditNote.etaMissing')}</p>
                <ul className="mt-1 list-disc space-y-0.5 ps-5 t-small text-muted" dir="ltr">{eta.missing.map((m) => <li key={m}>{m}</li>)}</ul>
              </div>
            )}
            <p className="t-small mt-4 text-muted">{t('creditNote.etaDigest')} <code dir="ltr" className="break-all text-xs text-ink">{eta.digest}</code></p>
          </>
        )}
      </section>
    </div>
  )
}
