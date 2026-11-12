import { useCallback, useEffect, useState, type FormEvent, type ReactNode } from 'react'
import { CheckCircle2, CircleDashed, Mail, TriangleAlert } from 'lucide-react'
import { toast } from '../lib/toast'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import { Refused, type DnsCheckView, type DnsLine, type MailAccountInUse, type MailAccountSaved, type MailProvider, type MailProviderView, type MailSetupView } from '../api/types'
import { StaffOnly } from './StaffOnly'

/** Where a sign-in with Google or Microsoft left its answer (main.tsx moves it here from the address bar). */
export const SIGN_IN_KEY = 'luxor:mailSignIn'
/** The account given but not yet approved, kept while the owner moves through the steps. */
const PENDING_KEY = 'luxor:mailPending'

type Pending = MailAccountSaved & { account?: string }

function readPending(): Pending | null {
  try { const v = sessionStorage.getItem(PENDING_KEY); return v ? JSON.parse(v) as Pending : null } catch { return null }
}
function writePending(p: Pending | null) {
  try { if (p) sessionStorage.setItem(PENDING_KEY, JSON.stringify(p)); else sessionStorage.removeItem(PENDING_KEY) } catch { /* a private window: the step is shown until reload */ }
}

const SECRET_FIELDS = new Set(['password', 'apiKey', 'secretAccessKey'])

/**
 * Guest email: the hotel's own email account, connected in six steps. The contract keeps an outbox and
 * makes no outbound request; the shared mail relay sends through this account. The account's password
 * or key is sealed in this browser to the relay and never reaches the chain; the chain keeps only its
 * digest, which the owner approves here.
 */
