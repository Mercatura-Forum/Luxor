import { ShieldCheck } from 'lucide-react'
import { useApp } from '../app'

/** What the console shows someone who is not signed in as staff: a plain sentence, and on a review
 *  build a way to look around on demo data. */
export function StaffOnly() {
  const { t, sources, setSource } = useApp()
  return (
    <div className="mt-8 flex flex-col items-start gap-4 rounded-lg border border-line bg-surface p-8 shadow-1" data-staff-only>
      <ShieldCheck className="h-6 w-6 text-accent" aria-hidden />
      <p className="max-w-lg text-ink">{t('console.staffOnly')}</p>
      {sources.includes('demo') && (
        <button type="button" onClick={() => setSource('demo')} className="rounded-base border border-ink px-4 py-2.5 font-semibold text-ink">{t('console.tryDemo')}</button>
      )}
    </div>
  )
}
