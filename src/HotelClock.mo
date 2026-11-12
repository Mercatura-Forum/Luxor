/// HotelClock.mo - the hotel's own clock: the time zone its day is kept in, and the night audit that
/// runs by itself at a local time.
///
/// The business date still moves only when a night audit closes a day (ClockWiring, Audit). What this
/// adds is WHO may run that audit without a person at the desk: when the owner turns the automatic audit
/// on, the contract's own principal is granted the auditor role, a row in the roster like any other
/// grant, and that role holds exactly the three audit acts (Staff.rolesFor). The contract's timer then
/// issues openAudit, advanceAudit and closeDay as itself, through the same accept path a person's
/// command takes, and each is checked against that row. Turning it off ends the grant.
///
/// The fold never reads a clock: the zone is stored as text and checked to parse, and the decision that
/// a day is due is taken by the contract from the substrate clock (`dueThrough`, pure, tested here).
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Array "mo:core/Array";
import Int "mo:core/Int";
import Principal "mo:core/Principal";
import Text "mo:core/Text";

import BatchCore "mo:kernel/batch/BatchCore";
import RowStore "mo:kernel/rows/RowStore";
import Zone "mo:kernel/time/Zone";

import Audit "Audit";
import Cmd "Command";
import R "Rows";
import Rf "Refusal";
import Staff "Staff";
import St "Store";
import TA "TextArena";

module {

  public type Out = { #ok : [Nat]; #err : Rf.Refusal };

  public let MAX_ZONE_NAME : Nat = 64;
  public let SECONDS_PER_DAY : Nat = 86_400;

  public func set(c : St.Ctx, zoneName : Text, zoneRule : Text, auditAt : Nat, auto : Bool, runner : Principal, staff : Principal) : Out {
    let n = Text.encodeUtf8(zoneName).size();
    if (n == 0) return #err(#invalid({ what = "Name the time zone, such as Africa/Cairo." }));
    if (n > MAX_ZONE_NAME) return #err(#tooLong({ what = "time-zone name"; max = MAX_ZONE_NAME }));
    switch (Zone.parse(zoneRule)) { case (#err e) return #err(#invalid({ what = e })); case (#ok _) {} };
    if (auditAt >= SECONDS_PER_DAY) return #err(#invalid({ what = "The audit time is a time of day, before 24:00." }));
    if (auditAt % 60 != 0) return #err(#invalid({ what = "The audit time is set to the minute." }));
    if (auto and Principal.isAnonymous(runner)) return #err(#invalid({ what = "The automatic audit needs the contract's own identity." }));
    if (auto and runner == staff) return #err(#invalid({ what = "The automatic audit runs as the contract, not as a person." }));
    let prev = St.hotelClock(c.x);
    // a text already stored is pointed at again, not written twice
    let sameName = switch prev { case (?p) TA.get(c.s.arena, p.zoneName) == zoneName; case null false };
    let sameRule = switch prev { case (?p) TA.get(c.s.arena, p.zoneRule) == zoneRule; case null false };
    let fresh = Array.concat<Text>(if (sameName) [] else [zoneName], if (sameRule) [] else [zoneRule]);
    switch (TA.fits(c.s.arena, fresh, Zone.MAX_TEXT)) { case (?why) return #err(#invalid({ what = why })); case null {} };

    // ── every check is above this line; nothing below can refuse ──
    let nameRef = switch prev { case (?p) { if (sameName) p.zoneName else TA.put(c.s.arena, zoneName) }; case null TA.put(c.s.arena, zoneName) };
    let ruleRef = switch prev { case (?p) { if (sameRule) p.zoneRule else TA.put(c.s.arena, zoneRule) }; case null TA.put(c.s.arena, zoneRule) };
    // the audit authority follows the setting: a runner that no longer runs it loses the grant
    switch prev {
      case (?{ runner = ?r0; auto = true }) { if (not auto or r0 != runner) Staff.endAuditFor(c, r0) };
      case _ {};
    };
    let granted = if (auto) Staff.holdAuditFor(c, runner) else 0;
    RowStore.put<R.HotelClock>(St.later(c.x, St.CLOCK_TABLE), R.hotelClock, St.CLOCK_ID,
      { zoneName = nameRef; zoneRule = ruleRef; auditAt; auto; runner = if (auto) ?runner else null; lastBlock = c.block });
    #ok([auditAt, if (auto) 1 else 0, granted])
  };

  /// The last business day whose night audit is due at UTC second `utc`: the audit of day D is due
  /// from `auditAt` on the local day after D. `null` when no day is due yet (before 1970 plus one day).
  public func dueThrough(rule : Zone.Rule, auditAt : Nat, utc : Int) : ?Nat {
    let (localDay, second) = Zone.localDayAndSecond(rule, utc);
    let last : Int = if (second >= auditAt) localDay - 1 else localDay - 2;
    if (last < 0) null else ?Int.abs(last)
  };

  /// What a run of due audits did: how many acts, the last act, the day it was for, and whether it held.
  public type Run = { steps : Nat; act : Text; day : Nat; ok : Bool; reason : Text };

  /// Every business day through `due`, oldest first, one act at a time: open the day's audit, advance it
  /// until its jobs are done and the books walked, close it. `accept` is the contract's accept path; a
  /// day only ends by a closeDay it accepts, which moves `today`. Stops at the first refusal (a day whose
  /// books show a problem stays open for a person) and after `maxSteps` acts; the audit's own run and
  /// walk are in the state, so the next call carries on where this one stopped.
  public func runDue(s : St.Stores, today : () -> Nat, runner : Principal, due : Nat, maxSteps : Nat,
    accept : Cmd.Command -> { ok : Bool; reason : Text }) : Run {
    var out : Run = { steps = 0; act = ""; day = today(); ok = true; reason = "" };
    label run while (out.steps < maxSteps) {
      let d = today();
      if (d > due) break run;
      let cmd : Cmd.Command = switch (BatchCore.get(s.audit, Audit.SCOPE, d)) {
        case null #openAudit({ staff = runner; day = d });
        case (?r) { if (r.state == #completed and s.walk.day == d and s.walk.done) #closeDay({ staff = runner; day = d }) else #advanceAudit({ staff = runner; day = d; limit = 0 }) };
      };
      let o = accept(cmd);
      out := { steps = out.steps + 1; act = Cmd.familyOf(cmd); day = d; ok = o.ok; reason = o.reason };
      if (not o.ok) break run;
    };
    out
  };
}
