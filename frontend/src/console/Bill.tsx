import { useCallback, useEffect, useMemo, useState, type FormEvent } from 'react'
import * as Dialog from '@radix-ui/react-dialog'
import { Link } from 'react-router-dom'
import { FileMinus, FileText, Plus, X } from 'lucide-react'
import { toast } from '../lib/toast'
import { useApp } from '../app'
import { useFormat } from '../lib/useFormat'
import { parseMoney, toDecimalString as toDecimal } from '../lib/money'
import { Refused, creditable, isNoteLine, type BillLineView, type BillView, type BillWindowView, type BookingView, type CreditNoteRow, type DeskMethod,
  type DeskRefundView, type ExtraView, type PaymentView, type RefundView } from '../api/types'
import { Settle } from './Settle'
import { RefundList } from './RefundList'

/** A line's words: the extra and its quantity, the tax's name, or the kind of line. */
export function useLineTitle() {
  const { t, tr } = useApp()
  const { money } = useFormat()
  return (l: BillLineView) => {
    if (l.kind === 'extra') return `${tr(l.title)}${l.quantity > 1 ? ` × ${l.quantity} (${money(l.unitAmount)})` : ''}`
    if ((l.kind === 'tax' || l.kind === 'extraTax') && l.title.en) return tr(l.title)
    return t(`folio.${l.kind}` as 'folio.tax')
  }
}

/**
 * THE BILL: a booking's lines by who pays them. The guest's bill comes first; a payer added (a company,
 * a relative) has a bill of its own, and lines are moved to it. Each bill is paid at the desk and
 * invoiced under the next number, which closes it. A charge is never edited: it is voided by two people.
 * An invoiced bill is amended only by a credit note, also by two people; its refund goes back through
 * the card that paid the bill, and a refund the gateway refuses is paid at the desk, by two people.
 */