export default function GuestEmail() {
  const { api, t, tr, lang } = useApp()
  const { num } = useFormat()
  const [setup, setSetup] = useState<MailSetupView | null>(null)
  const [denied, setDenied] = useState(false)
  const [providers, setProviders] = useState<MailProviderView[]>([])
  const [provider, setProvider] = useState<MailProvider>('google')
  const [from, setFrom] = useState('')
  const [fromName, setFromName] = useState('')
  const [testTo, setTestTo] = useState('')
  const [fields, setFields] = useState<Record<string, string>>({})
  const [pending, setPending] = useState<Pending | null>(readPending)
  const [inUse, setInUse] = useState<MailAccountInUse | null>(null)
  const [changing, setChanging] = useState(false)
  const [domain, setDomain] = useState('')
  const [selector, setSelector] = useState('')
  const [dns, setDns] = useState<DnsCheckView | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [testFailure, setTestFailure] = useState<string | null>(null)

  const fail = useCallback((e: unknown) => toast.error(e instanceof Refused ? tr(e.reason) : t('err.generic')), [t, tr])

  const load = useCallback(async () => {
    try {
      const s = await api.mailSetup()
      setSetup(s); setDenied(false)
      // the approved account as the mail service holds it; a service that does not answer leaves the line out, not the screen
      if (s.authorised && s.relay) api.mailAccountInUse().then(setInUse).catch(() => setInUse(null))
      else setInUse(null)
    }
    catch (e) { if (e instanceof Refused && e.kind === 'notAuthorised') setDenied(true); else fail(e) }
  }, [api, fail])

  useEffect(() => { load() }, [load])
  useEffect(() => { api.mailProviders().then(setProviders).catch(() => setProviders([])) }, [api])

  // a sign-in with Google or Microsoft comes back with the account's digest
  useEffect(() => {
    let back: string | null = null
    try { back = sessionStorage.getItem(SIGN_IN_KEY); sessionStorage.removeItem(SIGN_IN_KEY) } catch { /* nothing to read */ }
    if (!back) return
    const q = new URLSearchParams(back)
    const digest = q.get('mailCredential') ?? ''
    if (/^[0-9a-f]{64}$/.test(digest)) {
      const p: Pending = { digest, provider: (q.get('provider') ?? 'google') as MailProvider, from: q.get('account') ?? '', account: q.get('account') ?? '' }
      setPending(p); writePending(p)
      toast.success(t('gm.signInBack', { account: p.account || p.from }))
    } else toast.error(t('gm.signInFailed'))
  }, [t])

  useEffect(() => { if (!domain && from.includes('@')) setDomain(from.split('@')[1]) }, [from, domain])
  useEffect(() => { if (!domain && inUse?.from?.includes('@')) setDomain(inUse.from.split('@')[1]) }, [inUse, domain])

  const step = async (name: string, f: () => Promise<void>) => {
    setBusy(name)
    try { await f(); await load() } catch (e) { if (e instanceof Refused && e.kind === 'notAuthorised') setDenied(true); else fail(e) } finally { setBusy(null) }
  }

  const chosen = providers.find((p) => p.name === provider)
  const own = chosen?.fields.filter((f) => f !== 'from' && f !== 'fromName') ?? []

  const giveAccount = (e: FormEvent) => {
    e.preventDefault()
    if (!chosen) return
    const account = { provider, from, fromName, testTo: testTo || from, lang }
    step('account', async () => {
      if (chosen.oauth) { location.assign(await api.startMailSignIn(account)); return }
      const saved = await api.saveMailAccount({ ...account, fields })
      setPending(saved); writePending(saved); setFields({}); setChanging(false)
      toast.success(t('gm.saved', { from: saved.from, provider: chosen.label }))
    })
  }

  if (denied) return <div className="mx-auto max-w-3xl"><h1 className="t-h1 text-ink">{t('gm.title')}</h1><StaffOnly /></div>
  if (!setup) return <div className="mx-auto max-w-3xl" aria-hidden><div className="skeleton h-10 w-60 rounded-base" /><div className="skeleton mt-8 h-72 rounded-lg" /></div>

  const authorised = setup.authorised !== ''
  const approvedNow = !!pending && pending.digest === setup.authorised
  const needsApproval = !!pending && !approvedNow
  const tested = authorised && setup.tested === setup.authorised
  // the account the books name, held by the service: shown as in use, with the form behind "use another account"
  const held = authorised && !needsApproval && inUse?.digest === setup.authorised && inUse.onFile ? inUse : null
  const lost = authorised && !needsApproval && inUse?.digest === setup.authorised && !inUse.onFile
  const showForm = setup.connected && (changing || lost || (!pending && !authorised))
  const fieldCls = 'rounded-base border border-field bg-surface px-3 py-2.5 text-ink'
  const label = (f: string) => (f === 'from' ? t('gm.from') : t(`gm.field.${f}` as 'gm.field.host'))

  return (
    <div className="mx-auto max-w-3xl pb-16" data-guest-email={setup.on ? 'on' : 'off'}>
      <h1 className="t-h1 text-ink">{t('gm.title')}</h1>
      <p className="t-body mt-3 text-muted">{t('gm.lead')}</p>

      <p role="status" className={`mt-6 flex flex-wrap items-center gap-2 rounded-base border px-4 py-3 ${setup.on ? 'border-line text-ink' : 'border-accent text-ink'}`}>
        <Mail className="h-4 w-4 text-muted" aria-hidden />
        <span className="font-semibold">{setup.on ? t('gm.status.on') : t('gm.status.off')}</span>
        {setup.waiting > 0 && <span className="t-small text-muted nums">· {t('gm.waiting', { n: setup.more ? `${num(setup.waiting)}+` : num(setup.waiting) })}</span>}
      </p>
      {!setup.relay && <p role="alert" className="mt-4 flex gap-2 text-ink"><TriangleAlert className="mt-1 h-4 w-4 shrink-0 text-danger" aria-hidden />{t('gm.noRelay')}</p>}

      <ol className="mt-8 grid gap-4">
        <Step n={1} title={t('gm.s1')} lead={t('gm.s1Lead')} done={setup.connected}>
          {!setup.connected && (
            <button type="button" disabled={!setup.relay || busy !== null} onClick={() => step('connect', () => api.connectMailRelay())}
              className="rounded-base bg-primary px-4 py-2.5 font-semibold text-primary-ink disabled:opacity-40">{t('gm.connect')}</button>
          )}
        </Step>

        <Step n={2} title={t('gm.s2')} lead={t('gm.s2Lead')} done={!!pending || authorised} disabled={!setup.connected}>
          {held ? (
            <p className="mb-3 text-ink" data-mail-in-use={held.provider}>{t('gm.inUse', { from: held.from ?? '', provider: providers.find((p) => p.name === held.provider)?.label ?? held.provider ?? '' })}</p>
          ) : pending && <p className="mb-3 text-ink" data-mail-pending>{t('gm.saved', { from: pending.account || pending.from, provider: providers.find((p) => p.name === pending.provider)?.label ?? pending.provider })}</p>}
          {lost && <p role="alert" className="mb-3 flex gap-2 text-ink" data-mail-lost><TriangleAlert className="mt-1 h-4 w-4 shrink-0 text-danger" aria-hidden />{t('gm.notOnFile')}</p>}
          {setup.connected && !showForm && (
            <button type="button" onClick={() => setChanging(true)} className="rounded-base border border-ink px-4 py-2.5 font-semibold text-ink">{t('gm.change')}</button>
          )}
          {showForm && (
            <form onSubmit={giveAccount} className="grid gap-3" autoComplete="off">
              <label className="flex flex-col gap-1.5"><span className="t-small font-semibold text-ink">{t('gm.provider')}</span>
                <select value={provider} onChange={(e) => { setProvider(e.currentTarget.value as MailProvider); setFields({}) }} className={fieldCls}>
                  {providers.filter((p) => p.available).map((p) => <option key={p.name} value={p.name}>{p.label}</option>)}
                </select></label>
              <label className="flex flex-col gap-1.5"><span className="t-small font-semibold text-ink">{t('gm.from')}</span>
                <input type="email" required value={from} onChange={(e) => setFrom(e.currentTarget.value)} dir="ltr" className={fieldCls} />
                <span className="t-small text-muted">{t('gm.fromHint')}</span></label>
              <label className="flex flex-col gap-1.5"><span className="t-small font-semibold text-ink">{t('gm.fromName')}</span>
                <input value={fromName} onChange={(e) => setFromName(e.currentTarget.value)} maxLength={120} className={fieldCls} /></label>
              <label className="flex flex-col gap-1.5"><span className="t-small font-semibold text-ink">{t('gm.testTo')}</span>
                <input type="email" value={testTo} placeholder={from} onChange={(e) => setTestTo(e.currentTarget.value)} dir="ltr" className={fieldCls} /></label>
              {!chosen?.oauth && own.map((f) => (
                <label key={f} className="flex flex-col gap-1.5"><span className="t-small font-semibold text-ink">{label(f)}</span>
                  {f === 'security' ? (
                    <select value={fields[f] ?? ''} onChange={(e) => setFields({ ...fields, [f]: e.currentTarget.value })} className={fieldCls}>
                      <option value="">STARTTLS (587) / TLS (465)</option><option value="starttls">STARTTLS</option><option value="tls">TLS</option>
                    </select>
                  ) : f === 'region' && provider === 'mailgun' ? (
                    <select value={fields[f] ?? 'us'} onChange={(e) => setFields({ ...fields, [f]: e.currentTarget.value })} className={fieldCls}>
                      <option value="us">US</option><option value="eu">EU</option>
                    </select>
                  ) : (
                    <input type={SECRET_FIELDS.has(f) ? 'password' : f === 'port' ? 'number' : 'text'} required={f !== 'domain'} dir="ltr" autoComplete="off"
                      value={fields[f] ?? ''} onChange={(e) => setFields({ ...fields, [f]: e.currentTarget.value })} className={fieldCls} />
                  )}
                </label>
              ))}
              <p className="t-small text-muted">{t(`gm.tip.${provider}` as 'gm.tip.google')}</p>
              <div><button type="submit" disabled={busy !== null || !chosen} className="rounded-base bg-primary px-4 py-2.5 font-semibold text-primary-ink disabled:opacity-40">
                {chosen?.oauth ? t('gm.signIn', { provider: chosen.label.split(' ')[0] }) : t('gm.save')}</button>
                {changing && <button type="button" onClick={() => setChanging(false)} className="ms-3 px-2 py-2.5 font-semibold text-ink underline underline-offset-4">{t('gm.keep')}</button>}</div>
            </form>
          )}
        </Step>

        <Step n={3} title={t('gm.s3')} lead={t('gm.s3Lead')} done={authorised && !needsApproval} disabled={!pending && !authorised}>
          {needsApproval && (
            <button type="button" disabled={busy !== null} onClick={() => step('approve', () => api.approveMailAccount(pending!.digest))}
              className="rounded-base bg-primary px-4 py-2.5 font-semibold text-primary-ink disabled:opacity-40">{t('gm.approve')}</button>
          )}
        </Step>

        <Step n={4} title={t('gm.s4')} lead={t('gm.s4Lead')} done={!!dns?.ok} disabled={!authorised}>
          <form className="grid gap-3 sm:grid-cols-[1fr_1fr_auto] sm:items-end" onSubmit={(e) => { e.preventDefault(); step('dns', async () => setDns(await api.checkMailDomain(domain.trim(), pending?.provider ?? held?.provider ?? provider, selector.trim()))) }}>
            <label className="flex flex-col gap-1.5"><span className="t-small font-semibold text-ink">{t('gm.domain')}</span>
              <input required value={domain} onChange={(e) => setDomain(e.currentTarget.value)} dir="ltr" className={fieldCls} /></label>
            <label className="flex flex-col gap-1.5"><span className="t-small font-semibold text-ink">{t('gm.selector')}</span>
              <input value={selector} onChange={(e) => setSelector(e.currentTarget.value)} dir="ltr" className={fieldCls} /></label>
            <button type="submit" disabled={busy !== null || !authorised} className="rounded-base border border-ink px-4 py-2.5 font-semibold text-ink disabled:opacity-40">{t('gm.check')}</button>
          </form>
          {dns?.error && <p role="alert" className="mt-3 text-danger">{dns.error}</p>}
          {dns && !dns.error && (
            <div className="mt-4 grid gap-3" data-dns={dns.ok ? 'ok' : 'records'}>
              {(['spf', 'dkim', 'dmarc'] as const).map((k) => dns[k] && <DnsRow key={k} name={k.toUpperCase()} line={dns[k]!} />)}
              {!dns.ok && <p className="t-small text-muted">{t('gm.dns.again')}</p>}
            </div>
          )}
        </Step>

        <Step n={5} title={t('gm.s5')} lead={t('gm.s5Lead')} done={tested} disabled={!authorised}>
          {authorised && !tested && (
            <button type="button" disabled={busy !== null} onClick={() => step('test', async () => {
              setTestFailure(null)
              const r = await api.sendMailTest(setup.authorised)
              if (r.ok) toast.success(t('gm.tested')); else setTestFailure(r.failure ?? 'unavailable')
            })} className="rounded-base bg-primary px-4 py-2.5 font-semibold text-primary-ink disabled:opacity-40">{t('gm.test')}</button>
          )}
          {testFailure && <p role="alert" className="mt-3 font-semibold text-danger">{t('gm.testFailed', { why: t(`mail.failure.${testFailure}` as 'mail.failure.signIn') })}</p>}
        </Step>

        <Step n={6} title={t('gm.s6')} lead={t('gm.s6Lead')} done={setup.on} disabled={!tested}>
          {tested && (
            <button type="button" disabled={busy !== null} onClick={() => step('on', async () => { await api.setGuestEmail(!setup.on); if (!setup.on) { writePending(null); setPending(null) } })}
              className={setup.on ? 'rounded-base border border-ink px-4 py-2.5 font-semibold text-ink' : 'rounded-base bg-primary px-4 py-2.5 font-semibold text-primary-ink disabled:opacity-40'}>
              {setup.on ? t('gm.turnOff') : t('gm.turnOn')}</button>
          )}
        </Step>
      </ol>

      <details className="mt-10 rounded-lg border border-line p-5">
        <summary className="cursor-pointer font-semibold text-ink">{t('gm.help')}</summary>
        <ul className="mt-3 grid gap-3">
          {providers.map((p) => <li key={p.name}><p className="font-semibold text-ink">{p.label}</p><p className="t-small text-muted">{t(`gm.tip.${p.name}` as 'gm.tip.google')}</p></li>)}
        </ul>
      </details>
    </div>
  )
}

