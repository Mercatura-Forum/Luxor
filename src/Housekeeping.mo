/// Housekeeping.mo - the state of each room between guests: dirty, clean, inspected, out of order.
///
/// A guest leaving makes each of their rooms dirty (Reservations.checkOut calls `vacated`). A member of
/// housekeeping marks it clean; a second person inspects it, by comparing principals as four eyes does
/// for money, so "inspected" means two people have stood in the room. Any of the three may be marked
/// dirty again.
///
/// OUT OF ORDER HAS DATES. A room taken out with a reason until a day leaves its type's count only for
/// the nights before that day, so a hotel that offers every room it has can take one out for two
/// nights without lowering a year of allotments. On every night it leaves, the type must still have as
/// many rooms as the night offers (`roomsSuffice`, checked before anything is written); the law I1
/// counts the same way (Store.countsOn). If the day comes and the room is not back, it counts again
/// and the board shows it as due back: the date is a promise to sell the room, kept or broken in the
/// open. A room out of order from its setup (upsertRoom) has no dates and is out until put back.
///
/// The housekeeping row is a later table (Store.Later), under the room's own id. A room with no row has
/// no recorded cleaning: it was in service before this table existed, or has not been touched since.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Text "mo:core/Text";

import RowStore "mo:kernel/rows/RowStore";

import E "Enums";
import R "Rows";
import Rf "Refusal";
import St "Store";
import TA "TextArena";

