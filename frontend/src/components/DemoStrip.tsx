import { useApp } from '../app'

/**
 * THE DEMO STRIP: at the top of every page, guest or console, whenever what the page shows is sample
 * data and not the hotel's. It names which kind of sample it is (the live hotel's own pages on sample
 * data, or a property that only exists as a sample) and, when this page runs a hotel on the chain,
 * takes the visitor back to it in one click. The choice of sample data lasts for the visit only, so a
 * guest who comes back is on the live hotel again.
 */
export function DemoStrip({ note = 'demo.consoleNote' }: { note?: 'demo.consoleNote' | 'demo.note' }) {
  const { api, t, tr, tenant, live, goLive } = useApp()
  if (api.source !== 'demo') return null
  // a property the chain does not run is a sample whatever the source says
  const sampleProperty = live !== undefined && tenant.id !== live
  return (
    <div className="relative z-40 flex flex-wrap items-center justify-between gap-3 border-b border-accent/40 bg-accent/10 px-4 py-2.5 sm:px-6" role="status" data-demo-strip>
      <p className="t-small text-ink">
        <span className="me-2 rounded-base border border-accent px-2 py-0.5 font-bold text-accent">{t('demo.label')}</span>
        {sampleProperty ? t('demo.sampleProperty', { name: tr(tenant.name) }) : t(note)}
      </p>
      {live !== undefined && (
        <button type="button" onClick={goLive} className="rounded-base border border-ink px-3 py-1.5 t-small font-semibold text-ink" data-go-live>{t('demo.leave')}</button>
      )}
    </div>
  )
}
