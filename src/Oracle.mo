/// Oracle.mo - the hotel's laws, recomputed from raw rows, one bounded page at a time.
///
/// Each section walks one table in pages; every law it checks is local to the page it reads, so a
/// page is a consistent verdict at the block that read it and the walk can span messages. The one
/// global identity (the cash law) is kept by counters the fold maintains beside the rows, and checked
/// here as those counters; the independent reader recomputes it from the payments themselves.
///
/// An empty report is the proof only if something was examined: every page says how much it looked at.
///
///   I1 capacity     sold + held ≤ allotment ≤ the type's rooms in service that night (a room out of
///                   order with dates counts from its first night back), on every night from today
///   I2 counters     a night's sold and held equal the bookings and live holds that cover it
///   I3 nights       every booking that holds nights has a row for each of them
///   I4 money        charged = paid + credited + outstanding; charged and credited are the sums of the
///                   booking's own lines; paid is what its payments say
///   I5 cash         the sum of paid equals captured less committed refunds; and a refund to a guest
///                   goes back across the guest's own cards: no card gives back more than it captured;
///                   a settle's slices sum to the excess it split; read at the block that wrote them,
///                   the slices take the newest card first, each but the last draws its card to nothing,
///                   no newer card with money left is passed over, none goes to a card that had refused
///                   a refund, and the desk is sent only what no card could take
///   I6 restrictions a booking's length was within the stay limits it was accepted under
///   I7 indexes      each booking and hold is in the partial indexes its state puts it in
///   I8 rooms        an occupied room holds a checked-in booking of its type, and a checked-in
///                   booking occupies exactly its number of rooms
///   I9 waitlist     nobody waits for a stay that could be offered now
///   I10 housekeeping every record is for a room that exists; a clean room names its cleaner and an
///                   inspected one an inspector who is not its cleaner, a dirty one neither; dates
///                   out of order belong to a room that is out of order, with a reason, ending after
///                   they began
///   I11 bill        an extra's line is its quantity times its price, its taxes follow it on the same
///                   bill, a void credits exactly the charge and its taxes on that bill; every line and
///                   payment moved to a bill is on that payer's booking; an invoice is numbered in an
///                   unbroken run and its figures are still its bill's, less the credit notes against it;
///                   a credit note is numbered in an unbroken run of its own, names an invoice of its
///                   booking's bill, totals its lines, which are credits on that bill, each against a line
///                   of that booking it may take back, and no line is ever taken back beyond its amount;
///                   it was proposed by one person and approved by another; a refund paid at the desk is
///                   a refund the gateway would not make, with its reference, approved the same way; no
///                   bill of a split booking is paid for more than it owes
///   I12 origin      every booking came one way: from a hold it confirmed, or taken by staff (by phone,
///                   or a walk-in that arrived the day it was taken), never both and never neither
///   I13 figures     a day's figures fit the hotel (rooms sold and out of order within its rooms; the
///                   day's arrivals among its guests in house); its revenue rows by type and plan sum
///                   to its room nights and room revenue, each row under a day that has figures; its
///                   pickup starts where the last day's ended and names bookings that exist; once the
///                   day's audit jobs have run, every room, guest in house and booking made that the
///                   figures were planned from was counted, and while that day is still open the rooms
///                   sold are the rooms of the guests in house now
///   I15 blocks      a group block holds its rooms on every night of its dates: each of its nights has its
///                   row on the hotel's night; a night's rooms picked up are the rooms of the block's
///                   bookings that hold it, never more than the block's rooms; what it still holds is
///                   its rooms less those while it is open, and nothing once released; a hotel night's
///                   rooms held by blocks are the sum of its block nights; a pickup is the block's room
///                   type and plan within its dates, taken by staff from the group's list, and every
///                   booking taken from a group's list was picked up from a block; the block's room
///                   type, plan and company exist and its cut-off is on or before its arrival.
///                   (I1 counts the rooms blocks hold with the sold and held.)
///   I14 rates       a closed rate is sold only under an access it admits: a booking or hold on a plan
///                   whose access was last set before it carries the company the plan is closed to, or a
///                   promotion naming the plan when it is closed to everyone but codes; the access a
///                   booking or hold was sold under is never the public sale, names a company or a
///                   promotion that exists (never both), and was kept in the block that made the booking;
///                   a booking from a hold keeps the hold's access; a promotion's uses are its bookings:
///                   each booking under it carries a use from 1 to the promotion's count, found under its
///                   own number, with the use before it present, and the last use counted is present; no
///                   promotion is used beyond its limit; every company's and promotion's code is well formed,
///                   found under its own index and not the other's; a plan named for a company is closed
///                   and the company exists; a promotion's plan exists and its windows are in order
///   I18 packages    a package line is an extra of its booking sold with the room (its charge names no
///                   member of staff), its charge the inclusion's extra, quantity, price and tax lines, and
///                   no tax line on an extra that was not taxed; while its booking is confirmed or in house,
///                   each package line standing is on a night of the stay (an arrival-night inclusion on
///                   the arrival), no inclusion is on one night twice, and an every-night inclusion is on
///                   the nights either side of it within the stay; a hold's package line is an extra of
///                   the hold, its tax lines after it, untaxed when its extra was not; a plan's inclusion
///                   is under its plan and slot, and one on sale names a plan and an extra that exist,
///                   with a quantity from 1 to the most an inclusion gives
///   I16 card on file a card kept is the gateway's token on a payment the guest made, agreed before any
///                   charge on it; it is charged only for a no-show, never past the penalty less what the
///                   guarantee covered; it is forgotten (or on its way) once its booking is settled; a card
///                   still wanted is a confirmed booking's; a charge on file is its card's charge; a deposit
///                   plan has its share, a whole percentage from 1% to 99%
///   I17 mail        every message owed is a booking's with an address, the one its address names for its
///                   kind (so each kind at most once), tried at most three times, sent at most once, failed
///                   only after the third try and with a reason; a receipt is owed only for a stay checked
///                   out, a cancellation only for a cancelled booking, a pre-arrival note still due only for
///                   a booking still to arrive; every address has its confirmation, a cancelled booking's its
///                   cancellation and a checked-out stay's its receipt, and is sealed (never an address in
///                   the clear); guest email is on only with an account the relay tested, and the relay's
///                   key holds its mailer grant. No outbox row has a field that could hold an address, a
///                   name or a key (tools/outcall_and_secrets.sh)
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Blob "mo:core/Blob";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Text "mo:core/Text";

import BatchCore "mo:kernel/batch/BatchCore";
import Page "mo:kernel/rows/Page";
import RowStore "mo:kernel/rows/RowStore";
import SR "mo:kernel/rows/StableRows";

import Blocks "Blocks";
import CN "CreditNote";
import E "Enums";
import Mail "Mail";
import R "Rows";
import Res "Reservations";
import RP "RateProducts";
import Rules "Rules";
import St "Store";
import Staff "Staff";
import TA "TextArena";
import Win "Windows";
import W "Widths";

