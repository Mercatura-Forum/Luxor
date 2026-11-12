import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { ArrowRight, BadgePercent, CalendarDays } from 'lucide-react'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import { rateCode, stayQuery } from '../lib/stay'
import type { CalendarDay, StayRequest } from '../api/types'
import { Akhet } from './Akhet'
import { DatePicker } from './DatePicker'
import { GuestsPicker } from './GuestsPicker'

/**
 * The BookingBar (Almar's signature) fused with Akhet: the dates, the party and the search in one
 * rail, with the coming nights' real prices drawn above it. Choosing a stay on the horizon or in the
 * picker updates the rail; the search goes to the results with the stay in the address.
 */
export function BookingBar({ initial, withHorizon = true, className = '' }: { initial: StayRequest; withHorizon?: boolean; className?: string }) {
  const { api, t } = useApp()
  const { day: fmtDay, num } = useFormat()
  const nav = useNavigate()
  const [stay, setStay] = useState<StayRequest>(initial)
  const [open, setOpen] = useState(false)
  const [focusDay, setFocusDay] = useState<number | undefined>()
  const [days, setDays] = useState<CalendarDay[] | null>(null)
  // a company's or a promotion's code, typed by the guest who has one; it travels with the stay
  const [codeOpen, setCodeOpen] = useState(Boolean(initial.code))
  const [codeText, setCodeText] = useState(initial.code ?? '')
  const codeBad = codeText.trim() !== '' && rateCode(codeText) === ''

  useEffect(() => {
    let live = true
    api.property().then((p) => api.calendar(0, p.businessDate, 60)).then((d) => live && setDays(d))
    return () => { live = false }
  }, [api])

  const departure = stay.arrival + stay.nights
  const go = () => {
    if (codeBad) return
    const code = rateCode(codeText)
    nav(`/rooms?${stayQuery({ ...stay, code: code || undefined })}`)
  }

  return (
    <div className={`rounded-lg border border-line bg-surface p-3 shadow-2 sm:p-4 ${className}`}>
      {withHorizon && (
        <div className="px-1 pb-3 sm:px-2">
          <Akhet
            days={days}
            arrival={stay.arrival}
            nights={stay.nights}
            onChange={(arrival, nights) => setStay({ ...stay, arrival, nights: Math.max(1, nights) })}
            onOpenDay={(d) => { setFocusDay(d); setOpen(true) }}
          />
        </div>
      )}
      <form onSubmit={(e) => { e.preventDefault(); go() }} className="flex flex-col gap-2 sm:flex-row sm:items-stretch sm:gap-0 sm:rounded-base sm:border sm:border-line sm:bg-bg/40">
        <button type="button" onClick={() => { setFocusDay(undefined); setOpen(true) }} className="flex flex-1 flex-col items-start gap-1 rounded-base border border-line px-4 py-2 text-start sm:border-0">
          <span className="t-eyebrow flex items-center gap-1.5 text-muted"><CalendarDays className="h-3.5 w-3.5 text-accent" aria-hidden />{t('bar.dates')}</span>
          <span className="font-semibold text-ink">
            <bdi>{fmtDay(stay.arrival, 'weekday')}</bdi> <span aria-hidden>→</span> <bdi>{fmtDay(departure, 'weekday')}</bdi>
            <span className="ms-2 text-muted nums">{stay.nights === 1 ? t('bar.night') : t('bar.nights', { n: num(stay.nights) })}</span>
          </span>
        </button>
        <span className="hidden w-px self-stretch bg-line sm:block" aria-hidden />
        <div className="rounded-base border border-line sm:w-72 sm:border-0">
          <GuestsPicker value={stay} onChange={(g) => setStay({ ...stay, ...g })} />
        </div>
        <button type="submit" className="inline-flex items-center justify-center gap-2 rounded-base bg-primary px-6 py-3.5 font-semibold text-primary-ink transition hover:opacity-90 sm:m-1">
          {t('bar.search')}
          <ArrowRight className="h-4 w-4 rtl:rotate-180" aria-hidden />
        </button>
      </form>
      <div className="mt-2 px-1 sm:px-2">
        {codeOpen ? (
          <label className="flex flex-wrap items-center gap-2">
            <span className="t-small flex items-center gap-1.5 font-semibold text-ink"><BadgePercent className="h-3.5 w-3.5 text-accent" aria-hidden />{t('code.field')}</span>
            <input data-rate-code value={codeText} maxLength={16} onChange={(e) => setCodeText(e.currentTarget.value.toUpperCase())}
              onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); go() } }}
              autoComplete="off" dir="ltr" placeholder={t('code.example')}
              className="w-44 rounded-base border border-field bg-bg px-3 py-1.5 font-mono text-sm text-ink" />
            {codeBad && <span className="t-small text-danger">{t('code.shape')}</span>}
          </label>
        ) : (
          <button type="button" onClick={() => setCodeOpen(true)} className="t-small inline-flex items-center gap-1.5 font-semibold text-muted underline underline-offset-4 hover:text-ink">
            <BadgePercent className="h-3.5 w-3.5" aria-hidden />{t('code.have')}
          </button>
        )}
      </div>
      <DatePicker open={open} onOpenChange={setOpen} arrival={stay.arrival} nights={stay.nights} focusDay={focusDay}
        onChoose={(arrival, nights) => setStay({ ...stay, arrival, nights })} />
    </div>
  )
}
