import { useEffect, useState, type ReactNode } from 'react'
import { Link, NavLink, Outlet, useLocation } from 'react-router-dom'
import * as Dialog from '@radix-ui/react-dialog'
import { BadgePercent, BedDouble, Users, BookOpen, PhoneCall, Building2, CalendarCheck, CalendarRange, ChartColumn, ShoppingBag, ExternalLink, LayoutGrid, Mail, Menu, Moon, MoonStar, ShieldCheck, Sun, UsersRound, X, type LucideIcon } from 'lucide-react'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import { DemoStrip } from '../components/DemoStrip'
import type { dict } from '../i18n'

type Item = { to: string; end?: boolean; label: keyof typeof dict; icon: LucideIcon }

/** The console's sections, in the order a hotel's day uses them: the desk first, then the inventory. */
const ITEMS: Item[] = [
  { to: '/console', end: true, label: 'console.navToday', icon: CalendarCheck },
  { to: '/console/rates', label: 'console.navRates', icon: LayoutGrid },
  { to: '/console/products', label: 'console.navProducts', icon: BadgePercent },
  { to: '/console/groups', label: 'console.navGroups', icon: Users },
  { to: '/console/book', label: 'console.navBook', icon: PhoneCall },
  { to: '/console/bookings', label: 'console.navBookings', icon: BookOpen },
  { to: '/console/room-plan', label: 'console.navRoomPlan', icon: CalendarRange },
  { to: '/console/housekeeping', label: 'console.navHousekeeping', icon: BedDouble },
  { to: '/console/extras', label: 'console.navExtras', icon: ShoppingBag },
  { to: '/console/approvals', label: 'console.navApprovals', icon: ShieldCheck },
  { to: '/console/audit', label: 'console.navAudit', icon: MoonStar },
  { to: '/console/reports', label: 'console.navReports', icon: ChartColumn },
  { to: '/console/staff', label: 'console.navStaff', icon: UsersRound },
  { to: '/console/setup', label: 'console.navSetup', icon: Building2 },
  { to: '/console/email', label: 'console.navMail', icon: Mail },
]

/** The hotel's own day, as the property holds it (the night audit moves it), re-read on every section. */
function useHotelDay(): number | null {
  const { api } = useApp()
  const { pathname } = useLocation()
  const [d, setD] = useState<number | null>(null)
  useEffect(() => { let live = true; api.property().then((p) => live && setD(p.businessDate)).catch(() => {}); return () => { live = false } }, [api, pathname])
  return d
}

function Nav({ onPick }: { onPick?: () => void }) {
  const { t } = useApp()
  return (
    <nav aria-label={t('nav.console')} className="flex flex-col gap-0.5">
      {ITEMS.map(({ to, end, label, icon: Icon }) => (
        <NavLink key={to} to={to} end={end} onClick={onPick}
          className={({ isActive }) => `flex items-center gap-3 rounded-base px-3 py-2.5 font-semibold no-underline ${isActive ? 'bg-primary text-primary-ink' : 'text-ink hover:bg-surface-2'}`}>
          <Icon className="h-4 w-4 shrink-0" aria-hidden />{t(label)}
        </NavLink>
      ))}
    </nav>
  )
}

function Prefs() {
  const { t, lang, setLang, mode, setMode } = useApp()
  return (
    <div className="flex items-center gap-1">
      <button type="button" onClick={() => setLang(lang === 'en' ? 'ar' : 'en')} lang={lang === 'en' ? 'ar' : 'en'}
        className="rounded-base px-3 py-2 t-small font-semibold text-ink hover:bg-surface-2">{t('lang.switch')}</button>
      <button type="button" onClick={() => setMode(mode === 'dark' ? 'light' : 'dark')} aria-label={mode === 'dark' ? t('mode.light') : t('mode.dark')}
        className="grid h-9 w-9 place-items-center rounded-base text-ink hover:bg-surface-2">
        {mode === 'dark' ? <Sun className="h-4 w-4" aria-hidden /> : <Moon className="h-4 w-4" aria-hidden />}
      </button>
    </div>
  )
}

/**
 * THE CONSOLE'S FRAME: the hotel team's own screen, not the guest site's. A side menu on a laptop, a
 * sheet on a phone, the hotel's day always in view, and the demo strip whenever the data is not the hotel's.
 */
