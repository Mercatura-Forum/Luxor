import { useApp } from '../app'

/** The three steps of a booking, so the guest always knows how far there is to go. */
export function Steps({ at }: { at: 0 | 1 | 2 }) {
  const { t, locale } = useApp()
  const f = new Intl.NumberFormat(locale)
  const steps = [t('steps.room'), t('steps.details'), t('steps.payment')]
  return (
    <ol className="flex items-center gap-2 t-small sm:gap-3" aria-label="Progress">
      {steps.map((s, i) => (
        <li key={s} className="flex items-center gap-2 sm:gap-3" aria-current={i === at ? 'step' : undefined}>
          <span className={`grid h-6 w-6 place-items-center rounded-full text-xs font-bold nums ${i <= at ? 'bg-primary text-primary-ink' : 'border border-line text-muted'}`}>{f.format(i + 1)}</span>
          <span className={i === at ? 'font-semibold text-ink' : 'text-muted'}>{s}</span>
          {i < steps.length - 1 && <span className="h-px w-6 bg-line sm:w-10" aria-hidden />}
        </li>
      ))}
    </ol>
  )
}