module {

  public let INVARIANTS : Nat = 18;
  /// nights, bookings, holds, rooms, waitlist, housekeeping, charges, line routes, payment routes,
  /// invoices, credit notes, desk refunds, staff bookings, day figures, day revenue, refund slices,
  /// booking rates, hold rates, companies, plan access, promotions, blocks, block-held nights, pickups,
  /// package lines, hold package lines, plan inclusions, cards on file, plan deposits, the outbox, mail
  /// addresses and guest email's setup (the cash law rides with every page)
  public let SECTIONS : Nat = 31;

  public type Violation = { rule : Text; detail : Text };

  public type PageReport = { violations : [Violation]; examined : Nat; next : ?Blob; done : Bool };

  func v(out : List.List<Violation>, rule : Text, detail : Text) { List.add(out, { rule; detail }) };

  public func cash(s : St.Stores, out : List.List<Violation>) {
    let held : Int = s.capturedDone - s.refundsCommitted;
    if (s.paidTotal != held) v(out, "I5 cash", "paid " # Nat.toText(s.paidTotal) # " but captured less refunded is " # debug_show held);
  };

  /// One page of one section.
  public func page(c : St.Ctx, section : Nat, cursor : ?Blob, limit : Nat) : PageReport {
    let out = List.empty<Violation>();
    cash(c.s, out);
    let lim = Page.clampLimit(Nat.min(limit, 200));
    let (examined, next) = switch section {
      case 0 nights(c, cursor, lim, out);
      case 1 bookings(c, cursor, lim, out);
      case 2 holds(c, cursor, lim, out);
      case 3 rooms(c, cursor, lim, out);
      case 4 waiting(c, cursor, lim, out);
      case 5 housekeeping(c, cursor, lim, out);
      case 6 charges(c, cursor, lim, out);
      case 7 lineRoutes(c, cursor, lim, out);
      case 8 paymentRoutes(c, cursor, lim, out);
      case 9 invoices(c, cursor, lim, out);
      case 10 creditNotes(c, cursor, lim, out);
      case 11 deskRefunds(c, cursor, lim, out);
      case 12 staffBookings(c, cursor, lim, out);
      case 13 dayFigures(c, cursor, lim, out);
      case 14 dayRevenue(c, cursor, lim, out);
      case 15 refundSlices(c, cursor, lim, out);
      case 16 bookingRates(c, cursor, lim, out);
      case 17 holdRates(c, cursor, lim, out);
      case 18 companies(c, cursor, lim, out);
      case 19 planAccess(c, cursor, lim, out);
      case 20 promos(c, cursor, lim, out);
      case 21 blocks(c, cursor, lim, out);
      case 22 nightBlocks(c, cursor, lim, out);
      case 23 pickups(c, cursor, lim, out);
      case 24 packageLines(c, cursor, lim, out);
      case 25 holdPackages(c, cursor, lim, out);
      case 26 inclusions(c, cursor, lim, out);
      case 27 cards(c, cursor, lim, out);
      case 28 deposits(c, cursor, lim, out);
      case 29 outbox(c, cursor, lim, out);
      case 30 mailAddresses(c, cursor, lim, out);
      case _ (0, null);
    };
    { violations = List.toArray(out); examined; next; done = next == null }
  };

  func nights(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let s = c.s;
    let maxStay = switch (St.property(s)) { case (?p) p.maxStayNights; case null 255 };
    let pg = RowStore.pageById<R.Night>(s.nights, R.night, 0, St.pow256(R.NIGHT_ID_BYTES) - 1, cursor, lim);
    // group the page by room type so the covering bookings and holds are read once per type
    let byType = Map.empty<Nat, List.List<(Nat, R.Night)>>();
    for ((id, n) in pg.rows.vals()) {
      let rt = R.nightRoomType(id);
      let l = switch (Map.get(byType, Nat.compare, rt)) { case (?l) l; case null { let l = List.empty<(Nat, R.Night)>(); Map.add(byType, Nat.compare, rt, l); l } };
      List.add(l, (R.nightDay(id), n));
    };
    for ((rt, list) in Map.entries(byType)) {
      let rooms = St.inService(s, c.x, rt);
      // epoch 0 checks I1 as the first released build did: rooms active today, no rooms held by blocks
      let newer = Rules.from(c.x, Rules.LAWS_FROM);
      let activeNow = if newer 0 else St.activeRooms(s, rt);
      var lo = 16_777_215; var hi = 0;
      for ((d, _) in List.values(list)) { if (d < lo) lo := d; if (d > hi) hi := d };
      let from : Nat = if (lo > maxStay) lo - maxStay else 0;
      let sold = Map.empty<Nat, Nat>();
      let held = Map.empty<Nat, Nat>();
      for ((_, b) in St.rangeRows<R.Booking>(s.bookings, R.booking, "by_arrival", SR.key2(from, W.DAY, 0, W.ID), SR.key2(hi, W.DAY, St.MAX_ID, W.ID)).vals()) {
        if (b.roomTypeId == rt and E.holdsNights(b.status)) {
          var d = b.arrival;
          while (d < b.departure) { Map.add(sold, Nat.compare, d, b.rooms + (switch (Map.get(sold, Nat.compare, d)) { case (?x) x; case null 0 })); d += 1 };
        };
      };
      for ((_, h) in St.rangeRows<R.Hold>(s.holds, R.hold, "live_by_arrival", SR.key2(from, W.DAY, 0, W.ID), SR.key2(hi, W.DAY, St.MAX_ID, W.ID)).vals()) {
        if (h.roomTypeId == rt) {
          var d = h.arrival;
          while (d < h.arrival + h.nights) { Map.add(held, Nat.compare, d, h.rooms + (switch (Map.get(held, Nat.compare, d)) { case (?x) x; case null 0 })); d += 1 };
        };
      };
      for ((d, n) in List.values(list)) {
        let at = "room type " # Nat.toText(rt) # ", day " # Nat.toText(d);
        if (newer) {
          let blocked = St.blockedOn(c.x, rt, d);
          if (n.sold + n.held + blocked > n.allotment) {
            v(out, "I1 capacity", at # ": sold " # Nat.toText(n.sold) # " + held " # Nat.toText(n.held) # " + held by blocks " # Nat.toText(blocked) # " > allotment " # Nat.toText(n.allotment));
          };
          if (n.allotment > St.inServiceOn(rooms, d) and d >= c.day) v(out, "I1 capacity", at # ": allotment " # Nat.toText(n.allotment) # " > rooms in service " # Nat.toText(St.inServiceOn(rooms, d)));
        } else {
          if (n.sold + n.held > n.allotment) v(out, "I1 capacity", at # ": sold " # Nat.toText(n.sold) # " + held " # Nat.toText(n.held) # " > allotment " # Nat.toText(n.allotment));
          if (n.allotment > activeNow and d >= c.day) v(out, "I1 capacity", at # ": allotment " # Nat.toText(n.allotment) # " > active rooms " # Nat.toText(activeNow));
        };
        let s2 = switch (Map.get(sold, Nat.compare, d)) { case (?x) x; case null 0 };
        let h2 = switch (Map.get(held, Nat.compare, d)) { case (?x) x; case null 0 };
        if (s2 != n.sold) v(out, "I2 counters", at # ": sold says " # Nat.toText(n.sold) # ", bookings sum to " # Nat.toText(s2));
        if (h2 != n.held) v(out, "I2 counters", at # ": held says " # Nat.toText(n.held) # ", live holds sum to " # Nat.toText(h2));
      };
    };
    (pg.examined, pg.next)
  };

  func inIndex<Row>(store : RowStore.Store, decl : RowStore.Decl<Row>, index : Text, key : Blob, id : Nat) : Bool {
    switch (RowStore.page<Row>(store, decl, index, key, key, null, 1)) {
      case (#ok p) { p.rows.size() == 1 and p.rows[0].0 == id };
      case (#err _) false;
    }
  };

  func bookings(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let s = c.s;
    let pg = RowStore.pageById<R.Booking>(s.bookings, R.booking, 0, St.MAX_ID, cursor, lim);
    // the laws this page gained after the first released build (I16, I11, I12, I14) hold from epoch 1
    let newer = Rules.from(c.x, Rules.LAWS_FROM);
    for ((id, b) in pg.rows.vals()) {
      let at = "booking " # Nat.toText(id);
      // I3
      if (E.holdsNights(b.status)) {
        let rows = St.nightsRange(s, b.roomTypeId, b.arrival, b.departure);
        var i = 0;
        while (i < rows.size()) { if (rows[i] == null) v(out, "I3 nights", at # " holds day " # Nat.toText(b.arrival + i) # ", which has no row"); i += 1 };
      };
      // I4
      var charged = 0; var credited = 0;
      for ((_, l) in St.folioOf(s, id).vals()) { if (E.isCredit(l.kind)) credited += l.amount else charged += l.amount };
      var paid : Int = 0;
      for ((_, p) in St.paymentsOf(s, id).vals()) {
        switch (p.kind) {
          case (#captured or #chargedOnFile) { if (p.state == #done) paid += p.amount };
          case (#refunded) paid -= p.amount;
          case _ {};
        };
      };
      if (charged != b.charged) v(out, "I4 money", at # ": charged " # Nat.toText(b.charged) # ", its lines sum to " # Nat.toText(charged));
      if (credited != b.credited) v(out, "I4 money", at # ": credited " # Nat.toText(b.credited) # ", its lines sum to " # Nat.toText(credited));
      if (paid != b.paid) v(out, "I4 money", at # ": paid " # Nat.toText(b.paid) # ", its payments say " # debug_show paid);
      // I16: a charge on file is the one its booking's card was charged for, never another
      if (newer) for ((pid, p) in St.paymentsOf(s, id).vals()) {
        if (p.kind == #chargedOnFile) {
          switch (St.card(c.x, id)) {
            case (?k) { if (k.chargeId != pid) v(out, "I16 card on file", at # ": charge on file " # Nat.toText(pid) # " is not its card's charge") };
            case null v(out, "I16 card on file", at # ": charge on file " # Nat.toText(pid) # " rests on no card");
          };
        };
      };
      if (b.charged != b.paid + b.credited + b.outstanding) v(out, "I4 money", at # ": charged " # Nat.toText(b.charged) # " is not paid + credited + outstanding");
      // I6
      let nights : Nat = b.departure - b.arrival;
      if (b.status != #checkedOut and b.checkedMinStay > 0 and nights < b.checkedMinStay) v(out, "I6 restrictions", at # " is " # Nat.toText(nights) # " nights under a minimum of " # Nat.toText(b.checkedMinStay));
      if (b.status != #checkedOut and b.checkedMaxStay > 0 and nights > b.checkedMaxStay) v(out, "I6 restrictions", at # " is " # Nat.toText(nights) # " nights over a maximum of " # Nat.toText(b.checkedMaxStay));
      // I7
      if (b.status == #confirmed and not inIndex<R.Booking>(s.bookings, R.booking, "arrivals", SR.key2(b.arrival, W.DAY, id, W.ID), id)) v(out, "I7 indexes", at # " is missing from the arrivals");
      if (b.status == #checkedIn and not inIndex<R.Booking>(s.bookings, R.booking, "in_house", SR.key2(b.departure, W.DAY, id, W.ID), id)) v(out, "I7 indexes", at # " is missing from the guests in house");
      // I11: a split bill's windows, each paid at most what it owes
      if (newer and St.payersOf(c.x, id).size() > 0) {
        for (w in Win.all(s, c.x, id).vals()) {
          if (w.paid > Win.liability(w)) v(out, "I11 bill", at # ": the bill of payer " # Nat.toText(w.payerId) # " is paid " # Nat.toText(w.paid) # " and owes " # Nat.toText(Win.liability(w)));
        };
      };
      // I12: from a hold it confirmed, or taken by staff
      if (newer) switch (b.holdId, St.staffBooking(c.x, id)) {
        case (0, null) v(out, "I12 origin", at # " came from no hold and was not taken by staff");
        case (0, ?_) {};
        case (h, ?_) v(out, "I12 origin", at # " came from hold " # Nat.toText(h) # " and was also taken by staff");
        case (h, null) {
          switch (St.hold(s, h)) {
            case (?x) { if (x.state != #confirmed) v(out, "I12 origin", at # " came from hold " # Nat.toText(h) # ", which is " # E.holdStateText(x.state)) };
            case null v(out, "I12 origin", at # " came from hold " # Nat.toText(h) # ", which does not exist");
          };
        };
      };
      // I14: on a plan whose access was set before the booking was made, the booking carries an access it admits
      let kept = St.bookingRate(c.x, id);
      let (gc, gp) = switch kept { case (?r) (r.companyId, r.promoId); case null (0, 0) };
      if (newer) switch (St.planAccess(c.x, b.planId)) {
        case (?a) { if (a.lastBlock < b.createdBlock and not fits(c, b.planId, a, gc, gp)) v(out, "I14 rates", at # " is on plan " # Nat.toText(b.planId) # ", closed " # closedTo(a) # ", and was sold " # soldUnder(gc, gp)) };
        case null {};
      };
      // I14: a booking from a hold keeps the access the hold was placed under
      if (newer and b.holdId != 0) {
        let (hc, hp) = switch (St.holdRate(c.x, b.holdId)) { case (?r) (r.companyId, r.promoId); case null (0, 0) };
        if (hc != gc or hp != gp) v(out, "I14 rates", at # " was sold " # soldUnder(gc, gp) # "; its hold " # Nat.toText(b.holdId) # " was placed " # soldUnder(hc, hp));
      };
      // I8
      if (b.status == #checkedIn) {
        let (lo, hi) = SR.prefixRange(b.roomTypeId, W.ID, W.ID);
        var occupied = 0;
        for ((_, r) in St.rangeRows<R.Room>(s.rooms, R.room, "by_type", lo, hi).vals()) { if (r.occupiedBy == id) occupied += 1 };
        if (occupied != b.rooms) v(out, "I8 rooms", at # " occupies " # Nat.toText(occupied) # " rooms and booked " # Nat.toText(b.rooms));
      };
    };
    (pg.examined, pg.next)
  };

  func holds(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let pg = RowStore.pageById<R.Hold>(c.s.holds, R.hold, 0, St.MAX_ID, cursor, lim);
    for ((id, h) in pg.rows.vals()) {
      if (h.state == #live and not inIndex<R.Hold>(c.s.holds, R.hold, "live_by_expiry", SR.key2(h.expiresAt, W.HEIGHT, id, W.ID), id)) {
        v(out, "I7 indexes", "live hold " # Nat.toText(id) # " is missing from the expiry index, so it would never end");
      };
    };
    (pg.examined, pg.next)
  };

  func rooms(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let pg = RowStore.pageById<R.Room>(c.s.rooms, R.room, 0, St.MAX_ID, cursor, lim);
    for ((id, r) in pg.rows.vals()) {
      if (r.occupiedBy != 0) {
        switch (St.booking(c.s, r.occupiedBy)) {
          case (?b) {
            if (b.status != #checkedIn or b.roomTypeId != r.roomTypeId) v(out, "I8 rooms", "room " # Nat.toText(id) # " is held by booking " # Nat.toText(r.occupiedBy) # ", which is not checked in to this room type");
          };
          case null v(out, "I8 rooms", "room " # Nat.toText(id) # " is held by a booking that does not exist");
        };
      } else if (r.status == #active and not inIndex<R.Room>(c.s.rooms, R.room, "vacant_by_type", SR.key2(r.roomTypeId, W.ID, id, W.ID), id)) {
        v(out, "I7 indexes", "vacant room " # Nat.toText(id) # " is missing from the vacant rooms");
      };
    };
    (pg.examined, pg.next)
  };

  func waiting(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let pg = RowStore.pageById<R.WaitEntry>(c.s.waitlist, R.waitlist, 0, St.MAX_ID, cursor, lim);
    let plan = Res.firstActivePlan(c.s, c.x);
    for ((id, w) in pg.rows.vals()) {
      if (w.state == #waiting and w.arrival >= c.day) {
        switch plan {
          case (?planId) {
            switch (Res.quoteStay(c, { roomTypeId = w.roomTypeId; planId; arrival = w.arrival; nights = w.nights; rooms = w.rooms; adults = w.adults; children = w.children })) {
              case (#ok _) v(out, "I9 waitlist", "entry " # Nat.toText(id) # " waits for a stay that fits now");
              case (#err _) {};
            };
          };
          case null {};
        };
      };
    };
    (pg.examined, pg.next)
  };

  func housekeeping(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let pg = RowStore.pageById<R.Housekeeping>(St.later(c.x, St.HK_TABLE), R.housekeeping, 0, St.MAX_ID, cursor, lim);
    for ((id, h) in pg.rows.vals()) {
      let at = "room " # Nat.toText(id);
      let room = St.room(c.s, id);
      if (room == null) v(out, "I10 housekeeping", at # " has a housekeeping record and does not exist");
      switch (h.cleaning) {
        case (#dirty) { if (h.cleanedBy != null or h.inspectedBy != null) v(out, "I10 housekeeping", at # " is dirty and names a cleaner or an inspector") };
        case (#clean) { if (h.cleanedBy == null or h.inspectedBy != null) v(out, "I10 housekeeping", at # " is clean without its cleaner, or with an inspector") };
        case (#inspected) {
          if (h.cleanedBy == null or h.inspectedBy == null) v(out, "I10 housekeeping", at # " is inspected without both its cleaner and its inspector")
          else if (h.cleanedBy == h.inspectedBy) v(out, "I10 housekeeping", at # " was inspected by the person who cleaned it");
        };
      };
      if (h.outUntil > 0) {
        switch room { case (?r) { if (r.status != #outOfOrder) v(out, "I10 housekeeping", at # " has dates out of order and is in service") }; case null {} };
        if (h.outFrom >= h.outUntil) v(out, "I10 housekeeping", at # " is out of order until day " # Nat.toText(h.outUntil) # ", which is not after it went out");
        if (h.outReason.length == 0) v(out, "I10 housekeeping", at # " is out of order with no reason");
      };
    };
    (pg.examined, pg.next)
  };

  func payerOf(c : St.Ctx, bookingId : Nat, payerId : Nat) : Bool {
    if (payerId == 0) return true;
    switch (St.payer(c.x, payerId)) { case (?p) p.bookingId == bookingId; case null false }
  };

  func charges(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let pg = RowStore.pageById<R.Charge>(St.later(c.x, St.CHARGE_TABLE), R.charge, 0, St.MAX_ID, cursor, lim);
    for ((id, ch) in pg.rows.vals()) {
      let at = "charge on line " # Nat.toText(id);
      switch (St.folioLine(c.s, id)) {
        case (?l) {
          if (l.kind != #extra or l.bookingId != ch.bookingId) v(out, "I11 bill", at # " is not an extra of booking " # Nat.toText(ch.bookingId));
          if (l.amount != ch.quantity * ch.unitAmount) v(out, "I11 bill", at # " is " # Nat.toText(l.amount) # ", and " # Nat.toText(ch.quantity) # " × " # Nat.toText(ch.unitAmount) # " is " # Nat.toText(ch.quantity * ch.unitAmount));
          let window = St.lineWindow(c.x, id);
          var total = l.amount;
          for (t in Nat.range(id + 1, id + ch.taxLines + 1)) {
            switch (St.folioLine(c.s, t)) {
              case (?tl) {
                if (tl.kind != #extraTax or tl.bookingId != ch.bookingId or tl.night != l.night or St.lineWindow(c.x, t) != window) v(out, "I11 bill", at # ": line " # Nat.toText(t) # " is not its tax on its bill");
                total += tl.amount;
              };
              case null v(out, "I11 bill", at # ": its tax line " # Nat.toText(t) # " does not exist");
            };
          };
          if (ch.voidLine != 0) {
            switch (St.folioLine(c.s, ch.voidLine)) {
              case (?vl) {
                if (vl.kind != #credit or vl.bookingId != ch.bookingId or vl.amount != total or St.lineWindow(c.x, ch.voidLine) != window)
                  v(out, "I11 bill", at # " is voided by line " # Nat.toText(ch.voidLine) # ", which is not a credit of " # Nat.toText(total) # " on its bill");
              };
              case null v(out, "I11 bill", at # " is voided by a line that does not exist");
            };
          };
        };
        case null v(out, "I11 bill", at # ": the line does not exist");
      };
    };
    (pg.examined, pg.next)
  };

  func lineRoutes(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let pg = RowStore.pageById<R.Route>(St.later(c.x, St.LINE_ROUTE_TABLE), R.lineRoute, 0, St.MAX_ID, cursor, lim);
    for ((id, r) in pg.rows.vals()) {
      switch (St.folioLine(c.s, id)) {
        case (?l) { if (not payerOf(c, l.bookingId, r.payerId)) v(out, "I11 bill", "line " # Nat.toText(id) # " is on the bill of payer " # Nat.toText(r.payerId) # ", who is not on its booking") };
        case null v(out, "I11 bill", "a route for line " # Nat.toText(id) # ", which does not exist");
      };
    };
    (pg.examined, pg.next)
  };

  func paymentRoutes(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let pg = RowStore.pageById<R.Route>(St.later(c.x, St.PAYMENT_ROUTE_TABLE), R.paymentRoute, 0, St.MAX_ID, cursor, lim);
    for ((id, r) in pg.rows.vals()) {
      switch (St.payment(c.s, id)) {
        case (?p) { if (not payerOf(c, p.bookingId, r.payerId)) v(out, "I11 bill", "payment " # Nat.toText(id) # " is on the bill of payer " # Nat.toText(r.payerId) # ", who is not on its booking") };
        case null v(out, "I11 bill", "a route for payment " # Nat.toText(id) # ", which does not exist");
      };
    };
    (pg.examined, pg.next)
  };

  func invoices(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let table = St.later(c.x, St.INVOICE_TABLE);
    let pg = RowStore.pageById<R.Invoice>(table, R.invoice, 0, St.MAX_ID, cursor, lim);
    for ((n, inv) in pg.rows.vals()) {
      let at = "invoice " # Nat.toText(n);
      // numbers are their table's size plus one when written and rows are never removed: a number past
      // the count is a gap below it
      if (n == 0 or n > RowStore.size(table)) v(out, "I11 bill", at # " is past the " # Nat.toText(RowStore.size(table)) # " invoices issued");
      if (not payerOf(c, inv.bookingId, inv.payerId)) v(out, "I11 bill", at # " is for a payer who is not on booking " # Nat.toText(inv.bookingId));
      // a credit note credits the invoiced bill and leaves the invoice as issued: the bill's credits are
      // the invoice's and its notes'
      var noted = 0;
      for ((_, cn) in St.notesOf(c.x, n).vals()) noted += cn.total;
      switch (Win.of(c.s, c.x, inv.bookingId, inv.payerId)) {
        case (?w) {
          if (w.charges != inv.charges or w.credits != inv.credits + noted or w.taxes != inv.taxes)
            v(out, "I11 bill", at # " says " # Nat.toText(inv.charges) # "/" # Nat.toText(inv.credits) # " with " # Nat.toText(noted) # " in credit notes, and its bill is now " # Nat.toText(w.charges) # "/" # Nat.toText(w.credits));
        };
        case null v(out, "I11 bill", at # ": its bill does not exist");
      };
    };
    (pg.examined, pg.next)
  };

  /// An act that needs four eyes was proposed by one person and approved by another, under the permission
  /// it names.
  func approvedAs(c : St.Ctx, proposal : Nat, guard : Text) : Bool {
    switch (St.proposal(c.s, proposal)) {
      case (?p) p.status == #executed and Staff.guardOf(p.permission) == guard and (switch (p.checker) { case (?k) k != p.maker; case null false });
      case null false;
    }
  };

  func creditNotes(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let table = St.later(c.x, St.CREDIT_NOTE_TABLE);
    let pg = RowStore.pageById<R.CreditNote>(table, R.creditNote, 0, St.MAX_ID, cursor, lim);
    for ((n, cn) in pg.rows.vals()) {
      let at = "credit note " # Nat.toText(n);
      if (n == 0 or n > RowStore.size(table)) v(out, "I11 bill", at # " is past the " # Nat.toText(RowStore.size(table)) # " credit notes issued");
      switch (St.invoice(c.x, cn.invoice)) {
        case (?inv) { if (inv.bookingId != cn.bookingId or inv.payerId != cn.payerId) v(out, "I11 bill", at # " is against invoice " # Nat.toText(cn.invoice) # ", which is another bill's") };
        case null v(out, "I11 bill", at # " is against invoice " # Nat.toText(cn.invoice) # ", which does not exist");
      };
      if (cn.total != cn.net + cn.taxes) v(out, "I11 bill", at # " totals " # Nat.toText(cn.total) # ", and " # Nat.toText(cn.net) # " + " # Nat.toText(cn.taxes) # " is " # Nat.toText(cn.net + cn.taxes));
      if (not approvedAs(c, cn.proposal, "propose:issueCreditNote")) v(out, "I11 bill", at # " was not approved by a second person (proposal " # Nat.toText(cn.proposal) # ")");
      var sum = 0;
      var taxSum = 0;
      if (cn.lines == 0) v(out, "I11 bill", at # " has no lines");
      for (id in Nat.range(cn.firstLine, cn.firstLine + cn.lines)) {
        let lat = at # ", line " # Nat.toText(id);
        switch (St.folioLine(c.s, id), St.creditLine(c.x, id)) {
          case (?l, ?cl) {
            if (l.kind != #credit or l.code != CN.CREDIT_NOTE_CODE or l.bookingId != cn.bookingId or St.lineWindow(c.x, id) != cn.payerId or cl.note != n)
              v(out, "I11 bill", lat # " is not one of its credits on its bill");
            sum += l.amount;
            switch (St.folioLine(c.s, cl.source)) {
              case (?src) {
                if (src.bookingId != cn.bookingId or not (CN.reversible(src.kind) or CN.isTax(src.kind)))
                  v(out, "I11 bill", lat # " takes back line " # Nat.toText(cl.source) # ", which is not a charge of its booking");
                if (CN.isTax(src.kind)) taxSum += l.amount;
                let taken = St.creditedOf(c.s, c.x, cl.source);
                if (taken > src.amount) v(out, "I11 bill", "line " # Nat.toText(cl.source) # " is " # Nat.toText(src.amount) # " and credit notes have taken back " # Nat.toText(taken));
              };
              case null v(out, "I11 bill", lat # " takes back line " # Nat.toText(cl.source) # ", which does not exist");
            };
          };
          case _ v(out, "I11 bill", lat # " is missing, or is not recorded as one of its credits");
        };
      };
      if (sum != cn.total or taxSum != cn.taxes)
        v(out, "I11 bill", at # " says " # Nat.toText(cn.total) # " (taxes " # Nat.toText(cn.taxes) # "), and its lines are " # Nat.toText(sum) # " (taxes " # Nat.toText(taxSum) # ")");
    };
    (pg.examined, pg.next)
  };

  func deskRefunds(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let pg = RowStore.pageById<R.DeskRefund>(St.later(c.x, St.DESK_REFUND_TABLE), R.deskRefund, 0, St.MAX_ID, cursor, lim);
    for ((id, d) in pg.rows.vals()) {
      let at = "the desk refund of payment " # Nat.toText(id);
      switch (St.payment(c.s, id)) {
        case (?p) {
          if (p.bookingId != d.bookingId or p.kind != #refunded or p.state != #failed)
            v(out, "I11 bill", at # " is not a refund of booking " # Nat.toText(d.bookingId) # " the gateway would not make");
        };
        case null v(out, "I11 bill", at # ": the payment does not exist");
      };
      let n = Text.encodeUtf8(TA.get(c.s.arena, d.reference)).size();
      if (n == 0 or n > CN.MAX_REFERENCE) v(out, "I11 bill", at # " has no reference, or one past " # Nat.toText(CN.MAX_REFERENCE) # " bytes");
      if (not approvedAs(c, d.proposal, "propose:refundAtDesk")) v(out, "I11 bill", at # " was not approved by a second person (proposal " # Nat.toText(d.proposal) # ")");
    };
    (pg.examined, pg.next)
  };

  func staffBookings(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let pg = RowStore.pageById<R.StaffBooking>(St.later(c.x, St.STAFF_BOOKING_TABLE), R.staffBooking, 0, St.MAX_ID, cursor, lim);
    for ((id, x) in pg.rows.vals()) {
      let at = "the staff booking " # Nat.toText(id);
      switch (St.booking(c.s, id)) {
        case (?b) {
          if (b.holdId != 0) v(out, "I12 origin", at # " is of a booking that came from hold " # Nat.toText(b.holdId));
          if (x.channel == #walkIn and b.arrival != x.day) v(out, "I12 origin", at # " is a walk-in arriving on day " # Nat.toText(b.arrival) # ", taken on day " # Nat.toText(x.day));
          if (x.day > c.day) v(out, "I12 origin", at # " was taken on day " # Nat.toText(x.day) # ", after today");
          if ((x.channel == #group) != (St.bookingBlock(c.x, id) != null)) v(out, "I15 blocks", at # " is " # E.channelText(x.channel) # " and " # (if (St.bookingBlock(c.x, id) != null) "was" else "was not") # " picked up from a block");
        };
        case null v(out, "I12 origin", at # ": the booking does not exist");
      };
    };
    (pg.examined, pg.next)
  };

  func dayFigures(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let pg = RowStore.pageById<R.DayFigures>(St.later(c.x, St.DAY_FIGURES_TABLE), R.dayFigures, 0, St.MAX_ID, cursor, lim);
    for ((day, f) in pg.rows.vals()) {
      let at = "the figures of day " # Nat.toText(day);
      if (f.roomsSold + f.roomsOut > f.roomsTotal)
        v(out, "I13 figures", at # " sell " # Nat.toText(f.roomsSold) # " rooms with " # Nat.toText(f.roomsOut) # " out of order, of " # Nat.toText(f.roomsTotal));
      if (f.roomsTotal > RowStore.size(c.s.rooms)) v(out, "I13 figures", at # " count " # Nat.toText(f.roomsTotal) # " rooms; the hotel has " # Nat.toText(RowStore.size(c.s.rooms)));
      if (f.arrivals > f.houseSeen) v(out, "I13 figures", at # " have " # Nat.toText(f.arrivals) # " arrivals among " # Nat.toText(f.houseSeen) # " guests in house");
      if (day > c.day) v(out, "I13 figures", at # " are for a day after today");
      // the night's revenue by type and plan sums to the night's figures
      var nights = 0; var revenue = 0;
      for ((_, r) in St.dayRevenueOf(c.x, day).vals()) { nights += r.roomNights; revenue += r.revenue };
      if (nights != f.roomsSold or revenue != f.roomRevenue)
        v(out, "I13 figures", at # " sell " # Nat.toText(f.roomsSold) # " rooms for " # Nat.toText(f.roomRevenue) # "; its rows by type and plan sum to " # Nat.toText(nights) # " for " # Nat.toText(revenue));
      // pickup is an unbroken run of booking ids from the last day's figures on
      let from = switch (if (day == 0) null else St.dayFigures(c.x, day - 1 : Nat)) { case (?p) ?(p.pickupFrom + p.pickupCount); case null null };
      switch from { case (?x) { if (f.pickupFrom != x) v(out, "I13 figures", at # " count pickup from booking " # Nat.toText(f.pickupFrom) # "; the day before ended at " # Nat.toText(x)) }; case null {} };
      if (f.pickupFrom + f.pickupCount > c.s.nextBookingId) v(out, "I13 figures", at # " count pickup to booking " # Nat.toText(f.pickupFrom + f.pickupCount - 1 : Nat) # ", which does not exist");
      // once the day's jobs have run, everything planned was counted
      let ran = switch (BatchCore.get(c.s.audit, St.AUDIT_SCOPE, day)) { case (?r) r.state == #completed; case null false };
      if (ran) {
        if (f.roomsSeen != f.roomsTotal) v(out, "I13 figures", at # " looked at " # Nat.toText(f.roomsSeen) # " of " # Nat.toText(f.roomsTotal) # " rooms");
        if (f.houseSeen != f.inHouse) v(out, "I13 figures", at # " looked at " # Nat.toText(f.houseSeen) # " of " # Nat.toText(f.inHouse) # " guests in house");
        if (f.pickupBookings != f.pickupCount) v(out, "I13 figures", at # " looked at " # Nat.toText(f.pickupBookings) # " of " # Nat.toText(f.pickupCount) # " bookings made");
        if (day == c.day) {
          // the day is still open and every act dated today waits: the guests in house are the ones counted
          let lo = SR.key2(day + 1, W.DAY, 0, W.ID);
          let hi = SR.key2(16_777_215, W.DAY, St.MAX_ID, W.ID);
          var rooms = 0;
          for ((_, b) in St.rangeRows<R.Booking>(c.s.bookings, R.booking, "in_house", lo, hi).vals()) rooms += b.rooms;
          if (rooms != f.roomsSold) v(out, "I13 figures", at # " sell " # Nat.toText(f.roomsSold) # " rooms; the guests in house hold " # Nat.toText(rooms));
        };
      };
    };
    (pg.examined, pg.next)
  };

  func dayRevenue(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let pg = RowStore.pageById<R.DayRevenue>(St.later(c.x, St.DAY_REVENUE_TABLE), R.dayRevenue, 0, St.MAX_ID, cursor, lim);
    for ((id, r) in pg.rows.vals()) {
      let at = "the revenue row " # Nat.toText(id) # " (day " # Nat.toText(r.day) # ", type " # Nat.toText(r.roomTypeId) # ", plan " # Nat.toText(r.planId) # ")";
      if (St.dayFigures(c.x, r.day) == null) v(out, "I13 figures", at # " is under a day with no figures");
      if (r.roomNights == 0) v(out, "I13 figures", at # " sells no room nights");
      switch (St.dayRevenueRow(c.x, r.day, r.roomTypeId, r.planId)) {
        case (?(first, _)) { if (first != id) v(out, "I13 figures", at # " repeats row " # Nat.toText(first)) };
        case null v(out, "I13 figures", at # " is not found under its own key");
      };
    };
    (pg.examined, pg.next)
  };

  /// The refund slices, page by page. Each slice is checked against its card as it is now (no card
  /// gives back more than it captured); the first slice of each settle checks the whole settle as the
  /// payments stood at the block that wrote it: a capture counts once it was done by that block, a
  /// refund written before the settle counts unless it had failed by that block, and a card had
  /// refused a refund if one on it had failed by then. Only the guest's window is read.
  func refundSlices(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let pg = RowStore.pageById<R.RefundSlice>(St.later(c.x, St.REFUND_SLICE_TABLE), R.refundSlice, 0, St.MAX_ID, cursor, lim);
    label each for ((pid, r) in pg.rows.vals()) {
      let at = "the refund slice " # Nat.toText(pid);
      let ?p = St.payment(c.s, pid) else { v(out, "I5 cash", at # ": the payment does not exist"); continue each };
      if (p.kind != #refunded) v(out, "I5 cash", at # " is not a refund");
      let rows = St.paymentsOf(c.s, p.bookingId);
      func guest(id : Nat) : Bool { St.paymentWindow(c.x, id) == 0 };
      // now: the card has not given back more than it captured
      if (p.gatewayAuth != 0) {
        var cap = 0; var back = 0;
        for ((id, q) in rows.vals()) {
          if (q.gatewayAuth == p.gatewayAuth) {
            if (E.takesMoney(q.kind) and q.state == #done) cap += q.amount;
            if (q.kind == #refunded and q.state != #failed) back += q.amount;
          };
        };
        if (back > cap) v(out, "I5 cash", "card " # Nat.toText(p.gatewayAuth) # " has given back " # Nat.toText(back) # " of the " # Nat.toText(cap) # " it captured");
      };
      if (pid == r.firstSlice) {
        // the settle's slices: the payments from here on that name this one as their first
        let group = List.empty<(Nat, R.Payment)>();
        var id = pid;
        label g loop {
          switch (St.refundSlice(c.x, id), St.payment(c.s, id)) {
            case (?x, ?q) { if (x.firstSlice != pid) break g; List.add(group, (id, q)); id += 1 };
            case _ break g;
          };
        };
        var sum = 0;
        for ((_, q) in List.values(group)) sum += q.amount;
        if (sum != r.excess) v(out, "I5 cash", "the slices of the refund from payment " # Nat.toText(pid) # " sum to " # Nat.toText(sum) # "; it split " # Nat.toText(r.excess));
        // the guest's cards as they stood at the block of the settle
        let W = r.written;
        let cards = Map.empty<Nat, (Nat, Nat, Nat, Bool)>();   // auth -> (captured by W, refunded before, newest capture, refused by W)
        for ((qid, q) in rows.vals()) {
          if (q.gatewayAuth != 0 and guest(qid)) {
            let (cap, back, newest, refused) = switch (Map.get(cards, Nat.compare, q.gatewayAuth)) { case (?x) x; case null (0, 0, 0, false) };
            let next = if (E.takesMoney(q.kind) and q.state == #done and q.block <= W) (cap + q.amount, back, Nat.max(newest, qid), refused)
              else if (q.kind == #refunded and qid < pid and q.state == #failed and q.block <= W) (cap, back, newest, true)
              else if (q.kind == #refunded and qid < pid) (cap, back + q.amount, newest, refused)
              else (cap, back, newest, refused);
            Map.add(cards, Nat.compare, q.gatewayAuth, next);
          };
        };
        let slices = List.toArray(group);
        var lastNewest : ?Nat = null;
        var lastCard : Nat = 0;
        var desk = 0;
        let drawn = Map.empty<Nat, Nat>();
        for (i in slices.keys()) {
          let (sid, q) = slices[i];
          if (q.gatewayAuth == 0) {
            desk += q.amount;
            if (i + 1 != slices.size()) v(out, "I5 cash", "the refund from payment " # Nat.toText(pid) # " sent payment " # Nat.toText(sid) # " to the desk before a card");
            if (q.state != #failed) v(out, "I5 cash", "the refund from payment " # Nat.toText(pid) # " sent payment " # Nat.toText(sid) # " to the desk as a refund the gateway still holds");
          } else {
            let (cap, back, newest, refused) = switch (Map.get(cards, Nat.compare, q.gatewayAuth)) { case (?x) x; case null (0, 0, 0, false) };
            let left = if (cap > back) cap - back : Nat else 0;
            if (refused) v(out, "I5 cash", "payment " # Nat.toText(sid) # " went to card " # Nat.toText(q.gatewayAuth) # ", which had refused a refund");
            if (q.amount > left) v(out, "I5 cash", "payment " # Nat.toText(sid) # " took " # Nat.toText(q.amount) # " from card " # Nat.toText(q.gatewayAuth) # " with " # Nat.toText(left) # " left");
            // every card but the last one drawn is drawn to nothing, and all of them when the desk is sent the rest
            let lastCardSlice = i + 1 == slices.size() or slices[i + 1].1.gatewayAuth == 0;
            let toDesk = slices[slices.size() - 1 : Nat].1.gatewayAuth == 0;
            if (q.amount < left and (not lastCardSlice or toDesk))
              v(out, "I5 cash", "payment " # Nat.toText(sid) # " left " # Nat.toText(left - q.amount : Nat) # " on card " # Nat.toText(q.gatewayAuth) # " before drawing the next");
            switch lastNewest { case (?n) { if (newest >= n) v(out, "I5 cash", "the refund from payment " # Nat.toText(pid) # " drew card " # Nat.toText(lastCard) # " before the newer card " # Nat.toText(q.gatewayAuth)) }; case null {} };
            lastNewest := ?newest; lastCard := q.gatewayAuth;
            Map.add(drawn, Nat.compare, q.gatewayAuth, q.amount);
          };
        };
        // a card with money left that the settle passed over: newer than the last card drawn, or any at all when the desk was sent some
        for ((auth, (cap, back, newest, refused)) in Map.entries(cards)) {
          let left = if (cap > back) cap - back : Nat else 0;
          if (not refused and left > 0 and Map.get(drawn, Nat.compare, auth) == null) {
            if (desk > 0) v(out, "I5 cash", "the refund from payment " # Nat.toText(pid) # " sent " # Nat.toText(desk) # " to the desk while card " # Nat.toText(auth) # " had " # Nat.toText(left) # " left");
            switch lastNewest { case (?n) { if (newest > n) v(out, "I5 cash", "the refund from payment " # Nat.toText(pid) # " skipped the newer card " # Nat.toText(auth)) }; case null {} };
          };
        };
      };
    };
    (pg.examined, pg.next)
  };

  /// Whether an access admits a sale of this plan under this company or promotion: its company, or,
  /// closed to everyone but codes, a promotion that names the plan.
  func fits(c : St.Ctx, planId : Nat, a : R.PlanAccess, companyId : Nat, promoId : Nat) : Bool {
    if (not a.closed) return true;
    if (a.companyId != 0) return companyId == a.companyId;
    promoId != 0 and (switch (St.promo(c.x, promoId)) { case (?p) p.planId == planId; case null false })
  };
  func closedTo(a : R.PlanAccess) : Text { if (a.companyId == 0) "to everyone" else "to company " # Nat.toText(a.companyId) };
  func soldUnder(companyId : Nat, promoId : Nat) : Text {
    if (companyId != 0) "under company " # Nat.toText(companyId) else if (promoId != 0) "under promotion " # Nat.toText(promoId) else "on public sale"
  };

  func bookingRates(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let pg = RowStore.pageById<R.RateGrant>(St.later(c.x, St.BOOKING_RATE_TABLE), R.bookingRate, 0, St.MAX_ID, cursor, lim);
    for ((id, r) in pg.rows.vals()) {
      let at = "the access of booking " # Nat.toText(id);
      kept(c, at, r, out);
      switch (St.booking(c.s, id)) {
        case (?b) { if (r.lastBlock != b.createdBlock) v(out, "I14 rates", at # " was kept at block " # Nat.toText(r.lastBlock) # "; the booking was made at " # Nat.toText(b.createdBlock)) };
        case null v(out, "I14 rates", at # ": the booking does not exist");
      };
      // a promotion's uses, one row at a time: this use within its count, under its own number, after the one before
      if (r.promoId == 0) {
        if (r.use != 0) v(out, "I14 rates", at # " counts use " # Nat.toText(r.use) # " of no promotion");
      } else {
        let used = switch (St.promo(c.x, r.promoId)) { case (?p) p.used; case null 0 };
        if (r.use == 0 or r.use > used) v(out, "I14 rates", at # " counts use " # Nat.toText(r.use) # " of promotion " # Nat.toText(r.promoId) # ", which has counted " # Nat.toText(used));
        switch (St.bookingOfUse(c.x, r.promoId, r.use)) {
          case (?(found, _)) { if (found != id) v(out, "I14 rates", at # "'s use " # Nat.toText(r.use) # " of promotion " # Nat.toText(r.promoId) # " is booking " # Nat.toText(found) # "'s") };
          case null v(out, "I14 rates", at # "'s use is not found under its number");
        };
        if (r.use > 1 and St.bookingOfUse(c.x, r.promoId, r.use - 1 : Nat) == null)
          v(out, "I14 rates", at # " counts use " # Nat.toText(r.use) # " of promotion " # Nat.toText(r.promoId) # " with no use " # Nat.toText(r.use - 1 : Nat));
      };
    };
    (pg.examined, pg.next)
  };

  func holdRates(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let pg = RowStore.pageById<R.RateGrant>(St.later(c.x, St.HOLD_RATE_TABLE), R.holdRate, 0, St.MAX_ID, cursor, lim);
    for ((id, r) in pg.rows.vals()) {
      let at = "the access of hold " # Nat.toText(id);
      kept(c, at, r, out);
      if (r.use != 0) v(out, "I14 rates", at # " counts a use; a hold counts none");
      switch (St.hold(c.s, id)) {
        case (?h) {
          if (r.lastBlock > h.lastBlock) v(out, "I14 rates", at # " was kept at block " # Nat.toText(r.lastBlock) # ", after the hold's last change at " # Nat.toText(h.lastBlock));
          switch (St.planAccess(c.x, h.planId)) {
            case (?a) { if (a.lastBlock < r.lastBlock and not fits(c, h.planId, a, r.companyId, r.promoId)) v(out, "I14 rates", at # " is on plan " # Nat.toText(h.planId) # ", closed " # closedTo(a) # ", and was placed " # soldUnder(r.companyId, r.promoId)) };
            case null {};
          };
        };
        case null v(out, "I14 rates", at # ": the hold does not exist");
      };
    };
    (pg.examined, pg.next)
  };

  func kept(c : St.Ctx, at : Text, r : R.RateGrant, out : List.List<Violation>) {
    if (r.companyId == 0 and r.promoId == 0) v(out, "I14 rates", at # " keeps the public sale, which is never kept");
    if (r.companyId != 0 and St.company(c.x, r.companyId) == null) v(out, "I14 rates", at # " names company " # Nat.toText(r.companyId) # ", which does not exist");
    if (r.promoId != 0 and St.promo(c.x, r.promoId) == null) v(out, "I14 rates", at # " names promotion " # Nat.toText(r.promoId) # ", which does not exist");
    if (r.companyId != 0 and r.promoId != 0) v(out, "I14 rates", at # " names both a company and a promotion");
  };

  func companies(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let pg = RowStore.pageById<R.Company>(St.later(c.x, St.COMPANY_TABLE), R.company, 0, St.MAX_ID, cursor, lim);
    for ((id, co) in pg.rows.vals()) {
      let at = "company " # Nat.toText(id);
      if (RP.codeShape(co.code) != null) v(out, "I14 rates", at # " has the code \"" # co.code # "\", which is not capitals, digits and dashes");
      switch (St.companyByCode(c.x, co.code)) {
        case (?(found, _)) { if (found != id) v(out, "I14 rates", at # "'s code finds company " # Nat.toText(found)) };
        case null v(out, "I14 rates", at # "'s code finds no company");
      };
      if (Text.encodeUtf8(TA.get(c.s.arena, co.name)).size() == 0) v(out, "I14 rates", at # " has no name");
      switch (St.promoByCode(c.x, co.code)) { case (?(p, _)) v(out, "I14 rates", at # "'s code is also promotion " # Nat.toText(p) # "'s"); case null {} };
    };
    (pg.examined, pg.next)
  };

  func planAccess(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let pg = RowStore.pageById<R.PlanAccess>(St.later(c.x, St.PLAN_ACCESS_TABLE), R.planAccess, 0, St.MAX_ID, cursor, lim);
    for ((planId, a) in pg.rows.vals()) {
      let at = "the access of plan " # Nat.toText(planId);
      if (St.plan(c.s, planId) == null) v(out, "I14 rates", at # ": the plan does not exist");
      if (a.companyId != 0) {
        if (not a.closed) v(out, "I14 rates", at # " names company " # Nat.toText(a.companyId) # " and is open to everyone");
        if (St.company(c.x, a.companyId) == null) v(out, "I14 rates", at # " names company " # Nat.toText(a.companyId) # ", which does not exist");
      };
    };
    (pg.examined, pg.next)
  };

  func promos(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let pg = RowStore.pageById<R.Promo>(St.later(c.x, St.PROMO_TABLE), R.promo, 0, St.MAX_ID, cursor, lim);
    for ((id, p) in pg.rows.vals()) {
      let at = "promotion " # Nat.toText(id);
      if (RP.codeShape(p.code) != null) v(out, "I14 rates", at # " has the code \"" # p.code # "\", which is not capitals, digits and dashes");
      switch (St.promoByCode(c.x, p.code)) {
        case (?(found, _)) { if (found != id) v(out, "I14 rates", at # "'s code finds promotion " # Nat.toText(found)) };
        case null v(out, "I14 rates", at # "'s code finds no promotion");
      };
      if (Text.encodeUtf8(TA.get(c.s.arena, p.name)).size() == 0) v(out, "I14 rates", at # " has no name");
      if (St.plan(c.s, p.planId) == null) v(out, "I14 rates", at # " opens plan " # Nat.toText(p.planId) # ", which does not exist");
      if (p.bookFrom > p.bookUntil or p.stayFrom > p.stayUntil) v(out, "I14 rates", at # " has a window that ends before it begins");
      if (p.maxUses != 0 and p.used > p.maxUses) v(out, "I14 rates", at # " was used " # Nat.toText(p.used) # " times, past its limit of " # Nat.toText(p.maxUses));
      if (p.used > 0 and St.bookingOfUse(c.x, id, p.used) == null) v(out, "I14 rates", at # " counts " # Nat.toText(p.used) # " uses; its last use is no booking's");
    };
    (pg.examined, pg.next)
  };

  func blocks(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let pg = RowStore.pageById<R.Block>(St.later(c.x, St.BLOCK_TABLE), R.block, 0, St.MAX_ID, cursor, lim);
    for ((id, b) in pg.rows.vals()) {
      let at = "block " # Nat.toText(id);
      if (St.roomType(c.s, b.roomTypeId) == null) v(out, "I15 blocks", at # " is of room type " # Nat.toText(b.roomTypeId) # ", which does not exist");
      if (St.plan(c.s, b.planId) == null) v(out, "I15 blocks", at # " is sold at plan " # Nat.toText(b.planId) # ", which does not exist");
      if (b.companyId != 0 and St.company(c.x, b.companyId) == null) v(out, "I15 blocks", at # " names company " # Nat.toText(b.companyId) # ", which does not exist");
      if (b.departure <= b.arrival or b.rooms == 0) v(out, "I15 blocks", at # " holds no room night");
      if (b.cutoff > b.arrival) v(out, "I15 blocks", at # "'s cut-off is after its arrival");
      // its bookings, night by night: the rooms of those that hold the night
      let picked = Map.empty<Nat, Nat>();
      for ((bid, _) in St.blockBookingsAll(c.x, id).vals()) {
        switch (St.booking(c.s, bid)) {
          case (?bk) {
            if (E.holdsNights(bk.status)) {
              var d = bk.arrival;
              while (d < bk.departure) { Map.add(picked, Nat.compare, d, bk.rooms + (switch (Map.get(picked, Nat.compare, d)) { case (?x) x; case null 0 })); d += 1 };
            };
          };
          // the pickups section names it
          case null {};
        };
      };
      var d = b.arrival;
      while (d < b.departure) {
        let on = at # ", day " # Nat.toText(d);
        let want = switch (Map.get(picked, Nat.compare, d)) { case (?x) x; case null 0 };
        switch (St.blockNight(c.x, id, d)) {
          case (?bn) {
            if (bn.night != R.nightId(b.roomTypeId, d)) v(out, "I15 blocks", on # " is on another hotel night");
            if (bn.picked != want) v(out, "I15 blocks", on # ": picked up says " # Nat.toText(bn.picked) # ", its bookings hold " # Nat.toText(want));
            if (bn.picked > b.rooms) v(out, "I15 blocks", on # ": " # Nat.toText(bn.picked) # " rooms picked up of " # Nat.toText(b.rooms));
            let held = if (b.open and b.rooms >= bn.picked) (b.rooms - bn.picked : Nat) else 0;
            if (bn.open != held) v(out, "I15 blocks", on # " still holds " # Nat.toText(bn.open) # " rooms; " # (if (b.open) "open" else "released") # ", it holds " # Nat.toText(held));
          };
          case null v(out, "I15 blocks", on # " has no row");
        };
        d += 1;
      };
    };
    (pg.examined, pg.next)
  };

  func nightBlocks(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let pg = RowStore.pageById<R.NightBlock>(St.later(c.x, St.NIGHT_BLOCK_TABLE), R.nightBlock, 0, St.pow256(R.NIGHT_ID_BYTES) - 1, cursor, lim);
    for ((nid, n) in pg.rows.vals()) {
      let rt = R.nightRoomType(nid);
      let d = R.nightDay(nid);
      var sum = 0;
      for ((_, bn) in St.blockNightsOn(c.x, rt, d, Blocks.MAX_BLOCKS).vals()) sum += bn.open;
      if (sum != n.open) v(out, "I15 blocks", "room type " # Nat.toText(rt) # ", day " # Nat.toText(d) # ": held by blocks says " # Nat.toText(n.open) # ", its blocks hold " # Nat.toText(sum));
    };
    (pg.examined, pg.next)
  };

  func pickups(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let pg = RowStore.pageById<R.BookingBlock>(St.later(c.x, St.BOOKING_BLOCK_TABLE), R.bookingBlock, 0, St.MAX_ID, cursor, lim);
    for ((id, p) in pg.rows.vals()) {
      let at = "the pickup of booking " # Nat.toText(id);
      switch (St.booking(c.s, id), St.block(c.x, p.blockId)) {
        case (?b, ?k) {
          if (b.roomTypeId != k.roomTypeId or b.planId != k.planId) v(out, "I15 blocks", at # " is not block " # Nat.toText(p.blockId) # "'s room type and plan");
          if (b.arrival < k.arrival or b.departure > k.departure) v(out, "I15 blocks", at # " runs outside block " # Nat.toText(p.blockId) # "'s dates");
          switch (St.staffBooking(c.x, id)) {
            case (?x) { if (x.channel != #group) v(out, "I15 blocks", at # " was taken " # E.channelText(x.channel) # ", not from the group's list") };
            case null v(out, "I15 blocks", at # " was not taken by staff");
          };
        };
        case (null, _) v(out, "I15 blocks", at # ": the booking does not exist");
        case (_, null) v(out, "I15 blocks", at # ": block " # Nat.toText(p.blockId) # " does not exist");
      };
    };
    (pg.examined, pg.next)
  };

  // ── I18 packages ──────────────────────────────────────────────────────────

  func packageLines(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let pg = RowStore.pageById<R.PackageLine>(St.later(c.x, St.PACKAGE_LINE_TABLE), R.packageLine, 0, St.MAX_ID, cursor, lim);
    for ((id, pk) in pg.rows.vals()) {
      let at = "package line " # Nat.toText(id);
      switch (St.folioLine(c.s, id), St.charge(c.x, id)) {
        case (?l, ?ch) {
          if (l.kind != #extra or ch.bookingId != l.bookingId) v(out, "I18 packages", at # " is not an extra of its booking");
          if (ch.postedBy != Res.packagePoster()) v(out, "I18 packages", at # " was posted by a member of staff");
          if (ch.extraId != pk.extraId or ch.quantity != pk.quantity or ch.unitAmount != pk.unitAmount or ch.taxLines != pk.taxLines)
            v(out, "I18 packages", at # ": its charge is not the inclusion sold");
          if (not pk.taxed and pk.taxLines > 0) v(out, "I18 packages", at # " is taxed, and its extra was not");
          if (ch.voidLine == 0) {
            switch (St.booking(c.s, l.bookingId)) {
              case (?b) {
                if (b.status == #confirmed or b.status == #checkedIn) {
                  let night = Nat.toText(l.night);
                  if (l.night < b.arrival or l.night >= b.departure) v(out, "I18 packages", at # " is on night " # night # ", outside booking " # Nat.toText(l.bookingId) # "'s stay");
                  if (pk.rhythm == #arrivalNight and l.night != b.arrival) v(out, "I18 packages", at # " is an arrival-night inclusion on night " # night);
                  var same = 0; var before = false; var after = false;
                  for ((_, l2, pk2, _) in Res.livePackage(c, l.bookingId, 0).vals()) {
                    if (pk2.slot == pk.slot) {
                      if (l2.night == l.night) same += 1;
                      if (l2.night + 1 == l.night) before := true;
                      if (l2.night == l.night + 1) after := true;
                    };
                  };
                  if (same > 1) v(out, "I18 packages", at # ": inclusion " # Nat.toText(pk.slot) # " is on night " # night # " twice");
                  if (pk.rhythm == #everyNight) {
                    if (l.night > b.arrival and not before) v(out, "I18 packages", at # ": inclusion " # Nat.toText(pk.slot) # " is on night " # night # " and not the night before");
                    if (l.night + 1 < b.departure and not after) v(out, "I18 packages", at # ": inclusion " # Nat.toText(pk.slot) # " is on night " # night # " and not the night after");
                  };
                };
              };
              case null v(out, "I18 packages", at # ": booking " # Nat.toText(l.bookingId) # " does not exist");
            };
          };
        };
        case _ v(out, "I18 packages", at # ": its line or its charge does not exist");
      };
    };
    (pg.examined, pg.next)
  };

  func holdPackages(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let pg = RowStore.pageById<R.PackageLine>(St.later(c.x, St.HOLD_PACKAGE_TABLE), R.holdPackage, 0, St.MAX_ID, cursor, lim);
    for ((id, pk) in pg.rows.vals()) {
      let at = "hold package line " # Nat.toText(id);
      switch (RowStore.get<R.FolioLine>(c.s.holdLines, R.folioLine, id)) {
        case (?l) {
          if (l.kind != #extra or St.hold(c.s, l.bookingId) == null) v(out, "I18 packages", at # " is not an extra of a hold");
          if (l.amount != pk.quantity * pk.unitAmount) v(out, "I18 packages", at # " is " # Nat.toText(l.amount) # ", and " # Nat.toText(pk.quantity) # " × " # Nat.toText(pk.unitAmount) # " is " # Nat.toText(pk.quantity * pk.unitAmount));
          if (not pk.taxed and pk.taxLines > 0) v(out, "I18 packages", at # " is taxed, and its extra was not");
          for (t in Nat.range(id + 1, id + pk.taxLines + 1)) {
            switch (RowStore.get<R.FolioLine>(c.s.holdLines, R.folioLine, t)) {
              case (?tl) { if (tl.kind != #extraTax or tl.bookingId != l.bookingId or tl.night != l.night) v(out, "I18 packages", at # ": line " # Nat.toText(t) # " is not its tax") };
              case null v(out, "I18 packages", at # ": its tax line " # Nat.toText(t) # " does not exist");
            };
          };
        };
        case null v(out, "I18 packages", at # ": the hold line does not exist");
      };
    };
    (pg.examined, pg.next)
  };

  func inclusions(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let pg = RowStore.pageById<R.PlanInclusion>(St.later(c.x, St.PLAN_INCLUSION_TABLE), R.planInclusion, 0, St.MAX_ID, cursor, lim);
    for ((id, inc) in pg.rows.vals()) {
      let at = "inclusion " # Nat.toText(id % 16) # " of plan " # Nat.toText(id / 16);
      if (inc.planId != id / 16 or id % 16 == 0 or id % 16 > R.MAX_INCLUSIONS) v(out, "I18 packages", at # " is under the wrong plan or slot");
      if (inc.on) {
        if (St.plan(c.s, inc.planId) == null) v(out, "I18 packages", at # ": the plan does not exist");
        if (St.extra(c.x, inc.extraId) == null) v(out, "I18 packages", at # ": extra " # Nat.toText(inc.extraId) # " does not exist");
        if (inc.quantity == 0 or inc.quantity > RP.MAX_INCLUSION_QUANTITY) v(out, "I18 packages", at # " gives " # Nat.toText(inc.quantity) # " of its extra");
      };
    };
    (pg.examined, pg.next)
  };

  /// I16 card on file: a card kept is the gateway's token on a payment the guest made, agreed before any
  /// charge on it; it is charged only for a no-show, after its audit, never past the penalty less what the
  /// guarantee's authorisation covered; never once forgotten; and forgotten (or on its way) once its
  /// booking is settled. A card still wanted is a confirmed booking's.
  func cards(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let pg = RowStore.pageById<R.CardOnFile>(St.later(c.x, St.CARD_TABLE), R.cardOnFile, 0, St.MAX_ID, cursor, lim);
    for ((id, k) in pg.rows.vals()) {
      let at = "the card of booking " # Nat.toText(id);
      switch (St.booking(c.s, id)) {
        case null v(out, "I16 card on file", at # ": the booking does not exist");
        case (?b) {
          let charge = if (k.chargeId == 0) null else St.payment(c.s, k.chargeId);
          let chargeDue = switch charge { case (?p) p.state == #due; case null false };
          switch (k.state) {
            case (#wanted or #closed) {
              if (k.token != 0 or k.chargeId != 0) v(out, "I16 card on file", at # " has no card, and names a token or a charge");
              if (k.state == #wanted and b.status != #confirmed) v(out, "I16 card on file", at # " is still wanted, and the booking is " # E.bookingStatusText(b.status));
            };
            case _ {
              if (k.token == 0 or k.agreedBlock == 0) v(out, "I16 card on file", at # " is kept with no token or no agreement");
              var paidBy = false;
              for ((_, p) in St.paymentsOf(c.s, id).vals()) { if (p.kind == #authorised and p.gatewayAuth == k.firstAuth and k.firstAuth != 0) paidBy := true };
              if (not paidBy) v(out, "I16 card on file", at # " rests on no payment of the guest's");
              let settled = b.status == #cancelled or b.status == #checkedOut or (b.status == #noShow and not chargeDue);
              if (k.state == #kept and settled) v(out, "I16 card on file", at # " is still kept, and the booking is settled (" # E.bookingStatusText(b.status) # ")");
              if (k.state != #kept and chargeDue) v(out, "I16 card on file", at # " is " # E.cardStateText(k.state) # " with its charge still due");
            };
          };
          switch charge {
            case (?p) {
              if (p.kind != #chargedOnFile or p.bookingId != id) v(out, "I16 card on file", at # ": payment " # Nat.toText(k.chargeId) # " is not a charge on file of the booking");
              if (b.status != #noShow) v(out, "I16 card on file", at # " was charged, and the booking is " # E.bookingStatusText(b.status) # ", not a no-show");
              if (k.agreedBlock >= p.block) v(out, "I16 card on file", at # " was charged in block " # Nat.toText(p.block) # ", not after the guest agreed in block " # Nat.toText(k.agreedBlock));
              var captured = 0;
              for ((_, q) in St.paymentsOf(c.s, id).vals()) { if (q.kind == #captured and q.state != #failed) captured += q.amount };
              if (p.amount + captured > b.penalty)
                v(out, "I16 card on file", at # " was charged " # Nat.toText(p.amount) # " on file and " # Nat.toText(captured) # " on its guarantee, past the penalty of " # Nat.toText(b.penalty));
              if (k.declinedDay > 0 and p.state != #failed) v(out, "I16 card on file", at # " is marked declined, and its charge is " # E.paymentStateText(p.state));
            };
            case null {
              if (k.chargeId != 0) v(out, "I16 card on file", at # ": its charge " # Nat.toText(k.chargeId) # " does not exist");
              if (k.declinedDay > 0) v(out, "I16 card on file", at # " is marked declined with no charge");
            };
          };
        };
      };
    };
    (pg.examined, pg.next)
  };

  /// I16 card on file: a deposit plan has its share, a whole percentage from 1% to 99%.
  func deposits(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    var examined = 0;
    // the plans are few (at most MAX_PLANS): every deposit plan on the first page has its share
    if (cursor == null) {
      for ((pid, p) in RowStore.pageById<R.RatePlan>(c.s.plans, R.ratePlan, 1, St.MAX_PLANS, null, St.MAX_PLANS).rows.vals()) {
        examined += 1;
        if (p.guarantee == #deposit and St.depositBps(c.x, pid) == 0) v(out, "I16 card on file", "plan " # Nat.toText(pid) # " takes a deposit with no share set");
      };
    };
    let pg = RowStore.pageById<R.PlanDeposit>(St.later(c.x, St.PLAN_DEPOSIT_TABLE), R.planDeposit, 0, St.MAX_ID, cursor, lim);
    for ((pid, d) in pg.rows.vals()) {
      if (St.plan(c.s, pid) == null) v(out, "I16 card on file", "the deposit of plan " # Nat.toText(pid) # ": the plan does not exist");
      if (d.depositBps != 0 and (d.depositBps < 100 or d.depositBps > 9_900 or d.depositBps % 100 != 0))
        v(out, "I16 card on file", "the deposit of plan " # Nat.toText(pid) # " is " # Nat.toText(d.depositBps) # " basis points, not a whole percentage from 1% to 99%");
    };
    (examined + pg.examined, pg.next)
  };

  /// I17 mail: each message owed, against its booking and its address.
  func outbox(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    let pg = RowStore.pageById<R.Outbox>(St.later(c.x, St.OUTBOX_TABLE), R.outbox, 0, St.MAX_ID, cursor, lim);
    for ((id, o) in pg.rows.vals()) {
      let at = "message " # Nat.toText(id) # " (" # E.mailKindText(o.kind) # " of booking " # Nat.toText(o.bookingId) # ")";
      switch (St.booking(c.s, o.bookingId), St.mailAddress(c.x, o.bookingId)) {
        case (null, _) v(out, "I17 mail", at # ": the booking does not exist");
        case (_, null) v(out, "I17 mail", at # ": the booking gave no address");
        case (?b, ?m) {
          let slot = switch (o.kind) { case (#confirmation) m.confirmation; case (#preArrival) m.preArrival; case (#receipt) m.receipt; case (#cancellation) m.cancellation };
          if (slot != id) v(out, "I17 mail", at # ": its address names message " # Nat.toText(slot) # " for that kind");
          switch (o.kind) {
            case (#receipt) { if (b.status != #checkedOut) v(out, "I17 mail", at # ": a receipt, and the booking is " # E.bookingStatusText(b.status)) };
            case (#cancellation) { if (b.status != #cancelled) v(out, "I17 mail", at # ": a cancellation notice, and the booking is " # E.bookingStatusText(b.status)) };
            case (#preArrival) {
              if (o.state == #due and b.status != #confirmed) v(out, "I17 mail", at # ": a note before arrival still due, and the booking is " # E.bookingStatusText(b.status));
              if (o.notBefore == 0 or o.notBefore >= b.arrival) v(out, "I17 mail", at # ": a note before arrival due on day " # Nat.toText(o.notBefore) # ", arrival " # Nat.toText(b.arrival));
            };
            case (#confirmation) {};
          };
          if (o.kind != #preArrival and o.notBefore != 0) v(out, "I17 mail", at # ": waits for day " # Nat.toText(o.notBefore) # "; only a note before arrival waits");
        };
      };
      if (o.attempts > 3) v(out, "I17 mail", at # ": tried " # Nat.toText(o.attempts) # " times, past three");
      switch (o.state) {
        case (#sent) { if (o.attempts == 0 or o.failure != #none) v(out, "I17 mail", at # ": sent, with " # Nat.toText(o.attempts) # " attempts and failure '" # E.mailFailureText(o.failure) # "'") };
        case (#failed) { if (o.attempts != 3 or o.failure == #none) v(out, "I17 mail", at # ": failed after " # Nat.toText(o.attempts) # " attempts, failure '" # E.mailFailureText(o.failure) # "'") };
        case (#due) {
          if (o.attempts >= 3) v(out, "I17 mail", at # ": still due after " # Nat.toText(o.attempts) # " attempts");
          if ((o.attempts == 0) != (o.failure == #none)) v(out, "I17 mail", at # ": due with " # Nat.toText(o.attempts) # " attempts and failure '" # E.mailFailureText(o.failure) # "'");
        };
        case (#skipped) {};
      };
      if (o.queuedBlock == 0 or o.queuedBlock > o.lastBlock) v(out, "I17 mail", at # ": queued in block " # Nat.toText(o.queuedBlock) # ", last written in " # Nat.toText(o.lastBlock));
    };
    (pg.examined, pg.next)
  };

  /// Is this text an address as a browser seals one ("lxe1." and base64url, within the bounds)?
  func sealedOk(t : Text) : Bool {
    if (not Text.startsWith(t, #text "lxe1.")) return false;
    let n = Text.encodeUtf8(t).size();
    if (n < 133 or n > 512) return false;
    for (ch in Text.toIter(Text.trimStart(t, #text "lxe1."))) {
      if (not ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '-' or ch == '_')) return false;
    };
    true
  };

  /// I17 mail: each booking's address and the messages it names; guest email's setup on the first page.
  func mailAddresses(c : St.Ctx, cursor : ?Blob, lim : Nat, out : List.List<Violation>) : (Nat, ?Blob) {
    var examined = 0;
    if (cursor == null) {
      switch (St.mailSetup(c.x)) {
        case (?m) {
          examined += 1;
          let zeroKey = Mail.noKey();
          let zero = Mail.noDigest();
          let key = Blob.toArray(m.mailKey);
          let connected = m.mailKey != zeroKey;
          if (connected and key[0] != (4 : Nat8)) v(out, "I17 mail", "guest email's mail key is not a raw P-256 point");
          if (m.on and not connected) v(out, "I17 mail", "guest email is on with no relay connected");
          if (m.on and (m.authorised == zero or m.tested != m.authorised)) v(out, "I17 mail", "guest email is on with an account the relay has not tested");
          if (m.tested != zero and m.tested != m.authorised) v(out, "I17 mail", "the account tested is not the one authorised");
          if (connected) {
            switch (RowStore.get<R.Grant>(c.s.grants, R.grant, m.mailerGrant)) {
              case (?g) { if (not g.active or g.role != #mailer) v(out, "I17 mail", "the relay's grant " # Nat.toText(m.mailerGrant) # " is not an active mailer grant") };
              case null v(out, "I17 mail", "the relay's grant " # Nat.toText(m.mailerGrant) # " does not exist");
            };
          };
        };
        case null {};
      };
    };
    let pg = RowStore.pageById<R.MailAddress>(St.later(c.x, St.MAIL_ADDRESS_TABLE), R.mailAddress, 0, St.MAX_ID, cursor, lim);
    for ((id, m) in pg.rows.vals()) {
      let at = "the address of booking " # Nat.toText(id);
      if (not sealedOk(TA.get(c.s.arena, m.sealed))) v(out, "I17 mail", at # " is not sealed");
      func names(slot : Nat, kind : E.MailKind) {
        if (slot == 0) return;
        switch (St.outboxRow(c.x, slot)) {
          case (?o) { if (o.bookingId != id or o.kind != kind) v(out, "I17 mail", at # " names message " # Nat.toText(slot) # " for its " # E.mailKindText(kind) # ", which is not") };
          case null v(out, "I17 mail", at # " names message " # Nat.toText(slot) # ", which does not exist");
        };
      };
      names(m.confirmation, #confirmation); names(m.preArrival, #preArrival); names(m.receipt, #receipt); names(m.cancellation, #cancellation);
      if (m.confirmation == 0) v(out, "I17 mail", at # " has no confirmation");
      switch (St.booking(c.s, id)) {
        case null v(out, "I17 mail", at # ": the booking does not exist");
        case (?b) {
          if (b.status == #cancelled and m.cancellation == 0) v(out, "I17 mail", at # ": the booking is cancelled and no cancellation notice is owed");
          if (b.status == #checkedOut and m.receipt == 0) v(out, "I17 mail", at # ": the stay is checked out and no receipt is owed");
        };
      };
    };
    (examined + pg.examined, pg.next)
  };

  /// One bounded step of the audit's walk through every section.
  public func step(c : St.Ctx, limit : Nat) : { examined : Nat; done : Bool } {
    let w = c.s.walk;
    if (w.done) return { examined = 0; done = true };
    let r = page(c, w.section, w.cursor, limit);
    w.examined += r.examined;
    if (r.violations.size() > 0) {
      let add = List.fromArray<Text>(w.violations);
      for (x in r.violations.vals()) { if (List.size(add) < 64) List.add(add, x.rule # ": " # x.detail) };
      w.violations := List.toArray(add);
    };
    switch (r.next) {
      case (?cur) { w.cursor := ?cur };
      case null {
        w.cursor := null;
        w.section += 1;
        // the walk ends at the span it opened with: the sections of the rules it opened under
        if (w.section >= Rules.walkSections(c.x)) w.done := true;
      };
    };
    { examined = r.examined; done = w.done }
  };

}