export default function ConsoleShell() {
  const { t, tr, tenant } = useApp()
  const { day } = useFormat()
  const hotelDay = useHotelDay()
  const [open, setOpen] = useState(false)
  const dayChip: ReactNode = hotelDay !== null && (
    <p className="t-small text-muted">{t('console.hotelDay')} <span className="font-semibold text-ink">{day(hotelDay, 'weekday')}</span></p>
  )
  return (
    <div className="min-h-dvh bg-bg">
      <a href="#main" className="sr-only focus:not-sr-only focus:absolute focus:z-50 focus:m-2 focus:rounded-base focus:bg-surface focus:p-3">{t('a11y.skip')}</a>
      <DemoStrip />
      <div className="lg:grid lg:grid-cols-[240px_minmax(0,1fr)] print:!block">
        <aside className="sticky top-0 hidden h-dvh print:!hidden flex-col gap-6 border-e border-line bg-surface px-4 py-6 lg:flex">
          <div className="px-3">
            <Link to="/" className="font-display text-2xl text-ink no-underline">{tr(tenant.name)}</Link>
            <p className="t-eyebrow mt-1 text-muted">{t('nav.console')}</p>
            <div className="mt-3">{dayChip}</div>
          </div>
          <Nav />
          <div className="mt-auto space-y-2 px-1">
            <Link to="/" className="flex items-center gap-2 rounded-base px-2 py-2 t-small font-semibold text-ink no-underline hover:bg-surface-2">
              <ExternalLink className="h-4 w-4" aria-hidden />{t('console.guestSite')}
            </Link>
            <Prefs />
          </div>
        </aside>

        <header className="sticky top-0 z-30 flex print:hidden items-center justify-between gap-3 border-b border-line bg-surface/95 px-4 py-3 backdrop-blur lg:hidden">
          <div className="min-w-0">
            <p className="font-display text-xl leading-tight text-ink">{tr(tenant.name)}</p>
            {dayChip}
          </div>
          <Dialog.Root open={open} onOpenChange={setOpen}>
            <Dialog.Trigger className="grid h-10 w-10 place-items-center rounded-base border border-line text-ink" aria-label={t('console.menu')}>
              <Menu className="h-5 w-5" aria-hidden />
            </Dialog.Trigger>
            <Dialog.Portal>
              <Dialog.Overlay className="fixed inset-0 z-40 bg-black/35" />
              <Dialog.Content className="fixed inset-y-0 start-0 z-50 flex w-[min(86vw,320px)] flex-col gap-6 overflow-y-auto border-e border-line bg-surface p-5 shadow-2">
                <div className="flex items-start justify-between gap-3">
                  <div>
                    <Dialog.Title className="font-display text-2xl text-ink">{tr(tenant.name)}</Dialog.Title>
                    <Dialog.Description className="t-eyebrow mt-1 text-muted">{t('nav.console')}</Dialog.Description>
                  </div>
                  <Dialog.Close className="grid h-9 w-9 place-items-center rounded-full hover:bg-surface-2" aria-label={t('console.cancel')}><X className="h-4 w-4" aria-hidden /></Dialog.Close>
                </div>
                <Nav onPick={() => setOpen(false)} />
                <div className="mt-auto space-y-2">
                  <Link to="/" onClick={() => setOpen(false)} className="flex items-center gap-2 rounded-base px-2 py-2 t-small font-semibold text-ink no-underline hover:bg-surface-2">
                    <ExternalLink className="h-4 w-4" aria-hidden />{t('console.guestSite')}
                  </Link>
                  <Prefs />
                </div>
              </Dialog.Content>
            </Dialog.Portal>
          </Dialog.Root>
        </header>

        <main id="main" className="min-w-0 px-4 pb-24 pt-6 sm:px-8 lg:pt-8">
          <Outlet />
        </main>
      </div>
    </div>
  )
}

/** A console screen's heading: its title, an optional line under it, and the screen's own actions. */
export function ScreenHead({ title, sub, actions }: { title: string; sub?: ReactNode; actions?: ReactNode }) {
  return (
    <div className="flex flex-wrap items-end justify-between gap-4">
      <div className="min-w-0">
        <h1 className="t-h1 text-ink">{title}</h1>
        {sub && <div className="t-small mt-1.5 max-w-2xl text-muted">{sub}</div>}
      </div>
      {actions && <div className="flex flex-wrap items-center gap-2">{actions}</div>}
    </div>
  )
}
