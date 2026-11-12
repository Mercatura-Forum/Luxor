import { useState } from 'react'
import { Link, Navigate } from 'react-router-dom'
import { CalendarPlus, Check, Copy, Mail } from 'lucide-react'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import { useFlow } from '../lib/flow'
import { iso } from '../lib/days'
import { useRoomAndPlan } from './Details'
import { LuxorSeal } from '../components/LuxorSeal'

export function manageLink(ref: string, secret: string) {
  // the secret travels after '#', which a browser never sends to any server
  return `${location.origin}${location.pathname}#/manage/${ref}?k=${secret}`
}

/** The card link of a booking taken by phone: the same secret as the manage link, to the page that puts a card on file. */
export function cardLink(ref: string, secret: string) {
  return `${location.origin}${location.pathname}#/card/${ref}?k=${secret}`
}

function ics(summary: string, where: string, from: number, to: number, ref: string) {
  const d = (x: number) => iso(x).replaceAll('-', '')
  return ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Luxor//Booking//EN', 'BEGIN:VEVENT', `UID:${ref}@luxor`,
    `DTSTART;VALUE=DATE:${d(from)}`, `DTEND;VALUE=DATE:${d(to)}`, `SUMMARY:${summary}`, `LOCATION:${where}`, `DESCRIPTION:Booking ${ref}`,
    'END:VEVENT', 'END:VCALENDAR'].join('\r\n')
}

export default function Confirmation() {
  const { t, tr, tenant } = useApp()
  const { money, day, num } = useFormat()
  const flow = useFlow()
  const [copied, setCopied] = useState<string | null>(null)
  const b = flow.done?.booking
  const { room } = useRoomAndPlan(b?.roomTypeId, b?.planId)
  if (!flow.done || !b) return <Navigate to="/" replace />
  const link = manageLink(b.ref, flow.done.manageSecret)
  const copy = async (what: string, text: string) => { try { await navigator.clipboard.writeText(text); setCopied(what); setTimeout(() => setCopied(null), 1800) } catch { /* clipboard blocked: the text stays selectable */ } }
  const cal = URL.createObjectURL(new Blob([ics(`${tr(room?.name)} · ${tr(tenant.name)}`, tr(tenant.address), b.arrival, b.departure, b.ref)], { type: 'text/calendar' }))

  return (
    <div className="mx-auto max-w-3xl px-5 pb-20 pt-14 sm:px-8">
      <p className="grid h-14 w-14 place-items-center rounded-full bg-primary text-primary-ink" aria-hidden><Check className="h-7 w-7" /></p>
      <h1 className="t-hero mt-6 text-balance text-ink" tabIndex={-1}>{t('done.title')}</h1>
      <p className="t-body mt-4 text-muted">
        {b.guestName} · {tr(room?.name)} · <bdi>{day(b.arrival, 'long')}</bdi> → <bdi>{day(b.departure, 'long')}</bdi>
      </p>

      <div className="mt-10 rounded-lg border border-line bg-surface p-6 shadow-1">
        <p className="t-eyebrow text-muted">{t('done.ref')}</p>
        <div className="mt-2 flex items-center gap-3">
          <p className="font-sans text-3xl font-semibold tracking-wider text-ink [font-variant-numeric:lining-nums_tabular-nums_slashed-zero]" dir="ltr">{b.ref}</p>
          <button type="button" onClick={() => copy('ref', b.ref)} className="inline-flex items-center gap-1.5 rounded-base border border-line px-3 py-1.5 t-small font-semibold text-ink">
            {copied === 'ref' ? <Check className="h-3.5 w-3.5" aria-hidden /> : <Copy className="h-3.5 w-3.5" aria-hidden />}{copied === 'ref' ? t('done.copied') : t('done.copy')}
          </button>
        </div>
        <dl className="mt-6 grid gap-3 border-t border-line pt-5 nums sm:grid-cols-3">
          <div><dt className="t-small text-muted">{t('summary.total')}</dt><dd className="text-lg font-semibold text-ink">{money(b.charged)}</dd></div>
          <div><dt className="t-small text-muted">{t('done.paidNow')}</dt><dd className="text-lg font-semibold text-ink">{money(b.paid)}</dd></div>
          <div><dt className="t-small text-muted">{t('done.dueHotel')}</dt><dd className="text-lg font-semibold text-ink">{money(b.outstanding)}</dd></div>
        </dl>
        <p className="t-small mt-4 text-muted nums">{t('guests.summary', { a: num(b.adults), c: num(b.children), r: num(b.rooms) })}</p>
      </div>

      {(flow.done.mail === 'queued' || flow.done.mail === 'failed') && (
        <p role="status" className="mt-6 flex items-start gap-2 text-ink" data-mail-attach={flow.done.mail}>
          <Mail className="mt-1 h-4 w-4 shrink-0 text-muted" aria-hidden />
          <span>{flow.done.mail === 'queued' ? t('mail.done.queued', { email: flow.guest?.email ?? '' }) : t('mail.done.failed')}</span>
        </p>
      )}

      <div className="mt-6 rounded-lg border border-accent p-6">
        <p className="font-semibold text-ink">{t('done.manage')}</p>
        <p className="t-small mt-1 text-muted">{t('done.manageHint')}</p>
        <div className="mt-3 flex flex-col gap-2 sm:flex-row">
          <input readOnly value={link} dir="ltr" onFocus={(e) => e.currentTarget.select()} className="min-w-0 flex-1 rounded-base border border-field bg-surface px-3 py-2.5 t-small text-ink" aria-label={t('done.manage')} />
          <button type="button" onClick={() => copy('link', link)} className="inline-flex items-center justify-center gap-1.5 rounded-base bg-primary px-4 py-2.5 font-semibold text-primary-ink">
            {copied === 'link' ? <Check className="h-4 w-4" aria-hidden /> : <Copy className="h-4 w-4" aria-hidden />}{copied === 'link' ? t('done.copied') : t('done.copy')}
          </button>
        </div>
      </div>

      <div className="mt-8 flex flex-wrap gap-4">
        <a href={cal} download={`${b.ref}.ics`} className="inline-flex items-center gap-2 rounded-base border border-line px-4 py-2.5 font-semibold text-ink no-underline hover:border-ink"><CalendarPlus className="h-4 w-4" aria-hidden />{t('done.calendar')}</a>
        <Link to={`/manage/${b.ref}?k=${flow.done.manageSecret}`} className="inline-flex items-center rounded-base px-4 py-2.5 font-semibold text-ink underline underline-offset-4">{t('done.view')}</Link>
      </div>
      <div className="mt-12 border-t border-line pt-6"><LuxorSeal /></div>
    </div>
  )
}
