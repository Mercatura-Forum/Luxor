/// Audit.mo - the night audit: close the hotel's day, one bounded step at a time.
///
/// A run for business day D is opened with a plan fixed from recorded counts (the kernel's `Batch`):
/// rank 1 ends every hold that has expired, rank 2 marks as no-shows the arrivals of D that never
/// checked in (the penalty stands, the nights go back). While the run is open, acts dated on or before
/// D wait (`Batch.admitsAct`). When the plan is done the oracle walks every table; a single
/// violation keeps the day open, and `closeDay` rolls the business date to D + 1 only when the plan
/// completed, nothing failed, and the walk found nothing.
///
/// Items take work from the head of the partial index they drain (the expiry index, the arrivals of
/// D), because acting on a row removes it from that index: positions would shift under a cursor, and
/// the head never does.
///
/// Rank 5 releases the group blocks whose cut-off is the day (or before: a block made with a cut-off
/// already reached waits for the next audit): every room they still hold goes back on sale.
///
/// Rank 4 writes the day's figures (`R.DayFigures`, and `R.DayRevenue` by room type and plan): the
/// rooms by id, the guests in house who stay the night by the in-house index from a cursor kept in
/// the figures row, and the bookings made since the last day's figures by id. None of these drains
/// as it is read, and nothing moves under the run: while it is open every act dated D waits. The
/// counts they are planned from are written into the figures row when the run opens, so the plan is
/// recomputed from that row at every step. A run opened before the figures existed has no row, and
/// keeps the plan it was opened with.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Array "mo:core/Array";
import List "mo:core/List";
import Nat "mo:core/Nat";

import Page "mo:kernel/rows/Page";


import Batch "mo:kernel/batch/Batch";
import BatchCore "mo:kernel/batch/BatchCore";
import RowStore "mo:kernel/rows/RowStore";
import SR "mo:kernel/rows/StableRows";

import Blocks "Blocks";
import IdDocs "IdDocs";
import O "Oracle";
import Rules "Rules";
import R "Rows";
import Res "Reservations";
import Rf "Refusal";
import St "Store";
import W "Widths";

