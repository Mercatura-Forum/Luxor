import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { toast } from '../lib/toast'
import { useApp } from '../app'
import { useAccount } from '../lib/account'
import { useFormat } from '../lib/useFormat'
import { Refused, type BookingView, type RoomTypeView, type WaitView } from '../api/types'

/** The account holder's stays and waitlist places, read with their passkey session. */
export default function MyStays() {
  const { api, t, tr } = useApp()
  const acct = useAccount()
  const { money, day } = useFormat()
  const [stays, setStays] = useState<BookingView[] | null>(null)
  const [waits, setWaits] = useState<WaitView[]>([])
  const [types, setTypes] = useState<RoomTypeView[]>([])
  const [today, setToday] = useState(0)

  const load = useCallback(async () => {
    if (!acct.ready) return
    const [s, w, rt, p] = await Promise.all([api.myStays(acct.token), api.myWaitlist(acct.token), api.roomTypes(), api.property()])
    setStays(s); setWaits(w.filter((x) => x.state !== 'left')); setTypes(rt); setToday(p.businessDate)
  }, [api, acct.ready, acct.token])
  useEffect(() => { load() }, [load])

  if (!acct.available || !acct.signedIn) return (
    <div className="mx-auto max-w-2xl px-5 pt-16 sm:px-8">
      <h1 className="t-h1 text-ink">{t('account.stays')}</h1>
      <p className="mt-4 text-ink">{t(acct.available ? 'account.signInFor' : 'account.offline')}</p>
      {acct.available && <button type="button" onClick={() => acct.signIn()} className="mt-6 rounded-base bg-primary px-5 py-3 font-semibold text-primary-ink">{t('account.signIn')}</button>}
    </div>
  )

  const name = (id: number) => tr(types.find((x) => x.id === id)?.name)
  const upcoming = (stays ?? []).filter((b) => b.departure > today && b.status !== 'cancelled')
  const past = (stays ?? []).filter((b) => !(b.departure > today && b.status !== 'cancelled'))
  const Row = ({ b }: { b: BookingView }) => (
    <li className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-line bg-surface p-4">
      <div>
        <p className="font-display text-lg text-ink">{name(b.roomTypeId)}</p>
        <p className="t-small text-muted"><bdi>{day(b.arrival, 'weekday')}</bdi> → <bdi>{day(b.departure, 'weekday')}</bdi> · <span dir="ltr">{b.ref}</span></p>
      </div>
      <span className="t-small font-semibold text-ink nums">{money(b.charged - b.credited)} · {t(`manage.status.${b.status}` as 'manage.status.confirmed')}</span>
    </li>
  )
  const leave = async (id: number) => {
    try { await api.leaveWaitlist(acct.token, id); await load() } catch (e) { toast.error(e instanceof Refused ? tr(e.reason) : t('err.generic')) }
  }

  return (
    <div className="mx-auto max-w-3xl px-5 pb-20 pt-12 sm:px-8">
      <p className="t-eyebrow text-muted">{acct.name}</p>
      <h1 className="t-h1 mt-2 text-ink">{t('account.stays')}</h1>
      {waits.length > 0 && (
        <section className="mt-8">
          <h2 className="t-eyebrow text-muted">{t('account.waitlist')}</h2>
          <ul className="mt-3 space-y-3">
            {waits.map((w) => (
              <li key={w.id} className={`rounded-lg border p-4 ${w.state === 'offered' ? 'border-accent bg-surface' : 'border-line'}`}>
                <p className="font-display text-lg text-ink">{name(w.roomTypeId)}</p>
                <p className="t-small text-muted"><bdi>{day(w.arrival, 'weekday')}</bdi> → <bdi>{day(w.arrival + w.nights, 'weekday')}</bdi></p>
                <p className="mt-2 text-ink">{w.state === 'offered' ? t('account.offer', { price: money(w.offerTotal) }) : t('account.waiting')}</p>
                {w.state === 'waiting' && <button type="button" onClick={() => leave(w.id)} className="mt-2 t-small font-semibold text-ink underline">{t('account.leave')}</button>}
              </li>
            ))}
          </ul>
        </section>
      )}
      <section className="mt-8">
        <h2 className="t-eyebrow text-muted">{t('account.upcoming')}</h2>
        {stays === null ? <div className="skeleton mt-3 h-20 rounded-lg" aria-hidden /> : upcoming.length === 0
          ? <p className="mt-3 text-muted">{t('account.none')} <Link to="/" className="font-semibold text-ink underline">{t('bar.search')}</Link></p>
          : <ul className="mt-3 space-y-3">{upcoming.map((b) => <Row key={b.id} b={b} />)}</ul>}
      </section>
      {past.length > 0 && (
        <section className="mt-8">
          <h2 className="t-eyebrow text-muted">{t('account.past')}</h2>
          <ul className="mt-3 space-y-3">{past.map((b) => <Row key={b.id} b={b} />)}</ul>
        </section>
      )}
    </div>
  )
}
