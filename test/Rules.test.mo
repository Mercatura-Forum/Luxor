/// Rules.test.mo - the rules the log was written under (`src/Rules.mo`), on two hotels of their own.
///
/// Hotel A runs the rules the first released build ran (epoch 0): it books a guest and closes a day
/// whose audit walked five sections and wrote no figures. It opens the next audit under epoch 0 and the
/// owner adopts epoch 1 between two steps of the walk: that walk still closes after five sections. The
/// audit after it walks every section and writes the day's figures. A's log, folded from genesis, gives
/// A's fingerprint; with no refusal.
///
/// Hotel B is sent the same acts as A but for the adoption: it stays at epoch 0, its third audit is not
/// A's, and the fold of A's log without the marker block is not A's state. Its bookings page reads a
/// booking from nowhere as nothing wrong, since I12 holds from epoch 1, and as I12 once B adopts.
///
/// The adoption's refusals (an epoch skipped, an epoch repeated, an epoch this build does not know, a
/// member of the desk, a guest) each leave five dimensions untouched: the fingerprint, the log's length,
/// the arena's bytes, the rules row and the grants.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Debug "mo:core/Debug";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";

import DL "mo:kernel/domain/DomainLog";
import RowStore "mo:kernel/rows/RowStore";

import Clk "../src/ClockWiring";
import Cmd "../src/Command";
import Con "../src/Contract";
import Log "../src/Log";
import O "../src/Oracle";
import R "../src/Rows";
import Res "../src/Reservations";
import Rules "../src/Rules";
import St "../src/Store";
import TA "../src/TextArena";
import W "../src/Widths";

