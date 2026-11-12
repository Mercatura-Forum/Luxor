import { Link, NavLink, Outlet, useLocation } from 'react-router-dom'
import { Moon, Sun } from 'lucide-react'
import { useApp } from '../app'
import { PageFrame } from './PageFrame'
import { useAccount } from '../lib/account'
import { LuxorSeal } from './LuxorSeal'
import { DemoStrip } from './DemoStrip'

function Wordmark() {
  const { tenant, tr } = useApp()
  return (
    <Link to="/" className="group flex items-baseline gap-2 no-underline" aria-label={tr(tenant.name)}>
      <span className="font-display text-[1.6rem] leading-none tracking-wide text-ink">{tr(tenant.name)}</span>
      <span className="t-eyebrow hidden text-muted sm:inline">{tr(tenant.place)}</span>
    </Link>
  )
}

export function Header({ overlay = false }: { overlay?: boolean }) {
  const { t, lang, setLang, mode, setMode } = useApp()
  const acct = useAccount()
  const tone = overlay ? 'text-white [&_a]:text-white' : 'text-ink'
  return (
    <header className={`${overlay ? 'absolute inset-x-0 top-0 z-30' : 'sticky top-0 z-30 border-b border-line bg-bg/92 backdrop-blur'} ${tone}`}>
      <div className="text-ink [&_a]:text-ink"><DemoStrip note="demo.note" /></div>
      <div className="mx-auto flex h-16 max-w-[1240px] items-center justify-between gap-4 px-5 sm:px-8">
        <div className={overlay ? '[&_span]:!text-white [&_.text-muted]:!text-white/80' : ''}><Wordmark /></div>
        <nav aria-label="Main" className="flex items-center gap-1 sm:gap-2">
          <NavLink to="/rooms" className="hidden rounded-base px-3 py-2 text-sm font-semibold no-underline hover:underline sm:inline">{t('nav.rooms')}</NavLink>
          <NavLink to="/console" className="hidden rounded-base px-3 py-2 text-sm font-semibold no-underline hover:underline md:inline">{t('nav.console')}</NavLink>
          {acct.available && (acct.signedIn
            ? <NavLink to="/stays" className="rounded-base px-3 py-2 text-sm font-semibold no-underline hover:underline">{t('account.stays')}</NavLink>
            : <button type="button" onClick={() => acct.signIn()} disabled={acct.busy} className="rounded-base px-3 py-2 text-sm font-semibold hover:underline">{t('account.signIn')}</button>)}
          <button type="button" onClick={() => setLang(lang === 'en' ? 'ar' : 'en')} className="rounded-base px-3 py-2 text-sm font-semibold hover:underline" lang={lang === 'en' ? 'ar' : 'en'}>
            {t('lang.switch')}
          </button>
          <button
            type="button"
            onClick={() => setMode(mode === 'dark' ? 'light' : 'dark')}
            className="grid h-9 w-9 place-items-center rounded-base hover:bg-surface-2/40"
            aria-label={mode === 'dark' ? t('mode.light') : t('mode.dark')}
          >
            {mode === 'dark' ? <Sun className="h-4 w-4" aria-hidden /> : <Moon className="h-4 w-4" aria-hidden />}
          </button>
        </nav>
      </div>
    </header>
  )
}

export function Footer() {
  const { tenant, tr, t, api, setTenant, sources, setSource } = useApp()
  return (
    <footer className="relative z-10 mt-24 border-t border-line bg-surface">
      <div className="mx-auto grid max-w-[1240px] gap-10 px-5 py-14 sm:px-8 md:grid-cols-[1.4fr_1fr_1fr]">
        <div className="space-y-3">
          <p className="font-display text-2xl text-ink">{tr(tenant.name)}</p>
          <p className="t-small text-muted">{tr(tenant.address)}</p>
          <p className="t-small text-muted"><bdi className="nums">{tenant.phone}</bdi> · {tenant.email}</p>
        </div>
        <div className="space-y-2 t-small text-muted">
          <p>{tr(tenant.checkIn)}</p>
          <p>{tr(tenant.checkOut)}</p>
        </div>
        <div className="space-y-3">
          <LuxorSeal />
        </div>
      </div>
      <div className="border-t border-line">
        <div className="mx-auto flex max-w-[1240px] flex-wrap items-center justify-between gap-3 px-5 py-5 t-small text-muted sm:px-8">
          {api.source === 'demo' && (
            <p className="flex items-center gap-2">
              <span className="rounded-base border border-accent px-2 py-0.5 font-bold text-accent">{t('demo.label')}</span>
              <span>{t('demo.note')}</span>
            </p>
          )}
          {sources.length > 1 && (
            <p className="flex items-center gap-2" role="group" aria-label={t('source.label')}>
              <span>{t('source.label')}</span>
              {sources.map((x) => (
                <button key={x} type="button" onClick={() => setSource(x)} aria-pressed={api.source === x}
                  className={`rounded-base border px-2 py-0.5 font-semibold ${api.source === x ? 'border-ink text-ink' : 'border-line text-muted'}`}>
                  {x === 'chain' ? t('source.chain') : t('demo.label')}
                </button>
              ))}
            </p>
          )}
          <p className="flex gap-3">
            <button type="button" className="underline" onClick={() => setTenant('almar')}>Almar</button>
            <button type="button" className="underline" onClick={() => setTenant('karnak')}>Karnak House</button>
          </p>
        </div>
      </div>
    </footer>
  )
}

export function Layout() {
  const { pathname } = useLocation()
  const home = pathname === '/'
  return (
    <PageFrame header={<Header overlay={home} />} footer={<Footer />}>
      <Outlet />
    </PageFrame>
  )
}
