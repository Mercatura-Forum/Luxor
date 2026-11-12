/**
 * Where a photograph's files are and how the page offers them: WebP at three widths, AVIF first for the
 * home hero (see Img's avif), with a JPEG fallback. Shared by the image component and the early-data script's preload, so the preload asks for
 * the very file the page then shows.
 */

// the build's own config renders the home hero with this too, where Vite's env is not defined; the base is './' there
export function photoBase(src: string): string {
  return (import.meta.env?.BASE_URL ?? './').replace(/\/*$/, '/') + src
}

function srcSet(src: string, ext: 'avif' | 'webp'): string {
  const b = photoBase(src)
  return `${b}-480.${ext} 480w, ${b}-960.${ext} 960w, ${b}-1600.${ext} 1600w`
}

export const avifSrcSet = (src: string) => srcSet(src, 'avif')
export const webpSrcSet = (src: string) => srcSet(src, 'webp')

/** The first photograph of a slot; the credits number each slot's photographs from 1. */
export function firstPhotoSrc(slot: string): string {
  return `media/${slot}-1`
}

/** How wide a room's photograph is drawn on the results page. */
export const RESULT_PHOTO_SIZES = '(min-width: 768px) 40vw, 100vw'