function Step({ n, title, lead, done, disabled, children }: { n: number; title: string; lead: string; done: boolean; disabled?: boolean; children?: ReactNode }) {
  const { t } = useApp()
  const { num } = useFormat()
  return (
    <li className={`rounded-lg border p-5 ${done ? 'border-line' : 'border-line bg-surface shadow-1'} ${disabled ? 'opacity-60' : ''}`} data-mail-step={n} data-done={done ? 'yes' : 'no'}>
      <div className="flex items-start gap-3">
        {done ? <CheckCircle2 className="mt-0.5 h-5 w-5 shrink-0 text-ink" aria-hidden /> : <CircleDashed className="mt-0.5 h-5 w-5 shrink-0 text-muted" aria-hidden />}
        <div className="min-w-0 flex-1">
          <p className="t-eyebrow text-muted">{t('gm.step', { n: num(n) })}{done ? ` · ${t('gm.done')}` : ''}</p>
          <h2 className="mt-1 font-semibold text-ink">{title}</h2>
          <p className="t-small mt-1 text-muted">{lead}</p>
          {!disabled && children && <div className="mt-4">{children}</div>}
        </div>
      </div>
    </li>
  )
}

function DnsRow({ name, line }: { name: string; line: DnsLine }) {
  const { t } = useApp()
  return (
    <div className="rounded-base border border-line p-3" data-dns-line={name} data-state={line.state}>
      <p className="flex items-center gap-2">
        {line.state === 'pass' ? <CheckCircle2 className="h-4 w-4 text-ink" aria-hidden /> : <TriangleAlert className="h-4 w-4 text-danger" aria-hidden />}
        <span className="font-semibold text-ink">{name}</span>
        <span className={`t-small ${line.state === 'pass' ? 'text-muted' : 'font-semibold text-danger'}`}>{t(`gm.dns.${line.state}`)}</span>
      </p>
      {line.note && <p className="t-small mt-1 text-muted">{t('gm.dns.notNeeded')}</p>}
      {line.state === 'wrong' && <p className="t-small mt-1 text-muted">{t('gm.dns.whyWrong')}</p>}
      {line.state === 'missing' && !line.add && <p className="t-small mt-1 text-muted">{t('gm.dns.whyNoKey')}</p>}
      {line.add && (
        <div className="mt-2">
          <p className="t-small text-ink">{t('gm.dns.add')}</p>
          <dl className="mt-1 grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 t-small">
            <dt className="text-muted">{t('gm.dns.type')}</dt><dd className="text-ink" dir="ltr">{line.add.type}</dd>
            <dt className="text-muted">{t('gm.dns.name')}</dt><dd className="break-all text-ink" dir="ltr"><code>{line.add.name}</code></dd>
            <dt className="text-muted">{t('gm.dns.value')}</dt><dd className="break-all text-ink" dir="ltr"><code>{line.add.value}</code></dd>
          </dl>
        </div>
      )}
    </div>
  )
}
