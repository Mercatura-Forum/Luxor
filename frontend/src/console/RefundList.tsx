import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import type { RefundState, RefundView } from '../api/types'

const STATE_KEY: Record<RefundState, 'refund.due' | 'refund.done' | 'refund.failed' | 'refund.paidAtDesk'> = {
  due: 'refund.due', done: 'refund.done', failed: 'refund.failed', paidAtDesk: 'refund.paidAtDesk',
}
const STATE_TONE: Record<RefundState, string> = {
  due: 'border-line text-muted', done: 'border-success/50 text-success', failed: 'border-danger/60 bg-danger/10 text-danger', paidAtDesk: 'border-line text-ink',
}

/**
 * WHERE A REFUND GOES: each refund with the card it goes back to, as the gateway names it, and where it
 * stands. A refund to the guest split across the guest's cards is shown as one group, its parts in the
 * order drawn (the newest card first), so the guest knows to look on every card listed.
 */
export function RefundList({ refunds }: { refunds: RefundView[] }) {
  const { t } = useApp()
  const { money, num } = useFormat()
  const groups: RefundView[][] = []
  for (const r of refunds) {
    const last = groups.at(-1)
    if (last && r.firstSlice !== 0 && last[0].firstSlice === r.firstSlice) last.push(r); else groups.push([r])
  }
  return (
    <ul className="space-y-2">
      {groups.map((g) => (
        <li key={g[0].paymentId} className="t-small">
          {g.length > 1 && <p className="mb-1 text-muted">{t('refund.split', { amount: money(g[0].excess), n: num(g.length) })}</p>}
          <ul className="space-y-1">
            {g.map((r) => (
              <li key={r.paymentId} className="flex flex-wrap items-center gap-x-3 gap-y-1" data-refund={r.paymentId} data-refund-card={r.card} data-refund-state={r.state}>
                <span className="w-24 shrink-0 nums font-semibold text-ink">{money(r.amount)}</span>
                <span className="min-w-0 flex-1 text-ink">{r.card === 0 ? t('refund.noCard') : <>{t('refund.card')} <bdi className="nums" dir="ltr">#{r.card}</bdi></>}</span>
                <span className={`rounded-sm border px-2 py-0.5 ${STATE_TONE[r.state]}`}>{t(r.card === 0 && r.state === 'failed' ? 'refund.toDesk' : STATE_KEY[r.state])}</span>
              </li>
            ))}
          </ul>
        </li>
      ))}
    </ul>
  )
}
