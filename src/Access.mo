/// Access.mo - who a rate is sold to.
///
/// A rate plan is on public sale unless its access row closes it. A closed plan is sold only to one
/// company's bookings, or, closed with no company, only under a promotion's code that names it, within
/// the promotion's booking and stay windows and its uses. A code
/// a guest or a member of staff gives resolves to the access it grants; the stay check asks whether
/// that access admits the plan, the confirmation asks again (a company may have been closed between the
/// hold and its confirmation), and the access a closed rate was sold under is kept beside the hold and
/// the booking (`holdRate`, `bookingRate`), so a later change to the booking is checked under it too.
///
/// A company's or a promotion's code is a marketing code its bookers share, not a secret: it opens a
/// price, never a booking, a person or money, so it travels in the command like any other field.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import List "mo:core/List";
import Nat "mo:core/Nat";
import Text "mo:core/Text";

import CivilDate "mo:kernel/num/CivilDate";
import RowStore "mo:kernel/rows/RowStore";

import R "Rows";
import Rf "Refusal";
import St "Store";

module {

  public type Grant = { companyId : Nat; promoId : Nat };

  /// The public sale: no code given.
  public let PUBLIC : Grant = { companyId = 0; promoId = 0 };

  public func isPublic(g : Grant) : Bool { g.companyId == 0 and g.promoId == 0 };

  /// The access a code grants: a company's, while its rates are on sale, or a promotion's, while it is
  /// on sale. A code is stored in capitals; what was typed is matched in capitals, without the spaces
  /// around it. Companies and promotions share one set of codes (each upsert refuses the other's).
  public func resolve(c : St.Ctx, typed : Text) : { #ok : Grant; #err : Rf.Refusal } {
    let code = Text.toUpper(Text.trim(typed, #char ' '));
    switch (St.companyByCode(c.x, code)) {
      case (?(id, co)) { return if (co.active) #ok({ companyId = id; promoId = 0 }) else #err(#noSuchCode({ code })) };
      case null {};
    };
    switch (St.promoByCode(c.x, code)) {
      case (?(id, pr)) { if (pr.active) #ok({ companyId = 0; promoId = id }) else #err(#noSuchCode({ code })) };
      case null #err(#noSuchCode({ code }));
    }
  };

  /// A sale being checked: the stay, and whether it is a new booking (a hold, a confirmation, a booking
  /// by staff), which a promotion's booking window and uses apply to, or a change to a booking already
  /// made, which keeps the use it counted.
  public type Sale = { arrival : Nat; nights : Nat; counts : Bool };

  /// The access a new sale of this plan is made under: a promotion's code counts only on the plan it
  /// names while that plan is closed to everyone but codes; on any other plan the code is the public
  /// sale, so a promotion is never counted for a booking it did not open.
  public func forPlan(c : St.Ctx, g : Grant, planId : Nat) : Grant {
    if (g.promoId == 0) return g;
    let opened = switch (St.planAccess(c.x, planId), St.promo(c.x, g.promoId)) {
      case (?a, ?pr) a.closed and a.companyId == 0 and pr.planId == planId;
      case _ false;
    };
    if (opened) g else ({ g with promoId = 0 })
  };

  /// Whether this access admits the plan. A plan closed to a company admits that company while its rates
  /// are on sale. A sale under a promotion that names the plan is held to the promotion: on sale, and,
  /// with a sale, within its windows and uses. A plan closed to everyone but codes admits nothing else;
  /// any other plan admits every access. With no sale (a listing), only whether the plan is the
  /// access's at all is asked.
  ///
  /// A new sale reaches here through `forPlan`, so a promotion meets an open plan only when the plan was
  /// opened after the hold or the booking was made under it; its rules still hold there, which is what
  /// keeps a promotion's count within its limit.
  public func admits(c : St.Ctx, planId : Nat, g : Grant, sale : ?Sale) : ?Rf.Refusal {
    let access = St.planAccess(c.x, planId);
    switch access {
      case (?a) {
        if (a.closed and a.companyId != 0) {
          if (g.companyId != a.companyId) return ?#closedRate({ planId });
          return switch (St.company(c.x, a.companyId)) { case (?co) { if (co.active) null else ?#closedRate({ planId }) }; case null ?#closedRate({ planId }) };
        };
      };
      case null {};
    };
    let toCodes = switch access { case (?a) a.closed; case null false };
    let named = if (g.promoId == 0) null else switch (St.promo(c.x, g.promoId)) { case (?pr) { if (pr.planId == planId) ?pr else null }; case null null };
    let ?pr = named else return if (toCodes) ?#closedRate({ planId }) else null;
    if (not pr.active) return if (toCodes) ?#closedRate({ planId }) else ?#promoClosed({ code = pr.code; why = "is off sale." });
    switch sale {
      case null null;
      case (?x) {
        if (x.counts and (c.day < pr.bookFrom or c.day > pr.bookUntil))
          return ?#promoClosed({ code = pr.code; why = "is booked from " # CivilDate.toText(pr.bookFrom) # " to " # CivilDate.toText(pr.bookUntil) # "." });
        if (x.arrival < pr.stayFrom or x.arrival + x.nights > pr.stayUntil + 1)
          return ?#promoClosed({ code = pr.code; why = "is for nights from " # CivilDate.toText(pr.stayFrom) # " to " # CivilDate.toText(pr.stayUntil) # "." });
        if (x.counts and pr.maxUses > 0 and pr.used >= pr.maxUses)
          return ?#promoClosed({ code = pr.code; why = "has been used " # Nat.toText(pr.used) # " times, all it may be." });
        null
      };
    }
  };

  /// The active plans this access opens that the public sale does not: what a code is worth to the
  /// guest who typed it. Bounded by the plan count.
  public func opens(c : St.Ctx, g : Grant) : [Nat] {
    let out = List.empty<Nat>();
    let pg = RowStore.pageById<R.PlanAccess>(St.later(c.x, St.PLAN_ACCESS_TABLE), R.planAccess, 1, St.MAX_PLANS, null, St.MAX_PLANS);
    for ((planId, a) in pg.rows.vals()) {
      if (a.closed and admits(c, planId, g, null) == null) {
        switch (St.plan(c.s, planId)) { case (?p) { if (p.active) List.add(out, planId) }; case null {} };
      };
    };
    List.toArray(out)
  };

  /// Whether a plan is on public sale: what the public search and the waitlist offer.
  public func onPublicSale(x : St.Later, planId : Nat) : Bool {
    switch (St.planAccess(x, planId)) { case (?a) not a.closed; case null true }
  };

  /// The access a hold or a booking was sold under; the public sale when none is kept.
  public func ofHold(x : St.Later, holdId : Nat) : Grant {
    switch (St.holdRate(x, holdId)) { case (?r) ({ companyId = r.companyId; promoId = r.promoId }); case null PUBLIC }
  };
  public func ofBooking(x : St.Later, bookingId : Nat) : Grant {
    switch (St.bookingRate(x, bookingId)) { case (?r) ({ companyId = r.companyId; promoId = r.promoId }); case null PUBLIC }
  };

  /// Keep the access a hold or a booking was sold under; the public sale keeps nothing. A booking under
  /// a promotion counts its use here: the promotion's count goes up by one and the booking keeps the
  /// number of its use. Called after every check, where nothing can refuse.
  public func keepForHold(c : St.Ctx, holdId : Nat, g : Grant) {
    if (not isPublic(g)) RowStore.put<R.RateGrant>(St.later(c.x, St.HOLD_RATE_TABLE), R.holdRate, holdId, { g with use = 0; lastBlock = c.block });
  };
  public func keepForBooking(c : St.Ctx, bookingId : Nat, g : Grant) {
    if (isPublic(g)) return;
    var use = 0;
    if (g.promoId != 0) {
      switch (St.promo(c.x, g.promoId)) {
        case (?pr) {
          use := pr.used + 1;
          RowStore.put<R.Promo>(St.later(c.x, St.PROMO_TABLE), R.promo, g.promoId, { pr with used = use; lastBlock = c.block });
        };
        // kept on purpose and never reached: the sale was admitted under this promotion in the same act,
        // which refuses a promotion that does not exist (`admits`)
        case null {};
      };
    };
    RowStore.put<R.RateGrant>(St.later(c.x, St.BOOKING_RATE_TABLE), R.bookingRate, bookingId, { g with use; lastBlock = c.block });
  };
}
