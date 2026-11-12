/** @jsxRuntime automatic */
/** @jsxImportSource preact */
import { useState } from 'preact/hooks'
import type { JSX } from 'preact'
type CSSProperties = JSX.CSSProperties
import type { Photo } from '../api/types'
import { avifSrcSet, photoBase, webpSrcSet } from '../lib/photoSrc'

/**
 * One photograph at the size the layout needs: WebP at three widths (AVIF first where asked) with a JPEG fallback, the box
 * reserved from the real aspect ratio (no layout shift), and a blurred preview painted until the
 * bytes arrive. Below the fold it loads lazily; the hero asks for priority.
 */
export function Img({ photo, sizes, priority = false, avif = false, className = '', style, alt }: {
  photo: Photo
  sizes: string
  priority?: boolean
  /** Offer AVIF first. Measured on the mobile profile: it wins where bytes dominate (the full-bleed hero,
   *  2.44 s against 3.3 s) and loses where decoding does (a results card, 3.54 s against 2.90 s). */
  avif?: boolean
  className?: string
  style?: CSSProperties
  alt?: string
}) {
  const [loaded, setLoaded] = useState(false)
  const base = photoBase(photo.src)
  return (
    <picture>
      {avif && <source type="image/avif" srcSet={avifSrcSet(photo.src)} sizes={sizes} />}
      <source type="image/webp" srcSet={webpSrcSet(photo.src)} sizes={sizes} />
      <img
        src={`${base}-1600.jpg`}
        alt={alt ?? photo.alt}
        width={photo.width}
        height={photo.height}
        loading={priority ? 'eager' : 'lazy'}
        decoding={priority ? 'sync' : 'async'}
        {...(priority ? { fetchPriority: 'high' as const } : {})}
        onLoad={() => setLoaded(true)}
        className={`${className} transition-opacity duration-300 ${loaded ? 'opacity-100' : 'opacity-95'}`}
        style={{ ...style, backgroundImage: loaded || !photo.lqip ? undefined : `url(${photo.lqip})`, backgroundSize: 'cover' }}
      />
    </picture>
  )
}
