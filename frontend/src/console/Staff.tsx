import { useCallback, useEffect, useMemo, useState, type FormEvent } from 'react'
import { Check, Copy, UserRound } from 'lucide-react'
import { toast } from '../lib/toast'
import { useApp } from '../app'
import { ROLES, Refused, type Role, type StaffRow } from '../api/types'
import { ScreenHead } from './Shell'
import { StaffOnly } from './StaffOnly'

/** A staff id is the hex of a principal's bytes: long, so it is shown as its two ends. */
export function shortId(hex: string): string { return hex.length > 16 ? `${hex.slice(0, 8)}…${hex.slice(-6)}` : hex }

/** One person and the roles they hold, in the order the owner gave them. */
type Person = { subject: string; mine: boolean; roles: StaffRow[] }

/**
 * THE STAFF: who works at the hotel and what each may do. The owner gives a role to a person by the id
 * they read on their own screen, and ends it; every other member of staff reads the list. A role takes
 * effect at the next act. The automatic night audit holds the auditor role while it runs, and only
 * turning that audit off ends it.
 */
export default function Staff() {
  const { api, t, tr } = useApp()
  const [rows, setRows] = useState<StaffRow[] | null>(null)
  const [mine, setMine] = useState<Role[]>([])
  const [me, setMe] = useState('')
  const [denied, setDenied] = useState(false)
  const [subject, setSubject] = useState('')
  const [role, setRole] = useState<Role>('frontDesk')
  const [ending, setEnding] = useState<StaffRow | null>(null)
  const [busy, setBusy] = useState(false)
  const [copied, setCopied] = useState(false)

  const load = useCallback(async () => {
    try {
      const [r, m, id] = await Promise.all([api.staff(), api.myRoles(), api.myId()])
      setRows(r); setMine(m); setMe(id); setDenied(false)
    } catch (e) {
      if (e instanceof Refused && e.kind === 'notAuthorised') { setDenied(true); api.myId().then(setMe).catch(() => {}) } else toast.error(t('err.generic'))
    }
  }, [api, t])
  useEffect(() => { load() }, [load])

  const owner = mine.includes('owner')
  const people = useMemo(() => {
    const m = new Map<string, Person>()
    for (const r of rows ?? []) {
      const p = m.get(r.subject) ?? { subject: r.subject, mine: r.mine, roles: [] }
      p.roles.push(r); m.set(r.subject, p)
    }
    // the person reading first, then by the first role each was given
    return [...m.values()].sort((a, b) => Number(b.mine) - Number(a.mine) || a.roles[0].grantId - b.roles[0].grantId)
  }, [rows])
  const id = subject.trim().toLowerCase()
  const idOk = /^[0-9a-f]+$/.test(id) && id.length % 2 === 0 && id.length >= 2 && id.length <= 58
  const held = rows?.some((r) => r.subject === id && r.role === role) ?? false

  const run = async (f: () => Promise<void>, ok: string) => {
    setBusy(true)
    try { await f(); toast.success(ok); await load(); return true }
    catch (e) { toast.error(e instanceof Refused ? tr(e.reason) : t('err.generic')); return false }
    finally { setBusy(false) }
  }
  const give = async (e: FormEvent) => {
    e.preventDefault()
    if (!idOk || held) return
    if (await run(() => api.grantRole(id, role), t('staff.given', { role: t(`role.${role}`), who: shortId(id) }))) setSubject('')
  }
  const copy = async () => {
    try { await navigator.clipboard.writeText(me); setCopied(true); setTimeout(() => setCopied(false), 1800) } catch { toast.error(t('err.generic')) }
  }

  const myId = me && (
    <section className="rounded-lg border border-line bg-surface p-5" aria-labelledby="my-id">
      <h2 id="my-id" className="font-semibold text-ink">{t('staff.myId')}</h2>
      <p className="t-small mt-1 text-muted">{t('staff.myIdLead')}</p>
      <div className="mt-3 flex items-center gap-2">
        <code dir="ltr" className="min-w-0 flex-1 break-all rounded-base border border-line bg-bg px-3 py-2 text-xs text-ink" data-my-id>{me}</code>
        <button type="button" onClick={copy} aria-label={t('staff.copy')} className="grid h-10 w-10 shrink-0 place-items-center rounded-base border border-line text-ink">
          {copied ? <Check className="h-4 w-4 text-success" aria-hidden /> : <Copy className="h-4 w-4" aria-hidden />}
        </button>
      </div>
    </section>
  )

  if (denied) return (
    <div className="mx-auto max-w-[1240px]">
      <ScreenHead title={t('staff.title')} />
      <StaffOnly />
      {me && <div className="mt-6 max-w-xl">{myId}</div>}
    </div>
  )
  const field = 'mt-1 block w-full rounded-base border border-field bg-bg px-3 py-2.5 text-ink'
  return (
    <div className="mx-auto max-w-[1240px]">
      <ScreenHead title={t('staff.title')} sub={owner ? t('staff.lead') : t('staff.leadReader')} />
      <div className="mt-8 grid gap-8 lg:grid-cols-[minmax(0,1fr)_380px]">
        <ul className="space-y-3" aria-label={t('staff.title')}>
          {rows === null && [0, 1, 2].map((i) => <li key={i} className="skeleton h-24 rounded-lg" aria-hidden />)}
          {people.map((p) => (
            <li key={p.subject} className="rounded-lg border border-line bg-surface p-4" data-person={p.subject}>
              <div className="flex flex-wrap items-center gap-3">
                <span className="grid h-9 w-9 shrink-0 place-items-center rounded-full bg-surface-2 text-ink" aria-hidden><UserRound className="h-4 w-4" /></span>
                <div className="min-w-0 flex-1">
                  <p className="font-semibold text-ink">
                    {p.roles.some((r) => r.automatic) ? t('staff.automatic') : <code dir="ltr" title={p.subject} className="text-sm">{shortId(p.subject)}</code>}
                    {p.mine && <span className="ms-2 rounded-base border border-ink px-1.5 py-0.5 t-small font-semibold">{t('staff.you')}</span>}
                  </p>
                </div>
              </div>
              <ul className="mt-3 flex flex-wrap gap-2">
                {p.roles.map((r) => (
                  <li key={r.grantId} className="flex items-center gap-1 rounded-base border border-line bg-bg ps-3 pe-1 py-1">
                    <span className="t-small font-semibold text-ink">{t(`role.${r.role}`)}</span>
                    {owner && !r.automatic && (
                      <button type="button" onClick={() => setEnding(r)} className="rounded-base px-2 py-1 t-small text-muted underline underline-offset-4 hover:text-ink"
                        aria-label={t('staff.endFor', { role: t(`role.${r.role}`), who: shortId(r.subject) })}>{t('staff.end')}</button>
                    )}
                  </li>
                ))}
              </ul>
              {ending && p.roles.some((r) => r.grantId === ending.grantId) && (
                <div className="mt-3 flex flex-wrap items-center gap-2 rounded-base border border-danger/50 bg-danger/5 p-3" role="alertdialog" aria-label={t('staff.endConfirm', { role: t(`role.${ending.role}`) })}>
                  <p className="t-small min-w-0 flex-1 text-ink">{p.mine ? t('staff.endMine', { role: t(`role.${ending.role}`) }) : t('staff.endConfirm', { role: t(`role.${ending.role}`) })}</p>
                  <button type="button" disabled={busy} onClick={() => run(() => api.revokeRole(ending.subject, ending.role), t('staff.ended', { role: t(`role.${ending.role}`) })).then(() => setEnding(null))}
                    className="rounded-base bg-danger px-3 py-2 t-small font-semibold text-bg disabled:opacity-40">{t('staff.end')}</button>
                  <button type="button" onClick={() => setEnding(null)} className="rounded-base border border-line px-3 py-2 t-small font-semibold text-ink">{t('console.cancel')}</button>
                </div>
              )}
            </li>
          ))}
        </ul>
        <div className="space-y-6">
          {owner && (
            <form onSubmit={give} className="space-y-4 rounded-lg border border-line bg-surface p-5">
              <h2 className="t-h2 text-ink">{t('staff.give')}</h2>
              <label className="block"><span className="font-semibold text-ink">{t('staff.id')}</span>
                <input dir="ltr" value={subject} onChange={(e) => setSubject(e.currentTarget.value)} spellcheck={false} autoComplete="off" className={`${field} font-mono text-sm`} />
                <span className={`t-small mt-1 block ${subject && !idOk ? 'text-danger' : 'text-muted'}`}>{subject && !idOk ? t('staff.idBad') : t('staff.idHint')}</span></label>
              <fieldset>
                <legend className="font-semibold text-ink">{t('staff.role')}</legend>
                <div className="mt-2 space-y-2">
                  {ROLES.map((r) => (
                    <label key={r} className={`flex cursor-pointer gap-3 rounded-base border p-3 ${role === r ? 'border-primary bg-primary/5' : 'border-line'}`}>
                      <input type="radio" name="role" value={r} checked={role === r} onChange={() => setRole(r)} className="mt-1" />
                      <span><span className="block font-semibold text-ink">{t(`role.${r}`)}</span><span className="t-small block text-muted">{t(`role.${r}.does`)}</span></span>
                    </label>
                  ))}
                </div>
              </fieldset>
              {held && <p className="t-small text-muted">{t('staff.alreadyHeld')}</p>}
              <button type="submit" disabled={busy || !idOk || held} className="w-full rounded-base bg-primary px-5 py-3 font-semibold text-primary-ink disabled:opacity-40">
                {t('staff.giveRole', { role: t(`role.${role}`) })}</button>
            </form>
          )}
          {myId}
          <p className="t-small text-muted">{t('staff.fourEyes')}</p>
        </div>
      </div>
    </div>
  )
}
