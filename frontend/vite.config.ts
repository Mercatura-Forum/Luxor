import { defineConfig, loadEnv, searchForWorkspaceRoot, type Plugin } from 'vite'
import * as esbuild from 'esbuild'
import { readFileSync, realpathSync } from 'node:fs'
import path from 'node:path'
import preact from '@preact/preset-vite'
import tailwindcss from '@tailwindcss/vite'
import { TENANTS } from './src/theme/tenants'
import credits from './public/media/credits.json'
import { createElement } from 'preact'
import { renderToString as renderToStaticMarkup } from 'preact-render-to-string'
import { HomeHero } from './src/pages/HomeHero'
import { PageFrame } from './src/components/PageFrame'
import { avifSrcSet } from './src/lib/photoSrc'
import { photoFor } from './src/api/photos'

// The page shell learns each property's hero photograph and description from the tenant data, so the
// pre-paint script can ask for the hero before the app's script arrives (it is the page's largest paint).
function tenantShell(): Plugin {
  const fallback = (process.env.VITE_LUXOR_TENANT as keyof typeof TENANTS) || 'almar'
  // each property's hero as the srcset the page's image offers first, so the preload asks for that very file
  const heroes = Object.fromEntries(Object.entries(TENANTS).map(([id, t]) => [id, (() => { const p = photoFor(t.hero.slot); return p ? avifSrcSet(p.src) : '' })()]))
  const escape = (x: string) => x.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;')
  // the home page's first paint: the frame and hero the app draws, rendered here for each property and
  // language, so the photograph and headline show before the app's script has arrived
  const shells: Record<string, string> = {}
  for (const [id, t] of Object.entries(TENANTS)) {
    for (const lang of ['en', 'ar'] as const) {
      shells[`${id}|${lang}`] = renderToStaticMarkup(createElement(PageFrame, { header: null, footer: null, children: createElement(HomeHero, { tenant: t, lang, drift: 0 }) }))
    }
  }
  // inside a script, '<' is written as its escape so no markup can close the script early
  const shellJson = JSON.stringify(shells).replace(/</g, '\\u003c')
  return {
    name: 'luxor-tenant-shell',
    transformIndexHtml: (html) => html
      .replace('/*SHELLS*/{}', shellJson)
      .replace('/*HEROES*/{}', JSON.stringify(heroes))
      .replace('%DESCRIPTION%', escape((TENANTS[fallback] ?? TENANTS.almar).hero.body.en)),
  }
}

// The early-data script and the SDK's boundary script are written into the page's head, ahead of the
// stylesheet, so they run while the page is still being read. The results page's queries then leave at
// once instead of after the app's script (or the stylesheet) has arrived. The early script is bundled
// here from src/early.ts into one self-contained script, with the same env values Vite gives the app.
// The boundary tag in index.html is the anchor they replace.
const BOUNDARY_TAG = '<script defer src="./boundary.js"></script>'
const BOUNDARY_SRC = 'node_modules/@thebes/sdk/runtime/boundary.js'
function earlyData(env: Record<string, string>, slots: string[]): Plugin {
  const meta = { BASE_URL: './', ...env }
  let inputs = new Set<string>()
  let script = ''
  const build = () => {
    const out = esbuild.buildSync({
      entryPoints: ['src/early.ts'], bundle: true, format: 'iife', minify: true, write: false, metafile: true, target: 'es2020',
      define: { 'import.meta.env': JSON.stringify(meta), PHOTO_SLOTS: JSON.stringify(slots) },
    })
    inputs = new Set(Object.keys(out.metafile!.inputs).map((f) => path.resolve(f)))
    script = out.outputFiles[0].text.replace(/<\/script/gi, '<\\/script')
  }
  build()
  // inline scripts: '</script' inside them is escaped so the page's markup cannot be closed early
  const boundary = () => readFileSync(BOUNDARY_SRC, 'utf8').replace(/<\/script/gi, '<\\/script')
  return {
    name: 'luxor-early-data',
    transformIndexHtml(html) {
      if (!html.includes(BOUNDARY_TAG)) throw new Error('luxor-early-data: index.html has no boundary script tag to replace')
      return html.replace(BOUNDARY_TAG, `<script>${boundary()}</script>\n    <script>${script}</script>`)
    },
    // in dev, an edit to anything the early script is built from rebuilds it and reloads the page
    handleHotUpdate({ file, server }) {
      if (!inputs.has(path.resolve(file))) return
      build()
      server.ws.send({ type: 'full-reload' })
      return []
    },
  }
}