export function BillPanel({ booking: b, onChanged }: { booking: BookingView; onChanged?(): void }) {
  const { api, t, tr } = useApp()
  const { money, day } = useFormat()
  const title = useLineTitle()
  const [bill, setBill] = useState<BillView | null>(null)
  const [picked, setPicked] = useState<number[]>([])
  const [moveTo, setMoveTo] = useState(0)
  const [charging, setCharging] = useState(false)
  const [payerName, setPayerName] = useState('')
  const [paying, setPaying] = useState<BillWindowView | null>(null)
  const [voiding, setVoiding] = useState<BillLineView | null>(null)
  const [busy, setBusy] = useState(false)
  const [notes, setNotes] = useState<CreditNoteRow[]>([])
  const [credited, setCredited] = useState<Map<number, bigint>>(new Map())
  const [payments, setPayments] = useState<PaymentView[]>([])
  const [desks, setDesks] = useState<DeskRefundView[]>([])
  const [refunds, setRefunds] = useState<RefundView[]>([])
  const [noting, setNoting] = useState<{ window: BillWindowView; lineId: number } | null>(null)
  const [deskPaying, setDeskPaying] = useState<PaymentView | null>(null)

  const load = useCallback(async () => {
    try {
      const [bl, ns, cr, ps, ds, rs] = await Promise.all([api.bill(b.id), api.creditNotes(b.id), api.creditedLines(b.id), api.payments(b.id), api.deskRefunds(b.id),
        api.refunds(b.id)])
      setBill(bl); setNotes(ns); setCredited(cr); setPayments(ps); setDesks(ds); setRefunds(rs); setPicked([])
    } catch (e) { toast.error(e instanceof Refused ? tr(e.reason) : t('err.generic')) }
  }, [api, b.id, t, tr])
  useEffect(() => { load() }, [load])
  const changed = async () => { await load(); onChanged?.() }

  const run = async (f: () => Promise<unknown>, ok: string) => {
    setBusy(true)
    try { await f(); toast.success(ok); await changed() }
    catch (e) { toast.error(e instanceof Refused ? tr(e.reason) : t('err.generic')) }
    finally { setBusy(false) }
  }

  const inHouse = b.status === 'checkedIn'
  const open = b.status === 'confirmed' || b.status === 'checkedIn'
  const split = (bill?.windows.length ?? 0) > 1
  const movable = (l: BillLineView, w: BillWindowView) => split && open && !w.invoice && l.kind !== 'extraTax' && !l.voided
  const targets = useMemo(() => (bill?.windows ?? []).filter((w) => !w.invoice), [bill])
  /** What is left of a line for a credit note to take back. */
  const left = (l: BillLineView) => l.amount - (credited.get(l.id) ?? 0n)
  const notable = (l: BillLineView, w: BillWindowView) => !!w.invoice && creditable(l.kind) && !l.voided && left(l) > 0n
  const failed = payments.filter((p) => p.kind === 'refunded' && p.state === 'failed')

  if (!bill) return <div className="skeleton h-40 rounded-lg" aria-hidden />
  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-2">
        {inHouse && <button type="button" onClick={() => setCharging(true)} className="inline-flex items-center gap-1.5 rounded-base bg-primary px-3 py-2 t-small font-semibold text-primary-ink">
          <Plus className="h-4 w-4" aria-hidden />{t('bill.addCharge')}</button>}
        {open && (
          <form className="flex flex-wrap items-center gap-2" onSubmit={(e) => { e.preventDefault(); run(() => api.addPayer(b.id, payerName), t('bill.payerAdded', { name: payerName })).then(() => setPayerName('')) }}>
            <input value={payerName} onChange={(e) => setPayerName(e.currentTarget.value)} placeholder={t('bill.payerName')} aria-label={t('bill.payerName')}
              className="w-44 rounded-base border border-field bg-bg px-3 py-2 t-small text-ink" />
            <button type="submit" disabled={busy || !payerName.trim()} className="rounded-base border border-line px-3 py-2 t-small font-semibold text-ink disabled:opacity-40">{t('bill.addPayer')}</button>
          </form>
        )}
      </div>

      {bill.windows.map((w) => {
        const lines = bill.lines.filter((l) => l.payerId === w.payerId)
        const back = refunds.filter((r) => r.payerId === w.payerId)
        return (
          <section key={w.payerId} aria-labelledby={`win${w.payerId}`} className="rounded-lg border border-line bg-surface p-4">
            <div className="flex flex-wrap items-start justify-between gap-2">
              <div>
                <h4 id={`win${w.payerId}`} className="font-semibold text-ink">{w.payerId === 0 ? t('bill.guest', { name: w.name }) : w.name}</h4>
                <p className="t-small text-muted nums">{t('bill.figures', { charges: money(w.charges), taxes: money(w.taxes), credits: money(w.credits), paid: money(w.paid) })}</p>
              </div>
              <p className={`font-semibold nums ${w.open > 0n ? 'text-ink' : 'text-success'}`}>{w.open > 0n ? t('bill.toPay', { amount: money(w.open) }) : t('bill.paid')}</p>
            </div>
            {lines.length === 0 ? <p className="t-small mt-2 text-muted">{t('bill.empty')}</p> : (
              <ul className="mt-3 divide-y divide-line/70 text-sm">
                {lines.map((l) => (
                  <li key={l.id} className="flex items-center gap-3 py-1.5">
                    {movable(l, w) ? (
                      <input type="checkbox" aria-label={t('bill.pick', { line: title(l) })} checked={picked.includes(l.id)}
                        onChange={(e) => setPicked((p) => (e.currentTarget.checked ? [...p, l.id] : p.filter((x) => x !== l.id)))} />
                    ) : <span className="w-[13px]" aria-hidden />}
                    <span className="w-16 shrink-0 t-small text-muted nums"><bdi>{day(l.night)}</bdi></span>
                    <span className={`min-w-0 flex-1 ${l.voided ? 'text-muted line-through' : 'text-ink'}`}>{title(l)}</span>
                    {l.voidable && <button type="button" onClick={() => setVoiding(l)} className="t-small font-semibold text-ink underline underline-offset-4">{t('bill.void')}</button>}
                    {notable(l, w) && <button type="button" onClick={() => setNoting({ window: w, lineId: l.id })} data-credit-line={l.id}
                      className="t-small font-semibold text-ink underline underline-offset-4">{t('bill.creditNote')}</button>}
                    {isNoteLine(l) && <span className="t-small text-muted">{t('bill.noteLine')}</span>}
                    <span className={`shrink-0 nums ${l.kind === 'credit' ? 'text-success' : l.voided ? 'text-muted line-through' : 'text-ink'}`}>{l.kind === 'credit' ? '−' : ''}{money(l.amount)}</span>
                  </li>
                ))}
              </ul>
            )}
            {back.length > 0 && (
              <div className="mt-3 border-t border-line/70 pt-3" data-bill-refunds={w.payerId}>
                <p className="t-small mb-1.5 font-semibold text-ink">{t('bill.refunds')}</p>
                <RefundList refunds={back} />
              </div>
            )}
            <div className="mt-3 flex flex-wrap items-center gap-2">
              {w.open > 0n && open && (
                <button type="button" onClick={() => setPaying(w)} className="rounded-base bg-primary px-3 py-2 t-small font-semibold text-primary-ink">{t('settle.take', { amount: money(w.open) })}</button>
              )}
              {w.invoice ? (
                <>
                  <Link to={`/console/invoice/${w.invoice}`} className="inline-flex items-center gap-1.5 rounded-base border border-line px-3 py-2 t-small font-semibold text-ink no-underline">
                    <FileText className="h-4 w-4" aria-hidden />{t('bill.invoiceN', { n: w.invoice })}</Link>
                  {notes.filter((n) => n.invoice === w.invoice).map((n) => (
                    <Link key={n.number} to={`/console/credit-note/${n.number}`} className="inline-flex items-center gap-1.5 rounded-base border border-line px-3 py-2 t-small font-semibold text-ink no-underline">
                      <FileMinus className="h-4 w-4" aria-hidden />{t('bill.noteN', { n: n.number, amount: money(n.total) })}</Link>
                  ))}
                </>
              ) : (b.status === 'checkedIn' || b.status === 'checkedOut') && lines.length > 0 && (
                <button type="button" disabled={busy} onClick={() => run(() => api.issueInvoice(b.id, w.payerId), t('bill.invoiced'))}
                  className="rounded-base border border-line px-3 py-2 t-small font-semibold text-ink disabled:opacity-40">{t('bill.issue')}</button>
              )}
            </div>
          </section>
        )
      })}

      {failed.length > 0 && (
        <section aria-labelledby={`failed${b.id}`} className="rounded-lg border border-danger/50 bg-danger/5 p-4">
          <h4 id={`failed${b.id}`} className="font-semibold text-ink">{t('bill.failedRefunds')}</h4>
          <ul className="mt-2 space-y-2">
            {failed.map((p) => {
              const paid = desks.find((d) => d.paymentId === p.id)
              return (
                <li key={p.id} className="flex flex-wrap items-center justify-between gap-2 t-small" data-failed-refund={p.id}>
                  <span className="text-ink nums">{t('bill.failedRefund', { amount: money(p.amount) })}</span>
                  {paid ? <span className="text-success">{t('bill.paidAtDesk', { method: t(paid.method === 'cash' ? 'deskRefund.cash' : 'deskRefund.transfer'), reference: paid.reference, day: day(paid.day) })}</span>
                    : <button type="button" onClick={() => setDeskPaying(p)} className="rounded-base bg-primary px-3 py-2 font-semibold text-primary-ink">{t('bill.payAtDesk')}</button>}
                </li>
              )
            })}
          </ul>
        </section>
      )}

      {picked.length > 0 && (
        <div className="sticky bottom-0 flex flex-wrap items-center gap-2 rounded-lg border border-primary bg-surface p-3 shadow-2">
          <span className="t-small font-semibold text-ink">{t('bill.moveN', { n: picked.length })}</span>
          <select value={moveTo} onChange={(e) => setMoveTo(Number(e.currentTarget.value))} aria-label={t('bill.moveTo')}
            className="rounded-base border border-field bg-bg px-3 py-2 t-small text-ink">
            {targets.map((w) => <option key={w.payerId} value={w.payerId}>{w.payerId === 0 ? t('bill.guest', { name: w.name }) : w.name}</option>)}
          </select>
          <button type="button" disabled={busy} onClick={() => run(() => api.routeLines(b.id, picked, moveTo), t('bill.moved'))}
            className="rounded-base bg-primary px-3 py-2 t-small font-semibold text-primary-ink disabled:opacity-40">{t('bill.move')}</button>
        </div>
      )}

      {charging && <Charge booking={b} windows={targets} onClose={() => setCharging(false)} onDone={async () => { setCharging(false); await changed() }} />}
      <Settle booking={paying ? b : null} share={paying ? { payerId: paying.payerId, name: paying.name, open: paying.open } : undefined}
        onClose={() => setPaying(null)} onDone={async () => { setPaying(null); await changed() }} />
      {voiding && <Void booking={b} line={voiding} title={title(voiding)} onClose={() => setVoiding(null)} />}
      {noting && <NoteDialog booking={b} window={noting.window} first={noting.lineId} left={left}
        lines={bill.lines.filter((l) => l.payerId === noting.window.payerId && notable(l, noting.window))} onClose={() => setNoting(null)} />}
      {deskPaying && <DeskRefund booking={b} payment={deskPaying} onClose={() => setDeskPaying(null)} />}
    </div>
  )
}

