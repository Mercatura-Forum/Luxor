/// Blocks.mo - group blocks: a group's rooms taken out of sale, picked up from its rooming list.
///
/// A block takes `rooms` rooms of one type out of sale on every night of its dates: each of its nights
/// holds them (`blockNight.open`), and each hotel night counts what every open block holds there
/// (`nightBlock.open`), which `St.freeOn` takes out of what the night has free. The desk picks rooms up
/// from the block as bookings (`Reservations.bookByStaff` with the block): a pickup moves rooms from
/// the block's hold to the night's sold count, so the night's free rooms do not change. A pickup is
/// cancelled, marked a no-show or checked out early: its rooms go back to the block while the block is
/// open, and on sale once it is released. At the cut-off day's night audit, or when revenue releases
/// it, a block gives every room it still holds back on sale.
///
/// The writes keep three counts equal at every block: a block night's `picked` is the rooms of its
/// bookings that hold that night, its `open` is its rooms less `picked` while the block is open and 0
/// after, and a hotel night's `nightBlock.open` is the sum of the block nights on it (I15, oracle).
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Nat "mo:core/Nat";
import Text "mo:core/Text";

import RowStore "mo:kernel/rows/RowStore";

import R "Rows";
import Rf "Refusal";
import St "Store";
import TA "TextArena";

