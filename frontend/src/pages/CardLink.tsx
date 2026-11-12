import { useEffect, useState, type FormEvent } from 'react'
import { Link, useParams, useSearchParams } from 'react-router-dom'
import { FlaskConical, Lock } from 'lucide-react'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import { groups, scenarioOf } from '../lib/testCards'
import { BOOKING_REF_BASE, Refused, type BookingView, type CardView } from '../api/types'
import { Field, inputCls, useRoomAndPlan } from './Details'

/**
 * The card link of a booking taken by phone. The guest opens the link the desk gave them, agrees to keep a
 * card on file, and the guarantee of the rate is authorised on it (a deposit is taken at once). The card
 * number stays in this browser: the gateway keeps the card and the hotel receives only a reference. The
 * act is signed with the booking's own link key, as a cancellation is.
 */
export default function CardLink() {
  const { ref = '' } = useParams()
  const [q] = useSearchParams()
  const secret = q.get('k') ?? ''
  const { api, t, tr } = useApp()
  const { money, day } = useFormat()
  const [b, setB] = useState<BookingView | null>(null)
  const [card, setCard] = useState<CardView | null | undefined>(undefined)
  const [missing, setMissing] = useState(false)
  const [number, setNumber] = useState('')
  const [expiry, setExpiry] = useState('')
  const [cvc, setCvc] = useState('')
  const [agreed, setAgreed] = useState(false)
  const [busy, setBusy] = useState(false)
  const [done, setDone] = useState(false)
  const [err, setErr] = useState<string>()
  const { room, plan } = useRoomAndPlan(b?.roomTypeId, b?.planId)

  useEffect(() => {
    let live = true
    Promise.all([api.manage(ref, secret), api.manageCard(ref, secret)])
      .then(([x, c]) => { if (live) { setB(x); setCard(c) } })
      .catch(() => live && setMissing(true))
    return () => { live = false }
  }, [api, ref, secret])

  if (missing) return (
    <div className="mx-auto max-w-2xl px-5 pt-16 sm:px-8">
      <h1 className="t-h1 text-ink">{t('card.title')}</h1>
      <p className="mt-4 text-ink" role="alert">{t('manage.notFound')}</p>
      <Link to="/" className="mt-6 inline-block font-semibold text-ink underline">{t('err.back')}</Link>
    </div>
  )
  if (!b || card === undefined) return <div className="mx-auto max-w-2xl px-5 pt-16 sm:px-8" aria-hidden><div className="skeleton h-10 w-60 rounded-base" /><div className="skeleton mt-8 h-56 rounded-lg" /></div>

  const manageLink = `/manage/${encodeURIComponent(ref)}?k=${encodeURIComponent(secret)}`
  const wanted = card?.state === 'wanted' && card.due > 0n && !done
  const deposit = plan?.guarantee === 'deposit'

  const submit = async (e: FormEvent) => {
    e.preventDefault()
    setErr(undefined)
    const scenario = scenarioOf(number)
    if (!scenario) { setErr(t('pay.onlyTest')); return }
    if (!/^(0[1-9]|1[0-2])\s*\/\s*\d{2}$/.test(expiry) || !/^\d{3,4}$/.test(cvc)) { setErr(t('pay.cards')); return }
    if (!agreed) { setErr(t('pay.agreeFirst')); return }
    setBusy(true)
    try {
      const auth = await api.authorise(scenario, card!.due, BOOKING_REF_BASE + b.id, true)
      if (!auth.ok) { setErr(auth.reason ?? t('err.generic')); return }
      await api.putCardOnFile(ref, secret, auth.authId)
      setDone(true)
      setCard(await api.manageCard(ref, secret))
    } catch (e) {
      setErr(e instanceof Refused ? tr(e.reason) : t('err.generic'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="mx-auto max-w-2xl px-5 pb-20 pt-14 sm:px-8">
      <p className="t-eyebrow text-muted">{t('card.title')}</p>
      <h1 className="t-h1 mt-2 text-ink">{tr(room?.name)}</h1>
      <p className="mt-2 text-ink"><bdi>{day(b.arrival, 'long')}</bdi> → <bdi>{day(b.departure, 'long')}</bdi></p>
      <p className="t-small mt-1 text-muted nums"><span dir="ltr">{b.ref}</span> · {tr(b.planName ?? plan?.name)} · {b.guestName}</p>

      {done && <p role="status" className="mt-6 rounded-base border border-line px-4 py-3 font-semibold text-ink">{t('card.done')}</p>}
      {!wanted && !done && <p role="status" className="mt-6 text-ink">{card ? t(`card.state.${card.state}` as 'card.state.kept', { day: day(card.deadline, 'long') }) : t('card.notWanted')}</p>}

      {wanted && (
        <form onSubmit={submit} noValidate className="mt-6 space-y-5" data-card-form>
          <p className="text-ink">{t('card.intro', { day: day(card!.deadline, 'long') })}</p>
          <p className="font-semibold text-ink nums">{deposit ? t('card.amountDeposit', { amount: money(card!.due) }) : t('card.amountHold', { amount: money(card!.due) })}</p>
          <p role="note" className="flex items-start gap-3 rounded-lg border border-accent bg-surface p-4 text-ink">
            <FlaskConical className="mt-0.5 h-5 w-5 shrink-0 text-accent" aria-hidden />
            <span><strong className="font-semibold">{t('pay.test')}</strong><span className="t-small mt-1 block text-muted">{t('pay.cards')}</span></span>
          </p>
          <Field id="card" label={t('pay.card')}>
            <input id="card" inputMode="numeric" autoComplete="off" dir="ltr" value={number} onChange={(e) => setNumber(groups(e.currentTarget.value))} className={`${inputCls} nums tracking-wider`} placeholder="4242 4242 4242 4242" />
          </Field>
          <div className="grid grid-cols-2 gap-4">
            <Field id="exp" label={t('pay.expiry')}>
              <input id="exp" inputMode="numeric" autoComplete="off" dir="ltr" value={expiry} onChange={(e) => setExpiry(e.currentTarget.value.replace(/[^\d/]/g, '').slice(0, 5))} className={`${inputCls} nums`} placeholder="12/29" />
            </Field>
            <Field id="cvc" label={t('pay.cvc')}>
              <input id="cvc" inputMode="numeric" autoComplete="off" dir="ltr" value={cvc} onChange={(e) => setCvc(e.currentTarget.value.replace(/\D/g, '').slice(0, 4))} className={`${inputCls} nums`} placeholder="123" />
            </Field>
          </div>
          <section aria-labelledby="onfile" className="rounded-lg border border-line bg-surface p-4">
            <h2 id="onfile" className="font-semibold text-ink">{t('pay.onFileTitle')}</h2>
            <p className="t-small mt-2 text-ink">{t('pay.onFileText', { nights: plan?.penaltyNights ?? 1 })}</p>
            <label className="mt-3 flex items-start gap-3 text-ink">
              <input type="checkbox" checked={agreed} onChange={(e) => setAgreed(e.currentTarget.checked)} className="mt-1 h-4 w-4 shrink-0" />
              <span>{t('pay.onFileAgree')}</span>
            </label>
          </section>
          {err && <p role="alert" className="rounded-base border border-danger px-4 py-3 font-semibold text-danger">{err}</p>}
          <button type="submit" disabled={busy || !agreed} className="w-full rounded-base bg-primary px-6 py-4 text-lg font-semibold text-primary-ink transition hover:opacity-90 disabled:opacity-50">
            {busy ? t('pay.working') : t('card.submit')}
          </button>
          <p className="t-small flex items-center gap-2 text-muted"><Lock className="h-3.5 w-3.5" aria-hidden />{t('pay.privacy')}</p>
        </form>
      )}
      <Link to={manageLink} className="mt-8 inline-block font-semibold text-ink underline">{t('manage.title')}</Link>
    </div>
  )
}