/** A charge from the catalogue: the item, how many, the amount when it has none, and whose bill. */
function Charge({ booking: b, windows, onClose, onDone }: { booking: BookingView; windows: BillWindowView[]; onClose(): void; onDone(): void }) {
  const { api, t, tr, tenant } = useApp()
  const { money } = useFormat()
  const [extras, setExtras] = useState<ExtraView[] | null>(null)
  const [extraId, setExtraId] = useState(0)
  const [quantity, setQuantity] = useState('1')
  const [amount, setAmount] = useState('')
  const [payerId, setPayerId] = useState(windows[0]?.payerId ?? 0)
  const [busy, setBusy] = useState(false)
  useEffect(() => { api.extras().then((x) => { const live = x.filter((e) => e.active); setExtras(live); setExtraId(live[0]?.id ?? 0) }) }, [api])
  const extra = extras?.find((e) => e.id === extraId)
  const q = Number(quantity)
  const open = extra?.price === 0n
  const typed = parseMoney(amount, tenant.minorUnits)
  const ready = !!extra && Number.isInteger(q) && q >= 1 && q <= 99 && (!open || (typed !== null && typed > 0n))
  const submit = async (e: FormEvent) => {
    e.preventDefault()
    if (!extra || !ready) return
    setBusy(true)
    try { await api.postCharge(b.id, extra.id, q, open ? typed! : 0n, payerId); toast.success(t('bill.charged', { what: tr(extra.name) })); onDone() }
    catch (err) { toast.error(err instanceof Refused ? tr(err.reason) : t('err.generic')) }
    finally { setBusy(false) }
  }
  const field = 'mt-1 block w-full rounded-base border border-field bg-bg px-3 py-2.5 text-ink'
  return (
    <Dialog.Root open onOpenChange={(o) => !o && onClose()}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-[60] bg-black/40" />
        <Dialog.Content className="fixed inset-x-4 top-1/2 z-[70] mx-auto max-w-md -translate-y-1/2 rounded-lg border border-line bg-surface p-6 shadow-2">
          <div className="flex items-start justify-between gap-3">
            <Dialog.Title className="t-h2 text-ink">{t('bill.addCharge')}</Dialog.Title>
            <Dialog.Close className="grid h-9 w-9 place-items-center rounded-full hover:bg-surface-2" aria-label={t('console.cancel')}><X className="h-4 w-4" aria-hidden /></Dialog.Close>
          </div>
          <Dialog.Description className="t-small mt-1 text-muted"><span dir="ltr">{b.ref}</span> · {b.guestName}</Dialog.Description>
          {extras === null ? <div className="skeleton mt-5 h-24 rounded-base" aria-hidden /> : extras.length === 0 ? <p className="mt-5 text-ink">{t('bill.noExtras')}</p> : (
            <form className="mt-5 space-y-4" onSubmit={submit}>
              <label className="block"><span className="font-semibold text-ink">{t('bill.extra')}</span>
                <select value={extraId} onChange={(e) => setExtraId(Number(e.currentTarget.value))} className={field}>
                  {extras.map((x) => <option key={x.id} value={x.id}>{tr(x.name)}{x.price > 0n ? ` · ${money(x.price)}` : ''}</option>)}
                </select></label>
              <div className="grid grid-cols-2 gap-3">
                <label className="block"><span className="font-semibold text-ink">{t('bill.quantity')}</span>
                  <input inputMode="numeric" dir="ltr" value={quantity} onChange={(e) => setQuantity(e.currentTarget.value.replace(/\D/g, '').slice(0, 2))} className={`${field} nums`} /></label>
                {open && <label className="block"><span className="font-semibold text-ink">{t('bill.amount')}</span>
                  <input inputMode="decimal" dir="ltr" value={amount} onChange={(e) => setAmount(e.currentTarget.value)} className={`${field} nums`} /></label>}
              </div>
              {windows.length > 1 && (
                <label className="block"><span className="font-semibold text-ink">{t('bill.onBill')}</span>
                  <select value={payerId} onChange={(e) => setPayerId(Number(e.currentTarget.value))} className={field}>
                    {windows.map((w) => <option key={w.payerId} value={w.payerId}>{w.payerId === 0 ? t('bill.guest', { name: w.name }) : w.name}</option>)}
                  </select></label>
              )}
              {extra && <p className="t-small text-muted">{extra.taxed ? t('bill.taxed') : t('bill.untaxed')}</p>}
              <button type="submit" disabled={busy || !ready} className="w-full rounded-base bg-primary px-5 py-3.5 font-semibold text-primary-ink disabled:opacity-40">{t('bill.post')}</button>
            </form>
          )}
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  )
}

