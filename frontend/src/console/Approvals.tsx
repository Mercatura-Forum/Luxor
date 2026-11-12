import { useCallback, useEffect, useState } from 'react'
import { toast } from '../lib/toast'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import { Refused, type ProposalView } from '../api/types'
import { StaffOnly } from './StaffOnly'

export function useActText() {
  const { t } = useApp()
  const { money } = useFormat()
  return (p: Pick<ProposalView, 'act' | 'ref' | 'amount' | 'text'>) => {
    if (p.act === 'staffCancel') return p.amount === 1n ? t('act.staffCancelWaive', { ref: p.ref }) : t('act.staffCancel', { ref: p.ref })
    if (p.act === 'refundOutsidePolicy' || p.act === 'priceOverride') return t(`act.${p.act}`, { ref: p.ref, amount: money(p.amount) })
    if (p.act === 'editGuestRecord') return t('act.editGuestRecord', { ref: p.ref, text: p.text })
    if (p.act === 'voidCharge') return t('act.voidCharge', { ref: p.ref, text: p.text })
    // a credit note: its figure before tax, and the invoice it amends; a desk refund: the method and reference
    if (p.act === 'issueCreditNote') return t('act.issueCreditNote', { ref: p.ref, amount: money(p.amount), text: p.text })
    if (p.act === 'refundAtDesk') {
      const [method, ...reference] = p.text.split(' ')
      return t('act.refundAtDesk', { ref: p.ref, method: t(method === 'cash' ? 'deskRefund.cash' : 'deskRefund.transfer'), text: reference.join(' ') })
    }
    return t(`act.${p.act as 'waivePenalty' | 'compNights'}`, { ref: p.ref })
  }
}

/** Four eyes at the desk: what is waiting, and a different person's approval or rejection. */
export default function Approvals() {
  const { api, t, tr } = useApp()
  const actText = useActText()
  const [rows, setRows] = useState<ProposalView[] | null>(null)
  const [denied, setDenied] = useState(false)
  const [rejecting, setRejecting] = useState<number | null>(null)
  const [why, setWhy] = useState('')
  const [busy, setBusy] = useState(0)

  const load = useCallback(async () => {
    try { setRows(await api.proposals()); setDenied(false) }
    catch (e) { if (e instanceof Refused && e.kind === 'notAuthorised') setDenied(true); else toast.error(t('err.generic')) }
  }, [api, t])
  useEffect(() => { load() }, [load])

  const act = async (id: number, f: () => Promise<void>, ok: string) => {
    setBusy(id)
    try { await f(); toast.success(ok); setRejecting(null); setWhy(''); await load() }
    catch (e) { toast.error(e instanceof Refused ? tr(e.reason) : t('err.generic')) }
    finally { setBusy(0) }
  }

  return (
    <div className="mx-auto max-w-[1240px]">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="t-h1 mt-1 text-ink">{t('approvals.title')}</h1>
          <p className="t-small mt-2 max-w-xl text-muted">{t('approvals.lead')}</p>
        </div>
      </div>
      {denied ? <StaffOnly /> : (
        <ul className="mt-8 space-y-3">
          {rows === null && [0, 1].map((i) => <li key={i} className="skeleton h-20 rounded-lg" aria-hidden />)}
          {rows?.length === 0 && <li className="rounded-lg border border-dashed border-line p-6 text-muted">{t('approvals.none')}</li>}
          {rows?.map((p) => (
            <li key={p.id} className="rounded-lg border border-line bg-surface p-4 shadow-1">
              <div className="flex flex-wrap items-center justify-between gap-4">
                <div>
                  <p className="font-semibold text-ink">{actText(p)}</p>
                  {p.mine && <p className="t-small text-muted">{t('approvals.mine')}</p>}
                </div>
                {!p.mine && (
                  <div className="flex gap-2">
                    <button type="button" disabled={busy === p.id} onClick={() => act(p.id, () => api.approve(p.id), t('approvals.done'))}
                      className="rounded-base bg-primary px-4 py-2.5 font-semibold text-primary-ink disabled:opacity-50">{t('approvals.approve')}</button>
                    <button type="button" onClick={() => setRejecting(rejecting === p.id ? null : p.id)} className="rounded-base border border-ink px-4 py-2.5 font-semibold text-ink">{t('approvals.reject')}</button>
                  </div>
                )}
              </div>
              {rejecting === p.id && (
                <form className="mt-3 flex flex-wrap gap-2" onSubmit={(e) => { e.preventDefault(); act(p.id, () => api.reject(p.id, why), t('approvals.reject')) }}>
                  <input value={why} onChange={(e) => setWhy(e.currentTarget.value)} placeholder={t('approvals.why')} aria-label={t('approvals.why')}
                    className="min-w-0 flex-1 rounded-base border border-field bg-bg px-3 py-2 text-ink" />
                  <button type="submit" disabled={!why.trim() || busy === p.id} className="rounded-base bg-danger px-4 py-2 font-semibold text-bg disabled:opacity-40">{t('approvals.reject')}</button>
                </form>
              )}
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
