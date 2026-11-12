import { useState, type FormEvent } from 'react'
import { Navigate } from 'react-router-dom'
import { FlaskConical, Lock } from 'lucide-react'
import { toast } from '../lib/toast'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import { setFlow, useFlow } from '../lib/flow'
import { useAccount } from '../lib/account'
import { Refused } from '../api/types'
import { groups, scenarioOf } from '../lib/testCards'
import { Steps } from '../components/Steps'
import { Summary, useCountdown } from '../components/Summary'
import { policyText } from '../components/policy'
import { Field, inputCls, useRoomAndPlan } from './Details'


export default function Payment() {
  const { api, t, tr, lang } = useApp()
  const { money, day } = useFormat()
  const flow = useFlow()
  const acct = useAccount()
  const { room, plan } = useRoomAndPlan(flow.offer?.roomTypeId, flow.offer?.planId, flow.stay?.code)
  const [card, setCard] = useState('')
  const [expiry, setExpiry] = useState('')
  const [cvc, setCvc] = useState('')
  const [err, setErr] = useState<string>()
  const [busy, setBusy] = useState(false)
  const [agreed, setAgreed] = useState(false)
  const left = useCountdown(flow.hold?.expiresAtMs)

  if (flow.done) return <Navigate to="/book/done" replace />
  if (!flow.stay || !flow.offer || !flow.hold) return <Navigate to="/rooms" replace />
  if (!flow.guest) return <Navigate to="/book/details" replace />
  const offer = flow.offer
  const prepaid = plan?.guarantee === 'prepaidInFull'
  const deposit = plan?.guarantee === 'deposit'
  // the hotel keeps the card on file for this rate: the guest agrees to it here, or the booking is not made
  const keepsCard = Boolean(plan?.keepsCard)
  const now = offer.guarantee
  const later = offer.total - (prepaid || deposit ? now : 0n)

  const submit = async (e: FormEvent) => {
    e.preventDefault()
    setErr(undefined)
    const scenario = scenarioOf(card)
    if (!scenario) { setErr(t('pay.onlyTest')); return }
    if (!/^(0[1-9]|1[0-2])\s*\/\s*\d{2}$/.test(expiry) || !/^\d{3,4}$/.test(cvc)) { setErr(t('pay.cards')); return }
    if (keepsCard && !agreed) { setErr(t('pay.agreeFirst')); return }
    setBusy(true)
    try {
      const auth = await api.authorise(scenario, now, flow.hold!.holdId, keepsCard)
      if (!auth.ok) { setErr(auth.reason ?? t('err.generic')); return }
      // the guest's emails are written in the language they booked in
      const done = await api.confirmHold(flow.hold!.holdId, { ...flow.guest!, lang }, auth.authId, acct.signedIn ? acct.token : '')
      // the confirmation renders from this reply, never from a later read that may predate it
      setFlow({ done, hold: undefined })
    } catch (e) {
      if (e instanceof Refused) setErr(tr(e.reason)); else toast.error(t('err.generic'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="mx-auto max-w-[1240px] px-4 pb-32 pt-8 sm:px-8">
      <Steps at={2} />
      <div className="mt-8 grid gap-10 lg:grid-cols-[minmax(0,1fr)_340px]">
        <form onSubmit={submit} noValidate className="max-w-xl space-y-6">
          <h1 className="t-h1 text-ink">{t('pay.title')}</h1>
          <p role="note" className="flex items-start gap-3 rounded-lg border border-accent bg-surface p-4 text-ink">
            <FlaskConical className="mt-0.5 h-5 w-5 shrink-0 text-accent" aria-hidden />
            <span><strong className="font-semibold">{t('pay.test')}</strong><span className="t-small mt-1 block text-muted">{t('pay.cards')}</span></span>
          </p>

          <Field id="card" label={t('pay.card')}>
            <input id="card" inputMode="numeric" autoComplete="off" dir="ltr" value={card} onChange={(e) => setCard(groups(e.currentTarget.value))} className={`${inputCls} nums tracking-wider`} placeholder="4242 4242 4242 4242" />
          </Field>
          <div className="grid grid-cols-2 gap-4">
            <Field id="exp" label={t('pay.expiry')}>
              <input id="exp" inputMode="numeric" autoComplete="off" dir="ltr" value={expiry} onChange={(e) => setExpiry(e.currentTarget.value.replace(/[^\d/]/g, '').slice(0, 5))} className={`${inputCls} nums`} placeholder="12/29" />
            </Field>
            <Field id="cvc" label={t('pay.cvc')}>
              <input id="cvc" inputMode="numeric" autoComplete="off" dir="ltr" value={cvc} onChange={(e) => setCvc(e.currentTarget.value.replace(/\D/g, '').slice(0, 4))} className={`${inputCls} nums`} placeholder="123" />
            </Field>
          </div>

          <section aria-labelledby="terms" className="border-t border-line pt-5">
            <h2 id="terms" className="font-semibold text-ink">{t('pay.terms')}</h2>
            {plan && <p className="mt-2 text-ink">{policyText(plan, offer, t, money, day)}</p>}
            <p className="t-small mt-2 text-muted nums">{prepaid ? t('summary.nowAll', { now: money(now) }) : deposit ? t('summary.nowDeposit', { now: money(now), later: money(later) })
              : t('summary.nowHotel', { now: money(now), later: money(later) })}</p>
          </section>

          {keepsCard && (
            <section aria-labelledby="onfile" className="rounded-lg border border-line bg-surface p-4">
              <h2 id="onfile" className="font-semibold text-ink">{t('pay.onFileTitle')}</h2>
              <p className="t-small mt-2 text-ink">{t('pay.onFileText', { nights: plan?.penaltyNights ?? 1 })}</p>
              <label className="mt-3 flex items-start gap-3 text-ink">
                <input type="checkbox" checked={agreed} onChange={(e) => setAgreed(e.currentTarget.checked)} className="mt-1 h-4 w-4 shrink-0" />
                <span>{t('pay.onFileAgree')}</span>
              </label>
            </section>
          )}

          {err && <p role="alert" className="rounded-base border border-danger px-4 py-3 font-semibold text-danger">{err}</p>}

          <button type="submit" disabled={busy || left === 0 || (keepsCard && !agreed)}
            className="w-full rounded-base bg-primary px-6 py-4 text-lg font-semibold text-primary-ink transition hover:opacity-90 disabled:opacity-50">
            {busy ? t('pay.working') : prepaid || deposit ? t('pay.submitPay', { amount: money(now) }) : t('pay.submitHold', { amount: money(now) })}
          </button>
          <p className="t-small flex items-center gap-2 text-muted"><Lock className="h-3.5 w-3.5" aria-hidden />{t('pay.privacy')}</p>
        </form>
        <div><Summary stay={flow.stay} room={room} plan={plan} offer={offer} holdUntil={flow.hold.expiresAtMs} /></div>
      </div>
    </div>
  )
}