/** Voiding a charge: proposed here, approved by a second member of staff under Approvals. */
function Void({ booking: b, line, title, onClose }: { booking: BookingView; line: BillLineView; title: string; onClose(): void }) {
  const { api, t, tr } = useApp()
  const { money } = useFormat()
  const [why, setWhy] = useState('')
  const [busy, setBusy] = useState(false)
  const send = async () => {
    setBusy(true)
    try { await api.propose('voidCharge', b.id, BigInt(line.id), title, why); toast.success(t('propose.sent')); onClose() }
    catch (e) { toast.error(e instanceof Refused ? tr(e.reason) : t('err.generic')) }
    finally { setBusy(false) }
  }
  return (
    <Dialog.Root open onOpenChange={(o) => !o && onClose()}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-[60] bg-black/40" />
        <Dialog.Content className="fixed inset-x-4 top-1/2 z-[70] mx-auto max-w-md -translate-y-1/2 rounded-lg border border-line bg-surface p-6 shadow-2">
          <div className="flex items-start justify-between gap-3">
            <Dialog.Title className="t-h2 text-ink">{t('bill.voidTitle', { what: title })}</Dialog.Title>
            <Dialog.Close className="grid h-9 w-9 place-items-center rounded-full hover:bg-surface-2" aria-label={t('console.cancel')}><X className="h-4 w-4" aria-hidden /></Dialog.Close>
          </div>
          <Dialog.Description className="t-small mt-1 text-muted">{t('bill.voidLead', { amount: money(line.amount) })}</Dialog.Description>
          <form className="mt-5 space-y-4" onSubmit={(e) => { e.preventDefault(); send() }}>
            <label className="block"><span className="font-semibold text-ink">{t('propose.why')}</span>
              <textarea rows={3} value={why} onChange={(e) => setWhy(e.currentTarget.value)} className="mt-1.5 w-full rounded-base border border-field bg-bg px-3 py-2.5 text-ink" /></label>
            <button type="submit" disabled={busy || !why.trim()} className="w-full rounded-base bg-primary px-5 py-3.5 font-semibold text-primary-ink disabled:opacity-40">{t('propose.send')}</button>
          </form>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  )
}

