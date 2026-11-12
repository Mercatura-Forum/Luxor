/** @jsxRuntime automatic */
/** @jsxImportSource preact */
/**
 * The home page's hero: the photograph, its shade and the headline. It reads no context and fetches
 * nothing, so the build can render it to HTML for each property and language (vite.config.ts,
 * luxor-tenant-shell) and the page shows it before the app's script has arrived. React then draws the
 * same markup in its place. The pragmas above let the build's config bundler compile it too.
 */
import { photoFor } from '../api/photos'
import type { Bi } from '../api/types'
import type { Tenant } from '../theme/tenants'
import { Img } from '../components/Img'

export function HomeHero({ tenant, lang, drift }: { tenant: Tenant; lang: 'en' | 'ar'; drift: number }) {
  const pick = (b: Bi) => b[lang] || b[lang === 'en' ? 'ar' : 'en']   // as the app's tr: the other language rather than nothing
  const hero = photoFor(tenant.hero.slot)
  // the photograph carries it, the headline sits on its quiet side
  return (
    <section className="relative isolate min-h-[88svh] overflow-hidden bg-primary">
      {hero && (
        <div className="absolute inset-0 -z-10" style={{ transform: `translate3d(0, ${drift}px, 0) scale(1.06)` }}>
          <Img photo={hero} sizes="100vw" priority avif className="h-full w-full object-cover" alt="" />
        </div>
      )}
      <div className="absolute inset-0 -z-10" style={{ background: 'linear-gradient(180deg, rgb(var(--lx-scrim) / 0.55) 0%, rgb(var(--lx-scrim) / 0.1) 32%, rgb(var(--lx-scrim) / 0.2) 52%, rgb(var(--lx-scrim) / 0.62) 100%)' }} aria-hidden />
      {/* the copy's side is shaded too, so the words read over rocks or surf; mirrored for Arabic */}
      <div className="absolute inset-0 -z-10 [--lx-side:90deg] rtl:[--lx-side:270deg]" style={{ background: 'linear-gradient(var(--lx-side), rgb(var(--lx-scrim) / 0.5) 0%, rgb(var(--lx-scrim) / 0.28) 38%, rgb(var(--lx-scrim) / 0) 62%)' }} aria-hidden />
      <div className="mx-auto flex min-h-[88svh] max-w-[1240px] flex-col justify-end px-5 pb-40 pt-28 sm:px-8 sm:pb-44">
        <div className="max-w-[40rem] text-white">
          <p className="t-eyebrow text-white/85">{pick(tenant.hero.kicker)}</p>
          <h1 className="t-hero mt-4 text-balance">{pick(tenant.hero.title)}</h1>
          <p className="t-body mt-5 max-w-[34rem] text-white/90">{pick(tenant.hero.body)}</p>
        </div>
      </div>
    </section>
  )
}
