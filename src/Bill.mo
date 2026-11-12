/// Bill.mo - the hotel's extras, posted to a guest in house, and the bill split by who pays.
///
/// EXTRAS ARE FOLIO LINES. An extra posted (restaurant, minibar, spa, parking, breakfast) is a folio
/// line of kind `extra` with its taxes as lines of kind `extraTax`, so the booking's money identity
/// (I4: charged = paid + credited + outstanding, each the sum of its own lines and payments) holds
/// for them with no second set of books, and the independent reader sums them with the room. The
/// hotel's percentage taxes apply to a taxed extra in rank order, compound as for the room, each
/// rounded half-even once (Quote.divHalfEven).
///
/// A CHARGE IS CORRECTED BY FOUR EYES. A posted charge is never edited: it is voided by a credit line
/// of the same amount, its taxes with it, proposed by one member of staff and approved by another
/// (Staff, `voidCharge`). A wrong amount is a void and a new charge.
///
/// THE BILL HAS WINDOWS (Windows.mo). A payer added to a booking has a window; lines are moved into it
/// and the payer pays its share at the desk on the TEST gateway. A move that would leave a window paid
/// for more than it owes is refused, so moving lines never sends money back. An invoice closes a
/// window, under the next number of an unbroken sequence: its figures are the window's at that
/// moment, and nothing is posted to it, moved in or out, or voided on it afterwards.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
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
import W "Widths";
import Win "Windows";

