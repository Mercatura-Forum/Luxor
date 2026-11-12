#!/usr/bin/env python3
"""THE GATE'S WALK: every guest and console screen of Luxor, in a real browser, at 390 and 1440 px, in
English and Arabic, on the demo data source of a dev server started from the gated tree.

Before the screens are walked, each browser's demo hotel is given the documents a fresh demo does not
have, through the demo's own API (the module the page itself loads): an invoice for a guest in house,
and a credit note against it, proposed by one member of the desk and approved by the other. The
invoice and the credit note pages are then walked as documents, not as "there is no such number".

A screen is red when, after it has drawn:
  - the browser reported an error (a console error, an uncaught exception, a failed request to the
    page's own origin, or an HTTP status of 400 or above from it);
  - the page is wider than the window (a horizontal scroll at that width);
  - the document's language or direction is not the one asked for (ar is rtl);
  - it shows the not-found page, or a skeleton still drawing, where a screen was asked for;
  - it lacks the element that proves its content drew (the invoice's and the credit note's own marks).

The count printed is of screens walked and found clean; it must equal routes x widths x languages, so
a walk that reached nothing is red, not quietly green.

  python3 tools/walk.py --base http://127.0.0.1:5199 [--out walk] [--control]

--control runs the walk's own control: each class of fault the walk claims to catch is injected into
one screen (a thrown error, a console error, a page wider than the window, the wrong direction, a
document that does not draw) and the walk must go red for that reason, and for no other.

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import argparse, json, os, sys
from urllib.parse import urlsplit
from playwright.sync_api import sync_playwright

ROUTES = [
    "/", "/rooms", "/rooms/1", "/stays", "/no-such-page",
    "/console", "/console/rates", "/console/bookings", "/console/audit", "/console/reports", "/console/approvals",
    "/console/book", "/console/room-plan", "/console/housekeeping", "/console/extras", "/console/staff", "/console/setup",
    "/console/invoice/1", "/console/credit-note/1",
    "/console/products", "/rooms?code=ACME", "/rooms?code=NOPE", "/rooms?code=SPRING26",
    "/console/groups?open=1", "/console/setup?tab=plans",
    # the card on file: a booking by phone's card link, and a deposit stay's manage page showing its card kept
    # (the references and link secrets are the seed's, filled in for each browser)
    "/card/{phoneRef}?k={phoneSecret}", "/manage/{depRef}?k={depSecret}",
    # guest email: the six steps done, and a guest's manage page with its confirmation sent and its pre-arrival note waiting
    "/console/email", "/manage/{mailRef}?k={mailSecret}",
]
# the element that proves a screen's content drew, where a generic check cannot tell
MARKS = {
    "/console/invoice/1": "[data-invoice='1']",
    "/console/credit-note/1": "[data-credit-note='1'] [data-note-refund] [data-refund-state='done']",
    "/console/room-plan": "[data-room-plan] [data-plan-guest]",
    "/console/reports": "body:has([data-reports]):has([data-on-books])",
    "/console/products": "body:has([data-company='ACME']):has([data-plan='ACME-NEG'] [data-sold-to='1'])"
                         ":has([data-promo='SPRING26'] [data-promo-uses='1']):has([data-plan='SPRING'] [data-sold-to='-1'])",
    "/rooms?code=ACME": "body:has([data-code-banner='ok']):has([data-coded-rate])",
    "/rooms?code=NOPE": "[data-code-banner='refused']",
    "/rooms?code=SPRING26": "body:has([data-code-banner='ok'][data-code-kind='promotion']):has([data-coded-rate])",
    # the bed-and-breakfast plan: its inclusions under its name and one price "incl. breakfast"; the setup lists them
    "/rooms": "body:has([data-package] li):has([data-package-price])",
    "/console/setup?tab=plans": "body:has([data-plan-package] li):has([data-card-rule='on'])",
    # the books' rules: a hotel installed by this build keeps them at the newest epoch it knows
    "/console/setup": "[data-rules='1/1']",
    # the day list: a booking by phone with no card by its day, and a no-show fee the card declined
    "/console": "body:has([data-card-desk] [data-card-kind='unguaranteed']):has([data-card-desk] [data-card-kind='declined'])",
    "/card/{phoneRef}?k={phoneSecret}": "[data-card-form] input[type='checkbox']",
    "/manage/{depRef}?k={depSecret}": "[data-manage-card='kept']",
    "/console/email": "[data-guest-email='on']:has([data-mail-step='6'][data-done='yes']):has([data-mail-step='5'][data-done='yes']):has([data-mail-step='2'] [data-mail-in-use='postmark'])",
    "/manage/{mailRef}?k={mailSecret}": "[data-manage-mail]:has([data-mail-state='sent']):has([data-mail-state='due'])",
    "/console/groups?open=1": "[data-block='1'][data-block-open='yes']:has([data-block-picked='5']):has([data-block-nights] tbody tr):has([data-rooming-list] [data-rooming]):has([data-pickup-form])",
}
NOT_FOUND = {"en": "This page is not here", "ar": "هذه الصفحة غير موجودة"}

# Through the module the page loads: the first guest in house pays the stay on one card and two bottles
# from the minibar on a second; an invoice; a credit note taking back the first room night, proposed
# by one desk user and approved by the other, whose refund goes back across both cards. Then a company
# with a negotiated plan closed to it: the house rate at a fifth off, sold only under the code ACME. Then a
# promotion: a plan at a tenth off sold only under codes, opened by SPRING26 for two bookings; one is booked
# under it, which counts one use, and a stay outside its dates is refused by the promotion. Then a group
# block of three rooms for two nights: two guests are picked up from it (two rooms for both nights, one
# room for the first), and a third asking for two rooms is refused because the block has one left.
SEED = """async () => {
  const m = await import('/src/api/demo.ts')
  const api = m.demoApi('almar')
  const inHouse = await api.inHouse()
  if (!inHouse.length) throw new Error('the demo has no guest in house to invoice')
  const b = inHouse[0].booking.id
  const T = await import('/src/api/types.ts')
  const pay = async () => {
    const open = (await api.bill(b)).windows[0].open
    const a = await api.authorise('approve', open, T.BOOKING_REF_BASE + b)
    await api.settleAtDesk(b, a.authId)
  }
  await pay()
  const extra = (await api.extras()).find((e) => e.active && e.price > 0n)
  if (!extra) throw new Error('the demo has no extra with a price')
  await api.postCharge(b, extra.id, 2, 0n, 0)
  await pay()
  const inv = await api.issueInvoice(b, 0)
  const bill = await api.bill(b)
  const lines = bill.lines.filter((l) => l.kind === 'roomNight' && l.payerId === 0)
  if (!lines.length) throw new Error('the invoiced bill has no room night to credit')
  const pid = await api.proposeCreditNote(b, inv, [lines[0].id], [lines[0].amount], 'walk: a night credited')
  await api.approve(pid)
  const notes = await api.creditNotes(b)
  const slices = await api.creditNoteRefund(1)
  const failed = (await api.refunds(b)).filter((r) => r.state === 'failed').length
  const co = await api.upsertCompany(0, { code: 'ACME', name: 'Acme Trading', active: true })
  const house = (await api.setupPlans()).find((p) => p.active && !p.prepaid)
  if (!house) throw new Error('the demo has no house rate to negotiate from')
  const neg = await api.upsertRatePlan(0, { ...house, code: 'ACME-NEG', name: { en: 'Acme negotiated', ar: 'سعر أكمي' }, discountBps: 2000 })
  await api.setPlanAccess(neg, co, true)
  const coded = (await api.codeInfo(' acme ')).planIds.filter((x) => x === neg).length
  const hidden = !(await api.plans()).some((p) => p.id === neg)
  const today = (await import('/src/lib/days.ts')).localToday()
  const spring = await api.upsertRatePlan(0, { ...house, code: 'SPRING', name: { en: 'Spring offer', ar: 'عرض الربيع' }, discountBps: 1000 })
  await api.setPlanAccess(spring, 0, true)
  await api.upsertPromo(0, { code: 'SPRING26', name: 'Spring in the garden', planId: spring, bookFrom: today, bookUntil: today + 30, stayFrom: today, stayUntil: today + 90,
    maxUses: 2, active: true })
  const req = { arrival: today + 5, nights: 2, rooms: 1, adults: 2, children: 0, code: 'SPRING26' }
  const offer = (await api.search(req)).offers.find((o) => o.planId === spring)
  if (!offer) throw new Error('the code SPRING26 opened no spring rate')
  const hold = await api.placeHold(offer.roomTypeId, spring, req, offer.quoteHash)
  const auth = await api.authorise('approve', offer.guarantee, hold.holdId)
  await api.confirmHold(hold.holdId, { name: 'Mona Said', email: '', note: '' }, auth.authId)
  const promoUsed = (await api.promos()).find((p) => p.code === 'SPRING26')?.used
  let promoWindow = 'admitted'
  try { await api.quoteDetail(offer.roomTypeId, spring, { ...req, arrival: today + 95 }) } catch (e) { promoWindow = e.kind ?? String(e) }
  const G = today + 10
  const grid = await api.grid(G, 2)
  const row = grid.find((r) => r.cells.every((c) => c.bar !== null && !c.stopSell && c.allotment - c.sold - c.held - c.blocked >= 3))
  if (!row) throw new Error('the demo has no room type with three rooms free on the group nights')
  const blockId = await api.upsertBlock(0, { name: 'Hassan wedding', companyId: 0, roomTypeId: row.roomTypeId, planId: house.id, arrival: G, nights: 2, rooms: 3, cutoff: today + 3 })
  const pickReq = { arrival: G, nights: 2, rooms: 2, adults: 2, children: 0 }
  await api.pickUp(blockId, await api.blockQuote(blockId, pickReq), pickReq, { name: 'Leila Hassan', email: '', note: '' })
  const oneReq = { arrival: G, nights: 1, rooms: 1, adults: 2, children: 0 }
  await api.pickUp(blockId, await api.blockQuote(blockId, oneReq), oneReq, { name: 'Youssef Hassan', email: '', note: '' })
  let groupFull = 'admitted'
  try { await api.blockQuote(blockId, { ...oneReq, arrival: G + 1, rooms: 2 }) } catch (e) { groupFull = e.kind ?? String(e) }
  const groupPicked = (await api.blocks()).find((x) => x.id === blockId)?.pickedNights
  // a package: the bed-and-breakfast plan booked, its breakfasts on the bill as their own lines the desk cannot void alone
  const pkgReq = { arrival: today + 30, nights: 2, rooms: 1, adults: 2, children: 0 }
  const pkgOffer = (await api.search(pkgReq)).offers.find((o) => o.packageTotal > 0n)
  if (!pkgOffer) throw new Error('the demo offers no package rate')
  const pkgDetail = await api.quoteDetail(pkgOffer.roomTypeId, pkgOffer.planId, pkgReq)
  const pkgHold = await api.placeHold(pkgOffer.roomTypeId, pkgOffer.planId, pkgReq, pkgOffer.quoteHash)
  const pkgAuth = await api.authorise('approve', pkgOffer.guarantee, pkgHold.holdId)
  const pkgBooked = await api.confirmHold(pkgHold.holdId, { name: 'Sara Nabil', email: '', note: '' }, pkgAuth.authId)
  const pkgBill = (await api.bill(pkgBooked.booking.id)).lines.filter((l) => l.kind === 'extra')
  const pkgLines = pkgBill.length
  const pkgVoidable = pkgBill.filter((l) => l.voidable).length
  const pkgAdds = pkgDetail.total === pkgOffer.total && pkgDetail.package.length === 2 && pkgOffer.guarantee < pkgOffer.total - pkgOffer.packageTotal
  // the card on file: the owner turns the rule on; a deposit rate takes 30% of the room at once on a card kept on file, and the
  // same confirmation without the guest's agreement is refused; a booking by phone waits for a card and is flagged on the day
  // list once its day has come; another puts a card that declines later charges on file from its card link, does not
  // arrive, and the night audit's charge of its no-show fee is declined and shown to the desk
  await api.requireCardOnFile()
  const day0 = (await api.property()).businessDate
  const dep = await api.upsertRatePlan(0, { ...house, code: 'DEP30', name: { en: 'Deposit rate', ar: 'سعر بعربون' }, discountBps: 0, prepaid: false, guarantee: undefined })
  await api.setPlanDeposit(dep, 3000)
  const depReq = { arrival: today + 20, nights: 3, rooms: 1, adults: 2, children: 0 }
  const depOffer = (await api.search(depReq)).offers.find((o) => o.planId === dep)
  if (!depOffer) throw new Error('the demo offers no deposit rate')
  const depHold = await api.placeHold(depOffer.roomTypeId, dep, depReq, depOffer.quoteHash)
  const bare = await api.authorise('approve', depOffer.guarantee, depHold.holdId)
  let unagreed = 'admitted'
  try { await api.confirmHold(depHold.holdId, { name: 'Hana Fathy', email: '', note: '' }, bare.authId) } catch (e) { unagreed = e.kind ?? String(e) }
  const depAuth = await api.authorise('approve', depOffer.guarantee, depHold.holdId, true)
  const depBooked = await api.confirmHold(depHold.holdId, { name: 'Hana Fathy', email: '', note: '' }, depAuth.authId)
  const base = depOffer.roomSubtotal + depOffer.taxTotal
  const depositRight = depOffer.guarantee > 0n && (depOffer.guarantee * 10000n - base * 3000n) ** 2n <= 5000n ** 2n && depBooked.booking.paid === depOffer.guarantee
  const depCard = (await api.manageCard(depBooked.booking.ref, depBooked.manageSecret))?.state
  const phoneOn = async (arrival, name, planId = house.id) => {
    const r = { arrival, nights: 2, rooms: 1, adults: 2, children: 0 }
    const o = (await api.search(r)).offers.find((x) => x.planId === planId)
    if (!o) throw new Error('the demo offers no house rate for a booking by phone')
    return api.bookByStaff('phone', o, r, { name, email: '', note: '' }, [])
  }
  const phone = await phoneOn(day0 + house.freeCancelDaysBefore, 'Karim Adel')
  const phoneCard = await api.manageCard(phone.booking.ref, phone.manageSecret)
  // a no-show fee of two nights, so that the guarantee's one night leaves a night to charge to the card
  const two = await api.upsertRatePlan(0, { ...house, code: 'TWO-NIGHTS', name: { en: 'Two-night terms', ar: 'شروط الليلتين' }, discountBps: 0, prepaid: false, penaltyNights: 2, guarantee: undefined })
  const late = await phoneOn(day0, 'Nadia Samir', two)
  const lateDue = (await api.manageCard(late.booking.ref, late.manageSecret))?.due ?? 0n
  const lateAuth = await api.authorise('mitDeclined', lateDue, T.BOOKING_REF_BASE + late.booking.id, true)
  await api.putCardOnFile(late.booking.ref, late.manageSecret, lateAuth.authId)
  await api.openAudit(day0)
  await api.advanceAudit(day0)
  const desk = await api.cardDesk(day0)
  const flagged = desk.filter((x) => x.kind === 'unguaranteed' && x.bookingId === phone.booking.id).length
  const declined = desk.filter((x) => x.kind === 'declined' && x.bookingId === late.booking.id && x.outstanding > 0n).length
  // guest email: the owner connects the relay, gives an account and approves it; turning on before the test email is
  // refused; after the test it turns on, and a booking made with an address has its confirmation sent at once and its
  // note two days before arrival waiting for its day
  await api.connectMailRelay()
  const acct = await api.saveMailAccount({ provider: 'postmark', from: 'stay@almar.example', fromName: 'Al Mar', testTo: 'owner@almar.example', lang: 'en', fields: { apiKey: 'walk-key' } })
  await api.approveMailAccount(acct.digest)
  let mailEarly = 'admitted'
  try { await api.setGuestEmail(true) } catch (e) { mailEarly = e.kind ?? String(e) }
  const mailTest = await api.sendMailTest(acct.digest)
  await api.setGuestEmail(true)
  const mailReq = { arrival: today + 21, nights: 2, rooms: 1, adults: 2, children: 0 }
  const mailOffer = (await api.search(mailReq)).offers.find((o) => o.planId === house.id)
  if (!mailOffer) throw new Error('the demo offers no house rate for the guest email stay')
  const mailHold = await api.placeHold(mailOffer.roomTypeId, house.id, mailReq, mailOffer.quoteHash)
  const mailAuth = await api.authorise('approve', mailOffer.guarantee, mailHold.holdId, true)
  const mailBooked = await api.confirmHold(mailHold.holdId, { name: 'Yara Mostafa', email: 'yara@guest.example', note: '', lang: 'ar' }, mailAuth.authId)
  const mailRows = (await api.manageMail(mailBooked.booking.ref, mailBooked.manageSecret)).rows.map((r) => `${r.kind}:${r.state}`).join(',')
  const mailOn = (await api.mailSetup()).on
  return { booking: b, invoice: inv, notes: notes.length, slices: slices.length, cards: new Set(slices.map((r) => r.card)).size, failed, coded, hidden, promoUsed, promoWindow,
    blockId, groupPicked, groupFull, pkgLines, pkgVoidable, pkgAdds, unagreed, depositRight, depCard, phoneWanted: phoneCard?.state, flagged, declined,
    phoneRef: phone.booking.ref, phoneSecret: phone.manageSecret, depRef: depBooked.booking.ref, depSecret: depBooked.manageSecret,
    mailEarly, mailTested: mailTest.ok, mailAttach: mailBooked.mail, mailRows, mailOn, mailRef: mailBooked.booking.ref, mailSecret: mailBooked.manageSecret }
}"""

CONTROL_FAULTS = {
    # kind: (init script injected into the page, the words the walk must report)
    "thrown": ("window.addEventListener('load', () => setTimeout(() => { throw new Error('walk control: thrown') }, 0))", "pageerror"),
    "console": ("window.addEventListener('load', () => console.error('walk control: console error'))", "console error"),
    "overflow": ("window.addEventListener('load', () => { const d = document.createElement('div'); d.style.cssText = 'width:3000px;height:4px'; document.body.appendChild(d) })", "wider than the window"),
    # the control walks in Arabic: the page held left to right, put back at once whenever the app sets it
    "direction": ("window.addEventListener('load', () => { const h = document.documentElement; const wrong = () => { if (h.dir !== 'ltr') h.dir = 'ltr' };"
                  " wrong(); new MutationObserver(wrong).observe(h, { attributes: true, attributeFilter: ['dir'] }) })", "direction"),
}


def walk(p, base, widths, langs, routes, out, inject=None, mark_override=None, shots=False):
    """Walk; returns (screens clean, list of (screen, reason))."""
    origin = "{0.scheme}://{0.netloc}".format(urlsplit(base))
    marks = dict(MARKS, **(mark_override or {}))
    clean, red = 0, []
    b = p.chromium.launch()
    for lang in langs:
        for w in widths:
            ctx = b.new_context(viewport={"width": w, "height": 844 if w < 800 else 900}, device_scale_factor=2 if w < 800 else 1)
            ctx.add_init_script(f"try{{sessionStorage.setItem('luxor:tenant','almar');sessionStorage.setItem('luxor:source','demo');localStorage.setItem('luxor:lang','{lang}');localStorage.setItem('luxor:mode','light')}}catch(e){{}}")
            pg = ctx.new_page()
            errs = []
            pg.on("console", lambda m: m.type == "error" and errs.append("console error: " + m.text[:200]))
            pg.on("pageerror", lambda e: errs.append("pageerror: " + str(e)[:200]))
            pg.on("requestfailed", lambda r: r.url.startswith(origin) and "ERR_ABORTED" not in (r.failure or "") and errs.append(f"request failed: {r.url[:120]} {r.failure}"))
            pg.on("response", lambda r: r.status >= 400 and r.url.startswith(origin) and errs.append(f"HTTP {r.status}: {r.url[:120]}"))
            # the documents a fresh demo lacks, made through the demo's own API, then a new document
            pg.goto(f"{base}/#/no-such-page"); pg.wait_for_load_state("networkidle")
            try:
                seeded = pg.evaluate(SEED)
            except Exception as e:
                red.append((f"{lang}-{w} seed", f"the demo could not be given an invoice and a credit note: {str(e)[:200]}"))
                ctx.close(); continue
            if seeded.get("invoice") != 1 or seeded.get("notes") != 1:
                red.append((f"{lang}-{w} seed", f"the seed made invoice {seeded.get('invoice')} and {seeded.get('notes')} credit notes, not invoice 1 and one note"))
            if seeded.get("coded") != 1 or seeded.get("hidden") is not True:
                red.append((f"{lang}-{w} seed", f"the code ACME opened {seeded.get('coded')} negotiated plans (hidden from the public list: {seeded.get('hidden')}), not one hidden plan"))
            if seeded.get("promoUsed") != 1 or seeded.get("promoWindow") != "promoClosed":
                red.append((f"{lang}-{w} seed", f"the promotion counted {seeded.get('promoUsed')} uses after one booking and a stay outside its dates gave {seeded.get('promoWindow')}, not one use and promoClosed"))
            if seeded.get("blockId") != 1 or seeded.get("groupPicked") != 5 or seeded.get("groupFull") != "blockFull":
                red.append((f"{lang}-{w} seed", f"the group block {seeded.get('blockId')} counted {seeded.get('groupPicked')} room nights picked up and a pickup past it gave {seeded.get('groupFull')}, not block 1, 5 and blockFull"))
            if seeded.get("pkgLines") != 2 or seeded.get("pkgVoidable") != 0 or seeded.get("pkgAdds") is not True:
                red.append((f"{lang}-{w} seed", f"the package stay put {seeded.get('pkgLines')} breakfast lines on the bill ({seeded.get('pkgVoidable')} voidable alone; its breakdown adds up and its guarantee is the room's: {seeded.get('pkgAdds')}), not two, none voidable, and yes"))
            if seeded.get("unagreed") != "payment" or seeded.get("depositRight") is not True or seeded.get("depCard") != "kept":
                red.append((f"{lang}-{w} seed", f"the deposit stay: a confirmation without the guest's agreement gave {seeded.get('unagreed')}, its deposit was 30% and paid: {seeded.get('depositRight')}, its card {seeded.get('depCard')}; not payment, yes and kept"))
            if seeded.get("phoneWanted") != "wanted" or seeded.get("flagged") != 1 or seeded.get("declined") != 1:
                red.append((f"{lang}-{w} seed", f"the bookings by phone: a card {seeded.get('phoneWanted')}, {seeded.get('flagged')} flagged unguaranteed, {seeded.get('declined')} declined no-show fees; not wanted, 1 and 1"))
            if seeded.get("mailEarly") != "invalid" or seeded.get("mailTested") is not True or seeded.get("mailOn") is not True \
                    or seeded.get("mailAttach") != "queued" or seeded.get("mailRows") != "confirmation:sent,preArrival:due":
                red.append((f"{lang}-{w} seed", f"guest email: on before the test gave {seeded.get('mailEarly')}, the test {seeded.get('mailTested')}, on {seeded.get('mailOn')}, "
                                                f"the booking's address {seeded.get('mailAttach')}, its messages {seeded.get('mailRows')}; not invalid, True, True, queued, "
                                                "confirmation:sent,preArrival:due"))
            if seeded.get("slices") != 2 or seeded.get("cards") != 2 or seeded.get("failed") != 0:
                red.append((f"{lang}-{w} seed", f"the note's refund went as {seeded.get('slices')} slices on {seeded.get('cards')} cards with {seeded.get('failed')} failed, not two done on two cards"))
            if inject:
                ctx.add_init_script(inject)
            errs.clear()
            for route in routes:
                name = f"{lang}-{w}-{route.strip('/').replace('/', '_').replace('?', '_').replace('=', '-').replace('{', '').replace('}', '') or 'home'}"
                # a route naming the seed's references is walked at the ones this browser's seed made
                url = route.format(**seeded) if "{" in route else route
                pg.goto("about:blank")
                pg.goto(f"{base}/#{url}")
                pg.wait_for_load_state("networkidle")
                try:
                    pg.wait_for_function("() => !document.querySelector('.skeleton')", timeout=8000)
                except Exception:
                    pass
                pg.wait_for_timeout(400)
                why = list(errs)
                errs.clear()
                facts = pg.evaluate("""() => ({
                    sw: document.documentElement.scrollWidth, iw: window.innerWidth,
                    lang: document.documentElement.lang, dir: document.documentElement.dir,
                    h1: [...document.querySelectorAll('h1')].map((h) => h.innerText.trim()),
                    skeleton: !!document.querySelector('.skeleton'),
                    text: document.body.innerText.trim().length })""")
                if facts["sw"] > facts["iw"]:
                    why.append(f"the page is {facts['sw']} px, wider than the window ({facts['iw']} px)")
                want_dir = "rtl" if lang == "ar" else "ltr"
                if facts["lang"] != lang or facts["dir"] != want_dir:
                    why.append(f"language {facts['lang']!r} direction {facts['dir']!r}, asked for {lang!r} {want_dir!r}")
                lost = NOT_FOUND[lang] in facts["h1"]
                if route == "/no-such-page":
                    if not lost:
                        why.append("the not-found page did not show for an address that does not exist")
                elif lost:
                    why.append("shows the not-found page")
                if facts["skeleton"]:
                    why.append("still drawing (a skeleton) after 8 s")
                if facts["text"] < 40:
                    why.append(f"almost nothing drew ({facts['text']} characters)")
                if route in marks and pg.locator(marks[route]).count() == 0:
                    why.append(f"the mark of its content ({marks[route]}) is not on the page")
                if why:
                    pg.screenshot(path=os.path.join(out, name + ".png"), full_page=True)
                    red.extend((name, x) for x in why)
                else:
                    clean += 1
                    if shots:
                        pg.screenshot(path=os.path.join(out, name + ".png"), full_page=True)
            ctx.close()
    b.close()
    return clean, red


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--out", default="walk")
    ap.add_argument("--widths", default="390,1440")
    ap.add_argument("--langs", default="en,ar")
    ap.add_argument("--control", action="store_true")
    ap.add_argument("--routes", default="", help="walk only these routes (comma-separated, as ROUTES spells them), for a look by eye")
    ap.add_argument("--shots", action="store_true", help="save a screenshot of every screen, clean ones too")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    widths = [int(x) for x in a.widths.split(",")]
    langs = a.langs.split(",")
    with sync_playwright() as p:
        if not a.control:
            routes = [r for r in ROUTES if r in a.routes.split(",")] if a.routes else ROUTES
            if a.routes and len(routes) != len(a.routes.split(",")):
                sys.exit(f"--routes names a route the walk does not have: {sorted(set(a.routes.split(',')) - set(ROUTES))}")
            clean, red = walk(p, a.base, widths, langs, routes, a.out, shots=a.shots)
            want = len(routes) * len(widths) * len(langs)
            print(f"count: {clean} of {want} screens walked clean ({len(routes)} routes x {len(widths)} widths x {len(langs)} languages)")
            for name, why in red:
                print(f"RED {name}: {why}")
            json.dump({"clean": clean, "want": want, "red": red}, open(os.path.join(a.out, "walk.json"), "w"), indent=1)
            if red or clean != want:
                sys.exit(1)
            print("WALK GREEN")
            return
        # the control: each fault, on one screen at one width, must be caught for its own reason only
        caught, missed = 0, []
        base_clean, base_red = walk(p, a.base, [390], ["ar"], ["/console"], a.out)
        if base_red or base_clean != 1:
            print(f"CONTROL BROKEN: the screen the faults go into is not clean to start with: {base_red}")
            sys.exit(1)
        for kind, (script, words) in CONTROL_FAULTS.items():
            _, red = walk(p, a.base, [390], ["ar"], ["/console"], a.out, inject=script)
            reasons = [why for _, why in red]
            if any(words in r for r in reasons) and all(words in r for r in reasons):
                caught += 1; print(f"caught: {kind} ({words})")
            else:
                missed.append((kind, reasons)); print(f"MISSED: {kind}: {reasons}")
        # a document that does not draw: the credit note's mark is asked for on a screen that lacks it
        _, red = walk(p, a.base, [390], ["ar"], ["/console/credit-note/1"], a.out, mark_override={"/console/credit-note/1": "[data-credit-note='999']"})
        reasons = [why for _, why in red]
        if reasons and all("mark of its content" in r for r in reasons):
            caught += 1; print("caught: undrawn document (mark of its content)")
        else:
            missed.append(("undrawn", reasons)); print(f"MISSED: undrawn: {reasons}")
        total = len(CONTROL_FAULTS) + 1
        print(f"count: {caught} of {total} injected faults caught")
        if missed or caught != total:
            sys.exit(1)
        print("WALK CONTROL GREEN")


if __name__ == "__main__":
    main()
