/** @jsxRuntime automatic */
/** @jsxImportSource preact */
/**
 * The frame every page sits in: the skip link, the header, the main area and the footer. It holds no
 * state, so the build can render it around the home hero for the page's first paint (vite.config.ts)
 * with exactly the wrappers the app then draws.
 */
import type { ComponentChildren as ReactNode } from 'preact'

export function PageFrame({ header, footer, children }: { header: ReactNode; footer: ReactNode; children: ReactNode }) {
  return (
    <div className="grain relative min-h-screen">
      <a href="#main" className="sr-only focus:not-sr-only focus:absolute focus:z-50 focus:m-2 focus:rounded-base focus:bg-surface focus:p-3">Skip to content</a>
      {header}
      <main id="main" className="relative z-10">
        {children}
      </main>
      {footer}
    </div>
  )
}
