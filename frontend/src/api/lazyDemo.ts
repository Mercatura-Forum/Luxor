/**
 * The demo data source, loaded when first used. A property on the chain never loads it, so it is not in
 * the first script; a property on demo data loads it with its first call. The object is the Api at
 * once, so the app chooses its source synchronously as before: every method but `source` returns a
 * promise, and each waits for the module and then calls the same method on it.
 */
import type { Api } from './types'
import type { TenantId } from '../theme/tenants'

export function lazyDemoApi(tenantId: TenantId): Api {
  let loaded: Promise<Api> | null = null
  const api = () => (loaded ??= import('./demo').then((m) => m.demoApi(tenantId)))
  return new Proxy({ source: 'demo' } as Api, {
    get(target, prop) {
      if (prop === 'source') return target.source
      return (...args: unknown[]) => api().then((a) => (a[prop as keyof Api] as (...x: unknown[]) => unknown)(...args))
    },
  })
}
