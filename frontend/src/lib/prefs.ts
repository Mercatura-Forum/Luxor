/**
 * The page's preferences (property, language, mode, data source) and the decision of which data source
 * a property uses. Shared by the app and the early-data script, which must reach the same answer
 * before the app has loaded.
 */
import type { ChainConfig } from '../api/wire'
import type { TenantId } from '../theme/tenants'

/** Where a preference is kept: language and mode for good (this browser), the property and the data
 *  source for this visit only, so a visitor who looked at sample data comes back to the live hotel. */
export type Keep = 'browser' | 'visit'

export function store(keep: Keep): Storage { return keep === 'visit' ? sessionStorage : localStorage }

export function read<T extends string>(key: string, allowed: readonly T[], fallback: T, keep: Keep = 'browser'): T {
  try {
    const url = new URLSearchParams(location.hash.split('?')[1] ?? '')
    const fromUrl = url.get(key.split(':').pop() ?? '')
    if (fromUrl && (allowed as readonly string[]).includes(fromUrl)) return fromUrl as T
    const v = store(keep).getItem(key)
    if (v && (allowed as readonly string[]).includes(v)) return v as T
  } catch { /* storage blocked: defaults */ }
  return fallback
}

/** A review build: the dev server, configured for a chain by its environment rather than by a deploy. */
export function reviewBuild(): boolean {
  return !(window as unknown as { LUXOR_CID?: number }).LUXOR_CID && !!(import.meta.env as Record<string, string | undefined>).VITE_LUXOR_CID
}

export const INJECTED: TenantId = (typeof window !== 'undefined' && (window as unknown as { LUXOR_TENANT?: TenantId }).LUXOR_TENANT) || 'almar'

/** A chain holds one property: another property on the same page stays on its demo data. A review build
 *  offers both sources, switched in the footer; a deploy that injects its contract ids is chain only. */
export function chainActive(cfg: ChainConfig, tenantId: TenantId, source: 'chain' | 'demo'): boolean {
  return cfg.tenant === tenantId && (source === 'chain' || !reviewBuild())
}
