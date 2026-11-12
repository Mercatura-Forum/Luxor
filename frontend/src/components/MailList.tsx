import { CheckCircle2, Clock, MinusCircle, XCircle } from 'lucide-react'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import type { MailRow } from '../api/types'

/** A booking's emails as the contract keeps them: which, and what became of each. Never an address:
 *  the contract cannot read it. Shared by the guest's booking page and the console's booking page. */
export function MailList({ rows, today }: { rows: MailRow[]; today?: number | null }) {
  const { t } = useApp()
  const { day, num } = useFormat()
  if (!rows.length) return <p className="t-small text-muted">{t('mail.none')}</p>
  return (
    <ul className="divide-y divide-line" data-mail-rows={rows.length}>
      {rows.map((r) => {
        const Icon = r.state === 'sent' ? CheckCircle2 : r.state === 'failed' ? XCircle : r.state === 'skipped' ? MinusCircle : Clock
        const later = r.state === 'due' && today != null && r.notBefore > today
        return (
          <li key={r.outboxId} className="flex items-start gap-3 py-2.5" data-mail-state={r.state}>
            <Icon className={`mt-0.5 h-4 w-4 shrink-0 ${r.state === 'failed' ? 'text-danger' : 'text-muted'}`} aria-hidden />
            <div className="min-w-0">
              <p className="text-ink">{t(`mail.kind.${r.kind}`)}</p>
              <p className={`t-small ${r.state === 'failed' ? 'font-semibold text-danger' : 'text-muted'}`}>
                {later ? t('mail.state.dueOn', { day: day(r.notBefore, 'long') }) : t(`mail.state.${r.state}`)}
                {r.failure && <> · {t(`mail.failure.${r.failure}`)}</>}
                {r.attempts > 1 && <> · <span className="nums">{t('mail.attempts', { n: num(r.attempts) })}</span></>}
              </p>
            </div>
          </li>
        )
      })}
    </ul>
  )
}