module {

  public type Out = { #ok : [Nat]; #err : Rf.Refusal };

  public let MAX_EXTRAS : Nat = 500;
  public let MAX_QUANTITY : Nat = 99;
  public let MAX_PAYERS : Nat = 7;
  public let MAX_PAYER_NAME : Nat = 80;
  public let MAX_ROUTE_LINES : Nat = 64;
  /// The code of a credit line that voids a charge (other credits have code 0).
  public let VOID_CODE : Nat = 1;
  let MONEY_LIMIT : Nat = 9_223_372_036_854_775_808;   // 2^63: every figure stays below it

  func sub(a : Nat, b : Nat) : Nat { if (a > b) a - b else 0 };

  // ── the catalogue ───────────────────────────────────────────────────────────

  public func upsertExtra(c : St.Ctx, id : Nat, f : Cmd.ExtraFacts) : Out {
    let table = St.later(c.x, St.EXTRA_TABLE);
    let n = Text.encodeUtf8(f.code).size();
    if (n == 0) return #err(#invalid({ what = "An extra needs a code." }));
    if (n > W.CODE) return #err(#tooLong({ what = "code"; max = W.CODE }));
    let target = if (id == 0) RowStore.size(table) + 1 else id;
    if (id == 0 and RowStore.size(table) >= MAX_EXTRAS) return #err(#invalid({ what = "A hotel has at most " # Nat.toText(MAX_EXTRAS) # " extras." }));
    if (id != 0 and St.extra(c.x, id) == null) return #err(#noSuchExtra({ id }));
    let k = R.codeKey(f.code);
    switch (RowStore.page<R.Extra>(table, R.extra, "by_code", k, k, null, 1)) {
      case (#ok p) { if (p.rows.size() > 0 and p.rows[0].0 != target) return #err(#codeTaken({ code = f.code; id = p.rows[0].0 })) };
      case (#err _) {};
    };
    for (t in [f.nameEn, f.nameAr].vals()) {
      if (Text.encodeUtf8(t).size() > 200) return #err(#tooLong({ what = "name"; max = 200 }));
    };
    if (Text.encodeUtf8(f.nameEn).size() == 0) return #err(#invalid({ what = "An extra needs a name." }));
    if (f.price >= MONEY_LIMIT) return #err(#invalid({ what = "The price is past the largest amount." }));
    switch (TA.fits(c.s.arena, [f.nameEn, f.nameAr], 200)) { case (?why) return #err(#invalid({ what = why })); case null {} };
    // ── every check is above this line; nothing below can refuse ──
    RowStore.put<R.Extra>(table, R.extra, target, {
      code = f.code; nameEn = TA.put(c.s.arena, f.nameEn); nameAr = TA.put(c.s.arena, f.nameAr); category = f.category;
      price = f.price; taxed = f.taxed; active = f.active; lastBlock = c.block;
    });
    #ok([target])
  };

  /// The hotel's percentage taxes on an amount, in rank order, compound as for the room: each
  /// (rule, amount) above zero.
  public func taxesOn(s : St.Stores, net : Nat) : [(Nat, Nat)] { Q.percentTaxesOn(St.taxes(s), net) };

  func payerOk(c : St.Ctx, bookingId : Nat, payerId : Nat) : ?Rf.Refusal {
    if (payerId == 0) return null;
    switch (St.payer(c.x, payerId)) { case (?p) { if (p.bookingId == bookingId) null else ?#noSuchPayer({ id = payerId }) }; case null ?#noSuchPayer({ id = payerId }) }
  };

  // ── posting a charge ────────────────────────────────────────────────────────

  public func post(c : St.Ctx, staff : Principal, bookingId : Nat, extraId : Nat, quantity : Nat, amount : Nat, payerId : Nat) : Out {
    let ?b = St.booking(c.s, bookingId) else return #err(#noSuchBooking({ id = bookingId }));
    if (b.status != #checkedIn) return #err(#bookingState({ id = bookingId; state = E.bookingStatusText(b.status); wanted = "checked in" }));
    let ?e = St.extra(c.x, extraId) else return #err(#noSuchExtra({ id = extraId }));
    if (not e.active) return #err(#inactive({ what = "extra"; id = extraId }));
    if (quantity == 0 or quantity > MAX_QUANTITY) return #err(#invalid({ what = "A quantity is 1 to " # Nat.toText(MAX_QUANTITY) # "." }));
    let unit = if (e.price > 0) {
      if (amount != 0 and amount != e.price) return #err(#invalid({ what = "This extra has a set price of " # Nat.toText(e.price) # "." }));
      e.price
    } else {
      if (amount == 0) return #err(#invalid({ what = "Enter the amount of this charge." }));
      amount
    };
    if (unit >= MONEY_LIMIT / MAX_QUANTITY) return #err(#invalid({ what = "The amount is past the largest a charge can be." }));
    switch (payerOk(c, bookingId, payerId)) { case (?r) return #err(r); case null {} };
    if (Win.invoiced(c.x, bookingId, payerId)) return #err(#invoiced({ bookingId; payerId }));
    let net = unit * quantity;
    let taxes = if (e.taxed) taxesOn(c.s, net) else [];
    var total = net;
    for ((_, t) in taxes.vals()) total += t;

    // ── every check is above this line; nothing below can refuse ──
    let lineId = Res.addLine(c, bookingId, #extra, Nat8.toNat(E.extraCategoryByte(e.category)), c.day, net);
    Res.routeLine(c, lineId, payerId);
    for ((rule, t) in taxes.vals()) Res.routeLine(c, Res.addLine(c, bookingId, #extraTax, rule, c.day, t), payerId);
    RowStore.put<R.Charge>(St.later(c.x, St.CHARGE_TABLE), R.charge, lineId,
      { bookingId; extraId; quantity; unitAmount = unit; taxLines = taxes.size(); postedBy = staff; voidLine = 0; lastBlock = c.block });
    Res.putBooking(c, bookingId, Res.settle(c, bookingId, { b with charged = b.charged + total }, false));
    #ok([lineId, total])
  };

  /// What voiding a charge credits: the charge and its taxes. The checks a proposal and its approval
  /// both make.
  public func checkVoid(c : St.Ctx, bookingId : Nat, lineId : Nat) : { #ok : (R.Charge, Nat, Nat); #err : Rf.Refusal } {
    let ?ch = St.charge(c.x, lineId) else return #err(#noSuchCharge({ lineId }));
    if (ch.bookingId != bookingId) return #err(#noSuchCharge({ lineId }));
    if (ch.voidLine != 0) return #err(#invalid({ what = "This charge is already voided." }));
    // a package's inclusion is part of the rate: it changes with the stay, and is credited, not voided
    if (St.packageLine(c.x, lineId) != null) return #err(#invalid({ what = "This is part of the guest's package: change the stay, or credit the booking." }));
    let window = St.lineWindow(c.x, lineId);
    if (Win.invoiced(c.x, bookingId, window)) return #err(#invoiced({ bookingId; payerId = window }));
    var amount = 0;
    for (i in Nat.range(lineId, lineId + ch.taxLines + 1)) {
      switch (St.folioLine(c.s, i)) { case (?l) amount += l.amount; case null {} };
    };
    #ok((ch, amount, window))
  };

  /// Runs only from an approved proposal (Staff.execute), which has checked it twice.
  public func voidCharge(c : St.Ctx, bookingId : Nat, lineId : Nat) : Out {
    let ?b = St.booking(c.s, bookingId) else return #err(#noSuchBooking({ id = bookingId }));
    let (ch, amount, window) = switch (checkVoid(c, bookingId, lineId)) { case (#ok x) x; case (#err r) return #err(r) };
    // ── every check is above this line; nothing below can refuse ──
    let credit = Res.addLine(c, bookingId, #credit, VOID_CODE, c.day, amount);
    Res.routeLine(c, credit, window);
    RowStore.put<R.Charge>(St.later(c.x, St.CHARGE_TABLE), R.charge, lineId, { ch with voidLine = credit; lastBlock = c.block });
    Res.putBooking(c, bookingId, Res.settle(c, bookingId, { b with credited = b.credited + amount }, false));
    #ok([credit, amount])
  };

  // ── payers ──────────────────────────────────────────────────────────────────

  public func addPayer(c : St.Ctx, bookingId : Nat, name : Text) : Out {
    let ?b = St.booking(c.s, bookingId) else return #err(#noSuchBooking({ id = bookingId }));
    if (b.status != #confirmed and b.status != #checkedIn) return #err(#bookingState({ id = bookingId; state = E.bookingStatusText(b.status); wanted = "confirmed or checked in" }));
    let n = Text.encodeUtf8(name).size();
    if (n == 0) return #err(#invalid({ what = "Name who pays." }));
    if (n > MAX_PAYER_NAME) return #err(#tooLong({ what = "payer name"; max = MAX_PAYER_NAME }));
    if (St.payersOf(c.x, bookingId).size() >= MAX_PAYERS) return #err(#invalid({ what = "A bill has at most " # Nat.toText(MAX_PAYERS) # " payers besides the guest." }));
    switch (TA.fits(c.s.arena, [name], MAX_PAYER_NAME)) { case (?why) return #err(#invalid({ what = why })); case null {} };
    // ── every check is above this line; nothing below can refuse ──
    let table = St.later(c.x, St.PAYER_TABLE);
    let id = RowStore.size(table) + 1;
    RowStore.put<R.Payer>(table, R.payer, id, { bookingId; name = TA.put(c.s.arena, name); lastBlock = c.block });
    #ok([id])
  };

  /// Move lines to a window. A charge's taxes move with it; a tax line of an extra is never moved alone.
  public func routeLines(c : St.Ctx, bookingId : Nat, lineIds : [Nat], payerId : Nat) : Out {
    let ?b = St.booking(c.s, bookingId) else return #err(#noSuchBooking({ id = bookingId }));
    if (b.status != #confirmed and b.status != #checkedIn) return #err(#bookingState({ id = bookingId; state = E.bookingStatusText(b.status); wanted = "confirmed or checked in" }));
    if (lineIds.size() == 0 or lineIds.size() > MAX_ROUTE_LINES) return #err(#invalid({ what = "Move 1 to " # Nat.toText(MAX_ROUTE_LINES) # " lines at a time." }));
    switch (payerOk(c, bookingId, payerId)) { case (?r) return #err(r); case null {} };
    if (Win.invoiced(c.x, bookingId, payerId)) return #err(#invoiced({ bookingId; payerId }));
    let moving = List.empty<(Nat, R.FolioLine, Nat)>();   // line id, line, the window it leaves
    func seen(id : Nat) : Bool { List.any<(Nat, R.FolioLine, Nat)>(moving, func((x, _, _)) { x == id }) };
    for (id in lineIds.vals()) {
      if (seen(id)) return #err(#invalid({ what = "Line " # Nat.toText(id) # " is listed twice." }));
      let ?l = St.folioLine(c.s, id) else return #err(#invalid({ what = "There is no line " # Nat.toText(id) # " on this booking." }));
      if (l.bookingId != bookingId) return #err(#invalid({ what = "There is no line " # Nat.toText(id) # " on this booking." }));
      if (l.kind == #extraTax) return #err(#invalid({ what = "A tax on an extra moves with the extra." }));
      let from = St.lineWindow(c.x, id);
      if (from == payerId) return #err(#invalid({ what = "Line " # Nat.toText(id) # " is already on that bill." }));
      if (Win.invoiced(c.x, bookingId, from)) return #err(#invoiced({ bookingId; payerId = from }));
      List.add(moving, (id, l, from));
      switch (St.charge(c.x, id)) {
        case (?ch) {
          for (t in Nat.range(id + 1, id + ch.taxLines + 1)) {
            switch (St.folioLine(c.s, t)) { case (?tl) List.add(moving, (t, tl, from)); case null {} };
          };
        };
        case null {};
      };
    };
    // the windows as they would be: no window may end up paid for more than it owes
    for (w in Win.all(c.s, c.x, bookingId).vals()) {
      var charges = w.charges; var credits = w.credits;
      for ((_, l, from) in List.values(moving)) {
        let into = if (w.payerId == payerId) 1 else 0;
        let outOf = if (w.payerId == from) 1 else 0;
        if (E.isCredit(l.kind)) { credits := credits + into * l.amount; credits := sub(credits, outOf * l.amount) }
        else { charges := charges + into * l.amount; charges := sub(charges, outOf * l.amount) };
      };
      if (w.paid + w.due > sub(charges, credits)) {
        return #err(#invalid({ what = "That bill has paid " # Nat.toText(w.paid + w.due) # "; after the move it would owe only " # Nat.toText(sub(charges, credits)) # ". Paid lines stay where they were paid." }));
      };
    };
    // ── every check is above this line; nothing below can refuse ──
    for ((id, _, _) in List.values(moving)) Res.routeLine(c, id, payerId);
    Res.putBooking(c, bookingId, Res.settle(c, bookingId, b, false));
    #ok([List.size(moving)])
  };

  /// A payer's share, paid at the desk: a TEST gateway authorisation for exactly what is open in their
  /// window, against the booking's reference. The guest's own window is `settleAtDesk`.
  public func settleShare(c : St.Ctx, bookingId : Nat, payerId : Nat, a : Cmd.AuthFacts) : Out {
    let ?prop = St.property(c.s) else return #err(#notConfigured);
    let ?b = St.booking(c.s, bookingId) else return #err(#noSuchBooking({ id = bookingId }));
    if (b.status != #checkedIn and b.status != #confirmed) return #err(#bookingState({ id = bookingId; state = E.bookingStatusText(b.status); wanted = "confirmed or checked in" }));
    if (payerId == 0) return #err(#invalid({ what = "The guest's own share is taken with the guest's payment at the desk." }));
    switch (payerOk(c, bookingId, payerId)) { case (?r) return #err(r); case null {} };
    let ?w = Win.of(c.s, c.x, bookingId, payerId) else return #err(#noSuchPayer({ id = payerId }));
    let open = Win.open(w);
    if (open == 0) return #err(#invalid({ what = "Nothing is left to pay on this bill." }));
    switch (Res.checkAuth(c, prop, a, St.BOOKING_REF_BASE + bookingId, open)) { case (?r) return #err(r); case null {} };
    // ── every check is above this line; nothing below can refuse ──
    Res.routePayment(c, Res.addPayment(c, bookingId, a.authId, #authorised, a.amount, #done), payerId);
    let pid = Res.addPayment(c, bookingId, a.authId, #captured, a.amount, #due);
    Res.routePayment(c, pid, payerId);
    #ok([bookingId, pid])
  };

  // ── invoices ────────────────────────────────────────────────────────────────

  public func issueInvoice(c : St.Ctx, staff : Principal, bookingId : Nat, payerId : Nat) : Out {
    let ?b = St.booking(c.s, bookingId) else return #err(#noSuchBooking({ id = bookingId }));
    if (b.status != #checkedIn and b.status != #checkedOut) return #err(#bookingState({ id = bookingId; state = E.bookingStatusText(b.status); wanted = "checked in or checked out" }));
    switch (payerOk(c, bookingId, payerId)) { case (?r) return #err(r); case null {} };
    switch (St.invoiceOf(c.x, bookingId, payerId)) { case (?(n, _)) return #err(#invalid({ what = "This bill is already invoice " # Nat.toText(n) # "." })); case null {} };
    let ?w = Win.of(c.s, c.x, bookingId, payerId) else return #err(#noSuchPayer({ id = payerId }));
    if (w.lines == 0) return #err(#invalid({ what = "There is nothing on this bill to invoice." }));
    // ── every check is above this line; nothing below can refuse ──
    let table = St.later(c.x, St.INVOICE_TABLE);
    let number = RowStore.size(table) + 1;
    RowStore.put<R.Invoice>(table, R.invoice, number, {
      bookingId; payerId; issuedDay = c.day; charges = w.charges; credits = w.credits; taxes = w.taxes; paid = w.paid; issuedBy = staff; lastBlock = c.block;
    });
    #ok([number])
  };

  /// The lines of a window, for the bill and the invoice: id, line, and whether it is a voided charge
  /// or the credit that voided one (both are left off a printed invoice, as they net to nothing).
  public func linesOf(s : St.Stores, x : St.Later, bookingId : Nat, payerId : Nat) : [(Nat, R.FolioLine, Bool)] {
    let voided = List.empty<Nat>();
    for ((id, _) in St.folioOf(s, bookingId).vals()) {
      switch (St.charge(x, id)) {
        case (?ch) { if (ch.voidLine != 0) { for (i in Nat.range(id, id + ch.taxLines + 1)) List.add(voided, i); List.add(voided, ch.voidLine) } };
        case null {};
      };
    };
    let out = List.empty<(Nat, R.FolioLine, Bool)>();
    for ((id, l) in St.folioOf(s, bookingId).vals()) {
      if (St.lineWindow(x, id) == payerId) List.add(out, (id, l, List.contains<Nat>(voided, Nat.equal, id)));
    };
    List.toArray(out)
  };
}