module {

  public type Out = { #ok : [Nat]; #err : Rf.Refusal };

  public let MAX_REASON_BYTES : Nat = 160;

  let NONE : R.Housekeeping = {
    cleaning = #dirty; cleanedBy = null; inspectedBy = null; outReason = TA.EMPTY; outFrom = 0; outUntil = 0; changedDay = 0; lastBlock = 0;
  };

  func put(c : St.Ctx, roomId : Nat, h : R.Housekeeping) {
    RowStore.put<R.Housekeeping>(St.later(c.x, St.HK_TABLE), R.housekeeping, roomId, { h with changedDay = c.day; lastBlock = c.block });
  };

  public func cleaningText(h : ?R.Housekeeping) : Text {
    switch h { case (?x) E.cleaningText(x.cleaning); case null "not recorded" }
  };

  /// How ready a vacant room is for an arriving guest, readiest lowest: inspected, clean, not recorded,
  /// dirty. Check-in offers rooms in this order.
  public func readiness(h : ?R.Housekeeping) : Nat {
    switch h { case (?x) { switch (x.cleaning) { case (#inspected) 0; case (#clean) 1; case (#dirty) 3 } }; case null 2 }
  };

  /// Whether a room may leave its type's count on the nights `lost` names: on each such night in the
  /// horizon that is open, the rooms left must still cover the allotment. Reads only; no write.
  public func roomsSuffice(c : St.Ctx, horizonDays : Nat, rt : Nat, lost : Nat -> Bool) : ?Rf.Refusal {
    let v = St.inService(c.s, c.x, rt);
    let rows = St.nightsRange(c.s, rt, c.day, c.day + horizonDays);
    var i = 0;
    while (i < rows.size()) {
      let d = c.day + i;
      switch (rows[i]) {
        case (?nt) {
          if (lost(d)) {
            let n = St.inServiceOn(v, d);
            let left : Nat = if (n == 0) 0 else n - 1;
            if (nt.allotment > left) return ?#allotmentAboveRooms({ day = d; allotment = nt.allotment; rooms = left });
          };
        };
        case null {};
      };
      i += 1;
    };
    null
  };

  public func mark(c : St.Ctx, staff : Principal, roomId : Nat, cleaning : E.Cleaning) : Out {
    let ?r = St.room(c.s, roomId) else return #err(#noSuchRoom({ id = roomId }));
    if (r.status == #outOfOrder) return #err(#invalid({ what = "Room " # r.number # " is out of order; put it back in service first." }));
    let h = St.housekeeping(c.x, roomId);
    let now : ?E.Cleaning = switch h { case (?x) ?x.cleaning; case null null };
    if (now == ?cleaning) return #err(#invalid({ what = "Room " # r.number # " is already " # E.cleaningText(cleaning) # "." }));
    let base = switch h { case (?x) x; case null NONE };
    let next : R.Housekeeping = switch cleaning {
      case (#dirty) ({ base with cleaning = #dirty; cleanedBy = null; inspectedBy = null });
      case (#clean) ({ base with cleaning = #clean; cleanedBy = ?staff; inspectedBy = null });
      case (#inspected) {
        if (now != ?#clean) return #err(#invalid({ what = "Only a clean room is inspected; room " # r.number # " is " # cleaningText(h) # "." }));
        // a clean room always names its cleaner (only this command makes a room clean, and it records who)
        if (base.cleanedBy == ?staff) return #err(#invalid({ what = "A room is inspected by someone other than the person who cleaned it." }));
        { base with cleaning = #inspected; inspectedBy = ?staff }
      };
    };
    put(c, roomId, next);
    #ok([roomId, Nat8.toNat(E.cleaningByte(cleaning))])
  };

  public func takeOut(c : St.Ctx, roomId : Nat, reason : Text, untilDay : Nat) : Out {
    let ?prop = St.property(c.s) else return #err(#notConfigured);
    let ?r = St.room(c.s, roomId) else return #err(#noSuchRoom({ id = roomId }));
    if (r.occupiedBy != 0) return #err(#roomNotVacant({ id = roomId }));
    let n = Text.encodeUtf8(reason).size();
    if (n == 0) return #err(#invalid({ what = "Say why the room is out of order." }));
    if (n > MAX_REASON_BYTES) return #err(#tooLong({ what = "reason"; max = MAX_REASON_BYTES }));
    if (untilDay <= c.day) return #err(#invalid({ what = "A room out of order is back on a day after today." }));
    let lastDay = c.day + prop.horizonDays;
    if (untilDay > lastDay) return #err(#beyondHorizon({ day = untilDay; lastDay }));
    let h = St.housekeeping(c.x, roomId);
    let dated : ?R.Housekeeping = switch h { case (?x) { if (r.status == #outOfOrder and x.outUntil > 0) ?x else null }; case null null };
    let sameReason = switch dated { case (?x) TA.get(c.s.arena, x.outReason) == reason; case null false };
    switch dated { case (?x) { if (sameReason and x.outUntil == untilDay) return #err(#invalid({ what = "Room " # r.number # " is already out of order until that day, for that reason." })) }; case null {} };
    // the nights it leaves the count: those it counts on now and will not while it is out
    let leaves = func(d : Nat) : Bool { d < untilDay and St.countsOn(r, h, d) };
    switch (roomsSuffice(c, prop.horizonDays, r.roomTypeId, leaves)) { case (?x) return #err(x); case null {} };
    if (not sameReason) { switch (TA.fits(c.s.arena, [reason], MAX_REASON_BYTES)) { case (?why) return #err(#invalid({ what = why })); case null {} } };

    // ── every check is above this line; nothing below can refuse ──
    let reasonRef = switch dated { case (?x) { if (sameReason) x.outReason else TA.put(c.s.arena, reason) }; case null TA.put(c.s.arena, reason) };
    let outFrom = switch dated { case (?x) x.outFrom; case null c.day };
    RowStore.put<R.Room>(c.s.rooms, R.room, roomId, { r with status = #outOfOrder; lastBlock = c.block });
    put(c, roomId, { NONE with outReason = reasonRef; outFrom; outUntil = untilDay });
    #ok([roomId, untilDay])
  };

  public func returnToService(c : St.Ctx, roomId : Nat) : Out {
    let ?r = St.room(c.s, roomId) else return #err(#noSuchRoom({ id = roomId }));
    if (r.status != #outOfOrder) return #err(#invalid({ what = "Room " # r.number # " is in service." }));
    // a room coming back adds to its type's count on every night: nothing to check against the allotments
    RowStore.put<R.Room>(c.s.rooms, R.room, roomId, { r with status = #active; lastBlock = c.block });
    put(c, roomId, NONE);
    #ok([roomId])
  };

  /// A guest has left the room (checkOut, after its checks): it is dirty, and whoever cleaned or
  /// inspected it before the stay no longer vouches for it.
  public func vacated(c : St.Ctx, roomId : Nat) {
    let base = switch (St.housekeeping(c.x, roomId)) { case (?x) x; case null NONE };
    put(c, roomId, { base with cleaning = #dirty; cleanedBy = null; inspectedBy = null });
  };

  /// The room's setup put it back in service (upsertRoom): its dates and reason end with the outage.
  public func setupReturned(c : St.Ctx, roomId : Nat) {
    switch (St.housekeeping(c.x, roomId)) {
      case (?h) { if (h.outUntil > 0 or h.outReason.length > 0) put(c, roomId, { h with outReason = TA.EMPTY; outFrom = 0; outUntil = 0 }) };
      case null {};
    };
  };
}
