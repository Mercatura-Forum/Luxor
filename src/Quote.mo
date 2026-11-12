/// Quote.mo - the price of a stay, as one pure function the search view and the fold both call.
///
/// The arithmetic is exact integers throughout, with one declared rounding: **half-even**, applied
/// **once** per stored figure. A discounted nightly rate is `bar × (10000 − bps)` in ten-thousandths of
/// a minor unit, summed over the nights and rooms exactly, and quantised once into the room subtotal.
/// Per-night lines and the per-night share of each tax come from the kernel's largest-remainder
/// `allocate`, so the parts sum to their totals by construction and there is no residue to post.
/// The total **is** the sum of the stored lines; nothing is computed twice and compared with itself.
///
/// The quote hash is what a guest was shown. A hold carries it, and the fold recomputes the quote at
/// the block and refuses if the two differ: nobody is held at a price they did not see.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Nat "mo:core/Nat";

import C "mo:kernel/codec/Canonical";
import Rounding "mo:kernel/num/Rounding";

import E "Enums";
import R "Rows";

module {

  public let DOMAIN : Text = "LUXOR-QUOTE-v1";
  public let BPS_ONE : Nat = 10_000;

  public type TaxInput = { id : Nat; rule : R.TaxRule };

  public type TaxLine = { ruleId : Nat; amount : Nat; perNight : [Nat] };

  /// A package's inclusion as a quote prices it: the extra, its folio category byte, its catalogue
  /// price, how many of it a night (the inclusion's quantity times the rooms, adults or guests), when
  /// it is given, and whether the extra is taxed.
  public type IncInput = { slot : Nat; extraId : Nat; category : Nat; unit : Nat; quantity : Nat; rhythm : E.Rhythm; taxed : Bool };

  /// One inclusion on one night: `net` is quantity × unit, and `taxes` the hotel's percentage taxes on
  /// it in rank order, compound as for the room (each rounded half-even once), when the extra is taxed.
  public type IncLine = { slot : Nat; extraId : Nat; category : Nat; night : Nat; quantity : Nat; unit : Nat; net : Nat; rhythm : E.Rhythm; taxed : Bool;
    taxes : [(Nat, Nat)] };

  public type Quote = {
    roomTypeId : Nat;
    planId : Nat;
    arrival : Nat;
    nights : Nat;
    rooms : Nat;
    /// The room charge for each night, all rooms together; sums exactly to `roomSubtotal`.
    nightly : [Nat];
    roomSubtotal : Nat;
    taxes : [TaxLine];
    taxTotal : Nat;
    /// A package's lines (empty for a plain rate) and what they come to with their taxes: part of
    /// `total`, and never of the room's subtotal, its taxes, its guarantee or its penalty.
    inclusions : [IncLine];
    packageTotal : Nat;
    total : Nat;
    hash : Blob;
  };

  /// n / d rounded half to even. `d` is positive.
  public func divHalfEven(n : Nat, d : Nat) : Nat {
    let q = n / d;
    let r = n % d;
    if (r * 2 < d) q else if (r * 2 > d) q + 1 else if (q % 2 == 0) q else q + 1
  };

  /// The exact nightly rate of a plan, in ten-thousandths of a minor unit, for one room.
  public func exactRate(bar : Nat, plan : R.RatePlan) : Nat {
    switch (plan.kind) {
      case (#bar) bar * BPS_ONE;
      case (#discountOffBar) bar * (BPS_ONE - Nat.min(plan.discountBps, BPS_ONE));
    }
  };

  /// A plan's nightly rate for display: the exact rate quantised once, half-even.
  public func displayRate(bar : Nat, plan : R.RatePlan) : Nat { divHalfEven(exactRate(bar, plan), BPS_ONE) };

  func allocateOrZero(total : Nat, weights : [Nat]) : [Nat] {
    switch (Rounding.allocate(total, weights)) {
      case (#ok parts) parts;
      // every weight zero: the nights are free, and so is every share of them
      case (#err _) Array.tabulate<Nat>(weights.size(), func(_) { 0 });
    }
  };

  /// Price a stay. `bars` is the BAR of each night in order; `taxes` are the active rules sorted by
  /// rank then id. The caller has already checked that every night exists and is sellable.
  public func price(roomTypeId : Nat, planId : Nat, plan : R.RatePlan, arrival : Nat, bars : [Nat], rooms : Nat, taxes : [TaxInput]) : Quote {
    let n = bars.size();
    let weights = Array.tabulate<Nat>(n, func(i) { exactRate(bars[i], plan) * rooms });
    var exact = 0;
    for (w in weights.vals()) exact += w;
    let roomSubtotal = divHalfEven(exact, BPS_ONE);
    let nightly = allocateOrZero(roomSubtotal, weights);

    let lines = List.empty<TaxLine>();
    var taxTotal = 0;
    for (t in taxes.vals()) {
      let amount = switch (t.rule.kind) {
        case (#percent) {
          let base = switch (t.rule.base) { case (#room) roomSubtotal; case (#roomAndPriorTaxes) roomSubtotal + taxTotal };
          divHalfEven(base * t.rule.bps, BPS_ONE)
        };
        case (#perRoomNight) t.rule.amount * rooms * n;
        case (#perStay) t.rule.amount;
      };
      // each tax line split across the nights in proportion to the room charge of that night
      List.add(lines, { ruleId = t.id; amount; perNight = allocateOrZero(amount, nightly) });
      taxTotal += amount;
    };
    let taxLines = List.toArray(lines);
    let total = roomSubtotal + taxTotal;
    { roomTypeId; planId; arrival; nights = n; rooms; nightly; roomSubtotal; taxes = taxLines; taxTotal; inclusions = []; packageTotal = 0; total;
      hash = hashOf(roomTypeId, planId, arrival, rooms, nightly, taxLines, [], total) }
  };

  /// The hotel's percentage taxes on an amount, in rank order, compound as for the room: each
  /// (rule, amount) above zero. The desk's extras and a package's inclusions are taxed by this one rule.
  public func percentTaxesOn(taxes : [TaxInput], net : Nat) : [(Nat, Nat)] {
    let out = List.empty<(Nat, Nat)>();
    var prior = 0;
    for (t in taxes.vals()) {
      if (t.rule.kind == #percent) {
        let base = switch (t.rule.base) { case (#room) net; case (#roomAndPriorTaxes) net + prior };
        let amount = divHalfEven(base * t.rule.bps, BPS_ONE);
        if (amount > 0) { List.add(out, (t.id, amount)); prior += amount };
      };
    };
    List.toArray(out)
  };

  /// A quote with a package's inclusions added: one line per inclusion per night it is given (every
  /// night, or only when the first night priced is the stay's arrival), at the catalogue price the
  /// caller read now, taxed by the extra's own flag. The room's lines, taxes and subtotal are as they
  /// were; the total grows by the package, and the hash covers every inclusion line, so a price change
  /// between the quote a guest saw and the act is refused as a room rate change is.
  public func withPackage(q : Quote, incs : [IncInput], taxes : [TaxInput], stayArrival : Nat) : Quote {
    if (incs.size() == 0) return q;
    let lines = List.empty<IncLine>();
    var packageTotal = 0;
    var i = 0;
    while (i < q.nights) {
      let night = q.arrival + i;
      for (inc in incs.vals()) {
        if (inc.rhythm == #everyNight or night == stayArrival) {
          let net = inc.unit * inc.quantity;
          let tx = if (inc.taxed) percentTaxesOn(taxes, net) else [];
          var t = 0;
          for ((_, a) in tx.vals()) t += a;
          List.add(lines, { slot = inc.slot; extraId = inc.extraId; category = inc.category; night; quantity = inc.quantity; unit = inc.unit; net;
            rhythm = inc.rhythm; taxed = inc.taxed; taxes = tx });
          packageTotal += net + t;
        };
      };
      i += 1;
    };
    let inclusions = List.toArray(lines);
    let total = q.roomSubtotal + q.taxTotal + packageTotal;
    { q with inclusions; packageTotal; total; hash = hashOf(q.roomTypeId, q.planId, q.arrival, q.rooms, q.nightly, q.taxes, inclusions, total) }
  };

  /// A plain rate's hash is what it always was; a package's also covers each inclusion line.
  public func hashOf(roomTypeId : Nat, planId : Nat, arrival : Nat, rooms : Nat, nightly : [Nat], taxes : [TaxLine], inclusions : [IncLine], total : Nat) : Blob {
    let w = C.Writer();
    w.nat(roomTypeId); w.nat(planId); w.nat(arrival); w.nat(rooms);
    w.nats(nightly);
    w.len16(taxes.size());
    for (t in taxes.vals()) { w.nat(t.ruleId); w.nat(t.amount) };
    w.nat(total);
    if (inclusions.size() > 0) {
      w.len16(inclusions.size());
      for (l in inclusions.vals()) {
        w.nat(l.slot); w.nat(l.extraId); w.nat(l.night); w.nat(l.quantity); w.nat(l.unit);
        w.len16(l.taxes.size());
        for ((r, a) in l.taxes.vals()) { w.nat(r); w.nat(a) };
      };
    };
    C.hashWithDomain(DOMAIN, w.toArray())
  };

  /// What the first `k` nights cost, room and their share of every tax: the cancellation penalty and
  /// the first-night guarantee are both this figure.
  public func firstNights(q : Quote, k : Nat) : Nat {
    let upto = Nat.min(k, q.nights);
    var s = 0;
    var i = 0;
    while (i < upto) {
      s += q.nightly[i];
      for (t in q.taxes.vals()) s += t.perNight[i];
      i += 1;
    };
    s
  };

  /// The hex form a client carries back, so a reply stays a flat record of scalar fields.
  public func hashHex(q : Quote) : Text { C.hex(q.hash) };

  public func sameHash(a : Blob, b : Blob) : Bool { Blob.equal(a, b) };
}
