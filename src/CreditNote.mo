/// CreditNote.mo - a credit note against an issued invoice, a refund paid at the desk when the gateway
/// would not make it, and the codes the tax authority's documents need.
///
/// AN INVOICE IS NEVER CHANGED. Once a bill is invoiced nothing goes on it or comes off it (Bill.mo),
/// except by a credit note: a document of its own, numbered in a run of its own with no gap (CN-1,
/// CN-2, …), naming the invoice it amends. Its lines are credit lines on the invoiced bill, one for each
/// line taken back and one for each of that line's taxes, and every one of them is recorded against
/// the line it takes back (`creditLine`), so no line is ever taken back beyond its amount. The invoice
/// row keeps the figures it was issued with; the oracle's law is that the bill's credits are the
/// invoice's credits plus its notes' totals (Oracle, I11).
///
/// A CREDIT NOTE NEEDS FOUR EYES (Staff, `issueCreditNote`): one member of staff proposes it, another
/// approves it, and it is checked whole at both. What it names is the amount taken back of each line
/// before tax; each of that line's taxes on the same bill is taken back in proportion, cumulatively,
/// so the notes that take back the whole of a line take back exactly the whole of its taxes:
///
///     taken back of a tax line = halfEven(tax × (taken back of its line so far) / line) − already taken back
///
/// THE MONEY GOES BACK THROUGH THE BILL'S OWN CARD. The note credits the bill and `Reservations.settle`
/// refunds whatever the bill is then paid beyond what it owes, through the card that paid it, as every
/// other credit does. If the gateway refuses that refund (three attempts, then `failed`), the credit
/// note still stands, and the refund is recorded as paid at the desk, in cash or by transfer with its
/// reference, under the same four eyes (Staff, `refundAtDesk`). The refund was committed when it was
/// written, so the cash law (I5) is unchanged by the desk: the desk row says how the money left.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import List "mo:core/List";
import Nat "mo:core/Nat";
import Text "mo:core/Text";

import RowStore "mo:kernel/rows/RowStore";

import Cmd "Command";
import E "Enums";
import Q "Quote";
import R "Rows";
import Res "Reservations";
import Rf "Refusal";
import St "Store";
import TA "TextArena";
import Win "Windows";