module {

  public type Out = { #ok : [Nat]; #err : Rf.Refusal };

  public let MAX_BLOCKS : Nat = 500;
  /// A block's nights: a month, the longest group stay a hotel contracts as one block.
  public let MAX_BLOCK_NIGHTS : Nat = 31;
  public let MAX_NAME : Nat = 120;

  public type BlockFacts = { name : Text; companyId : Nat; roomTypeId : Nat; planId : Nat; arrival : Nat; nights : Nat; rooms : Nat; cutoff : Nat };

  func sub(a : Nat, b : Nat) : Nat { if (a >= b) a - b else 0 };

  func nightBlockT(c : St.Ctx) : RowStore.Store { St.later(c.x, St.NIGHT_BLOCK_TABLE) };
  func blockNightT(c : St.Ctx) : RowStore.Store { St.later(c.x, St.BLOCK_NIGHT_TABLE) };

  /// Adds `more` and takes `less` from the rooms open blocks hold on a hotel night.
  func moveBlocked(c : St.Ctx, rt : Nat, day : Nat, more : Nat, less : Nat) {
    let was = St.blockedOn(c.x, rt, day);
    RowStore.put<R.NightBlock>(nightBlockT(c), R.nightBlock, R.nightId(rt, day), { open = sub(was + more, less); lastBlock = c.block });
  };

  /// A group block: id 0 adds one. A block keeps its room type, plan, company and dates once made; its
  /// name, rooms and cut-off may change while it is open. Every room it adds must be free on every
  /// night, and its rooms never fall below what has been picked up on any night.
  public func upsert(c : St.Ctx, id : Nat, f : BlockFacts) : Out {
    let table = St.later(c.x, St.BLOCK_TABLE);
    let n = RowStore.size(table);
    if (id == 0 and n >= MAX_BLOCKS) return #err(#invalid({ what = "A hotel has at most " # Nat.toText(MAX_BLOCKS) # " group blocks." }));
    let was = if (id == 0) null else switch (St.block(c.x, id)) { case (?b) ?b; case null return #err(#noSuchBlock({ id })) };
    let ?prop = St.property(c.s) else return #err(#notConfigured);
    let ?rt = St.roomType(c.s, f.roomTypeId) else return #err(#noSuchRoomType({ id = f.roomTypeId }));
    if (not rt.active) return #err(#inactive({ what = "room type"; id = f.roomTypeId }));
    let ?plan = St.plan(c.s, f.planId) else return #err(#noSuchPlan({ id = f.planId }));
    if (not plan.active) return #err(#inactive({ what = "rate plan"; id = f.planId }));
    if (f.companyId != 0 and St.company(c.x, f.companyId) == null) return #err(#invalid({ what = "There is no company " # Nat.toText(f.companyId) # "." }));
    // the block's plan is sold to its company (or to everyone): a pickup carries the company's access
    switch (St.planAccess(c.x, f.planId)) {
      case (?a) { if (a.closed and (a.companyId == 0 or a.companyId != f.companyId)) return #err(#closedRate({ planId = f.planId })) };
      case null {};
    };
    if (f.nights == 0 or f.nights > MAX_BLOCK_NIGHTS) return #err(#stayLength({ nights = f.nights; max = MAX_BLOCK_NIGHTS }));
    // at most what the nights have free plus what the block already holds (checked night by night below)
    if (f.rooms == 0) return #err(#invalid({ what = "A block holds at least one room." }));
    let departure = f.arrival + f.nights;
    switch was {
      case (?b) {
        if (not b.open) return #err(#blockReleased({ id }));
        if (b.roomTypeId != f.roomTypeId or b.planId != f.planId or b.companyId != f.companyId or b.arrival != f.arrival or b.departure != departure) {
          return #err(#invalid({ what = "A block keeps its room type, plan, company and dates; release it and add a new one." }));
        };
      };
      case null {
        if (f.arrival < c.day) return #err(#inThePast({ day = f.arrival; today = c.day }));
        if (departure > c.day + prop.horizonDays) return #err(#beyondHorizon({ day = departure; lastDay = c.day + prop.horizonDays }));
      };
    };
    if (f.cutoff < c.day) return #err(#inThePast({ day = f.cutoff; today = c.day }));
    if (f.cutoff > f.arrival) return #err(#invalid({ what = "The cut-off is on or before the group's arrival." }));
    let size = Text.encodeUtf8(f.name).size();
    if (size == 0) return #err(#invalid({ what = "A block needs the group's name." }));
    if (size > MAX_NAME) return #err(#tooLong({ what = "group name"; max = MAX_NAME }));
    switch (TA.fits(c.s.arena, [f.name], MAX_NAME)) { case (?why) return #err(#invalid({ what = why })); case null {} };
    // the rooms this act adds on each night are free there; the rooms it takes away were not picked up
    let target = if (id == 0) n + 1 else id;
    let rows = St.nightsRange(c.s, f.roomTypeId, f.arrival, departure);
    var i = 0;
    while (i < f.nights) {
      let d = f.arrival + i;
      let ?nt = rows[i] else return #err(#nightClosed({ day = d }));
      let picked = switch (St.blockNight(c.x, target, d)) { case (?bn) bn.picked; case null 0 };
      if (f.rooms < picked) return #err(#invalid({ what = Nat.toText(picked) # " room(s) are already picked up from the block on that night." }));
      let had = switch was { case (?b) b.rooms; case null 0 };
      if (f.rooms > had) {
        let free = St.freeOn(c.x, f.roomTypeId, d, nt);
        if (free < sub(f.rooms, had)) return #err(#soldOut({ day = d; free; wanted = sub(f.rooms, had) }));
      };
      i += 1;
    };
    // ── every check is above this line; nothing below can refuse ──
    let had = switch was { case (?b) b.rooms; case null 0 };
    var k = 0;
    while (k < f.nights) {
      let d = f.arrival + k;
      let picked = switch (St.blockNight(c.x, target, d)) { case (?bn) bn.picked; case null 0 };
      RowStore.put<R.BlockNight>(blockNightT(c), R.blockNight, R.blockNightId(target, d),
        { night = R.nightId(f.roomTypeId, d); picked; open = sub(f.rooms, picked); lastBlock = c.block });
      moveBlocked(c, f.roomTypeId, d, f.rooms, had);
      k += 1;
    };
    RowStore.put<R.Block>(table, R.block, target, { name = TA.put(c.s.arena, f.name); companyId = f.companyId; roomTypeId = f.roomTypeId; planId = f.planId;
      arrival = f.arrival; departure; rooms = f.rooms; cutoff = f.cutoff; open = true; lastBlock = c.block });
    #ok([target])
  };

  /// Every room a block still holds goes back on sale; the block takes no more pickups. Its rooming
  /// list stays. Called by revenue, and by the night audit on the cut-off day.
  public func release(c : St.Ctx, id : Nat) : Out {
    let ?b = St.block(c.x, id) else return #err(#noSuchBlock({ id }));
    if (not b.open) return #err(#blockReleased({ id }));
    // ── every check is above this line; nothing below can refuse ──
    var d = b.arrival;
    while (d < b.departure) {
      switch (St.blockNight(c.x, id, d)) {
        case (?bn) {
          moveBlocked(c, b.roomTypeId, d, 0, bn.open);
          RowStore.put<R.BlockNight>(blockNightT(c), R.blockNight, R.blockNightId(id, d), { bn with open = 0; lastBlock = c.block });
        };
        // kept on purpose and never reached: `upsert` writes a row for every night of the block
        case null {};
      };
      d += 1;
    };
    RowStore.put<R.Block>(St.later(c.x, St.BLOCK_TABLE), R.block, id, { b with open = false; lastBlock = c.block });
    #ok([id])
  };

  /// Can `rooms` rooms be picked up from the block for these nights? The stay must be the block's room
  /// type and plan, within its dates, while it is open, with the rooms still held on every night.
  public func checkPickup(c : St.Ctx, id : Nat, roomTypeId : Nat, planId : Nat, arrival : Nat, nights : Nat, rooms : Nat) : ?Rf.Refusal {
    let ?b = St.block(c.x, id) else return ?#noSuchBlock({ id });
    if (not b.open) return ?#blockReleased({ id });
    if (roomTypeId != b.roomTypeId or planId != b.planId) return ?#invalid({ what = "A pickup is the block's room type and rate plan." });
    if (arrival < b.arrival or arrival + nights > b.departure) return ?#invalid({ what = "A pickup's nights are within the block's dates." });
    var d = arrival;
    while (d < arrival + nights) {
      let open = switch (St.blockNight(c.x, id, d)) { case (?bn) bn.open; case null 0 };
      if (open < rooms) return ?#blockFull({ id; day = d; open; wanted = rooms });
      d += 1;
    };
    null
  };

  /// The pickup's writes, after every check of the act: the rooms move from the block's hold to the
  /// booking, and the booking is put on the block's rooming list.
  public func pick(c : St.Ctx, id : Nat, bookingId : Nat, roomTypeId : Nat, arrival : Nat, departure : Nat, rooms : Nat) {
    var d = arrival;
    while (d < departure) {
      switch (St.blockNight(c.x, id, d)) {
        case (?bn) RowStore.put<R.BlockNight>(blockNightT(c), R.blockNight, R.blockNightId(id, d), { bn with picked = bn.picked + rooms; open = sub(bn.open, rooms); lastBlock = c.block });
        // kept on purpose and never reached: `checkPickup` refused a night the block does not hold
        case null {};
      };
      moveBlocked(c, roomTypeId, d, 0, rooms);
      d += 1;
    };
    RowStore.put<R.BookingBlock>(St.later(c.x, St.BOOKING_BLOCK_TABLE), R.bookingBlock, bookingId, { blockId = id; lastBlock = c.block });
  };

  /// A picked-up booking gives back nights `from`..`to`: they leave the block's pickup, and go back to
  /// the block while it is open (on sale once it is released). Nothing for a booking from no block.
  public func giveBack(c : St.Ctx, bookingId : Nat, roomTypeId : Nat, from : Nat, to : Nat, rooms : Nat) {
    let ?bb = St.bookingBlock(c.x, bookingId) else return;
    let ?b = St.block(c.x, bb.blockId) else return;
    var d = from;
    while (d < to) {
      switch (St.blockNight(c.x, bb.blockId, d)) {
        case (?bn) {
          let back = if (b.open) rooms else 0;
          RowStore.put<R.BlockNight>(blockNightT(c), R.blockNight, R.blockNightId(bb.blockId, d), { bn with picked = sub(bn.picked, rooms); open = bn.open + back; lastBlock = c.block });
          if (back > 0) moveBlocked(c, roomTypeId, d, back, 0);
        };
        // kept on purpose and never reached: a pickup's nights are within its block's (`checkPickup`)
        case null {};
      };
      d += 1;
    };
  };
}
