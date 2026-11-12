import { useEffect, useState, type FormEvent } from 'react'
import { Link, useParams, useSearchParams } from 'react-router-dom'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import { Refused, type BookingView, type CancelResult, type CardView, type MailRow } from '../api/types'
import { useRoomAndPlan } from './Details'
import { MailList } from '../components/MailList'

export default function Manage() {
  const { ref = '' } = useParams()
  const [q] = useSearchParams()
  const secret = q.get('k') ?? ''
  const { api, t, tr, lang } = useApp()
  const { money, day, num } = useFormat()
  const [b, setB] = useState<BookingView | null>(null)
  const [missing, setMissing] = useState(false)
  const [today, setToday] = useState<number | null>(null)
  const [asking, setAsking] = useState(false)
  const [busy, setBusy] = useState(false)
  const [result, setResult] = useState<CancelResult | null>(null)
  const [err, setErr] = useState<string>()
  const [card, setCard] = useState<CardView | null>(null)
  const [mail, setMail] = useState<{ rows: MailRow[]; connected: boolean } | null>(null)
  const [address, setAddress] = useState('')
  const [mailBusy, setMailBusy] = useState(false)
  const [mailErr, setMailErr] = useState<string>()
  const [mailGiven, setMailGiven] = useState(false)
  const { room, plan } = useRoomAndPlan(b?.roomTypeId, b?.planId)

  useEffect(() => {
    let live = true
    api.property().then((p) => live && setToday(p.businessDate))
    api.manage(ref, secret).then((x) => live && setB(x)).catch(() => live && setMissing(true))
    api.manageCard(ref, secret).then((c) => live && setCard(c)).catch(() => live && setCard(null))
    api.manageMail(ref, secret).then((m) => live && setMail(m)).catch(() => live && setMail(null))
    return () => { live = false }
  }, [api, ref, secret])

  if (missing) return (
    <div className="mx-auto max-w-2xl px-5 pt-16 sm:px-8">
      <h1 className="t-h1 text-ink">{t('manage.title')}</h1>
      <p className="mt-4 text-ink" role="alert">{t('manage.notFound')}</p>
      <Link to="/" className="mt-6 inline-block font-semibold text-ink underline">{t('err.back')}</Link>
    </div>
  )
  if (!b) return <div className="mx-auto max-w-2xl px-5 pt-16 sm:px-8" aria-hidden><div className="skeleton h-10 w-60 rounded-base" /><div className="skeleton mt-8 h-56 rounded-lg" /></div>

  const free = b.refundable && b.cancelDeadline !== null && today !== null && today <= b.cancelDeadline
  const fee = free ? 0n : b.penalty
  const cancel = async () => {
    setBusy(true); setErr(undefined)
    try { const r = await api.cancel(ref, secret); setResult(r); setB(r.booking); setAsking(false); setCard(await api.manageCard(ref, secret)); setMail(await api.manageMail(ref, secret)) }
    catch (e) { setErr(e instanceof Refused ? tr(e.reason) : t('err.generic')) }
    finally { setBusy(false) }
  }

  const giveMail = async (e: FormEvent) => {
    e.preventDefault()
    setMailBusy(true); setMailErr(undefined)
    try { await api.attachMailFromLink(ref, secret, address, lang); setMailGiven(true); setMail(await api.manageMail(ref, secret)) }
    catch (x) { setMailErr(x instanceof Refused ? tr(x.reason) : t('err.generic')) }
    finally { setMailBusy(false) }
  }
  const canGive = mail?.connected && !mail.rows.length && (b.status === 'confirmed' || b.status === 'checkedIn')

  return (
    <div className="mx-auto max-w-2xl px-5 pb-20 pt-14 sm:px-8">
      <p className="t-eyebrow text-muted">{t('manage.title')}</p>
      <h1 className="t-h1 mt-2 text-ink">{tr(room?.name)}</h1>
      <p className="mt-2 text-ink"><bdi>{day(b.arrival, 'long')}</bdi> → <bdi>{day(b.departure, 'long')}</bdi></p>
      <p className="t-small mt-1 text-muted nums"><span dir="ltr">{b.ref}</span> · {tr(b.planName ?? plan?.name)} · {t('guests.summary', { a: num(b.adults), c: num(b.children), r: num(b.rooms) })}</p>

      <p className={`mt-6 inline-block rounded-full px-3 py-1 t-small font-semibold ${b.status === 'confirmed' ? 'bg-primary text-primary-ink' : 'border border-line text-ink'}`} role="status">
        {t(`manage.status.${b.status}` as 'manage.status.confirmed')}
      </p>

      <dl className="mt-6 grid gap-3 rounded-lg border border-line bg-surface p-5 nums sm:grid-cols-3">
        <div><dt className="t-small text-muted">{t('summary.total')}</dt><dd className="font-semibold text-ink">{money(b.charged - b.credited)}</dd></div>
        <div><dt className="t-small text-muted">{t('done.paidNow')}</dt><dd className="font-semibold text-ink">{money(b.paid)}</dd></div>
        <div><dt className="t-small text-muted">{t('done.dueHotel')}</dt><dd className="font-semibold text-ink">{money(b.outstanding)}</dd></div>
      </dl>

      {card && (
        <section aria-labelledby="cardonfile" className="mt-6 rounded-lg border border-line p-5" data-manage-card={card.state}>
          <h2 id="cardonfile" className="font-semibold text-ink">{t('pay.onFileTitle')}</h2>
          <p className="mt-2 text-ink">{t(`card.state.${card.state}` as 'card.state.kept', { day: day(card.deadline, 'long') })}</p>
          {card.charge && <p className={`mt-2 nums ${card.charge === 'failed' ? 'font-semibold text-danger' : 'text-ink'}`}>{t(`card.charge.${card.charge}` as 'card.charge.done', { amount: money(card.chargeAmount) })}</p>}
          {card.state === 'wanted' && b.status === 'confirmed' && (
            <Link to={`/card/${encodeURIComponent(ref)}?k=${encodeURIComponent(secret)}`} className="mt-4 inline-block rounded-base bg-primary px-5 py-3 font-semibold text-primary-ink">{t('card.put')}</Link>
          )}
        </section>
      )}

      {mail && (mail.rows.length > 0 || canGive) && (
        <section aria-labelledby="emails" className="mt-6 rounded-lg border border-line p-5" data-manage-mail={mail.rows.length}>
          <h2 id="emails" className="font-semibold text-ink">{canGive ? t('mail.giveTitle') : t('mail.title')}</h2>
          {mail.rows.length > 0 && <div className="mt-2"><MailList rows={mail.rows} today={today} /></div>}
          {mailGiven && <p role="status" className="mt-2 text-ink">{t('mail.given')}</p>}
          {canGive && (
            <form onSubmit={giveMail} className="mt-2">
              <p className="t-small text-muted">{t('mail.giveLead')}</p>
              <div className="mt-3 flex flex-col gap-2 sm:flex-row">
                <input type="email" required value={address} onChange={(e) => setAddress(e.currentTarget.value)} autoComplete="email" dir="ltr" aria-label={t('details.email')}
                  className="min-w-0 flex-1 rounded-base border border-field bg-surface px-3 py-2.5 text-ink" />
                <button type="submit" disabled={mailBusy} className="rounded-base bg-primary px-4 py-2.5 font-semibold text-primary-ink disabled:opacity-50">{t('mail.give')}</button>
              </div>
              {mailErr && <p role="alert" className="mt-2 text-danger">{mailErr}</p>}
            </form>
          )}
        </section>
      )}

      {result && (
        <p role="status" className="mt-6 rounded-base border border-line px-4 py-3 text-ink">
          {result.fee > 0n ? t('manage.cancelledFee', { fee: money(result.fee) }) : result.refund > 0n ? t('manage.cancelled', { refund: money(result.refund) }) : t('manage.cancelledReleased')}
        </p>
      )}

      {b.status === 'confirmed' && !asking && (
        <button type="button" onClick={() => setAsking(true)} className="mt-8 rounded-base border border-ink px-5 py-3 font-semibold text-ink hover:bg-surface-2/60">{t('manage.cancel')}</button>
      )}
      {b.status === 'confirmed' && asking && (
        <div className="mt-8 rounded-lg border border-danger p-5">
          <p className="font-semibold text-ink">{free ? t('manage.cancelFree', { amount: money(b.paid > 0n ? b.paid : b.penalty) }) : t('manage.cancelFee', { fee: money(fee) })}</p>
          {err && <p role="alert" className="mt-2 text-danger">{err}</p>}
          <div className="mt-4 flex flex-wrap gap-3">
            <button type="button" onClick={cancel} disabled={busy} className="rounded-base bg-danger px-5 py-3 font-semibold text-bg disabled:opacity-50">{t('manage.cancelConfirm')}</button>
            <button type="button" onClick={() => setAsking(false)} className="rounded-base px-5 py-3 font-semibold text-ink underline">{t('manage.keep')}</button>
          </div>
        </div>
      )}
    </div>
  )
}
