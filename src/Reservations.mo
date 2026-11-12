/// Reservations.mo - holds, bookings, the waitlist, the front desk, and the money each one moves.
///
/// EVERY CHECK BEFORE ANY WRITE. Each act reads what it needs, decides, and only then writes; after
/// the first write nothing can refuse. A night's counters are changed through a pending set that is
/// read through and flushed once, so an act that touches the same night twice (a modification whose
/// old and new stays overlap) nets its changes and writes each row once.
///
/// THE MONEY LAW OF A BOOKING. `charged` is every charge line, `credited` every credit line, `paid`
/// what the gateway has captured less what has been committed back, and
/// `outstanding = charged − credited − paid`, never negative. Whenever a booking's liability moves,
/// `settle` brings the payments into line in the same step: money held above the liability is
/// committed back as a refund at once (so `paid` falls with the liability), and money owed below it
/// is captured against the guarantee authorisation where the authorisation still covers it.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Principal "mo:core/Principal";
import Text "mo:core/Text";

import Batch "mo:kernel/batch/Batch";
import BatchCore "mo:kernel/batch/BatchCore";
import RowStore "mo:kernel/rows/RowStore";
import SR "mo:kernel/rows/StableRows";

import Acc "Access";
import Blocks "Blocks";
import Cmd "Command";
import E "Enums";
import Hk "Housekeeping";
import Mail "Mail";
import Win "Windows";
import Q "Quote";
import R "Rows";
import Rf "Refusal";
import St "Store";
import TA "TextArena";
import W "Widths";

