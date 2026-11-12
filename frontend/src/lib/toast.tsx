/**
 * Notices, with the notice library (sonner) loaded after the first paint rather than in the first script.
 * `toast` has the two calls the app makes. The Toaster mounts lazily, and a notice waits until it has
 * mounted, so one raised in the first instant (a page's first load failing, say) is shown, not lost.
 */
import { lazy, Suspense, useEffect } from 'react'

let loaded: Promise<typeof import('sonner')> | null = null
const sonner = () => (loaded ??= import('sonner'))
let markMounted: () => void = () => {}
const mounted = new Promise<void>((resolve) => { markMounted = resolve })

export const toast = {
  success(message: string) { void Promise.all([sonner(), mounted]).then(([s]) => s.toast.success(message)) },
  error(message: string) { void Promise.all([sonner(), mounted]).then(([s]) => s.toast.error(message)) },
}

const SonnerToaster = lazy(() => sonner().then((m) => ({ default: m.Toaster })))

function Mounted() {
  useEffect(() => markMounted(), [])
  return null
}

/** The notices' place on the page. It resolves with the library; `Mounted` inside the same boundary
 *  says so only once the Toaster itself is on the page. */
export function Toaster() {
  return (
    <Suspense fallback={null}>
      <SonnerToaster position="bottom-center" />
      <Mounted />
    </Suspense>
  )
}