// Served by the Thebes asset contract under /_/raw/{cid}/, so every URL is relative (base './').
// The dev server also answers through a Cloudflare quick tunnel, so any host is accepted.
// On a page whose hero the HTML already painted (the home shell), the app's script is fetched and run once
// that photograph has painted. Fetched beside it, the script (about the photograph's size) shares the
// connection so both arrive late, and compiling it then holds the main thread at the moment the
// photograph would paint. Measured on the mobile profile: the photograph alone arrives in about two
// thirds of the time, and the app, fetched next, is still ready before the React build's was. A
// photograph that does not arrive within three seconds does not hold the app back. Every other page
// starts fetching the app while the page is still being read, as the script tag did. The build only: the
// dev server loads its modules as it always has.
function appAfterHero(): Plugin {
  return {
    name: 'luxor-app-after-hero',
    transformIndexHtml: {
      order: 'post',
      handler(html, ctx) {
        if (!ctx.bundle) return html
        const m = html.match(/<script type="module" crossorigin src="(\.\/assets\/app-[^"]+\.js)"><\/script>/)
        if (!m) throw new Error('luxor-app-after-hero: the app script tag is not in the built page')
        // fetched after the photograph, not beside it: the two are nearly the same size, and fetched side by
        // side they share the connection, finish together, and the script's compiling delays the paint
        // every other page fetches the app at once, as a script tag would: the route is known before the
        // page is parsed (the same test index.html uses for the home shell), and a preload starts the fetch
        const loader = `<script>
      if (location.hash && location.hash !== '#' && location.hash !== '#/') {
        var pre = document.createElement('link'); pre.rel = 'modulepreload'; pre.crossOrigin = ''; pre.href = '${m[1]}'; document.head.appendChild(pre);
      }
    </script>
    <script type="module">
      const img = document.querySelector('#root img[fetchpriority="high"]')
      const start = () => import('${m[1]}')
      if (!img || img.complete) start()
      else {
        let done = false
        const go = () => { if (!done) { done = true; requestAnimationFrame(() => requestAnimationFrame(start)) } }
        img.addEventListener('load', go, { once: true }); img.addEventListener('error', go, { once: true }); setTimeout(go, 3000)
      }
    </script>`
        return html.replace(m[0], loader)
      },
    },
  }
}

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), 'VITE_')
  const slots = [...new Set((credits as { slot: string }[]).map((c) => c.slot))]
  return {
    // Preact 10 with preact/compat in place of React DOM: the same components, a first script a third the size
    plugins: [preact(), tailwindcss(), tenantShell(), earlyData(env, slots), appAfterHero()],
    define: { PHOTO_SLOTS: JSON.stringify(slots) },
    base: './',
    // /api goes to the chain named by LUXOR_CHAIN (a Thebes subnet's gateway), never to a public boundary
    // files are served from this tree and from where its installed modules really are: a copy of the tree
    // whose node_modules is a link to another checkout's (the gate's clone) loads its fonts from there
    server: { allowedHosts: true, fs: { allow: [searchForWorkspaceRoot(process.cwd()), realpathSync('node_modules')] }, proxy: process.env.LUXOR_CHAIN ? { '/api': { target: process.env.LUXOR_CHAIN, changeOrigin: true } } : undefined },
    build: {
      target: 'es2022',
      assetsInlineLimit: 4096,
      // terser, two passes: a few per cent smaller than the default minifier, and the first script is what a phone waits for
      minify: 'terser',
      terserOptions: { compress: { passes: 2 }, format: { comments: false } },
      rollupOptions: {
        output: {
          entryFileNames: 'assets/app-[hash].js',
          chunkFileNames: 'assets/chunk-[hash].js',
          assetFileNames: 'assets/[name]-[hash][extname]',
        },
      },
    },
  }
})
