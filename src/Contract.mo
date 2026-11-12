/// Contract.mo - the accept path: the one route by which a command reaches the log.
///
/// In this order, and the order is the point: the Clock is read once (the business date and the
/// height, from one reading); the command is bound to its encoding version; the fold applies it,
/// refusing before any write if it refuses at all; and only then is the block appended. A refused
/// command appends nothing, because it did not happen. There is no await anywhere in here: from the
/// clock reading to the append is one synchronous step, which is what makes a capacity check and
/// the writes it permits indivisible.
///
/// A `closeDay` that succeeds rolls the business date by one in the same step, so the next command
/// reads the next day.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Array "mo:core/Array";
import Nat "mo:core/Nat";

import DL "mo:kernel/domain/DomainLog";

import Clk "ClockWiring";
import Cmd "Command";
import Log "Log";
import Rf "Refusal";
import State "State";
import St "Store";

module {

  public type Refused = {
    #clock : Clk.Error;
    #unrepresentable : { family : Text };
    #refused : Rf.Refusal;
  };

  public func kindOf(r : Refused) : Text {
    switch r { case (#clock _) "clock"; case (#unrepresentable _) "unrepresentable"; case (#refused f) Rf.kind(f) }
  };

  public func textOf(r : Refused) : Text {
    switch r {
      case (#clock e) "The hotel's date is not set: " # Clk.errorText(e);
      case (#unrepresentable { family }) "This version cannot record " # family # ".";
      case (#refused f) Rf.text(f);
    }
  };

  public type Accepted = { block : Nat; day : Nat; height : Nat; effects : [Nat] };

  /// The clock the contract keeps, which a successful `closeDay` moves.
  public type ClockCell = { var config : Clk.Config };

  public func accept(log : DL.State, s : St.Stores, x : St.Later, clock : ClockCell, source : Clk.Source, caller : Principal, command : Cmd.Command)
    : { #ok : Accepted; #err : Refused } {
    let reading = switch (Clk.read(clock.config, source)) { case (#err e) return #err(#clock e); case (#ok r) r };
    let ?event = Log.bind(reading.day, reading.height, command) else return #err(#unrepresentable { family = Cmd.familyOf(command) });
    let index = DL.length(log);
    let ctx : St.Ctx = { s; x; block = index; day = reading.day; height = reading.height };
    let effects = switch (State.apply(ctx, command)) { case (#err f) return #err(#refused f); case (#ok e) e };
    switch command {
      case (#closeDay { day }) {
        switch (Clk.roll(clock.config, day + 1)) {
          case (#ok cfg) clock.config := cfg;
          // the fold already refuses a close of any day but today, so a roll of one day cannot fail;
          // were it ever to, the date must not silently stay put while the log says it moved
          case (#err e) { assert false; ignore e };
        };
      };
      case _ {};
    };
    ignore DL.append<Log.Event>(log, Log.codec, Clk.stamp(reading), caller, event, null);
    #ok({ block = index; day = reading.day; height = reading.height; effects })
  };

  // ── replay ──────────────────────────────────────────────────────────────────

  /// A replay from genesis: the same fold, driven from the log. A block the fold refuses on replay is
  /// recorded with its reason, because it names where a live state and its log disagree.
  public type Replay = { stores : St.Stores; later : St.Later; var refusals : [(Nat, Text)] };

  public func newReplay() : Replay { { stores = St.newStores(); later = St.newLater(); var refusals = [] } };

  public func replayBlock(r : Replay, b : DL.Block<Log.Event>) {
    let ctx : St.Ctx = { s = r.stores; x = r.later; block = b.index; day = b.event.day; height = b.event.height };
    switch (State.apply(ctx, b.event.command)) {
      case (#ok _) {};
      case (#err f) {
        let n = r.refusals.size();
        let old = r.refusals;
        r.refusals := Array.tabulate<(Nat, Text)>(n + 1, func(i) { if (i < n) old[i] else (b.index, Rf.text(f)) });
      };
    };
  };

  public func replayAll(log : DL.State) : Replay {
    let r = newReplay();
    var i = 0;
    let n = DL.length(log);
    while (i < n) {
      switch (DL.get<Log.Event>(log, Log.codec, i)) {
        case (?b) replayBlock(r, b);
        case null { r.refusals := Array.concat(r.refusals, [(i, "block " # Nat.toText(i) # " does not decode")]) };
      };
      i += 1;
    };
    r
  };
}
