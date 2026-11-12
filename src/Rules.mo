/// Rules.mo - the rules the log was written under, numbered, so a new build rebuilds an old log.
///
/// THE STATE IS A FUNCTION OF THE LOG ALONE, and a build that changes a rule would break that for every
/// block written before it: the night audit's walk of the oracle grew from 5 sections to 31, so an old
/// log's audit, folded by the new code, is still walking when its close arrives, and the close is
/// refused. The log therefore says which rules
/// each block was folded under. `#adoptRules({ epoch })`, an owner's act, moves the hotel from one
/// epoch to the next; every rule that changed is read here as a function of the epoch:
///
///   epoch 0  (no row)  the rules of the first released build: the audit walks sections 0 to 4, opens
///                      with the three jobs it had (holds, no-shows, identity documents) and writes no
///                      figures; the laws of those five sections are the ones that build checked.
///   epoch 1            the audit walks every section, writes the day's figures and releases the group
///                      blocks at their cut-off; the laws added inside the first five sections apply
///                      (I1 counting rooms out of order by their dates and the rooms blocks hold; I11 a
///                      split bill's windows, I12 a booking's origin, I14 its rate's access and I16 a
///                      charge on file, on the bookings page).
///
/// The audit's walk keeps the span it opened with (`walkSections`), so an adoption landing between two
/// steps of a walk cannot move the end of a walk already under way. The epoch is a row in a later table,
/// so it is in the fingerprint; it is written by the first adoption, and a log with none folds to the
/// fingerprint it always had. A contract installed by this build adopts every epoch it knows in the
/// blocks after its first owner's, so a new hotel's log says it runs the newest rules.
///
/// References: Cosmos SDK x/upgrade and ADR-041 (the version map in state, old rules below the upgrade
/// height); Ethereum fork activation by block (EIP-2124); CometBFT app_version; G. Young, Versioning in
/// an Event Sourced System (2016).
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Nat "mo:core/Nat";

import RowStore "mo:kernel/rows/RowStore";

import R "Rows";
import Rf "Refusal";
import St "Store";

module {

  public type Out = { #ok : [Nat]; #err : Rf.Refusal };

  /// THE AUDIT WALK'S SPAN BY EPOCH, append only: an epoch's span is the oracle's section count when
  /// it was declared, and the battery holds the list to growing and its last to `Oracle.SECTIONS`.
  public let SECTIONS_AT : [Nat] = [5, 31];

  /// The newest epoch this build knows: the last of `SECTIONS_AT` (the battery holds the two together).
  public let CURRENT : Nat = 1;

  /// The epoch from which the audit writes the day's figures and releases group blocks, and from which
  /// the laws added inside the first five oracle sections apply.
  public let FIGURES_FROM : Nat = 1;
  public let LAWS_FROM : Nat = 1;

  public func epoch(x : St.Later) : Nat { switch (St.rulesRow(x)) { case (?r) r.epoch; case null 0 } };

  /// Whether the log has adopted epoch `e` or a later one.
  public func from(x : St.Later, e : Nat) : Bool { epoch(x) >= e };

  /// The span of the audit's walk as it opened: the sections it walks before the day may close.
  public func walkSections(x : St.Later) : Nat { switch (St.rulesRow(x)) { case (?r) r.walkSections; case null SECTIONS_AT[0] } };

  /// The owner moves the hotel to the next epoch. Refused unless it is exactly the next one and this
  /// build knows it; the walk under way keeps its span.
  public func adopt(c : St.Ctx, e : Nat) : Out {
    let now = epoch(c.x);
    if (e != now + 1) return #err(#invalid({ what = "The hotel's rules are at epoch " # Nat.toText(now) # "; the next is " # Nat.toText(now + 1) # "." }));
    if (e > CURRENT) return #err(#invalid({ what = "This build knows the rules up to epoch " # Nat.toText(CURRENT) # "." }));
    RowStore.put<R.Rules>(St.later(c.x, St.RULES_TABLE), R.rules, St.RULES_ID, { epoch = e; walkSections = walkSections(c.x); lastBlock = c.block });
    #ok([e])
  };

  /// A walk opens: it walks the span of the epoch it opens under. Before any adoption there is no row,
  /// and the span is epoch 0's, so nothing is written.
  public func walkOpened(c : St.Ctx) {
    switch (St.rulesRow(c.x)) {
      case (?r) RowStore.put<R.Rules>(St.later(c.x, St.RULES_TABLE), R.rules, St.RULES_ID, { r with walkSections = SECTIONS_AT[r.epoch]; lastBlock = c.block });
      case null {};
    };
  };
}
