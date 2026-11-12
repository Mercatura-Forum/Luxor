/**
 * The app's context: which property (tenant), which language and direction, which mode, and which
 * data source. The document root carries data-tenant / data-mode / lang / dir, so the tokens in
 * index.css answer for every component and nothing else needs to know.
 */
import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import { DirectionProvider } from '@radix-ui/react-direction'
import { lazyDemoApi } from './api/lazyDemo'
import { chainApi, chainConfig } from './api/chain'
import { INJECTED, chainActive, read, reviewBuild, store } from './lib/prefs'
import type { Api, Bi } from './api/types'
import { TENANTS, type Tenant, type TenantId } from './theme/tenants'
import { dict } from './i18n'

export type Lang = 'en' | 'ar'
export type Mode = 'light' | 'dark'

interface Ctx {
  tenant: Tenant
  setTenant(t: TenantId): void
  lang: Lang
  dir: 'ltr' | 'rtl'
  setLang(l: Lang): void
  mode: Mode
  setMode(m: Mode): void
  api: Api
  /** Offered only on a review build that has both sources. */
  sources: ('chain' | 'demo')[]
  setSource(s: 'chain' | 'demo'): void
  /** The property this page runs on the chain, if it runs one: the live hotel. */
  live: TenantId | undefined
  /** Back to the live hotel: its property, on the chain. */
  goLive(): void
  /** A bilingual pair in the current language, falling back to the other rather than to nothing. */
  tr(pair: Bi | undefined): string
  /** A dictionary string; `{name}` placeholders are filled from `vars`. */
  t(key: keyof typeof dict, vars?: Record<string, string | number>): string
  locale: string
}

const AppContext = createContext<Ctx | null>(null)


function preferredMode(): Mode {
  return typeof matchMedia !== 'undefined' && matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'
}



export function AppProvider({ children }: { children: ReactNode }) {
  const [tenantId, setTenantId] = useState<TenantId>(() => read('luxor:tenant', ['almar', 'karnak'] as const, INJECTED, 'visit'))
  const [lang, setLangState] = useState<Lang>(() => read('luxor:lang', ['en', 'ar'] as const, 'en'))
  const [mode, setModeState] = useState<Mode>(() => read('luxor:mode', ['light', 'dark'] as const, preferredMode()))
  const tenant = TENANTS[tenantId]
  const dir = lang === 'ar' ? 'rtl' : 'ltr'
  // the chain when this page is configured for one (a deploy injects the contract ids), the demo otherwise
  // a review build offers both, switched in the footer; a deploy that injects its contract ids is chain only
  const [source, setSourceState] = useState<'chain' | 'demo'>(() => read('luxor:source', ['chain', 'demo'] as const, 'chain', 'visit'))
  const api = useMemo(() => {
    const cfg = chainConfig()
    // a chain holds one property: another property on the same page stays on its demo data
    return cfg && chainActive(cfg, tenantId, source) ? chainApi(tenantId, cfg) : lazyDemoApi(tenantId)
  }, [tenantId, source])

  useEffect(() => {
    const root = document.documentElement
    root.dataset.tenant = tenantId
    root.dataset.mode = mode
    root.lang = lang
    root.dir = dir
    document.title = `${tenant.name[lang]} · ${tenant.place[lang]}`
    try {
      store('visit').setItem('luxor:tenant', tenantId)
      localStorage.setItem('luxor:lang', lang)
      localStorage.setItem('luxor:mode', mode)
    } catch { /* storage blocked */ }
  }, [tenantId, mode, lang, dir, tenant])

  const tr = useCallback((p: Bi | undefined) => (p ? p[lang] || p[lang === 'en' ? 'ar' : 'en'] : ''), [lang])
  const t = useCallback(
    (key: keyof typeof dict, vars?: Record<string, string | number>) => {
      let s: string = dict[key][lang]
      if (vars) for (const [k, v] of Object.entries(vars)) s = s.replaceAll(`{${k}}`, String(v))
      return s
    },
    [lang],
  )

  const value: Ctx = {
    tenant, setTenant: setTenantId, lang, dir, setLang: setLangState, mode, setMode: setModeState, api, tr, t,
    sources: chainConfig() && reviewBuild() ? ['chain', 'demo'] : [], setSource: (x) => { try { store('visit').setItem('luxor:source', x) } catch { /* memory only */ } setSourceState(x) },
    live: chainConfig()?.tenant as TenantId | undefined,
    goLive: () => {
      const cfg = chainConfig()
      if (!cfg) return
      try { store('visit').setItem('luxor:source', 'chain') } catch { /* memory only */ }
      setSourceState('chain'); setTenantId(cfg.tenant as TenantId)
    },
    locale: lang === 'en' ? tenant.locale.en : tenant.locale.ar,
  }
  return (
    <AppContext.Provider value={value}>
      <DirectionProvider dir={dir}>{children}</DirectionProvider>
    </AppContext.Provider>
  )
}

export function useApp(): Ctx {
  const c = useContext(AppContext)
  if (!c) throw new Error('useApp outside AppProvider')
  return c
}