/**
 * A credit note against an invoiced bill: the lines it takes back and how much of each before tax; each
 * line's taxes go with it, in proportion. Proposed here, approved by a second member of staff under
 * Approvals, and the bill's card refunded then.
 */
function NoteDialog({ booking: b, window: w, lines, first, left, onClose }: { booking: BookingView; window: BillWindowView; lines: BillLineView[]; first: number;
  left(l: BillLineView): bigint; onClose(): void }) {
  const { api, t, tr, tenant } = useApp()
  const { money, day } = useFormat()
  const title = useLineTitle()
  const [picked, setPicked] = useState<Record<number, string>>(() => {
    const l = lines.find((x) => x.id === first)
    return l ? { [l.id]: toDecimal(left(l), tenant.minorUnits) } : {}
  })
  const [why, setWhy] = useState('')
  const [busy, setBusy] = useState(false)
  const chosen = lines.filter((l) => picked[l.id] !== undefined)
  const amounts = chosen.map((l) => parseMoney(picked[l.id], tenant.minorUnits))
  const ok = chosen.length > 0 && chosen.length <= 16 && amounts.every((a, i) => a !== null && a > 0n && a <= left(chosen[i])) && why.trim() !== ''
  const net = amounts.reduce<bigint>((s, a) => s + (a ?? 0n), 0n)
  const send = async () => {
    if (!ok) return
    setBusy(true)
    try { await api.proposeCreditNote(b.id, w.invoice!, chosen.map((l) => l.id), amounts as bigint[], why.trim()); toast.success(t('propose.sent')); onClose() }
    catch (e) { toast.error(e instanceof Refused ? tr(e.reason) : t('err.generic')) }
    finally { setBusy(false) }
  }
  return (
    <Dialog.Root open onOpenChange={(o) => !o && onClose()}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-[60] bg-black/40" />
        <Dialog.Content className="fixed inset-x-4 top-1/2 z-[70] mx-auto max-h-[90vh] max-w-lg -translate-y-1/2 overflow-y-auto rounded-lg border border-line bg-surface p-6 shadow-2">
          <div className="flex items-start justify-between gap-3">
            <Dialog.Title className="t-h2 text-ink">{t('note.title', { n: w.invoice ?? 0 })}</Dialog.Title>
            <Dialog.Close className="grid h-9 w-9 place-items-center rounded-full hover:bg-surface-2" aria-label={t('console.cancel')}><X className="h-4 w-4" aria-hidden /></Dialog.Close>
          </div>
          <Dialog.Description className="t-small mt-1 text-muted">{t('note.lead')}</Dialog.Description>
          <form className="mt-5 space-y-4" onSubmit={(e) => { e.preventDefault(); send() }}>
            <ul className="divide-y divide-line/70">
              {lines.map((l) => {
                const on = picked[l.id] !== undefined
                const typed = on ? parseMoney(picked[l.id], tenant.minorUnits) : null
                const bad = on && !(typed !== null && typed > 0n && typed <= left(l))
                return (
                  <li key={l.id} className="flex flex-wrap items-center gap-3 py-2">
                    <input type="checkbox" checked={on} aria-label={t('bill.pick', { line: title(l) })}
                      onChange={(e) => { const c = e.currentTarget.checked; setPicked((p) => { const n = { ...p }; if (c) n[l.id] = toDecimal(left(l), tenant.minorUnits); else delete n[l.id]; return n }) }} />
                    <span className="min-w-0 flex-1 text-sm text-ink">{title(l)} <span className="t-small text-muted nums">· <bdi>{day(l.night)}</bdi> · {t('note.left', { amount: money(left(l)) })}</span></span>
                    {on && <input inputMode="decimal" dir="ltr" value={picked[l.id]} aria-label={t('note.amountFor', { line: title(l) })} aria-invalid={bad}
                      onChange={(e) => { const v = e.currentTarget.value; setPicked((p) => ({ ...p, [l.id]: v })) }}
                      className={`w-28 rounded-base border bg-bg px-2 py-1.5 text-end text-sm nums text-ink ${bad ? 'border-danger' : 'border-field'}`} />}
                  </li>
                )
              })}
            </ul>
            <p className="t-small text-muted nums">{t('note.net', { amount: money(net) })}</p>
            <label className="block"><span className="font-semibold text-ink">{t('propose.why')}</span>
              <textarea rows={3} value={why} onChange={(e) => setWhy(e.currentTarget.value)} className="mt-1.5 w-full rounded-base border border-field bg-bg px-3 py-2.5 text-ink" /></label>
            <button type="submit" disabled={busy || !ok} className="w-full rounded-base bg-primary px-5 py-3.5 font-semibold text-primary-ink disabled:opacity-40">{t('propose.send')}</button>
          </form>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  )
}