module {

  public type Out = { #ok : [Nat]; #err : Rf.Refusal };

  public let SCOPE : Text = St.AUDIT_SCOPE;
  let SWEEP : Batch.Job = { name = "sweep-holds"; rank = 1 };
  let NOSHOW : Batch.Job = { name = "no-shows"; rank = 2 };
  let ERASE : Batch.Job = { name = "erase-identity-documents"; rank = 3 };
  let FIGURES : Batch.Job = { name = "day-figures"; rank = 4 };
  let BLOCKS : Batch.Job = { name = "release-blocks"; rank = 5 };
  public let SHARD : Nat = 16;
  public let ORACLE_PAGE : Nat = 100;

  func arrivalsOf(s : St.Stores, day : Nat, maxId : Nat, limit : Nat) : [(Nat, R.Booking)] {
    let lo = SR.key2(day, W.DAY, 0, W.ID);
    let hi = SR.key2(day, W.DAY, maxId, W.ID);
    switch (RowStore.page<R.Booking>(s.bookings, R.booking, "arrivals", lo, hi, null, limit)) { case (#ok p) p.rows; case (#err _) [] }
  };

  /// The guests in house who stay night `day` (they leave after it), from just after `after`, up to
  /// `limit` of them. An index keeps entries a record has moved away from, and a page drops them
  /// (and may stop at its scan budget), so the pages are walked until `limit` rows or the end.
  func inHouseFrom(s : St.Stores, day : Nat, after : ?(Nat, Nat), limit : Nat) : [(Nat, R.Booking)] {
    let lo = switch after { case (?(d, id)) SR.key2(d, W.DAY, id + 1, W.ID); case null SR.key2(day + 1, W.DAY, 0, W.ID) };
    let hi = SR.key2(16_777_215, W.DAY, St.MAX_ID, W.ID);
    let out = List.empty<(Nat, R.Booking)>();
    var cursor : ?Page.Cursor = null;
    label pages loop {
      if (List.size(out) >= limit) break pages;
      switch (RowStore.page<R.Booking>(s.bookings, R.booking, "in_house", lo, hi, cursor, limit - List.size(out) : Nat)) {
        case (#err _) break pages;
        case (#ok p) {
          for (x in p.rows.vals()) List.add(out, x);
          switch (p.next) { case null break pages; case (?c) cursor := ?c };
        };
      };
    };
    List.toArray(out)
  };

  /// How many guests in house stay night `day`, counted as the job will read them. Each holds a room,
  /// so the count stops one past the hotel's rooms (a count I8 forbids).
  func inHouseCount(s : St.Stores, day : Nat, rooms : Nat) : Nat { inHouseFrom(s, day, null, rooms + 1).size() };

  /// A booking's room charges: of one night, or (`night` null) of every night.
  func roomCharges(s : St.Stores, id : Nat, night : ?Nat) : Nat {
    var sum = 0;
    for ((_, l) in St.folioOf(s, id).vals()) {
      if (l.kind == #roomNight) switch night { case (?d) { if (l.night == d) sum += l.amount }; case null sum += l.amount };
    };
    sum
  };

  func figures(c : St.Ctx, day : Nat) : ?R.DayFigures { St.dayFigures(c.x, day) };
  func putFigures(c : St.Ctx, day : Nat, f : R.DayFigures) {
    RowStore.put<R.DayFigures>(St.later(c.x, St.DAY_FIGURES_TABLE), R.dayFigures, day, { f with lastBlock = c.block })
  };

  /// Adds a booking's night to its room type and plan's revenue row for the night.
  func addRevenue(c : St.Ctx, day : Nat, b : R.Booking, nights : Nat, amount : Nat) {
    let t = St.later(c.x, St.DAY_REVENUE_TABLE);
    switch (St.dayRevenueRow(c.x, day, b.roomTypeId, b.planId)) {
      case (?(id, r)) RowStore.put<R.DayRevenue>(t, R.dayRevenue, id, { r with roomNights = r.roomNights + nights; revenue = r.revenue + amount; lastBlock = c.block });
      case null RowStore.put<R.DayRevenue>(t, R.dayRevenue, RowStore.size(t) + 1,
        { day; roomTypeId = b.roomTypeId; planId = b.planId; roomNights = nights; revenue = amount; lastBlock = c.block });
    };
  };

  type Counts = { expired : Nat; arrivals : Nat; erasures : Nat; figures : ?R.DayFigures; blocks : ?R.AuditBlocks };

  func planFor(n : Counts) : { #ok : [Batch.PlanItem]; #err : Batch.Fault } {
    let base = [
      { scope = "holds"; qualifier = ""; entities = n.expired; jobs = [SWEEP] },
      { scope = "arrivals"; qualifier = ""; entities = n.arrivals; jobs = [NOSHOW] },
      { scope = "identity"; qualifier = ""; entities = n.erasures; jobs = [ERASE] },
    ];
    let withFigures = switch (n.figures) {
      case null base;
      case (?f) Array.concat(base, [
        { scope = "figures-rooms"; qualifier = ""; entities = f.roomsTotal; jobs = [FIGURES] },
        { scope = "figures-house"; qualifier = ""; entities = f.inHouse; jobs = [FIGURES] },
        { scope = "figures-pickup"; qualifier = ""; entities = f.pickupCount; jobs = [FIGURES] },
      ]);
    };
    // the group blocks at their cut-off, counted when the run opened (a run opened before blocks
    // existed has no row and keeps the plan it was opened with)
    let scopes = switch (n.blocks) {
      case null withFigures;
      case (?b) Array.concat(withFigures, [{ scope = "blocks"; qualifier = ""; entities = b.due; jobs = [BLOCKS] }]);
    };
    Batch.plan({ scopes; shardSize = SHARD })
  };

  /// The counts the plan is fixed from are recorded in the run (its maxEntity and entity count), and
  /// recomputed from the same bound at every step, so the plan hash checks the run did not move.
  public func open(c : St.Ctx, day : Nat) : Out {
    if (day != c.day) return #err(#notTheDay({ day; today = c.day }));
    switch (BatchCore.get(c.s.audit, SCOPE, day)) {
      case (?run) { if (run.state == #completed) return #err(#audit({ reason = "The audit for this day has already run." })) else return #err(#auditOpen({ day })) };
      case null {};
    };
    let expired = Res.expiredHolds(c.s, c.height, 1_000).size();
    let maxId : Nat = c.s.nextBookingId - 1;
    let arrivals = arrivalsOf(c.s, day, maxId, 1_000).size();
    let erasures = IdDocs.due(c.s, day, 1_000).size();
    // the day's figures, planned from the counts as they stand now; bookings made since the last
    // day's figures (all of them before the first: every booking is new to the first figures)
    let roomsTotal = RowStore.size(c.s.rooms);
    let before = if (day == 0) null else figures(c, day - 1 : Nat);
    let pickupFrom = switch before { case (?p) p.pickupFrom + p.pickupCount; case null 1 };
    let fig : R.DayFigures = {
      roomsTotal; roomsSeen = 0; roomsOut = 0; roomsSold = 0; roomRevenue = 0;
      inHouse = inHouseCount(c.s, day, roomsTotal); houseSeen = 0; arrivals = 0; noShows = 0;
      pickupFrom; pickupCount = if (maxId + 1 > pickupFrom) maxId + 1 - pickupFrom else 0; pickupBookings = 0; pickupNights = 0; pickupRevenue = 0;
      cursorDay = 0; cursorId = 0; lastBlock = c.block;
    };
    let due = St.blocksDue(c.x, day, Blocks.MAX_BLOCKS).size();
    let blocks : R.AuditBlocks = { due; lastBlock = c.block };
    // under the rules of the first released build (epoch 0) the audit has its three first jobs and writes
    // no figures, so a log written then rebuilds as it was (`Rules`)
    let newer = Rules.from(c.x, Rules.FIGURES_FROM);
    let items = switch (planFor({ expired; arrivals; erasures; figures = if newer ?fig else null; blocks = if newer ?blocks else null })) {
      case (#ok x) x;
      case (#err f) return #err(#audit({ reason = Batch.faultText(f) }));
    };
    switch (BatchCore.open(c.s.audit, SCOPE, day, SHARD, items, c.block, c.height, maxId)) {
      case (#err (#AlreadyOpen _)) return #err(#auditOpen({ day }));
      case (#err _) return #err(#audit({ reason = "The audit plan could not be opened." }));
      case (#ok _) {};
    };
    c.s.auditCounts := (day, expired, arrivals, erasures);
    if (newer) {
      putFigures(c, day, fig);
      RowStore.put<R.AuditBlocks>(St.later(c.x, St.AUDIT_BLOCKS_TABLE), R.auditBlocks, day, blocks);
    };
    Rules.walkOpened(c);
    let w = c.s.walk;
    w.day := day; w.section := 0; w.cursor := null; w.examined := 0; w.violations := []; w.done := false;
    #ok([items.size(), expired, arrivals])
  };

  public func advance(c : St.Ctx, day : Nat, limit : Nat) : Out {
    let ?run = BatchCore.get(c.s.audit, SCOPE, day) else return #err(#audit({ reason = "No audit is open for this day." }));
    if (run.state != #completed) {
      // the plan is recomputed from the counts it recorded; the hash check in `advance` catches drift
      let (d, expired, arrivals, erasures) = c.s.auditCounts;
      if (d != day) return #err(#audit({ reason = "The audit's recorded counts are for another day." }));
      let items = switch (planFor({ expired; arrivals; erasures; figures = figures(c, day); blocks = St.auditBlocks(c.x, day) })) { case (#ok x) x; case (#err f) return #err(#audit({ reason = Batch.faultText(f) })) };
      let p = Res.newPending();
      let exec = func(_ : Nat, item : Batch.PlanItem) : BatchCore.Outcome {
        let want : Nat = if (Batch.isPerScope(item)) 0 else item.to - item.from;
        if (want == 0) return #ok({ examined = 0; movement = false });
        if (item.scope == "holds") {
          let due = Res.expiredHolds(c.s, c.height, want);
          if (due.size() == 0) return #ok({ examined = 0; movement = false });
          switch (Res.releaseExpired(c, want)) { case (#ok _) #ok({ examined = due.size(); movement = true }); case (#err r) #failed({ reason = Rf.text(r) }) }
        } else if (item.scope == "identity") {
          let rows = IdDocs.due(c.s, day, want);
          for ((id, d) in rows.vals()) IdDocs.erase(c, id, d);
          #ok({ examined = rows.size(); movement = rows.size() > 0 })
        } else if (item.scope == "blocks") {
          // the head of the open blocks in cut-off order: a released block leaves the index
          let rows = St.blocksDue(c.x, day, want);
          for ((id, _) in rows.vals()) ignore Blocks.release(c, id);
          #ok({ examined = rows.size(); movement = rows.size() > 0 })
        } else if (item.scope == "arrivals") {
          let rows = arrivalsOf(c.s, day, run.maxEntity, want);
          for ((id, b) in rows.vals()) Res.noShow(c, p, id, b);
          switch (figures(c, day)) { case (?f) putFigures(c, day, { f with noShows = f.noShows + rows.size() }); case null {} };
          #ok({ examined = rows.size(); movement = rows.size() > 0 })
        } else {
          let ?f = figures(c, day) else return #failed({ reason = "The day's figures row is missing." });
          if (item.scope == "figures-rooms") {
            // a shard's positions run from 1, its end not included: rooms are numbered from 1 in the same way
            let rows = RowStore.pageById<R.Room>(c.s.rooms, R.room, item.from, item.to - 1 : Nat, null, want).rows;
            var out = 0;
            for ((_, r) in rows.vals()) { if (r.status == #outOfOrder) out += 1 };
            putFigures(c, day, { f with roomsSeen = f.roomsSeen + rows.size(); roomsOut = f.roomsOut + out });
            #ok({ examined = rows.size(); movement = true })
          } else if (item.scope == "figures-house") {
            let after = if (f.cursorDay == 0) null else ?(f.cursorDay, f.cursorId);
            let rows = inHouseFrom(c.s, day, after, want);
            var sold = 0; var revenue = 0; var arrived = 0; var cd = f.cursorDay; var ci = f.cursorId;
            for ((id, b) in rows.vals()) {
              let night = roomCharges(c.s, id, ?day);
              sold += b.rooms; revenue += night;
              if (b.arrival == day) arrived += 1;
              addRevenue(c, day, b, b.rooms, night);
              cd := b.departure; ci := id;
            };
            putFigures(c, day, { f with roomsSold = f.roomsSold + sold; roomRevenue = f.roomRevenue + revenue; houseSeen = f.houseSeen + rows.size();
              arrivals = f.arrivals + arrived; cursorDay = cd; cursorId = ci });
            #ok({ examined = rows.size(); movement = true })
          } else {
            let rows = RowStore.pageById<R.Booking>(c.s.bookings, R.booking, f.pickupFrom + item.from - 1 : Nat, f.pickupFrom + item.to - 2 : Nat, null, want).rows;
            var nights = 0; var revenue = 0;
            for ((id, b) in rows.vals()) { nights += b.rooms * (b.departure - b.arrival : Nat); revenue += roomCharges(c.s, id, null) };
            putFigures(c, day, { f with pickupBookings = f.pickupBookings + rows.size(); pickupNights = f.pickupNights + nights; pickupRevenue = f.pickupRevenue + revenue });
            #ok({ examined = rows.size(); movement = true })
          }
        }
      };
      let lim = if (limit == 0 or limit > Batch.MAX_ADVANCE_LIMIT) Batch.MAX_ADVANCE_LIMIT else limit;
      switch (BatchCore.advance(c.s.audit, SCOPE, day, items, lim, exec)) {
        case (#err (#PlanDrift _)) return #err(#audit({ reason = "The audit plan changed under the run." }));
        case (#err _) return #err(#audit({ reason = "The audit could not advance." }));
        case (#ok pr) { Res.flush(c, p); return #ok([pr.itemsRun, if (pr.completed) 1 else 0, 0]) };
      };
    };
    if (c.s.walk.done) return #err(#audit({ reason = "The audit is complete; close the day." }));
    let st = O.step(c, ORACLE_PAGE);
    #ok([0, 1, st.examined])
  };

  public func close(c : St.Ctx, day : Nat) : Out {
    let ?run = BatchCore.get(c.s.audit, SCOPE, day) else return #err(#audit({ reason = "No audit is open for this day." }));
    if (run.state != #completed) return #err(#audit({ reason = "The audit's jobs have not finished." }));
    if (BatchCore.unresolvedFailures(run) > 0) return #err(#audit({ reason = Nat.toText(BatchCore.unresolvedFailures(run)) # " audit item(s) failed." }));
    if (not c.s.walk.done or c.s.walk.day != day) return #err(#audit({ reason = "The books have not been checked yet." }));
    if (c.s.walk.violations.size() > 0) return #err(#audit({ reason = "The books show " # Nat.toText(c.s.walk.violations.size()) # " problem(s); the day stays open." }));
    c.s.closedDays += 1;
    #ok([day + 1, c.s.walk.examined])
  };
}