var failures = 0;
var checks = 0;
func check(cond : Bool, what : Text) { checks += 1; if (not cond) { failures += 1; Debug.print("FAIL: " # what) } };

func who(n : Nat) : Principal { Principal.fromBlob(Blob.fromArray(Array.tabulate<Nat8>(29, func(i) { if (i == 28) Nat8.fromNat(n) else 7 }))) };
let OWNER = who(1);
let DESK = who(2);
let GUEST = who(10);
let DAY : Nat = 20_723;
func key(n : Nat8) : Blob { Blob.fromArray(Array.tabulate<Nat8>(33, func(i) { if (i == 0) 2 else n })) };

/// A hotel of its own: its log, stores and clock, and the acts sent to it.
class Hotel() {
  var height : Nat = 5_000;
  let source : Clk.Source = {
    substrateNow = func() : Nat64 { Nat64.fromNat(height * 1_000_000_000) };
    substrateHeight = func() : Nat { height };
    blockTimestamp = func() : ?Nat64 { null };
  };
  public let clock : Con.ClockCell = { var config = Clk.genesisConfig() };
  switch (Clk.roll(clock.config, DAY)) { case (#ok c) clock.config := c; case (#err e) Runtime.trap(Clk.errorText(e)) };
  public let log = Log.newState();
  public let s = St.newStores();
  public let later = St.newLater();
  public func send(caller : Principal, c : Cmd.Command) : { #ok : Con.Accepted; #err : Con.Refused } {
    height += 1;
    Con.accept(log, s, later, clock, source, caller, c)
  };
  /// A height that passes with no act: the other hotel's adoption, so both see the same heights.
  public func pass() { height += 1 };
  public func today() : Nat { switch (Clk.today(clock.config, source)) { case (#ok d) d; case (#err _) 0 } };
  public func ctx() : St.Ctx { { s; x = later; block = DL.length(log); day = today(); height } };
  public func fingerprint() : Blob { St.fingerprintHash(s, later) };
};

let a = Hotel();
let b = Hotel();

/// Every act goes to both hotels, but the adoption, which goes to A alone.
func both(caller : Principal, c : Cmd.Command, what : Text) : [Nat] {
  let fromA = switch (a.send(caller, c)) { case (#ok x) x.effects; case (#err r) { check(false, what # " (A): " # Con.textOf(r)); [] } };
  switch (b.send(caller, c)) { case (#ok _) {}; case (#err r) check(false, what # " (B): " # Con.textOf(r)) };
  fromA
};
func adoptOnA(e : Nat, what : Text) {
  switch (a.send(OWNER, #adoptRules({ staff = OWNER; epoch = e }))) { case (#ok x) check(x.effects == [e], what); case (#err r) check(false, what # ": " # Con.textOf(r)) };
  b.pass();
};

// ── the table of spans ───────────────────────────────────────────────────────

do {
  check(Rules.SECTIONS_AT.size() == Rules.CURRENT + 1, "an epoch for every span, the newest the build's own");
  check(Rules.SECTIONS_AT[0] == 5, "epoch 0 walks the five sections of the first released build");
  check(Rules.SECTIONS_AT[Rules.CURRENT] == O.SECTIONS, "the newest epoch walks every section");
  var grows = 0;
  for (i in Nat.range(1, Rules.SECTIONS_AT.size())) { if (Rules.SECTIONS_AT[i] > Rules.SECTIONS_AT[i - 1]) grows += 1 else check(false, "span " # Nat.toText(i) # " is not past the one before") };
  check(grows == Rules.SECTIONS_AT.size() - 1, "the spans only grow");
  // the rules row holds an epoch and a span in a byte each
  check(Rules.CURRENT < 256 and O.SECTIONS < 256 and W.RULES_ROW == 2 * W.SMALL + W.BLOCK, "an epoch and a span each fit their byte");
  let r : R.Rules = { epoch = 1; walkSections = 31; lastBlock = 123_456 };
  check(R.rules.decode(Blob.toArray(R.rules.encode(r))) == r, "the rules row round-trips");
  Debug.print("count: spans that grow = " # Nat.toText(grows));
};

// ── two hotels, one setup ────────────────────────────────────────────────────

ignore both(OWNER, #bootstrapOwner({ subject = OWNER }), "the first owner");
ignore both(OWNER, #configureProperty({ staff = OWNER; facts = { currency = "EUR"; minorUnits = 2; nameEn = "Karnak"; nameAr = "الكرنك"; checkInText = "15:00"; checkOutText = "11:00";
  holdTtlHeights = 900; heightsPerRealMinute = 60; maxStayNights = 21; horizonDays = 240; maxRoomsPerBooking = 4; idRetentionDays = 30 } }), "property");
ignore both(OWNER, #upsertRatePlan({ staff = OWNER; id = 0; facts = { code = "FLEX"; nameEn = "Flexible"; nameAr = "مرن"; kind = #bar; discountBps = 0; refundable = true;
  freeCancelDaysBefore = 3; penaltyNights = 1; guarantee = #firstNightAuthorised; modifiable = true; active = true } }), "flexible");
ignore both(OWNER, #upsertRoomType({ staff = OWNER; id = 0; facts = { code = "NILE"; nameEn = "Nile room"; nameAr = "غرفة النيل"; descEn = ""; descAr = ""; sizeSqm = 30; maxAdults = 2;
  maxChildren = 1; maxOccupancy = 3; bedKind = #king; bedCount = 1; amenities = 3; photos = ""; rank = 1; active = true } }), "room type");
for (i in Nat.range(0, 2)) ignore both(OWNER, #upsertRoom({ staff = OWNER; id = 0; roomTypeId = 1; number = "10" # Nat.toText(i + 1); outOfOrder = false }), "room");
ignore both(OWNER, #setNights({ staff = OWNER; edit = { roomTypeId = 1; fromDay = DAY; toDay = DAY + 30; weekdays = 127; allotment = ?2; bar = ?10_000; minStay = null; maxStay = null;
  closedToArrival = null; closedToDeparture = null; stopSell = null } }), "nights");
ignore both(OWNER, #grantRole({ staff = OWNER; subject = DESK; role = #frontDesk }), "a member of the desk");

check(Rules.epoch(a.later) == 0 and Rules.walkSections(a.later) == 5 and St.rulesRow(a.later) == null, "a hotel that adopted nothing is at epoch 0 and has no rules row");

// ── the adoption refused, five dimensions untouched ──────────────────────────

var untouched = 0;
func unchanged(caller : Principal, e : Nat, kind : Text, what : Text) {
  let fp = a.fingerprint();
  let len = DL.length(a.log);
  let arena = TA.bytesUsed(a.s.arena);
  let rules = St.rulesRow(a.later);
  let grants = RowStore.size(a.s.grants);
  switch (a.send(caller, #adoptRules({ staff = caller; epoch = e }))) {
    case (#ok _) check(false, what # ": accepted, expected " # kind);
    case (#err r) check(Con.kindOf(r) == kind, what # ": refused as " # Con.kindOf(r) # " (" # Con.textOf(r) # "), expected " # kind);
  };
  b.pass();
  let same = a.fingerprint() == fp and DL.length(a.log) == len and TA.bytesUsed(a.s.arena) == arena and St.rulesRow(a.later) == rules
    and RowStore.size(a.s.grants) == grants;
  check(same, what # ": the refusal moved state");
  if (same) untouched += 1;
};
unchanged(OWNER, 2, "invalid", "epoch 2 sent from epoch 0");
unchanged(OWNER, 0, "invalid", "epoch 0 sent at epoch 0");
unchanged(DESK, 1, "notAuthorised", "a member of the desk sending the marker");
unchanged(GUEST, 1, "notAuthorised", "a guest sending the marker");

// ── a guest, and the first audit under epoch 0 ───────────────────────────────

let st : Cmd.Stay = { roomTypeId = 1; planId = 1; arrival = DAY + 4; nights = 2; rooms = 1; adults = 2; children = 0 };
let ?q = (switch (Res.quoteStay(a.ctx(), st)) { case (#ok c) ?c.quote; case (#err _) null }) else Runtime.trap("no quote for the stay");
let holdId = both(GUEST, #placeHold({ owner = GUEST; stay = st; quoteHash = q.hash; key = key(3) }), "the guest's hold")[0];
var guarantee = 0;
for ((_, l) in St.holdLinesOf(a.s, holdId).vals()) { if (l.night == st.arrival) guarantee += l.amount };
let bookingId = both(GUEST, #confirmHold({ owner = GUEST; holdId; guestName = "Hesham Adel"; guestEmail = "lxe1.h"; note = ""; manageKey = key(4); account = null;
  auth = { authId = 1; amount = guarantee; currency = "EUR"; merchantRef = holdId } }), "the guest's booking")[0];

/// Advance A's (and B's) audit one step; whether A's step was taken.
func step(day : Nat) : Bool {
  let ra = a.send(OWNER, #advanceAudit({ staff = OWNER; day; limit = 8 }));
  ignore b.send(OWNER, #advanceAudit({ staff = OWNER; day; limit = 8 }));
  switch ra { case (#ok _) true; case (#err _) false }
};
func runToEnd(day : Nat) : Nat { var n = 0; label run while (n < 200) { if (not step(day)) break run; n += 1 }; n };

let d0 = a.today();
ignore both(OWNER, #openAudit({ staff = OWNER; day = d0 }), "the audit of the first day");
check(St.dayFigures(a.later, d0) == null and St.auditBlocks(a.later, d0) == null, "an audit under epoch 0 writes no figures and no blocks row");
ignore runToEnd(d0);
check(a.s.walk.done and a.s.walk.section == 5, "the walk under epoch 0 ends after five sections, at " # Nat.toText(a.s.walk.section));
ignore both(OWNER, #closeDay({ staff = OWNER; day = d0 }), "the first day closes");

// ── the adoption between two steps of a walk ─────────────────────────────────

let d1 = a.today();
ignore both(OWNER, #openAudit({ staff = OWNER; day = d1 }), "the audit of the second day");
var before = 0;
label into while (before < 50 and a.s.walk.section < 2) { if (not step(d1)) break into; before += 1 };
check(not a.s.walk.done and a.s.walk.section == 2, "the walk is under way, at section " # Nat.toText(a.s.walk.section));
adoptOnA(1, "the owner adopts epoch 1 in the middle of the walk");
check(Rules.epoch(a.later) == 1 and Rules.walkSections(a.later) == 5, "epoch 1, and the walk under way keeps the five sections it opened with");
ignore runToEnd(d1);
check(a.s.walk.done and a.s.walk.section == 5, "the walk opened under epoch 0 closes after five sections, at " # Nat.toText(a.s.walk.section));
ignore both(OWNER, #closeDay({ staff = OWNER; day = d1 }), "the second day closes");
unchanged(OWNER, 1, "invalid", "epoch 1 sent again");
unchanged(OWNER, 2, "invalid", "an epoch this build does not know");

// ── the first audit under epoch 1 ────────────────────────────────────────────

let d2 = a.today();
ignore a.send(OWNER, #openAudit({ staff = OWNER; day = d2 }));
let bOpen = b.send(OWNER, #openAudit({ staff = OWNER; day = d2 }));
check(Rules.walkSections(a.later) == O.SECTIONS and St.dayFigures(a.later, d2) != null, "the audit under epoch 1 walks every section and writes the day's figures");
check(St.dayFigures(b.later, d2) == null, "the hotel still at epoch 0 writes none");
var aSteps = 0;
label run while (aSteps < 200) { switch (a.send(OWNER, #advanceAudit({ staff = OWNER; day = d2; limit = 8 }))) { case (#ok _) aSteps += 1; case (#err _) break run } };
check(a.s.walk.done and a.s.walk.section == O.SECTIONS, "the walk under epoch 1 ends after every section, at " # Nat.toText(a.s.walk.section));
switch (a.send(OWNER, #closeDay({ staff = OWNER; day = d2 }))) { case (#ok _) {}; case (#err r) check(false, "the third day closes: " # Con.textOf(r)) };
let fig = St.dayFigures(a.later, d2);
check((switch fig { case (?f) f.roomsTotal == 2; case null false }), "the day's figures count the hotel's two rooms");

// ── the log is the state ─────────────────────────────────────────────────────

func fold(blocks : [DL.Block<Log.Event>]) : Con.Replay {
  let r = Con.newReplay();
  for (blk in blocks.vals()) Con.replayBlock(r, blk);
  r
};
let aLog = DL.getRange<Log.Event>(a.log, Log.codec, 0, DL.length(a.log));
let ra = fold(aLog);
check(ra.refusals.size() == 0, "A's log folds with no refusal: " # debug_show ra.refusals);
check(St.fingerprintHash(ra.stores, ra.later) == a.fingerprint(), "A's log folds to A's fingerprint, rules row and all");

// the marker dropped: the same acts but the adoption, as B was sent them, fold to another state
var marker = 0;
for (blk in aLog.vals()) { switch (blk.event.command) { case (#adoptRules _) marker := blk.index; case _ {} } };
let rd = fold(Array.filter<DL.Block<Log.Event>>(aLog, func(blk) { blk.index != marker }));
check(marker > 0, "A's log holds the marker, at block " # Nat.toText(marker));
check(St.fingerprintHash(rd.stores, rd.later) != a.fingerprint(), "without the marker, A's log does not fold to A's state");
// the third audit folds as the epoch-0 audit: its walk is done after five sections, and A's next step
// past them is refused, the first refusal of the fold and after the marker's place
check(rd.refusals.size() > 0 and rd.refusals[0].0 > marker and rd.refusals[0].1 == "The audit is complete; close the day.",
  "without the marker the fold refuses the third audit's steps past five sections: " # debug_show (if (rd.refusals.size() > 0) [rd.refusals[0]] else []));
// B is that log as a hotel kept it
switch bOpen { case (#ok _) {}; case (#err r) check(false, "B opens the third audit: " # Con.textOf(r)) };
var bSteps = 0;
label runB while (bSteps < 200) { switch (b.send(OWNER, #advanceAudit({ staff = OWNER; day = d2; limit = 8 }))) { case (#ok _) bSteps += 1; case (#err _) break runB } };
check(b.s.walk.done and b.s.walk.section == 5 and bSteps < aSteps,
  "with no marker the third audit is the epoch-0 audit: five sections in " # Nat.toText(bSteps) # " steps, against " # Nat.toText(aSteps));
check(b.fingerprint() != a.fingerprint(), "and B's state is not A's");

// ── the laws added inside the first five sections hold from epoch 1 ──────────

func bookingsPage(h : Hotel) : [O.Violation] { O.page(h.ctx(), 1, null, 50).violations };
let ?bk = St.booking(b.s, bookingId) else Runtime.trap("B has no booking");
RowStore.put<R.Booking>(b.s.bookings, R.booking, bookingId, { bk with holdId = 0 });
func names(vs : [O.Violation], rule : Text) : Nat { var n = 0; for (x in vs.vals()) { if (x.rule == rule) n += 1 }; n };
check(names(bookingsPage(b), "I12 origin") == 0, "under epoch 0 a booking from nowhere is not an I12 violation (the law came later)");
switch (b.send(OWNER, #adoptRules({ staff = OWNER; epoch = 1 }))) { case (#ok _) {}; case (#err r) check(false, "B adopts epoch 1: " # Con.textOf(r)) };
check(names(bookingsPage(b), "I12 origin") == 1, "under epoch 1 it is");
RowStore.put<R.Booking>(b.s.bookings, R.booking, bookingId, bk);

Debug.print("count: adoption refusals that left the state untouched = " # Nat.toText(untouched));
Debug.print("count: audit steps under epoch 1 = " # Nat.toText(aSteps));
Debug.print("count: blocks folded = " # Nat.toText(aLog.size()));
Debug.print("count: checks = " # Nat.toText(checks));
if (failures > 0) { Debug.print(Nat.toText(failures) # " failures"); Runtime.trap("rules battery failed") };
