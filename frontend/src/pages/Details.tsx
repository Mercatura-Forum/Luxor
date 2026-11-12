import { useEffect, useState, type FormEvent } from 'react'
import { Navigate, useNavigate } from 'react-router-dom'
import { useApp } from '../app'
import { useAccount } from '../lib/account'
import { setFlow, useFlow } from '../lib/flow'
import type { PlanView, RoomTypeView } from '../api/types'
import { Steps } from '../components/Steps'
import { Summary } from '../components/Summary'

export function Field({ id, label, hint, error, children }: { id: string; label: string; hint?: string; error?: string; children: React.ReactNode }) {
  return (
    <div>
      <label htmlFor={id} className="block font-semibold text-ink">{label}</label>
      {hint && <p id={`${id}-hint`} className="t-small mt-0.5 text-muted">{hint}</p>}
      <div className="mt-2">{children}</div>
      {error && <p id={`${id}-error`} className="t-small mt-1.5 font-semibold text-danger" role="alert">{error}</p>}
    </div>
  )
}

export const inputCls = 'w-full rounded-base border border-field bg-surface px-4 py-3 text-ink placeholder:text-muted focus:border-ink focus:outline-none'

/** The room type and plan of the booking in progress; a plan a rate code opened is read under that code. */
export function useRoomAndPlan(roomTypeId?: number, planId?: number, code?: string) {
  const { api } = useApp()
  const [room, setRoom] = useState<RoomTypeView>()
  const [plan, setPlan] = useState<PlanView>()
  useEffect(() => {
    let live = true
    Promise.all([api.roomTypes(), api.plans(code)]).then(([r, p]) => {
      if (!live) return
      setRoom(r.find((x) => x.id === roomTypeId)); setPlan(p.find((x) => x.id === planId))
    })
    return () => { live = false }
  }, [api, roomTypeId, planId, code])
  return { room, plan }
}

export default function Details() {
  const { t } = useApp()
  const acct = useAccount()
  const flow = useFlow()
  const nav = useNavigate()
  const { room, plan } = useRoomAndPlan(flow.offer?.roomTypeId, flow.offer?.planId, flow.stay?.code)
  const [name, setName] = useState(flow.guest?.name ?? '')
  const [email, setEmail] = useState(flow.guest?.email ?? '')
  const [note, setNote] = useState(flow.guest?.note ?? '')
  const [tried, setTried] = useState(false)

  if (!flow.stay || !flow.offer || !flow.hold) return <Navigate to="/rooms" replace />
  const nameErr = tried && !name.trim() ? t('details.nameNeeded') : undefined
  const emailErr = tried && !/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email.trim()) ? t('details.emailNeeded') : undefined

  const submit = (e: FormEvent) => {
    e.preventDefault()
    setTried(true)
    if (!name.trim() || !/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email.trim())) return
    setFlow({ guest: { name: name.trim(), email: email.trim(), note: note.trim() } })
    nav('/book/payment')
  }

  return (
    <div className="mx-auto max-w-[1240px] px-4 pb-32 pt-8 sm:px-8">
      <Steps at={1} />
      <div className="mt-8 grid gap-10 lg:grid-cols-[minmax(0,1fr)_340px]">
        <form onSubmit={submit} noValidate className="max-w-xl space-y-6">
          <h1 className="t-h1 text-ink">{t('details.title')}</h1>
          <Field id="name" label={t('details.name')} error={nameErr}>
            <input id="name" autoComplete="name" value={name} onChange={(e) => setName(e.currentTarget.value)} className={inputCls}
              aria-invalid={!!nameErr} aria-describedby={nameErr ? 'name-error' : undefined} maxLength={120} />
          </Field>
          <Field id="email" label={t('details.email')} hint={t('details.emailHint')} error={emailErr}>
            <input id="email" type="email" inputMode="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.currentTarget.value)} className={inputCls}
              aria-invalid={!!emailErr} aria-describedby={`email-hint${emailErr ? ' email-error' : ''}`} dir="ltr" />
          </Field>
          <Field id="note" label={t('details.note')}>
            <textarea id="note" rows={3} value={note} onChange={(e) => setNote(e.currentTarget.value)} className={inputCls} maxLength={500} />
          </Field>
          {acct.available && (acct.signedIn
            ? <p className="t-small text-success">{t('account.linked')}</p>
            : <p className="t-small text-muted">{t('details.passkey')} <button type="button" onClick={() => acct.signIn()} className="font-semibold text-ink underline">{t('account.signIn')}</button></p>)}
          <button type="submit" className="w-full rounded-base bg-primary px-6 py-4 text-lg font-semibold text-primary-ink transition hover:opacity-90 sm:w-auto">
            {t('details.continue')}
          </button>
        </form>
        <div><Summary stay={flow.stay} room={room} plan={plan} offer={flow.offer} holdUntil={flow.hold.expiresAtMs} /></div>
      </div>
    </div>
  )
}