module {

  public type Out = { #ok : [Nat]; #err : Rf.Refusal };

  public let MAX_NAME_BYTES : Nat = 120;
  public let MAX_EMAIL_ENVELOPE_BYTES : Nat = 2_048;
  public let MAX_NOTE_BYTES : Nat = 500;
  public let RELEASE_LIMIT : Nat = 64;
  public let GATEWAY_ATTEMPTS : Nat = 3;
  /// A waitlist offer is held for an account, whose passkey session proves it; it has no browser key.
  public let NO_KEY : Blob = "\02\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00";

  // ── pending nights ──────────────────────────────────────────────────────────

  public type Pending = Map.Map<Nat, R.Night>;

  public func newPending() : Pending { Map.empty<Nat, R.Night>() };

  public func readThrough(s : St.Stores, p : Pending, rt : Nat, from : Nat, to : Nat) : [?R.Night] {
    let base = St.nightsRange(s, rt, from, to);
    Array.tabulate<?R.Night>(base.size(), func(i) {
      switch (Map.get(p, Nat.compare, R.nightId(rt, from + i))) { case (?n) ?n; case null base[i] }
    })
  };

  func adjust(s : St.Stores, p : Pending, rt : Nat, from : Nat, to : Nat, f : R.Night -> R.Night) {
    let rows = readThrough(s, p, rt, from, to);
    var i = 0;
    while (i < rows.size()) {
      switch (rows[i]) { case (?n) Map.add(p, Nat.compare, R.nightId(rt, from + i), f(n)); case null {} };
      i += 1;
    };
  };

  func sub(a : Nat, b : Nat) : Nat { if (a >= b) a - b else 0 };

  public func takeHeld(s : St.Stores, p : Pending, rt : Nat, from : Nat, to : Nat, k : Nat) { adjust(s, p, rt, from, to, func(n) { { n with held = n.held + k } }) };
  public func dropHeld(s : St.Stores, p : Pending, rt : Nat, from : Nat, to : Nat, k : Nat) { adjust(s, p, rt, from, to, func(n) { { n with held = sub(n.held, k) } }) };
  public func takeSold(s : St.Stores, p : Pending, rt : Nat, from : Nat, to : Nat, k : Nat) { adjust(s, p, rt, from, to, func(n) { { n with sold = n.sold + k } }) };
  public func dropSold(s : St.Stores, p : Pending, rt : Nat, from : Nat, to : Nat, k : Nat) { adjust(s, p, rt, from, to, func(n) { { n with sold = sub(n.sold, k) } }) };

  public func flush(c : St.Ctx, p : Pending) {
    for ((id, n) in Map.entries(p)) RowStore.put<R.Night>(c.s.nights, R.night, id, { n with lastBlock = c.block });
  };

  // ── checking a stay ─────────────────────────────────────────────────────────

  /// Rooms a modification gives back on each night of its old stay, so its own rooms count as free.
  public type Credit = { roomTypeId : Nat; arrival : Nat; departure : Nat; rooms : Nat };

  public type Checked = { property : R.Property; roomType : R.RoomType; plan : R.RatePlan; quote : Q.Quote; nights : [R.Night] };

  /// Is this stay sellable right now, and at what price? One range read over the grid returns the
  /// stayed nights and the departure day's row. The first failing night is named.
  public func checkStay(c : St.Ctx, p : Pending, stay : Cmd.Stay, credit : ?Credit, grant : Acc.Grant) : { #ok : Checked; #err : Rf.Refusal } {
    checkStayAs(c, p, stay, credit, grant, false)
  };

  /// `fromBlock`: a pickup from a group block, whose rooms were taken out of sale when the block was
  /// made. Its nights are not asked for free rooms or for the restrictions on rooms on sale (stop-sell,
  /// closed to arrival or departure, minimum and maximum stay); the caller has checked the block holds
  /// them (`Blocks.checkPickup`). Everything else (the plan, its access, the stay's shape, the price)
  /// is asked as for any sale.
  public func checkStayAs(c : St.Ctx, p : Pending, stay : Cmd.Stay, credit : ?Credit, grant : Acc.Grant, fromBlock : Bool) : { #ok : Checked; #err : Rf.Refusal } {
    let s = c.s;
    let ?prop = St.property(s) else return #err(#notConfigured);
    let ?rt = St.roomType(s, stay.roomTypeId) else return #err(#noSuchRoomType({ id = stay.roomTypeId }));
    if (not rt.active) return #err(#inactive({ what = "room type"; id = stay.roomTypeId }));
    let ?plan = St.plan(s, stay.planId) else return #err(#noSuchPlan({ id = stay.planId }));
    if (not plan.active) return #err(#inactive({ what = "rate plan"; id = stay.planId }));
    // a new sale (no credit) meets a promotion's booking window and uses; a change keeps the use it counted
    switch (Acc.admits(c, stay.planId, grant, ?{ arrival = stay.arrival; nights = stay.nights; counts = credit == null })) { case (?r) return #err(r); case null {} };
    if (stay.nights == 0 or stay.nights > prop.maxStayNights) return #err(#stayLength({ nights = stay.nights; max = prop.maxStayNights }));
    if (stay.rooms == 0 or stay.rooms > prop.maxRoomsPerBooking) return #err(#rooms({ rooms = stay.rooms; max = prop.maxRoomsPerBooking }));
    if (stay.adults == 0 or stay.adults > rt.maxAdults * stay.rooms or stay.children > rt.maxChildren * stay.rooms
        or stay.adults + stay.children > rt.maxOccupancy * stay.rooms) {
      return #err(#occupancy({ adults = stay.adults; children = stay.children; roomTypeId = stay.roomTypeId }));
    };
    if (stay.arrival < c.day) return #err(#inThePast({ day = stay.arrival; today = c.day }));
    let departure = stay.arrival + stay.nights;
    let lastDay = c.day + prop.horizonDays;
    if (departure > lastDay) return #err(#beyondHorizon({ day = departure; lastDay }));

    let rows = readThrough(s, p, stay.roomTypeId, stay.arrival, departure + 1);
    let stayed = List.empty<R.Night>();
    var i = 0;
    while (i < stay.nights) {
      let d = stay.arrival + i;
      let ?n = rows[i] else return #err(#nightClosed({ day = d }));
      if (not fromBlock) {
        if (n.stopSell) return #err(#stopSell({ day = d }));
        let back = switch credit {
          case (?cr) { if (cr.roomTypeId == stay.roomTypeId and d >= cr.arrival and d < cr.departure) cr.rooms else 0 };
          case null 0;
        };
        // the rooms open group blocks hold that night are not free
        let free = St.freeOn(c.x, stay.roomTypeId, d, n) + back;
        if (free < stay.rooms) return #err(#soldOut({ day = d; free; wanted = stay.rooms }));
      };
      List.add(stayed, n);
      i += 1;
    };
    let first = List.at(stayed, 0);
    if (not fromBlock) {
      if (first.closedToArrival) return #err(#closedToArrival({ day = stay.arrival }));
      switch (rows[stay.nights]) {
        case (?dep) { if (dep.closedToDeparture) return #err(#closedToDeparture({ day = departure })) };
        case null {};
      };
      let minStay = if (first.minStay == 0) 1 else first.minStay;
      if (stay.nights < minStay) return #err(#minStay({ nights = stay.nights; min = minStay }));
      if (first.maxStay > 0 and stay.nights > first.maxStay) return #err(#maxStay({ nights = stay.nights; max = first.maxStay }));
    };
    let nightsArr = List.toArray(stayed);
    let bars = Array.map<R.Night, Nat>(nightsArr, func(n) { n.bar });
    let incs = switch (packageOf(c, stay.planId, stay.rooms, stay.adults, stay.children)) { case (#ok x) x; case (#err r) return #err(r) };
    let taxes = St.taxes(s);
    let quote = Q.withPackage(Q.price(stay.roomTypeId, stay.planId, plan, stay.arrival, bars, stay.rooms, taxes), incs, taxes, stay.arrival);
    #ok({ property = prop; roomType = rt; plan; quote; nights = nightsArr })
  };

  // ── packages ────────────────────────────────────────────────────────────────

  /// Who posts a package's lines: nobody at the desk. They are sold with the room, so their charge rows
  /// name the anonymous principal, which no member of staff can be.
  public func packagePoster() : Principal { Principal.anonymous() };

  /// A plan's inclusions as a stay of `rooms` rooms, `adults` adults and `children` children takes them,
  /// at each extra's catalogue price now. An included extra off sale, or with no set price, makes the
  /// plan unsellable until the owner mends the package: it is never sold without what it promises.
  public func packageOf(c : St.Ctx, planId : Nat, rooms : Nat, adults : Nat, children : Nat) : { #ok : [Q.IncInput]; #err : Rf.Refusal } {
    let out = List.empty<Q.IncInput>();
    for ((slot, inc) in St.inclusionsOf(c.x, planId).vals()) {
      let ?e = St.extra(c.x, inc.extraId) else return #err(#noSuchExtra({ id = inc.extraId }));
      if (not e.active) return #err(#inactive({ what = "extra"; id = inc.extraId }));
      if (e.price == 0) return #err(#invalid({ what = "An extra in a package needs a set price." }));
      let per = switch (inc.per) { case (#room) rooms; case (#adult) adults; case (#guest) adults + children };
      List.add(out, { slot; extraId = inc.extraId; category = Nat8.toNat(E.extraCategoryByte(e.category)); unit = e.price; quantity = inc.quantity * per;
        rhythm = inc.rhythm; taxed = e.taxed });
    };
    #ok(List.toArray(out))
  };

  /// A booking's package lines still standing (not voided), with their charge, from `from` on.
  public func livePackage(c : St.Ctx, bookingId : Nat, from : Nat) : [(Nat, R.FolioLine, R.PackageLine, R.Charge)] {
    let out = List.empty<(Nat, R.FolioLine, R.PackageLine, R.Charge)>();
    for ((lid, l) in St.folioOf(c.s, bookingId).vals()) {
      if (l.kind == #extra and l.night >= from) {
        switch (St.packageLine(c.x, lid), St.charge(c.x, lid)) {
          case (?pk, ?ch) { if (ch.voidLine == 0) List.add(out, (lid, l, pk, ch)) };
          case _ {};
        };
      };
    };
    List.toArray(out)
  };

  /// What voiding these package lines refuses on: a bill an invoice has closed.
  func packageVoidRefusal(c : St.Ctx, bookingId : Nat, lines : [(Nat, R.FolioLine, R.PackageLine, R.Charge)]) : ?Rf.Refusal {
    for ((lid, _, _, _) in lines.vals()) {
      let w = St.lineWindow(c.x, lid);
      if (Win.invoiced(c.x, bookingId, w)) return ?#invoiced({ bookingId; payerId = w });
    };
    null
  };

  /// Void package lines: each by a credit of the line and its taxes on the line's own bill, as a voided
  /// charge is (I11). Returns what was credited. The caller has made every check.
  func voidPackage(c : St.Ctx, bookingId : Nat, lines : [(Nat, R.FolioLine, R.PackageLine, R.Charge)]) : Nat {
    var credited = 0;
    for ((lid, l, _, ch) in lines.vals()) {
      var total = l.amount;
      for (t in Nat.range(lid + 1, lid + ch.taxLines + 1)) { switch (St.folioLine(c.s, t)) { case (?tl) total += tl.amount; case null {} } };
      let credit = addLine(c, bookingId, #credit, VOID_CODE, 0, total);
      routeLine(c, credit, St.lineWindow(c.x, lid));
      RowStore.put<R.Charge>(St.later(c.x, St.CHARGE_TABLE), R.charge, lid, { ch with voidLine = credit; lastBlock = c.block });
      credited += total;
    };
    credited
  };

  /// The code of a credit line that voids a charge (Bill.VOID_CODE; other credits have code 0).
  let VOID_CODE : Nat = 1;

  /// A quote's package lines on a booking's bill: each inclusion's line, its tax lines after it, the
  /// charge row the bill and the invoice read, and the package row saying which inclusion it is.
  func writePackage(c : St.Ctx, bookingId : Nat, q : Q.Quote) {
    for (l in q.inclusions.vals()) {
      let lid = addLine(c, bookingId, #extra, l.category, l.night, l.net);
      for ((rule, t) in l.taxes.vals()) ignore addLine(c, bookingId, #extraTax, rule, l.night, t);
      RowStore.put<R.Charge>(St.later(c.x, St.CHARGE_TABLE), R.charge, lid,
        { bookingId; extraId = l.extraId; quantity = l.quantity; unitAmount = l.unit; taxLines = l.taxes.size(); postedBy = packagePoster(); voidLine = 0; lastBlock = c.block });
      RowStore.put<R.PackageLine>(St.later(c.x, St.PACKAGE_LINE_TABLE), R.packageLine, lid,
        { slot = l.slot; extraId = l.extraId; quantity = l.quantity; unitAmount = l.unit; rhythm = l.rhythm; taxed = l.taxed; taxLines = l.taxes.size(); lastBlock = c.block });
    };
  };

  /// What a booking's lines charge for its room (the room nights and their taxes, never a package's
  /// inclusions) on the nights before `until`: the first-night guarantee and the penalty are this.
  /// An inclusion of a night not stayed is a service never given, and is not charged.
  public func roomBefore(lines : [(E.FolioKind, Nat, Nat, Nat)], until : Nat) : Nat {
    var t = 0;
    for ((kind, _, night, amount) in lines.vals()) { if (E.isRoomLine(kind) and night < until) t += amount };
    t
  };

  /// What a plan takes at confirmation for a quote: the first night's room (with its taxes), the whole
  /// stay paid in advance, package and all, or the plan's deposit, a share of the room's stay.
  public func guaranteeOf(x : St.Later, planId : Nat, plan : R.RatePlan, q : Q.Quote) : Nat {
    switch (plan.guarantee) {
      case (#firstNightAuthorised) Q.firstNights(q, 1);
      case (#prepaidInFull) q.total;
      case (#deposit) depositOf(St.depositBps(x, planId), q.roomSubtotal + q.taxTotal);
    }
  };

  /// A deposit: its share of the room's stay with its taxes, rounded half-even once. Never a package's
  /// inclusions, as the first-night guarantee and the penalty are not.
  public func depositOf(bps : Nat, roomStay : Nat) : Nat { Q.divHalfEven(roomStay * bps, Q.BPS_ONE) };

  /// The guarantee of a booking's stored lines, as `guaranteeOf` is of a quote's.
  func guaranteeOfLines(x : St.Later, planId : Nat, plan : R.RatePlan, lines : [(E.FolioKind, Nat, Nat, Nat)], arrival : Nat, departure : Nat, total : Nat) : Nat {
    switch (plan.guarantee) {
      case (#firstNightAuthorised) roomBefore(lines, arrival + 1);
      case (#prepaidInFull) total;
      case (#deposit) depositOf(St.depositBps(x, planId), roomBefore(lines, departure));
    }
  };

  /// The quote a guest is shown for a stay, or why there is none. The search view calls this.
  public func quoteStay(c : St.Ctx, stay : Cmd.Stay) : { #ok : Checked; #err : Rf.Refusal } { checkStay(c, newPending(), stay, null, Acc.PUBLIC) };

  /// The quote under a company's or a promotion's access: the search of a guest who gave a code.
  public func quoteStayFor(c : St.Ctx, stay : Cmd.Stay, grant : Acc.Grant) : { #ok : Checked; #err : Rf.Refusal } { checkStay(c, newPending(), stay, null, grant) };

  /// The room's folio lines of a quote: each night's room charge and each tax's share of it. A package's
  /// lines are written beside them (`writePackage`), each with the inclusion it is.
  public func quoteLines(q : Q.Quote) : [(E.FolioKind, Nat, Nat, Nat)] {
    let out = List.empty<(E.FolioKind, Nat, Nat, Nat)>();
    var i = 0;
    while (i < q.nights) {
      let d = q.arrival + i;
      if (q.nightly[i] > 0) List.add(out, (#roomNight, 0, d, q.nightly[i]));
      for (t in q.taxes.vals()) { if (t.perNight[i] > 0) List.add(out, (#tax, t.ruleId, d, t.perNight[i])) };
      i += 1;
    };
    List.toArray(out)
  };

  func sumLines(lines : [(Nat, R.FolioLine)], pred : R.FolioLine -> Bool) : Nat {
    var t = 0;
    for ((_, l) in lines.vals()) { if (pred(l)) t += l.amount };
    t
  };

  // ── the hold share cap ──────────────────────────────────────────────────────

  /// At most half a night's allotment (rounded up, at least one) may sit on hold, so a burst of holds
  /// cannot lock a night away from guests ready to pay.
  public func holdCap(allotment : Nat) : Nat { Nat.max(1, (allotment + 1) / 2) };

  // ── money ───────────────────────────────────────────────────────────────────

  public func addLine(c : St.Ctx, bookingId : Nat, kind : E.FolioKind, code : Nat, night : Nat, amount : Nat) : Nat {
    let id = c.s.nextFolioId;
    c.s.nextFolioId += 1;
    RowStore.put<R.FolioLine>(c.s.folio, R.folioLine, id, { bookingId; kind; code; night; amount; block = c.block });
    id
  };

  public func addPayment(c : St.Ctx, bookingId : Nat, auth : Nat, kind : E.PaymentKind, amount : Nat, state : E.PaymentState) : Nat {
    let id = c.s.nextPaymentId;
    c.s.nextPaymentId += 1;
    RowStore.put<R.Payment>(c.s.payments, R.payment, id, { bookingId; gatewayAuth = auth; kind; amount; state; attempts = 0; block = c.block });
    id
  };

  /// Put a line or a payment in a window other than the guest's (the guest's has no route row).
  public func routeLine(c : St.Ctx, lineId : Nat, payerId : Nat) {
    if (payerId != 0 or St.lineWindow(c.x, lineId) != 0) RowStore.put<R.Route>(St.later(c.x, St.LINE_ROUTE_TABLE), R.lineRoute, lineId, { payerId; lastBlock = c.block });
  };
  public func routePayment(c : St.Ctx, paymentId : Nat, payerId : Nat) {
    if (payerId != 0) RowStore.put<R.Route>(St.later(c.x, St.PAYMENT_ROUTE_TABLE), R.paymentRoute, paymentId, { payerId; lastBlock = c.block });
  };

  /// A payment in the guest's window: every payment of a booking with no other payer.
  func guestPayment(c : St.Ctx, routed : Bool, paymentId : Nat) : Bool { not routed or St.paymentWindow(c.x, paymentId) == 0 };

  /// The authorisation a booking's guarantee rests on, and how much of it is captured or queued.
  public type AuthView = { auth : Nat; authorised : Nat; captured : Nat };

  public func authOf(s : St.Stores, bookingId : Nat) : ?AuthView { authWhere(s, bookingId, func(_) { true }) };

  /// The guest's own authorisation: the booking's, leaving out the payments of other windows.
  func guestAuth(c : St.Ctx, bookingId : Nat, routed : Bool) : ?AuthView { authWhere(c.s, bookingId, func(id) { guestPayment(c, routed, id) }) };

  func authWhere(s : St.Stores, bookingId : Nat, keep : Nat -> Bool) : ?AuthView {
    var auth = 0; var authorised = 0; var captured = 0; var voided = false;
    for ((pid, pmt) in St.paymentsOf(s, bookingId).vals()) if (keep(pid)) {
      switch (pmt.kind) {
        case (#authorised) { auth := pmt.gatewayAuth; authorised := pmt.amount; voided := false };
        case (#captured) { if (pmt.gatewayAuth == auth and pmt.state != #failed) captured += pmt.amount };
        case (#voided) { if (pmt.gatewayAuth == auth) voided := true };
        // a refund moves no authorisation; a charge on file rests on its own, never on the guarantee's
        case (#refunded or #chargedOnFile) {};
      };
    };
    if (auth == 0 or voided) null else ?{ auth; authorised; captured }
  };

  /// Captures (and charges on file) queued and not yet confirmed by the gateway.
  public func capturesDue(s : St.Stores, bookingId : Nat) : Nat {
    var due = 0;
    for ((_, pmt) in St.paymentsOf(s, bookingId).vals()) { if (E.takesMoney(pmt.kind) and pmt.state == #due) due += pmt.amount };
    due
  };

  /// Captures queued in the guest's window.
  public func guestCapturesDue(c : St.Ctx, bookingId : Nat) : Nat {
    let routed = St.payersOf(c.x, bookingId).size() > 0;
    var due = 0;
    for ((pid, pmt) in St.paymentsOf(c.s, bookingId).vals()) { if (E.takesMoney(pmt.kind) and pmt.state == #due and guestPayment(c, routed, pid)) due += pmt.amount };
    due
  };

  /// A card the guest paid with, as a refund sees it: the authorisation, what it can still give back
  /// (captured, less the refunds on it that have not failed), the id of its latest capture (the
  /// larger, the newer the card), and whether a gateway has refused a refund on it.
  public type Card = { auth : Nat; left : Nat; newest : Nat; refused : Bool };

  /// The guest's cards, from ONE walk of the booking's payments, and how many payment rows it read.
  public func guestCards(c : St.Ctx, bookingId : Nat, routed : Bool) : ([Card], Nat) {
    let rows = St.paymentsOf(c.s, bookingId);
    let byAuth = Map.empty<Nat, (Nat, Nat, Nat, Bool)>();   // auth -> (captured, refunded, newest, refused)
    for ((pid, pmt) in rows.vals()) {
      if (pmt.gatewayAuth != 0 and guestPayment(c, routed, pid)) {
        let (cap, ref, newest, refused) = switch (Map.get(byAuth, Nat.compare, pmt.gatewayAuth)) { case (?x) x; case null (0, 0, 0, false) };
        let next = switch (pmt.kind, pmt.state) {
          case (#captured or #chargedOnFile, #done) (cap + pmt.amount, ref, pid, refused);
          case (#refunded, #failed) (cap, ref, newest, true);
          case (#refunded, _) (cap, ref + pmt.amount, newest, refused);
          case _ (cap, ref, newest, refused);
        };
        Map.add(byAuth, Nat.compare, pmt.gatewayAuth, next);
      };
    };
    let out = List.empty<Card>();
    for ((auth, (cap, ref, newest, refused)) in Map.entries(byAuth)) {
      if (cap > 0) List.add(out, { auth; left = sub(cap, ref); newest; refused });
    };
    (List.toArray(out), rows.size())
  };

  /// A refund of `back` split across the cards, newest first, each up to what it can still give back,
  /// skipping a card that has refused a refund. What no card can take is the remainder, paid at the
  /// desk. Refunding to the card that paid, never another, is the card schemes' rule.
  public func slices(cards : [Card], back : Nat) : ([(Nat, Nat)], Nat) {
    let open = Array.filter<Card>(cards, func(k) { not k.refused and k.left > 0 });
    let order = Array.sort<Card>(open, func(a, b) { Nat.compare(b.newest, a.newest) });
    let out = List.empty<(Nat, Nat)>();
    var rest = back;
    for (k in order.vals()) {
      if (rest > 0) {
        let take = Nat.min(rest, k.left);
        List.add(out, (k.auth, take));
        rest -= take;
      };
    };
    (List.toArray(out), rest)
  };

  /// Writes a refund of `back` to the guest as its slices: one `#refunded` row per card, `#due`, and
  /// what no card can take as a refund the desk pays (no authorisation, `#failed`, as a refund the
  /// gateway would not make). Each row is recorded with its settle: its first row, the excess the
  /// settle split, and the block that wrote it.
  func refundGuest(c : St.Ctx, bookingId : Nat, routed : Bool, back : Nat) {
    let (cards, _) = guestCards(c, bookingId, routed);
    let (sl, rest) = slices(cards, back);
    let first = c.s.nextPaymentId;
    let t = St.later(c.x, St.REFUND_SLICE_TABLE);
    for ((auth, amount) in sl.vals()) {
      let id = addPayment(c, bookingId, auth, #refunded, amount, #due);
      RowStore.put<R.RefundSlice>(t, R.refundSlice, id, { firstSlice = first; excess = back; written = c.block });
    };
    if (rest > 0) {
      let id = addPayment(c, bookingId, 0, #refunded, rest, #failed);
      RowStore.put<R.RefundSlice>(t, R.refundSlice, id, { firstSlice = first; excess = back; written = c.block });
    };
  };

  /// Bring a booking's payments into line with a new liability, in the same step as the change that
  /// moved it. Returns the booking with `paid` and `outstanding` updated.
  ///
  /// Window by window (Windows.mo): a window other than the guest's that has been paid more than it
  /// owes is refunded through its own card, and is never captured by itself (its payer pays at the
  /// desk). The guest's window is the booking less the others, and is refunded and captured on the
  /// guest's own authorisation, as a booking with no other payer always was.
  public func settle(c : St.Ctx, bookingId : Nat, b : R.Booking, voidIfFree : Bool) : R.Booking {
    let o = Win.others(c.s, c.x, bookingId);
    let routed = o.windows.size() > 0;
    var othersPaid = o.paid;
    for (w in o.windows.vals()) {
      let owes = Win.liability(w);
      if (w.paid > owes) {
        let back : Nat = w.paid - owes;
        routePayment(c, addPayment(c, bookingId, w.auth, #refunded, back, #due), w.payerId);
        c.s.refundsCommitted += back;
        c.s.paidTotal := sub(c.s.paidTotal, back);
        othersPaid := sub(othersPaid, back);
      };
    };
    let liability = sub(sub(b.charged, o.charges), sub(b.credited, o.credits));
    var paid = sub(b.paid, o.paid);
    if (paid > liability) {
      let back : Nat = paid - liability;
      refundGuest(c, bookingId, routed, back);
      c.s.refundsCommitted += back;
      c.s.paidTotal := sub(c.s.paidTotal, back);
      paid := liability;
    };
    let due = sub(capturesDue(c.s, bookingId), o.due);
    if (liability > paid + due) {
      switch (guestAuth(c, bookingId, routed)) {
        case (?a) {
          let room = sub(a.authorised, a.captured);
          let want : Nat = liability - paid - due;
          let take = Nat.min(room, want);
          if (take > 0) ignore addPayment(c, bookingId, a.auth, #captured, take, #due);
        };
        case null {};
      };
    };
    if (voidIfFree and liability == 0) {
      switch (guestAuth(c, bookingId, routed)) {
        case (?a) { if (a.captured == 0) ignore addPayment(c, bookingId, a.auth, #voided, a.authorised, #due) };
        case null {};
      };
    };
    let total = paid + othersPaid;
    { b with paid = total; outstanding = sub(sub(b.charged, b.credited), total) }
  };

  /// Credit a booking down to a target liability, then settle.
  func creditTo(c : St.Ctx, bookingId : Nat, b : R.Booking, target : Nat, voidIfFree : Bool) : R.Booking {
    let liability = sub(b.charged, b.credited);
    var credited = b.credited;
    if (liability > target) {
      let amt : Nat = liability - target;
      ignore addLine(c, bookingId, #credit, 0, 0, amt);
      credited += amt;
    };
    settle(c, bookingId, { b with credited }, voidIfFree)
  };

  public func putBooking(c : St.Ctx, id : Nat, b : R.Booking) {
    RowStore.put<R.Booking>(c.s.bookings, R.booking, id, { b with lastBlock = c.block });
  };

  // ── holds ───────────────────────────────────────────────────────────────────

  /// Write a hold for a checked stay: counters, the hold row, and the quote's lines. The caller has
  /// finished every check.
  func writeHold(c : St.Ctx, p : Pending, owner : Principal, key : Blob, stay : Cmd.Stay, ch : Checked, ttl : Nat, fromWaitlist : Nat) : Nat {
    let departure = stay.arrival + stay.nights;
    takeHeld(c.s, p, stay.roomTypeId, stay.arrival, departure, stay.rooms);
    let id = c.s.nextHoldId;
    c.s.nextHoldId += 1;
    RowStore.put<R.Hold>(c.s.holds, R.hold, id, {
      roomTypeId = stay.roomTypeId; planId = stay.planId; arrival = stay.arrival; nights = stay.nights; rooms = stay.rooms;
      adults = stay.adults; children = stay.children; owner; expiresAt = c.height + ttl; state = #live;
      quotedTotal = ch.quote.total; quoteHash = ch.quote.hash; fromWaitlist; key; lastBlock = c.block;
    });
    for ((kind, code, night, amount) in quoteLines(ch.quote).vals()) {
      let lid = c.s.nextHoldLineId;
      c.s.nextHoldLineId += 1;
      RowStore.put<R.FolioLine>(c.s.holdLines, R.folioLine, lid, { bookingId = id; kind; code; night; amount; block = c.block });
    };
    // the package's lines, each frozen with the inclusion it is, as the guest was quoted them
    let holdLine = func(kind : E.FolioKind, code : Nat, night : Nat, amount : Nat) : Nat {
      let lid = c.s.nextHoldLineId;
      c.s.nextHoldLineId += 1;
      RowStore.put<R.FolioLine>(c.s.holdLines, R.folioLine, lid, { bookingId = id; kind; code; night; amount; block = c.block });
      lid
    };
    for (l in ch.quote.inclusions.vals()) {
      let lid = holdLine(#extra, l.category, l.night, l.net);
      for ((rule, t) in l.taxes.vals()) ignore holdLine(#extraTax, rule, l.night, t);
      RowStore.put<R.PackageLine>(St.later(c.x, St.HOLD_PACKAGE_TABLE), R.holdPackage, lid,
        { slot = l.slot; extraId = l.extraId; quantity = l.quantity; unitAmount = l.unit; rhythm = l.rhythm; taxed = l.taxed; taxLines = l.taxes.size(); lastBlock = c.block });
    };
    id
  };

  public func liveHoldsOf(s : St.Stores, owner : Principal) : Nat {
    St.prefixRows<R.Hold>(s.holds, R.hold, "live_by_owner", R.principalField(owner), W.ID, St.MAX_LIVE_HOLDS_PER_OWNER + 1).size()
  };

  func auditBlocks(c : St.Ctx, day : Nat) : ?Rf.Refusal {
    switch (BatchCore.get(c.s.audit, "night", c.day)) {
      case (?run) {
        let open = run.state != #completed;
        if (not Batch.admitsAct(c.day, open, day)) ?#auditOpen({ day = c.day }) else null
      };
      case null null;
    }
  };

  public func placeHold(c : St.Ctx, owner : Principal, stay : Cmd.Stay, quoteHash : Blob, key : Blob, grant : Acc.Grant) : Out {
    if (Principal.isAnonymous(owner)) return #err(#notTheOwner);
    let k = Blob.toArray(key);
    if (k.size() != W.PUBKEY or (k[0] != (2 : Nat8) and k[0] != (3 : Nat8))) return #err(#invalid({ what = "The hold key is not a compressed P-256 key." }));
    switch (auditBlocks(c, stay.arrival)) { case (?r) return #err(r); case null {} };
    let live = liveHoldsOf(c.s, owner);
    if (live >= St.MAX_LIVE_HOLDS_PER_OWNER) return #err(#tooManyHolds({ live; max = St.MAX_LIVE_HOLDS_PER_OWNER }));
    let p = newPending();
    let ch = switch (checkStay(c, p, stay, null, grant)) { case (#err r) return #err(r); case (#ok x) x };
    if (not Q.sameHash(ch.quote.hash, quoteHash)) return #err(#priceChanged({ total = ch.quote.total }));
    var i = 0;
    while (i < ch.nights.size()) {
      let n = ch.nights[i];
      let cap = holdCap(n.allotment);
      if (n.held + stay.rooms > cap) return #err(#holdShareCap({ day = stay.arrival + i; cap }));
      i += 1;
    };
    // every check has passed; the writes begin
    let id = writeHold(c, p, owner, key, stay, ch, ch.property.holdTtlHeights, 0);
    Acc.keepForHold(c, id, grant);
    flush(c, p);
    #ok([id, c.height + ch.property.holdTtlHeights, ch.quote.total])
  };

  /// Give a hold's nights back and mark it. The caller has decided it may.
  func endHold(c : St.Ctx, p : Pending, id : Nat, h : R.Hold, state : E.HoldState) {
    dropHeld(c.s, p, h.roomTypeId, h.arrival, h.arrival + h.nights, h.rooms);
    RowStore.put<R.Hold>(c.s.holds, R.hold, id, { h with state; lastBlock = c.block });
    if (h.fromWaitlist != 0) {
      switch (St.waitEntry(c.s, h.fromWaitlist)) {
        case (?w) { if (w.state == #offered and w.offeredHold == id) RowStore.put<R.WaitEntry>(c.s.waitlist, R.waitlist, h.fromWaitlist, { w with state = #left; lastBlock = c.block }) };
        case null {};
      };
    };
  };

  public func releaseHold(c : St.Ctx, owner : Principal, holdId : Nat) : Out {
    let ?h = St.hold(c.s, holdId) else return #err(#noSuchHold({ id = holdId }));
    if (h.owner != owner) return #err(#notTheOwner);
    if (h.state != #live) return #err(#holdNotLive({ id = holdId; state = E.holdStateText(h.state) }));
    let p = newPending();
    endHold(c, p, holdId, h, #released);
    promote(c, p, h.roomTypeId);
    flush(c, p);
    #ok([holdId])
  };

  /// The expired live holds at this height, oldest first.
  public func expiredHolds(s : St.Stores, height : Nat, limit : Nat) : [(Nat, R.Hold)] {
    let lo = SR.key2(0, W.HEIGHT, 0, W.ID);
    let hi = SR.key2(height, W.HEIGHT, St.MAX_ID, W.ID);
    switch (RowStore.page<R.Hold>(s.holds, R.hold, "live_by_expiry", lo, hi, null, limit)) { case (#ok pg) pg.rows; case (#err _) [] }
  };

  public func releaseExpired(c : St.Ctx, limit : Nat) : Out {
    let lim = if (limit == 0 or limit > RELEASE_LIMIT) RELEASE_LIMIT else limit;
    let due = expiredHolds(c.s, c.height, lim);
    if (due.size() == 0) return #err(#nothingToRelease);
    let p = newPending();
    let types = List.empty<Nat>();
    for ((id, h) in due.vals()) {
      endHold(c, p, id, h, #expired);
      if (not List.contains(types, Nat.equal, h.roomTypeId)) List.add(types, h.roomTypeId);
    };
    for (rt in List.values(types)) promote(c, p, rt);
    flush(c, p);
    #ok([due.size()])
  };

  // ── confirming a hold ───────────────────────────────────────────────────────

  public type GuestFacts = { guestName : Text; guestEmail : Text; note : Text; manageKey : Blob; account : ?Principal };

  /// A guest's details as a booking stores them. A guest booking online gives an email (sealed in their
  /// browser); a guest on the phone or at the desk may give none.
  func checkGuest(c : St.Ctx, g : GuestFacts, emailRequired : Bool) : ?Rf.Refusal {
    let nameBytes = Text.encodeUtf8(g.guestName).size();
    if (nameBytes == 0) return ?#invalid({ what = "The guest's name is required." });
    if (nameBytes > MAX_NAME_BYTES) return ?#tooLong({ what = "guest name"; max = MAX_NAME_BYTES });
    let emailBytes = Text.encodeUtf8(g.guestEmail).size();
    if (emailBytes == 0 and emailRequired) return ?#invalid({ what = "The guest's email is required." });
    // the email arrives encrypted in the browser; the contract stores the envelope and never the address
    if (emailBytes > 0 and not Text.startsWith(g.guestEmail, #text "lxe1.")) return ?#invalid({ what = "The email must arrive encrypted." });
    if (emailBytes > MAX_EMAIL_ENVELOPE_BYTES) return ?#tooLong({ what = "encrypted email"; max = MAX_EMAIL_ENVELOPE_BYTES });
    if (Text.encodeUtf8(g.note).size() > MAX_NOTE_BYTES) return ?#tooLong({ what = "note"; max = MAX_NOTE_BYTES });
    let k = Blob.toArray(g.manageKey);
    if (k.size() != W.PUBKEY or (k[0] != (2 : Nat8) and k[0] != (3 : Nat8))) return ?#invalid({ what = "The manage key is not a compressed P-256 key." });
    switch (TA.fits(c.s.arena, [g.guestName, g.guestEmail, g.note], MAX_EMAIL_ENVELOPE_BYTES)) { case (?why) ?#invalid({ what = why }); case null null }
  };

  public func checkAuth(c : St.Ctx, prop : R.Property, a : Cmd.AuthFacts, ref : Nat, amount : Nat) : ?Rf.Refusal {
    if (a.merchantRef != ref) return ?#payment({ reason = "The payment authorisation is for another reservation." });
    if (a.currency != prop.currency) return ?#payment({ reason = "The payment authorisation is in " # a.currency # ", and the hotel charges in " # prop.currency # "." });
    if (a.amount != amount) return ?#payment({ reason = "The payment authorisation is for " # Nat.toText(a.amount) # ", and " # Nat.toText(amount) # " is due." });
    if (St.authUsed(c.s, a.authId)) return ?#authUsed({ authId = a.authId });
    null
  };

  func cancelDeadlineOf(plan : R.RatePlan, arrival : Nat) : Nat {
    if (not plan.refundable) 0 else sub(arrival, plan.freeCancelDaysBefore)
  };

  public func confirmHold(c : St.Ctx, owner : Principal, holdId : Nat, g : GuestFacts, a : Cmd.AuthFacts) : Out { confirmWith(c, owner, holdId, g, a, 0) };

  /// A hold confirmed with the guest's card kept on file under `token`.
  public func confirmHoldOnFile(c : St.Ctx, owner : Principal, holdId : Nat, g : GuestFacts, a : Cmd.AuthFacts, token : Nat) : Out {
    if (token == 0) return #err(#payment({ reason = "The card was not kept on file." }));
    confirmWith(c, owner, holdId, g, a, token)
  };

  /// Why a plan refuses a card on file, or would refuse a booking without one.
  func cardRule(c : St.Ctx, plan : R.RatePlan, token : Nat) : ?Rf.Refusal {
    if (token != 0 and plan.guarantee == #prepaidInFull) return ?#payment({ reason = "A rate paid in advance keeps no card on file." });
    if (token == 0 and St.keepsCard(c.x, plan)) return ?#payment({ reason = "This rate keeps the guest's card on file, and the guest has not agreed to it." });
    null
  };

  func confirmWith(c : St.Ctx, owner : Principal, holdId : Nat, g : GuestFacts, a : Cmd.AuthFacts, token : Nat) : Out {
    let ?prop = St.property(c.s) else return #err(#notConfigured);
    let ?h = St.hold(c.s, holdId) else return #err(#noSuchHold({ id = holdId }));
    if (h.owner != owner) return #err(#notTheOwner);
    if (h.state != #live) return #err(#holdNotLive({ id = holdId; state = E.holdStateText(h.state) }));
    if (h.expiresAt <= c.height) return #err(#holdExpired({ id = holdId; expiredAt = h.expiresAt; height = c.height }));
    switch (auditBlocks(c, h.arrival)) { case (?r) return #err(r); case null {} };
    let ?plan = St.plan(c.s, h.planId) else return #err(#noSuchPlan({ id = h.planId }));
    // the access the hold was placed under must still admit its rate: a company closed since is refused
    let grant = Acc.ofHold(c.x, holdId);
    switch (Acc.admits(c, h.planId, grant, ?{ arrival = h.arrival; nights = h.nights; counts = true })) { case (?r) return #err(r); case null {} };
    let stored = St.holdLinesOf(c.s, holdId);
    let lines = Array.map<(Nat, R.FolioLine), (E.FolioKind, Nat, Nat, Nat)>(stored, func((_, l)) { (l.kind, l.code, l.night, l.amount) });
    let total = sumLines(stored, func(_) { true });
    let guarantee = guaranteeOfLines(c.x, h.planId, plan, lines, h.arrival, h.arrival + h.nights, total);
    if (guarantee == 0) return #err(#invalid({ what = "The rate's deposit is not set." }));
    switch (checkGuest(c, g, true)) { case (?r) return #err(r); case null {} };
    switch (checkAuth(c, prop, a, holdId, guarantee)) { case (?r) return #err(r); case null {} };
    switch (cardRule(c, plan, token)) { case (?r) return #err(r); case null {} };

    // every check has passed; the writes begin
    let p = newPending();
    let departure = h.arrival + h.nights;
    dropHeld(c.s, p, h.roomTypeId, h.arrival, departure, h.rooms);
    takeSold(c.s, p, h.roomTypeId, h.arrival, departure, h.rooms);
    RowStore.put<R.Hold>(c.s.holds, R.hold, holdId, { h with state = #confirmed; lastBlock = c.block });
    if (h.fromWaitlist != 0) {
      switch (St.waitEntry(c.s, h.fromWaitlist)) {
        case (?w) RowStore.put<R.WaitEntry>(c.s.waitlist, R.waitlist, h.fromWaitlist, { w with state = #left; lastBlock = c.block });
        case null {};
      };
    };
    let id = c.s.nextBookingId;
    c.s.nextBookingId += 1;
    // the hold's lines in order; a package's line brings its charge and its package row with it
    for ((hlid, l) in stored.vals()) {
      let lid = addLine(c, id, l.kind, l.code, l.night, l.amount);
      switch (St.holdPackage(c.x, hlid)) {
        case (?pk) {
          RowStore.put<R.Charge>(St.later(c.x, St.CHARGE_TABLE), R.charge, lid,
            { bookingId = id; extraId = pk.extraId; quantity = pk.quantity; unitAmount = pk.unitAmount; taxLines = pk.taxLines; postedBy = packagePoster(); voidLine = 0; lastBlock = c.block });
          RowStore.put<R.PackageLine>(St.later(c.x, St.PACKAGE_LINE_TABLE), R.packageLine, lid, { pk with lastBlock = c.block });
        };
        case null {};
      };
    };
    ignore addPayment(c, id, a.authId, #authorised, a.amount, #done);
    // a stay paid in advance and a deposit are taken at once; a first night is authorised and held
    let captureId = if (plan.guarantee == #firstNightAuthorised) 0 else addPayment(c, id, a.authId, #captured, guarantee, #due);
    if (token != 0) keepCard(c, id, token, a.authId, 0);
    let penalty = if (plan.refundable) roomBefore(lines, h.arrival + Nat.max(1, plan.penaltyNights)) else roomBefore(lines, departure);
    let b : R.Booking = {
      roomTypeId = h.roomTypeId; planId = h.planId; arrival = h.arrival; departure; rooms = h.rooms;
      adults = h.adults; children = h.children; status = #confirmed; account = g.account;
      manageKey = g.manageKey; manageNonce = 0;
      guestName = TA.put(c.s.arena, g.guestName); guestEmail = TA.put(c.s.arena, g.guestEmail); note = TA.put(c.s.arena, g.note);
      charged = total; credited = 0; paid = 0; outstanding = total;
      cancelDeadline = cancelDeadlineOf(plan, h.arrival); penalty;
      checkedMinStay = 0; checkedMaxStay = 0; holdId; assignedRoom = 0; createdBlock = c.block; lastBlock = c.block;
    };
    // the restriction bounds this stay was accepted under, read from its arrival night
    let arr = St.night(c.s, h.roomTypeId, h.arrival);
    let (mn, mx) = switch arr { case (?n) (if (n.minStay == 0) 1 else n.minStay, n.maxStay); case null (1, 0) };
    putBooking(c, id, { b with checkedMinStay = mn; checkedMaxStay = mx });
    Acc.keepForBooking(c, id, grant);
    flush(c, p);
    #ok([id, captureId, total])
  };

  // ── a booking taken by staff ────────────────────────────────────────────────

  /// The rooms a check-in gives: as many as booked, each of the booking's type, in service and empty.
  func checkRooms(c : St.Ctx, roomTypeId : Nat, rooms : Nat, roomIds : [Nat]) : { #ok : [(Nat, R.Room)]; #err : Rf.Refusal } {
    if (roomIds.size() != rooms) return #err(#invalid({ what = "Assign exactly " # Nat.toText(rooms) # " room(s)." }));
    let out = List.empty<(Nat, R.Room)>();
    for (rid in roomIds.vals()) {
      if (List.any<(Nat, R.Room)>(out, func((x, _)) { x == rid })) return #err(#invalid({ what = "Room " # Nat.toText(rid) # " is listed twice." }));
      let ?r = St.room(c.s, rid) else return #err(#noSuchRoom({ id = rid }));
      if (r.roomTypeId != roomTypeId) return #err(#roomWrongType({ id = rid; roomTypeId }));
      if (r.status != #active or r.occupiedBy != 0) return #err(#roomNotVacant({ id = rid }));
      List.add(out, (rid, r));
    };
    #ok(List.toArray(out))
  };

  /// A booking for a guest on the phone or at the desk. It is checked as a guest's stay is (the same
  /// grid, the same restrictions, the same price, confirmed by its hash), takes its nights at once, and
  /// carries no payment: what it costs is outstanding until it is paid at the desk. A walk-in arrives
  /// today and is checked in to its rooms in the same act.
  /// A booking staff take: by phone, a walk-in, or (`blockId` not 0, channel `#group`) a guest of a
  /// group's rooming list picked up from its block.
  public func bookByStaff(c : St.Ctx, staff : Principal, channel : E.Channel, stay : Cmd.Stay, quoteHash : Blob, g : GuestFacts, roomIds : [Nat], grant : Acc.Grant,
      blockId : Nat) : Out {
    let ?_ = St.property(c.s) else return #err(#notConfigured);
    switch (auditBlocks(c, stay.arrival)) { case (?r) return #err(r); case null {} };
    let fromBlock = blockId != 0;
    switch channel {
      case (#walkIn) { if (stay.arrival != c.day) return #err(#notTheDay({ day = stay.arrival; today = c.day })) };
      case (#phone) { if (roomIds.size() != 0) return #err(#invalid({ what = "A booking by phone is given its rooms at check-in." })) };
      case (#group) { if (roomIds.size() != 0) return #err(#invalid({ what = "A group's guest is given rooms at check-in." })) };
    };
    // kept on purpose: the endpoints pass a block only with `#group`, and `#group` only with a block
    if (fromBlock != (channel == #group)) return #err(#invalid({ what = "A group's guest is picked up from its block." }));
    if (fromBlock) switch (Blocks.checkPickup(c, blockId, stay.roomTypeId, stay.planId, stay.arrival, stay.nights, stay.rooms)) { case (?r) return #err(r); case null {} };
    let p = newPending();
    let ch = switch (checkStayAs(c, p, stay, null, grant, fromBlock)) { case (#err r) return #err(r); case (#ok x) x };
    if (not Q.sameHash(ch.quote.hash, quoteHash)) return #err(#priceChanged({ total = ch.quote.total }));
    switch (checkGuest(c, g, false)) { case (?r) return #err(r); case null {} };
    let rooms : [(Nat, R.Room)] = switch channel {
      case (#walkIn) { switch (checkRooms(c, stay.roomTypeId, stay.rooms, roomIds)) { case (#ok x) x; case (#err r) return #err(r) } };
      case (#phone or #group) [];
    };

    // every check has passed; the writes begin
    let departure = stay.arrival + stay.nights;
    takeSold(c.s, p, stay.roomTypeId, stay.arrival, departure, stay.rooms);
    let id = c.s.nextBookingId;
    c.s.nextBookingId += 1;
    let lines = quoteLines(ch.quote);
    for ((kind, code, night, amount) in lines.vals()) ignore addLine(c, id, kind, code, night, amount);
    writePackage(c, id, ch.quote);
    let total = ch.quote.total;
    let penalty = if (ch.plan.refundable) roomBefore(lines, stay.arrival + Nat.max(1, ch.plan.penaltyNights)) else roomBefore(lines, departure);
    let first = ch.nights[0];
    let walkIn = channel == #walkIn;
    putBooking(c, id, {
      roomTypeId = stay.roomTypeId; planId = stay.planId; arrival = stay.arrival; departure; rooms = stay.rooms;
      adults = stay.adults; children = stay.children; status = if (walkIn) #checkedIn else #confirmed; account = null;
      manageKey = g.manageKey; manageNonce = 0;
      guestName = TA.put(c.s.arena, g.guestName); guestEmail = TA.put(c.s.arena, g.guestEmail); note = TA.put(c.s.arena, g.note);
      charged = total; credited = 0; paid = 0; outstanding = total;
      cancelDeadline = cancelDeadlineOf(ch.plan, stay.arrival); penalty;
      // a pickup was not sold under the night's restrictions (`checkStayAs`): none is recorded for it
      checkedMinStay = (if (fromBlock) 0 else if (first.minStay == 0) 1 else first.minStay); checkedMaxStay = (if (fromBlock) 0 else first.maxStay);
      holdId = 0; assignedRoom = (if (walkIn) roomIds[0] else 0); createdBlock = c.block; lastBlock = c.block;
    });
    for ((rid, r) in rooms.vals()) RowStore.put<R.Room>(c.s.rooms, R.room, rid, { r with occupiedBy = id; lastBlock = c.block });
    RowStore.put<R.StaffBooking>(St.later(c.x, St.STAFF_BOOKING_TABLE), R.staffBooking, id, { channel; madeBy = staff; day = c.day; lastBlock = c.block });
    // a guest booked by phone or from a group's list on a rate that keeps a card: the desk sends the card
    // link, and the booking is flagged on the day list once its guarantee is due without one
    if (not walkIn and St.keepsCard(c.x, ch.plan)) {
      let deadline = if (ch.plan.refundable) cancelDeadlineOf(ch.plan, stay.arrival) else c.day;
      putCard(c, id, { token = 0; firstAuth = 0; agreedBlock = 0; deadline; state = #wanted; chargeId = 0; attempts = 0; declinedDay = 0; lastBlock = c.block });
    };
    Acc.keepForBooking(c, id, grant);
    if (fromBlock) Blocks.pick(c, blockId, id, stay.roomTypeId, stay.arrival, departure, stay.rooms);
    flush(c, p);
    #ok([id, total])
  };

  // ── acting on a booking ─────────────────────────────────────────────────────

  func mayAct(b : R.Booking, by : Cmd.GuestActor) : Bool {
    switch by {
      case (#manageKey) true;   // the signature over this booking was verified at the edge
      case (#account p) { switch (b.account) { case (?q) q == p; case null false } };
    }
  };

  /// What cancelling now leaves the guest owing.
  public func cancelLiability(c : St.Ctx, b : R.Booking, plan : R.RatePlan) : Nat {
    if (plan.refundable and c.day <= b.cancelDeadline) 0 else b.penalty
  };

  /// A booking's nights from `from` to `to` given back: off the night's sold count, and, for a pickup
  /// from a group block, off the block's pickup (back to the block while it is open).
  func giveNights(c : St.Ctx, p : Pending, id : Nat, b : R.Booking, from : Nat, to : Nat) {
    dropSold(c.s, p, b.roomTypeId, from, to, b.rooms);
    Blocks.giveBack(c, id, b.roomTypeId, from, to, b.rooms);
  };

  func releaseNights(c : St.Ctx, p : Pending, id : Nat, b : R.Booking) { giveNights(c, p, id, b, b.arrival, b.departure) };

  public func cancel(c : St.Ctx, by : Cmd.GuestActor, id : Nat) : Out {
    let ?b = St.booking(c.s, id) else return #err(#noSuchBooking({ id }));
    if (not mayAct(b, by)) return #err(#notTheOwner);
    if (b.status != #confirmed) return #err(#bookingState({ id; state = E.bookingStatusText(b.status); wanted = "confirmed" }));
    switch (auditBlocks(c, b.arrival)) { case (?r) return #err(r); case null {} };
    let ?plan = St.plan(c.s, b.planId) else return #err(#noSuchPlan({ id = b.planId }));
    let liability = cancelLiability(c, b, plan);
    let p = newPending();
    releaseNights(c, p, id, b);
    let after = creditTo(c, id, { b with status = #cancelled }, liability, true);
    putBooking(c, id, after);
    releaseCard(c, id);
    Mail.cancelled(c, id);
    promote(c, p, b.roomTypeId);
    flush(c, p);
    #ok([id, liability, sub(b.paid, after.paid)])
  };

  /// A cancellation by staff: the same, with the penalty waived when the proposal says so. Called
  /// only from an approved proposal.
  public func staffCancel(c : St.Ctx, id : Nat, waive : Bool) : Out {
    let ?b = St.booking(c.s, id) else return #err(#noSuchBooking({ id }));
    if (b.status != #confirmed) return #err(#bookingState({ id; state = E.bookingStatusText(b.status); wanted = "confirmed" }));
    let ?plan = St.plan(c.s, b.planId) else return #err(#noSuchPlan({ id = b.planId }));
    let liability = if (waive) 0 else cancelLiability(c, b, plan);
    let p = newPending();
    releaseNights(c, p, id, b);
    let after = creditTo(c, id, { b with status = #cancelled }, liability, true);
    putBooking(c, id, after);
    releaseCard(c, id);
    Mail.cancelled(c, id);
    promote(c, p, b.roomTypeId);
    flush(c, p);
    #ok([id, liability])
  };

  /// Credit a booking down by an amount (a waiver, a comp, an override, a goodwill refund). Called
  /// only from an approved proposal, which has already checked the amount.
  public func creditBy(c : St.Ctx, id : Nat, amount : Nat) : Out {
    let ?b = St.booking(c.s, id) else return #err(#noSuchBooking({ id }));
    // a credit goes on the guest's bill, which its invoice has closed
    if (Win.invoiced(c.x, id, 0)) return #err(#invoiced({ bookingId = id; payerId = 0 }));
    let liability = sub(b.charged, b.credited);
    if (amount == 0 or amount > liability) return #err(#invalid({ what = "The credit must be between 1 and " # Nat.toText(liability) # "." }));
    putBooking(c, id, creditTo(c, id, b, liability - amount, false));
    #ok([id, amount])
  };

  public func editGuestName(c : St.Ctx, id : Nat, name : Text) : Out {
    let ?b = St.booking(c.s, id) else return #err(#noSuchBooking({ id }));
    let n = Text.encodeUtf8(name).size();
    if (n == 0 or n > MAX_NAME_BYTES) return #err(#tooLong({ what = "guest name"; max = MAX_NAME_BYTES }));
    switch (TA.fits(c.s.arena, [name], MAX_NAME_BYTES)) { case (?why) return #err(#invalid({ what = why })); case null {} };
    putBooking(c, id, { b with guestName = TA.put(c.s.arena, name) });
    #ok([id])
  };

  public func claim(c : St.Ctx, account : Principal, id : Nat) : Out {
    let ?b = St.booking(c.s, id) else return #err(#noSuchBooking({ id }));
    switch (b.account) { case (?_) return #err(#notTheOwner); case null {} };
    putBooking(c, id, { b with account = ?account; manageNonce = b.manageNonce + 1 });
    #ok([id])
  };

  /// A manage-key act advances the booking's nonce, so a signed request cannot be replayed.
  public func bumpNonce(c : St.Ctx, id : Nat) {
    switch (St.booking(c.s, id)) { case (?b) RowStore.put<R.Booking>(c.s.bookings, R.booking, id, { b with manageNonce = b.manageNonce + 1; lastBlock = c.block }); case null {} };
  };

  // ── modifying a booking ─────────────────────────────────────────────────────

  /// The quote of an in-house stay's extra nights: the nights `from ≤ day < to`, with every tax but
  /// the once-per-stay ones (those were charged when the stay was booked).
  public func extensionQuote(c : St.Ctx, p : Pending, id : Nat, b : R.Booking, to : Nat) : { #ok : Q.Quote; #err : Rf.Refusal } {
    let ?prop = St.property(c.s) else return #err(#notConfigured);
    let ?plan = St.plan(c.s, b.planId) else return #err(#noSuchPlan({ id = b.planId }));
    let from = b.departure;
    if (to <= from) return #err(#invalid({ what = "An extension ends after the current departure." }));
    if (to > c.day + prop.horizonDays) return #err(#beyondHorizon({ day = to; lastDay = c.day + prop.horizonDays }));
    if (to - b.arrival > prop.maxStayNights) return #err(#stayLength({ nights = to - b.arrival; max = prop.maxStayNights }));
    let rows = readThrough(c.s, p, b.roomTypeId, from, to + 1);
    let bars = List.empty<Nat>();
    var i = 0;
    while (i + from < to) {
      let d = from + i;
      let ?n = rows[i] else return #err(#nightClosed({ day = d }));
      if (n.stopSell) return #err(#stopSell({ day = d }));
      let free = St.freeOn(c.x, b.roomTypeId, d, n);
      if (free < b.rooms) return #err(#soldOut({ day = d; free; wanted = b.rooms }));
      List.add(bars, n.bar);
      i += 1;
    };
    switch (rows[to - from]) { case (?dep) { if (dep.closedToDeparture) return #err(#closedToDeparture({ day = to })) }; case null {} };
    let taxes = Array.filter<Q.TaxInput>(St.taxes(c.s), func(t) { t.rule.kind != #perStay });
    // a package goes on with the stay: each inclusion the guest has every night, re-priced at the
    // extra's catalogue price now for the nights added (the nights posted keep their price)
    let incs = List.empty<Q.IncInput>();
    for ((_, l, pk, ch) in livePackage(c, id, from - 1 : Nat).vals()) {
      if (pk.rhythm == #everyNight and l.night + 1 == from) {
        let ?e = St.extra(c.x, pk.extraId) else return #err(#noSuchExtra({ id = pk.extraId }));
        if (not e.active) return #err(#inactive({ what = "extra"; id = pk.extraId }));
        if (e.price == 0) return #err(#invalid({ what = "An extra in a package needs a set price." }));
        List.add(incs, { slot = pk.slot; extraId = pk.extraId; category = Nat8.toNat(E.extraCategoryByte(e.category)); unit = e.price; quantity = ch.quantity;
          rhythm = #everyNight; taxed = e.taxed });
      };
    };
    #ok(Q.withPackage(Q.price(b.roomTypeId, b.planId, plan, from, List.toArray(bars), b.rooms, taxes), List.toArray(incs), taxes, b.arrival))
  };

  public func modify(c : St.Ctx, by : Cmd.GuestActor, id : Nat, stay : Cmd.Stay, quoteHash : Blob, auth : ?Cmd.AuthFacts) : Out {
    let ?b = St.booking(c.s, id) else return #err(#noSuchBooking({ id }));
    if (not mayAct(b, by)) return #err(#notTheOwner);
    let ?prop = St.property(c.s) else return #err(#notConfigured);
    let ?oldPlan = St.plan(c.s, b.planId) else return #err(#noSuchPlan({ id = b.planId }));
    if (not oldPlan.modifiable) return #err(#notModifiable({ planId = b.planId }));
    // a pickup's nights are the group's: the desk cancels it and picks the guest up again
    if (St.bookingBlock(c.x, id) != null) return #err(#invalid({ what = "A booking from a group block is changed by the desk: cancel it and pick the guest up again." }));
    switch (b.status) {
      case (#confirmed) modifyBeforeArrival(c, prop, id, b, oldPlan, stay, quoteHash, auth);
      case (#checkedIn) modifyInHouse(c, id, b, stay, quoteHash);
      case _ #err(#bookingState({ id; state = E.bookingStatusText(b.status); wanted = "confirmed or checked in" }));
    }
  };

  func modifyBeforeArrival(c : St.Ctx, prop : R.Property, id : Nat, b : R.Booking, oldPlan : R.RatePlan, stay : Cmd.Stay, quoteHash : Blob, auth : ?Cmd.AuthFacts) : Out {
    switch (auditBlocks(c, Nat.min(b.arrival, stay.arrival))) { case (?r) return #err(r); case null {} };
    let p = newPending();
    let credit : Credit = { roomTypeId = b.roomTypeId; arrival = b.arrival; departure = b.departure; rooms = b.rooms };
    // checked under the access the booking was sold under: a company's booking may move to its other rates
    let ch = switch (checkStay(c, p, stay, ?credit, Acc.ofBooking(c.x, id))) { case (#err r) return #err(r); case (#ok x) x };
    if (not ch.plan.modifiable) return #err(#notModifiable({ planId = stay.planId }));
    if (ch.plan.guarantee != oldPlan.guarantee) return #err(#invalid({ what = "A change keeps the same kind of guarantee; book the other rate as a new reservation." }));
    if (not Q.sameHash(ch.quote.hash, quoteHash)) return #err(#priceChanged({ total = ch.quote.total }));
    let lines = quoteLines(ch.quote);
    let departure = stay.arrival + stay.nights;
    let guarantee = guaranteeOf(c.x, stay.planId, ch.plan, ch.quote);
    let current = authOf(c.s, id);
    let covered = switch current { case (?x) x.authorised; case null 0 };
    let needsAuth = guarantee > covered;
    switch (needsAuth, auth) {
      case (true, null) return #err(#payment({ reason = "The new stay needs a guarantee of " # Nat.toText(guarantee) # "; authorise it and try again." }));
      case (true, ?a) { switch (checkAuth(c, prop, a, St.BOOKING_REF_BASE + id, guarantee)) { case (?r) return #err(r); case null {} } };
      case (false, ?_) return #err(#invalid({ what = "No new payment authorisation is needed for this change." }));
      case (false, null) {};
    };
    // the old package's lines are voided one by one, on the bills they are on
    let oldPackage = livePackage(c, id, 0);
    switch (packageVoidRefusal(c, id, oldPackage)) { case (?r) return #err(r); case null {} };

    // every check has passed; the writes begin
    dropSold(c.s, p, b.roomTypeId, b.arrival, b.departure, b.rooms);
    takeSold(c.s, p, stay.roomTypeId, stay.arrival, departure, stay.rooms);
    let voided = voidPackage(c, id, oldPackage);
    let reversed = sub(sub(b.charged, b.credited), voided);
    if (reversed > 0) ignore addLine(c, id, #credit, 0, 0, reversed);
    for ((kind, code, night, amount) in lines.vals()) ignore addLine(c, id, kind, code, night, amount);
    writePackage(c, id, ch.quote);
    switch (needsAuth, auth, current) {
      case (true, ?a, old) {
        ignore addPayment(c, id, a.authId, #authorised, a.amount, #done);
        switch old { case (?o) { if (o.captured == 0) ignore addPayment(c, id, o.auth, #voided, o.authorised, #due) }; case null {} };
      };
      case _ {};
    };
    let penalty = if (ch.plan.refundable) roomBefore(lines, stay.arrival + Nat.max(1, ch.plan.penaltyNights)) else roomBefore(lines, departure);
    let first = ch.nights[0];
    let nb : R.Booking = {
      b with
      roomTypeId = stay.roomTypeId; planId = stay.planId; arrival = stay.arrival; departure; rooms = stay.rooms;
      adults = stay.adults; children = stay.children;
      charged = b.charged + ch.quote.total; credited = b.credited + voided + reversed;
      cancelDeadline = cancelDeadlineOf(ch.plan, stay.arrival); penalty;
      checkedMinStay = (if (first.minStay == 0) 1 else first.minStay); checkedMaxStay = first.maxStay;
    };
    putBooking(c, id, settle(c, id, nb, false));
    if (stay.arrival != b.arrival) Mail.moved(c, id, stay.arrival);
    promote(c, p, b.roomTypeId);
    if (stay.roomTypeId != b.roomTypeId) promote(c, p, stay.roomTypeId);
    flush(c, p);
    #ok([id, ch.quote.total])
  };

  /// An in-house stay may change only its departure: extend (priced on the extra nights) or shorten
  /// (the nights given back are credited with their taxes).
  func modifyInHouse(c : St.Ctx, id : Nat, b : R.Booking, stay : Cmd.Stay, quoteHash : Blob) : Out {
    if (stay.roomTypeId != b.roomTypeId or stay.planId != b.planId or stay.arrival != b.arrival or stay.rooms != b.rooms) {
      return #err(#invalid({ what = "During a stay only the departure date can change." }));
    };
    let newDeparture = stay.arrival + stay.nights;
    if (newDeparture <= c.day) return #err(#invalid({ what = "The new departure must be after today." }));
    if (newDeparture == b.departure) return #err(#invalid({ what = "The departure is already that day." }));
    let p = newPending();
    if (newDeparture > b.departure) {
      let q = switch (extensionQuote(c, p, id, b, newDeparture)) { case (#err r) return #err(r); case (#ok x) x };
      if (not Q.sameHash(q.hash, quoteHash)) return #err(#priceChanged({ total = q.total }));
      // the nights added go on the guest's bill
      if (Win.invoiced(c.x, id, 0)) return #err(#invoiced({ bookingId = id; payerId = 0 }));
      // every check has passed; the writes begin
      takeSold(c.s, p, b.roomTypeId, b.departure, newDeparture, b.rooms);
      for ((kind, code, night, amount) in quoteLines(q).vals()) ignore addLine(c, id, kind, code, night, amount);
      writePackage(c, id, q);
      putBooking(c, id, settle(c, id, { b with departure = newDeparture; charged = b.charged + q.total }, false));
    } else {
      // shortening: the room's lines of the nights given back, credited in the window each line is in.
      // An extra is posted on the day it is posted, which is before any new departure, so the kind is
      // what a room line is, not a guard that ever turns one away.
      let backs = List.empty<(Nat, Nat)>();   // (window, amount), in the order the windows are met
      var back = 0;
      for ((lid, l) in St.folioOf(c.s, id).vals()) {
        if (E.isRoomLine(l.kind) and l.night >= newDeparture and l.night < b.departure) {
          let w = St.lineWindow(c.x, lid);
          switch (List.indexOf<(Nat, Nat)>(backs, func(a, b2) { a.0 == b2.0 }, (w, 0))) {
            case (?i) { let (_, amt) = List.at(backs, i); List.put(backs, i, (w, amt + l.amount)) };
            case null List.add(backs, (w, l.amount));
          };
          back += l.amount;
        };
      };
      for ((w, _) in List.values(backs)) { if (Win.invoiced(c.x, id, w)) return #err(#invoiced({ bookingId = id; payerId = w })) };
      // a package's inclusions of the nights given back are services never given: each is voided
      let dropped = livePackage(c, id, newDeparture);
      switch (packageVoidRefusal(c, id, dropped)) { case (?r) return #err(r); case null {} };
      giveNights(c, p, id, b, newDeparture, b.departure);
      for ((w, amt) in List.values(backs)) { if (amt > 0) routeLine(c, addLine(c, id, #credit, 0, 0, amt), w) };
      let voided = voidPackage(c, id, dropped);
      putBooking(c, id, settle(c, id, { b with departure = newDeparture; credited = b.credited + back + voided }, false));
      promote(c, p, b.roomTypeId);
    };
    flush(c, p);
    #ok([id])
  };

  // ── the front desk ──────────────────────────────────────────────────────────

  public func checkIn(c : St.Ctx, id : Nat, roomIds : [Nat]) : Out {
    let ?b = St.booking(c.s, id) else return #err(#noSuchBooking({ id }));
    if (b.status != #confirmed) return #err(#bookingState({ id; state = E.bookingStatusText(b.status); wanted = "confirmed" }));
    if (b.arrival != c.day) return #err(#notTheDay({ day = b.arrival; today = c.day }));
    let rooms = switch (checkRooms(c, b.roomTypeId, b.rooms, roomIds)) { case (#ok x) x; case (#err r) return #err(r) };
    for ((rid, r) in rooms.vals()) RowStore.put<R.Room>(c.s.rooms, R.room, rid, { r with occupiedBy = id; lastBlock = c.block });
    putBooking(c, id, { b with status = #checkedIn; assignedRoom = roomIds[0] });
    // the guest is here: a card the desk was still waiting for is no longer needed, and so is the note
    // before arrival
    closeWanted(c, id);
    Mail.arrivedOrNot(c, id);
    #ok([id])
  };

  public func checkOut(c : St.Ctx, id : Nat) : Out {
    let ?b = St.booking(c.s, id) else return #err(#noSuchBooking({ id }));
    if (b.status != #checkedIn) return #err(#bookingState({ id; state = E.bookingStatusText(b.status); wanted = "checked in" }));
    if (b.outstanding > 0) return #err(#balanceOutstanding({ outstanding = b.outstanding }));
    let p = newPending();
    // an early departure gives back the nights not used; the charges stand
    let newDeparture = Nat.max(Nat.max(c.day, b.arrival + 1), Nat.min(c.day, b.departure));
    let departure = if (newDeparture < b.departure) newDeparture else b.departure;
    if (departure < b.departure) giveNights(c, p, id, b, departure, b.departure);
    let (lo, hi) = SR.prefixRange(b.roomTypeId, W.ID, W.ID);
    for ((rid, r) in St.rangeRows<R.Room>(c.s.rooms, R.room, "by_type", lo, hi).vals()) {
      if (r.occupiedBy == id) {
        RowStore.put<R.Room>(c.s.rooms, R.room, rid, { r with occupiedBy = 0; lastBlock = c.block });
        // the room the guest leaves is dirty until housekeeping cleans it
        Hk.vacated(c, rid);
      };
    };
    putBooking(c, id, { b with status = #checkedOut; departure });
    releaseCard(c, id);
    Mail.checkedOut(c, id);
    if (departure < b.departure) promote(c, p, b.roomTypeId);
    flush(c, p);
    #ok([id])
  };

  /// A guest in house moves to a free room of the same type (a move to another type is another price:
  /// a change of the stay, not of the room). The room left is dirty until it is cleaned.
  public func moveRoom(c : St.Ctx, id : Nat, fromRoomId : Nat, toRoomId : Nat) : Out {
    let ?b = St.booking(c.s, id) else return #err(#noSuchBooking({ id }));
    if (b.status != #checkedIn) return #err(#bookingState({ id; state = E.bookingStatusText(b.status); wanted = "checked in" }));
    let ?from = St.room(c.s, fromRoomId) else return #err(#noSuchRoom({ id = fromRoomId }));
    if (from.occupiedBy != id) return #err(#invalid({ what = "The guest is not in room " # Nat.toText(fromRoomId) # "." }));
    if (toRoomId == fromRoomId) return #err(#invalid({ what = "The guest is already in that room." }));
    let ?to = St.room(c.s, toRoomId) else return #err(#noSuchRoom({ id = toRoomId }));
    if (to.roomTypeId != b.roomTypeId) return #err(#roomWrongType({ id = toRoomId; roomTypeId = b.roomTypeId }));
    if (to.status != #active or to.occupiedBy != 0) return #err(#roomNotVacant({ id = toRoomId }));
    // every check has passed; the writes begin
    RowStore.put<R.Room>(c.s.rooms, R.room, fromRoomId, { from with occupiedBy = 0; lastBlock = c.block });
    Hk.vacated(c, fromRoomId);
    RowStore.put<R.Room>(c.s.rooms, R.room, toRoomId, { to with occupiedBy = id; lastBlock = c.block });
    if (b.assignedRoom == fromRoomId) putBooking(c, id, { b with assignedRoom = toRoomId });
    #ok([id, toRoomId])
  };

  /// What is still to pay on the guest's own window: the booking less the other windows, less what is
  /// paid and on its way. For a booking with no other payer: what is outstanding less captures due.
  public func guestOpen(c : St.Ctx, id : Nat, b : R.Booking) : Nat {
    let o = Win.others(c.s, c.x, id);
    let liability = sub(sub(b.charged, o.charges), sub(b.credited, o.credits));
    sub(liability, sub(b.paid, o.paid) + sub(capturesDue(c.s, id), o.due))
  };

  /// Takes what is left on the guest's window, by the guest's card at the desk.
  public func settleAtDesk(c : St.Ctx, id : Nat, a : Cmd.AuthFacts) : Out {
    let ?prop = St.property(c.s) else return #err(#notConfigured);
    let ?b = St.booking(c.s, id) else return #err(#noSuchBooking({ id }));
    if (b.status != #checkedIn and b.status != #confirmed) return #err(#bookingState({ id; state = E.bookingStatusText(b.status); wanted = "confirmed or checked in" }));
    let open = guestOpen(c, id, b);
    if (open == 0) return #err(#invalid({ what = "Nothing is left to pay." }));
    switch (checkAuth(c, prop, a, St.BOOKING_REF_BASE + id, open)) { case (?r) return #err(r); case null {} };
    ignore addPayment(c, id, a.authId, #authorised, a.amount, #done);
    let pid = addPayment(c, id, a.authId, #captured, a.amount, #due);
    #ok([id, pid])
  };

  /// The night audit's no-show: the guest never came. The penalty stands, every night is given back.
  /// With a card on file, what the guarantee's authorisation does not cover of the penalty is charged to
  /// the card, once, by the gateway queue; a card the desk was still waiting for is no longer needed.
  public func noShow(c : St.Ctx, p : Pending, id : Nat, b : R.Booking) {
    releaseNights(c, p, id, b);
    let after = creditTo(c, id, { b with status = #noShow }, b.penalty, true);
    putBooking(c, id, after);
    Mail.arrivedOrNot(c, id);
    switch (St.card(c.x, id)) {
      case (?k) {
        if (k.state == #kept) {
          let open = guestOpen(c, id, after);
          if (open > 0) putCard(c, id, { k with chargeId = addPayment(c, id, 0, #chargedOnFile, open, #due) })
          else putCard(c, id, { k with state = #forgetDue });
        } else if (k.state == #wanted) putCard(c, id, { k with state = #closed });
      };
      case null {};
    };
  };

  // ── the card on file ────────────────────────────────────────────────────────

  public let FORGET_ATTEMPTS : Nat = 3;

  func putCard(c : St.Ctx, id : Nat, k : R.CardOnFile) {
    RowStore.put<R.CardOnFile>(St.later(c.x, St.CARD_TABLE), R.cardOnFile, id, { k with lastBlock = c.block });
  };

  /// A card kept on file for a booking: the gateway's token, the guest's payment it was kept on, agreed in
  /// this block. A card the desk was waiting for keeps the day it was due by.
  func keepCard(c : St.Ctx, id : Nat, token : Nat, firstAuth : Nat, deadline : Nat) {
    putCard(c, id, { token; firstAuth; agreedBlock = c.block; deadline; state = #kept; chargeId = 0; attempts = 0; declinedDay = 0; lastBlock = c.block });
  };

  /// A card the desk was still waiting for, no longer needed.
  func closeWanted(c : St.Ctx, id : Nat) {
    switch (St.card(c.x, id)) { case (?k) { if (k.state == #wanted) putCard(c, id, { k with state = #closed }) }; case null {} };
  };

  /// The booking is settled (checked out or cancelled): its token is to be deleted at the gateway, and a
  /// card still wanted is no longer needed. A no-show's card waits for its charge (`noShow`).
  func releaseCard(c : St.Ctx, id : Nat) {
    switch (St.card(c.x, id)) {
      case (?k) {
        if (k.state == #kept) putCard(c, id, { k with state = #forgetDue })
        else if (k.state == #wanted) putCard(c, id, { k with state = #closed });
      };
      case null {};
    };
  };

  /// A guest gives the address for their booking's messages, sealed in their browser: by the booking's
  /// manage key or the account that holds it.
  public func attachMail(c : St.Ctx, by : Cmd.GuestActor, id : Nat, sealed : Text, lang : E.Lang) : Out {
    let ?b = St.booking(c.s, id) else return #err(#noSuchBooking({ id }));
    if (not mayAct(b, by)) return #err(#notTheOwner);
    Mail.attach(c, id, sealed, lang)
  };

  /// The hotel's card rule turned on: once, by the owner.
  public func requireCardOnFile(c : St.Ctx) : Out {
    if (St.cardRequired(c.x)) return #err(#invalid({ what = "The card rule is already on." }));
    RowStore.put<R.CardPolicy>(St.later(c.x, St.CARD_POLICY_TABLE), R.cardPolicy, St.CARD_POLICY_ID, { fromBlock = c.block; lastBlock = c.block });
    #ok([c.block])
  };

  /// The guest puts a card on file for a booking that has none, from its card link: the guarantee paid
  /// (authorised, and captured at once for a deposit) and the card kept, as at an online confirmation.
  /// a: the booking, b: the capture queued (0: none).
  public func putCardOnFile(c : St.Ctx, by : Cmd.GuestActor, id : Nat, a : Cmd.AuthFacts, token : Nat) : Out {
    let ?prop = St.property(c.s) else return #err(#notConfigured);
    let ?b = St.booking(c.s, id) else return #err(#noSuchBooking({ id }));
    if (not mayAct(b, by)) return #err(#notTheOwner);
    if (b.status != #confirmed) return #err(#bookingState({ id; state = E.bookingStatusText(b.status); wanted = "confirmed" }));
    switch (auditBlocks(c, b.arrival)) { case (?r) return #err(r); case null {} };
    let ?plan = St.plan(c.s, b.planId) else return #err(#noSuchPlan({ id = b.planId }));
    if (plan.guarantee == #prepaidInFull) return #err(#payment({ reason = "A rate paid in advance keeps no card on file." }));
    if (token == 0) return #err(#payment({ reason = "The card was not kept on file." }));
    let deadline = switch (St.card(c.x, id)) {
      case (?k) { if (k.state != #wanted) return #err(#invalid({ what = "The booking's card is " # E.cardStateText(k.state) # "." })); k.deadline };
      case null 0;
    };
    if (b.paid > 0 or authOf(c.s, id) != null) return #err(#invalid({ what = "The booking is already guaranteed." }));
    let stored = St.folioOf(c.s, id);
    let lines = Array.map<(Nat, R.FolioLine), (E.FolioKind, Nat, Nat, Nat)>(stored, func((_, l)) { (l.kind, l.code, l.night, l.amount) });
    let guarantee = guaranteeOfLines(c.x, b.planId, plan, lines, b.arrival, b.departure, b.charged);
    if (guarantee == 0) return #err(#invalid({ what = "The rate's deposit is not set." }));
    switch (checkAuth(c, prop, a, St.BOOKING_REF_BASE + id, guarantee)) { case (?r) return #err(r); case null {} };

    // every check has passed; the writes begin
    ignore addPayment(c, id, a.authId, #authorised, a.amount, #done);
    let captureId = if (plan.guarantee == #deposit) addPayment(c, id, a.authId, #captured, guarantee, #due) else 0;
    keepCard(c, id, token, a.authId, deadline);
    #ok([id, captureId])
  };

  /// What a booking's card link takes when the guest puts a card on file: the guarantee of its rate on
  /// the bill as it stands (0 when the booking waits for no card).
  public func cardLinkDue(c : St.Ctx, id : Nat) : Nat {
    let ?b = St.booking(c.s, id) else return 0;
    let ?k = St.card(c.x, id) else return 0;
    if (k.state != #wanted or b.status != #confirmed) return 0;
    let ?plan = St.plan(c.s, b.planId) else return 0;
    let lines = Array.map<(Nat, R.FolioLine), (E.FolioKind, Nat, Nat, Nat)>(St.folioOf(c.s, id), func((_, l)) { (l.kind, l.code, l.night, l.amount) });
    guaranteeOfLines(c.x, b.planId, plan, lines, b.arrival, b.departure, b.charged)
  };

  /// What the gateway said of a no-show's charge on file. Made: the money is the guest's payment, under
  /// the authorisation the gateway gave it, and settled as a capture is. Declined: it stays outstanding on
  /// the bill for the desk, and the card is not tried again. Either way the token is then forgotten.
  public func chargeOutcome(c : St.Ctx, paymentId : Nat, ok : Bool, authId : Nat) : Out {
    let ?pmt = St.payment(c.s, paymentId) else return #err(#noSuchPayment({ id = paymentId }));
    if (pmt.kind != #chargedOnFile) return #err(#invalid({ what = "Payment " # Nat.toText(paymentId) # " is not a charge on file." }));
    if (pmt.state != #due) return #err(#invalid({ what = "Payment " # Nat.toText(paymentId) # " is " # E.paymentStateText(pmt.state) # "." }));
    let ?k = St.card(c.x, pmt.bookingId) else return #err(#invalid({ what = "The booking has no card on file." }));
    if (k.state != #kept or k.chargeId != paymentId) return #err(#invalid({ what = "The charge is not the card's." }));
    if (ok and (authId == 0 or St.authUsed(c.s, authId))) return #err(#invalid({ what = "The charge names no new authorisation." }));
    let ?b = St.booking(c.s, pmt.bookingId) else return #err(#noSuchBooking({ id = pmt.bookingId }));

    // every check has passed; the writes begin
    putCard(c, pmt.bookingId, { k with state = #forgetDue; declinedDay = if (ok) 0 else Nat.max(c.day, 1) });
    if (not ok) {
      RowStore.put<R.Payment>(c.s.payments, R.payment, paymentId, { pmt with state = #failed; attempts = pmt.attempts + 1; block = c.block });
      return #ok([paymentId, 0]);
    };
    RowStore.put<R.Payment>(c.s.payments, R.payment, paymentId, { pmt with state = #done; gatewayAuth = authId; block = c.block });
    c.s.capturedDone += pmt.amount;
    c.s.paidTotal += pmt.amount;
    putBooking(c, pmt.bookingId, settle(c, pmt.bookingId, { b with paid = b.paid + pmt.amount }, false));
    #ok([paymentId, 1])
  };

  /// What the gateway said when asked to delete a card's token: deleted, or refused (tried at most three
  /// times, then shown to the desk).
  public func cardForgotten(c : St.Ctx, bookingId : Nat, ok : Bool) : Out {
    let ?k = St.card(c.x, bookingId) else return #err(#invalid({ what = "The booking has no card on file." }));
    if (k.state != #forgetDue) return #err(#invalid({ what = "The booking's card is " # E.cardStateText(k.state) # "." }));
    if (ok) { putCard(c, bookingId, { k with state = #forgotten }); return #ok([bookingId, 1]) };
    let attempts = k.attempts + 1;
    putCard(c, bookingId, { k with attempts; state = if (attempts >= FORGET_ATTEMPTS) #forgetFailed else #forgetDue });
    #ok([bookingId, 0])
  };

  // ── the gateway queue ───────────────────────────────────────────────────────

  public func gatewayOutcome(c : St.Ctx, paymentId : Nat, ok : Bool) : Out {
    let ?pmt = St.payment(c.s, paymentId) else return #err(#noSuchPayment({ id = paymentId }));
    if (pmt.state != #due) return #err(#invalid({ what = "Payment " # Nat.toText(paymentId) # " is " # E.paymentStateText(pmt.state) # "." }));
    if (not ok) {
      let attempts = pmt.attempts + 1;
      let state : E.PaymentState = if (attempts >= GATEWAY_ATTEMPTS) #failed else #due;
      RowStore.put<R.Payment>(c.s.payments, R.payment, paymentId, { pmt with attempts; state; block = c.block });
      return #ok([paymentId, 0]);
    };
    RowStore.put<R.Payment>(c.s.payments, R.payment, paymentId, { pmt with state = #done; block = c.block });
    if (pmt.kind == #captured) {
      c.s.capturedDone += pmt.amount;
      switch (St.booking(c.s, pmt.bookingId)) {
        case (?b) {
          c.s.paidTotal += pmt.amount;
          // a capture that lands after the liability fell is handed straight back
          putBooking(c, pmt.bookingId, settle(c, pmt.bookingId, { b with paid = b.paid + pmt.amount }, false));
        };
        case null {};
      };
    };
    #ok([paymentId, 1])
  };

  // ── the waitlist ────────────────────────────────────────────────────────────

  public func joinWaitlist(c : St.Ctx, account : Principal, stay : Cmd.Stay) : Out {
    // the stay is checked on the house rate, the plan an offer is made on (see promote)
    let ?planId = firstActivePlan(c.s, c.x) else return #err(#invalid({ what = "The hotel has no active rate plan to offer a room on." }));
    switch (checkStay(c, newPending(), { stay with planId }, null, Acc.PUBLIC)) {
      case (#ok _) return #err(#invalid({ what = "Rooms are available for these dates: book them instead of waiting." }));
      case (#err (#soldOut _)) {};
      case (#err r) return #err(r);
    };
    let waiting = St.prefixRows<R.WaitEntry>(c.s.waitlist, R.waitlist, "waiting_by_type", SR.key(stay.roomTypeId, W.ID), W.ID, St.MAX_WAITLIST_PER_TYPE + 1);
    if (waiting.size() >= St.MAX_WAITLIST_PER_TYPE) return #err(#waitlistFull({ roomTypeId = stay.roomTypeId; max = St.MAX_WAITLIST_PER_TYPE }));
    for ((eid, w) in waiting.vals()) {
      if (w.account == account and w.arrival == stay.arrival) return #err(#alreadyWaiting({ entryId = eid }));
    };
    let id = c.s.nextWaitId;
    c.s.nextWaitId += 1;
    RowStore.put<R.WaitEntry>(c.s.waitlist, R.waitlist, id, {
      account; roomTypeId = stay.roomTypeId; arrival = stay.arrival; nights = stay.nights; rooms = stay.rooms;
      adults = stay.adults; children = stay.children; state = #waiting; offeredHold = 0; lastBlock = c.block;
    });
    #ok([id])
  };

  public func leaveWaitlist(c : St.Ctx, account : Principal, id : Nat) : Out {
    let ?w = St.waitEntry(c.s, id) else return #err(#noSuchWaitEntry({ id }));
    if (w.account != account) return #err(#notTheOwner);
    if (w.state == #left) return #err(#invalid({ what = "You have already left this waitlist." }));
    let p = newPending();
    if (w.state == #offered) {
      switch (St.hold(c.s, w.offeredHold)) {
        case (?h) { if (h.state == #live) endHold(c, p, w.offeredHold, h, #released) };
        case null {};
      };
    };
    RowStore.put<R.WaitEntry>(c.s.waitlist, R.waitlist, id, { w with state = #left; lastBlock = c.block });
    promote(c, p, w.roomTypeId);
    flush(c, p);
    #ok([id])
  };

  /// Offer freed rooms to the waitlist, first come first served. Every waiting entry of the room type
  /// is looked at (a room type's waitlist is bounded), in the order they joined; an entry whose whole
  /// stay now fits is offered a hold, and an entry that does not fit is passed over, because a
  /// different stay is a different resource. When two entries want the same freed room the earlier
  /// one gets it: the later one is checked against the counters the earlier offer already took.
  public func promote(c : St.Ctx, p : Pending, rt : Nat) {
    let ?prop = St.property(c.s) else return;
    let waiting = St.prefixRows<R.WaitEntry>(c.s.waitlist, R.waitlist, "waiting_by_type", SR.key(rt, W.ID), W.ID, St.MAX_WAITLIST_PER_TYPE);
    for ((eid, w) in waiting.vals()) {
      let stay : Cmd.Stay = { roomTypeId = w.roomTypeId; planId = 0; arrival = w.arrival; nights = w.nights; rooms = w.rooms; adults = w.adults; children = w.children };
      // an offer is made on the house rate: the first active plan
      switch (firstActivePlan(c.s, c.x)) {
        case (?planId) {
          switch (checkStay(c, p, { stay with planId }, null, Acc.PUBLIC)) {
            case (#ok ch) {
              let hid = writeHold(c, p, w.account, NO_KEY, { stay with planId }, ch, prop.holdTtlHeights * 4, eid);
              RowStore.put<R.WaitEntry>(c.s.waitlist, R.waitlist, eid, { w with state = #offered; offeredHold = hid; lastBlock = c.block });
            };
            case (#err _) {};
          };
        };
        case null {};
      };
    };
  };

  /// The plan a waitlist offer is made on: the first active plan on public sale.
  public func firstActivePlan(s : St.Stores, x : St.Later) : ?Nat {
    let pg = RowStore.pageById<R.RatePlan>(s.plans, R.ratePlan, 1, St.MAX_PLANS, null, St.MAX_PLANS);
    for ((id, pl) in pg.rows.vals()) { if (pl.active and Acc.onPublicSale(x, id)) return ?id };
    null
  };
}
