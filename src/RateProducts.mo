/// RateProducts.mo - the rates the hotel sells beyond its public plans: companies with negotiated
/// rates (a plan closed to one company), promotions (a code opening a plan closed to everyone else,
/// for a booking window, a stay window and a number of uses), and who each plan is sold to.
///
/// Every check comes before the first write. A company's id is the next after the companies there are
/// (they are never removed: a company whose rates are off sale is marked, so the bookings it made keep
/// naming it).
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
import W "Widths";

module {

  public type Out = { #ok : [Nat]; #err : Rf.Refusal };

  public let MAX_COMPANIES : Nat = 500;
  public let MAX_NAME : Nat = 120;

  /// A code a guest types: capital letters, digits and dashes, 1 to 16 of them, so that a code read
  /// aloud or typed in either case is the same code.
  public func codeShape(code : Text) : ?Rf.Refusal {
    let b = Text.encodeUtf8(code);
    if (b.size() == 0) return ?#invalid({ what = "A code is required." });
    if (b.size() > W.CODE) return ?#tooLong({ what = "code"; max = W.CODE });
    for (x in b.vals()) {
      let ok = (x >= (65 : Nat8) and x <= (90 : Nat8)) or (x >= (48 : Nat8) and x <= (57 : Nat8)) or x == (45 : Nat8);
      if (not ok) return ?#invalid({ what = "A code is capital letters, digits and dashes." });
    };
    null
  };

  public func upsertCompany(c : St.Ctx, id : Nat, code : Text, name : Text, active : Bool) : Out {
    switch (codeShape(code)) { case (?r) return #err(r); case null {} };
    let table = St.later(c.x, St.COMPANY_TABLE);
    let n = RowStore.size(table);
    let target = if (id == 0) n + 1 else id;
    if (id == 0 and n >= MAX_COMPANIES) return #err(#invalid({ what = "A hotel has at most " # Nat.toText(MAX_COMPANIES) # " companies." }));
    if (id != 0 and St.company(c.x, id) == null) return #err(#invalid({ what = "There is no company " # Nat.toText(id) # "." }));
    switch (St.companyByCode(c.x, code)) {
      case (?(other, _)) { if (other != target) return #err(#codeTaken({ code; id = other })) };
      case null {};
    };
    // companies and promotions share one set of codes: a typed code is one or the other
    switch (St.promoByCode(c.x, code)) { case (?(other, _)) return #err(#codeTaken({ code; id = other })); case null {} };
    let size = Text.encodeUtf8(name).size();
    if (size == 0) return #err(#invalid({ what = "A company needs a name." }));
    if (size > MAX_NAME) return #err(#tooLong({ what = "company name"; max = MAX_NAME }));
    switch (TA.fits(c.s.arena, [name], MAX_NAME)) { case (?why) return #err(#invalid({ what = why })); case null {} };
    // ── every check is above this line; nothing below can refuse ──
    RowStore.put<R.Company>(table, R.company, target, { code; name = TA.put(c.s.arena, name); active; lastBlock = c.block });
    #ok([target])
  };

  public let MAX_PROMOS : Nat = 500;
  public let MAX_USES : Nat = 1_000_000;
  /// How far ahead a promotion's windows may reach, in days: a year and a half of the hotel's horizon.
  public let MAX_WINDOW : Nat = 550;

  public type PromoFacts = { code : Text; name : Text; planId : Nat; bookFrom : Nat; bookUntil : Nat; stayFrom : Nat; stayUntil : Nat; maxUses : Nat; active : Bool };

  /// A promotion: id 0 adds one. It keeps its plan and the uses it has counted when it is changed; a
  /// promotion that has done its work is taken off sale, never removed, so its bookings keep naming it.
  public func upsertPromo(c : St.Ctx, id : Nat, f : PromoFacts) : Out {
    switch (codeShape(f.code)) { case (?r) return #err(r); case null {} };
    let table = St.later(c.x, St.PROMO_TABLE);
    let n = RowStore.size(table);
    let target = if (id == 0) n + 1 else id;
    if (id == 0 and n >= MAX_PROMOS) return #err(#invalid({ what = "A hotel has at most " # Nat.toText(MAX_PROMOS) # " promotions." }));
    let was = if (id == 0) null else switch (St.promo(c.x, id)) { case (?p) ?p; case null return #err(#invalid({ what = "There is no promotion " # Nat.toText(id) # "." })) };
    switch (St.promoByCode(c.x, f.code)) {
      case (?(other, _)) { if (other != target) return #err(#codeTaken({ code = f.code; id = other })) };
      case null {};
    };
    switch (St.companyByCode(c.x, f.code)) { case (?(other, _)) return #err(#codeTaken({ code = f.code; id = other })); case null {} };
    if (St.plan(c.s, f.planId) == null) return #err(#noSuchPlan({ id = f.planId }));
    switch was { case (?p) { if (p.planId != f.planId) return #err(#invalid({ what = "A promotion keeps its plan; add a new promotion for another." })) }; case null {} };
    if (f.bookFrom > f.bookUntil) return #err(#invalid({ what = "The booking window ends before it begins." }));
    if (f.stayFrom > f.stayUntil) return #err(#invalid({ what = "The stay window ends before it begins." }));
    if (f.bookUntil > c.day + MAX_WINDOW or f.stayUntil > c.day + MAX_WINDOW) return #err(#invalid({ what = "A promotion's windows end within " # Nat.toText(MAX_WINDOW) # " days." }));
    if (f.maxUses > MAX_USES) return #err(#invalid({ what = "A promotion is used at most " # Nat.toText(MAX_USES) # " times; 0 is no limit." }));
    let used = switch was { case (?p) p.used; case null 0 };
    if (f.maxUses != 0 and f.maxUses < used) return #err(#invalid({ what = "The promotion has been used " # Nat.toText(used) # " times already." }));
    let size = Text.encodeUtf8(f.name).size();
    if (size == 0) return #err(#invalid({ what = "A promotion needs a name the guest is shown." }));
    if (size > MAX_NAME) return #err(#tooLong({ what = "promotion name"; max = MAX_NAME }));
    switch (TA.fits(c.s.arena, [f.name], MAX_NAME)) { case (?why) return #err(#invalid({ what = why })); case null {} };
    // ── every check is above this line; nothing below can refuse ──
    RowStore.put<R.Promo>(table, R.promo, target, { code = f.code; name = TA.put(c.s.arena, f.name); planId = f.planId; bookFrom = f.bookFrom; bookUntil = f.bookUntil;
      stayFrom = f.stayFrom; stayUntil = f.stayUntil; maxUses = f.maxUses; used; active = f.active; lastBlock = c.block });
    #ok([target])
  };

  public func setPlanAccess(c : St.Ctx, planId : Nat, companyId : Nat, closed : Bool) : Out {
    if (St.plan(c.s, planId) == null) return #err(#noSuchPlan({ id = planId }));
    if (companyId != 0 and St.company(c.x, companyId) == null) return #err(#invalid({ what = "There is no company " # Nat.toText(companyId) # "." }));
    if (companyId != 0 and not closed) return #err(#invalid({ what = "A plan named for a company is closed to it; open it to everyone with no company." }));
    // ── every check is above this line; nothing below can refuse ──
    RowStore.put<R.PlanAccess>(St.later(c.x, St.PLAN_ACCESS_TABLE), R.planAccess, planId, { companyId; closed; lastBlock = c.block });
    #ok([planId])
  };

  // ── packages ────────────────────────────────────────────────────────────────

  /// The most of one extra an inclusion gives per room, adult or guest.
  public let MAX_INCLUSION_QUANTITY : Nat = 9;

  public type Inclusion = { extraId : Nat; quantity : Nat; rhythm : E.Rhythm; per : E.Per };

  /// A plan's package, set whole: the inclusions given are its slots 1, 2, … in order, and any slot it
  /// had beyond them is taken off. An empty list makes the plan a plain rate again. Each inclusion is an
  /// extra on sale with a set price (its price is added to the rate, so it must have one), once per
  /// package. Bookings already made keep the lines they were sold with.
  /// A plan's deposit set: a whole percentage of the room's stay (100 to 9,900 basis points), captured at
  /// confirmation, the plan then guaranteed by its deposit; or 0, the plan guaranteed by its first night
  /// again. A plan paid in advance has taken the whole stay and takes no deposit.
  public let MIN_DEPOSIT_BPS : Nat = 100;
  public let MAX_DEPOSIT_BPS : Nat = 9_900;

  public func setPlanDeposit(c : St.Ctx, planId : Nat, depositBps : Nat) : Out {
    let ?plan = St.plan(c.s, planId) else return #err(#noSuchPlan({ id = planId }));
    if (plan.guarantee == #prepaidInFull) return #err(#invalid({ what = "A rate paid in advance takes the whole stay, not a deposit." }));
    if (depositBps == 0 and plan.guarantee != #deposit) return #err(#invalid({ what = "The plan takes no deposit." }));
    if (depositBps != 0 and (depositBps < MIN_DEPOSIT_BPS or depositBps > MAX_DEPOSIT_BPS or depositBps % 100 != 0))
      return #err(#invalid({ what = "A deposit is a whole percentage, from 1% to 99%." }));
    RowStore.put<R.RatePlan>(c.s.plans, R.ratePlan, planId, { plan with guarantee = if (depositBps == 0) #firstNightAuthorised else #deposit; lastBlock = c.block });
    RowStore.put<R.PlanDeposit>(St.later(c.x, St.PLAN_DEPOSIT_TABLE), R.planDeposit, planId, { depositBps; lastBlock = c.block });
    #ok([planId, depositBps])
  };

  public func setPlanInclusions(c : St.Ctx, planId : Nat, incs : [Inclusion]) : Out {
    if (St.plan(c.s, planId) == null) return #err(#noSuchPlan({ id = planId }));
    if (incs.size() > R.MAX_INCLUSIONS) return #err(#invalid({ what = "A package has at most " # Nat.toText(R.MAX_INCLUSIONS) # " inclusions." }));
    var i = 0;
    while (i < incs.size()) {
      let inc = incs[i];
      let ?e = St.extra(c.x, inc.extraId) else return #err(#noSuchExtra({ id = inc.extraId }));
      if (not e.active) return #err(#inactive({ what = "extra"; id = inc.extraId }));
      if (e.price == 0) return #err(#invalid({ what = "An extra in a package needs a set price." }));
      if (inc.quantity == 0 or inc.quantity > MAX_INCLUSION_QUANTITY) return #err(#invalid({ what = "An inclusion gives 1 to " # Nat.toText(MAX_INCLUSION_QUANTITY) # " of its extra." }));
      var j = 0;
      while (j < i) { if (incs[j].extraId == inc.extraId) return #err(#invalid({ what = "An extra is in a package once." })); j += 1 };
      i += 1;
    };
    let had = St.inclusionSlots(c.x, planId);
    // ── every check is above this line; nothing below can refuse ──
    let table = St.later(c.x, St.PLAN_INCLUSION_TABLE);
    i := 0;
    while (i < incs.size()) {
      let inc = incs[i];
      RowStore.put<R.PlanInclusion>(table, R.planInclusion, R.inclusionId(planId, i + 1),
        { planId; extraId = inc.extraId; quantity = inc.quantity; rhythm = inc.rhythm; per = inc.per; on = true; lastBlock = c.block });
      i += 1;
    };
    for ((slot, r) in had.vals()) {
      if (slot > incs.size() and r.on) RowStore.put<R.PlanInclusion>(table, R.planInclusion, R.inclusionId(planId, slot), { r with on = false; lastBlock = c.block });
    };
    #ok([planId, incs.size()])
  };
}
