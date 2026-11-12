/**
 * Early data for the results page. The build writes this into the page's head, bundled and inline, right
 * after the SDK's boundary script (vite.config.ts, luxor-early-data), so it runs while the page is still
 * being read, long before the app's own script has arrived, and asks the chain for the room types, plans and search the results page is about
 * to ask for, with the same bytes (see api/views.ts). The replies wait in the early store for the app.
 * When the search and room types are back, the first room photograph the page will show is preloaded.
 * On any other page, for a property on demo data, or when anything here fails, the app asks as usual.
 */
import { earlyKey, earlyOpen, earlyStore, putEarly } from './api/early'
import { ROOM_TYPE_FIELDS, SEARCH_FIELDS, searchArgs } from './api/views'
import { boundary, chainConfig, postQuery, queryBody, type Arg, type QueryReply } from './api/wire'
import { firstPhotoSrc, RESULT_PHOTO_SIZES, webpSrcSet } from './lib/photoSrc'
import { chainActive, INJECTED, read } from './lib/prefs'
import { stayFromQuery } from './lib/stay'

/** The boundary script is written just before this one; should a page ever order them the other way, this waits for it. */
function whenBoundary(): Promise<void> {
  if ((window as unknown as { EgyptBoundary?: unknown }).EgyptBoundary) return Promise.resolve()
  const tag = document.querySelector<HTMLScriptElement>('script[src$="boundary.js"]')
  if (!tag) return Promise.reject(new Error('no boundary script'))
  // no event can fire between the check above and these listeners: they are added in the same task
  return new Promise((resolve, reject) => {
    tag.addEventListener('load', () => resolve(), { once: true })
    tag.addEventListener('error', () => reject(new Error('boundary script failed')), { once: true })
  })
}

function start() {
  const [path, qs] = location.hash.replace(/^#/, '').split('?')
  if (path !== '/rooms') return
  const cfg = chainConfig()
  const tenant = read('luxor:tenant', ['almar', 'karnak'] as const, INJECTED, 'visit')
  const source = read('luxor:source', ['chain', 'demo'] as const, 'chain', 'visit')
  if (!cfg || !chainActive(cfg, tenant, source)) return
  if (!earlyOpen()) return   // the app is already asking for itself

  const ask = (method: string, args: Arg[]): Promise<QueryReply> => {
    const body = queryBody(cfg.luxorCid, method, args)
    const reply = postQuery(cfg.base, body)
    putEarly(earlyStore(), earlyKey(cfg.luxorCid, method, body.arg), reply, Date.now())
    return reply
  }
  const types = ask('roomTypesView', [])
  ask('plansView', [])
  const search = ask('searchView', searchArgs(stayFromQuery(new URLSearchParams(qs ?? ''))))

  // the page shows the room types in the contract's order, those with an offer first; its first photograph is the largest paint
  Promise.all([types, search]).then(([t, s]) => {
    if (t.status !== 'success' || !t.reply || s.status !== 'success' || !s.reply) return
    const b = boundary()
    const offered = new Set(b.decodeVecRecord(s.reply, SEARCH_FIELDS).filter((r) => r.ok).map((r) => Number(r.roomTypeId)))
    const first = b.decodeVecRecord(t.reply, ROOM_TYPE_FIELDS).find((r) => r.active && offered.has(Number(r.id)))
    const slot = first ? String(first.photos) : ''
    if (!PHOTO_SLOTS.includes(slot)) return
    const link = document.createElement('link')
    link.rel = 'preload'; link.as = 'image'; link.type = 'image/webp'   // the format the results card offers (see Img's avif)
    link.setAttribute('fetchpriority', 'high')
    link.setAttribute('imagesrcset', webpSrcSet(firstPhotoSrc(slot)))
    link.setAttribute('imagesizes', RESULT_PHOTO_SIZES)
    document.head.appendChild(link)
  }).catch(() => { /* the app asks again */ })
}

whenBoundary().then(start).catch(() => { /* the app asks as usual */ })
