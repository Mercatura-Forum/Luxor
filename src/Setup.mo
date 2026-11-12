/// Setup.mo - the property, its room types, rooms, rate plans and taxes, and the night grid.
///
/// THE GRID EDIT LANDS WHOLE. `setNights` reads the edited range with one range read, checks every
/// night it will touch - an allotment below what is already sold and held, above the rooms of the
/// type, a new night with no rate - and only then writes. A refused edit changes no night.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Text "mo:core/Text";
import List "mo:core/List";
import Set "mo:core/Set";

import RowStore "mo:kernel/rows/RowStore";
import Calendar "mo:kernel/time/Calendar";
import KeyRing "mo:kernel/eco/KeyRing";
import SR "mo:kernel/rows/StableRows";

import Cmd "Command";
import E "Enums";
import Hk "Housekeeping";
import R "Rows";
import Q "Quote";
import Rf "Refusal";
import St "Store";
import TA "TextArena";
import W "Widths";

module {

  public type Out = { #ok : [Nat]; #err : Rf.Refusal };

  public let MAX_TEXT : Nat = 2_000;
  public let MAX_EDIT_NIGHTS : Nat = 366;

  func codeOk(code : Text) : ?Rf.Refusal {
    let n = Text.encodeUtf8(code).size();
    if (n == 0) return ?#invalid({ what = "A code is required." });
    if (n > W.CODE) return ?#tooLong({ what = "code"; max = W.CODE });
    null
  };

  func textsOk(s : St.Stores, texts : [Text]) : ?Rf.Refusal {
    switch (TA.fits(s.arena, texts, MAX_TEXT)) { case (?why) ?#invalid({ what = why }); case null null }
  };

  public func configureProperty(c : St.Ctx, f : Cmd.PropertyFacts) : Out {
    let cur = Text.encodeUtf8(f.currency);
    if (cur.size() != 3) return #err(#invalid({ what = "A currency is its three-letter ISO 4217 code." }));
    for (b in cur.vals()) { if (b < 65 or b > 90) return #err(#invalid({ what = "A currency code is three capital letters." })) };
    if (f.minorUnits > 3) return #err(#invalid({ what = "A currency has at most three minor units." }));
    if (f.holdTtlHeights == 0) return #err(#invalid({ what = "A hold must last at least one block." }));
    if (f.heightsPerRealMinute == 0) return #err(#invalid({ what = "The clock ratio must be at least one block per minute." }));
    if (f.maxStayNights == 0 or f.maxStayNights > 255) return #err(#invalid({ what = "The longest stay is 1 to 255 nights." }));
    if (f.horizonDays == 0 or f.horizonDays > 1_095) return #err(#invalid({ what = "Bookings open 1 to 1,095 days ahead." }));
    if (f.maxRoomsPerBooking == 0 or f.maxRoomsPerBooking > 9) return #err(#invalid({ what = "One booking holds 1 to 9 rooms." }));
    if (f.idRetentionDays == 0 or f.idRetentionDays > 3_650) return #err(#invalid({ what = "Identity documents are kept 1 to 3,650 days." }));
    if (Text.encodeUtf8(f.nameEn).size() == 0) return #err(#invalid({ what = "The property needs a name." }));
    switch (textsOk(c.s, [f.nameEn, f.nameAr, f.checkInText, f.checkOutText])) { case (?r) return #err(r); case null {} };
    RowStore.put<R.Property>(c.s.property, R.property, St.PROPERTY_ID, {
      currency = f.currency; minorUnits = f.minorUnits;
      nameEn = TA.put(c.s.arena, f.nameEn); nameAr = TA.put(c.s.arena, f.nameAr);
      checkInText = TA.put(c.s.arena, f.checkInText); checkOutText = TA.put(c.s.arena, f.checkOutText);
      holdTtlHeights = f.holdTtlHeights; heightsPerRealMinute = f.heightsPerRealMinute; maxStayNights = f.maxStayNights;
      horizonDays = f.horizonDays; maxRoomsPerBooking = f.maxRoomsPerBooking; idRetentionDays = f.idRetentionDays; lastBlock = c.block;
    });
    #ok([St.PROPERTY_ID])
  };

  func codeHolder<Row>(store : RowStore.Store, decl : RowStore.Decl<Row>, code : Text) : ?Nat {
    let k = R.codeKey(code);
    switch (RowStore.page<Row>(store, decl, "by_code", k, k, null, 1)) {
      case (#ok p) { if (p.rows.size() > 0) ?p.rows[0].0 else null };
      case (#err _) null;
    }
  };

  public func upsertRoomType(c : St.Ctx, id : Nat, f : Cmd.RoomTypeFacts) : Out {
    switch (codeOk(f.code)) { case (?r) return #err(r); case null {} };
    let target = if (id == 0) c.s.nextRoomTypeId else id;
    if (id == 0 and c.s.nextRoomTypeId > W.MAX_ROOM_TYPES) return #err(#tooManyRoomTypes({ max = W.MAX_ROOM_TYPES }));
    if (id != 0 and St.roomType(c.s, id) == null) return #err(#noSuchRoomType({ id }));
    switch (codeHolder<R.RoomType>(c.s.roomTypes, R.roomType, f.code)) {
      case (?other) { if (other != target) return #err(#codeTaken({ code = f.code; id = other })) };
      case null {};
    };
    if (f.maxAdults == 0 or f.maxOccupancy == 0 or f.maxOccupancy > f.maxAdults + f.maxChildren or f.maxOccupancy > 255) {
      return #err(#invalid({ what = "A room sleeps at least one adult, and no more than its adults and children together." }));
    };
    if (f.bedCount == 0 or f.bedCount > 255 or f.sizeSqm > 65_535 or f.rank > 255 or f.amenities >= 4_294_967_296) {
      return #err(#invalid({ what = "A room's beds, size, rank or amenities are out of range." }));
    };
    switch (textsOk(c.s, [f.nameEn, f.nameAr, f.descEn, f.descAr, f.photos])) { case (?r) return #err(r); case null {} };
    if (id == 0) c.s.nextRoomTypeId += 1;
    RowStore.put<R.RoomType>(c.s.roomTypes, R.roomType, target, {
      code = f.code; nameEn = TA.put(c.s.arena, f.nameEn); nameAr = TA.put(c.s.arena, f.nameAr);
      descEn = TA.put(c.s.arena, f.descEn); descAr = TA.put(c.s.arena, f.descAr); sizeSqm = f.sizeSqm;
      maxAdults = f.maxAdults; maxChildren = f.maxChildren; maxOccupancy = f.maxOccupancy; bedKind = f.bedKind;
      bedCount = f.bedCount; amenities = f.amenities; photos = TA.put(c.s.arena, f.photos); rank = f.rank;
      active = f.active; lastBlock = c.block;
    });
    #ok([target])
  };

  public func upsertRoom(c : St.Ctx, id : Nat, roomTypeId : Nat, number : Text, outOfOrder : Bool) : Out {
    let ?prop = St.property(c.s) else return #err(#notConfigured);
    let ?_ = St.roomType(c.s, roomTypeId) else return #err(#noSuchRoomType({ id = roomTypeId }));
    let n = Text.encodeUtf8(number).size();
    if (n == 0 or n > W.ROOM_NUMBER) return #err(#tooLong({ what = "room number"; max = W.ROOM_NUMBER }));
    // the same field the room table's `by_number` index is built from
    let k = SR.textKey(number, W.ROOM_NUMBER);
    let holder = switch (RowStore.page<R.Room>(c.s.rooms, R.room, "by_number", k, k, null, 1)) {
      case (#ok p) { if (p.rows.size() > 0) ?p.rows[0].0 else null };
      case (#err _) null;
    };
    let target = if (id == 0) c.s.nextRoomId else id;
    switch holder { case (?other) { if (other != target) return #err(#codeTaken({ code = number; id = other })) }; case null {} };
    let old = if (id == 0) null else switch (St.room(c.s, id)) { case (?r) ?r; case null return #err(#noSuchRoom({ id })) };
    switch old {
      case (?r) {
        if (r.occupiedBy != 0 and (outOfOrder or r.roomTypeId != roomTypeId)) return #err(#roomNotVacant({ id }));
      };
      case null {};
    };
    // taking a room out of sale, or moving it to another type, may leave nights offering more rooms
    // than the type has: every such night in the horizon is found and named before anything is written.
    // The nights it leaves are those it counts on for its present type and will not: every one if it
    // moves type; if it stays, every one it counts on when a room in service goes out of order. A room
    // out of order with dates (Housekeeping) keeps them through an edit that keeps it out.
    switch old {
      case (?r) {
        let h = St.housekeeping(c.x, id);
        let leaving = r.roomTypeId != roomTypeId or (outOfOrder and r.status == #active);
        if (leaving) {
          switch (Hk.roomsSuffice(c, prop.horizonDays, r.roomTypeId, func(d : Nat) : Bool { St.countsOn(r, h, d) })) { case (?x) return #err(x); case null {} };
        };
      };
      case null {};
    };
    if (id == 0) c.s.nextRoomId += 1;
    RowStore.put<R.Room>(c.s.rooms, R.room, target, {
      roomTypeId; number; status = if (outOfOrder) #outOfOrder else #active;
      occupiedBy = switch old { case (?r) r.occupiedBy; case null 0 }; lastBlock = c.block;
    });
    switch old { case (?r) { if (r.status == #outOfOrder and not outOfOrder) Hk.setupReturned(c, target) }; case null {} };
    #ok([target])
  };

  public func upsertRatePlan(c : St.Ctx, id : Nat, f : Cmd.RatePlanFacts) : Out {
    switch (codeOk(f.code)) { case (?r) return #err(r); case null {} };
    let target = if (id == 0) c.s.nextPlanId else id;
    if (id == 0 and c.s.nextPlanId > St.MAX_PLANS) return #err(#invalid({ what = "A property has at most " # Nat.toText(St.MAX_PLANS) # " rate plans." }));
    if (id != 0 and St.plan(c.s, id) == null) return #err(#noSuchPlan({ id }));
    switch (codeHolder<R.RatePlan>(c.s.plans, R.ratePlan, f.code)) {
      case (?other) { if (other != target) return #err(#codeTaken({ code = f.code; id = other })) };
      case null {};
    };
    if (f.discountBps > 9_000) return #err(#invalid({ what = "A discount is at most 90%." }));
    if (f.kind == #bar and f.discountBps != 0) return #err(#invalid({ what = "The best available rate has no discount." }));
    if (f.freeCancelDaysBefore > 255 or f.penaltyNights > 255) return #err(#invalid({ what = "The cancellation terms are out of range." }));
    switch (textsOk(c.s, [f.nameEn, f.nameAr])) { case (?r) return #err(r); case null {} };
    // a deposit comes with its share, which only `setPlanDeposit` sets
    if (f.guarantee == #deposit) return #err(#invalid({ what = "A deposit is set with its share, on the plan's deposit." }));
    // a plan not paid in advance keeps the deposit it has: `prepaid` false is "not prepaid", and whether
    // such a plan takes a deposit is the deposit's own setting
    let guarantee : E.Guarantee = switch (St.plan(c.s, target)) {
      case (?old) { if (old.guarantee == #deposit and f.guarantee == #firstNightAuthorised) #deposit else f.guarantee };
      case null f.guarantee;
    };
    if (id == 0) c.s.nextPlanId += 1;
    RowStore.put<R.RatePlan>(c.s.plans, R.ratePlan, target, {
      code = f.code; nameEn = TA.put(c.s.arena, f.nameEn); nameAr = TA.put(c.s.arena, f.nameAr); kind = f.kind;
      discountBps = f.discountBps; refundable = f.refundable; freeCancelDaysBefore = f.freeCancelDaysBefore;
      penaltyNights = f.penaltyNights; guarantee; modifiable = f.modifiable; active = f.active; lastBlock = c.block;
    });
    #ok([target])
  };

  public func upsertTaxRule(c : St.Ctx, id : Nat, f : Cmd.TaxRuleFacts) : Out {
    switch (codeOk(f.code)) { case (?r) return #err(r); case null {} };
    let target = if (id == 0) c.s.nextTaxId else id;
    if (id == 0 and c.s.nextTaxId > St.MAX_TAX_RULES) return #err(#invalid({ what = "A property has at most " # Nat.toText(St.MAX_TAX_RULES) # " tax rules." }));
    if (id != 0 and RowStore.get<R.TaxRule>(c.s.taxes, R.taxRule, id) == null) return #err(#noSuchTaxRule({ id }));
    switch (codeHolder<R.TaxRule>(c.s.taxes, R.taxRule, f.code)) {
      case (?other) { if (other != target) return #err(#codeTaken({ code = f.code; id = other })) };
      case null {};
    };
    if (f.kind == #percent and (f.bps == 0 or f.bps > 10_000)) return #err(#invalid({ what = "A percentage tax is between 0.01% and 100%." }));
    if (f.kind != #percent and f.amount == 0) return #err(#invalid({ what = "A fixed tax needs an amount." }));
    if (f.rank > 255 or f.amount >= 18_446_744_073_709_551_616) return #err(#invalid({ what = "The tax rule is out of range." }));
    switch (textsOk(c.s, [f.nameEn, f.nameAr])) { case (?r) return #err(r); case null {} };
    if (id == 0) c.s.nextTaxId += 1;
    RowStore.put<R.TaxRule>(c.s.taxes, R.taxRule, target, {
      code = f.code; nameEn = TA.put(c.s.arena, f.nameEn); nameAr = TA.put(c.s.arena, f.nameAr); kind = f.kind; bps = f.bps;
      amount = f.amount; base = f.base; rank = f.rank; active = f.active; lastBlock = c.block;
    });
    #ok([target])
  };

  /// The key guests' contact details are sealed to. Its private half lives on the hotel's own devices.
  public func setGuestDataKey(c : St.Ctx, key : Blob) : Out {
    let k = Blob.toArray(key);
    if (k.size() != 65 or k[0] != (4 : Nat8)) return #err(#invalid({ what = "The guest-data key is a raw uncompressed P-256 key." }));
    c.s.guestDataKey := key;
    // the team ring identity documents are filed under; a new key is a new epoch of it
    let ring = KeyRing.openRing(c.s.keys, "scope:hotel:team", c.day);
    #ok([ring.epoch])
  };

  public func setNights(c : St.Ctx, e : Cmd.NightsEdit) : Out {
    let ?prop = St.property(c.s) else return #err(#notConfigured);
    let writes = List.empty<(Nat, R.Night)>();
    switch (planEdit(c, prop, e, null, writes, Set.empty<Nat>())) { case (?r) return #err(r); case null {} };
    // every night has been checked; the writes begin
    for ((id, n) in List.values(writes)) RowStore.put<R.Night>(c.s.nights, R.night, id, n);
    #ok([List.size(writes)])
  };

  /// The most edits one save carries, and the most nights they may cover between them. An undo of a
  /// month of six room types is at most 186 one-night edits; both bounds sit above every screen's need.
  public let MAX_MANY_EDITS : Nat = 256;
  public let MAX_MANY_NIGHTS : Nat = 2_048;
  /// A percentage change takes a rate at most to eleven times itself, and never to nothing.
  public let MAX_ADJUST_UP_BPS : Nat = 100_000;

  /// Several edits, all or nothing: every edit is checked against the nights as they stand, the
  /// writes of all of them are gathered, and only when the last edit has passed is anything written.
  /// Two edits touching the same night are refused, so the order of the list cannot change the result.
  public func setNightsMany(c : St.Ctx, edits : [Cmd.ManyEdit]) : Out {
    let ?prop = St.property(c.s) else return #err(#notConfigured);
    if (edits.size() == 0) return #err(#invalid({ what = "A save carries at least one change." }));
    if (edits.size() > MAX_MANY_EDITS) return #err(#invalid({ what = "One save carries at most " # Nat.toText(MAX_MANY_EDITS) # " changes." }));
    var span = 0;
    for (m in edits.vals()) { if (m.edit.toDay > m.edit.fromDay) span += m.edit.toDay - m.edit.fromDay };
    if (span > MAX_MANY_NIGHTS) return #err(#editTooWide({ nights = span; max = MAX_MANY_NIGHTS }));
    let writes = List.empty<(Nat, R.Night)>();
    let touched = Set.empty<Nat>();
    for (m in edits.vals()) {
      switch (planEdit(c, prop, m.edit, m.adjust, writes, touched)) { case (?r) return #err(r); case null {} };
    };
    // every edit has been checked; the writes begin
    for ((id, n) in List.values(writes)) RowStore.put<R.Night>(c.s.nights, R.night, id, n);
    #ok([List.size(writes), edits.size()])
  };

  /// One edit's checks, in the order `setNights` has always made them, and the night rows it would
  /// write, added to `writes`. Writes nothing to the stores. `touched` holds the nights earlier edits of
  /// the same save will write; meeting one of them again is a refusal.
  func planEdit(c : St.Ctx, prop : R.Property, e : Cmd.NightsEdit, adjust : ?Cmd.RateAdjust, writes : List.List<(Nat, R.Night)>, touched : Set.Set<Nat>) : ?Rf.Refusal {
    let ?_ = St.roomType(c.s, e.roomTypeId) else return ?#noSuchRoomType({ id = e.roomTypeId });
    if (e.fromDay < c.day) return ?#inThePast({ day = e.fromDay; today = c.day });
    if (e.toDay <= e.fromDay) return ?#invalid({ what = "An edit covers at least one night." });
    if (e.toDay - e.fromDay > MAX_EDIT_NIGHTS) return ?#editTooWide({ nights = e.toDay - e.fromDay; max = MAX_EDIT_NIGHTS });
    if (e.toDay > c.day + prop.horizonDays) return ?#beyondHorizon({ day = e.toDay; lastDay = c.day + prop.horizonDays });
    if (e.weekdays == 0 or e.weekdays > 127) return ?#invalid({ what = "Choose at least one day of the week." });
    if (e.allotment == null and e.bar == null and e.minStay == null and e.maxStay == null
        and e.closedToArrival == null and e.closedToDeparture == null and e.stopSell == null and adjust == null) {
      return ?#invalid({ what = "The edit changes nothing." });
    };
    switch (e.minStay) { case (?m) { if (m == 0 or m > 255) return ?#invalid({ what = "A minimum stay is 1 to 255 nights." }) }; case null {} };
    switch (e.maxStay) { case (?m) { if (m > 255) return ?#invalid({ what = "A maximum stay is at most 255 nights." }) }; case null {} };
    switch (e.bar) { case (?b) { if (b == 0 or b >= 18_446_744_073_709_551_616) return ?#invalid({ what = "A rate is above zero." }) }; case null {} };
    switch (adjust) {
      case (?a) {
        if (e.bar != null) return ?#invalid({ what = "Set a rate or change it by a percentage, not both." });
        if (a.bps == 0) return ?#invalid({ what = "A percentage change is above zero." });
        if (not a.up and a.bps >= 10_000) return ?#invalid({ what = "A rate cannot fall by 100% or more." });
        if (a.up and a.bps > MAX_ADJUST_UP_BPS) return ?#invalid({ what = "A rate rises by at most " # Nat.toText(MAX_ADJUST_UP_BPS / 100) # "% in one change." });
      };
      case null {};
    };
    // the rooms of the type night by night: a room out of order with dates counts from its first night back
    let rooms = St.inService(c.s, c.x, e.roomTypeId);
    let rows = St.nightsRange(c.s, e.roomTypeId, e.fromDay, e.toDay);
    let mine = List.empty<(Nat, R.Night)>();
    var i = 0;
    while (i < rows.size()) {
      let d = e.fromDay + i;
      if ((e.weekdays / Nat.pow(2, Calendar.weekday(d))) % 2 == 1) {
        let id = R.nightId(e.roomTypeId, d);
        if (Set.contains(touched, Nat.compare, id)) return ?#invalid({ what = "Two changes in one save touch the same night (" # Nat.toText(d) # ")." });
        let base : R.Night = switch (rows[i]) {
          case (?n) n;
          case null {
            if (e.bar == null) return ?#invalid({ what = "Set a rate for nights that are not open yet (from " # Nat.toText(d) # ")." });
            { allotment = 0; sold = 0; held = 0; bar = 0; minStay = 1; maxStay = 0; closedToArrival = false; closedToDeparture = false; stopSell = false; lastBlock = 0 }
          };
        };
        let allotment = switch (e.allotment) { case (?a) a; case null base.allotment };
        if (e.allotment != null and allotment > St.inServiceOn(rooms, d)) {
          return ?#allotmentAboveRooms({ day = d; allotment; rooms = St.inServiceOn(rooms, d) });
        };
        // the rooms open group blocks hold that night are on hold too
        let held = base.held + St.blockedOn(c.x, e.roomTypeId, d);
        if (allotment < base.sold + held) {
          return ?#allotmentBelowSold({ day = d; sold = base.sold; held; allotment });
        };
        let minStay = switch (e.minStay) { case (?m) m; case null base.minStay };
        let maxStay = switch (e.maxStay) { case (?m) m; case null base.maxStay };
        if (maxStay > 0 and maxStay < minStay) return ?#invalid({ what = "A maximum stay below the minimum stay leaves no stay to sell." });
        let bar = switch (e.bar, adjust) {
          case (?b, _) b;
          case (null, ?a) {
            // exact: the stored rate times (1 ± bps/10⁴), rounded half-even once, as every price here is
            let factor : Nat = if (a.up) 10_000 + a.bps else 10_000 - a.bps;
            let next = Q.divHalfEven(base.bar * factor, 10_000);
            if (next == 0) return ?#invalid({ what = "The change would bring the rate on " # Nat.toText(d) # " to nothing." });
            if (next >= 18_446_744_073_709_551_616) return ?#invalid({ what = "The change would take the rate on " # Nat.toText(d) # " past the largest amount." });
            next
          };
          case (null, null) base.bar;
        };
        List.add(mine, (id, {
          base with
          allotment;
          bar;
          minStay; maxStay;
          closedToArrival = switch (e.closedToArrival) { case (?x) x; case null base.closedToArrival };
          closedToDeparture = switch (e.closedToDeparture) { case (?x) x; case null base.closedToDeparture };
          stopSell = switch (e.stopSell) { case (?x) x; case null base.stopSell };
          lastBlock = c.block;
        }));
      };
      i += 1;
    };
    if (List.size(mine) == 0) return ?#invalid({ what = "None of the chosen days of the week fall in this range." });
    // this edit has passed: its nights join the save's, and later edits may not touch them
    for ((id, n) in List.values(mine)) { List.add(writes, (id, n)); Set.add(touched, Nat.compare, id) };
    null
  };
}
