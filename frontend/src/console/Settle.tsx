import { useState, type FormEvent } from 'react'
import * as Dialog from '@radix-ui/react-dialog'
import { FlaskConical, X } from 'lucide-react'
import { toast } from '../lib/toast'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import { groups, scenarioOf } from '../lib/testCards'
import { BOOKING_REF_BASE, Refused, type BookingView } from '../api/types'

/**
 * TAKE PAYMENT AT THE DESK: what is left on a stay, paid by the guest's card in person. The card is
 * authorised on the TEST gateway for exactly that amount against the booking's own reference, and the
 * contract then records it (`settleAtDesk`): it refuses an authorisation for another booking, another
 * amount, or one already used.
 */
export function Settle({ booking: b, share, onClose, onDone }: {
  booking: BookingView | null
  /** Another payer's window (payerId above 0) or the guest's, with what is open on it; absent: the guest's whole balance. */
  share?: { payerId: number; name: string; open: bigint }
  onClose(): void
  onDone(): void
}) {
  const { api, t, tr } = useApp()
  const { money } = useFormat()
  const [card, setCard] = useState('')
  const [err, setErr] = useState<string>()
  const [busy, setBusy] = useState(false)
  if (!b) return null
  const amount = share ? share.open : b.outstanding
  const who = share ? share.name : b.guestName
  const submit = async (e: FormEvent) => {
    e.preventDefault()
    setErr(undefined)
    const scenario = scenarioOf(card)
    if (!scenario) { setErr(t('pay.onlyTest')); return }
    setBusy(true)
    try {
      const auth = await api.authorise(scenario, amount, BOOKING_REF_BASE + b.id)
      // the gateway's reason is its own English; the person at the desk reads it in their language
      if (!auth.ok) { setErr(scenario === 'decline' ? t('settle.declined') : scenario === 'insufficient' ? t('settle.insufficient') : auth.reason ?? t('err.generic')); return }
      if (share && share.payerId !== 0) await api.settleShare(b.id, share.payerId, auth.authId)
      else await api.settleAtDesk(b.id, auth.authId)
      toast.success(t('settle.done', { amount: money(amount), name: who }))
      setCard('')
      onDone()
    } catch (e) {
      if (e instanceof Refused) setErr(tr(e.reason)); else toast.error(t('err.generic'))
    } finally { setBusy(false) }
  }
  return (
    <Dialog.Root open onOpenChange={(o) => !o && onClose()}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-[60] bg-black/40" />
        <Dialog.Content className="fixed inset-x-4 top-1/2 z-[70] mx-auto max-w-md -translate-y-1/2 rounded-lg border border-line bg-surface p-6 shadow-2">
          <form onSubmit={submit} noValidate>
            <div className="flex items-start justify-between gap-3">
              <Dialog.Title className="t-h2 text-ink">{t('settle.title', { name: who })}</Dialog.Title>
              <Dialog.Close className="grid h-9 w-9 place-items-center rounded-full hover:bg-surface-2" aria-label={t('console.cancel')}><X className="h-4 w-4" aria-hidden /></Dialog.Close>
            </div>
            <Dialog.Description className="mt-1 text-muted"><span dir="ltr">{b.ref}</span> · {t('settle.due', { amount: money(amount) })}</Dialog.Description>
            <p role="note" className="mt-5 flex items-start gap-3 rounded-base border border-accent p-3 t-small text-ink">
              <FlaskConical className="mt-0.5 h-4 w-4 shrink-0 text-accent" aria-hidden />
              <span>{t('settle.test')}</span>
            </p>
            <label htmlFor="settle-card" className="mt-5 block font-semibold text-ink">{t('pay.card')}</label>
            <input id="settle-card" inputMode="numeric" autoComplete="off" dir="ltr" value={card} onChange={(e) => setCard(groups(e.currentTarget.value))}
              placeholder="4242 4242 4242 4242" className="mt-1 block w-full rounded-base border border-field bg-bg px-3 py-2.5 text-ink nums tracking-wider" />
            {err && <p role="alert" className="mt-3 rounded-base border border-danger px-3 py-2 t-small font-semibold text-danger">{err}</p>}
            <button type="submit" disabled={busy || card.replace(/\D/g, '').length < 16}
              className="mt-6 w-full rounded-base bg-primary px-5 py-3.5 font-semibold text-primary-ink disabled:opacity-40">
              {busy ? t('pay.working') : t('settle.take', { amount: money(amount) })}
            </button>
          </form>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  )
}
