import * as Popover from '@radix-ui/react-popover'
import { Minus, Plus, Users } from 'lucide-react'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'

type Guests = { adults: number; children: number; rooms: number }

function Stepper({ label, hint, value, min, max, onChange }: { label: string; hint?: string; value: number; min: number; max: number; onChange(v: number): void }) {
  const { t } = useApp()
  const { num } = useFormat()
  return (
    <div className="flex items-center justify-between gap-6 py-3">
      <div>
        <p className="font-semibold text-ink">{label}</p>
        {hint && <p className="t-small text-muted">{hint}</p>}
      </div>
      <div className="flex items-center gap-3">
        <button type="button" disabled={value <= min} onClick={() => onChange(value - 1)} aria-label={t('guests.less', { what: label })}
          className="grid h-9 w-9 place-items-center rounded-full border border-line text-ink disabled:opacity-35 hover:border-ink">
          <Minus className="h-4 w-4" aria-hidden />
        </button>
        <span className="w-6 text-center nums font-semibold" aria-live="polite">{num(value)}</span>
        <button type="button" disabled={value >= max} onClick={() => onChange(value + 1)} aria-label={t('guests.more', { what: label })}
          className="grid h-9 w-9 place-items-center rounded-full border border-line text-ink disabled:opacity-35 hover:border-ink">
          <Plus className="h-4 w-4" aria-hidden />
        </button>
      </div>
    </div>
  )
}

/** Adults, children and rooms, with the age bands stated in the control (Tandjung Sari's pattern). */
export function GuestsPicker({ value, onChange, className = '' }: { value: Guests; onChange(v: Guests): void; className?: string }) {
  const { t } = useApp()
  const { num } = useFormat()
  const summary = t('guests.summary', { a: num(value.adults), c: num(value.children), r: num(value.rooms) })
  return (
    <Popover.Root>
      <Popover.Trigger className={`flex w-full flex-col items-start gap-1 px-4 py-2 text-start ${className}`}>
        <span className="t-eyebrow flex items-center gap-1.5 text-muted"><Users className="h-3.5 w-3.5 text-accent" aria-hidden />{t('bar.guests')}</span>
        <span className="font-semibold text-ink">{summary}</span>
      </Popover.Trigger>
      <Popover.Portal>
        <Popover.Content sideOffset={10} align="start" className="z-50 w-[min(92vw,340px)] rounded-lg border border-line bg-surface p-4 shadow-2">
          <Stepper label={t('guests.adults')} hint={t('guests.adultsHint')} value={value.adults} min={1} max={12} onChange={(adults) => onChange({ ...value, adults })} />
          <div className="border-t border-line" />
          <Stepper label={t('guests.children')} hint={t('guests.childrenHint')} value={value.children} min={0} max={8} onChange={(children) => onChange({ ...value, children })} />
          <div className="border-t border-line" />
          <Stepper label={t('guests.rooms')} value={value.rooms} min={1} max={4} onChange={(rooms) => onChange({ ...value, rooms })} />
          <Popover.Close className="mt-3 w-full rounded-base bg-primary px-4 py-2.5 font-semibold text-primary-ink">{t('guests.done')}</Popover.Close>
        </Popover.Content>
      </Popover.Portal>
    </Popover.Root>
  )
}
