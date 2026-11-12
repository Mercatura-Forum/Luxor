import { useEffect, useState } from 'react'
import { ShieldCheck, ShieldAlert } from 'lucide-react'
import { useApp } from '../app'
import type { SealView } from '../api/types'

/**
 * The hotel's books, checked where the guest can see it. The
 * figures come from the oracle; an empty list of violations is the proof, and the rules are one
 * click away in plain words.
 */
export function LuxorSeal({ compact = false }: { compact?: boolean }) {
  const { api, t, lang } = useApp()
  const [seal, setSeal] = useState<SealView | null>(null)
  const [open, setOpen] = useState(false)
  useEffect(() => { let live = true; api.seal().then((s) => live && setSeal(s)); return () => { live = false } }, [api])
  if (!seal) return <div className="h-5 w-64 skeleton rounded-base" aria-hidden />
  const Icon = seal.ok ? ShieldCheck : ShieldAlert
  return (
    <div className="t-small">
      <button type="button" onClick={() => setOpen(!open)} aria-expanded={open} className="flex items-start gap-2 text-start text-muted hover:text-ink">
        <Icon className={`mt-0.5 h-4 w-4 shrink-0 ${seal.ok ? 'text-success' : 'text-danger'}`} aria-hidden />
        <span>{!seal.ok ? t('seal.bad') : seal.scope === 'cash' ? t('seal.cash') : t('seal.ok', { n: new Intl.NumberFormat(lang === 'ar' ? 'ar-EG' : 'en-GB').format(seal.invariants) })}</span>
      </button>
      {open && !compact && <p className="mt-2 max-w-sm ps-6 text-muted">{t('seal.rules')}</p>}
    </div>
  )
}
