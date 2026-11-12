/// Windows.mo - the windows of a booking's bill: who pays which lines.
///
/// A booking's bill is split into windows. The guest's is window 0 and is every line and payment not
/// routed elsewhere; a payer added to the booking (a company, a relative) has a window of its own,
/// made of the lines and payments routed to it (Store.lineWindow, Store.paymentWindow). Every figure
/// of a window is a sum over its own stored lines and payments: nothing is kept twice.
///
/// THE GUEST'S WINDOW IS THE BOOKING LESS THE OTHERS. `settle` (Reservations) works on the booking's
/// own counters, and the guest's window is read as those counters less the sum of the other windows,
/// so a booking with no other payer is exactly what it was before windows existed: the same figures,
/// the same captures on the guest's card, the same refunds.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Array "mo:core/Array";
import List "mo:core/List";

import E "Enums";
import R "Rows";
import St "Store";

module {

  /// One window's figures: what it is charged and credited (taxes are part of `charges`, and also
  /// summed alone for the invoice), what has been paid into it and what captures are on their way,
  /// and the last card authorisation captured in it (a refund goes back through it).
  public type Window = { payerId : Nat; charges : Nat; credits : Nat; taxes : Nat; paid : Nat; due : Nat; auth : Nat; lines : Nat };

  type Acc = { payerId : Nat; var charges : Nat; var credits : Nat; var taxes : Nat; var captured : Nat; var refunded : Nat; var due : Nat; var auth : Nat; var lines : Nat };

  func sub(a : Nat, b : Nat) : Nat { if (a > b) a - b else 0 };

  public func liability(w : Window) : Nat { sub(w.charges, w.credits) };

  /// What is still to pay into a window: its liability less what is paid and on its way.
  public func open(w : Window) : Nat { sub(liability(w), w.paid + w.due) };

  func isTax(k : E.FolioKind) : Bool { switch k { case (#tax or #extraTax) true; case _ false } };

  /// Every window of a booking, the guest's first, each summed from its own lines and payments.
  public func all(s : St.Stores, x : St.Later, bookingId : Nat) : [Window] {
    let ids = Array.concat<Nat>([0], Array.map<(Nat, R.Payer), Nat>(St.payersOf(x, bookingId), func((id, _)) { id }));
    let accs = Array.map<Nat, Acc>(ids, func(id) {
      { payerId = id; var charges = 0; var credits = 0; var taxes = 0; var captured = 0; var refunded = 0; var due = 0; var auth = 0; var lines = 0 }
    });
    func accOf(w : Nat) : ?Acc { Array.find<Acc>(accs, func(a) { a.payerId == w }) };
    let routed = ids.size() > 1;
    for ((id, l) in St.folioOf(s, bookingId).vals()) {
      let w = if (routed) St.lineWindow(x, id) else 0;
      switch (accOf(w)) {
        case (?a) {
          a.lines += 1;
          if (E.isCredit(l.kind)) a.credits += l.amount else a.charges += l.amount;
          if (isTax(l.kind)) a.taxes += l.amount;
        };
        case null {};
      };
    };
    for ((id, p) in St.paymentsOf(s, bookingId).vals()) {
      let w = if (routed) St.paymentWindow(x, id) else 0;
      switch (accOf(w)) {
        case (?a) {
          switch (p.kind, p.state) {
            case (#captured or #chargedOnFile, #done) { a.captured += p.amount; a.auth := p.gatewayAuth };
            case (#captured or #chargedOnFile, #due) a.due += p.amount;
            case (#refunded, _) a.refunded += p.amount;   // a refund is committed when it is written
            case _ {};
          };
        };
        case null {};
      };
    };
    Array.map<Acc, Window>(accs, func(a) {
      { payerId = a.payerId; charges = a.charges; credits = a.credits; taxes = a.taxes; paid = sub(a.captured, a.refunded); due = a.due; auth = a.auth; lines = a.lines }
    })
  };

  public func of(s : St.Stores, x : St.Later, bookingId : Nat, payerId : Nat) : ?Window {
    Array.find<Window>(all(s, x, bookingId), func(w) { w.payerId == payerId })
  };

  /// The windows other than the guest's, and the sum of their figures.
  public type Others = { windows : [Window]; charges : Nat; credits : Nat; paid : Nat; due : Nat };

  public func others(s : St.Stores, x : St.Later, bookingId : Nat) : Others {
    if (St.payersOf(x, bookingId).size() == 0) return { windows = []; charges = 0; credits = 0; paid = 0; due = 0 };
    let ws = List.empty<Window>();
    var charges = 0; var credits = 0; var paid = 0; var due = 0;
    for (w in all(s, x, bookingId).vals()) {
      if (w.payerId != 0) { List.add(ws, w); charges += w.charges; credits += w.credits; paid += w.paid; due += w.due };
    };
    { windows = List.toArray(ws); charges; credits; paid; due }
  };

  /// Whether a window is closed by its invoice.
  public func invoiced(x : St.Later, bookingId : Nat, payerId : Nat) : Bool { St.invoiceOf(x, bookingId, payerId) != null };
}
