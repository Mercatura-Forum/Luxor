import { Link } from 'react-router-dom'
import { useApp } from '../app'

export default function NotFound() {
  const { t } = useApp()
  return (
    <section className="mx-auto max-w-[1240px] px-5 pt-28 sm:px-8">
      <p className="font-display text-[7rem] leading-none text-accent nums" aria-hidden>404</p>
      <h1 className="t-h1 mt-4 text-ink">{t('nf.title')}</h1>
      <Link to="/" className="mt-6 inline-block font-semibold text-ink underline underline-offset-4">{t('err.back')}</Link>
    </section>
  )
}