module {

  public type Out = { #ok : [Nat]; #err : Rf.Refusal };

  /// The code of a credit line written by a credit note (a void's is Bill.VOID_CODE, 1; other credits 0).
  public let CREDIT_NOTE_CODE : Nat = 2;
  /// The most lines one note names. With each line's taxes (at most `St.MAX_TAX_RULES`) a note writes at
  /// most 16 × 9 = 144 credit lines, inside the one byte its row counts them in.
  public let MAX_NOTE_LINES : Nat = 16;
  public let MAX_REFERENCE : Nat = 64;
  public let MAX_ETA_TEXT : Nat = 200;

  /// One credit line a note will write: the line it takes back, how much, and whether that is a tax.
  public type Item = { source : Nat; amount : Nat; tax : Bool };
  /// A note checked whole: the bill it credits and every line it will write, in order.
  public type Plan = { invoice : Nat; payerId : Nat; items : [Item]; net : Nat; taxes : Nat };

  /// The lines a credit note can take back: what the guest was charged for. A tax is taken back with
  /// its line, a credit is not a charge, and an adjustment is the hotel's own correction.
  public func reversible(k : E.FolioKind) : Bool { switch k { case (#roomNight or #extra or #penalty) true; case _ false } };
  public func isTax(k : E.FolioKind) : Bool { switch k { case (#tax or #extraTax) true; case _ false } };

  /// The tax lines of a line. An extra's are the `taxLines` lines that follow it (Bill.post). A room
  /// night's are the tax lines of the same night that follow it: a stay's lines are written in one
  /// command, each night's room charge and then that night's taxes (Reservations.quoteLines), so the
  /// run is consecutive and ends at the next night's room charge.
  public func taxLinesOf(c : St.Ctx, id : Nat, l : R.FolioLine) : [(Nat, R.FolioLine)] {
    let out = List.empty<(Nat, R.FolioLine)>();
    switch (l.kind) {
      case (#extra) {
        let n = switch (St.charge(c.x, id)) { case (?ch) ch.taxLines; case null 0 };
        for (t in Nat.range(id + 1, id + n + 1)) { switch (St.folioLine(c.s, t)) { case (?tl) List.add(out, (t, tl)); case null {} } };
      };
      case (#roomNight) {
        var t = id + 1;
        label run loop {
          switch (St.folioLine(c.s, t)) {
            case (?tl) { if (tl.kind == #tax and tl.bookingId == l.bookingId and tl.night == l.night) { List.add(out, (t, tl)); t += 1 } else break run };
            case null break run;
          };
        };
      };
      case _ {};
    };
    List.toArray(out)
  };

  /// Every check a credit note makes, at its proposal and again at its approval; the plan it would write.
  public func check(c : St.Ctx, bookingId : Nat, invoice : Nat, lineIds : [Nat], amounts : [Nat]) : { #ok : Plan; #err : Rf.Refusal } {
    let ?inv = St.invoice(c.x, invoice) else return #err(#noSuchInvoice({ number = invoice }));
    if (inv.bookingId != bookingId) return #err(#noSuchInvoice({ number = invoice }));
    let ?_ = St.booking(c.s, bookingId) else return #err(#noSuchBooking({ id = bookingId }));
    if (lineIds.size() == 0 or lineIds.size() > MAX_NOTE_LINES) return #err(#invalid({ what = "A credit note names 1 to " # Nat.toText(MAX_NOTE_LINES) # " lines." }));
    if (lineIds.size() != amounts.size()) return #err(#invalid({ what = "Each line a credit note names needs its amount." }));
    let items = List.empty<Item>();
    var net = 0;
    var taxes = 0;
    var i = 0;
    while (i < lineIds.size()) {
      let id = lineIds[i];
      let amount = amounts[i];
      var j = 0;
      while (j < i) { if (lineIds[j] == id) return #err(#invalid({ what = "Line " # Nat.toText(id) # " is named twice." })); j += 1 };
      let ?l = St.folioLine(c.s, id) else return #err(#otherBill({ lineId = id; invoice }));
      if (l.bookingId != bookingId or St.lineWindow(c.x, id) != inv.payerId) return #err(#otherBill({ lineId = id; invoice }));
      if (not reversible(l.kind)) return #err(#invalid({ what = "Line " # Nat.toText(id) # " is a " # E.folioKindText(l.kind) # "; a credit note takes back a room night, an extra or a penalty, with its taxes." }));
      switch (St.charge(c.x, id)) { case (?ch) { if (ch.voidLine != 0) return #err(#invalid({ what = "Line " # Nat.toText(id) # " is voided." })) }; case null {} };
      if (amount == 0) return #err(#invalid({ what = "Take back more than nothing of line " # Nat.toText(id) # "." }));
      let before = St.creditedOf(c.s, c.x, id);
      let left : Nat = if (l.amount > before) l.amount - before else 0;
      if (amount > left) return #err(#creditBeyondLine({ lineId = id; left }));
      List.add(items, { source = id; amount; tax = false });
      net += amount;
      // its taxes on the same bill, in proportion to what has now been taken back of it
      for ((t, tl) in taxLinesOf(c, id, l).vals()) {
        if (St.lineWindow(c.x, t) == inv.payerId) {
          let target = Q.divHalfEven(tl.amount * (before + amount), l.amount);
          let already = St.creditedOf(c.s, c.x, t);
          if (target > already) { let back : Nat = target - already; List.add(items, { source = t; amount = back; tax = true }); taxes += back };
        };
      };
      i += 1;
    };
    // a bill already credited by other means (a stay shortened in house) owes less than its lines say:
    // a note takes back no more than the bill is charged for
    let ?w = Win.of(c.s, c.x, bookingId, inv.payerId) else return #err(#noSuchPayer({ id = inv.payerId }));
    if (net + taxes > Win.liability(w)) return #err(#invalid({ what = "The bill is charged " # Nat.toText(Win.liability(w)) # " after its credits; this note would take back " # Nat.toText(net + taxes) # "." }));
    #ok({ invoice; payerId = inv.payerId; items = List.toArray(items); net; taxes })
  };

  /// Runs only from an approved proposal (Staff.execute), which has checked it twice.
  public func issue(c : St.Ctx, bookingId : Nat, invoice : Nat, lineIds : [Nat], amounts : [Nat], proposal : Nat) : Out {
    let plan = switch (check(c, bookingId, invoice, lineIds, amounts)) { case (#ok p) p; case (#err r) return #err(r) };
    let ?b = St.booking(c.s, bookingId) else return #err(#noSuchBooking({ id = bookingId }));
    // ── every check is above this line; nothing below can refuse ──
    let notes = St.later(c.x, St.CREDIT_NOTE_TABLE);
    let lines = St.later(c.x, St.CREDIT_LINE_TABLE);
    let number = RowStore.size(notes) + 1;
    let first = c.s.nextFolioId;
    for (it in plan.items.vals()) {
      let id = Res.addLine(c, bookingId, #credit, CREDIT_NOTE_CODE, c.day, it.amount);
      Res.routeLine(c, id, plan.payerId);
      RowStore.put<R.CreditLine>(lines, R.creditLine, id, { note = number; source = it.source; lastBlock = c.block });
    };
    let total = plan.net + plan.taxes;
    RowStore.put<R.CreditNote>(notes, R.creditNote, number, {
      invoice; bookingId; payerId = plan.payerId; issuedDay = c.day; net = plan.net; taxes = plan.taxes; total;
      firstLine = first; lines = plan.items.size(); proposal; lastBlock = c.block;
    });
    Res.putBooking(c, bookingId, Res.settle(c, bookingId, { b with credited = b.credited + total }, false));
    #ok([number, total])
  };

  // ── a refund paid at the desk ───────────────────────────────────────────────

  public func checkDeskRefund(c : St.Ctx, bookingId : Nat, paymentId : Nat, reference : Text) : ?Rf.Refusal {
    let ?p = St.payment(c.s, paymentId) else return ?#noSuchPayment({ id = paymentId });
    if (p.bookingId != bookingId) return ?#noSuchPayment({ id = paymentId });
    if (p.kind != #refunded) return ?#invalid({ what = "Payment " # Nat.toText(paymentId) # " is not a refund." });
    if (p.state != #failed) return ?#invalid({ what = "Refund " # Nat.toText(paymentId) # " is " # E.paymentStateText(p.state) # "; only a refund the gateway would not make is paid at the desk." });
    if (St.deskRefund(c.x, paymentId) != null) return ?#invalid({ what = "Refund " # Nat.toText(paymentId) # " was already paid at the desk." });
    let n = Text.encodeUtf8(reference).size();
    if (n == 0) return ?#invalid({ what = "Give the receipt number or the transfer reference." });
    if (n > MAX_REFERENCE) return ?#tooLong({ what = "reference"; max = MAX_REFERENCE });
    switch (TA.fits(c.s.arena, [reference], MAX_REFERENCE)) { case (?why) return ?#invalid({ what = why }); case null {} };
    null
  };

  /// Runs only from an approved proposal (Staff.execute).
  public func refundAtDesk(c : St.Ctx, bookingId : Nat, paymentId : Nat, method : E.DeskMethod, reference : Text, proposal : Nat) : Out {
    switch (checkDeskRefund(c, bookingId, paymentId, reference)) { case (?r) return #err(r); case null {} };
    // ── every check is above this line; nothing below can refuse ──
    RowStore.put<R.DeskRefund>(St.later(c.x, St.DESK_REFUND_TABLE), R.deskRefund, paymentId,
      { bookingId; method; reference = TA.put(c.s.arena, reference); day = c.day; proposal; lastBlock = c.block });
    #ok([paymentId])
  };

  // ── the tax authority's codes ───────────────────────────────────────────────

  /// A code of the authority's tables: 1 to 8 ASCII letters and digits.
  func etaCode(t : Text) : Bool {
    let b = Text.encodeUtf8(t);
    if (b.size() == 0 or b.size() > 8) return false;
    for (x in b.vals()) { if (not ((x >= 48 and x <= 57) or (x >= 65 and x <= 90) or (x >= 97 and x <= 122))) return false };
    true
  };

  /// A tax rule's tax type (T1 for VAT) and sub-type (V009 and so on), as the hotel's registration with the
  /// authority lists them.
  public func setTaxEta(c : St.Ctx, taxRuleId : Nat, taxType : Text, subType : Text) : Out {
    let ?_ = RowStore.get<R.TaxRule>(c.s.taxes, R.taxRule, taxRuleId) else return #err(#noSuchTaxRule({ id = taxRuleId }));
    if (not etaCode(taxType) or not etaCode(subType)) return #err(#invalid({ what = "A tax type and its sub-type are 1 to 8 letters and digits, as the authority's tables write them." }));
    // ── every check is above this line; nothing below can refuse ──
    RowStore.put<R.TaxEta>(St.later(c.x, St.TAX_ETA_TABLE), R.taxEta, taxRuleId, { taxType; subType; lastBlock = c.block });
    #ok([taxRuleId])
  };

  public func setEtaProfile(c : St.Ctx, f : Cmd.EtaProfileFacts) : Out {
    let ib = Text.encodeUtf8(f.issuerId);
    if (ib.size() == 0 or ib.size() > 32) return #err(#invalid({ what = "The registration number is 1 to 32 letters and digits." }));
    for (x in ib.vals()) { if (not ((x >= 48 and x <= 57) or (x >= 65 and x <= 90) or (x >= 97 and x <= 122))) return #err(#invalid({ what = "The registration number is 1 to 32 letters and digits." })) };
    let ab = Text.encodeUtf8(f.activityCode);
    if (ab.size() != 4) return #err(#invalid({ what = "The activity code is the four digits the authority registered." }));
    for (x in ab.vals()) { if (x < 48 or x > 57) return #err(#invalid({ what = "The activity code is the four digits the authority registered." })) };
    if (not etaCode(f.branchId)) return #err(#invalid({ what = "The branch is the code the authority registered (0 for the main one)." }));
    let cb = Text.encodeUtf8(f.country);
    if (cb.size() != 2) return #err(#invalid({ what = "The country is its two-letter code, such as EG." }));
    for (x in cb.vals()) { if (x < 65 or x > 90) return #err(#invalid({ what = "The country is its two-letter code, such as EG." })) };
    let texts = [f.governate, f.regionCity, f.street, f.buildingNumber];
    for (t in texts.vals()) {
      let n = Text.encodeUtf8(t).size();
      if (n == 0) return #err(#invalid({ what = "The address needs its governorate, city, street and building number." }));
      if (n > MAX_ETA_TEXT) return #err(#tooLong({ what = "address"; max = MAX_ETA_TEXT }));
    };
    switch (TA.fits(c.s.arena, [f.issuerId, f.branchId, f.governate, f.regionCity, f.street, f.buildingNumber], MAX_ETA_TEXT)) { case (?why) return #err(#invalid({ what = why })); case null {} };
    // ── every check is above this line; nothing below can refuse ──
    RowStore.put<R.EtaProfile>(St.later(c.x, St.ETA_PROFILE_TABLE), R.etaProfile, St.ETA_PROFILE_ID, {
      issuerId = TA.put(c.s.arena, f.issuerId); activityCode = f.activityCode; branchId = TA.put(c.s.arena, f.branchId); country = f.country;
      governate = TA.put(c.s.arena, f.governate); regionCity = TA.put(c.s.arena, f.regionCity); street = TA.put(c.s.arena, f.street);
      buildingNumber = TA.put(c.s.arena, f.buildingNumber); lastBlock = c.block;
    });
    #ok([St.ETA_PROFILE_ID])
  };
}