/** A refund the gateway would not make, recorded as paid at the desk in cash or by transfer; approved by a second member of staff. */
function DeskRefund({ booking: b, payment, onClose }: { booking: BookingView; payment: PaymentView; onClose(): void }) {
  const { api, t, tr } = useApp()
  const { money } = useFormat()
  const [method, setMethod] = useState<DeskMethod>('cash')
  const [reference, setReference] = useState('')
  const [why, setWhy] = useState('')
  const [busy, setBusy] = useState(false)
  const bytes = new TextEncoder().encode(reference.trim()).length
  const ok = bytes > 0 && bytes <= 64 && why.trim() !== ''
  const send = async () => {
    setBusy(true)
    try { await api.proposeDeskRefund(b.id, payment.id, method, reference.trim(), why.trim()); toast.success(t('propose.sent')); onClose() }
    catch (e) { toast.error(e instanceof Refused ? tr(e.reason) : t('err.generic')) }
    finally { setBusy(false) }
  }
  return (
    <Dialog.Root open onOpenChange={(o) => !o && onClose()}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-[60] bg-black/40" />
        <Dialog.Content className="fixed inset-x-4 top-1/2 z-[70] mx-auto max-w-md -translate-y-1/2 rounded-lg border border-line bg-surface p-6 shadow-2">
          <div className="flex items-start justify-between gap-3">
            <Dialog.Title className="t-h2 text-ink">{t('deskRefund.title', { amount: money(payment.amount) })}</Dialog.Title>
            <Dialog.Close className="grid h-9 w-9 place-items-center rounded-full hover:bg-surface-2" aria-label={t('console.cancel')}><X className="h-4 w-4" aria-hidden /></Dialog.Close>
          </div>
          <Dialog.Description className="t-small mt-1 text-muted">{t('deskRefund.lead')}</Dialog.Description>
          <form className="mt-5 space-y-4" onSubmit={(e) => { e.preventDefault(); if (ok) send() }}>
            <fieldset>
              <legend className="font-semibold text-ink">{t('deskRefund.method')}</legend>
              <div className="mt-2 flex gap-4">
                {(['cash', 'transfer'] as const).map((m) => (
                  <label key={m} className="flex items-center gap-2 text-ink"><input type="radio" name="desk-method" checked={method === m} onChange={() => setMethod(m)} />{t(m === 'cash' ? 'deskRefund.cash' : 'deskRefund.transfer')}</label>
                ))}
              </div>
            </fieldset>
            <label className="block"><span className="font-semibold text-ink">{t(method === 'cash' ? 'deskRefund.receipt' : 'deskRefund.transferRef')}</span>
              <input dir="ltr" value={reference} onChange={(e) => setReference(e.currentTarget.value)} className="mt-1.5 w-full rounded-base border border-field bg-bg px-3 py-2.5 text-ink" />
              {bytes > 64 && <span className="t-small mt-1 block text-danger">{t('deskRefund.tooLong')}</span>}</label>
            <label className="block"><span className="font-semibold text-ink">{t('propose.why')}</span>
              <textarea rows={3} value={why} onChange={(e) => setWhy(e.currentTarget.value)} className="mt-1.5 w-full rounded-base border border-field bg-bg px-3 py-2.5 text-ink" /></label>
            <button type="submit" disabled={busy || !ok} className="w-full rounded-base bg-primary px-5 py-3.5 font-semibold text-primary-ink disabled:opacity-40">{t('propose.send')}</button>
          </form>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  )
}

/** The bill in a sheet of its own, for the desk. */
export function BillSheet({ booking, onClose, onChanged }: { booking: BookingView | null; onClose(): void; onChanged(): void }) {
  const { t } = useApp()
  if (!booking) return null
  return (
    <Dialog.Root open onOpenChange={(o) => !o && onClose()}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-40 bg-black/35" />
        <Dialog.Content className="fixed inset-y-0 end-0 z-50 w-[min(100vw,640px)] overflow-y-auto border-s border-line bg-bg p-5 shadow-2 sm:p-6">
          <div className="mb-4 flex items-start justify-between gap-3">
            <div>
              <Dialog.Title className="t-h2 text-ink">{t('bill.title', { name: booking.guestName })}</Dialog.Title>
              <Dialog.Description className="t-small mt-1 text-muted" dir="ltr">{booking.ref}</Dialog.Description>
            </div>
            <Dialog.Close className="grid h-9 w-9 place-items-center rounded-full hover:bg-surface-2" aria-label={t('console.cancel')}><X className="h-4 w-4" aria-hidden /></Dialog.Close>
          </div>
          <BillPanel booking={booking} onChanged={onChanged} />
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  )
}
