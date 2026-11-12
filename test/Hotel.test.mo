// Hotel.test.mo - the hotel's fold, driven through its one accept path, against the laws it claims.
//
//   widths      every row's declared width is the sum of its fields; every table round-trips
//   encoding    every command family reads back from its bytes; Luxor's tags start at 1024
//   quote       hand-computed stays, a half-even boundary, per-night lines that sum exactly
//   holds       every night or none: a stay short on its last night moves nothing, measured as the
//               whole fingerprint, the log length and the arena
//   race        two guests for the last room on overlapping, nested and adjacent nights
//   money       confirm, capture, free cancellation, late cancellation, a no-show: charged = paid +
//               credited + outstanding after every act, and the cash law
//   audit       the night audit marks the no-show, walks the books, and rolls the date
//   figures     the day's figures the audit writes, recomputed from the whole tables by another road
//   four eyes   the maker cannot approve; a second owner can; the act runs from its stored bytes
//   bill        extras, payers, invoices; a credit note against an unchanged invoice, its refund through
//               the bill's card, the refund the gateway refused paid at the desk, and the note as the
//               tax authority's credit note
//   authority   the catalogue is total over the staff commands; guest commands are named apart
//   oracle      empty on the real state; each injected fault is named by its own rule
//   replay      the log rebuilds the state byte for byte; a row changed beside the fold does not
//
// engine: wasi-only (a Region is stable memory).

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Debug "mo:core/Debug";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Iter "mo:core/Iter";
import Nat64 "mo:core/Nat64";
import Option "mo:core/Option";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";

import C "mo:kernel/codec/Canonical";
import DL "mo:kernel/domain/DomainLog";
import CivilDate "mo:kernel/num/CivilDate";
import Zone "mo:kernel/time/Zone";
import Permissions "mo:kernel/auth/Permissions";
import RowStore "mo:kernel/rows/RowStore";

import Clk "../src/ClockWiring";
import Cmd "../src/Command";
import E "../src/Enums";
import Con "../src/Contract";
import CN "../src/CreditNote";
import Eta "../src/Eta";
import Enc "../src/Encoding";
import H "../src/History";
import HotelClock "../src/HotelClock";
import Hk "../src/Housekeeping";
import Win "../src/Windows";
import Log "../src/Log";
import O "../src/Oracle";
import Mail "../src/Mail";
import Q "../src/Quote";
import R "../src/Rows";
import Ref "../src/Ref";
import Res "../src/Reservations";
import Rules "../src/Rules";
import Acc "../src/Access";
import Staff "../src/Staff";
import St "../src/Store";
import TA "../src/TextArena";
import W "../src/Widths";

var failures = 0;
var checks = 0;
func check(cond : Bool, what : Text) { checks += 1; if (not cond) { failures += 1; Debug.print("FAIL: " # what) } };

func who(n : Nat) : Principal {
  Principal.fromBlob(Blob.fromArray(Array.tabulate<Nat8>(29, func(i) { if (i == 0) 7 else if (i == 1) Nat8.fromNat(n / 256) else if (i == 2) Nat8.fromNat(n % 256) else 0 })))
};
let OWNER = who(1);
let OWNER2 = who(2);
let GUEST_A = who(10);
let GUEST_B = who(11);

var heightCell : Nat = 5_000;
let source : Clk.Source = {
  substrateNow = func() : Nat64 { Nat64.fromNat(heightCell * 1_000_000_000) };
  substrateHeight = func() : Nat { heightCell };
  blockTimestamp = func() : ?Nat64 { null };
};
let DAY : Nat = 20_723;   // a Sunday
let clock : Con.ClockCell = { var config = Clk.genesisConfig() };
switch (Clk.roll(clock.config, DAY)) { case (#ok c) clock.config := c; case (#err e) Runtime.trap(Clk.errorText(e)) };

let log = Log.newState();
let s = St.newStores();
let later = St.newLater();

func send(caller : Principal, c : Cmd.Command) : { #ok : Con.Accepted; #err : Con.Refused } {
  heightCell += 1;
  Con.accept(log, s, later, clock, source, caller, c)
};
func ok(caller : Principal, c : Cmd.Command, what : Text) : [Nat] {
  switch (send(caller, c)) { case (#ok a) a.effects; case (#err r) { check(false, what # ": " # Con.textOf(r)); [] } }
};
func refused(caller : Principal, c : Cmd.Command, kind : Text, what : Text) {
  switch (send(caller, c)) {
    case (#ok _) check(false, what # ": accepted, expected " # kind);
    case (#err r) check(Con.kindOf(r) == kind, what # ": refused as " # Con.kindOf(r) # " (" # Con.textOf(r) # "), expected " # kind);
  }
};
func today() : Nat { switch (Clk.today(clock.config, source)) { case (#ok d) d; case (#err _) 0 } };
func ctx() : St.Ctx { { s; x = later; block = DL.length(log); day = today(); height = heightCell } };
/// The fingerprint sections the night audit's figures add: its figures, and its revenue rows once a
/// guest was in house on an audited night. Each later table writes a section only once it has a row.
// The later tables a run of the battery fills along the way, each a section once it has a row: the
// audit's figures and revenue, the slices of every refund to a guest, and the rules the hotel adopted.
func auditSections() : Nat {
  var n = 0;
  for (t in [St.DAY_FIGURES_TABLE, St.DAY_REVENUE_TABLE, St.REFUND_SLICE_TABLE, St.AUDIT_BLOCKS_TABLE, St.RULES_TABLE].vals()) { if (RowStore.size(St.later(later, t)) > 0) n += 1 };
  n
};
func key(n : Nat8) : Blob { Blob.fromArray(Array.tabulate<Nat8>(33, func(i) { if (i == 0) 2 else n })) };

// ── widths and rows ──────────────────────────────────────────────────────────

check(W.checkSums().size() == 0, "row widths: " # debug_show W.checkSums());
Debug.print("count: row widths checked = " # Nat.toText(W.ROWS_CHECKED));

do {
  let n : R.Night = { allotment = 7; sold = 3; held = 2; bar = 123_456; minStay = 2; maxStay = 9; closedToArrival = true; closedToDeparture = false; stopSell = true; lastBlock = 77 };
  check(R.night.decode(Blob.toArray(R.night.encode(n))) == n, "night round-trips");
  let h : R.Hold = { roomTypeId = 3; planId = 2; arrival = DAY; nights = 4; rooms = 2; adults = 3; children = 1; owner = GUEST_A; expiresAt = 99_999;
    state = #live; quotedTotal = 5_000_000; quoteHash = Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { Nat8.fromNat(i) })); fromWaitlist = 5; key = key(9); lastBlock = 12 };
  check(R.hold.decode(Blob.toArray(R.hold.encode(h))) == h, "hold round-trips");
  let p : R.Proposal = { maker = OWNER; permission = 3; proposedBlock = 8; expiresAt = 1_000; status = #awaiting; checker = ?OWNER2; resolvedBlock = 9;
    commandHash = Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { Nat8.fromNat(255 - i) })); act = { offset = 12; length = 30 } };
  check(R.proposal.decode(Blob.toArray(R.proposal.encode(p))) == p, "proposal round-trips");
  let hc : R.HotelClock = { zoneName = { offset = 40; length = 12 }; zoneRule = { offset = 52; length = 29 }; auditAt = 86_340; auto = true; runner = ?OWNER2; lastBlock = 31 };
  check(R.hotelClock.decode(Blob.toArray(R.hotelClock.encode(hc))) == hc, "hotel clock round-trips");
  check(R.hotelClock.decode(Blob.toArray(R.hotelClock.encode({ hc with auto = false; runner = null }))) == { hc with auto = false; runner = null }, "hotel clock with no runner round-trips");
  let hk : R.Housekeeping = { cleaning = #inspected; cleanedBy = ?OWNER; inspectedBy = ?OWNER2; outReason = { offset = 70; length = 21 }; outFrom = DAY; outUntil = DAY + 3; changedDay = DAY + 1; lastBlock = 44 };
  check(R.housekeeping.decode(Blob.toArray(R.housekeeping.encode(hk))) == hk, "housekeeping round-trips");
  check(R.housekeeping.decode(Blob.toArray(R.housekeeping.encode({ hk with cleaning = #dirty; cleanedBy = null; inspectedBy = null }))) == { hk with cleaning = #dirty; cleanedBy = null; inspectedBy = null }, "housekeeping with nobody round-trips");
  let cn : R.CreditNote = { invoice = 70_001; bookingId = 123_456; payerId = 3; issuedDay = DAY + 2; net = 98_765_432; taxes = 1_234_567; total = 99_999_999;
    firstLine = 4_000_001; lines = 144; proposal = 9_876; lastBlock = 3_210 };
  check(R.creditNote.decode(Blob.toArray(R.creditNote.encode(cn))) == cn, "credit note round-trips");
  let cl : R.CreditLine = { note = 70_002; source = 4_000_000; lastBlock = 3_211 };
  check(R.creditLine.decode(Blob.toArray(R.creditLine.encode(cl))) == cl, "credit line round-trips");
  let dr : R.DeskRefund = { bookingId = 123_456; method = #transfer; reference = { offset = 90; length = 64 }; day = DAY + 3; proposal = 9_877; lastBlock = 3_212 };
  check(R.deskRefund.decode(Blob.toArray(R.deskRefund.encode(dr))) == dr, "desk refund round-trips");
  check(R.deskRefund.decode(Blob.toArray(R.deskRefund.encode({ dr with method = #cash }))) == { dr with method = #cash }, "desk refund in cash round-trips");
  let sb : R.StaffBooking = { channel = #walkIn; madeBy = OWNER2; day = DAY + 9; lastBlock = 3_214 };
  check(R.staffBooking.decode(Blob.toArray(R.staffBooking.encode(sb))) == sb, "staff booking round-trips");
  check(R.staffBooking.decode(Blob.toArray(R.staffBooking.encode({ sb with channel = #phone }))) == { sb with channel = #phone }, "staff booking by phone round-trips");
  let te : R.TaxEta = { taxType = "T1"; subType = "V009"; lastBlock = 3_213 };
  check(R.taxEta.decode(Blob.toArray(R.taxEta.encode(te))) == te, "tax codes round-trip");
  let ep : R.EtaProfile = { issuerId = { offset = 1; length = 9 }; activityCode = "5510"; branchId = { offset = 10; length = 1 }; country = "EG";
    governate = { offset = 11; length = 5 }; regionCity = { offset = 16; length = 9 }; street = { offset = 25; length = 15 }; buildingNumber = { offset = 40; length = 2 }; lastBlock = 3_214 };
  check(R.etaProfile.decode(Blob.toArray(R.etaProfile.encode(ep))) == ep, "the tax registration round-trips");
  let co : R.Company = { code = "NILE-TOURS-2026"; name = { offset = 77; length = 120 }; active = true; lastBlock = 3_215 };
  check(R.company.decode(Blob.toArray(R.company.encode(co))) == co, "company round-trips");
  check(R.company.decode(Blob.toArray(R.company.encode({ co with code = "A"; active = false }))) == { co with code = "A"; active = false }, "a one-letter company off sale round-trips");
  let pa : R.PlanAccess = { companyId = 499; closed = true; lastBlock = 3_216 };
  check(R.planAccess.decode(Blob.toArray(R.planAccess.encode(pa))) == pa, "plan access round-trips");
  let rg : R.RateGrant = { companyId = 12; promoId = 70_000; use = 999_999; lastBlock = 3_217 };
  check(R.holdRate.decode(Blob.toArray(R.holdRate.encode(rg))) == rg and R.bookingRate.decode(Blob.toArray(R.bookingRate.encode(rg))) == rg, "a kept access round-trips");
  let pr : R.Promo = { code = "SPRING-2026"; name = { offset = 300; length = 41 }; planId = 7; bookFrom = 20_500; bookUntil = 20_560; stayFrom = 20_510; stayUntil = 20_600;
    maxUses = 1_000_000; used = 999_999; active = true; lastBlock = 3_218 };
  check(R.promo.decode(Blob.toArray(R.promo.encode(pr))) == pr, "a promotion round-trips");
  check(R.promo.decode(Blob.toArray(R.promo.encode({ pr with maxUses = 0; used = 0; active = false }))) == { pr with maxUses = 0; used = 0; active = false }, "a promotion off sale with no limit round-trips");
};

// ── encoding ─────────────────────────────────────────────────────────────────

do {
  let w = C.Writer();
  Enc.putTag(w, Cmd.LUXOR_BASE);
  check(w.toArray() == [255, 255, 2, 2], "tag 1024 is 0xFF 0xFF then 514");
  let samples : [Cmd.Command] = [
    #placeHold({ owner = GUEST_A; stay = { roomTypeId = 1; planId = 2; arrival = DAY; nights = 3; rooms = 1; adults = 2; children = 0 }; quoteHash = "\01\02"; key = key(4) }),
    #setNights({ staff = OWNER; edit = { roomTypeId = 1; fromDay = DAY; toDay = DAY + 7; weekdays = 127; allotment = ?2; bar = null; minStay = ?1; maxStay = null; closedToArrival = ?true; closedToDeparture = null; stopSell = ?false } }),
    #propose({ staff = OWNER; act = #priceOverride({ bookingId = 4; newTotal = 1_000 }); justification = "long-staying guest" }),
    #checkIn({ staff = OWNER; bookingId = 3; roomIds = [1, 2] }),
    #setGuestDataKey({ staff = OWNER; key = "\04\01" }),
    #setNightsMany({ staff = OWNER; edits = [
      { edit = { roomTypeId = 1; fromDay = DAY; toDay = DAY + 2; weekdays = 127; allotment = null; bar = null; minStay = null; maxStay = null; closedToArrival = null; closedToDeparture = null; stopSell = ?true }; adjust = null },
      { edit = { roomTypeId = 2; fromDay = DAY; toDay = DAY + 2; weekdays = 31; allotment = ?1; bar = null; minStay = ?2; maxStay = null; closedToArrival = null; closedToDeparture = ?false; stopSell = null }; adjust = ?{ up = false; bps = 1_250 } },
    ] }),
    #setHotelClock({ staff = OWNER; zoneName = "Africa/Cairo"; zoneRule = "EET-2EEST,M4.5.5/0,M10.5.4/24"; auditAt = 10_800; auto = true; runner = OWNER2 }),
    #markRoom({ staff = OWNER; roomId = 4; cleaning = #inspected }),
    #takeRoomOutOfOrder({ staff = OWNER; roomId = 5; reason = "Leak under the basin"; untilDay = DAY + 3 }),
    #returnRoomToService({ staff = OWNER; roomId = 5 }),
    #upsertExtra({ staff = OWNER; id = 0; facts = { code = "WATER"; nameEn = "Water"; nameAr = "مياه"; category = #minibar; price = 300; taxed = true; active = true } }),
    #postCharge({ staff = OWNER; bookingId = 4; extraId = 1; quantity = 2; amount = 0; payerId = 3 }),
    #addPayer({ staff = OWNER; bookingId = 4; name = "Acme Travel" }),
    #routeLines({ staff = OWNER; bookingId = 4; lineIds = [7, 9]; payerId = 3 }),
    #settleShare({ staff = OWNER; bookingId = 4; payerId = 3; auth = { authId = 9; amount = 5_005; currency = "EUR"; merchantRef = 1_000_000_000_004 } }),
    #issueInvoice({ staff = OWNER; bookingId = 4; payerId = 0 }),
    #propose({ staff = OWNER; act = #voidCharge({ bookingId = 4; lineId = 7 }); justification = "posted to the wrong room" }),
    #propose({ staff = OWNER; act = #issueCreditNote({ bookingId = 4; invoice = 2; lineIds = [7, 300_000]; amounts = [150, 99_999_999] }); justification = "overcharged" }),
    #propose({ staff = OWNER; act = #refundAtDesk({ bookingId = 4; paymentId = 12; method = #transfer; reference = "TRF-0042" }); justification = "the card was closed" }),
    #setTaxEta({ staff = OWNER; taxRuleId = 1; taxType = "T1"; subType = "V009" }),
    #setEtaProfile({ staff = OWNER; facts = { issuerId = "100324932"; activityCode = "5510"; branchId = "0"; country = "EG"; governate = "Luxor";
      regionCity = "East Bank"; street = "Corniche El Nil"; buildingNumber = "12" } }),
    #bookByStaff({ staff = OWNER; channel = #phone; stay = { roomTypeId = 1; planId = 2; arrival = DAY + 4; nights = 2; rooms = 1; adults = 2; children = 1 };
      quoteHash = "\01\02"; guestName = "Hany Adel"; guestEmail = ""; note = "late arrival"; manageKey = key(61); roomIds = [] }),
    #bookByStaff({ staff = OWNER2; channel = #walkIn; stay = { roomTypeId = 2; planId = 1; arrival = DAY; nights = 1; rooms = 2; adults = 3; children = 0 };
      quoteHash = "\03"; guestName = "كريم"; guestEmail = "lxe1.x"; note = ""; manageKey = key(62); roomIds = [3, 7] }),
    #moveRoom({ staff = OWNER; bookingId = 4; fromRoomId = 1; toRoomId = 2 }),
    #upsertCompany({ staff = OWNER; id = 0; code = "ACME"; name = "Acme Trading"; active = true }),
    #setPlanAccess({ staff = OWNER; planId = 3; companyId = 1; closed = true }),
    #placeHoldCoded({ owner = GUEST_A; stay = { roomTypeId = 1; planId = 3; arrival = DAY + 2; nights = 2; rooms = 1; adults = 1; children = 0 }; quoteHash = "\07"; key = key(5); code = "acme" }),
    #bookByStaffCoded({ staff = OWNER2; channel = #phone; stay = { roomTypeId = 1; planId = 3; arrival = DAY + 4; nights = 1; rooms = 1; adults = 1; children = 0 };
      quoteHash = "\08"; guestName = "Rania"; guestEmail = ""; note = "Acme's travel desk"; manageKey = key(63); roomIds = []; code = "NILE-TOURS" }),
    #upsertPromo({ staff = OWNER; id = 0; code = "SPRING-2026"; name = "Spring on the Nile"; planId = 4; bookFrom = DAY; bookUntil = DAY + 30; stayFrom = DAY + 10;
      stayUntil = DAY + 90; maxUses = 250; active = true }),
    #upsertBlock({ staff = OWNER; id = 0; name = "زفاف حسن وليلى"; companyId = 2; roomTypeId = 3; planId = 1; arrival = DAY + 40; nights = 3; rooms = 12; cutoff = DAY + 10 }),
    #releaseBlock({ staff = OWNER2; id = 7 }),
    #pickUpFromBlock({ staff = OWNER2; blockId = 7; stay = { roomTypeId = 3; planId = 1; arrival = DAY + 40; nights = 2; rooms = 1; adults = 2; children = 0 };
      quoteHash = "\09"; guestName = "Leila"; guestEmail = "lxe1.l"; note = "bride's aunt"; manageKey = key(64) }),
    #setPlanInclusions({ staff = OWNER; planId = 5; inclusions = [{ extraId = 2; quantity = 1; rhythm = #everyNight; per = #guest },
      { extraId = 9; quantity = 3; rhythm = #arrivalNight; per = #room }, { extraId = 300; quantity = 9; rhythm = #everyNight; per = #adult }] }),
    #configureProperty({ staff = OWNER; facts = { currency = "EGP"; minorUnits = 2; nameEn = "Almar"; nameAr = "الـمار"; checkInText = "15:00"; checkOutText = "12:00";
      holdTtlHeights = 900; heightsPerRealMinute = 60; maxStayNights = 30; horizonDays = 365; maxRoomsPerBooking = 4; idRetentionDays = 30 } }),
    #upsertRoomType({ staff = OWNER; id = 0; facts = { code = "SEA"; nameEn = "Sea room"; nameAr = "غرفة البحر"; descEn = "On the water"; descAr = ""; sizeSqm = 42;
      maxAdults = 2; maxChildren = 1; maxOccupancy = 3; bedKind = #twin; bedCount = 2; amenities = 5; photos = "almar/sea-room"; rank = 2; active = true } }),
    #upsertRoom({ staff = OWNER2; id = 4; roomTypeId = 1; number = "204"; outOfOrder = true }),
    #upsertRatePlan({ staff = OWNER; id = 0; facts = { code = "NRF"; nameEn = "Non-refundable"; nameAr = "غير مسترد"; kind = #discountOffBar; discountBps = 1_200;
      refundable = false; freeCancelDaysBefore = 0; penaltyNights = 0; guarantee = #prepaidInFull; modifiable = false; active = true } }),
    #upsertTaxRule({ staff = OWNER; id = 2; facts = { code = "SVC"; nameEn = "Service"; nameAr = "خدمة"; kind = #percent; bps = 1_200; amount = 0; base = #roomAndPriorTaxes;
      rank = 3; active = false } }),
    #releaseExpiredHolds({ limit = 25 }),
    #releaseHold({ owner = GUEST_B; holdId = 3 }),
    #confirmHold({ owner = GUEST_A; holdId = 11; guestName = "Selim"; guestEmail = "lxe1.o"; note = "sea view"; manageKey = key(66); account = null;
      auth = { authId = 40; amount = 25_380; currency = "EUR"; merchantRef = 11 } }),
    #modifyBooking({ by = #account(GUEST_A); bookingId = 2; stay = { roomTypeId = 1; planId = 1; arrival = DAY + 1; nights = 2; rooms = 1; adults = 2; children = 1 };
      quoteHash = "\0a"; auth = ?{ authId = 44; amount = 1_000; currency = "EUR"; merchantRef = 1_000_000_000_002 } }),
    #modifyBooking({ by = #manageKey; bookingId = 2; stay = { roomTypeId = 1; planId = 1; arrival = DAY; nights = 1; rooms = 1; adults = 1; children = 0 }; quoteHash = "\0b"; auth = null }),
    #cancelBooking({ by = #manageKey; bookingId = 5 }),
    #claimBooking({ account = GUEST_B; bookingId = 5 }),
    #joinWaitlist({ account = GUEST_B; stay = { roomTypeId = 2; planId = 0; arrival = DAY + 9; nights = 4; rooms = 1; adults = 2; children = 0 } }),
    #leaveWaitlist({ account = GUEST_B; entryId = 1 }),
    #checkOut({ staff = OWNER2; bookingId = 4 }),
    #recordGatewayOutcome({ paymentId = 9; ok = false }),
    #openAudit({ staff = OWNER2; day = DAY }),
    #advanceAudit({ staff = OWNER2; day = DAY; limit = 50 }),
    #closeDay({ staff = OWNER2; day = DAY }),
    #bootstrapOwner({ subject = OWNER }),
    #grantRole({ staff = OWNER; subject = OWNER2; role = #frontDesk }),
    #revokeRole({ staff = OWNER; subject = OWNER2; role = #auditor }),
    #approve({ staff = OWNER2; proposalId = 3 }),
    #reject({ staff = OWNER2; proposalId = 4; reason = "the guest was told otherwise" }),
    #settleAtDesk({ staff = OWNER2; bookingId = 4; auth = { authId = 45; amount = 14_160; currency = "EUR"; merchantRef = 1_000_000_000_004 } }),
    #beginIdUpload({ staff = OWNER2; bookingId = 4; size = 70_000; chunkHashes = ["aa11", "bb22"] }),
    #putIdChunk({ staff = OWNER2; blobId = "blob-1"; index = 1; bytes = "\01\02\03" }),
    #fileIdDocument({ staff = OWNER2; bookingId = 4; blobId = "blob-1"; plainHash = "cc33"; plainSize = 69_000; mime = "image/jpeg"; fileKey = "lxk1.f" }),
    #setPlanDeposit({ staff = OWNER; planId = 6; depositBps = 3_000 }),
    #requireCardOnFile({ staff = OWNER }),
    #confirmHoldOnFile({ owner = GUEST_A; holdId = 12; guestName = "Mona Saleh"; guestEmail = "lxe1.m"; note = ""; manageKey = key(65); account = ?GUEST_B;
      auth = { authId = 41; amount = 11_220; currency = "EUR"; merchantRef = 12 }; token = 7 }),
    #putCardOnFile({ by = #manageKey; bookingId = 19; auth = { authId = 42; amount = 6_600; currency = "EUR"; merchantRef = 1_000_000_000_019 }; token = 8 }),
    #recordChargeOutcome({ paymentId = 77; ok = true; authId = 43 }),
    #recordCardForgotten({ bookingId = 19; ok = false }),
    #setMailRelay({ staff = OWNER; mailer = GUEST_B; mailKey = "\04\01\02" }),
    #authoriseMailCredential({ staff = OWNER; digest = "\aa\bb" }),
    #setMailOn({ staff = OWNER2; on = true }),
    #attachMail({ by = #account(GUEST_A); bookingId = 20; sealed = "lxe1.abc"; lang = #ar }),
    #attachMailByStaff({ staff = OWNER2; bookingId = 21; sealed = "lxe1.def"; lang = #en }),
    #recordMailOutcome({ mailer = GUEST_B; outboxId = 33; sent = false; failure = #unavailable }),
    #recordMailTest({ mailer = GUEST_B; digest = "\cc" }),
    #adoptRules({ staff = OWNER; epoch = 1 }),
  ];
  var n = 0;
  for (c in samples.vals()) {
    switch (Enc.bytesAt(1, c)) {
      case (?b) { check(Enc.read(1, b) == ?c, "command reads back: " # Cmd.familyOf(c)); n += 1 };
      case null check(false, "command has no bytes: " # Cmd.familyOf(c));
    };
  };
  check(Cmd.FAMILIES.size() == 70, "70 families");
  // every family has its sample: a family with no vector is a family whose bytes nobody froze
  for (f in Cmd.FAMILIES.vals()) check(Array.find<Cmd.Command>(samples, func(c) { Cmd.familyOf(c) == f }) != null, "a sample of " # f);
  Debug.print("count: command families round-tripped = " # Nat.toText(n));
};

// ── the hotel ────────────────────────────────────────────────────────────────

ignore ok(OWNER, #bootstrapOwner({ subject = OWNER }), "the first owner");
refused(OWNER2, #bootstrapOwner({ subject = OWNER2 }), "alreadyOwned", "a second bootstrap");
// the hotel keeps its books under the newest rules, as an install by this build does (test/Rules.test.mo
// holds the rules of each epoch, and a hotel that adopts them under way)
for (e in Nat.range(1, Rules.CURRENT + 1)) check(ok(OWNER, #adoptRules({ staff = OWNER; epoch = e }), "the rules of epoch " # Nat.toText(e)) == [e], "the rules of epoch " # Nat.toText(e) # " adopted");
check(Rules.epoch(later) == Rules.CURRENT and Rules.walkSections(later) == Rules.SECTIONS_AT[0], "the hotel is at the newest rules, and no walk has opened under them yet");
ignore ok(OWNER, #configureProperty({ staff = OWNER; facts = { currency = "EUR"; minorUnits = 2; nameEn = "Almar"; nameAr = "الـمار"; checkInText = "15:00"; checkOutText = "11:00";
  holdTtlHeights = 900; heightsPerRealMinute = 60; maxStayNights = 21; horizonDays = 240; maxRoomsPerBooking = 4; idRetentionDays = 30 } }), "property");
refused(GUEST_A, #configureProperty({ staff = GUEST_A; facts = { currency = "EUR"; minorUnits = 2; nameEn = "x"; nameAr = ""; checkInText = ""; checkOutText = "";
  holdTtlHeights = 1; heightsPerRealMinute = 1; maxStayNights = 1; horizonDays = 1; maxRoomsPerBooking = 1; idRetentionDays = 1 } }), "notAuthorised", "a guest configuring the hotel");
ignore ok(OWNER, #upsertTaxRule({ staff = OWNER; id = 0; facts = { code = "IVA"; nameEn = "VAT"; nameAr = "ضريبة"; kind = #percent; bps = 1_000; amount = 0; base = #room; rank = 1; active = true } }), "VAT");
ignore ok(OWNER, #upsertTaxRule({ staff = OWNER; id = 0; facts = { code = "TOURIST"; nameEn = "Tourist tax"; nameAr = "ضريبة السياحة"; kind = #perRoomNight; bps = 0; amount = 220; base = #room; rank = 2; active = true } }), "tourist tax");
ignore ok(OWNER, #upsertRatePlan({ staff = OWNER; id = 0; facts = { code = "FLEX"; nameEn = "Flexible"; nameAr = "مرن"; kind = #bar; discountBps = 0; refundable = true;
  freeCancelDaysBefore = 3; penaltyNights = 1; guarantee = #firstNightAuthorised; modifiable = true; active = true } }), "flexible");
ignore ok(OWNER, #upsertRatePlan({ staff = OWNER; id = 0; facts = { code = "SAVER"; nameEn = "Saver"; nameAr = "توفير"; kind = #discountOffBar; discountBps = 1_500; refundable = false;
  freeCancelDaysBefore = 0; penaltyNights = 0; guarantee = #prepaidInFull; modifiable = false; active = true } }), "saver");
func roomType(code : Text, rooms : Nat) {
  ignore ok(OWNER, #upsertRoomType({ staff = OWNER; id = 0; facts = { code; nameEn = code; nameAr = code; descEn = ""; descAr = ""; sizeSqm = 40; maxAdults = 2; maxChildren = 1;
    maxOccupancy = 3; bedKind = #king; bedCount = 1; amenities = 3; photos = "almar/sea-room"; rank = 1; active = true } }), "room type " # code);
};
roomType("SEA", 2);
roomType("VILLA", 1);
for (i in Nat.range(0, 2)) ignore ok(OWNER, #upsertRoom({ staff = OWNER; id = 0; roomTypeId = 1; number = "20" # Nat.toText(i + 1); outOfOrder = false }), "room");
ignore ok(OWNER, #upsertRoom({ staff = OWNER; id = 0; roomTypeId = 2; number = "301"; outOfOrder = false }), "villa room");
refused(OWNER, #setNights({ staff = OWNER; edit = { roomTypeId = 1; fromDay = DAY; toDay = DAY + 30; weekdays = 127; allotment = ?3; bar = ?18_000; minStay = null; maxStay = null;
  closedToArrival = null; closedToDeparture = null; stopSell = null } }), "allotmentAboveRooms", "an allotment above the rooms of the type");
ignore ok(OWNER, #setNights({ staff = OWNER; edit = { roomTypeId = 1; fromDay = DAY; toDay = DAY + 30; weekdays = 127; allotment = ?2; bar = ?18_000; minStay = null; maxStay = null;
  closedToArrival = null; closedToDeparture = null; stopSell = null } }), "sea nights");
ignore ok(OWNER, #setNights({ staff = OWNER; edit = { roomTypeId = 2; fromDay = DAY; toDay = DAY + 30; weekdays = 127; allotment = ?1; bar = ?88_000; minStay = null; maxStay = null;
  closedToArrival = null; closedToDeparture = null; stopSell = null } }), "villa nights");

// ── the quote ────────────────────────────────────────────────────────────────

func stay(rt : Nat, plan : Nat, arrival : Nat, nights : Nat, rooms : Nat) : Cmd.Stay { { roomTypeId = rt; planId = plan; arrival; nights; rooms; adults = 2; children = 0 } };
func quote(st : Cmd.Stay) : ?Q.Quote { switch (Res.quoteStay(ctx(), st)) { case (#ok c) ?c.quote; case (#err _) null } };

switch (quote(stay(1, 1, DAY + 5, 3, 1))) {
  case (?q) {
    check(q.roomSubtotal == 54_000, "flexible room subtotal 54,000, got " # Nat.toText(q.roomSubtotal));
    check(q.taxTotal == 5_400 + 660, "VAT 5,400 and tourist tax 660, got " # Nat.toText(q.taxTotal));
    check(q.total == 60_060, "flexible total 60,060");
    var sum = 0; for (x in q.nightly.vals()) sum += x;
    check(sum == q.roomSubtotal, "per-night lines sum to the subtotal");
    check(Q.firstNights(q, 1) == 18_000 + 1_800 + 220, "the first night with its taxes is 20,020");
  };
  case null check(false, "the flexible stay has a quote");
};
switch (quote(stay(1, 2, DAY + 5, 3, 1))) {
  case (?q) { check(q.roomSubtotal == 45_900 and q.total == 45_900 + 4_590 + 660, "saver total 51,150, got " # Nat.toText(q.total)) };
  case null check(false, "the saver stay has a quote");
};
check(Q.divHalfEven(25_502_5500, 10_000) == 25_503, "half-even rounds .55 up");
check(Q.divHalfEven(25_502_5000, 10_000) == 25_502, "half-even rounds a tie to the even 25,502");
check(Q.divHalfEven(25_503_5000, 10_000) == 25_504, "half-even rounds a tie to the even 25,504");
Debug.print("count: quote vectors = 3");

// ── holds: every night or none ───────────────────────────────────────────────

func hold(owner : Principal, st : Cmd.Stay, k : Nat8) : { #ok : Nat; #err : Text } {
  let ?q = quote(st) else return #err("no quote");
  switch (send(owner, #placeHold({ owner; stay = st; quoteHash = q.hash; key = key(k) }))) { case (#ok a) #ok(a.effects[0]); case (#err r) #err(Con.kindOf(r)) }
};

let villaA = switch (hold(GUEST_A, stay(2, 1, DAY + 8, 2, 1), 1)) { case (#ok id) id; case (#err k) { check(false, "villa hold A: " # k); 0 } };
do {
  // a stay whose LAST night is the one already held: refused, and nothing moves
  let before = St.fingerprintHash(s, later);
  let len = DL.length(log);
  let arena = TA.bytesUsed(s.arena);
  let q : Blob = switch (quote(stay(2, 1, DAY + 6, 3, 1))) { case (?x) x.hash; case null Blob.fromArray([]) };
  refused(GUEST_B, #placeHold({ owner = GUEST_B; stay = stay(2, 1, DAY + 6, 3, 1); quoteHash = q; key = key(2) }), "soldOut", "a stay short on its last night");
  check(St.fingerprintHash(s, later) == before, "the refused hold moved no byte of state");
  check(DL.length(log) == len, "the refused hold appended no block");
  check(TA.bytesUsed(s.arena) == arena, "the refused hold wrote no arena bytes");
  refused(GUEST_B, #placeHold({ owner = GUEST_B; stay = stay(1, 1, DAY + 5, 3, 1); quoteHash = "\00"; key = key(2) }), "priceChanged", "a hold at a price the guest was not shown");
  check(St.fingerprintHash(s, later) == before, "the refused price moved no byte of state");
  Debug.print("count: refusals that left the state untouched = 2");
};

// ── the race for the last room ───────────────────────────────────────────────

var raceHold = 0;
do {
  var wins = 0;
  // villa nights DAY+12..DAY+15 for A; B wants DAY+14..DAY+16 (overlapping), C wants DAY+13 only (nested), D DAY+16..DAY+17 (adjacent).
  // Every guest is quoted while the villa is free, as each of them was shown a price before anyone held.
  func quoted(st : Cmd.Stay) : Blob { switch (quote(st)) { case (?q) q.hash; case null { check(false, "a quote while the villa is free"); Blob.fromArray([]) } } };
  let (sa, sb, sc, sd) = (stay(2, 1, DAY + 12, 3, 1), stay(2, 1, DAY + 14, 2, 1), stay(2, 1, DAY + 13, 1, 1), stay(2, 1, DAY + 15, 2, 1));
  let (qa, qb, qc, qd) = (quoted(sa), quoted(sb), quoted(sc), quoted(sd));
  func race(owner : Principal, st : Cmd.Stay, q : Blob, k : Nat8) : { #ok : Nat; #err : Text } {
    switch (send(owner, #placeHold({ owner; stay = st; quoteHash = q; key = key(k) }))) { case (#ok a) #ok(a.effects[0]); case (#err r) #err(Con.kindOf(r)) }
  };
  switch (race(GUEST_A, sa, qa, 3)) { case (#ok id) { raceHold := id; wins += 1 }; case (#err k) check(false, "the first hold should win, got " # k) };
  switch (race(GUEST_B, sb, qb, 4)) { case (#ok _) check(false, "overlapping hold must lose"); case (#err k) check(k == "soldOut", "the overlap loses as soldOut, got " # k) };
  switch (race(who(12), sc, qc, 5)) { case (#ok _) check(false, "nested hold must lose"); case (#err k) check(k == "soldOut", "the nested stay loses as soldOut, got " # k) };
  switch (race(who(13), sd, qd, 6)) { case (#ok _) wins += 1; case (#err k) check(false, "the adjacent stay should win, got " # k) };
  check(wins == 2, "the first and the adjacent win; the overlap and the nest lose");
  Debug.print("count: race outcomes checked = 4");
};

// ── the waitlist ─────────────────────────────────────────────────────────────

do {
  // the endpoint sends plan 0: the stay is checked, and later offered, on the house rate (plan 1)
  let WAITER = who(14);
  let entry = ok(WAITER, #joinWaitlist({ account = WAITER; stay = stay(2, 0, DAY + 13, 1, 1) }), "join the waitlist for the sold-out villa night")[0];
  refused(WAITER, #joinWaitlist({ account = WAITER; stay = stay(2, 0, DAY + 13, 1, 1) }), "alreadyWaiting", "a second place for the same arrival");
  refused(WAITER, #joinWaitlist({ account = WAITER; stay = stay(2, 0, DAY + 22, 1, 1) }), "invalid", "a place for a stay that has rooms free");
  refused(GUEST_B, #leaveWaitlist({ account = GUEST_B; entryId = entry }), "notTheOwner", "leaving someone else's place");
  ignore ok(GUEST_A, #releaseHold({ owner = GUEST_A; holdId = raceHold }), "A lets the race hold go");
  switch (St.waitEntry(s, entry)) {
    case (?w) {
      check(w.state == #offered, "the freed villa night is offered to the waiting guest");
      switch (St.hold(s, w.offeredHold)) {
        case (?h) check(h.owner == WAITER and h.state == #live and h.planId == 1 and h.arrival == DAY + 13 and h.nights == 1, "the offer is a live hold for the waiting guest on the house rate");
        case null check(false, "the offer names a hold");
      };
    };
    case null check(false, "the waitlist entry exists");
  };
  ignore ok(WAITER, #leaveWaitlist({ account = WAITER; entryId = entry }), "the waiting guest turns the offer down");
  switch (St.waitEntry(s, entry)) {
    case (?w) {
      check(w.state == #left, "the place is left");
      switch (St.hold(s, w.offeredHold)) { case (?h) check(h.state != #live, "turning the offer down lets its hold go"); case null check(false, "the offered hold is kept on record") };
    };
    case null check(false, "the waitlist entry is kept on record");
  };
  Debug.print("count: waitlist cases = 6");
};

// ── confirm and the money law ────────────────────────────────────────────────

func law(what : Text) {
  for (id in Nat.range(1, s.nextBookingId)) {
    switch (St.booking(s, id)) {
      case (?b) check(b.charged == b.paid + b.credited + b.outstanding, what # ": booking " # Nat.toText(id) # " breaks charged = paid + credited + outstanding");
      case null {};
    };
  };
  check(s.paidTotal + s.refundsCommitted == s.capturedDone, what # ": the cash law");
};

func holdLines(id : Nat) : Nat { var t = 0; for ((_, l) in St.holdLinesOf(s, id).vals()) { if (l.night == (switch (St.hold(s, id)) { case (?h) h.arrival; case null 0 })) t += l.amount }; t };

let flexHold = switch (hold(GUEST_A, stay(1, 1, DAY + 5, 3, 1), 7)) { case (#ok id) id; case (#err k) { check(false, "flex hold: " # k); 0 } };
let guarantee = holdLines(flexHold);
check(guarantee == 20_020, "the guarantee is the first night with its taxes");
let guest : Res.GuestFacts = { guestName = "Salma Farouk"; guestEmail = "lxe1.sealed"; note = ""; manageKey = key(8); account = null };
refused(GUEST_A, #confirmHold({ owner = GUEST_A; holdId = flexHold; guestName = guest.guestName; guestEmail = "salma@example.com"; note = ""; manageKey = key(8); account = null;
  auth = { authId = 1; amount = guarantee; currency = "EUR"; merchantRef = flexHold } }), "invalid", "an email that arrives unsealed");
refused(GUEST_A, #confirmHold({ owner = GUEST_A; holdId = flexHold; guestName = guest.guestName; guestEmail = guest.guestEmail; note = ""; manageKey = key(8); account = null;
  auth = { authId = 1; amount = guarantee - 1; currency = "EUR"; merchantRef = flexHold } }), "payment", "an authorisation for the wrong amount");
let flexBooking = ok(GUEST_A, #confirmHold({ owner = GUEST_A; holdId = flexHold; guestName = guest.guestName; guestEmail = guest.guestEmail; note = ""; manageKey = key(8); account = null;
  auth = { authId = 1; amount = guarantee; currency = "EUR"; merchantRef = flexHold } }), "confirm the flexible stay");
law("after the flexible confirmation");
refused(GUEST_B, #confirmHold({ owner = GUEST_B; holdId = villaA; guestName = "x"; guestEmail = "lxe1.x"; note = ""; manageKey = key(9); account = null;
  auth = { authId = 1; amount = 1; currency = "EUR"; merchantRef = villaA } }), "notTheOwner", "someone else's hold");

let saverHold = switch (hold(GUEST_B, stay(1, 2, DAY + 20, 2, 1), 9)) { case (#ok id) id; case (#err k) { check(false, "saver hold: " # k); 0 } };
let saverTotal = switch (St.hold(s, saverHold)) { case (?h) h.quotedTotal; case null 0 };
let saverOut = ok(GUEST_B, #confirmHold({ owner = GUEST_B; holdId = saverHold; guestName = "Selim"; guestEmail = "lxe1.o"; note = ""; manageKey = key(10); account = null;
  auth = { authId = 2; amount = saverTotal; currency = "EUR"; merchantRef = saverHold } }), "confirm the saver stay");
if (saverOut.size() > 1) ignore ok(GUEST_B, #recordGatewayOutcome({ paymentId = saverOut[1]; ok = true }), "the capture lands");
law("after the saver capture");
switch (St.booking(s, if (saverOut.size() > 0) saverOut[0] else 0)) { case (?b) check(b.paid == saverTotal and b.outstanding == 0, "the saver stay is paid in full"); case null check(false, "saver booking") };

// free cancellation of the flexible stay (arrival DAY+5, free until DAY+2)
if (flexBooking.size() > 0) {
  ignore ok(GUEST_A, #cancelBooking({ by = #manageKey; bookingId = flexBooking[0] }), "cancel the flexible stay in time");
  law("after the free cancellation");
  switch (St.booking(s, flexBooking[0])) { case (?b) check(b.charged == b.credited and b.outstanding == 0, "nothing is owed after a free cancellation"); case null {} };
};
// the saver stay is not refundable: cancelling keeps every cent
if (saverOut.size() > 0) {
  ignore ok(GUEST_B, #cancelBooking({ by = #manageKey; bookingId = saverOut[0] }), "cancel the saver stay");
  law("after the saver cancellation");
  switch (St.booking(s, saverOut[0])) { case (?b) check(b.paid == saverTotal and b.credited == 0, "the saver money stays"); case null {} };
};
Debug.print("count: money laws checked = 4");

// a stay arriving today, for the night audit to mark as a no-show
let todayHold = switch (hold(GUEST_A, stay(1, 1, DAY, 2, 1), 11)) { case (#ok id) id; case (#err k) { check(false, "today hold: " # k); 0 } };
let todayG = holdLines(todayHold);
let noShowBooking = ok(GUEST_A, #confirmHold({ owner = GUEST_A; holdId = todayHold; guestName = "Late"; guestEmail = "lxe1.l"; note = ""; manageKey = key(12); account = null;
  auth = { authId = 3; amount = todayG; currency = "EUR"; merchantRef = todayHold } }), "confirm today's stay");

// ── the oracle ───────────────────────────────────────────────────────────────

func walk() : { violations : List.List<Text>; examined : Nat } {
  let out = List.empty<Text>();
  var examined = 0;
  for (section in Nat.range(0, O.SECTIONS)) {
    var cursor : ?Blob = null;
    label pages loop {
      let r = O.page(ctx(), section, cursor, 100);
      examined += r.examined;
      for (v in r.violations.vals()) List.add(out, v.rule # ": " # v.detail);
      switch (r.next) { case null break pages; case (?c) cursor := ?c };
    };
  };
  { violations = out; examined }
};

do {
  let w = walk();
  check(List.size(w.violations) == 0, "the oracle is empty on the real state: " # debug_show List.toArray(w.violations));
  check(w.examined > 0, "the oracle examined something");
  Debug.print("count: rows the oracle examined = " # Nat.toText(w.examined));

  // controls: a fault injected beside the fold is named by its own rule, then removed
  func named(rule : Text) : Bool { for (v in List.values(walk().violations)) { if (Text.startsWith(v, #text rule)) return true }; false };
  let id = R.nightId(1, DAY + 25);
  let ?n = RowStore.get<R.Night>(s.nights, R.night, id) else Runtime.trap("night");
  RowStore.put<R.Night>(s.nights, R.night, id, { n with sold = n.sold + 1 });
  check(named("I2 counters"), "a sold counter moved beside the fold is named I2");
  RowStore.put<R.Night>(s.nights, R.night, id, { n with sold = n.allotment + 1 });
  check(named("I1 capacity"), "a night sold beyond its rooms is named I1");
  RowStore.put<R.Night>(s.nights, R.night, id, n);
  if (flexBooking.size() > 0) {
    let ?b = St.booking(s, flexBooking[0]) else Runtime.trap("booking");
    RowStore.put<R.Booking>(s.bookings, R.booking, flexBooking[0], { b with credited = b.credited + 1 });
    check(named("I4 money"), "a credit written beside its lines is named I4");
    RowStore.put<R.Booking>(s.bookings, R.booking, flexBooking[0], b);
  };
  s.paidTotal += 1;
  check(named("I5 cash"), "a paid total moved beside the payments is named I5");
  s.paidTotal -= 1;
  check(List.size(walk().violations) == 0, "every control was removed");
  Debug.print("count: oracle controls that went red for their own rule = 4");
};

// ── four eyes ────────────────────────────────────────────────────────────────

if (saverOut.size() > 0) {
  let pid = ok(OWNER, #propose({ staff = OWNER; act = #waivePenalty({ bookingId = saverOut[0] }); justification = "flight cancelled by the airline" }), "propose a waiver");
  if (pid.size() > 0) {
    refused(OWNER, #approve({ staff = OWNER; proposalId = pid[0] }), "fourEyes", "the maker approving their own waiver");
    refused(GUEST_A, #approve({ staff = GUEST_A; proposalId = pid[0] }), "notAuthorised", "a guest approving");
    ignore ok(OWNER, #grantRole({ staff = OWNER; subject = OWNER2; role = #owner }), "a second owner");
    ignore ok(OWNER2, #approve({ staff = OWNER2; proposalId = pid[0] }), "the second owner approves");
    law("after the approved waiver");
    switch (St.booking(s, saverOut[0])) { case (?b) check(b.charged == b.credited and b.paid == 0, "the waiver credited the stay and committed its money back"); case null {} };
    refused(OWNER2, #approve({ staff = OWNER2; proposalId = pid[0] }), "proposalState", "an approval twice");
  };
  Debug.print("count: four-eyes cases = 4");
};

// ── authority ────────────────────────────────────────────────────────────────

do {
  // A proposal names its permission by its place in the catalogue, so the catalogue is append only:
  // a permission may join the end, and none may move. (The places moved between the build that went
  // live and this one; that contract holds no proposal, so nothing named a place that moved.)
  let FROZEN : [Text] = [
    "setup.property", "setup.roomType", "setup.room", "setup.ratePlan", "setup.planInclusions", "setup.planDeposit",
    "setup.cardPolicy", "setup.mailRelay", "setup.mailCredential", "setup.mailOn", "booking.attachMail", "mail.outcome",
    "mail.test", "setup.taxRule", "setup.dataKey", "setup.clock", "rates.edit", "rates.editMany",
    "desk.checkIn", "desk.checkOut", "desk.idBegin", "desk.idPut", "desk.idFile", "desk.settle",
    "hk.mark", "hk.outOfOrder", "hk.return", "setup.extra", "desk.charge", "desk.payer",
    "desk.route", "desk.settleShare", "desk.invoice", "audit.open", "audit.advance", "audit.close",
    "roles.grant", "roles.revoke", "proposal.approve", "proposal.reject", "booking.staffCancel", "booking.waivePenalty",
    "booking.refundOutsidePolicy", "booking.compNights", "booking.priceOverride", "booking.editGuestRecord", "booking.voidCharge", "booking.creditNote",
    "booking.refundAtDesk", "setup.taxEta", "setup.etaProfile", "desk.book", "desk.moveRoom", "rates.company",
    "rates.planAccess", "rates.promo", "desk.bookCoded", "rates.block", "rates.releaseBlock", "desk.pickUp",
    "setup.rules"
  ];
  let cat = Staff.catalogue();
  check(cat.size() >= FROZEN.size(), "the catalogue still has every permission it had");
  var kept = 0;
  for (i in Nat.range(0, FROZEN.size())) { if (i < cat.size() and cat[i].id == FROZEN[i]) kept += 1 else check(false, "permission " # FROZEN[i] # " left place " # Nat.toText(i)) };
  check(kept == FROZEN.size(), "every permission is at its place");
  Debug.print("count: permissions held at their place = " # Nat.toText(kept));
};

do {
  let r = Permissions.validate(Staff.catalogue(), Staff.STAFF_COMMANDS, []);
  check(Permissions.clean(r), "the catalogue is total over the staff commands: " # debug_show r.faults);
  // every family is either a staff command, a guest or system command, or proposed through `propose`
  for (fam in Cmd.FAMILIES.vals()) {
    let staff = Array.find<Text>(Staff.STAFF_COMMANDS, func(x) { x == fam }) != null;
    let other = Array.find<Text>(Staff.NON_STAFF_COMMANDS, func(x) { x == fam }) != null;
    check(staff != other, "family " # fam # " is named exactly once, as staff or as guest and system");
  };
  Debug.print("count: permissions checked = " # Nat.toText(r.checked));
};

// ── the night audit ──────────────────────────────────────────────────────────

do {
  let day0 = today();
  refused(OWNER, #closeDay({ staff = OWNER; day = day0 }), "audit", "a close with no audit");
  ignore ok(OWNER, #openAudit({ staff = OWNER; day = day0 }), "open the audit");
  refused(GUEST_B, #placeHold({ owner = GUEST_B; stay = stay(1, 1, day0, 1, 1); quoteHash = "\00"; key = key(3) }), "auditOpen", "a same-day hold during the audit");
  var steps = 0;
  label run loop {
    switch (send(OWNER, #advanceAudit({ staff = OWNER; day = day0; limit = 8 }))) {
      case (#ok _) { steps += 1; if (steps > 200) break run };
      case (#err _) break run;
    };
  };
  if (noShowBooking.size() > 0) {
    switch (St.booking(s, noShowBooking[0])) { case (?b) check(b.status == #noShow and b.outstanding + b.paid == b.penalty, "the guest who did not come is a no-show and owes the penalty"); case null {} };
  };
  if (s.walk.violations.size() > 0) Debug.print("the audit's walk: " # debug_show s.walk.violations);
  ignore ok(OWNER, #closeDay({ staff = OWNER; day = day0 }), "close the day");
  check(today() == day0 + 1, "the business date rolled one day");
  switch (St.dayFigures(later, day0)) {
    case (?f) check(f.pickupFrom == 1 and f.pickupBookings == f.pickupCount and f.pickupCount == s.nextBookingId - 1 and f.noShows == (if (noShowBooking.size() > 0) 1 else 0)
      and f.roomsSeen == f.roomsTotal, "the first figures count every booking ever made, and the no-show");
    case null check(false, "the audit wrote no figures for its day");
  };
  law("after the audit");
  Debug.print("count: audit steps = " # Nat.toText(steps));
};

// ── a booking's history, read from the log ───────────────────────────────────

do {
  func history(id : Nat) : [Text] {
    let ?b = St.booking(s, id) else return [];
    let out = List.empty<Text>();
    for (i in Nat.range(0, DL.length(log))) {
      switch (DL.get<Log.Event>(log, Log.codec, i)) {
        case (?blk) switch (H.actOn(s, blk.event.command, id, b)) { case (?a) List.add(out, a); case null {} };
        case null {};
      };
    };
    List.toArray(out)
  };
  if (saverOut.size() > 0 and flexBooking.size() > 0) {
    let saver = history(saverOut[0]);
    check(saver == ["confirmHold", "recordGatewayOutcome", "cancelBooking", "propose:waivePenalty", "approve"],
      "the saver stay's history is its five acts in order, got " # debug_show saver);
    let flex = history(flexBooking[0]);
    check(flex == ["confirmHold", "cancelBooking"], "the flexible stay's history is its confirmation and cancellation, got " # debug_show flex);
  } else check(false, "the history cases need both stays");
  Debug.print("count: histories read from the log = 2");
};

// ── several edits in one save ────────────────────────────────────────────────
//
// Room types side by side, a percentage on the rate (half-even, once), the undo of a save; and every
// refusal leaves the state as it was: the fingerprint (every row and counter), the log and the arena.

do {
  let F = DAY + 100;   // far past every earlier case's nights
  func ed(rt : Nat, from : Nat, to : Nat) : Cmd.NightsEdit {
    { roomTypeId = rt; fromDay = from; toDay = to; weekdays = 127; allotment = null; bar = null; minStay = null; maxStay = null; closedToArrival = null; closedToDeparture = null; stopSell = null }
  };
  func night(rt : Nat, d : Nat) : ?R.Night { RowStore.get<R.Night>(s.nights, R.night, R.nightId(rt, d)) };
  func barOf(rt : Nat, d : Nat) : Nat { switch (night(rt, d)) { case (?n) n.bar; case null 0 } };
  func many(edits : [Cmd.ManyEdit]) : Cmd.Command { #setNightsMany({ staff = OWNER; edits }) };

  // open both room types on new nights in one save
  let opened = ok(OWNER, many([
    { edit = { ed(1, F, F + 6) with allotment = ?2; bar = ?18_000 }; adjust = null },
    { edit = { ed(2, F, F + 6) with allotment = ?1; bar = ?88_000 }; adjust = null },
  ]), "two room types opened in one save");
  check(opened.size() == 2 and opened[0] == 12 and opened[1] == 2, "twelve nights written by two edits, got " # debug_show opened);

  // a percentage: up 10% on the villa, down 3.33% on the sea room, each rounded half-even once
  ignore ok(OWNER, many([
    { edit = ed(2, F, F + 3); adjust = ?{ up = true; bps = 1_000 } },
    { edit = ed(1, F, F + 3); adjust = ?{ up = false; bps = 333 } },
  ]), "a percentage on two room types");
  check(barOf(2, F) == 96_800, "88,000 up 10% is 96,800, got " # Nat.toText(barOf(2, F)));
  check(barOf(1, F + 2) == 17_401, "18,000 down 3.33% is 17,400.6, rounded to 17,401, got " # Nat.toText(barOf(1, F + 2)));
  check(barOf(1, F + 3) == 18_000, "a night outside the range keeps its rate");
  check(Q.divHalfEven(50 * 9_000, 10_000) == 45 and Q.divHalfEven(25 * 10_100, 10_000) == 25, "half-even on small rates: 45, and 25.25 to 25");

  // the undo of a save: each night's values before it, written back in one save
  let undoDays = [F + 3, F + 4, F + 5];
  let before = Array.map<Nat, ?R.Night>(undoDays, func(d) { night(1, d) });
  ignore ok(OWNER, many([{ edit = { ed(1, F + 3, F + 6) with bar = ?25_000; stopSell = ?true; minStay = ?3 }; adjust = null }]), "a save to undo");
  check(barOf(1, F + 4) == 25_000, "the save to undo landed");
  let undo = Array.tabulate<Cmd.ManyEdit>(undoDays.size(), func(i) {
    let ?n = before[i] else Runtime.trap("undo night");
    { edit = { roomTypeId = 1; fromDay = undoDays[i]; toDay = undoDays[i] + 1; weekdays = 127; allotment = ?n.allotment; bar = ?n.bar; minStay = ?n.minStay;
      maxStay = ?n.maxStay; closedToArrival = ?n.closedToArrival; closedToDeparture = ?n.closedToDeparture; stopSell = ?n.stopSell }; adjust = null }
  });
  ignore ok(OWNER, many(undo), "the undo");
  var restored = 0;
  for (i in Nat.range(0, undoDays.size())) {
    switch (night(1, undoDays[i]), before[i]) {
      case (?a, ?b) { if ({ a with lastBlock = 0 } == { b with lastBlock = 0 }) restored += 1 };
      case _ {};
    };
  };
  check(restored == 3, "the undo restores every value of every night, got " # Nat.toText(restored));
  Debug.print("count: nights restored by an undo = " # Nat.toText(restored));

  // refusals: the state is exactly as it was
  var untouched = 0;
  func unchanged(caller : Principal, edits : [Cmd.ManyEdit], kind : Text, what : Text) {
    let fp = St.fingerprintHash(s, later);
    let len = DL.length(log);
    let arena = TA.bytesUsed(s.arena);
    let nightsBefore = RowStore.size(s.nights);
    refused(caller, #setNightsMany({ staff = caller; edits }), kind, what);
    let same = St.fingerprintHash(s, later) == fp and DL.length(log) == len and TA.bytesUsed(s.arena) == arena and RowStore.size(s.nights) == nightsBefore;
    check(same, what # ": the refusal moved state");
    if (same) untouched += 1;
  };
  // the second edit fails, so the first, valid on its own, is not written either
  unchanged(OWNER, [
    { edit = { ed(1, F, F + 2) with bar = ?19_000 }; adjust = null },
    { edit = { ed(2, F, F + 2) with allotment = ?5 }; adjust = null },
  ], "allotmentAboveRooms", "a valid edit beside one above the rooms");
  unchanged(OWNER, [
    { edit = { ed(1, F, F + 3) with bar = ?19_000 }; adjust = null },
    { edit = { ed(1, F + 2, F + 4) with stopSell = ?true }; adjust = null },
  ], "invalid", "two edits touching the same night");
  unchanged(OWNER, [{ edit = { ed(1, F, F + 2) with bar = ?19_000 }; adjust = ?{ up = true; bps = 500 } }], "invalid", "a rate and a percentage together");
  unchanged(OWNER, [{ edit = ed(1, F, F + 2); adjust = ?{ up = false; bps = 10_000 } }], "invalid", "a rate down by 100%");
  unchanged(OWNER, [{ edit = ed(1, F, F + 2); adjust = ?{ up = true; bps = 100_001 } }], "invalid", "a rate up past eleven times");
  unchanged(OWNER, [{ edit = ed(1, F, F + 2); adjust = ?{ up = true; bps = 0 } }], "invalid", "a percentage of zero");
  unchanged(OWNER, [{ edit = ed(1, F + 50, F + 52); adjust = ?{ up = true; bps = 500 } }], "invalid", "a percentage on nights not open yet");
  unchanged(OWNER, [], "invalid", "a save with no changes");
  unchanged(OWNER, Array.tabulate<Cmd.ManyEdit>(257, func(i) { { edit = { ed(1, F, F + 1) with stopSell = ?true }; adjust = null } }), "invalid", "a save of 257 changes");
  unchanged(GUEST_A, [{ edit = { ed(1, F, F + 2) with stopSell = ?true }; adjust = null }], "notAuthorised", "a guest saving rates");
  // a percentage that rounds a one-unit rate to nothing
  ignore ok(OWNER, many([{ edit = { ed(1, F + 7, F + 8) with bar = ?1 }; adjust = null }]), "a one-unit rate");
  unchanged(OWNER, [{ edit = ed(1, F + 7, F + 8); adjust = ?{ up = false; bps = 6_000 } }], "invalid", "a percentage that takes a rate to nothing");
  // bytes a browser sends: the whole edit list reads back, and anything else is refused
  let w = C.Writer();
  Enc.manyEdits(w, [{ edit = ed(1, F, F + 2); adjust = ?{ up = true; bps = 750 } }]);
  let hex = C.hex(w.toBlob());
  // the vector the page's own encoder (frontend/src/api/manyEdits.ts) is tested against, byte for byte
  check(hex == "00010101025157025159017f0000000000000001010202ee", "the shared edit-list vector, got " # hex);
  check(Enc.readManyEditsHex(hex) == ?[{ edit = ed(1, F, F + 2); adjust = ?{ up = true; bps = 750 } }], "the edit list reads back from its hex");
  check(Enc.readManyEditsHex(hex # "00") == null, "a trailing byte is refused");
  let bytes = Blob.toArray(w.toBlob());
  check(Enc.readManyEditsHex(C.hexOf(Array.sliceToArray<Nat8>(bytes, 0, bytes.size() - 1))) == null, "a list cut short by one byte is refused");
  check(Enc.readManyEditsHex("zz") == null, "a non-hex list is refused");
  Debug.print("count: many-edit refusals that left the state untouched = " # Nat.toText(untouched));
};

// ── the hotel clock and the night audit by itself ────────────────────────────
//
// The owner sets the hotel's time zone and the audit's local time and turns the automatic audit on: the
// contract's own principal is granted the auditor role and nothing more. HotelClock.runDue, the loop
// the contract's timer runs, closes the due days as that principal through the same accept path, a few
// acts at a time; turned off, the grant ends and its first act is refused. Every refusal of the clock
// command leaves the five dimensions as they were.

do {
  let RUNNER = who(900);   // the contract's own principal, as the contract fills it in
  let CAIRO = "EET-2EEST,M4.5.5/0,M10.5.4/24";
  let AT3 = 3 * 3600;
  func clockCmd(staff : Principal, name : Text, rule : Text, at : Nat, auto : Bool, runner : Principal) : Cmd.Command {
    #setHotelClock({ staff; zoneName = name; zoneRule = rule; auditAt = at; auto; runner })
  };
  func clocks() : Nat { RowStore.size(St.later(later, St.CLOCK_TABLE)) };
  // the audit before this one wrote its figures (and revenue rows, if a guest was in house), each a section
  check(St.fingerprintCounted(s, later).1 == St.SECTIONS + auditSections(), "a hotel with no clock writes the sections it always wrote, and its audit's figures, got " # Nat.toText(St.fingerprintCounted(s, later).1));

  var untouched = 0;
  func unchanged(caller : Principal, c : Cmd.Command, kind : Text, what : Text) {
    let fp = St.fingerprintHash(s, later);
    let len = DL.length(log);
    let arena = TA.bytesUsed(s.arena);
    let grants = RowStore.size(s.grants);
    let nextGrant = s.nextGrantId;
    let clockRows = clocks();
    refused(caller, c, kind, what);
    let same = St.fingerprintHash(s, later) == fp and DL.length(log) == len and TA.bytesUsed(s.arena) == arena
      and RowStore.size(s.grants) == grants and s.nextGrantId == nextGrant and clocks() == clockRows;
    check(same, what # ": the refusal moved state");
    if (same) untouched += 1;
  };
  let REVENUE = who(20);
  ignore ok(OWNER, #grantRole({ staff = OWNER; subject = REVENUE; role = #revenue }), "a revenue manager");
  unchanged(REVENUE, clockCmd(REVENUE, "Africa/Cairo", CAIRO, AT3, true, RUNNER), "notAuthorised", "a revenue manager setting the clock");
  unchanged(GUEST_A, clockCmd(GUEST_A, "Africa/Cairo", CAIRO, AT3, true, RUNNER), "notAuthorised", "a guest setting the clock");
  unchanged(OWNER, clockCmd(OWNER, "", CAIRO, AT3, true, RUNNER), "invalid", "a zone with no name");
  unchanged(OWNER, clockCmd(OWNER, Text.join(Array.tabulate<Text>(65, func(_) { "z" }).vals(), ""), CAIRO, AT3, true, RUNNER), "tooLong", "a zone name of 65 bytes");
  unchanged(OWNER, clockCmd(OWNER, "Africa/Cairo", "EET-2EEST", AT3, true, RUNNER), "invalid", "a summer time with no rule");
  unchanged(OWNER, clockCmd(OWNER, "Africa/Cairo", CAIRO, 86_400, true, RUNNER), "invalid", "an audit at 24:00");
  unchanged(OWNER, clockCmd(OWNER, "Africa/Cairo", CAIRO, AT3 + 30, true, RUNNER), "invalid", "an audit time not on the minute");
  unchanged(OWNER, clockCmd(OWNER, "Africa/Cairo", CAIRO, AT3, true, Principal.fromText("2vxsx-fae")), "invalid", "an automatic audit with no identity");
  unchanged(OWNER, clockCmd(OWNER, "Africa/Cairo", CAIRO, AT3, true, OWNER), "invalid", "an automatic audit run as a person");

  // on: the runner holds the auditor role, and the auditor role holds the audit and nothing else
  let on = ok(OWNER, clockCmd(OWNER, "Africa/Cairo", CAIRO, AT3, true, RUNNER), "the automatic audit on");
  check(on.size() == 3 and on[0] == AT3 and on[1] == 1 and on[2] > 0, "the clock reports the time, on, and the grant, got " # debug_show on);
  check(St.holdsRole(s, RUNNER, #auditor), "the runner holds the auditor role");
  check(St.hotelClock(later) == ?{ zoneName = { offset = TA.bytesUsed(s.arena) - 29 - 12; length = 12 }; zoneRule = { offset = TA.bytesUsed(s.arena) - 29; length = 29 };
    auditAt = AT3; auto = true; runner = ?RUNNER; lastBlock = DL.length(log) - 1 }, "the clock row is what was set");
  check(St.fingerprintCounted(s, later).1 == St.SECTIONS + 1 + auditSections(), "a hotel with a clock writes its section too");
  var held = 0;
  for (p in ["audit.open", "audit.advance", "audit.close"].vals()) { if (Staff.may(s, RUNNER, p)) held += 1 else check(false, "the runner may not " # p) };
  for (p in ["desk.checkIn", "desk.settle", "rates.edit", "rates.editMany", "roles.grant", "setup.clock", "proposal.approve", "booking.staffCancel"].vals()) {
    check(not Staff.may(s, RUNNER, p), "the runner may " # p);
  };
  check(held == 3, "the runner holds the three audit acts");
  unchanged(OWNER, #revokeRole({ staff = OWNER; subject = RUNNER; role = #auditor }), "invalid", "revoking the automatic audit's role while it is on");

  // when a day is due, in Cairo: summer time (UTC+3) in October, standard (UTC+2) in December
  let rule = switch (Zone.parse(CAIRO)) { case (#ok r) r; case (#err e) Runtime.trap(e) };
  func utc(y : Nat, m : Nat, d : Nat, hh : Nat, mm : Nat) : Int { let ?x = CivilDate.fromCivil(y, m, d) else Runtime.trap("date"); x * 86_400 + hh * 3600 + mm * 60 };
  func dayOf(y : Nat, m : Nat, d : Nat) : ?Nat { CivilDate.fromCivil(y, m, d) };
  check(HotelClock.dueThrough(rule, AT3, utc(2026, 10, 11, 23, 59)) == dayOf(2026, 10, 10), "02:59 summer time on the 12th: the 10th is the last due");
  check(HotelClock.dueThrough(rule, AT3, utc(2026, 10, 12, 0, 0)) == dayOf(2026, 10, 11), "03:00 summer time on the 12th: the 11th is due");
  check(HotelClock.dueThrough(rule, AT3, utc(2026, 12, 1, 0, 59)) == dayOf(2026, 11, 29), "02:59 standard time on 1 December: the 29th is the last due");
  check(HotelClock.dueThrough(rule, AT3, utc(2026, 12, 1, 1, 0)) == dayOf(2026, 11, 30), "03:00 standard time on 1 December: the 30th is due");
  // summer time ends at 24:00 on 29 October (21:00 UTC) by going back to 23:00: midnight comes at 22:00 UTC
  check(HotelClock.dueThrough(rule, 0, utc(2026, 10, 29, 21, 59) + 59) == dayOf(2026, 10, 28), "an audit at midnight: the hour repeated as summer time ends is still the 29th");
  check(HotelClock.dueThrough(rule, 0, utc(2026, 10, 29, 22, 0)) == dayOf(2026, 10, 29), "an audit at midnight: due at 22:00 UTC, the night summer time ends");
  check(HotelClock.dueThrough(rule, AT3, 0) == null, "nothing is due in the first day of 1970");

  // the loop the timer runs, a few acts a tick, as the runner
  func asRunner(c : Cmd.Command) : { ok : Bool; reason : Text } {
    switch (send(RUNNER, c)) { case (#ok _) ({ ok = true; reason = "" }); case (#err r) ({ ok = false; reason = Con.textOf(r) }) }
  };
  func ticksUntilClosed(through : Nat) : Nat {
    var ticks = 0;
    label t while (today() <= through and ticks < 400) {
      let r = HotelClock.runDue(s, today, RUNNER, through, 3, asRunner);
      ticks += 1;
      if (not r.ok) { check(false, "the automatic audit was refused: " # r.act # ": " # r.reason); break t };
      check(r.steps <= 3, "a tick took more than its bound");
    };
    ticks
  };
  let closedBefore = s.closedDays;
  let d0 = today();
  check(HotelClock.runDue(s, today, RUNNER, d0 - 1, 3, asRunner).steps == 0, "nothing due, nothing run");
  let firstTicks = ticksUntilClosed(d0);
  check(today() == d0 + 1, "the automatic audit closed the due day, today is " # Nat.toText(today()));
  check(firstTicks > 1, "the day took more than one tick, so the run carried on from the state");
  switch (DL.get<Log.Event>(log, Log.codec, DL.length(log) - 1)) {
    case (?b) check(b.caller == RUNNER and Cmd.familyOf(b.event.command) == "closeDay", "the log records the runner closing the day");
    case null check(false, "the last block reads back");
  };

  // off: the grant ends, the texts are not written again, and the runner's next act is refused
  let arenaOn = TA.bytesUsed(s.arena);
  ignore ok(OWNER, clockCmd(OWNER, "Africa/Cairo", CAIRO, AT3, false, RUNNER), "the automatic audit off");
  check(not St.holdsRole(s, RUNNER, #auditor), "off ends the runner's grant");
  check(TA.bytesUsed(s.arena) == arenaOn, "the same zone is pointed at again, not written twice");
  let fpOff = St.fingerprintHash(s, later);
  let stopped = HotelClock.runDue(s, today, RUNNER, today(), 3, asRunner);
  check(not stopped.ok and stopped.steps == 1 and stopped.act == "openAudit", "the runner's first act after off is refused, and the run stops there");
  check(St.fingerprintHash(s, later) == fpOff and today() == d0 + 1, "the refused act moved nothing");

  // on again, two days behind: caught up one day at a time
  ignore ok(OWNER, clockCmd(OWNER, "Africa/Cairo", CAIRO, 2 * 3600 + 30 * 60, true, RUNNER), "on again, at 02:30");
  let d1 = today();
  ignore ticksUntilClosed(d1 + 1);
  check(today() == d1 + 2, "two due days caught up, today is " # Nat.toText(today()));
  check(s.closedDays == closedBefore + 3, "three days closed by the runner, got " # Nat.toText(s.closedDays - closedBefore));

  Debug.print("count: clock refusals that left the state untouched = " # Nat.toText(untouched));
  Debug.print("count: days closed by the automatic audit = 3");
  Debug.print("count: ticks for the first day = " # Nat.toText(firstTicks));
};

// ── housekeeping ─────────────────────────────────────────────────────────────
//
// Two guests stay a night in the same room: check-out leaves it dirty, one person cleans it and a second
// inspects it, and the next guest is offered it first. A room on a new type goes out of order with
// dates: it leaves the count only for the nights before it is back, so the nights after keep their
// allotment, and the same room out with no dates is refused. Every refusal leaves the five dimensions
// (the fingerprint, the log, the arena, the rooms and the housekeeping rows) as they were.

do {
  let HK1 = who(30);
  let HK2 = who(31);
  let CLERK = who(32);
  ignore ok(OWNER, #grantRole({ staff = OWNER; subject = HK1; role = #housekeeping }), "a housekeeper");
  ignore ok(OWNER, #grantRole({ staff = OWNER; subject = HK2; role = #housekeeping }), "a second housekeeper");
  ignore ok(OWNER, #grantRole({ staff = OWNER; subject = CLERK; role = #revenue }), "a revenue clerk");
  func hkRows() : Nat { RowStore.size(St.later(later, St.HK_TABLE)) };
  func hkOf(id : Nat) : ?R.Housekeeping { St.housekeeping(later, id) };
  func cleaningOf(id : Nat) : Text { Hk.cleaningText(hkOf(id)) };
  var untouched = 0;
  func unchanged(caller : Principal, c : Cmd.Command, kind : Text, what : Text) {
    let fp = St.fingerprintHash(s, later);
    let len = DL.length(log);
    let arena = TA.bytesUsed(s.arena);
    let rooms = RowStore.size(s.rooms);
    let rows = hkRows();
    refused(caller, c, kind, what);
    let same = St.fingerprintHash(s, later) == fp and DL.length(log) == len and TA.bytesUsed(s.arena) == arena
      and RowStore.size(s.rooms) == rooms and hkRows() == rows;
    check(same, what # ": the refusal moved state");
    if (same) untouched += 1;
  };
  func mark(by : Principal, room : Nat, c : E.Cleaning) : Cmd.Command { #markRoom({ staff = by; roomId = room; cleaning = c }) };
  func out(by : Principal, room : Nat, reason : Text, until : Nat) : Cmd.Command { #takeRoomOutOfOrder({ staff = by; roomId = room; reason; untilDay = until }) };

  // a night's stay on the saver plan, paid in full, arriving today
  func stayTonight(guest : Principal, k : Nat8, authId : Nat, name : Text) : Nat {
    let hid = switch (hold(guest, stay(1, 2, today(), 1, 1), k)) { case (#ok id) id; case (#err e) { check(false, name # "'s hold: " # e); return 0 } };
    let total = switch (St.hold(s, hid)) { case (?h) h.quotedTotal; case null 0 };
    let made = ok(guest, #confirmHold({ owner = guest; holdId = hid; guestName = name; guestEmail = "lxe1.hk"; note = ""; manageKey = key(k); account = null;
      auth = { authId; amount = total; currency = "EUR"; merchantRef = hid } }), "confirm " # name # "'s night");
    if (made.size() < 2) return 0;
    ignore ok(guest, #recordGatewayOutcome({ paymentId = made[1]; ok = true }), name # "'s capture lands");
    made[0]
  };

  check(hkRows() == 0 and cleaningOf(1) == "not recorded", "before anyone leaves a room, no room has a record");
  check(St.fingerprintCounted(s, later).1 == St.SECTIONS + 1 + auditSections(), "an empty housekeeping table writes no section");
  let first = stayTonight(who(40), 40, 40, "Nadia");
  ignore ok(OWNER, #checkIn({ staff = OWNER; bookingId = first; roomIds = [1] }), "Nadia checks in to room 1");

  unchanged(GUEST_A, mark(GUEST_A, 2, #clean), "notAuthorised", "a guest marking a room");
  unchanged(CLERK, mark(CLERK, 2, #clean), "notAuthorised", "a revenue clerk marking a room");
  unchanged(HK1, mark(HK1, 99, #clean), "noSuchRoom", "a room that does not exist");
  unchanged(HK1, mark(HK1, 2, #inspected), "invalid", "an inspection of a room nobody has cleaned");
  unchanged(HK1, out(HK1, 1, "Broken lamp", today() + 2), "roomNotVacant", "an occupied room out of order");
  unchanged(HK1, #returnRoomToService({ staff = HK1; roomId = 2 }), "invalid", "a room in service put back in service");

  ignore ok(OWNER, #checkOut({ staff = OWNER; bookingId = first }), "Nadia checks out");
  check(cleaningOf(1) == "dirty" and hkRows() == 1, "the room she left is dirty");
  check(St.fingerprintCounted(s, later).1 == St.SECTIONS + 2 + auditSections(), "a hotel with housekeeping rows writes their section");
  ignore ok(HK1, mark(HK1, 1, #clean), "the housekeeper cleans room 1");
  check(hkOf(1) == ?{ cleaning = #clean; cleanedBy = ?HK1; inspectedBy = null; outReason = TA.EMPTY; outFrom = 0; outUntil = 0; changedDay = today(); lastBlock = DL.length(log) - 1 },
    "the clean room names its cleaner");
  unchanged(HK1, mark(HK1, 1, #clean), "invalid", "a clean room marked clean");
  unchanged(HK1, mark(HK1, 1, #inspected), "invalid", "the cleaner inspecting their own cleaning");
  unchanged(OWNER, mark(OWNER, 99, #inspected), "noSuchRoom", "the owner inspecting a room that does not exist");
  ignore ok(HK2, mark(HK2, 1, #inspected), "a second housekeeper inspects room 1");
  switch (hkOf(1)) { case (?h) check(h.cleaning == #inspected and h.cleanedBy == ?HK1 and h.inspectedBy == ?HK2, "the inspection names both people"); case null check(false, "room 1 has a record") };

  // the next guest is offered the readiest room first
  check(Hk.readiness(hkOf(1)) < Hk.readiness(hkOf(2)) and Hk.readiness(null) < Hk.readiness(?{ Option.unwrap(hkOf(1)) with cleaning = #dirty }),
    "inspected comes before not recorded, and not recorded before dirty");
  check(Hk.readiness(?{ Option.unwrap(hkOf(1)) with cleaning = #clean }) == 1 and Hk.readiness(hkOf(1)) == 0, "inspected first, then clean");
  let second = stayTonight(who(41), 41, 41, "Karim");
  ignore ok(OWNER, #checkIn({ staff = OWNER; bookingId = second; roomIds = [1] }), "Karim checks in to the inspected room");
  ignore ok(OWNER, #checkOut({ staff = OWNER; bookingId = second }), "Karim checks out");
  switch (hkOf(1)) { case (?h) check(h.cleaning == #dirty and h.cleanedBy == null and h.inspectedBy == null, "after the stay nobody vouches for the room"); case null check(false, "room 1 record") };
  ignore ok(HK1, mark(HK1, 1, #clean), "cleaned again");
  ignore ok(HK2, mark(HK2, 1, #dirty), "found dirty on inspection");
  ignore ok(HK2, mark(HK2, 1, #clean), "cleaned by the second housekeeper");
  ignore ok(HK1, mark(HK1, 1, #inspected), "and inspected by the first");
  law("after two stays in one room");

  // out of order with dates, on a type of its own: two garden rooms, both offered, a leak in one
  roomType("GARDEN", 2);
  let GT = s.nextRoomTypeId - 1;
  let G1 = ok(OWNER, #upsertRoom({ staff = OWNER; id = 0; roomTypeId = GT; number = "401"; outOfOrder = false }), "garden room 401")[0];
  let G2 = ok(OWNER, #upsertRoom({ staff = OWNER; id = 0; roomTypeId = GT; number = "402"; outOfOrder = false }), "garden room 402")[0];
  let T = today();
  func gardenNights(from : Nat, to : Nat, allotment : Nat, bar : ?Nat) : Cmd.Command {
    #setNights({ staff = OWNER; edit = { roomTypeId = GT; fromDay = from; toDay = to; weekdays = 127; allotment = ?allotment; bar; minStay = null; maxStay = null;
      closedToArrival = null; closedToDeparture = null; stopSell = null } })
  };
  ignore ok(OWNER, gardenNights(T, T + 30, 2, ?15_000), "both garden rooms offered for a month");
  // with no dates, the room would leave every night of the month: refused
  unchanged(OWNER, #upsertRoom({ staff = OWNER; id = G2; roomTypeId = GT; number = "402"; outOfOrder = true }), "allotmentAboveRooms", "a room out with no dates while every night offers it");
  unchanged(HK1, out(HK1, G2, "Leak under the basin", T + 3), "allotmentAboveRooms", "out for three nights the type still offers it");
  ignore ok(OWNER, gardenNights(T, T + 3, 1, null), "one garden room offered for three nights");
  unchanged(HK1, out(HK1, G2, "", T + 3), "invalid", "out of order with no reason");
  unchanged(HK1, out(HK1, G2, Text.join(Array.tabulate<Text>(161, func(_) { "x" }).vals(), ""), T + 3), "tooLong", "a reason of 161 bytes");
  unchanged(HK1, out(HK1, G2, "Leak under the basin", T), "invalid", "out of order until today");
  unchanged(HK1, out(HK1, G2, "Leak under the basin", T + 241), "beyondHorizon", "out of order past the horizon");
  unchanged(GUEST_A, out(GUEST_A, G2, "Leak under the basin", T + 3), "notAuthorised", "a guest taking a room out");
  ignore ok(HK1, out(HK1, G2, "Leak under the basin", T + 3), "402 out of order for three nights");
  switch (St.room(s, G2), hkOf(G2)) {
    case (?r, ?h) check(r.status == #outOfOrder and h.cleaning == #dirty and h.outFrom == T and h.outUntil == T + 3 and TA.get(s.arena, h.outReason) == "Leak under the basin",
      "402 is out, dirty, with its reason and dates");
    case _ check(false, "402 and its record");
  };
  let garden = St.inService(s, later, GT);
  check(St.inServiceOn(garden, T) == 1 and St.inServiceOn(garden, T + 2) == 1 and St.inServiceOn(garden, T + 3) == 2, "402 leaves the count for three nights and is back on the fourth");
  unchanged(HK1, out(HK1, G1, "Paint", T + 1), "allotmentAboveRooms", "the last garden room in service out tonight");
  unchanged(HK1, out(HK1, G2, "Leak under the basin", T + 5), "allotmentAboveRooms", "402's dates stretched over nights that offer it");
  unchanged(HK1, out(HK1, G2, "Leak under the basin", T + 3), "invalid", "402 out again for the same reason and dates");
  unchanged(OWNER, gardenNights(T, T + 1, 2, null), "allotmentAboveRooms", "both garden rooms offered tonight while 402 is out");
  unchanged(HK1, mark(HK1, G2, #clean), "invalid", "a room out of order marked clean");
  ignore ok(HK1, out(HK1, G2, "Leak under the basin", T + 2), "402 back a night sooner");
  ignore ok(OWNER, gardenNights(T + 2, T + 3, 2, null), "both garden rooms offered from the night 402 is back");
  check(Option.unwrap(hkOf(G2)).outFrom == T, "new dates keep the day it went out");
  ignore ok(HK2, #returnRoomToService({ staff = HK2; roomId = G2 }), "402 back early");
  switch (St.room(s, G2), hkOf(G2)) {
    case (?r, ?h) check(r.status == #active and h.cleaning == #dirty and h.outUntil == 0 and h.outReason.length == 0, "402 is in service, dirty, with no dates");
    case _ check(false, "402 and its record");
  };
  ignore ok(HK1, out(HK1, G2, "Leak under the basin", T + 2), "402 out again");
  ignore ok(OWNER, #upsertRoom({ staff = OWNER; id = G2; roomTypeId = GT; number = "402"; outOfOrder = true }), "its setup saved with it still out");
  check(Option.unwrap(hkOf(G2)).outUntil == T + 2, "an edit that keeps the room out keeps its dates");
  ignore ok(OWNER, #upsertRoom({ staff = OWNER; id = G2; roomTypeId = GT; number = "402"; outOfOrder = false }), "its setup puts it back in service");
  check(Option.unwrap(hkOf(G2)).outUntil == 0 and Option.unwrap(hkOf(G2)).outReason.length == 0, "putting it back from its setup ends its dates");
  ignore ok(HK1, out(HK1, G2, "Leak under the basin", T + 2), "402 out until the night after tomorrow");
  law("after housekeeping");

  // the books: nothing wrong, and each housekeeping fault named by its own rule
  let w = walk();
  check(List.size(w.violations) == 0, "the oracle is empty after housekeeping: " # debug_show List.toArray(w.violations));
  func named(rule : Text) : Bool { for (v in List.values(walk().violations)) { if (Text.startsWith(v, #text rule)) return true }; false };
  let hkStore = St.later(later, St.HK_TABLE);
  let h1 = Option.unwrap(hkOf(1));
  RowStore.put<R.Housekeeping>(hkStore, R.housekeeping, 1, { h1 with inspectedBy = h1.cleanedBy });
  check(named("I10 housekeeping"), "an inspection by the room's own cleaner is named I10");
  RowStore.put<R.Housekeeping>(hkStore, R.housekeeping, 1, h1);
  let h2 = Option.unwrap(hkOf(G2));
  RowStore.put<R.Housekeeping>(hkStore, R.housekeeping, G2, { h2 with outUntil = 0 });
  check(named("I1 capacity"), "402 out with no dates leaves nights above the rooms: named I1");
  RowStore.put<R.Housekeeping>(hkStore, R.housekeeping, G2, h2);
  let r2 = Option.unwrap(St.room(s, G2));
  RowStore.put<R.Room>(s.rooms, R.room, G2, { r2 with status = #active });
  check(named("I10 housekeeping"), "dates out of order on a room in service are named I10");
  RowStore.put<R.Room>(s.rooms, R.room, G2, r2);
  check(List.size(walk().violations) == 0, "every housekeeping control was removed");

  Debug.print("count: housekeeping refusals that left the state untouched = " # Nat.toText(untouched));
  Debug.print("count: housekeeping controls that went red for their own rule = 3");
};

// ── the bill: extras, payers, invoices ───────────────────────────────────────
//
// A guest in house is charged from the catalogue (a set price, an open amount, an untaxed item),
// with the hotel's percentage tax rounded half-even once; a charge is voided only by a second person;
// a company is added as a payer and the restaurant bill moved to it, while the paid room stays where
// it was paid; each pays their own share at the desk; each bill is invoiced under the next number and
// closed by it. Every refusal leaves the fingerprint, the log, the arena, the folio, the payments and
// every bill table as they were; the money law holds after every act.

do {
  let CLERK = who(32);   // revenue, from the housekeeping case
  func billTables() : Nat {
    var n = 0;
    for (name in [St.EXTRA_TABLE, St.CHARGE_TABLE, St.PAYER_TABLE, St.LINE_ROUTE_TABLE, St.PAYMENT_ROUTE_TABLE, St.INVOICE_TABLE,
        St.CREDIT_NOTE_TABLE, St.CREDIT_LINE_TABLE, St.DESK_REFUND_TABLE, St.TAX_ETA_TABLE, St.ETA_PROFILE_TABLE].vals()) n += RowStore.size(St.later(later, name));
    n += RowStore.size(s.proposals);
    n
  };
  var untouched = 0;
  func unchanged(caller : Principal, c : Cmd.Command, kind : Text, what : Text) {
    let fp = St.fingerprintHash(s, later);
    let len = DL.length(log);
    let arena = TA.bytesUsed(s.arena);
    let lines = s.nextFolioId; let pays = s.nextPaymentId; let tables = billTables();
    refused(caller, c, kind, what);
    let same = St.fingerprintHash(s, later) == fp and DL.length(log) == len and TA.bytesUsed(s.arena) == arena
      and s.nextFolioId == lines and s.nextPaymentId == pays and billTables() == tables;
    check(same, what # ": the refusal moved state");
    if (same) untouched += 1;
  };
  func extra(code : Text, cat : E.ExtraCategory, price : Nat, taxed : Bool) : Cmd.Command { extraBy(OWNER, code, cat, price, taxed) };
  func extraBy(staff : Principal, code : Text, cat : E.ExtraCategory, price : Nat, taxed : Bool) : Cmd.Command {
    #upsertExtra({ staff; id = 0; facts = { code; nameEn = code; nameAr = code; category = cat; price; taxed; active = true } })
  };
  // the catalogue
  unchanged(CLERK, extraBy(CLERK, "WATER", #minibar, 300, true), "notAuthorised", "a revenue clerk adding an extra");
  unchanged(OWNER, extra("", #minibar, 300, true), "invalid", "an extra with no code");
  let WATER = ok(OWNER, extra("WATER", #minibar, 300, true), "minibar water at 3.00, taxed")[0];
  let DINNER = ok(OWNER, extra("DINNER", #restaurant, 0, true), "the restaurant, its amount entered when posted")[0];
  let PARKING = ok(OWNER, extra("PARKING", #parking, 1_500, false), "parking at 15.00 a night, untaxed")[0];
  let OLD = ok(OWNER, #upsertExtra({ staff = OWNER; id = 0; facts = { code = "FAX"; nameEn = "Fax"; nameAr = "فاكس"; category = #other; price = 100; taxed = false; active = false } }), "an extra no longer sold")[0];
  unchanged(OWNER, extra("WATER", #minibar, 400, true), "codeTaken", "a second extra with the same code");

  // a guest in house: two nights in the villa on the saver rate, paid in full at booking
  let G = who(50);
  let hid = switch (hold(G, stay(2, 2, today(), 2, 1), 50)) { case (#ok id) id; case (#err e) { check(false, "the bill guest's hold: " # e); 0 } };
  let total = switch (St.hold(s, hid)) { case (?h) h.quotedTotal; case null 0 };
  let made = ok(G, #confirmHold({ owner = G; holdId = hid; guestName = "Layla Haddad"; guestEmail = "lxe1.bill"; note = ""; manageKey = key(50); account = null;
    auth = { authId = 50; amount = total; currency = "EUR"; merchantRef = hid } }), "confirm the bill guest's stay");
  let B = made[0];
  ignore ok(G, #recordGatewayOutcome({ paymentId = made[1]; ok = true }), "the stay is captured");
  unchanged(OWNER, #postCharge({ staff = OWNER; bookingId = B; extraId = WATER; quantity = 1; amount = 0; payerId = 0 }), "bookingState", "a charge before the guest arrives");
  ignore ok(OWNER, #checkIn({ staff = OWNER; bookingId = B; roomIds = [3] }), "the bill guest checks in to the villa");
  func bk() : R.Booking { Option.unwrap(St.booking(s, B)) };
  func post(extraId : Nat, quantity : Nat, amount : Nat, payerId : Nat) : Cmd.Command { #postCharge({ staff = OWNER; bookingId = B; extraId; quantity; amount; payerId }) };
  func line(id : Nat) : R.FolioLine { Option.unwrap(St.folioLine(s, id)) };

  // charges
  let before = bk();
  let water = ok(OWNER, post(WATER, 2, 0, 0), "two bottles of water");
  check(water[1] == 660 and line(water[0]).amount == 600 and line(water[0]).kind == #extra and line(water[0] + 1).kind == #extraTax and line(water[0] + 1).amount == 60,
    "2 × 3.00 is 6.00, with 10% tax of 0.60 on its own line, got " # debug_show water);
  check(bk().charged == before.charged + 660 and bk().outstanding == before.outstanding + 660, "the water is on the guest's bill");
  law("after a charge");
  // the tax on an open amount, rounded half-even once: 10.05 → 1.005 → 1.00; 10.15 → 1.015 → 1.02
  let d1 = ok(OWNER, post(DINNER, 1, 1_005, 0), "a dinner of 10.05");
  check(line(d1[0] + 1).amount == 100, "10% of 10.05 is 1.005, half-even 1.00, got " # Nat.toText(line(d1[0] + 1).amount));
  let d2 = ok(OWNER, post(DINNER, 1, 1_015, 0), "a dinner of 10.15");
  check(line(d2[0] + 1).amount == 102, "10% of 10.15 is 1.015, half-even 1.02, got " # Nat.toText(line(d2[0] + 1).amount));
  let dinner = ok(OWNER, post(DINNER, 1, 4_550, 0), "dinner for two, 45.50");
  let parking = ok(OWNER, post(PARKING, 3, 0, 0), "three nights of parking");
  check(parking[1] == 4_500 and Option.unwrap(St.charge(later, parking[0])).taxLines == 0, "parking is untaxed: 3 × 15.00 and no tax line");
  unchanged(OWNER, post(DINNER, 1, 0, 0), "invalid", "an open-priced charge with no amount");
  unchanged(OWNER, post(WATER, 1, 999, 0), "invalid", "a set-price extra at another price");
  unchanged(OWNER, post(WATER, 0, 0, 0), "invalid", "a quantity of zero");
  unchanged(OWNER, post(WATER, 100, 0, 0), "invalid", "a quantity of 100");
  unchanged(OWNER, post(OLD, 1, 0, 0), "inactive", "an extra no longer sold");
  unchanged(OWNER, post(999, 1, 0, 0), "noSuchExtra", "an extra that does not exist");
  unchanged(OWNER, post(WATER, 1, 0, 99), "noSuchPayer", "a payer who is not on the booking");
  unchanged(CLERK, #postCharge({ staff = CLERK; bookingId = B; extraId = WATER; quantity = 1; amount = 0; payerId = 0 }), "notAuthorised", "a revenue clerk posting a charge");
  law("after every charge");

  // a void needs a second person, and credits the charge with its taxes
  let pv = ok(OWNER, #propose({ staff = OWNER; act = #voidCharge({ bookingId = B; lineId = d1[0] }); justification = "posted to the wrong room" }), "propose voiding the 10.05 dinner")[0];
  unchanged(OWNER, #approve({ staff = OWNER; proposalId = pv }), "fourEyes", "the maker approving their own void");
  let credited = bk().credited;
  ignore ok(OWNER2, #approve({ staff = OWNER2; proposalId = pv }), "a second owner approves the void");
  let ch1 = Option.unwrap(St.charge(later, d1[0]));
  check(ch1.voidLine > 0 and line(ch1.voidLine).kind == #credit and line(ch1.voidLine).amount == 1_105 and bk().credited == credited + 1_105, "the void credits 10.05 and its 1.00 tax");
  unchanged(OWNER, #propose({ staff = OWNER; act = #voidCharge({ bookingId = B; lineId = d1[0] }); justification = "again" }), "invalid", "voiding a charge twice");
  unchanged(OWNER, #propose({ staff = OWNER; act = #voidCharge({ bookingId = B; lineId = water[0] + 1 }); justification = "the tax alone" }), "noSuchCharge", "voiding a tax line alone");
  law("after the void");

  // a company pays the restaurant; the paid room stays where it was paid
  unchanged(OWNER, #addPayer({ staff = OWNER; bookingId = B; name = "" }), "invalid", "a payer with no name");
  unchanged(OWNER, #addPayer({ staff = OWNER; bookingId = B; name = Text.join(Array.tabulate<Text>(81, func(_) { "x" }).vals(), "") }), "tooLong", "a payer name of 81 bytes");
  let ACME = ok(OWNER, #addPayer({ staff = OWNER; bookingId = B; name = "Acme Travel" }), "Acme Travel pays part of the bill")[0];
  var roomLine = 0;
  for ((id, l) in St.folioOf(s, B).vals()) { if (roomLine == 0 and l.kind == #roomNight) roomLine := id };
  func route(ids : [Nat], payerId : Nat) : Cmd.Command { #routeLines({ staff = OWNER; bookingId = B; lineIds = ids; payerId }) };
  unchanged(OWNER, route([roomLine], ACME), "invalid", "moving a room night the guest has already paid");
  unchanged(OWNER, route([dinner[0] + 1], ACME), "invalid", "moving a tax without its extra");
  unchanged(OWNER, route([dinner[0], dinner[0]], ACME), "invalid", "a line listed twice");
  unchanged(OWNER, route([dinner[0]], 0), "invalid", "a line moved to the bill it is on");
  unchanged(OWNER, route([1], ACME), "invalid", "a line of another booking");
  ignore ok(OWNER, route([dinner[0]], ACME), "the dinner moves to Acme");
  check(St.lineWindow(later, dinner[0]) == ACME and St.lineWindow(later, dinner[0] + 1) == ACME, "the dinner's tax moved with it");
  let wins = Win.all(s, later, B);
  check(wins.size() == 2 and Win.open(wins[1]) == 5_005 and wins[1].taxes == 455, "Acme owes 45.50 and its 4.55 tax");
  let water0 = water[1] + d2[1] + parking[1];
  check(Win.open(wins[0]) == water0, "the guest owes the water, the second dinner and the parking, got " # Nat.toText(Win.open(wins[0])));
  law("after the move");

  // each pays their share at the desk
  func share(payerId : Nat, authId : Nat, amount : Nat) : Cmd.Command {
    #settleShare({ staff = OWNER; bookingId = B; payerId; auth = { authId; amount; currency = "EUR"; merchantRef = St.BOOKING_REF_BASE + B } })
  };
  unchanged(OWNER, share(ACME, 51, 5_000), "payment", "Acme's card for less than its share");
  unchanged(OWNER, #settleAtDesk({ staff = OWNER; bookingId = B; auth = { authId = 54; amount = water0 + 5_005; currency = "EUR"; merchantRef = St.BOOKING_REF_BASE + B } }),
    "payment", "the guest's card for Acme's share as well");
  unchanged(OWNER, share(0, 51, water0), "invalid", "the guest's share taken as a payer's");
  let sh = ok(OWNER, share(ACME, 51, 5_005), "Acme pays 50.05");
  ignore ok(OWNER, #recordGatewayOutcome({ paymentId = sh[1]; ok = true }), "Acme's capture lands");
  check(St.paymentWindow(later, sh[1]) == ACME and Win.open(Win.all(s, later, B)[1]) == 0, "Acme's payment is on Acme's bill, which is paid");
  unchanged(OWNER, share(ACME, 52, 5_005), "invalid", "a paid bill paid again");

  unchanged(OWNER, #checkOut({ staff = OWNER; bookingId = B }), "balanceOutstanding", "check-out while the guest's share is open");
  let gs = ok(OWNER, #settleAtDesk({ staff = OWNER; bookingId = B; auth = { authId = 53; amount = water0; currency = "EUR"; merchantRef = St.BOOKING_REF_BASE + B } }), "the guest pays their share");
  ignore ok(OWNER, #recordGatewayOutcome({ paymentId = gs[1]; ok = true }), "the guest's capture lands");
  check(bk().outstanding == 0, "nothing is outstanding");
  law("after both shares");
  // after the guest's card (53) is the last captured, so a refund that went through the wrong card would show
  // Acme's dinner, paid, voided by two people: the credit is on Acme's bill and the money goes back
  // through Acme's card; the guest's bill does not move
  let guestBefore = Win.all(s, later, B)[0];
  let pa = ok(OWNER, #propose({ staff = OWNER; act = #voidCharge({ bookingId = B; lineId = dinner[0] }); justification = "Acme's dinner was a guest's" }), "propose voiding Acme's paid dinner")[0];
  let paysBefore = s.nextPaymentId;
  ignore ok(OWNER2, #approve({ staff = OWNER2; proposalId = pa }), "the void of Acme's dinner is approved");
  let chD = Option.unwrap(St.charge(later, dinner[0]));
  check(St.lineWindow(later, chD.voidLine) == ACME and line(chD.voidLine).amount == 5_005, "the void's credit is on Acme's bill");
  check(s.nextPaymentId == paysBefore + 1, "the void wrote one payment");
  let refund = Option.unwrap(St.payment(s, paysBefore));
  check(refund.kind == #refunded and refund.amount == 5_005 and refund.gatewayAuth == 51 and St.paymentWindow(later, paysBefore) == ACME,
    "the refund goes back through Acme's card (51), on Acme's bill, got " # debug_show (refund.kind, refund.amount, refund.gatewayAuth, St.paymentWindow(later, paysBefore)));
  let guestAfter = Win.all(s, later, B)[0];
  check(guestAfter.paid == guestBefore.paid and guestAfter.charges == guestBefore.charges and guestAfter.due == guestBefore.due, "the guest's bill did not move");
  law("after Acme's refund");

  // invoices: one per bill, numbered on, each closing its bill
  let inv0 = ok(OWNER, #issueInvoice({ staff = OWNER; bookingId = B; payerId = 0 }), "the guest's invoice")[0];
  let inv1 = ok(OWNER, #issueInvoice({ staff = OWNER; bookingId = B; payerId = ACME }), "Acme's invoice")[0];
  check(inv1 == inv0 + 1 and inv0 == 1, "invoices 1 and 2");
  let i1 = Option.unwrap(St.invoice(later, inv1));
  check(i1.charges == 5_005 and i1.taxes == 455 and i1.credits == 5_005 and i1.paid == 0, "Acme's invoice is 45.50 with 4.55 tax, voided and refunded");
  unchanged(OWNER, #issueInvoice({ staff = OWNER; bookingId = B; payerId = ACME }), "invalid", "a bill invoiced twice");
  unchanged(OWNER, post(WATER, 1, 0, ACME), "invoiced", "a charge on an invoiced bill");
  unchanged(OWNER, post(WATER, 1, 0, 0), "invoiced", "a charge on the guest's invoiced bill");
  unchanged(OWNER, route([water[0]], ACME), "invoiced", "a line moved out of an invoiced bill");
  unchanged(OWNER, #propose({ staff = OWNER; act = #voidCharge({ bookingId = B; lineId = water[0] }); justification = "late" }), "invoiced", "voiding a charge on an invoiced bill");
  unchanged(OWNER, #addPayer({ staff = OWNER; bookingId = 1; name = "Late" }), "bookingState", "a payer on a cancelled booking");
  ignore ok(OWNER, #checkOut({ staff = OWNER; bookingId = B }), "the bill guest checks out");
  law("after check-out");

  // the books: nothing wrong, and each bill fault named by its own rule
  let w = walk();
  check(List.size(w.violations) == 0, "the oracle is empty after the bill: " # debug_show List.toArray(w.violations));
  func named(rule : Text) : Bool { for (v in List.values(walk().violations)) { if (Text.startsWith(v, #text rule)) return true }; false };
  let chTable = St.later(later, St.CHARGE_TABLE);
  let chW = Option.unwrap(St.charge(later, water[0]));
  RowStore.put<R.Charge>(chTable, R.charge, water[0], { chW with unitAmount = 301 });
  check(named("I11 bill"), "a charge whose line is not its quantity times its price is named I11");
  RowStore.put<R.Charge>(chTable, R.charge, water[0], chW);
  let invTable = St.later(later, St.INVOICE_TABLE);
  RowStore.put<R.Invoice>(invTable, R.invoice, inv1, { i1 with charges = 5_006 });
  check(named("I11 bill"), "an invoice whose figures are not its bill's is named I11");
  RowStore.put<R.Invoice>(invTable, R.invoice, inv1, i1);
  // a row changed beside the fold is put back exactly as it was (a store keeps every row it was given)
  let rtTable = St.later(later, St.PAYMENT_ROUTE_TABLE);
  let acmeRoute = Option.unwrap(RowStore.get<R.Route>(rtTable, R.paymentRoute, sh[1]));
  RowStore.put<R.Route>(rtTable, R.paymentRoute, sh[1], { acmeRoute with payerId = 0 });
  check(named("I11 bill"), "Acme's payment moved onto the guest's bill leaves the guest's paid twice: named I11");
  RowStore.put<R.Route>(rtTable, R.paymentRoute, sh[1], acmeRoute);
  check(List.size(walk().violations) == 0, "every bill control was removed");

  // ── credit notes ──
  //
  // The guest's invoice is amended only by a credit note: proposed by one person, approved by another,
  // numbered 1, 2 with no gap, its lines credits on the invoiced bill, the invoice row as issued. Each
  // note's refund goes back through the guest's own card; the gateway refuses the second, which the
  // desk then pays by transfer under the same four eyes, and the note still stands. Each note is then
  // read as the tax authority's credit note.
  let NOBODY = who(99);
  let i0 = Option.unwrap(St.invoice(later, inv0));
  func cnote(staff : Principal, invoice : Nat, lineIds : [Nat], amounts : [Nat]) : Cmd.Command {
    #propose({ staff; act = #issueCreditNote({ bookingId = B; invoice; lineIds; amounts }); justification = "the guest was overcharged" })
  };
  func desk(staff : Principal, bookingId : Nat, paymentId : Nat, method : E.DeskMethod, reference : Text) : Cmd.Command {
    #propose({ staff; act = #refundAtDesk({ bookingId; paymentId; method; reference }); justification = "the card was closed" })
  };
  check(RowStore.size(St.later(later, St.CREDIT_NOTE_TABLE)) == 0, "no credit note yet");
  unchanged(OWNER, cnote(OWNER, 99, [water[0]], [100]), "noSuchInvoice", "a credit note against an invoice that does not exist");
  unchanged(OWNER, #propose({ staff = OWNER; act = #issueCreditNote({ bookingId = 1; invoice = inv0; lineIds = [water[0]]; amounts = [100] }); justification = "x" }),
    "noSuchInvoice", "a credit note against another booking's invoice");
  unchanged(OWNER, cnote(OWNER, inv1, [water[0]], [100]), "otherBill", "a credit note naming a line of another bill");
  unchanged(OWNER, cnote(OWNER, inv0, [d1[0]], [100]), "invalid", "a credit note taking back a voided charge");
  unchanged(OWNER, cnote(OWNER, inv0, [water[0] + 1], [10]), "invalid", "a credit note taking back a tax alone");
  unchanged(OWNER, cnote(OWNER, inv0, [ch1.voidLine], [10]), "invalid", "a credit note taking back a credit");
  unchanged(OWNER, cnote(OWNER, inv0, [water[0]], [0]), "invalid", "a credit note taking back nothing of a line");
  unchanged(OWNER, cnote(OWNER, inv0, [water[0], water[0]], [100, 100]), "invalid", "a credit note naming a line twice");
  unchanged(OWNER, cnote(OWNER, inv0, [water[0]], [601]), "creditBeyondLine", "a credit note taking back more than the line");
  unchanged(OWNER, cnote(OWNER, inv0, [], []), "invalid", "a credit note with no lines");
  unchanged(OWNER, cnote(OWNER, inv0, [water[0], d2[0]], [100]), "invalid", "a credit note with a line and no amount for it");
  unchanged(NOBODY, cnote(NOBODY, inv0, [water[0]], [100]), "notAuthorised", "a credit note proposed by someone who is not staff");

  // note 1: one of the two bottles, and half the tax with it
  let p1 = ok(OWNER, cnote(OWNER, inv0, [water[0]], [300]), "propose taking back one bottle of water")[0];
  unchanged(OWNER, #approve({ staff = OWNER; proposalId = p1 }), "fourEyes", "the maker approving their own credit note");
  unchanged(CLERK, #approve({ staff = CLERK; proposalId = p1 }), "notAuthorised", "a revenue clerk approving a credit note");
  let first1 = s.nextFolioId;
  let credited0 = bk().credited;
  let pays1 = s.nextPaymentId;
  let n1 = ok(OWNER2, #approve({ staff = OWNER2; proposalId = p1 }), "a second owner approves credit note 1");
  check(n1 == [1, 330], "credit note 1 takes back 3.00 and half the 0.60 tax, 3.30, got " # debug_show n1);
  let cn1 = Option.unwrap(St.creditNote(later, 1));
  check(cn1.invoice == inv0 and cn1.bookingId == B and cn1.payerId == 0 and cn1.net == 300 and cn1.taxes == 30 and cn1.total == 330
    and cn1.firstLine == first1 and cn1.lines == 2 and cn1.proposal == p1, "credit note 1's row, got " # debug_show cn1);
  check(line(first1).kind == #credit and line(first1).code == CN.CREDIT_NOTE_CODE and line(first1).amount == 300 and line(first1 + 1).amount == 30
    and St.lineWindow(later, first1) == 0 and St.lineWindow(later, first1 + 1) == 0, "its two credit lines are on the guest's invoiced bill");
  check(Option.map<R.CreditLine, (Nat, Nat)>(St.creditLine(later, first1), func(x) { (x.note, x.source) }) == ?(1, water[0])
    and Option.map<R.CreditLine, (Nat, Nat)>(St.creditLine(later, first1 + 1), func(x) { (x.note, x.source) }) == ?(1, water[0] + 1),
    "each credit line names its note and the line it takes back");
  check(St.invoice(later, inv0) == ?i0, "the invoice row is as it was issued");
  check(bk().credited == credited0 + 330 and Win.all(s, later, B)[0].credits == i0.credits + 330, "the bill's credits are the invoice's and the note's");
  check(s.nextPaymentId == pays1 + 1, "the note wrote one refund");
  let r1 = Option.unwrap(St.payment(s, pays1));
  check(r1.kind == #refunded and r1.amount == 330 and r1.state == #due and r1.gatewayAuth == 53 and St.paymentWindow(later, pays1) == 0,
    "the refund goes back through the guest's own card (53), got " # debug_show (r1.kind, r1.amount, r1.state, r1.gatewayAuth));
  ignore ok(G, #recordGatewayOutcome({ paymentId = pays1; ok = true }), "credit note 1's refund lands");
  law("after credit note 1");

  // note 2, proposed by a revenue clerk: the other bottle, the second dinner, and a whole night with its
  // two taxes; a line taken back whole takes back its taxes whole
  let rn = line(roomLine);
  let rnTaxes = CN.taxLinesOf(ctx(), roomLine, rn);
  var rnTax = 0;
  for ((_, t) in rnTaxes.vals()) rnTax += t.amount;
  check(rnTaxes.size() == 2, "a night has its VAT and its tourist tax, got " # Nat.toText(rnTaxes.size()));
  let p2 = ok(CLERK, cnote(CLERK, inv0, [water[0], d2[0], roomLine], [300, 1_015, rn.amount]), "a revenue clerk proposes the rest of the water, the second dinner and a night")[0];
  let pays2 = s.nextPaymentId;
  let n2 = ok(OWNER2, #approve({ staff = OWNER2; proposalId = p2 }), "a second owner approves credit note 2");
  let total2 = 300 + 30 + 1_015 + 102 + rn.amount + rnTax;
  check(n2 == [2, total2], "credit note 2 is numbered 2 and totals " # Nat.toText(total2) # ", got " # debug_show n2);
  let cn2 = Option.unwrap(St.creditNote(later, 2));
  check(cn2.lines == 7 and cn2.net == 300 + 1_015 + rn.amount and cn2.taxes == 30 + 102 + rnTax, "credit note 2's seven lines, got " # debug_show cn2);
  check(St.creditedOf(s, later, water[0]) == 600 and St.creditedOf(s, later, water[0] + 1) == 60, "the water and its tax are taken back whole across the two notes");
  for ((t, tl) in rnTaxes.vals()) check(St.creditedOf(s, later, t) == tl.amount, "the night's tax on line " # Nat.toText(t) # " is taken back whole");
  check(St.invoice(later, inv0) == ?i0, "the invoice row is as it was issued, after two notes");
  check(Win.all(s, later, B)[0].credits == i0.credits + 330 + total2, "the bill's credits are the invoice's and both notes'");
  check(Array.map<(Nat, R.CreditNote), Nat>(St.notesOf(later, inv0), func((n, _)) { n }) == [1, 2], "the invoice's notes are 1 and 2");
  unchanged(OWNER, cnote(OWNER, inv0, [water[0]], [1]), "creditBeyondLine", "a line taken back whole, taken back again");
  law("after credit note 2");

  // note 2's refund is more than the guest's newest card (53) has left: it goes back across the guest's
  // own cards, newest first, each drawn to nothing before an older one is drawn at all
  let slices2 = Array.tabulate<(Nat, R.Payment)>(s.nextPaymentId - pays2 : Nat, func(i) { (pays2 + i, Option.unwrap(St.payment(s, pays2 + i))) });
  check(slices2.size() >= 2, "note 2's refund is split across the guest's cards, got " # Nat.toText(slices2.size()) # " slice(s)");
  var sum2 = 0;
  for ((id, q) in slices2.vals()) {
    sum2 += q.amount;
    check(q.kind == #refunded and q.state == #due and St.paymentWindow(later, id) == 0 and q.gatewayAuth != 0, "slice " # Nat.toText(id) # " is a refund due to a guest's card");
    check(St.refundSlice(later, id) == ?{ firstSlice = pays2; excess = total2; written = DL.length(log) - 1 }, "slice " # Nat.toText(id) # " records its settle");
  };
  check(sum2 == total2, "the slices sum to the note, got " # Nat.toText(sum2) # " of " # Nat.toText(total2));
  check(slices2[0].1.gatewayAuth == 53 and slices2[0].1.amount == water0 - 330, "the newest card (53) gives back all it has left, " # Nat.toText(water0 - 330 : Nat));
  for (i in Nat.range(1, slices2.size())) check(slices2[i].1.gatewayAuth != 53 and slices2[i].1.gatewayAuth != slices2[i - 1].1.gatewayAuth, "each slice is on a card of its own");
  // every slice but the last lands; the gateway refuses the last, and the desk pays that slice only
  for (i in Nat.range(0, slices2.size() - 1 : Nat)) ignore ok(G, #recordGatewayOutcome({ paymentId = slices2[i].0; ok = true }), "slice " # Nat.toText(slices2[i].0) # " lands");
  let failedSlice = slices2[slices2.size() - 1 : Nat].0;
  unchanged(OWNER, desk(OWNER, B, failedSlice, #cash, "R-1001"), "invalid", "a refund the gateway may still make, paid at the desk");
  for (_ in Nat.range(0, 3)) ignore ok(G, #recordGatewayOutcome({ paymentId = failedSlice; ok = false }), "the gateway refuses the last slice");
  check(Option.unwrap(St.payment(s, failedSlice)).state == #failed, "after three refusals that slice has failed");
  for (i in Nat.range(0, slices2.size() - 1 : Nat)) check(Option.unwrap(St.payment(s, slices2[i].0)).state == #done, "the other slices are done");
  check(St.creditNote(later, 2) == ?cn2 and Win.all(s, later, B)[0].credits == i0.credits + 330 + total2, "the credit note stands");
  law("after the gateway refused one slice");
  unchanged(OWNER, desk(OWNER, B, pays1, #cash, "R-1001"), "invalid", "a refund the gateway made, paid at the desk");
  unchanged(OWNER, desk(OWNER, B, 9_999, #cash, "R-1001"), "noSuchPayment", "a refund that does not exist, paid at the desk");
  unchanged(OWNER, desk(OWNER, 1, failedSlice, #cash, "R-1001"), "noSuchPayment", "another booking's refund, paid at the desk");
  unchanged(OWNER, desk(OWNER, B, failedSlice, #cash, ""), "invalid", "a desk refund with no reference");
  unchanged(OWNER, desk(OWNER, B, failedSlice, #cash, Text.join(Array.tabulate<Text>(65, func(_) { "x" }).vals(), "")), "tooLong", "a desk refund reference of 65 bytes");
  unchanged(NOBODY, desk(NOBODY, B, failedSlice, #cash, "R-1001"), "notAuthorised", "a desk refund proposed by someone who is not staff");
  let pd = ok(OWNER, desk(OWNER, B, failedSlice, #transfer, "TRF-2026-11-0042"), "propose paying the refund by transfer")[0];
  unchanged(OWNER, #approve({ staff = OWNER; proposalId = pd }), "fourEyes", "the maker approving their own desk refund");
  let paidBefore = s.paidTotal;
  let refundsBefore = s.refundsCommitted;
  ignore ok(OWNER2, #approve({ staff = OWNER2; proposalId = pd }), "a second owner approves the desk refund");
  let dr = Option.unwrap(St.deskRefund(later, failedSlice));
  check(dr.bookingId == B and dr.method == #transfer and TA.get(s.arena, dr.reference) == "TRF-2026-11-0042" and dr.proposal == pd and dr.day == today(),
    "the desk refund's row names the refund, the transfer and its approval");
  check(s.paidTotal == paidBefore and s.refundsCommitted == refundsBefore, "the desk moves no cash counter: the refund was committed when it was written");
  unchanged(OWNER, desk(OWNER, B, failedSlice, #cash, "again"), "invalid", "a refund paid at the desk twice");
  law("after the desk refund");

  // the tax authority's credit note
  let VAT_RULE = line(water[0] + 1).code;
  let e0 = Option.unwrap(Eta.creditNote(ctx(), 1));
  func says(missing : [Text], fragment : Text) : Bool { for (m in missing.vals()) { if (Text.contains(m, #text fragment)) return true }; false };
  check(says(e0.missing, "registration with the authority") and e0.doc.issuer.id == "", "before the registration, the document names it as missing and leaves the issuer's id empty");
  unchanged(CLERK, #setTaxEta({ staff = CLERK; taxRuleId = VAT_RULE; taxType = "T1"; subType = "V009" }), "notAuthorised", "a revenue clerk setting a tax's codes");
  unchanged(OWNER, #setTaxEta({ staff = OWNER; taxRuleId = 99; taxType = "T1"; subType = "V009" }), "noSuchTaxRule", "codes for a tax that does not exist");
  unchanged(OWNER, #setTaxEta({ staff = OWNER; taxRuleId = VAT_RULE; taxType = "T 1"; subType = "V009" }), "invalid", "a tax type with a space");
  unchanged(OWNER, #setTaxEta({ staff = OWNER; taxRuleId = VAT_RULE; taxType = "T1"; subType = "" }), "invalid", "a tax with no sub-type");
  ignore ok(OWNER, #setTaxEta({ staff = OWNER; taxRuleId = VAT_RULE; taxType = "T1"; subType = "V009" }), "VAT is the authority's T1, V009");
  let prof : Cmd.EtaProfileFacts = { issuerId = "100324932"; activityCode = "5510"; branchId = "0"; country = "EG"; governate = "Luxor"; regionCity = "East Bank";
    street = "Corniche El Nil"; buildingNumber = "12" };
  func profile(staff : Principal, f : Cmd.EtaProfileFacts) : Cmd.Command { #setEtaProfile({ staff; facts = f }) };
  unchanged(CLERK, profile(CLERK, prof), "notAuthorised", "a revenue clerk setting the registration");
  unchanged(OWNER, profile(OWNER, { prof with issuerId = "" }), "invalid", "a registration with no number");
  unchanged(OWNER, profile(OWNER, { prof with activityCode = "55a0" }), "invalid", "an activity code that is not four digits");
  unchanged(OWNER, profile(OWNER, { prof with country = "eg" }), "invalid", "a country in lower case");
  unchanged(OWNER, profile(OWNER, { prof with street = "" }), "invalid", "an address with no street");
  ignore ok(OWNER, profile(OWNER, prof), "the hotel's registration with the authority");
  let e1 = Option.unwrap(Eta.creditNote(ctx(), 1));
  let doc1 = e1.doc;
  check(doc1.documentType == "C" and doc1.documentTypeVersion == "1.0" and doc1.internalId == "CN-1" and doc1.references == ["INV-" # Nat.toText(inv0)]
    and doc1.issueDay == cn1.issuedDay and doc1.currency == "EUR" and doc1.exponent == 2, "note 1 is a credit note (C, 1.0), CN-1, referring to its invoice");
  check(doc1.issuer.partyType == "B" and doc1.issuer.id == "100324932" and doc1.issuer.address.branchId == "0" and doc1.issuer.address.country == "EG"
    and doc1.issuer.address.governate == "Luxor" and doc1.issuer.address.street == "Corniche El Nil" and doc1.activityCode == "5510", "the issuer is the hotel as registered");
  check(doc1.receiver.partyType == "P" and doc1.receiver.name == "Layla Haddad", "the receiver is the guest, a person");
  check(doc1.lines.size() == 1 and doc1.lines[0].salesTotal == 300 and doc1.lines[0].unitPrice == 300 and doc1.lines[0].quantity == 1_000
    and doc1.lines[0].internalCode == "EXTRA-WATER" and doc1.lines[0].taxes == [{ taxType = "T1"; subType = "V009"; rate = 100_000; amount = 30 }],
    "note 1's line: the water, 3.00, with its VAT as T1/V009 at 10%, got " # debug_show doc1.lines);
  check(Eta.totals(doc1) == { sales = 300; tax = 30 } and Eta.taxTotals(doc1) == [("T1", 30)], "the document's totals are the note's");
  check(not says(e1.missing, "registration with the authority") and says(e1.missing, "EGS item code") and says(e1.missing, "identifier of invoice INV-" # Nat.toText(inv0))
    and not says(e1.missing, "national id"), "with the registration given, what is still missing is the item codes and the invoice's identifier, got " # debug_show e1.missing);
  let json1 = Eta.json(doc1);
  check(Text.contains(json1, #text "\"documentType\":\"C\"") and Text.contains(json1, #text "\"rate\":10.0000") and Text.contains(json1, #text "\"references\":[\"INV-1\"]")
    and Text.contains(json1, #text "\"totalAmount\":3.30"), "the JSON carries the type, the rate as written, the reference and the total, got " # json1);
  check(Text.startsWith(Eta.serialize(Eta.tree(doc1)), #text "\"ISSUER\"\"ADDRESS\"\"BRANCHID\"\"0\"\"COUNTRY\"\"EG\""), "the authority's serialisation: names upper-cased, values as written");
  check(Eta.digest(doc1).size() == 32, "the digest is a SHA-256");
  let e2 = Option.unwrap(Eta.creditNote(ctx(), 2));
  let night = e2.doc.lines[2];
  check(e2.doc.lines.size() == 3 and e2.doc.lines[0].taxes.size() == 1 and e2.doc.lines[1].taxes.size() == 1 and night.taxes.size() == 2
    and night.salesTotal == rn.amount and night.taxes[0].taxType == "T1" and night.taxes[1].rate == 0 and night.taxes[1].taxType == ""
    and Text.startsWith(night.internalCode, #text "ROOM-"), "note 2: the water, the dinner, and the night with its VAT and its fixed tourist tax, got " # debug_show e2.doc.lines);
  check(Eta.totals(e2.doc).sales + Eta.totals(e2.doc).tax == total2, "note 2's document totals the note");
  check(says(e2.missing, "tax TOURIST") and not says(e2.missing, "tax IVA"), "the tourist tax's codes are named as missing, VAT's are not");
  check(Eta.creditNote(ctx(), 3) == null, "there is no note 3");
  check(Eta.dec(-50, 2) == "-0.50" and Eta.dec(5, 2) == "0.05" and Eta.dec(140_000, 4) == "14.0000", "the amounts keep their sign and their places");

  // the books: nothing wrong, and each credit-note fault named by its own rule and detail
  let wc = walk();
  check(List.size(wc.violations) == 0, "the oracle is empty after the credit notes: " # debug_show List.toArray(wc.violations));
  func namedWith(fragment : Text) : Bool {
    for (v in List.values(walk().violations)) { if (Text.startsWith(v, #text "I11 bill") and Text.contains(v, #text fragment)) return true };
    false
  };
  var cnControls = 0;
  func control(caught : Bool, what : Text) { check(caught, what); if (caught) cnControls += 1 };
  let cnTable = St.later(later, St.CREDIT_NOTE_TABLE);
  RowStore.put<R.CreditNote>(cnTable, R.creditNote, 2, { cn2 with total = cn2.total + 1 });
  control(namedWith("credit note 2 totals"), "a note whose total is not its net and its taxes is named I11");
  RowStore.put<R.CreditNote>(cnTable, R.creditNote, 2, { cn2 with net = cn2.net + 1; total = cn2.total + 1 });
  control(namedWith("and its lines are"), "a note whose figures are not its lines' is named I11");
  RowStore.put<R.CreditNote>(cnTable, R.creditNote, 2, cn2);
  RowStore.put<R.Invoice>(invTable, R.invoice, inv0, { i0 with credits = i0.credits + 1 });
  control(namedWith("in credit notes, and its bill is now"), "an invoice whose credits and notes are not its bill's credits is named I11");
  RowStore.put<R.Invoice>(invTable, R.invoice, inv0, i0);
  let clTable = St.later(later, St.CREDIT_LINE_TABLE);
  let cl1 = Option.unwrap(St.creditLine(later, first1));
  RowStore.put<R.CreditLine>(clTable, R.creditLine, first1, { cl1 with note = 2 });
  control(namedWith("is not one of its credits"), "a credit line recorded against another note is named I11");
  RowStore.put<R.CreditLine>(clTable, R.creditLine, first1, cl1);
  let wl = line(water[0]);
  RowStore.put<R.FolioLine>(s.folio, R.folioLine, water[0], { wl with amount = 500 });
  control(namedWith("credit notes have taken back"), "a line taken back beyond its amount is named I11");
  RowStore.put<R.FolioLine>(s.folio, R.folioLine, water[0], wl);
  let pr2 = Option.unwrap(St.proposal(s, p2));
  RowStore.put<R.Proposal>(s.proposals, R.proposal, p2, { pr2 with checker = ?pr2.maker });
  control(namedWith("credit note 2 was not approved by a second person"), "a note approved by its own maker is named I11");
  RowStore.put<R.Proposal>(s.proposals, R.proposal, p2, pr2);
  let prd = Option.unwrap(St.proposal(s, pd));
  RowStore.put<R.Proposal>(s.proposals, R.proposal, pd, { prd with permission = Option.unwrap(St.proposal(s, p2)).permission });
  control(namedWith("desk refund of payment " # Nat.toText(failedSlice) # " was not approved"), "a desk refund approved under another permission is named I11");
  RowStore.put<R.Proposal>(s.proposals, R.proposal, pd, prd);
  let pm2 = Option.unwrap(St.payment(s, failedSlice));
  RowStore.put<R.Payment>(s.payments, R.payment, failedSlice, { pm2 with state = #done });
  control(namedWith("the gateway would not make"), "a desk refund of a refund the gateway made is named I11");
  RowStore.put<R.Payment>(s.payments, R.payment, failedSlice, pm2);
  // a gap: a note numbered past the notes issued, on a copy rebuilt from the log (a store keeps every row
  // it is given, so the copy is what is spoiled)
  do {
    let rp = Con.replayAll(log);
    RowStore.put<R.CreditNote>(St.later(rp.later, St.CREDIT_NOTE_TABLE), R.creditNote, 4, cn2);
    let rc : St.Ctx = { s = rp.stores; x = rp.later; block = DL.length(log); day = today(); height = heightCell };
    var gap = false;
    var cursor : ?Blob = null;
    label pages loop {
      let r = O.page(rc, 10, cursor, 200);
      for (x in r.violations.vals()) { if (x.rule == "I11 bill" and Text.contains(x.detail, #text "credit note 4 is past the 3")) gap := true };
      switch (r.next) { case (?c) cursor := ?c; case null break pages };
    };
    control(gap, "a note numbered past the notes issued (a gap below it) is named I11");
  };
  check(List.size(walk().violations) == 0, "every credit-note control was removed");
  Debug.print("count: credit-note controls that went red for their own rule = " # Nat.toText(cnControls));
  Debug.print("count: credit notes issued = " # Nat.toText(RowStore.size(cnTable)));

  Debug.print("count: bill refusals that left the state untouched = " # Nat.toText(untouched));
  Debug.print("count: bill controls that went red for their own rule = 3");
};

// ── bookings staff take: by phone, and a guest at the desk ────────────────────

do {
  let T = today();
  let FRONT = who(50);
  let HKP = who(51);
  ignore ok(OWNER, #grantRole({ staff = OWNER; subject = FRONT; role = #frontDesk }), "a receptionist");
  ignore ok(OWNER, #grantRole({ staff = OWNER; subject = HKP; role = #housekeeping }), "a housekeeper");
  // a room type of its own, so this case reads only what it wrote
  ignore ok(OWNER, #upsertRoomType({ staff = OWNER; id = 0; facts = { code = "DESK"; nameEn = "Desk"; nameAr = "مكتب"; descEn = ""; descAr = ""; sizeSqm = 30; maxAdults = 2; maxChildren = 1;
    maxOccupancy = 3; bedKind = #king; bedCount = 1; amenities = 1; photos = "almar/sea-room"; rank = 9; active = true } }), "the desk's room type");
  let DT = s.nextRoomTypeId - 1;
  let r1 = ok(OWNER, #upsertRoom({ staff = OWNER; id = 0; roomTypeId = DT; number = "901"; outOfOrder = false }), "room 901")[0];
  let r2 = ok(OWNER, #upsertRoom({ staff = OWNER; id = 0; roomTypeId = DT; number = "902"; outOfOrder = false }), "room 902")[0];
  let other = 1;   // a sea room: of another type
  ignore ok(OWNER, #setNights({ staff = OWNER; edit = { roomTypeId = DT; fromDay = T; toDay = T + 20; weekdays = 127; allotment = ?2; bar = ?12_000; minStay = null; maxStay = null;
    closedToArrival = null; closedToDeparture = null; stopSell = null } }), "the desk's nights");
  let phoneStay = stay(DT, 1, T + 3, 2, 1);
  let walkStay = stay(DT, 1, T, 1, 1);
  func quoted(st : Cmd.Stay, what : Text) : Q.Quote {
    switch (Res.quoteStay(ctx(), st)) { case (#ok c) c.quote; case (#err r) Runtime.trap(what # " has no quote: " # debug_show r) }
  };
  let phoneQ = quoted(phoneStay, "the phone stay");
  let walkQ = quoted(walkStay, "the walk-in stay");
  func book(by : Principal, ch : E.Channel, st : Cmd.Stay, hash : Blob, name : Text, email : Text, rooms : [Nat]) : Cmd.Command {
    #bookByStaff({ staff = by; channel = ch; stay = st; quoteHash = hash; guestName = name; guestEmail = email; note = "called at 10:12"; manageKey = key(60); roomIds = rooms })
  };
  let sbTable = St.later(later, St.STAFF_BOOKING_TABLE);
  var untouchedSb = 0;
  func unchanged(caller : Principal, c : Cmd.Command, kind : Text, what : Text) {
    let fp = St.fingerprintHash(s, later);
    let len = DL.length(log);
    let arena = TA.bytesUsed(s.arena);
    let next = s.nextBookingId;
    let lines = s.nextFolioId;
    let rows = RowStore.size(sbTable);
    let bookings = RowStore.size(s.bookings);
    refused(caller, c, kind, what);
    let same = St.fingerprintHash(s, later) == fp and DL.length(log) == len and TA.bytesUsed(s.arena) == arena and s.nextBookingId == next
      and s.nextFolioId == lines and RowStore.size(sbTable) == rows and RowStore.size(s.bookings) == bookings;
    check(same, what # ": the refusal moved state");
    if (same) untouchedSb += 1;
  };
  unchanged(GUEST_A, book(GUEST_A, #phone, phoneStay, phoneQ.hash, "Hany", "", []), "notAuthorised", "a guest booking as staff");
  unchanged(HKP, book(HKP, #phone, phoneStay, phoneQ.hash, "Hany", "", []), "notAuthorised", "a housekeeper taking a booking");
  unchanged(FRONT, book(FRONT, #phone, phoneStay, walkQ.hash, "Hany", "", []), "priceChanged", "a booking at a price that is not the stay's");
  unchanged(FRONT, book(FRONT, #phone, phoneStay, phoneQ.hash, "", "", []), "invalid", "a booking with no name");
  unchanged(FRONT, book(FRONT, #phone, phoneStay, phoneQ.hash, "Hany", "hany@example.com", []), "invalid", "an email that arrives unsealed");
  unchanged(FRONT, book(FRONT, #phone, phoneStay, phoneQ.hash, "Hany", "", [r1]), "invalid", "a booking by phone given a room");
  unchanged(FRONT, book(FRONT, #walkIn, phoneStay, phoneQ.hash, "Hany", "", [r1]), "notTheDay", "a walk-in arriving another day");
  unchanged(FRONT, book(FRONT, #walkIn, walkStay, walkQ.hash, "Hany", "", []), "invalid", "a walk-in given no room");
  unchanged(FRONT, book(FRONT, #walkIn, walkStay, walkQ.hash, "Hany", "", [other]), "roomWrongType", "a walk-in given a room of another type");
  unchanged(FRONT, book(FRONT, #walkIn, walkStay, walkQ.hash, "Hany", "", [999]), "noSuchRoom", "a walk-in given a room that does not exist");
  unchanged(FRONT, book(FRONT, #walkIn, stay(DT, 1, T, 1, 2), quoted(stay(DT, 1, T, 1, 2), "two rooms tonight").hash, "Hany", "", [r1, r1]), "invalid", "a walk-in given one room twice");
  unchanged(FRONT, book(FRONT, #phone, stay(DT, 1, T + 40, 2, 1), phoneQ.hash, "Hany", "", []), "nightClosed", "a booking on nights the hotel has not opened");
  unchanged(FRONT, book(FRONT, #phone, { phoneStay with adults = 4 }, phoneQ.hash, "Hany", "", []), "occupancy", "a booking for more guests than the room holds");

  // by phone: the nights are taken at once, no money moves, the whole stay is outstanding
  let soldBefore = Option.unwrap(St.night(s, DT, T + 3)).sold;
  let ph = ok(FRONT, book(FRONT, #phone, phoneStay, phoneQ.hash, "Hany Adel", "lxe1.sealed", []), "a booking by phone");
  let phoneId = ph[0];
  let pb = Option.unwrap(St.booking(s, phoneId));
  check(ph[1] == phoneQ.total and pb.status == #confirmed and pb.holdId == 0 and pb.charged == phoneQ.total and pb.paid == 0 and pb.outstanding == phoneQ.total
    and St.paymentsOf(s, phoneId).size() == 0, "the phone booking is confirmed, owes its whole stay and has no payment");
  check(Option.unwrap(St.night(s, DT, T + 3)).sold == soldBefore + 1 and Option.unwrap(St.night(s, DT, T + 4)).sold == 1, "its nights are sold at once");
  check(St.staffBooking(later, phoneId) == ?{ channel = #phone; madeBy = FRONT; day = T; lastBlock = DL.length(log) - 1 }, "it records the call, who took it and the day");
  check(TA.get(s.arena, pb.guestEmail) == "lxe1.sealed" and pb.manageKey == key(60), "the sealed email and the manage key made in the receptionist's browser");
  // a guest who gave no email
  let noMail = ok(OWNER, book(OWNER, #phone, stay(DT, 1, T + 3, 1, 1), quoted(stay(DT, 1, T + 3, 1, 1), "one night by phone").hash, "Mona", "", []), "a booking with no email")[0];
  check(TA.get(s.arena, Option.unwrap(St.booking(s, noMail)).guestEmail) == "", "the email may be empty");
  unchanged(FRONT, book(FRONT, #phone, stay(DT, 1, T + 3, 1, 1), phoneQ.hash, "Third", "", []), "soldOut", "a third booking for a night of two rooms");

  // a walk-in: checked in to its room in the same act
  let wk = ok(FRONT, book(FRONT, #walkIn, walkStay, walkQ.hash, "Karim Saleh", "", [r2]), "a walk-in");
  let walkId = wk[0];
  let wb = Option.unwrap(St.booking(s, walkId));
  check(wb.status == #checkedIn and wb.assignedRoom == r2 and wb.outstanding == walkQ.total, "the walk-in is in house in room 902 and owes the night");
  check(Option.unwrap(St.room(s, r2)).occupiedBy == walkId, "room 902 is occupied by the walk-in");
  check(St.staffBooking(later, walkId) != null and Option.unwrap(St.staffBooking(later, walkId)).channel == #walkIn, "it records the walk-in");
  unchanged(FRONT, book(FRONT, #walkIn, walkStay, walkQ.hash, "Late", "", [r2]), "roomNotVacant", "a walk-in given an occupied room");
  // a second walk-in, in room 901, asks for another room: refused into Karim's
  let mai = ok(FRONT, book(FRONT, #walkIn, walkStay, walkQ.hash, "Mai Nabil", "", [r1]), "a second walk-in, in room 901")[0];
  func move(by : Principal, id : Nat, from : Nat, to : Nat) : Cmd.Command { #moveRoom({ staff = by; bookingId = id; fromRoomId = from; toRoomId = to }) };
  unchanged(HKP, move(HKP, mai, r1, r2), "notAuthorised", "a housekeeper moving a guest");
  unchanged(FRONT, move(FRONT, mai, r1, r2), "roomNotVacant", "a move into a room another guest is in");
  unchanged(FRONT, move(FRONT, mai, r1, r1), "invalid", "a move into the room the guest is in");
  unchanged(FRONT, move(FRONT, mai, r2, r1), "invalid", "a move out of a room the guest is not in");
  unchanged(FRONT, move(FRONT, mai, r1, other), "roomWrongType", "a move into a room of another type");
  unchanged(FRONT, move(FRONT, mai, r1, 999), "noSuchRoom", "a move into a room that does not exist");
  unchanged(FRONT, move(FRONT, phoneId, r1, r2), "bookingState", "a move for a guest not in house");
  unchanged(FRONT, move(FRONT, 999_999, r1, r2), "noSuchBooking", "a move for a booking that does not exist");
  // leaving with the stay unpaid is refused; paid at the desk, the guest leaves
  unchanged(FRONT, #checkOut({ staff = FRONT; bookingId = walkId }), "balanceOutstanding", "a walk-in leaving without paying");
  let paid = ok(FRONT, #settleAtDesk({ staff = FRONT; bookingId = walkId; auth = { authId = 5_001; amount = walkQ.total; currency = "EUR"; merchantRef = St.BOOKING_REF_BASE + walkId } }), "the walk-in pays at the desk");
  ignore ok(FRONT, #recordGatewayOutcome({ paymentId = paid[1]; ok = true }), "the capture lands");
  ignore ok(FRONT, #checkOut({ staff = FRONT; bookingId = walkId }), "the walk-in leaves");
  check(Option.unwrap(St.booking(s, walkId)).outstanding == 0 and Option.unwrap(St.room(s, r2)).occupiedBy == 0, "paid, out, and the room is free");
  // room 902 is free now: Mai moves into it, and 901 is left dirty
  ignore ok(OWNER, #markRoom({ staff = OWNER; roomId = r1; cleaning = #clean }), "901 was cleaned before Mai came");
  let moved = ok(FRONT, move(FRONT, mai, r1, r2), "Mai moves to room 902");
  check(moved == [mai, r2], "the move answers the booking and its new room");
  check(Option.unwrap(St.room(s, r2)).occupiedBy == mai and Option.unwrap(St.room(s, r1)).occupiedBy == 0, "Mai is in 902 and 901 is free");
  check(Option.unwrap(St.booking(s, mai)).assignedRoom == r2, "her booking names 902");
  check((switch (St.housekeeping(later, r1)) { case (?h) h.cleaning == #dirty and h.cleanedBy == null; case null false }), "the room she left is dirty again");
  let maiActs = H.actOn(s, move(FRONT, mai, r1, r2), mai, Option.unwrap(St.booking(s, mai)));
  check(maiActs == ?"moveRoom", "her history names the move");
  law("after the staff bookings");

  // the history names the act
  let acts = List.empty<Text>();
  for (i in Nat.range(0, DL.length(log))) {
    switch (DL.get<Log.Event>(log, Log.codec, i)) {
      case (?blk) { if (Cmd.familyOf(blk.event.command) == "bookByStaff") List.add(acts, "bookByStaff") };
      case null {};
    };
  };
  check(List.size(acts) == 4, "four bookings taken by staff are in the log");

  // the books, and the origin law's controls
  let wsb = walk();
  check(List.size(wsb.violations) == 0, "the oracle is empty after the staff bookings: " # debug_show List.toArray(wsb.violations));
  func origin(fragment : Text) : Bool {
    for (v in List.values(walk().violations)) { if (Text.startsWith(v, #text "I12 origin") and Text.contains(v, #text fragment)) return true };
    false
  };
  var sbControls = 0;
  func control(caught : Bool, what : Text) { check(caught, what); if (caught) sbControls += 1 };
  let row = Option.unwrap(St.staffBooking(later, walkId));
  RowStore.put<R.StaffBooking>(sbTable, R.staffBooking, walkId, { row with day = T + 1 });
  control(origin("is a walk-in arriving on day"), "a walk-in recorded on a day it did not arrive is named I12");
  RowStore.put<R.StaffBooking>(sbTable, R.staffBooking, walkId, row);
  // a move written beside the fold that left the guest in both rooms
  let left = Option.unwrap(St.room(s, r1));
  RowStore.put<R.Room>(s.rooms, R.room, r1, { left with occupiedBy = mai });
  var both = false;
  for (v in List.values(walk().violations)) { if (Text.startsWith(v, #text "I8 rooms") and Text.contains(v, #text "occupies 2 rooms and booked 1")) both := true };
  control(both, "a guest left in the room they moved out of is named I8");
  RowStore.put<R.Room>(s.rooms, R.room, r1, left);
  if (flexBooking.size() > 0) {
    let fb = Option.unwrap(St.booking(s, flexBooking[0]));
    RowStore.put<R.Booking>(s.bookings, R.booking, flexBooking[0], { fb with holdId = 0 });
    control(origin("came from no hold and was not taken by staff"), "a booking from nowhere is named I12");
    let fh = Option.unwrap(St.hold(s, fb.holdId));
    RowStore.put<R.Booking>(s.bookings, R.booking, flexBooking[0], fb);
    RowStore.put<R.Hold>(s.holds, R.hold, fb.holdId, { fh with state = #expired });
    control(origin("which is expired"), "a booking from a hold that was never confirmed is named I12");
    RowStore.put<R.Hold>(s.holds, R.hold, fb.holdId, fh);
    // a staff row beside a booking from a hold, on a copy rebuilt from the log (a store keeps every row it is given)
    let rp = Con.replayAll(log);
    RowStore.put<R.StaffBooking>(St.later(rp.later, St.STAFF_BOOKING_TABLE), R.staffBooking, flexBooking[0], row);
    let rc : St.Ctx = { s = rp.stores; x = rp.later; block = DL.length(log); day = today(); height = heightCell };
    var both = false;
    var twice = false;
    for (section in [1, 12].vals()) {
      var cursor : ?Blob = null;
      label pages loop {
        let r = O.page(rc, section, cursor, 200);
        for (x in r.violations.vals()) {
          if (x.rule == "I12 origin" and Text.contains(x.detail, #text "and was also taken by staff")) both := true;
          if (x.rule == "I12 origin" and Text.contains(x.detail, #text "is of a booking that came from hold")) twice := true;
        };
        switch (r.next) { case (?c) cursor := ?c; case null break pages };
      };
    };
    control(both, "a booking from a hold also recorded as taken by staff is named I12 (bookings)");
    control(twice, "the same, from the staff booking's side, is named I12 (staff bookings)");
  };
  check(List.size(walk().violations) == 0, "every staff-booking control was removed");

  // ── a refund across the guest's own cards ──
  //
  // Nadia walks in and pays her night with one card, her minibar with a second, her snack with a third.
  // The minibar is voided: its refund goes back through the newest card first, drawn to nothing, then
  // the second; the second card's issuer refuses its slice. The snack is voided next: the third card
  // has nothing left and the second has refused a refund, so the whole slice goes to the first card.
  let r3 = ok(OWNER, #upsertRoom({ staff = OWNER; id = 0; roomTypeId = DT; number = "903"; outOfOrder = false }), "room 903")[0];
  ignore ok(OWNER, #setNights({ staff = OWNER; edit = { roomTypeId = DT; fromDay = T; toDay = T + 1; weekdays = 127; allotment = ?3; bar = null; minStay = null; maxStay = null;
    closedToArrival = null; closedToDeparture = null; stopSell = null } }), "a third room of the desk's type tonight");
  let MINI = ok(OWNER, #upsertExtra({ staff = OWNER; id = 0; facts = { code = "MINI"; nameEn = "Minibar"; nameAr = "ميني بار"; category = #minibar; price = 1_000; taxed = false; active = true } }), "a minibar item")[0];
  let nq = quoted(walkStay, "Nadia's night");
  let nadia = ok(FRONT, book(FRONT, #walkIn, walkStay, nq.hash, "Nadia Fahmy", "", [r3]), "Nadia walks in to 903")[0];
  func nb() : R.Booking { Option.unwrap(St.booking(s, nadia)) };
  func payWith(card : Nat, what : Text) : Nat {
    let out = nb().outstanding;
    let r = ok(FRONT, #settleAtDesk({ staff = FRONT; bookingId = nadia; auth = { authId = card; amount = out; currency = "EUR"; merchantRef = St.BOOKING_REF_BASE + nadia } }), what);
    ignore ok(FRONT, #recordGatewayOutcome({ paymentId = r[1]; ok = true }), what # " lands");
    out
  };
  let CARD_A = 7_001;
  let CARD_B = 7_002;
  let CARD_C = 7_003;
  let nightPaid = payWith(CARD_A, "the night, by card A");
  let minibar = ok(OWNER, #postCharge({ staff = OWNER; bookingId = nadia; extraId = MINI; quantity = 3; amount = 0; payerId = 0 }), "three from the minibar");
  check(payWith(CARD_B, "the minibar, by card B") == 3_000, "card B pays the minibar, 30.00");
  let snack = ok(OWNER, #postCharge({ staff = OWNER; bookingId = nadia; extraId = MINI; quantity = 1; amount = 0; payerId = 0 }), "one more from the minibar");
  check(payWith(CARD_C, "the snack, by card C") == 1_000, "card C pays the snack, 10.00");
  check(nb().outstanding == 0 and nb().paid == nightPaid + 4_000, "Nadia owes nothing, having paid on three cards");
  let (cards0, read0) = Res.guestCards(ctx(), nadia, false);
  check(cards0.size() == 3, "she has three cards, got " # debug_show cards0);
  check(read0 == St.paymentsOf(s, nadia).size(), "the cards are found in one walk of her payments: " # Nat.toText(read0) # " rows read");
  func voidLine(lineId : Nat, what : Text) : [Nat] {
    let pv = ok(OWNER, #propose({ staff = OWNER; act = #voidCharge({ bookingId = nadia; lineId }); justification = what }), "propose voiding " # what)[0];
    let from = s.nextPaymentId;
    ignore ok(OWNER2, #approve({ staff = OWNER2; proposalId = pv }), "a second owner voids " # what);
    Array.tabulate<Nat>(s.nextPaymentId - from : Nat, func(i) { from + i })
  };
  func pay(id : Nat) : R.Payment { Option.unwrap(St.payment(s, id)) };
  let v1 = voidLine(minibar[0], "the minibar");
  check(v1.size() == 2, "the minibar's 30.00 goes back in two slices, got " # Nat.toText(v1.size()));
  check(pay(v1[0]).gatewayAuth == CARD_C and pay(v1[0]).amount == 1_000 and pay(v1[1]).gatewayAuth == CARD_B and pay(v1[1]).amount == 2_000,
    "card C, the newest, gives back all its 10.00, card B the other 20.00; card A is not drawn");
  for (id in v1.vals()) check(pay(id).kind == #refunded and pay(id).state == #due and St.refundSlice(later, id) == ?{ firstSlice = v1[0]; excess = 3_000; written = DL.length(log) - 1 },
    "slice " # Nat.toText(id) # " is a refund due, recorded with its settle");
  law("after the minibar is voided");
  ignore ok(FRONT, #recordGatewayOutcome({ paymentId = v1[0]; ok = true }), "card C's slice lands");
  for (_ in Nat.range(0, 3)) ignore ok(FRONT, #recordGatewayOutcome({ paymentId = v1[1]; ok = false }), "card B's issuer refuses its slice");
  check(pay(v1[1]).state == #failed, "after three refusals card B's slice has failed");
  let (cards1, _) = Res.guestCards(ctx(), nadia, false);
  check(Array.filter<Res.Card>(cards1, func(k) { k.auth == CARD_B and k.refused and k.left == 3_000 }).size() == 1, "card B has refused a refund, and still holds its 30.00");
  let v2 = voidLine(snack[0], "the snack");
  check(v2.size() == 1 and pay(v2[0]).gatewayAuth == CARD_A and pay(v2[0]).amount == 1_000,
    "the snack's 10.00 goes to card A: card C has nothing left and card B refused, got " # debug_show Array.map<Nat, (Nat, Nat)>(v2, func(id) { (pay(id).gatewayAuth, pay(id).amount) }));
  law("after the snack is voided");
  ignore ok(FRONT, #recordGatewayOutcome({ paymentId = v2[0]; ok = true }), "card A's slice lands");
  // the split itself: what no open card can take is the desk's
  let three : [Res.Card] = [
    { auth = 1; left = 100; newest = 5; refused = false },
    { auth = 2; left = 500; newest = 9; refused = true },
    { auth = 3; left = 0; newest = 12; refused = false },
    { auth = 4; left = 250; newest = 7; refused = false },
  ];
  check(Res.slices(three, 300) == ([(4, 250), (1, 50)], 0), "newest open card first, an older one only for the rest");
  check(Res.slices(three, 400) == ([(4, 250), (1, 100)], 50), "what the open cards cannot take goes to the desk, never to the card that refused");
  check(Res.slices(three, 0) == ([], 0) and Res.slices([], 70) == ([], 70), "nothing to give back writes nothing; no card at all sends it all to the desk");
  check(List.size(walk().violations) == 0, "the oracle is empty after the refunds across cards: " # debug_show List.toArray(walk().violations));
  // each slice law, broken beside the fold, named by its own words
  func cash(fragment : Text) : Bool {
    for (x in List.values(walk().violations)) { if (Text.startsWith(x, #text "I5 cash") and Text.contains(x, #text fragment)) return true };
    false
  };
  var rsControls = 0;
  func rsControl(caught : Bool, what : Text) { check(caught, what); if (caught) rsControls += 1 };
  let slC = pay(v1[0]); let slB = pay(v1[1]); let slA = pay(v2[0]);
  let rsTable = St.later(later, St.REFUND_SLICE_TABLE);
  let rs1 = Option.unwrap(St.refundSlice(later, v1[0]));
  func put(id : Nat, q : R.Payment) { RowStore.put<R.Payment>(s.payments, R.payment, id, q) };
  RowStore.put<R.RefundSlice>(rsTable, R.refundSlice, v1[0], { rs1 with excess = 3_001 });
  rsControl(cash("sum to 3000; it split 3001"), "slices that do not sum to what the settle split are named I5");
  RowStore.put<R.RefundSlice>(rsTable, R.refundSlice, v1[0], rs1);
  put(v2[0], { slA with gatewayAuth = CARD_B });
  rsControl(cash("went to card 7002, which had refused a refund"), "a slice sent to a card that refused a refund is named I5");
  put(v2[0], { slA with amount = nightPaid + 1 });
  rsControl(cash("card 7001 has given back " # Nat.toText(nightPaid + 1) # " of the " # Nat.toText(nightPaid) # " it captured"), "a card giving back more than it captured is named I5");
  rsControl(cash("took " # Nat.toText(nightPaid + 1) # " from card 7001 with " # Nat.toText(nightPaid) # " left"), "a slice taking more than its card had left is named I5");
  put(v2[0], { slA with gatewayAuth = 0; state = #due });
  rsControl(cash("to the desk as a refund the gateway still holds"), "a desk slice the gateway still holds is named I5");
  put(v2[0], slA);
  put(v1[0], { slC with amount = 500 }); put(v1[1], { slB with amount = 2_500 });
  rsControl(cash("left 500 on card 7003 before drawing the next"), "a card not drawn to nothing before an older one is named I5");
  put(v1[0], { slC with gatewayAuth = CARD_B; amount = 2_000 }); put(v1[1], { slB with gatewayAuth = CARD_C; amount = 1_000 });
  rsControl(cash("drew card 7002 before the newer card 7003"), "an older card drawn before a newer one is named I5");
  put(v1[0], { slC with gatewayAuth = CARD_B; amount = 1_000 }); put(v1[1], { slB with gatewayAuth = CARD_A; amount = 2_000 });
  rsControl(cash("skipped the newer card 7003"), "a newer card with money left passed over is named I5");
  put(v1[0], { slC with gatewayAuth = 0; state = #failed }); put(v1[1], slB);
  rsControl(cash("to the desk before a card"), "a desk slice before a card's is named I5");
  put(v1[0], slC); put(v1[1], { slB with gatewayAuth = 0; amount = 2_000 });
  rsControl(cash("sent 2000 to the desk while card 7001 had " # Nat.toText(nightPaid) # " left"), "the desk paid while a card had money left is named I5");
  put(v1[1], slB);
  check(List.size(walk().violations) == 0, "every refund-slice control was removed");
  Debug.print("count: refund-slice controls that went red for their own rule = " # Nat.toText(rsControls));
  Debug.print("count: staff-booking refusals that left the state untouched = " # Nat.toText(untouchedSb));
  Debug.print("count: staff-booking controls that went red for their own rule = " # Nat.toText(sbControls));
};

// ── the day's figures ────────────────────────────────────────────────────────
//
// The night audit writes the day's figures. Each is recomputed here from the whole tables by another
// road (every room and booking read by id, not through the audit's indexes or its cursor) and must
// agree to the unit: rooms, out of order, sold, room revenue, guests in house, arrivals, no-shows,
// pickup, and the revenue rows by room type and plan. Then each law of I13 is shown a fault of its own.

do {
  let D = today();
  let before = St.dayFigures(later, D - 1 : Nat);
  ignore ok(OWNER, #openAudit({ staff = OWNER; day = D }), "open the audit for the day's figures");
  let opened = Option.unwrap(St.dayFigures(later, D));
  check(opened.roomsSeen == 0 and opened.houseSeen == 0 and opened.pickupBookings == 0 and opened.roomsSold == 0,
    "the figures row is written when the audit opens, with its plan and nothing counted yet");
  check(opened.roomsTotal == RowStore.size(s.rooms), "it is planned over every room of the hotel");
  var steps = 0;
  label run loop {
    switch (send(OWNER, #advanceAudit({ staff = OWNER; day = D; limit = 3 }))) {
      case (#ok _) { steps += 1; if (steps > 400) break run };
      case (#err _) break run;
    };
  };
  check(steps > 3, "the figures took more than one step at three items a step, got " # Nat.toText(steps));

  // the same figures by another road
  var rooms = 0; var out = 0;
  for (id in Nat.range(1, s.nextRoomId)) { switch (St.room(s, id)) { case (?r) { rooms += 1; if (r.status == #outOfOrder) out += 1 }; case null {} } };
  var house = 0; var sold = 0; var revenue = 0; var arrivals = 0; var noShows = 0;
  let byKey = Map.empty<Text, (Nat, Nat)>();
  func roomNights(id : Nat, night : ?Nat) : Nat {
    var sum = 0;
    for ((_, l) in St.folioOf(s, id).vals()) { if (l.kind == #roomNight and (switch night { case (?d) l.night == d; case null true })) sum += l.amount };
    sum
  };
  for (id in Nat.range(1, s.nextBookingId)) {
    switch (St.booking(s, id)) {
      case (?b) {
        if (b.status == #checkedIn and b.arrival <= D and b.departure > D) {
          let night = roomNights(id, ?D);
          house += 1; sold += b.rooms; revenue += night;
          if (b.arrival == D) arrivals += 1;
          let k = Nat.toText(b.roomTypeId) # "/" # Nat.toText(b.planId);
          let (n0, r0) = switch (Map.get(byKey, Text.compare, k)) { case (?x) x; case null (0, 0) };
          Map.add(byKey, Text.compare, k, (n0 + b.rooms, r0 + night));
        };
        if (b.status == #noShow and b.arrival == D) noShows += 1;
      };
      case null {};
    };
  };
  let from = switch before { case (?p) p.pickupFrom + p.pickupCount; case null 1 };
  var made = 0; var madeNights = 0; var madeRevenue = 0;
  for (id in Nat.range(from, s.nextBookingId)) {
    switch (St.booking(s, id)) { case (?b) { made += 1; madeNights += b.rooms * (b.departure - b.arrival : Nat); madeRevenue += roomNights(id, null) }; case null {} };
  };
  check(sold > 0 and revenue > 0 and made > 0, "the day has guests in house and bookings made, so the figures are not all zero");
  let f = Option.unwrap(St.dayFigures(later, D));
  func same(what : Text, got : Nat, want : Nat) { check(got == want, "the day's " # what # ": the audit wrote " # Nat.toText(got) # ", the tables give " # Nat.toText(want)) };
  same("rooms", f.roomsTotal, rooms); same("rooms looked at", f.roomsSeen, rooms); same("rooms out of order", f.roomsOut, out);
  same("rooms sold", f.roomsSold, sold); same("room revenue", f.roomRevenue, revenue);
  same("guests in house", f.inHouse, house); same("guests in house looked at", f.houseSeen, house); same("arrivals", f.arrivals, arrivals);
  same("no-shows", f.noShows, noShows);
  same("first booking of the pickup", f.pickupFrom, from); same("bookings made", f.pickupBookings, made); same("bookings planned", f.pickupCount, made);
  same("room nights booked", f.pickupNights, madeNights); same("room revenue booked", f.pickupRevenue, madeRevenue);
  let rows = St.dayRevenueOf(later, D);
  same("revenue rows", rows.size(), Map.size(byKey));
  for ((_, r) in rows.vals()) {
    let k = Nat.toText(r.roomTypeId) # "/" # Nat.toText(r.planId);
    switch (Map.get(byKey, Text.compare, k)) {
      case (?(n, rv)) { same("room nights of type/plan " # k, r.roomNights, n); same("revenue of type/plan " # k, r.revenue, rv) };
      case null check(false, "a revenue row for type/plan " # k # " that no guest in house holds");
    };
  };

  // controls: each law of I13 named for its own fault, then the fault removed
  var figControls = 0;
  func i13(words : Text) : Bool {
    var hit = false; var stray = false;
    for (v in List.values(walk().violations)) { if (Text.startsWith(v, #text "I13 figures") and Text.contains(v, #text words)) hit := true else stray := true };
    hit and not stray
  };
  func control(caught : Bool, what : Text) { check(caught, what); if (caught) figControls += 1 };
  let ft = St.later(later, St.DAY_FIGURES_TABLE);
  let rt = St.later(later, St.DAY_REVENUE_TABLE);
  let (rid, rrow) = rows[0];
  // while the day is open: the rooms sold must be the rooms of the guests in house now (the row and
  // its revenue rows moved together, so only the live law can see it)
  RowStore.put<R.DayFigures>(ft, R.dayFigures, D, { f with roomsSold = f.roomsSold + 1 });
  RowStore.put<R.DayRevenue>(rt, R.dayRevenue, rid, { rrow with roomNights = rrow.roomNights + 1 });
  control(i13("the guests in house hold"), "a night sold beside the guests in house is named I13 while the day is open");
  RowStore.put<R.DayRevenue>(rt, R.dayRevenue, rid, rrow);
  RowStore.put<R.DayFigures>(ft, R.dayFigures, D, f);
  ignore ok(OWNER, #closeDay({ staff = OWNER; day = D }), "close the day of the figures");
  law("after the day of the figures");
  RowStore.put<R.DayRevenue>(rt, R.dayRevenue, rid, { rrow with revenue = rrow.revenue + 1 });
  control(i13("its rows by type and plan sum to"), "a revenue row moved beside its night is named I13");
  RowStore.put<R.DayRevenue>(rt, R.dayRevenue, rid, rrow);
  RowStore.put<R.DayFigures>(ft, R.dayFigures, D, { f with houseSeen = f.houseSeen - 1 : Nat; arrivals = 0 });
  control(i13("guests in house"), "a day whose job skipped a guest in house is named I13");
  RowStore.put<R.DayFigures>(ft, R.dayFigures, D, { f with roomsOut = f.roomsTotal });
  control(i13("out of order, of"), "a day selling more rooms than it had in service is named I13");
  RowStore.put<R.DayFigures>(ft, R.dayFigures, D, { f with pickupFrom = f.pickupFrom + 1; pickupCount = f.pickupCount - 1 : Nat; pickupBookings = f.pickupBookings - 1 : Nat });
  check(before != null, "the day before this one was audited, so the pickup has a day to follow on from");
  control(i13("the day before ended at"), "a pickup that skipped a booking is named I13");
  RowStore.put<R.DayFigures>(ft, R.dayFigures, D, { f with pickupCount = f.pickupCount + s.nextBookingId; pickupBookings = f.pickupBookings + s.nextBookingId });
  control(i13("which does not exist"), "a pickup that runs past the last booking is named I13");
  RowStore.put<R.DayFigures>(ft, R.dayFigures, D, f);
  // a revenue row under a night with no figures: a row added, so on a copy rebuilt from the log
  let rp = Con.replayAll(log);
  RowStore.put<R.DayRevenue>(St.later(rp.later, St.DAY_REVENUE_TABLE), R.dayRevenue, RowStore.size(St.later(rp.later, St.DAY_REVENUE_TABLE)) + 1,
    { rrow with day = D + 400 });
  let rc : St.Ctx = { s = rp.stores; x = rp.later; block = DL.length(log); day = today(); height = heightCell };
  var orphan = false;
  label pages do {
    var cursor : ?Blob = null;
    loop {
      let r = O.page(rc, 14, cursor, 200);
      for (x in r.violations.vals()) { if (x.rule == "I13 figures" and Text.contains(x.detail, #text "is under a day with no figures")) orphan := true };
      switch (r.next) { case (?c) cursor := ?c; case null break pages };
    };
  };
  control(orphan, "a revenue row under a night with no figures is named I13");
  check(List.size(walk().violations) == 0, "every figures control was removed");
  Debug.print("count: audit steps for the day's figures = " # Nat.toText(steps));
  Debug.print("count: figures controls that went red for their own rule = " # Nat.toText(figControls));
};

// ── rates closed to a company ────────────────────────────────────────────────
//
// A company's negotiated rate is a plan closed to it. The public search, a hold, a confirmation, a
// booking taken by staff and a change to a booking are each refused it without the company's code, and
// with a code the plan does not admit; a company taken off sale between a hold and its confirmation is
// refused at the confirmation. Each refusal is compared on five dimensions; then each law of I14 is
// shown a fault of its own.

do {
  let T = today();
  let FRONT = who(50);
  let HKP = who(51);
  let REV = who(52);
  let CORP_GUEST = who(53);
  ignore ok(OWNER, #grantRole({ staff = OWNER; subject = REV; role = #revenue }), "a revenue manager");
  // a room type of its own, so this case reads only what it wrote
  ignore ok(OWNER, #upsertRoomType({ staff = OWNER; id = 0; facts = { code = "CORP"; nameEn = "Business"; nameAr = "أعمال"; descEn = ""; descAr = ""; sizeSqm = 28; maxAdults = 2; maxChildren = 0;
    maxOccupancy = 2; bedKind = #king; bedCount = 1; amenities = 1; photos = "almar/sea-room"; rank = 10; active = true } }), "the business room type");
  let BT = s.nextRoomTypeId - 1;
  ignore ok(OWNER, #upsertRoom({ staff = OWNER; id = 0; roomTypeId = BT; number = "1001"; outOfOrder = false }), "room 1001");
  ignore ok(OWNER, #upsertRoom({ staff = OWNER; id = 0; roomTypeId = BT; number = "1002"; outOfOrder = false }), "room 1002");
  ignore ok(OWNER, #upsertRoom({ staff = OWNER; id = 0; roomTypeId = BT; number = "1003"; outOfOrder = false }), "room 1003");
  ignore ok(OWNER, #setNights({ staff = OWNER; edit = { roomTypeId = BT; fromDay = T; toDay = T + 20; weekdays = 127; allotment = ?3; bar = ?15_000; minStay = null; maxStay = null;
    closedToArrival = null; closedToDeparture = null; stopSell = null } }), "the business nights");
  let P = ok(OWNER, #upsertRatePlan({ staff = OWNER; id = 0; facts = { code = "ACME-NEG"; nameEn = "Acme negotiated"; nameAr = "سعر أكمي"; kind = #discountOffBar; discountBps = 2_000;
    refundable = true; freeCancelDaysBefore = 1; penaltyNights = 1; guarantee = #firstNightAuthorised; modifiable = true; active = true } }), "the negotiated plan")[0];

  let companyT = St.later(later, St.COMPANY_TABLE);
  let accessT = St.later(later, St.PLAN_ACCESS_TABLE);
  let holdRateT = St.later(later, St.HOLD_RATE_TABLE);
  let bookingRateT = St.later(later, St.BOOKING_RATE_TABLE);
  var untouched = 0;
  func unchanged(caller : Principal, c : Cmd.Command, kind : Text, what : Text) {
    let fp = St.fingerprintHash(s, later);
    let len = DL.length(log);
    let arena = TA.bytesUsed(s.arena);
    let counters = (s.nextHoldId, s.nextHoldLineId, s.nextBookingId, s.nextFolioId, s.nextPaymentId);
    let rows = (RowStore.size(companyT), RowStore.size(accessT), RowStore.size(holdRateT), RowStore.size(bookingRateT), RowStore.size(s.holds) + RowStore.size(s.bookings));
    refused(caller, c, kind, what);
    let same = St.fingerprintHash(s, later) == fp and DL.length(log) == len and TA.bytesUsed(s.arena) == arena
      and (s.nextHoldId, s.nextHoldLineId, s.nextBookingId, s.nextFolioId, s.nextPaymentId) == counters
      and (RowStore.size(companyT), RowStore.size(accessT), RowStore.size(holdRateT), RowStore.size(bookingRateT), RowStore.size(s.holds) + RowStore.size(s.bookings)) == rows;
    check(same, what # ": the refusal moved state");
    if (same) untouched += 1;
  };
  func company(by : Principal, id : Nat, code : Text, name : Text, active : Bool) : Cmd.Command { #upsertCompany({ staff = by; id; code; name; active }) };
  func access(by : Principal, planId : Nat, companyId : Nat, closed : Bool) : Cmd.Command { #setPlanAccess({ staff = by; planId; companyId; closed }) };

  // the company's account: revenue's, refused in every way it can be
  unchanged(GUEST_A, company(GUEST_A, 0, "ACME", "Acme Trading", true), "notAuthorised", "a guest adding a company");
  unchanged(FRONT, company(FRONT, 0, "ACME", "Acme Trading", true), "notAuthorised", "a receptionist adding a company");
  unchanged(REV, company(REV, 0, "acme", "Acme Trading", true), "invalid", "a code in small letters");
  unchanged(REV, company(REV, 0, "AC ME", "Acme Trading", true), "invalid", "a code with a space");
  unchanged(REV, company(REV, 0, "", "Acme Trading", true), "invalid", "no code");
  unchanged(REV, company(REV, 0, "ACME-TRADING-2026", "Acme Trading", true), "tooLong", "a code of seventeen characters");
  unchanged(REV, company(REV, 0, "ACME", "", true), "invalid", "a company with no name");
  unchanged(REV, company(REV, 0, "ACME", Text.fromArray(Array.tabulate<Char>(121, func(_) { 'x' })), true), "tooLong", "a name past 120 bytes");
  unchanged(REV, company(REV, 99, "ACME", "Acme Trading", true), "invalid", "a change to a company that does not exist");
  let A = ok(REV, company(REV, 0, "ACME", "Acme Trading", true), "Acme's account")[0];
  let B = ok(REV, company(REV, 0, "NILE-TOURS", "Nile Tours", true), "Nile Tours' account")[0];
  check(A == 1 and B == 2, "the companies are numbered from one");
  check((switch (St.company(later, A)) { case (?co) co.code == "ACME" and TA.get(s.arena, co.name) == "Acme Trading" and co.active; case null false }), "Acme's row");
  unchanged(REV, company(REV, 0, "ACME", "Another Acme", true), "codeTaken", "a second company with Acme's code");
  unchanged(REV, company(REV, B, "ACME", "Nile Tours", true), "codeTaken", "Nile Tours renamed to Acme's code");
  ignore ok(REV, company(REV, B, "NILE-TOURS", "Nile Tours Co.", true), "Nile Tours renames itself, keeping its code");

  // who the plan is sold to
  unchanged(FRONT, access(FRONT, P, A, true), "notAuthorised", "a receptionist closing a plan");
  unchanged(REV, access(REV, 999, A, true), "noSuchPlan", "a plan that does not exist");
  unchanged(REV, access(REV, P, 99, true), "invalid", "a plan closed to a company that does not exist");
  unchanged(REV, access(REV, P, A, false), "invalid", "a plan named for a company and open to everyone");
  check(Acc.onPublicSale(later, P), "before its access is set, the plan is on public sale");
  ignore ok(REV, access(REV, P, A, true), "the negotiated plan is closed to Acme");
  check(not Acc.onPublicSale(later, P) and Acc.onPublicSale(later, 1), "closed, it is off public sale; the house rate is not");

  // the search
  let st = stay(BT, P, T + 4, 2, 1);
  let gA : Acc.Grant = { companyId = A; promoId = 0 };
  let gB : Acc.Grant = { companyId = B; promoId = 0 };
  check((switch (Res.quoteStay(ctx(), st)) { case (#err (#closedRate { planId })) planId == P; case _ false }), "the public search is refused the closed plan");
  check((switch (Res.quoteStayFor(ctx(), st, gB)) { case (#err (#closedRate _)) true; case _ false }), "Nile Tours' search is refused Acme's plan");
  let qA = switch (Res.quoteStayFor(ctx(), st, gA)) { case (#ok c) c.quote; case (#err r) Runtime.trap("Acme's quote: " # debug_show r) };
  let qPub = switch (Res.quoteStay(ctx(), stay(BT, 1, T + 4, 2, 1))) { case (#ok c) c.quote; case (#err r) Runtime.trap("the house quote: " # debug_show r) };
  check(qA.roomSubtotal * 10 == qPub.roomSubtotal * 8, "Acme's rate is the house rate less a fifth: " # Nat.toText(qA.roomSubtotal) # " of " # Nat.toText(qPub.roomSubtotal));
  check(Acc.resolve(ctx(), " acme ") == #ok(gA), "a code typed in small letters with spaces is Acme's");
  check(Acc.resolve(ctx(), "NOPE") == #err(#noSuchCode({ code = "NOPE" })), "a code nobody has");
  check(Acc.opens(ctx(), gA) == [P] and Acc.opens(ctx(), gB) == [] and Acc.opens(ctx(), Acc.PUBLIC) == [], "Acme's code opens its plan and nothing else does");

  // a hold
  func holdCoded(code : Text, sty : Cmd.Stay, hash : Blob, k : Nat8) : Cmd.Command { #placeHoldCoded({ owner = CORP_GUEST; stay = sty; quoteHash = hash; key = key(k); code }) };
  unchanged(CORP_GUEST, #placeHold({ owner = CORP_GUEST; stay = st; quoteHash = qA.hash; key = key(70) }), "closedRate", "a hold on the closed plan with no code");
  unchanged(CORP_GUEST, holdCoded("NOPE", st, qA.hash, 70), "noSuchCode", "a hold under a code nobody has");
  unchanged(CORP_GUEST, holdCoded("NILE-TOURS", st, qA.hash, 70), "closedRate", "a hold on Acme's plan under Nile Tours' code");
  unchanged(CORP_GUEST, holdCoded("ACME", st, qPub.hash, 70), "priceChanged", "a hold under Acme's code at the house price");
  let H = ok(CORP_GUEST, holdCoded("acme", st, qA.hash, 70), "a hold on Acme's plan under its code")[0];
  check(St.holdRate(later, H) == ?{ companyId = A; promoId = 0; use = 0; lastBlock = DL.length(log) - 1 }, "the hold keeps the access it was placed under");
  let hPub = ok(CORP_GUEST, #placeHold({ owner = CORP_GUEST; stay = stay(BT, 1, T + 4, 2, 1); quoteHash = qPub.hash; key = key(71) }), "a public hold beside it")[0];
  check(St.holdRate(later, hPub) == null, "the public sale keeps nothing");

  // the confirmation: Acme taken off sale between the hold and its confirmation
  let g = holdLines(H);
  func confirm(id : Nat, authId : Nat, amount : Nat) : Cmd.Command {
    #confirmHold({ owner = CORP_GUEST; holdId = id; guestName = "Hossam Fahmy"; guestEmail = "lxe1.h"; note = "Acme"; manageKey = key(72); account = null;
      auth = { authId; amount; currency = "EUR"; merchantRef = id } })
  };
  ignore ok(REV, company(REV, A, "ACME", "Acme Trading", false), "Acme's rates are taken off sale");
  check(Acc.resolve(ctx(), "ACME") == #err(#noSuchCode({ code = "ACME" })), "a company off sale has no code");
  unchanged(CORP_GUEST, confirm(H, 9_101, g), "closedRate", "a hold confirmed after its company was taken off sale");
  ignore ok(REV, company(REV, A, "ACME", "Acme Trading", true), "Acme's rates are back on sale");
  let BK = ok(CORP_GUEST, confirm(H, 9_101, g), "the hold confirmed under Acme's access")[0];
  let bk = Option.unwrap(St.booking(s, BK));
  check(St.bookingRate(later, BK) == ?{ companyId = A; promoId = 0; use = 0; lastBlock = bk.createdBlock }, "the booking keeps Acme's access, kept in the block that made it");
  let BKP = ok(CORP_GUEST, confirm(hPub, 9_102, holdLines(hPub)), "the public hold confirmed")[0];
  check(St.bookingRate(later, BKP) == null, "the public booking keeps nothing");

  // a booking taken by staff
  func desk(by : Principal, code : ?Text, sty : Cmd.Stay, hash : Blob) : Cmd.Command {
    switch code {
      case (?c) #bookByStaffCoded({ staff = by; channel = #phone; stay = sty; quoteHash = hash; guestName = "Rania Samir"; guestEmail = ""; note = "Acme's travel desk"; manageKey = key(73); roomIds = []; code = c });
      case null #bookByStaff({ staff = by; channel = #phone; stay = sty; quoteHash = hash; guestName = "Rania Samir"; guestEmail = ""; note = "Acme's travel desk"; manageKey = key(73); roomIds = [] });
    }
  };
  unchanged(FRONT, desk(FRONT, null, st, qA.hash), "closedRate", "a booking by phone on the closed plan with no code");
  unchanged(FRONT, desk(FRONT, ?"NOPE", st, qA.hash), "noSuchCode", "a booking by phone under a code nobody has");
  unchanged(FRONT, desk(FRONT, ?"NILE-TOURS", st, qA.hash), "closedRate", "a booking by phone on Acme's plan under Nile Tours' code");
  unchanged(HKP, desk(HKP, ?"ACME", st, qA.hash), "notAuthorised", "a housekeeper taking a coded booking");
  let SB = ok(FRONT, desk(FRONT, ?"ACME", st, qA.hash), "a booking by phone under Acme's code")[0];
  check(St.bookingRate(later, SB) == ?{ companyId = A; promoId = 0; use = 0; lastBlock = Option.unwrap(St.booking(s, SB)).createdBlock }, "the staff booking keeps Acme's access");
  check(St.staffBooking(later, SB) != null, "and records the call like any booking by phone");

  // a change: the public booking may not move onto Acme's plan
  let st2 = stay(BT, P, T + 4, 2, 1);
  unchanged(CORP_GUEST, #modifyBooking({ by = #manageKey; bookingId = BKP; stay = st2; quoteHash = qA.hash; auth = null }), "closedRate", "a public booking moved onto the closed plan");
  check(Res.firstActivePlan(s, later) == ?1, "a waitlist offer is made on the house rate, never a closed one");
  law("after the company rates");
  let w0 = walk();
  check(List.size(w0.violations) == 0, "the oracle is empty after the company rates: " # debug_show List.toArray(w0.violations));

  // the controls: each law of I14 shown a fault of its own, and nothing else red
  var rateControls = 0;
  func i14(words : Text) : Bool {
    var hit = false; var stray = false;
    for (v in List.values(walk().violations)) { if (Text.startsWith(v, #text "I14 rates")) { if (Text.contains(v, #text words)) hit := true } else stray := true };
    hit and not stray
  };
  func control(caught : Bool, what : Text) { check(caught, what); if (caught) rateControls += 1 };
  let kept = Option.unwrap(St.bookingRate(later, BK));
  RowStore.put<R.RateGrant>(bookingRateT, R.bookingRate, BK, { kept with companyId = B });
  control(i14("was sold under company " # Nat.toText(B)), "a booking on Acme's plan kept under Nile Tours is named I14");
  RowStore.put<R.RateGrant>(bookingRateT, R.bookingRate, BK, { kept with companyId = 0 });
  control(i14("keeps the public sale"), "a kept public sale is named I14");
  RowStore.put<R.RateGrant>(bookingRateT, R.bookingRate, BK, { kept with lastBlock = kept.lastBlock + 1 });
  control(i14("the booking was made at"), "an access kept in another block than the booking is named I14");
  RowStore.put<R.RateGrant>(bookingRateT, R.bookingRate, BK, { kept with companyId = 77 });
  control(i14("names company 77, which does not exist"), "an access naming no company is named I14");
  RowStore.put<R.RateGrant>(bookingRateT, R.bookingRate, BK, { kept with promoId = 999 });
  control(i14("names promotion 999, which does not exist"), "an access naming a promotion that does not exist is named I14");
  RowStore.put<R.RateGrant>(bookingRateT, R.bookingRate, BK, kept);
  // the hold's access moved beside the booking's
  let hk = Option.unwrap(St.holdRate(later, H));
  RowStore.put<R.RateGrant>(holdRateT, R.holdRate, H, { hk with companyId = B });
  control(i14("its hold " # Nat.toText(H) # " was placed under company " # Nat.toText(B)), "a booking whose hold was placed under another access is named I14");
  RowStore.put<R.RateGrant>(holdRateT, R.holdRate, H, { hk with lastBlock = 9_999_999 });
  control(i14("after the hold's last change"), "a hold's access kept after the hold last changed is named I14");
  RowStore.put<R.RateGrant>(holdRateT, R.holdRate, H, hk);
  // a public booking on the closed plan: the booking's plan moved beside the fold
  let pb = Option.unwrap(St.booking(s, BKP));
  RowStore.put<R.Booking>(s.bookings, R.booking, BKP, { pb with planId = P });
  control(i14("was sold on public sale"), "a public booking on Acme's plan is named I14");
  RowStore.put<R.Booking>(s.bookings, R.booking, BKP, pb);
  // the plan's access
  let ac = Option.unwrap(St.planAccess(later, P));
  RowStore.put<R.PlanAccess>(accessT, R.planAccess, P, { ac with closed = false });
  control(i14("is open to everyone"), "a plan named for a company and open to everyone is named I14");
  RowStore.put<R.PlanAccess>(accessT, R.planAccess, P, { ac with companyId = 88 });
  control(i14("names company 88, which does not exist"), "a plan closed to a company that does not exist is named I14");
  RowStore.put<R.PlanAccess>(accessT, R.planAccess, P, ac);
  // a company's code
  let coA = Option.unwrap(St.company(later, A));
  RowStore.put<R.Company>(companyT, R.company, A, { coA with code = "Acme" });
  control(i14("which is not capitals, digits and dashes"), "a company code in small letters is named I14");
  RowStore.put<R.Company>(companyT, R.company, A, coA);
  // rows added beside the fold, on a copy rebuilt from the log: two companies under one code, an
  // access for a plan that does not exist
  let rp = Con.replayAll(log);
  let rc : St.Ctx = { s = rp.stores; x = rp.later; block = DL.length(log); day = today(); height = heightCell };
  RowStore.put<R.Company>(St.later(rp.later, St.COMPANY_TABLE), R.company, 3, { coA with code = "NILE-TOURS" });
  RowStore.put<R.PlanAccess>(St.later(rp.later, St.PLAN_ACCESS_TABLE), R.planAccess, 999, ac);
  func onCopy(section : Nat, words : Text) : Bool {
    var hit = false;
    var cursor : ?Blob = null;
    label pages loop {
      let r = O.page(rc, section, cursor, 200);
      for (x in r.violations.vals()) { if (x.rule == "I14 rates" and Text.contains(x.detail, #text words)) hit := true };
      switch (r.next) { case (?c) cursor := ?c; case null break pages };
    };
    hit
  };
  control(onCopy(18, "'s code finds company"), "two companies under one code are named I14");
  control(onCopy(19, "the plan does not exist"), "an access for a plan that does not exist is named I14");
  check(List.size(walk().violations) == 0, "every rate control was removed");
  Debug.print("count: rate refusals that left the state untouched = " # Nat.toText(untouched));
  Debug.print("count: rate controls that went red for their own rule = " # Nat.toText(rateControls));
};

// ── promotions ───────────────────────────────────────────────────────────────
//
// A promotion's code opens one plan closed to everyone but codes, within a booking window, a stay
// window and a number of uses. A use is counted at the confirmation or the booking by staff, never at
// the hold and never at a change; three holds against two uses are settled at the confirmations. Each
// refusal is compared on five dimensions; then each law the promotions add to I14 is shown a fault of
// its own.

do {
  let T = today();
  let MKT = who(54);
  let PGUEST = who(55);
  let DESK = who(56);
  let PGUEST2 = who(57);
  ignore ok(OWNER, #grantRole({ staff = OWNER; subject = MKT; role = #revenue }), "a revenue manager for the promotions");
  ignore ok(OWNER, #grantRole({ staff = OWNER; subject = DESK; role = #frontDesk }), "a receptionist for the promotions");
  ignore ok(OWNER, #upsertRoomType({ staff = OWNER; id = 0; facts = { code = "ORCHARD"; nameEn = "Orchard"; nameAr = "بستان"; descEn = ""; descAr = ""; sizeSqm = 30; maxAdults = 2; maxChildren = 0;
    maxOccupancy = 2; bedKind = #king; bedCount = 1; amenities = 1; photos = "almar/sea-room"; rank = 11; active = true } }), "the orchard room type");
  let GT = s.nextRoomTypeId - 1;
  for (n in ["2001", "2002", "2003", "2004"].vals()) ignore ok(OWNER, #upsertRoom({ staff = OWNER; id = 0; roomTypeId = GT; number = n; outOfOrder = false }), "room " # n);
  ignore ok(OWNER, #setNights({ staff = OWNER; edit = { roomTypeId = GT; fromDay = T; toDay = T + 20; weekdays = 127; allotment = ?4; bar = ?12_000; minStay = null; maxStay = null;
    closedToArrival = null; closedToDeparture = null; stopSell = null } }), "the patio nights");
  let SP = ok(OWNER, #upsertRatePlan({ staff = OWNER; id = 0; facts = { code = "SPRING"; nameEn = "Spring offer"; nameAr = "عرض الربيع"; kind = #discountOffBar; discountBps = 1_000;
    refundable = true; freeCancelDaysBefore = 1; penaltyNights = 1; guarantee = #firstNightAuthorised; modifiable = true; active = true } }), "the spring plan")[0];
  ignore ok(MKT, #setPlanAccess({ staff = MKT; planId = SP; companyId = 0; closed = true }), "the spring plan is closed to everyone but codes");

  let promoT = St.later(later, St.PROMO_TABLE);
  let holdRateT = St.later(later, St.HOLD_RATE_TABLE);
  let bookingRateT = St.later(later, St.BOOKING_RATE_TABLE);
  var untouched = 0;
  func unchanged(caller : Principal, c : Cmd.Command, kind : Text, what : Text) {
    let fp = St.fingerprintHash(s, later);
    let len = DL.length(log);
    let arena = TA.bytesUsed(s.arena);
    let counters = (s.nextHoldId, s.nextHoldLineId, s.nextBookingId, s.nextFolioId, s.nextPaymentId);
    let rows = (RowStore.size(promoT), RowStore.size(holdRateT), RowStore.size(bookingRateT), RowStore.size(s.holds) + RowStore.size(s.bookings));
    refused(caller, c, kind, what);
    let same = St.fingerprintHash(s, later) == fp and DL.length(log) == len and TA.bytesUsed(s.arena) == arena
      and (s.nextHoldId, s.nextHoldLineId, s.nextBookingId, s.nextFolioId, s.nextPaymentId) == counters
      and (RowStore.size(promoT), RowStore.size(holdRateT), RowStore.size(bookingRateT), RowStore.size(s.holds) + RowStore.size(s.bookings)) == rows;
    check(same, what # ": the refusal moved state");
    if (same) untouched += 1;
  };
  type Facts = { code : Text; name : Text; planId : Nat; bookFrom : Nat; bookUntil : Nat; stayFrom : Nat; stayUntil : Nat; maxUses : Nat; active : Bool };
  let spring : Facts = { code = "SPRING26"; name = "Spring in the garden"; planId = SP; bookFrom = T; bookUntil = T + 10; stayFrom = T + 2; stayUntil = T + 12; maxUses = 2; active = true };
  func promo(by : Principal, id : Nat, f : Facts) : Cmd.Command {
    #upsertPromo({ staff = by; id; code = f.code; name = f.name; planId = f.planId; bookFrom = f.bookFrom; bookUntil = f.bookUntil; stayFrom = f.stayFrom;
      stayUntil = f.stayUntil; maxUses = f.maxUses; active = f.active })
  };

  // the promotion, refused in every way it can be
  unchanged(PGUEST, promo(PGUEST, 0, spring), "notAuthorised", "a guest adding a promotion");
  unchanged(DESK, promo(DESK, 0, spring), "notAuthorised", "a receptionist adding a promotion");
  unchanged(MKT, promo(MKT, 0, { spring with code = "spring26" }), "invalid", "a promotion code in small letters");
  unchanged(MKT, promo(MKT, 0, { spring with code = "" }), "invalid", "a promotion with no code");
  unchanged(MKT, promo(MKT, 0, { spring with code = "SPRING-IN-THE-GARDEN" }), "tooLong", "a promotion code past sixteen characters");
  unchanged(MKT, promo(MKT, 0, { spring with code = "ACME" }), "codeTaken", "a promotion under a company's code");
  unchanged(MKT, promo(MKT, 0, { spring with planId = 999 }), "noSuchPlan", "a promotion of a plan that does not exist");
  unchanged(MKT, promo(MKT, 0, { spring with bookFrom = T + 11 }), "invalid", "a booking window that ends before it begins");
  unchanged(MKT, promo(MKT, 0, { spring with stayFrom = T + 13 }), "invalid", "a stay window that ends before it begins");
  unchanged(MKT, promo(MKT, 0, { spring with stayUntil = T + 551 }), "invalid", "a stay window past the hotel's horizon");
  unchanged(MKT, promo(MKT, 0, { spring with bookUntil = T + 551; stayUntil = T + 551 }), "invalid", "a booking window past the hotel's horizon");
  unchanged(MKT, promo(MKT, 0, { spring with maxUses = 1_000_001 }), "invalid", "a limit past a million uses");
  unchanged(MKT, promo(MKT, 0, { spring with name = "" }), "invalid", "a promotion with no name");
  unchanged(MKT, promo(MKT, 0, { spring with name = Text.fromArray(Array.tabulate<Char>(121, func(_) { 'x' })) }), "tooLong", "a promotion name past 120 bytes");
  unchanged(MKT, promo(MKT, 99, spring), "invalid", "a change to a promotion that does not exist");
  let PR = ok(MKT, promo(MKT, 0, spring), "the spring promotion")[0];
  check(PR == 1, "the promotions are numbered from one");
  check((switch (St.promo(later, PR)) { case (?p) p.code == "SPRING26" and TA.get(s.arena, p.name) == "Spring in the garden" and p.planId == SP and p.used == 0 and p.maxUses == 2; case null false }), "the promotion's row");
  unchanged(MKT, promo(MKT, 0, { spring with name = "Another spring" }), "codeTaken", "a second promotion under the same code");
  unchanged(MKT, #upsertCompany({ staff = MKT; id = 0; code = "SPRING26"; name = "Spring Travel"; active = true }), "codeTaken", "a company under the promotion's code");
  unchanged(MKT, promo(MKT, PR, { spring with planId = 1 }), "invalid", "a promotion moved to another plan");

  // the code
  let gP : Acc.Grant = { companyId = 0; promoId = PR };
  check(Acc.resolve(ctx(), " spring26 ") == #ok(gP), "a promotion's code typed in small letters is the promotion's");
  check(Acc.opens(ctx(), gP) == [SP], "the promotion's code opens the spring plan and nothing else");
  check(not Acc.onPublicSale(later, SP), "the spring plan is off public sale");
  check(Acc.forPlan(ctx(), gP, 1) == Acc.PUBLIC and Acc.forPlan(ctx(), gP, SP) == gP, "on another plan the promotion's code is the public sale");

  // the quotes
  let st = stay(GT, SP, T + 3, 2, 1);
  check((switch (Res.quoteStay(ctx(), st)) { case (#err (#closedRate { planId })) planId == SP; case _ false }), "the public search is refused the spring plan");
  let q = switch (Res.quoteStayFor(ctx(), st, gP)) { case (#ok c) c.quote; case (#err r) Runtime.trap("the spring quote: " # debug_show r) };
  let qHouse = switch (Res.quoteStay(ctx(), stay(GT, 1, T + 3, 2, 1))) { case (#ok c) c.quote; case (#err r) Runtime.trap("the garden house quote: " # debug_show r) };
  check(q.roomSubtotal * 10 == qHouse.roomSubtotal * 9, "the spring rate is the house rate less a tenth: " # Nat.toText(q.roomSubtotal) # " of " # Nat.toText(qHouse.roomSubtotal));
  func promoClosed(sty : Cmd.Stay, words : Text) : Bool {
    switch (Res.quoteStayFor(ctx(), sty, gP)) { case (#err (#promoClosed { code; why })) code == "SPRING26" and Text.contains(why, #text words); case _ false }
  };
  check(promoClosed(stay(GT, SP, T + 1, 2, 1), "is for nights from"), "a stay before the stay window is refused the promotion");
  check(promoClosed(stay(GT, SP, T + 11, 3, 1), "is for nights from"), "a stay running past the stay window is refused the promotion");
  check((switch (Res.quoteStayFor(ctx(), stay(GT, SP, T + 11, 2, 1), gP)) { case (#ok _) true; case (#err _) false }), "a stay ending on the window's last night is admitted");

  // the holds: none of them counts a use
  func holdBy(owner : Principal, code : Text, sty : Cmd.Stay, hash : Blob, k : Nat8) : Cmd.Command { #placeHoldCoded({ owner; stay = sty; quoteHash = hash; key = key(k); code }) };
  func holdCoded(code : Text, sty : Cmd.Stay, hash : Blob, k : Nat8) : Cmd.Command { holdBy(PGUEST, code, sty, hash, k) };
  unchanged(PGUEST, #placeHold({ owner = PGUEST; stay = st; quoteHash = q.hash; key = key(80) }), "closedRate", "a hold on the spring plan with no code");
  unchanged(PGUEST, holdCoded("ACME", st, q.hash, 80), "closedRate", "a hold on the spring plan under a company's code");
  unchanged(PGUEST, holdCoded("SPRING26", stay(GT, SP, T + 1, 2, 1), q.hash, 80), "promoClosed", "a hold before the stay window");
  let H1 = ok(PGUEST, holdCoded("spring26", st, q.hash, 81), "the first hold under the promotion")[0];
  check(St.holdRate(later, H1) == ?{ companyId = 0; promoId = PR; use = 0; lastBlock = DL.length(log) - 1 }, "the hold keeps the promotion, counting no use");
  let H2 = ok(PGUEST, holdCoded("SPRING26", st, q.hash, 82), "the second")[0];
  // the third on nights of its own: a night holds at most two rooms on hold at once
  let st7 = stay(GT, SP, T + 7, 1, 1);
  let q7 = switch (Res.quoteStayFor(ctx(), st7, gP)) { case (#ok c) c.quote; case (#err r) Runtime.trap("the night-seven quote: " # debug_show r) };
  let H3 = ok(PGUEST2, holdBy(PGUEST2, "SPRING26", st7, q7.hash, 83), "the third, by another guest, against two uses")[0];
  check((switch (St.promo(later, PR)) { case (?p) p.used == 0; case null false }), "three holds count no use");
  let qHouse8 = switch (Res.quoteStay(ctx(), stay(GT, 1, T + 8, 2, 1))) { case (#ok c) c.quote; case (#err r) Runtime.trap("the night-eight house quote: " # debug_show r) };
  let HP = ok(PGUEST2, holdBy(PGUEST2, "SPRING26", stay(GT, 1, T + 8, 2, 1), qHouse8.hash, 84), "the promotion's code on the house rate")[0];
  check(St.holdRate(later, HP) == null, "on the house rate the code is the public sale and keeps nothing");
  ignore ok(PGUEST2, #releaseHold({ owner = PGUEST2; holdId = HP }), "the house-rate hold released");

  // the confirmations: two uses, the third refused
  func confirm(id : Nat, authId : Nat) : Cmd.Command {
    #confirmHold({ owner = (if (id == H3) PGUEST2 else PGUEST); holdId = id; guestName = "Mona Said"; guestEmail = "lxe1.m"; note = "spring"; manageKey = key(85); account = null;
      auth = { authId; amount = holdLines(id); currency = "EUR"; merchantRef = id } })
  };
  let B1 = ok(PGUEST, confirm(H1, 9_201), "the first hold confirmed")[0];
  check(St.bookingRate(later, B1) == ?{ companyId = 0; promoId = PR; use = 1; lastBlock = Option.unwrap(St.booking(s, B1)).createdBlock }, "the first booking is the promotion's first use");
  let B2 = ok(PGUEST, confirm(H2, 9_202), "the second hold confirmed")[0];
  check((switch (St.bookingRate(later, B2)) { case (?r) r.use == 2; case null false }) and (switch (St.promo(later, PR)) { case (?p) p.used == 2; case null false }), "the second booking is the second use");
  check(St.bookingOfUse(later, PR, 1) == ?(B1, Option.unwrap(St.bookingRate(later, B1))) and St.bookingOfUse(later, PR, 2) == ?(B2, Option.unwrap(St.bookingRate(later, B2))), "each use is found under its number");
  unchanged(PGUEST2, confirm(H3, 9_203), "promoClosed", "the third hold confirmed after the promotion's two uses");

  // the limit raised, and never below the uses counted
  unchanged(MKT, promo(MKT, PR, { spring with maxUses = 1 }), "invalid", "a limit below the uses already counted");
  ignore ok(MKT, promo(MKT, PR, { spring with maxUses = 3 }), "the limit raised to three");
  check((switch (St.promo(later, PR)) { case (?p) p.used == 2 and p.maxUses == 3; case null false }), "a change keeps the uses counted");

  // the price of a change to the first booking, a night later, read while a use is left
  let stMove = stay(GT, SP, T + 4, 2, 1);
  let qMove = switch (Res.quoteStayFor(ctx(), stMove, gP)) { case (#ok c) c.quote; case (#err r) Runtime.trap("the moved quote: " # debug_show r) };
  // a booking taken by staff counts a use like a confirmation
  let st6 = stay(GT, SP, T + 6, 1, 1);
  let q6 = switch (Res.quoteStayFor(ctx(), st6, gP)) { case (#ok c) c.quote; case (#err r) Runtime.trap("the night-six quote: " # debug_show r) };
  func desk(code : Text) : Cmd.Command {
    #bookByStaffCoded({ staff = DESK; channel = #phone; stay = st6; quoteHash = q6.hash; guestName = "Selim Nabil"; guestEmail = ""; note = "spring by phone"; manageKey = key(86); roomIds = []; code })
  };
  let B3 = ok(DESK, desk("SPRING26"), "a booking by phone under the promotion")[0];
  check((switch (St.bookingRate(later, B3)) { case (?r) r.use == 3; case null false }), "the booking by phone is the third use");
  unchanged(DESK, desk("SPRING26"), "promoClosed", "a fourth booking by phone past the limit");

  // a change keeps its use: moved a night later after the booking window closed and every use is spent
  ignore ok(MKT, promo(MKT, PR, { spring with bookFrom = T + 1; bookUntil = T + 10; maxUses = 3 }), "the booking window moved to begin tomorrow");
  unchanged(PGUEST, holdCoded("SPRING26", st, q.hash, 87), "promoClosed", "a hold outside the booking window");
  check(promoClosed(st, "is booked from"), "and the quote says why");
  unchanged(PGUEST, #modifyBooking({ by = #manageKey; bookingId = B1; stay = stay(GT, SP, T + 11, 3, 1); quoteHash = qMove.hash; auth = null }), "promoClosed", "a change running past the stay window");
  ignore ok(PGUEST, #modifyBooking({ by = #manageKey; bookingId = B1; stay = stMove; quoteHash = qMove.hash; auth = null }), "a change inside the stay window, outside the booking window");
  check((switch (St.promo(later, PR)) { case (?p) p.used == 3; case null false }) and (switch (St.bookingRate(later, B1)) { case (?r) r.use == 1; case null false }), "the change counted no use and kept its own");

  // off sale
  ignore ok(MKT, promo(MKT, PR, { spring with maxUses = 0; active = false }), "the promotion taken off sale, its limit lifted");
  check(Acc.resolve(ctx(), "SPRING26") == #err(#noSuchCode({ code = "SPRING26" })), "a promotion off sale has no code");
  ignore ok(MKT, promo(MKT, PR, { spring with maxUses = 0 }), "and back on sale with no limit");
  law("after the promotions");
  let w0 = walk();
  check(List.size(w0.violations) == 0, "the oracle is empty after the promotions: " # debug_show List.toArray(w0.violations));

  // the controls: each law the promotions add, shown a fault of its own, and nothing else red
  var promoControls = 0;
  func i14(words : Text) : Bool {
    var hit = false; var stray = false;
    for (v in List.values(walk().violations)) { if (Text.startsWith(v, #text "I14 rates")) { if (Text.contains(v, #text words)) hit := true } else stray := true };
    hit and not stray
  };
  func control(caught : Bool, what : Text) { check(caught, what); if (caught) promoControls += 1 };
  let r1 = Option.unwrap(St.bookingRate(later, B1));
  let r2 = Option.unwrap(St.bookingRate(later, B2));
  let r3 = Option.unwrap(St.bookingRate(later, B3));
  RowStore.put<R.RateGrant>(bookingRateT, R.bookingRate, B2, { r2 with use = 5 });
  control(i14("counts use 5 of promotion " # Nat.toText(PR) # ", which has counted 3"), "a use past the promotion's count is named I14");
  RowStore.put<R.RateGrant>(bookingRateT, R.bookingRate, B2, { r2 with use = 0 });
  control(i14("with no use 2"), "a use with the one before it missing is named I14");
  RowStore.put<R.RateGrant>(bookingRateT, R.bookingRate, B2, r2);
  RowStore.put<R.RateGrant>(bookingRateT, R.bookingRate, B3, { r3 with promoId = 0; use = 0 });
  control(i14("its last use is no booking's"), "a promotion counting a use no booking holds is named I14");
  RowStore.put<R.RateGrant>(bookingRateT, R.bookingRate, B3, { r3 with promoId = 0 });
  control(i14("of no promotion"), "a use counted under no promotion is named I14");
  RowStore.put<R.RateGrant>(bookingRateT, R.bookingRate, B3, r3);
  RowStore.put<R.RateGrant>(bookingRateT, R.bookingRate, B1, { r1 with companyId = 1 });
  control(i14("names both a company and a promotion"), "an access naming a company and a promotion is named I14");
  RowStore.put<R.RateGrant>(bookingRateT, R.bookingRate, B1, r1);
  let hr = Option.unwrap(St.holdRate(later, H3));
  RowStore.put<R.RateGrant>(holdRateT, R.holdRate, H3, { hr with use = 1 });
  control(i14("a hold counts none"), "a hold counting a use is named I14");
  RowStore.put<R.RateGrant>(holdRateT, R.holdRate, H3, hr);
  let p0 = Option.unwrap(St.promo(later, PR));
  RowStore.put<R.Promo>(promoT, R.promo, PR, { p0 with maxUses = 2 });
  control(i14("past its limit of 2"), "a promotion used past its limit is named I14");
  RowStore.put<R.Promo>(promoT, R.promo, PR, { p0 with used = 2 });
  control(i14("which has counted 2"), "a promotion counting fewer uses than its bookings is named I14");
  RowStore.put<R.Promo>(promoT, R.promo, PR, { p0 with stayFrom = p0.stayUntil + 1 });
  control(i14("has a window that ends before it begins"), "a promotion's window out of order is named I14");
  RowStore.put<R.Promo>(promoT, R.promo, PR, { p0 with planId = 999 });
  control(i14("opens plan 999, which does not exist"), "a promotion of a plan that does not exist is named I14");
  RowStore.put<R.Promo>(promoT, R.promo, PR, { p0 with planId = 1 });
  control(i14("was sold under"), "a booking on a plan closed to codes whose promotion names another plan is named I14");
  RowStore.put<R.Promo>(promoT, R.promo, PR, { p0 with code = "Spring26" });
  control(i14("which is not capitals, digits and dashes"), "a promotion code in small letters is named I14");
  RowStore.put<R.Promo>(promoT, R.promo, PR, p0);
  // rows added beside the fold, on a copy rebuilt from the log: a second promotion under the code, a
  // company under the promotion's code
  let rp = Con.replayAll(log);
  let rc : St.Ctx = { s = rp.stores; x = rp.later; block = DL.length(log); day = today(); height = heightCell };
  RowStore.put<R.Promo>(St.later(rp.later, St.PROMO_TABLE), R.promo, 2, p0);
  let co1 = Option.unwrap(St.company(rp.later, 1));
  RowStore.put<R.Company>(St.later(rp.later, St.COMPANY_TABLE), R.company, 9, { co1 with code = "SPRING26" });
  func onCopy(section : Nat, words : Text) : Bool {
    var hit = false;
    var cursor : ?Blob = null;
    label pages loop {
      let r = O.page(rc, section, cursor, 200);
      for (x in r.violations.vals()) { if (x.rule == "I14 rates" and Text.contains(x.detail, #text words)) hit := true };
      switch (r.next) { case (?c) cursor := ?c; case null break pages };
    };
    hit
  };
  control(onCopy(20, "'s code finds promotion"), "two promotions under one code are named I14");
  control(onCopy(18, "'s code is also promotion"), "a company under a promotion's code is named I14");
  check(List.size(walk().violations) == 0, "every promotion control was removed");
  Debug.print("count: promotion refusals that left the state untouched = " # Nat.toText(untouched));
  Debug.print("count: promotion controls that went red for their own rule = " # Nat.toText(promoControls));
};

// ── group blocks ─────────────────────────────────────────────────────────────
//
// A group block holds rooms of one type on one plan off sale for a group until its cut-off. The desk
// picks the group's guests up from it, through stop-sell and the night's restrictions; a cancelled
// pickup goes back to the block while it is open; revenue or the night audit at the cut-off gives
// what is left back to sale. Each refusal is compared on five dimensions; then each law of I15 is
// shown a fault of its own.

do {
  let T = today();
  let REVB = who(58);
  let DESKB = who(59);
  let BGUEST = who(60);
  ignore ok(OWNER, #grantRole({ staff = OWNER; subject = REVB; role = #revenue }), "a revenue manager for the blocks");
  ignore ok(OWNER, #grantRole({ staff = OWNER; subject = DESKB; role = #frontDesk }), "a receptionist for the blocks");
  ignore ok(OWNER, #upsertRoomType({ staff = OWNER; id = 0; facts = { code = "TERRACE"; nameEn = "Terrace"; nameAr = "تراس"; descEn = ""; descAr = ""; sizeSqm = 34; maxAdults = 2; maxChildren = 0;
    maxOccupancy = 2; bedKind = #king; bedCount = 1; amenities = 1; photos = "almar/sea-room"; rank = 12; active = true } }), "the terrace room type");
  let TT = s.nextRoomTypeId - 1;
  for (n in ["3001", "3002", "3003", "3004", "3005", "3006"].vals()) ignore ok(OWNER, #upsertRoom({ staff = OWNER; id = 0; roomTypeId = TT; number = n; outOfOrder = false }), "room " # n);
  ignore ok(OWNER, #setNights({ staff = OWNER; edit = { roomTypeId = TT; fromDay = T; toDay = T + 30; weekdays = 127; allotment = ?6; bar = ?10_000; minStay = null; maxStay = null;
    closedToArrival = null; closedToDeparture = null; stopSell = null } }), "the terrace nights");
  func planOf(code : Text) : Nat { for (id in Nat.range(1, 64)) { switch (St.plan(s, id)) { case (?p) { if (p.code == code) return id }; case null {} } }; 0 };
  let SP = planOf("SPRING");
  let NEG = planOf("ACME-NEG");
  func companyOf(code : Text) : Nat { for (id in Nat.range(1, 64)) { switch (St.company(later, id)) { case (?x) { if (x.code == code) return id }; case null {} } }; 0 };
  let ACME = companyOf("ACME");
  let NILE = companyOf("NILE-TOURS");
  check(SP != 0 and NEG != 0 and ACME != 0 and NILE != 0, "the plans and companies of the earlier sections");
  check((switch (St.planAccess(later, NEG)) { case (?a) a.closed and a.companyId == ACME; case null false }), "the negotiated plan is closed to Acme");

  let blockT = St.later(later, St.BLOCK_TABLE);
  let blockNightT = St.later(later, St.BLOCK_NIGHT_TABLE);
  let nightBlockT = St.later(later, St.NIGHT_BLOCK_TABLE);
  let bookingBlockT = St.later(later, St.BOOKING_BLOCK_TABLE);
  var untouched = 0;
  func unchanged(caller : Principal, c : Cmd.Command, kind : Text, what : Text) {
    let fp = St.fingerprintHash(s, later);
    let len = DL.length(log);
    let arena = TA.bytesUsed(s.arena);
    let counters = (s.nextHoldId, s.nextHoldLineId, s.nextBookingId, s.nextFolioId, s.nextPaymentId);
    let rows = (RowStore.size(blockT), RowStore.size(blockNightT), RowStore.size(nightBlockT), RowStore.size(bookingBlockT), RowStore.size(s.holds) + RowStore.size(s.bookings));
    refused(caller, c, kind, what);
    let same = St.fingerprintHash(s, later) == fp and DL.length(log) == len and TA.bytesUsed(s.arena) == arena
      and (s.nextHoldId, s.nextHoldLineId, s.nextBookingId, s.nextFolioId, s.nextPaymentId) == counters
      and (RowStore.size(blockT), RowStore.size(blockNightT), RowStore.size(nightBlockT), RowStore.size(bookingBlockT), RowStore.size(s.holds) + RowStore.size(s.bookings)) == rows;
    check(same, what # ": the refusal moved state");
    if (same) untouched += 1;
  };
  type Facts = { name : Text; companyId : Nat; roomTypeId : Nat; planId : Nat; arrival : Nat; nights : Nat; rooms : Nat; cutoff : Nat };
  let wedding : Facts = { name = "Hassan and Leila's wedding"; companyId = 0; roomTypeId = TT; planId = 1; arrival = T + 5; nights = 3; rooms = 4; cutoff = T };
  func blk(by : Principal, id : Nat, f : Facts) : Cmd.Command {
    #upsertBlock({ staff = by; id; name = f.name; companyId = f.companyId; roomTypeId = f.roomTypeId; planId = f.planId; arrival = f.arrival; nights = f.nights;
      rooms = f.rooms; cutoff = f.cutoff })
  };

  // the block, refused in every way it can be
  unchanged(BGUEST, blk(BGUEST, 0, wedding), "notAuthorised", "a guest adding a block");
  unchanged(DESKB, blk(DESKB, 0, wedding), "notAuthorised", "a receptionist adding a block");
  unchanged(REVB, blk(REVB, 0, { wedding with roomTypeId = 999 }), "noSuchRoomType", "a block of a room type that does not exist");
  unchanged(REVB, blk(REVB, 0, { wedding with planId = 999 }), "noSuchPlan", "a block on a plan that does not exist");
  unchanged(REVB, blk(REVB, 0, { wedding with companyId = 999 }), "invalid", "a block for a company that does not exist");
  unchanged(REVB, blk(REVB, 0, { wedding with planId = SP }), "closedRate", "a block on a plan sold only under codes");
  unchanged(REVB, blk(REVB, 0, { wedding with planId = NEG; companyId = NILE }), "closedRate", "a block on Acme's rate for another company");
  unchanged(REVB, blk(REVB, 0, { wedding with planId = NEG }), "closedRate", "a block on Acme's rate for no company");
  unchanged(REVB, blk(REVB, 0, { wedding with nights = 0 }), "stayLength", "a block of no night");
  unchanged(REVB, blk(REVB, 0, { wedding with nights = 32 }), "stayLength", "a block past 31 nights");
  unchanged(REVB, blk(REVB, 0, { wedding with rooms = 0 }), "invalid", "a block of no room");
  unchanged(REVB, blk(REVB, 0, { wedding with arrival = T - 1; cutoff = T - 1 }), "inThePast", "a block arriving yesterday");
  unchanged(REVB, blk(REVB, 0, { wedding with arrival = T + 238; cutoff = T }), "beyondHorizon", "a block past the hotel's horizon");
  unchanged(REVB, blk(REVB, 0, { wedding with cutoff = T + 6 }), "invalid", "a cut-off after the group's arrival");
  unchanged(REVB, blk(REVB, 0, { wedding with cutoff = T - 1 }), "inThePast", "a cut-off already past");
  unchanged(REVB, blk(REVB, 0, { wedding with name = "" }), "invalid", "a block with no name");
  unchanged(REVB, blk(REVB, 0, { wedding with name = Text.fromArray(Array.tabulate<Char>(121, func(_) { 'x' })) }), "tooLong", "a block name past 120 bytes");
  unchanged(REVB, blk(REVB, 0, { wedding with rooms = 7 }), "soldOut", "a block of more rooms than the nights have");
  unchanged(REVB, blk(REVB, 0, { wedding with arrival = T + 29 }), "nightClosed", "a block on nights not on sale");
  unchanged(REVB, blk(REVB, 99, wedding), "noSuchBlock", "a change to a block that does not exist");

  let G1 = ok(REVB, blk(REVB, 0, wedding), "the wedding's block")[0];
  check((switch (St.block(later, G1)) { case (?b) TA.get(s.arena, b.name) == wedding.name and b.open and b.rooms == 4 and b.departure == T + 8; case null false }), "the block's row");
  let nt5 = Option.unwrap(St.night(s, TT, T + 5));
  check(St.blockedOn(later, TT, T + 5) == 4 and St.freeOn(later, TT, T + 5, nt5) == 2 and nt5.sold == 0, "the block takes four rooms off sale and sells none");
  check((switch (Res.quoteStay(ctx(), stay(TT, 1, T + 5, 1, 3))) { case (#err (#soldOut { free })) free == 2; case _ false }), "the public sale sees two rooms left");
  // its changes: more rooms if free, never its dates
  ignore ok(REVB, blk(REVB, G1, { wedding with rooms = 5; name = "The Hassan wedding" }), "the block grows to five rooms and is renamed");
  check(St.blockedOn(later, TT, T + 6) == 5, "five rooms held");
  unchanged(REVB, blk(REVB, G1, { wedding with rooms = 8 }), "soldOut", "a block grown past the free rooms");
  unchanged(REVB, blk(REVB, G1, { wedding with rooms = 5; arrival = T + 6 }), "invalid", "a block moved to other dates");
  unchanged(REVB, blk(REVB, G1, { wedding with rooms = 5; planId = 2 }), "invalid", "a block moved to another plan");

  // the company's block: Acme's rate, picked up under Acme's access
  let acmeBlock : Facts = { name = "Acme sales conference"; companyId = ACME; roomTypeId = TT; planId = NEG; arrival = T + 12; nights = 2; rooms = 1; cutoff = T + 2 };
  let G2 = ok(REVB, blk(REVB, 0, acmeBlock), "Acme's block on its own rate")[0];

  // the pickups: through stop-sell and a minimum stay, which close the nights to the public sale
  ignore ok(OWNER, #setNights({ staff = OWNER; edit = { roomTypeId = TT; fromDay = T + 5; toDay = T + 8; weekdays = 127; allotment = null; bar = null; minStay = ?3; maxStay = null;
    closedToArrival = null; closedToDeparture = null; stopSell = ?true } }), "the wedding nights stopped for sale, three nights at least");
  func quote(f : Facts, arrival : Nat, nights : Nat, rooms : Nat) : Q.Quote {
    let grant : Acc.Grant = { companyId = f.companyId; promoId = 0 };
    switch (Res.checkStayAs(ctx(), Res.newPending(), stay(f.roomTypeId, f.planId, arrival, nights, rooms), null, grant, true)) {
      case (#ok c) c.quote; case (#err r) Runtime.trap("a pickup's quote: " # debug_show r)
    }
  };
  func pickUp(by : Principal, id : Nat, f : Facts, arrival : Nat, nights : Nat, rooms : Nat, hash : Blob, k : Nat8) : Cmd.Command {
    #pickUpFromBlock({ staff = by; blockId = id; stay = stay(f.roomTypeId, f.planId, arrival, nights, rooms); quoteHash = hash; guestName = "Guest of the group";
      guestEmail = ""; note = "group"; manageKey = key(k) })
  };
  check((switch (Res.quoteStay(ctx(), stay(TT, 1, T + 5, 3, 1))) { case (#err _) true; case (#ok _) false }), "the public sale is refused the stopped nights");
  let q1 = quote(wedding, T + 5, 2, 2);
  unchanged(BGUEST, pickUp(BGUEST, G1, wedding, T + 5, 2, 2, q1.hash, 90), "notAuthorised", "a guest picking up from a block");
  unchanged(REVB, pickUp(REVB, G1, wedding, T + 5, 2, 2, q1.hash, 90), "notAuthorised", "revenue picking up from a block");
  unchanged(DESKB, pickUp(DESKB, 99, wedding, T + 5, 2, 2, q1.hash, 90), "noSuchBlock", "a pickup from a block that does not exist");
  unchanged(DESKB, pickUp(DESKB, G1, { wedding with planId = 2 }, T + 5, 2, 2, q1.hash, 90), "invalid", "a pickup on another plan");
  unchanged(DESKB, pickUp(DESKB, G1, wedding, T + 4, 2, 2, q1.hash, 90), "invalid", "a pickup arriving before the block");
  unchanged(DESKB, pickUp(DESKB, G1, wedding, T + 7, 2, 2, q1.hash, 90), "invalid", "a pickup leaving after the block");
  unchanged(DESKB, pickUp(DESKB, G1, wedding, T + 5, 2, 2, "\00", 90), "priceChanged", "a pickup at a price it was not shown");
  let P1 = ok(DESKB, pickUp(DESKB, G1, wedding, T + 5, 2, 2, q1.hash, 91), "two rooms for the bride's family, two nights")[0];
  let P2 = ok(DESKB, pickUp(DESKB, G1, wedding, T + 5, 3, 1, quote(wedding, T + 5, 3, 1).hash, 92), "one room for the groom, three nights")[0];
  let P3 = ok(DESKB, pickUp(DESKB, G1, wedding, T + 6, 1, 2, quote(wedding, T + 6, 1, 2).hash, 93), "two rooms for the band, one night")[0];
  unchanged(DESKB, pickUp(DESKB, G1, wedding, T + 6, 1, 1, q1.hash, 94), "blockFull", "a pickup on a night the block has given out");
  check((switch (St.staffBooking(later, P1)) { case (?x) x.channel == #group and x.madeBy == DESKB; case null false }) and St.bookingBlock(later, P2) != null
    and (switch (St.bookingBlock(later, P3)) { case (?x) x.blockId == G1; case null false }), "each pickup is the group's and on the block's rooming list");
  check((switch (St.blockNight(later, G1, T + 6)) { case (?bn) bn.picked == 5 and bn.open == 0; case null false })
    and (switch (St.blockNight(later, G1, T + 7)) { case (?bn) bn.picked == 1 and bn.open == 4; case null false }), "the block's nights count the rooms picked up");
  let nt6 = Option.unwrap(St.night(s, TT, T + 6));
  check(nt6.sold == 5 and St.blockedOn(later, TT, T + 6) == 0 and St.freeOn(later, TT, T + 6, nt6) == 1, "a pickup moves rooms from the block to sold, and the free room stays free");
  check((switch (St.booking(s, P3)) { case (?b) b.status == #confirmed; case null false }), "a pickup is a confirmed booking");
  check(St.bookingRate(later, P1) == null, "a pickup on a public plan keeps no access");
  // a pickup on Acme's block is sold at Acme's rate under Acme's access
  let qa = quote(acmeBlock, T + 12, 2, 1);
  let PA = ok(DESKB, pickUp(DESKB, G2, acmeBlock, T + 12, 2, 1, qa.hash, 95), "Acme's guest picked up")[0];
  check((switch (St.bookingRate(later, PA)) { case (?r) r.companyId == ACME; case null false }), "Acme's pickup keeps Acme's access");
  // a pickup is not changed: cancelled and picked up again
  unchanged(BGUEST, #modifyBooking({ by = #manageKey; bookingId = P2; stay = stay(TT, 1, T + 5, 2, 1); quoteHash = q1.hash; auth = null }), "invalid", "a change to a pickup");
  ignore ok(BGUEST, #cancelBooking({ by = #manageKey; bookingId = P1 }), "the bride's family cancels");
  check((switch (St.blockNight(later, G1, T + 5)) { case (?bn) bn.picked == 1 and bn.open == 4; case null false }) and St.blockedOn(later, TT, T + 5) == 4,
    "a cancelled pickup's rooms go back to the open block");
  unchanged(REVB, blk(REVB, G1, { wedding with rooms = 2 }), "invalid", "a block shrunk below its pickups");
  ignore ok(REVB, blk(REVB, G1, { wedding with rooms = 3; name = "The Hassan wedding" }), "the block shrunk to three rooms");
  check(St.blockedOn(later, TT, T + 5) == 2 and St.blockedOn(later, TT, T + 6) == 0, "a smaller block gives its rooms not picked up back to sale");
  ignore ok(OWNER, #setNights({ staff = OWNER; edit = { roomTypeId = TT; fromDay = T + 5; toDay = T + 8; weekdays = 127; allotment = null; bar = null; minStay = ?1; maxStay = null;
    closedToArrival = null; closedToDeparture = null; stopSell = ?false } }), "the wedding nights back on sale");

  // released by revenue: the rooms back on sale, the pickups kept
  ignore ok(REVB, #releaseBlock({ staff = REVB; id = G2 }), "Acme's block released early");
  check(St.blockedOn(later, TT, T + 12) == 0 and (switch (St.blockNight(later, G2, T + 12)) { case (?bn) bn.picked == 1 and bn.open == 0; case null false }), "a released block holds nothing and keeps its pickup");
  unchanged(REVB, #releaseBlock({ staff = REVB; id = G2 }), "blockReleased", "a block released twice");
  unchanged(DESKB, #releaseBlock({ staff = DESKB; id = G1 }), "notAuthorised", "a receptionist releasing a block");
  unchanged(REVB, #releaseBlock({ staff = REVB; id = 99 }), "noSuchBlock", "a release of a block that does not exist");
  unchanged(DESKB, pickUp(DESKB, G2, acmeBlock, T + 12, 1, 1, qa.hash, 96), "blockReleased", "a pickup from a released block");
  unchanged(REVB, blk(REVB, G2, acmeBlock), "blockReleased", "a change to a released block");
  ignore ok(BGUEST, #cancelBooking({ by = #manageKey; bookingId = PA }), "Acme's guest cancels after the release");
  check((switch (St.blockNight(later, G2, T + 12)) { case (?bn) bn.picked == 0 and bn.open == 0; case null false }) and St.blockedOn(later, TT, T + 12) == 0,
    "a pickup cancelled after the release goes back to sale, not to the block");
  law("after the pickups");
  let w0 = walk();
  check(List.size(w0.violations) == 0, "the oracle is empty after the pickups: " # debug_show List.toArray(w0.violations));

  // the night audit at the wedding's cut-off gives its rooms back to sale
  ignore ok(OWNER, #openAudit({ staff = OWNER; day = T }), "the audit of the cut-off day");
  check((switch (St.auditBlocks(later, T)) { case (?a) a.due == 1; case null false }), "the audit counts one block due");
  var steps = 0;
  label run loop {
    switch (send(OWNER, #advanceAudit({ staff = OWNER; day = T; limit = 8 }))) {
      case (#ok _) { steps += 1; if (steps > 200) break run };
      case (#err _) break run;
    };
  };
  ignore ok(OWNER, #closeDay({ staff = OWNER; day = T }), "the cut-off day closed");
  check((switch (St.block(later, G1)) { case (?b) not b.open; case null false }) and St.blockedOn(later, TT, T + 5) == 0 and St.blockedOn(later, TT, T + 7) == 0,
    "the audit released the wedding's block at its cut-off");
  check((switch (St.blockNight(later, G1, T + 6)) { case (?bn) bn.picked == 3 and bn.open == 0; case null false }), "and kept its pickups");
  law("after the cut-off");
  let w1 = walk();
  check(List.size(w1.violations) == 0, "the oracle is empty after the cut-off: " # debug_show List.toArray(w1.violations));

  // the controls: each law of I15, shown a fault of its own, and nothing outside I15 red
  var blockControls = 0;
  func i15(words : Text) : Bool {
    var hit = false; var stray = false;
    for (v in List.values(walk().violations)) { if (Text.startsWith(v, #text "I15 blocks")) { if (Text.contains(v, #text words)) hit := true } else stray := true };
    hit and not stray
  };
  func control(caught : Bool, what : Text) { check(caught, what); if (caught) blockControls += 1 };
  func walkHas(rule : Text, words : Text) : Bool {
    for (v in List.values(walk().violations)) { if (Text.startsWith(v, #text rule) and Text.contains(v, #text words)) return true };
    false
  };
  let b1 = Option.unwrap(St.block(later, G1));
  let bn6 = Option.unwrap(St.blockNight(later, G1, T + 6));
  RowStore.put<R.BlockNight>(blockNightT, R.blockNight, R.blockNightId(G1, T + 6), { bn6 with picked = 4 });
  control(i15("picked up says 4, its bookings hold 3"), "a block night counting a pickup no booking holds is named I15");
  RowStore.put<R.BlockNight>(blockNightT, R.blockNight, R.blockNightId(G1, T + 6), { bn6 with open = 1 });
  control(i15("still holds 1 rooms; released, it holds 0"), "a released block still holding a room is named I15");
  RowStore.put<R.BlockNight>(blockNightT, R.blockNight, R.blockNightId(G1, T + 6), { bn6 with night = R.nightId(TT, T + 7) });
  control(i15("is on another hotel night"), "a block night on the wrong hotel night is named I15");
  RowStore.put<R.BlockNight>(blockNightT, R.blockNight, R.blockNightId(G1, T + 6), bn6);
  RowStore.put<R.Block>(blockT, R.block, G1, { b1 with rooms = 2 });
  control(i15("3 rooms picked up of 2"), "a block with more rooms picked up than it holds is named I15");
  RowStore.put<R.Block>(blockT, R.block, G1, { b1 with open = true });
  control(i15("still holds 0 rooms; open, it holds"), "an open block holding less than its rooms not picked up is named I15");
  RowStore.put<R.Block>(blockT, R.block, G1, { b1 with cutoff = b1.arrival + 1 });
  control(i15("cut-off is after its arrival"), "a cut-off after the arrival is named I15");
  RowStore.put<R.Block>(blockT, R.block, G1, { b1 with planId = 999 });
  control(i15("is sold at plan 999, which does not exist"), "a block on a plan that does not exist is named I15");
  RowStore.put<R.Block>(blockT, R.block, G1, { b1 with companyId = 999 });
  control(i15("names company 999, which does not exist"), "a block for a company that does not exist is named I15");
  RowStore.put<R.Block>(blockT, R.block, G1, { b1 with arrival = b1.arrival + 1 });
  control(i15("runs outside block"), "a pickup outside its block's dates is named I15");
  RowStore.put<R.Block>(blockT, R.block, G1, b1);
  // rows already there only: a row added beside the fold could not be taken away again
  let nb7 = Option.unwrap(RowStore.get<R.NightBlock>(nightBlockT, R.nightBlock, R.nightId(TT, T + 7)));
  RowStore.put<R.NightBlock>(nightBlockT, R.nightBlock, R.nightId(TT, T + 7), { nb7 with open = 1 });
  control(i15("held by blocks says 1, its blocks hold 0"), "a hotel night held by no block is named I15");
  RowStore.put<R.NightBlock>(nightBlockT, R.nightBlock, R.nightId(TT, T + 7), nb7);
  let nb6 = Option.unwrap(RowStore.get<R.NightBlock>(nightBlockT, R.nightBlock, R.nightId(TT, T + 6)));
  RowStore.put<R.NightBlock>(nightBlockT, R.nightBlock, R.nightId(TT, T + 6), { nb6 with open = 7 });
  control(walkHas("I1 capacity", "held by blocks 7"), "the rooms held by blocks past the allotment are named I1");
  RowStore.put<R.NightBlock>(nightBlockT, R.nightBlock, R.nightId(TT, T + 6), nb6);
  let sb3 = Option.unwrap(St.staffBooking(later, P3));
  RowStore.put<R.StaffBooking>(St.later(later, St.STAFF_BOOKING_TABLE), R.staffBooking, P3, { sb3 with channel = #phone });
  control(i15("was taken phone, not from the group's list"), "a pickup taken by phone is named I15");
  RowStore.put<R.StaffBooking>(St.later(later, St.STAFF_BOOKING_TABLE), R.staffBooking, P3, sb3);
  let bb3 = Option.unwrap(St.bookingBlock(later, P3));
  RowStore.put<R.BookingBlock>(bookingBlockT, R.bookingBlock, P3, { bb3 with blockId = 99 });
  control(i15("block 99 does not exist"), "a pickup from a block that does not exist is named I15");
  RowStore.put<R.BookingBlock>(bookingBlockT, R.bookingBlock, P3, bb3);
  let bk3 = Option.unwrap(St.booking(s, P3));
  RowStore.put<R.Booking>(s.bookings, R.booking, P3, { bk3 with planId = 2 });
  control(walkHas("I15 blocks", "is not block " # Nat.toText(G1) # "'s room type and plan"), "a pickup on another plan is named I15");
  RowStore.put<R.Booking>(s.bookings, R.booking, P3, bk3);
  check(List.size(walk().violations) == 0, "every block control was removed");
  Debug.print("count: block refusals that left the state untouched = " # Nat.toText(untouched));
  Debug.print("count: block controls that went red for their own rule = " # Nat.toText(blockControls));
  Debug.print("count: block audit steps = " # Nat.toText(steps));
};

// ── packages ─────────────────────────────────────────────────────────────────
//
// A package plan sells the room with extras from the catalogue: each inclusion is its own line on the
// bill, taxed by the extra's own flag, at the price the quote froze, per room, per adult or per guest,
// every night or on the arrival night. The guarantee and the no-show penalty are the room's alone. A
// change before arrival voids the old package and sells the new one; in house, an extension adds the
// every-night inclusions at the catalogue price of the day and a shortening voids the nights given
// back; the desk cannot void one line of a package. Each refusal is compared on five dimensions; then
// each law of I18 is shown a fault of its own.

do {
  let T = today();
  let REVP = who(80);
  let DESKP = who(81);
  ignore ok(OWNER, #grantRole({ staff = OWNER; subject = REVP; role = #revenue }), "a revenue manager for the packages");
  ignore ok(OWNER, #grantRole({ staff = OWNER; subject = DESKP; role = #frontDesk }), "a receptionist for the packages");
  ignore ok(OWNER, #upsertRoomType({ staff = OWNER; id = 0; facts = { code = "PATIO"; nameEn = "Patio"; nameAr = "فناء"; descEn = ""; descAr = ""; sizeSqm = 36; maxAdults = 2;
    maxChildren = 1; maxOccupancy = 3; bedKind = #king; bedCount = 1; amenities = 1; photos = "almar/sea-room"; rank = 13; active = true } }), "the patio room type");
  let GT = s.nextRoomTypeId - 1;
  let ROOM1 = s.nextRoomId;
  for (n in ["4001", "4002", "4003"].vals()) ignore ok(OWNER, #upsertRoom({ staff = OWNER; id = 0; roomTypeId = GT; number = n; outOfOrder = false }), "room " # n);
  ignore ok(OWNER, #setNights({ staff = OWNER; edit = { roomTypeId = GT; fromDay = T; toDay = T + 30; weekdays = 127; allotment = ?3; bar = ?10_000; minStay = null; maxStay = null;
    closedToArrival = null; closedToDeparture = null; stopSell = null } }), "the patio nights");
  ignore ok(OWNER, #upsertRatePlan({ staff = OWNER; id = 0; facts = { code = "BB"; nameEn = "Bed and breakfast"; nameAr = "مبيت وإفطار"; kind = #bar; discountBps = 0;
    refundable = true; freeCancelDaysBefore = 1; penaltyNights = 1; guarantee = #firstNightAuthorised; modifiable = true; active = true } }), "the bed-and-breakfast plan");
  let BB = s.nextPlanId - 1;
  func extraFacts(code : Text, cat : E.ExtraCategory, price : Nat, taxed : Bool, active : Bool) : Cmd.ExtraFacts {
    { code; nameEn = code; nameAr = code; category = cat; price; taxed; active }
  };
  func extra(code : Text, cat : E.ExtraCategory, price : Nat, taxed : Bool, active : Bool) : Nat {
    let e = ok(OWNER, #upsertExtra({ staff = OWNER; id = 0; facts = extraFacts(code, cat, price, taxed, active) }), "the extra " # code);
    if (e.size() > 0) e[0] else 0
  };
  let BF = extra("PKG-BREAKFAST", #breakfast, 1_200, true, true);
  let TR = extra("PKG-TRANSFER", #other, 2_500, false, true);
  let SPA = extra("PKG-SPA", #spa, 4_000, true, true);
  let WAT = extra("PKG-WATER", #minibar, 300, true, true);
  let OPEN = extra("PKG-BAR", #restaurant, 0, true, true);
  let GONE = extra("PKG-OLD", #other, 900, false, false);
  func breakfastAt(price : Nat) { ignore ok(OWNER, #upsertExtra({ staff = OWNER; id = BF; facts = extraFacts("PKG-BREAKFAST", #breakfast, price, true, true) }), "breakfast at " # Nat.toText(price)) };

  let incT = St.later(later, St.PLAN_INCLUSION_TABLE);
  let pkT = St.later(later, St.PACKAGE_LINE_TABLE);
  let hpT = St.later(later, St.HOLD_PACKAGE_TABLE);
  let chargeT = St.later(later, St.CHARGE_TABLE);
  var untouched = 0;
  // the refusal must be the rule under test: its kind, and words of its own reason
  func unchanged(caller : Principal, c : Cmd.Command, kind : Text, words : Text, what : Text) {
    let fp = St.fingerprintHash(s, later);
    let len = DL.length(log);
    let arena = TA.bytesUsed(s.arena);
    let counters = (s.nextHoldId, s.nextHoldLineId, s.nextBookingId, s.nextFolioId, s.nextPaymentId);
    let rows = (RowStore.size(incT), RowStore.size(pkT), RowStore.size(hpT), RowStore.size(chargeT), RowStore.size(s.holds) + RowStore.size(s.bookings));
    switch (send(caller, c)) {
      case (#ok _) check(false, what # ": accepted, expected " # kind);
      case (#err r) check(Con.kindOf(r) == kind and Text.contains(Con.textOf(r), #text words),
        what # ": refused as " # Con.kindOf(r) # " (" # Con.textOf(r) # "), expected " # kind # " saying \"" # words # "\"");
    };
    let same = St.fingerprintHash(s, later) == fp and DL.length(log) == len and TA.bytesUsed(s.arena) == arena
      and (s.nextHoldId, s.nextHoldLineId, s.nextBookingId, s.nextFolioId, s.nextPaymentId) == counters
      and (RowStore.size(incT), RowStore.size(pkT), RowStore.size(hpT), RowStore.size(chargeT), RowStore.size(s.holds) + RowStore.size(s.bookings)) == rows;
    check(same, what # ": the refusal moved state");
    if (same) untouched += 1;
  };
  func inc(extraId : Nat, quantity : Nat, rhythm : E.Rhythm, per : E.Per) : Cmd.InclusionFacts { { extraId; quantity; rhythm; per } };
  func setInc(by : Principal, planId : Nat, inclusions : [Cmd.InclusionFacts]) : Cmd.Command { #setPlanInclusions({ staff = by; planId; inclusions }) };
  // breakfast for every guest every night, the airport transfer once a room, the spa once an adult
  let package = [inc(BF, 1, #everyNight, #guest), inc(TR, 1, #arrivalNight, #room), inc(SPA, 1, #arrivalNight, #adult)];

  // the package, refused in every way it can be
  unchanged(DESKP, setInc(DESKP, BB, package), "notAuthorised", "", "a receptionist setting a package");
  unchanged(REVP, setInc(REVP, BB, package), "notAuthorised", "", "revenue setting a package (a package is part of its plan, the owner's)");
  unchanged(OWNER, setInc(OWNER, 999, package), "noSuchPlan", "", "a package on a plan that does not exist");
  unchanged(OWNER, setInc(OWNER, BB, [inc(999, 1, #everyNight, #room)]), "noSuchExtra", "", "a package of an extra that does not exist");
  unchanged(OWNER, setInc(OWNER, BB, [inc(GONE, 1, #everyNight, #room)]), "inactive", "", "a package of an extra no longer sold");
  unchanged(OWNER, setInc(OWNER, BB, [inc(OPEN, 1, #everyNight, #room)]), "invalid", "needs a set price", "a package of an extra priced when it is posted");
  unchanged(OWNER, setInc(OWNER, BB, [inc(BF, 0, #everyNight, #guest)]), "invalid", "1 to 9", "an inclusion of none of its extra");
  unchanged(OWNER, setInc(OWNER, BB, [inc(BF, 10, #everyNight, #guest)]), "invalid", "1 to 9", "an inclusion of ten of its extra");
  unchanged(OWNER, setInc(OWNER, BB, [inc(BF, 1, #everyNight, #guest), inc(BF, 2, #arrivalNight, #room)]), "invalid", "once", "an extra in a package twice");
  unchanged(OWNER, setInc(OWNER, BB, Array.tabulate<Cmd.InclusionFacts>(9, func(i) { inc(BF, 1 + i % 9, #everyNight, #room) })), "invalid", "at most 8",
    "a package of nine inclusions");
  // four inclusions, then three: the fourth is turned off, its row kept
  check(ok(OWNER, setInc(OWNER, BB, Array.concat(package, [inc(WAT, 2, #everyNight, #room)])), "a package of four") == [BB, 4], "the package of four is set");
  check(ok(OWNER, setInc(OWNER, BB, package), "the package of three") == [BB, 3], "the package of three is set");
  check(St.inclusionsOf(later, BB).size() == 3
    and (switch (RowStore.get<R.PlanInclusion>(incT, R.planInclusion, R.inclusionId(BB, 4))) { case (?r) not r.on and r.extraId == WAT; case null false }),
    "a package set again turns its fourth inclusion off and keeps the row");
  law("after the package is set");

  // the quote: the room as a plain rate, and one line per inclusion per night it is given
  func st(arrival : Nat, nights : Nat, rooms : Nat, adults : Nat, children : Nat) : Cmd.Stay { { roomTypeId = GT; planId = BB; arrival; nights; rooms; adults; children } };
  func q(x : Cmd.Stay) : Q.Quote { switch (Res.quoteStay(ctx(), x)) { case (#ok c) c.quote; case (#err r) Runtime.trap("a package quote: " # debug_show r) } };
  func taxOf(l : Q.IncLine) : Nat { var t = 0; for ((_, a) in l.taxes.vals()) t += a; t };
  let st1 = st(T + 4, 2, 1, 2, 1);
  let q1 = q(st1);
  check(q1.roomSubtotal == 20_000 and q1.taxTotal == 2_000 + 440, "the package's room is priced as a plain rate: 200.00 and 24.40 of taxes, got " # debug_show (q1.roomSubtotal, q1.taxTotal));
  check(q1.inclusions.size() == 4, "breakfast on both nights, the transfer and the spa on the arrival night: four lines, got " # Nat.toText(q1.inclusions.size()));
  var linesRight = 0;
  for (l in q1.inclusions.vals()) {
    let right = if (l.extraId == BF) l.quantity == 3 and l.unit == 1_200 and l.net == 3_600 and l.taxes == [(1, 360)]
      else if (l.extraId == TR) l.night == T + 4 and l.quantity == 1 and l.net == 2_500 and l.taxes.size() == 0
      else if (l.extraId == SPA) l.night == T + 4 and l.quantity == 2 and l.net == 8_000 and l.taxes == [(1, 800)]
      else false;
    check(right, "the package line " # debug_show l);
    if (right) linesRight += 1;
  };
  check(q1.packageTotal == 7_920 + 2_500 + 8_800 and q1.total == 22_440 + 19_220,
    "breakfast for three guests 79.20 with VAT, the transfer 25.00 untaxed, the spa for two adults 88.00 with VAT: 192.20 on 224.40, got " # debug_show (q1.packageTotal, q1.total));
  // per room, per adult, per guest: two rooms, three adults and a child
  let q2 = q(st(T + 4, 1, 2, 3, 1));
  check((switch (Array.find<Q.IncLine>(q2.inclusions, func(l) { l.extraId == TR })) { case (?l) l.quantity == 2; case null false })
    and (switch (Array.find<Q.IncLine>(q2.inclusions, func(l) { l.extraId == SPA })) { case (?l) l.quantity == 3; case null false })
    and (switch (Array.find<Q.IncLine>(q2.inclusions, func(l) { l.extraId == BF })) { case (?l) l.quantity == 4; case null false }),
    "two rooms, three adults and a child: two transfers, three spa visits, four breakfasts");
  // the same stay on a plain plan: no package, and the room priced the same
  let plain = q({ st1 with planId = 1 });
  check(plain.inclusions.size() == 0 and plain.packageTotal == 0 and plain.total == 22_440 and plain.hash != q1.hash, "the flexible plan sells the room alone, at the same price");
  let bbPlan = Option.unwrap(St.plan(s, BB));
  check(Res.guaranteeOf(later, BB, bbPlan, q1) == 11_220, "the guarantee is the room's first night with its taxes, no breakfast: 112.20, got " # Nat.toText(Res.guaranteeOf(later, BB, bbPlan, q1)));

  // the hold carries the package, and the confirmation puts each inclusion on the bill
  let G1 = who(82);
  let h1 = switch (send(G1, #placeHold({ owner = G1; stay = st1; quoteHash = q1.hash; key = key(101) }))) { case (#ok a) a.effects[0]; case (#err r) { check(false, "the package hold: " # Con.textOf(r)); 0 } };
  var heldPackage = 0;
  for ((lid, _) in St.holdLinesOf(s, h1).vals()) { if (St.holdPackage(later, lid) != null) heldPackage += 1 };
  check(heldPackage == 4 and (switch (St.hold(s, h1)) { case (?h) h.quotedTotal == q1.total; case null false }), "the hold holds the package's four lines at the quoted total");
  func confirm(g : Principal, holdId : Nat, k : Nat8, authId : Nat, amount : Nat) : Cmd.Command {
    #confirmHold({ owner = g; holdId; guestName = "Mona Saleh"; guestEmail = "lxe1.package"; note = ""; manageKey = key(k); account = null;
      auth = { authId; amount; currency = "EUR"; merchantRef = holdId } })
  };
  unchanged(G1, confirm(G1, h1, 102, 801, 11_220 + 3_960), "payment", "", "a guarantee that takes the first breakfast with the room");
  let B1 = ok(G1, confirm(G1, h1, 102, 801, 11_220), "the package stay is confirmed on the room's first night")[0];
  let bk1 = Option.unwrap(St.booking(s, B1));
  check(bk1.charged == q1.total and bk1.penalty == 11_220, "the bill is the package's total, and the late-cancellation penalty is the room's first night: " # debug_show (bk1.charged, bk1.penalty));
  func taxesPosted(lid : Nat, pk : R.PackageLine) : Nat {
    var t = 0;
    for (i in Nat.range(lid + 1, lid + pk.taxLines + 1)) { switch (St.folioLine(s, i)) { case (?l) { if (l.kind == #extraTax) t += l.amount }; case null {} } };
    t
  };
  // the bill's package lines are the quote's, one for one: night, extra, quantity, price, taxes, poster
  func asQuoted(bookingId : Nat, qq : Q.Quote, what : Text) {
    let live = Res.livePackage(ctx(), bookingId, 0);
    var same = live.size() == qq.inclusions.size();
    var i = 0;
    for ((lid, l, pk, ch) in live.vals()) {
      if (i < qq.inclusions.size()) {
        let ql = qq.inclusions[i];
        if (l.night != ql.night or l.amount != ql.net or pk.extraId != ql.extraId or pk.quantity != ql.quantity or pk.unitAmount != ql.unit
          or taxesPosted(lid, pk) != taxOf(ql) or ch.postedBy != Res.packagePoster() or ch.extraId != ql.extraId) same := false;
      };
      i += 1;
    };
    check(same, what # ": each package line on the bill is the quote's line (" # Nat.toText(live.size()) # " lines, " # Nat.toText(qq.inclusions.size()) # " quoted)");
  };
  asQuoted(B1, q1, "after the confirmation");
  law("after the package confirmation");
  check(List.size(walk().violations) == 0, "the oracle is empty after the package confirmation: " # debug_show List.toArray(walk().violations));

  // the catalogue price moves: a hold at the price shown before is refused
  breakfastAt(1_300);
  let G2 = who(83);
  unchanged(G2, #placeHold({ owner = G2; stay = st1; quoteHash = q1.hash; key = key(103) }), "priceChanged", "", "a package hold at the breakfast price before it went up");
  check(q(st1).total == q1.total + 2 * 330, "the same stay now costs 3.30 more a night: three breakfasts at 1.10 with VAT");

  // a change before arrival: the old package voided line by line, the new one sold at today's price
  let st1b = st(T + 4, 3, 1, 2, 1);
  let q1b = q(st1b);
  check(q1b.total == 33_660 + 12_870 + 2_500 + 8_800, "three nights: the room 336.60, breakfast 128.70, the transfer and the spa once, got " # Nat.toText(q1b.total));
  let old1 = Res.livePackage(ctx(), B1, 0);
  ignore ok(G1, #modifyBooking({ by = #manageKey; bookingId = B1; stay = st1b; quoteHash = q1b.hash; auth = null }), "the package stay grows to three nights before arrival");
  var oldVoided = 0;
  for ((lid, _, _, _) in old1.vals()) { switch (St.charge(later, lid)) { case (?ch) { if (ch.voidLine != 0) oldVoided += 1 }; case null {} } };
  check(oldVoided == 4, "the four lines of the old package are each voided, got " # Nat.toText(oldVoided));
  asQuoted(B1, q1b, "after the change before arrival");
  let bk1b = Option.unwrap(St.booking(s, B1));
  check(bk1b.charged == q1.total + q1b.total and bk1b.credited == q1.total and bk1b.penalty == 11_220, "the old stay credited whole, the new one charged: " # debug_show (bk1b.charged, bk1b.credited));
  let firstLine = old1[0].0;
  unchanged(OWNER, #propose({ staff = OWNER; act = #voidCharge({ bookingId = B1; lineId = Res.livePackage(ctx(), B1, 0)[0].0 }); justification = "breakfast not wanted" }),
    "invalid", "part of the guest's package", "a desk void of one line of a package");
  unchanged(OWNER, #propose({ staff = OWNER; act = #voidCharge({ bookingId = B1; lineId = firstLine }); justification = "again" }), "invalid", "already voided", "a desk void of a package line already voided");
  law("after the change before arrival");
  ignore ok(G1, #cancelBooking({ by = #manageKey; bookingId = B1 }), "the package stay cancelled in time");
  check((switch (St.booking(s, B1)) { case (?b) b.charged == b.credited and b.outstanding == 0; case null false }), "a free cancellation credits the room and the package whole");

  // in house: an extension adds the every-night inclusions at the price of the day; the arrival-night ones are not given again
  let G3 = who(84);
  let stH = st(T, 2, 1, 2, 0);
  let qH = q(stH);
  check(qH.total == 22_440 + 5_720 + 2_500 + 8_800, "two nights for two: the room 224.40, breakfast 57.20, the transfer and the spa, got " # Nat.toText(qH.total));
  let hH = switch (send(G3, #placeHold({ owner = G3; stay = stH; quoteHash = qH.hash; key = key(104) }))) { case (#ok a) a.effects[0]; case (#err r) { check(false, "the in-house hold: " # Con.textOf(r)); 0 } };
  let H = ok(G3, confirm(G3, hH, 105, 802, 11_220), "the stay arriving today is confirmed")[0];
  ignore ok(DESKP, #checkIn({ staff = DESKP; bookingId = H; roomIds = [ROOM1] }), "the package guest checks in");
  breakfastAt(1_400);
  let bH = Option.unwrap(St.booking(s, H));
  let qx = switch (Res.extensionQuote(ctx(), Res.newPending(), H, bH, T + 3)) { case (#ok x) x; case (#err r) Runtime.trap("the extension's quote: " # debug_show r) };
  check(qx.inclusions.size() == 1 and qx.inclusions[0].extraId == BF and qx.inclusions[0].night == T + 2 and qx.inclusions[0].unit == 1_400 and qx.inclusions[0].quantity == 2
    and qx.total == 11_220 + 3_080, "one night more: the room 112.20 and two breakfasts at 14.00 with VAT, no transfer and no spa, got " # debug_show (qx.inclusions.size(), qx.total));
  unchanged(G3, #modifyBooking({ by = #manageKey; bookingId = H; stay = st(T, 3, 1, 2, 0); quoteHash = qH.hash; auth = null }), "priceChanged", "", "an extension at a price not shown");
  ignore ok(G3, #modifyBooking({ by = #manageKey; bookingId = H; stay = st(T, 3, 1, 2, 0); quoteHash = qx.hash; auth = null }), "the package guest stays one night more");
  let liveH = Res.livePackage(ctx(), H, 0);
  func breakfasts() : [(Nat, R.FolioLine, R.PackageLine, R.Charge)] { Array.filter<(Nat, R.FolioLine, R.PackageLine, R.Charge)>(Res.livePackage(ctx(), H, 0), func(x) { x.2.extraId == BF }) };
  let bfs = breakfasts();
  check(liveH.size() == 5 and bfs.size() == 3 and bfs[0].2.unitAmount == 1_300 and bfs[1].2.unitAmount == 1_300 and bfs[2].2.unitAmount == 1_400 and bfs[2].1.night == T + 2,
    "the nights posted keep 13.00 and the night added is at 14.00");
  check((switch (St.booking(s, H)) { case (?b) b.charged == qH.total + qx.total and b.departure == T + 3; case null false }), "the night added is on the bill");
  unchanged(OWNER, #propose({ staff = OWNER; act = #voidCharge({ bookingId = H; lineId = bfs[1].0 }); justification = "no breakfast" }), "invalid", "part of the guest's package",
    "a desk void of a package line in house");
  law("after the extension");
  check(List.size(walk().violations) == 0, "the oracle is empty after the extension: " # debug_show List.toArray(walk().violations));

  // the controls: each law of I18, shown a fault of its own, and nothing outside I18 red
  var pkgControls = 0;
  func i18(words : Text) : Bool {
    var hit = false; var stray = false;
    for (v in List.values(walk().violations)) { if (Text.startsWith(v, #text "I18 packages")) { if (Text.contains(v, #text words)) hit := true } else stray := true };
    hit and not stray
  };
  func walkHas(rule : Text, words : Text) : Bool {
    for (v in List.values(walk().violations)) { if (Text.startsWith(v, #text rule) and Text.contains(v, #text words)) return true };
    false
  };
  func control(caught : Bool, what : Text) { check(caught, what); if (caught) pkgControls += 1 };
  let (mid, _, midPk, midCh) = bfs[1];
  let (lastId, lastLine, _, _) = bfs[2];
  let trLine = Option.unwrap(Array.find<(Nat, R.FolioLine, R.PackageLine, R.Charge)>(liveH, func(x) { x.2.extraId == TR }));
  RowStore.put<R.PackageLine>(pkT, R.packageLine, mid, { midPk with quantity = midPk.quantity + 1 });
  control(i18("its charge is not the inclusion sold"), "a package line whose charge is not the inclusion sold is named I18");
  RowStore.put<R.PackageLine>(pkT, R.packageLine, mid, { midPk with taxed = false });
  control(i18("is taxed, and its extra was not"), "a package line taxed when its extra was not is named I18");
  RowStore.put<R.PackageLine>(pkT, R.packageLine, mid, { midPk with rhythm = #arrivalNight });
  control(i18("is an arrival-night inclusion on night " # Nat.toText(T + 1)), "an arrival-night inclusion on another night is named I18");
  RowStore.put<R.PackageLine>(pkT, R.packageLine, mid, { midPk with slot = 7 });
  control(i18("and not the night after") and i18("and not the night before"), "a night missing from an every-night inclusion is named I18");
  RowStore.put<R.PackageLine>(pkT, R.packageLine, mid, midPk);
  RowStore.put<R.PackageLine>(pkT, R.packageLine, trLine.0, { trLine.2 with slot = midPk.slot });
  control(i18("is on night " # Nat.toText(T) # " twice"), "an inclusion twice on one night is named I18");
  RowStore.put<R.PackageLine>(pkT, R.packageLine, trLine.0, trLine.2);
  RowStore.put<R.Charge>(chargeT, R.charge, mid, { midCh with postedBy = DESKP });
  control(i18("was posted by a member of staff"), "a package line posted by staff is named I18");
  RowStore.put<R.Charge>(chargeT, R.charge, mid, midCh);
  RowStore.put<R.FolioLine>(s.folio, R.folioLine, lastId, { lastLine with night = T + 9 });
  control(walkHas("I18 packages", "is on night " # Nat.toText(T + 9) # ", outside booking " # Nat.toText(H)), "a package line outside its stay is named I18");
  RowStore.put<R.FolioLine>(s.folio, R.folioLine, lastId, lastLine);
  RowStore.put<R.Charge>(chargeT, R.charge, mid, { midCh with bookingId = B1 });
  control(walkHas("I18 packages", "is not an extra of its booking"), "a package line charged to another booking is named I18");
  RowStore.put<R.Charge>(chargeT, R.charge, mid, midCh);
  // the hold's package lines
  let (hl, _) = Option.unwrap(Array.find<(Nat, R.FolioLine)>(St.holdLinesOf(s, hH), func(x) { switch (St.holdPackage(later, x.0)) { case (?pk) pk.extraId == BF; case null false } }));
  let hpk = Option.unwrap(St.holdPackage(later, hl));
  RowStore.put<R.PackageLine>(hpT, R.holdPackage, hl, { hpk with unitAmount = hpk.unitAmount + 1 });
  control(i18("hold package line " # Nat.toText(hl) # " is 2600, and 2 × 1301 is 2602"), "a held package line not its quantity times its price is named I18");
  RowStore.put<R.PackageLine>(hpT, R.holdPackage, hl, { hpk with taxed = false });
  control(i18("hold package line " # Nat.toText(hl) # " is taxed, and its extra was not"), "a held package line taxed when its extra was not is named I18");
  RowStore.put<R.PackageLine>(hpT, R.holdPackage, hl, { hpk with taxLines = 2 });
  control(i18("is not its tax") or i18("its tax line " # Nat.toText(hl + 2) # " does not exist"), "a held package line naming a line that is not its tax is named I18");
  RowStore.put<R.PackageLine>(hpT, R.holdPackage, hl, hpk);
  // the plan's inclusions
  let inc1 = Option.unwrap(RowStore.get<R.PlanInclusion>(incT, R.planInclusion, R.inclusionId(BB, 1)));
  RowStore.put<R.PlanInclusion>(incT, R.planInclusion, R.inclusionId(BB, 1), { inc1 with quantity = 0 });
  control(i18("gives 0 of its extra"), "an inclusion of none of its extra is named I18");
  RowStore.put<R.PlanInclusion>(incT, R.planInclusion, R.inclusionId(BB, 1), { inc1 with extraId = 999 });
  control(i18("extra 999 does not exist"), "an inclusion of an extra that does not exist is named I18");
  RowStore.put<R.PlanInclusion>(incT, R.planInclusion, R.inclusionId(BB, 1), { inc1 with planId = BB + 1 });
  control(i18("is under the wrong plan or slot"), "an inclusion under another plan's id is named I18");
  RowStore.put<R.PlanInclusion>(incT, R.planInclusion, R.inclusionId(BB, 1), inc1);
  // rows already there only: a row added beside the fold could not be taken away again
  check(List.size(walk().violations) == 0, "every package control was removed");

  // a shortening voids the inclusions of the nights given back and credits them with the room
  let creditedBefore = Option.unwrap(St.booking(s, H)).credited;
  ignore ok(G3, #modifyBooking({ by = #manageKey; bookingId = H; stay = st(T, 1, 1, 2, 0); quoteHash = "\00"; auth = null }), "the package guest leaves after one night");
  check(breakfasts().size() == 1 and Res.livePackage(ctx(), H, 0).size() == 3, "the breakfasts of the two nights given back are voided; the first night's, the transfer and the spa stand");
  check((switch (St.booking(s, H)) { case (?b) b.credited == creditedBefore + 2 * 11_220 + 2_860 + 3_080 and b.departure == T + 1; case null false }),
    "two room nights and their breakfasts, at the price each was sold, credited back");
  law("after the shortening");
  check(List.size(walk().violations) == 0, "the oracle is empty after the shortening: " # debug_show List.toArray(walk().violations));

  // a no-show on a package: the penalty is the room's first night; the package is credited
  let G4 = who(85);
  let stN = st(T, 1, 1, 1, 0);
  let qN = q(stN);
  check(qN.total == 11_220 + 1_540 + 2_500 + 4_400, "one night for one: the room, a breakfast, the transfer and the spa, got " # Nat.toText(qN.total));
  let hN = switch (send(G4, #placeHold({ owner = G4; stay = stN; quoteHash = qN.hash; key = key(106) }))) { case (#ok a) a.effects[0]; case (#err r) { check(false, "the no-show's hold: " # Con.textOf(r)); 0 } };
  let N = ok(G4, confirm(G4, hN, 107, 803, 11_220), "a package stay arriving today, never to arrive")[0];
  ignore ok(OWNER, #openAudit({ staff = OWNER; day = T }), "the audit of the package day");
  var steps = 0;
  label run loop {
    switch (send(OWNER, #advanceAudit({ staff = OWNER; day = T; limit = 8 }))) {
      case (#ok _) { steps += 1; if (steps > 400) break run };
      case (#err _) break run;
    };
  };
  ignore ok(OWNER, #closeDay({ staff = OWNER; day = T }), "the package day closed");
  check((switch (St.booking(s, N)) { case (?b) b.status == #noShow and b.charged - b.credited == 11_220; case null false }),
    "the no-show keeps the room's first night and credits the package");
  law("after the package no-show");

  // the guest leaves on the day: settled at the desk, checked out, the inclusions on the bill as their own lines
  // the desk takes what the first night's authorisation does not cover, and every capture lands
  let open = Res.guestOpen(ctx(), H, Option.unwrap(St.booking(s, H)));
  check(open == Option.unwrap(St.booking(s, H)).outstanding - 11_220, "the desk is asked for the bill less the first night already authorised: " # Nat.toText(open));
  ignore ok(DESKP, #settleAtDesk({ staff = DESKP; bookingId = H; auth = { authId = 804; amount = open; currency = "EUR"; merchantRef = St.BOOKING_REF_BASE + H } }), "the package guest settles");
  for ((pid, pmt) in St.paymentsOf(s, H).vals()) {
    if (pmt.kind == #captured and pmt.state == #due) ignore ok(DESKP, #recordGatewayOutcome({ paymentId = pid; ok = true }), "a capture of the package stay lands");
  };
  ignore ok(DESKP, #checkOut({ staff = DESKP; bookingId = H }), "the package guest checks out");
  var items = 0;
  for ((lid, l) in St.folioOf(s, H).vals()) {
    switch (St.packageLine(later, lid), St.charge(later, lid)) { case (?_, ?ch) { if (ch.voidLine == 0 and l.kind == #extra) items += 1 }; case _ {} };
  };
  check(items == 3 and (switch (St.booking(s, H)) { case (?b) b.status == #checkedOut and b.outstanding == 0; case null false }),
    "checked out with breakfast, the transfer and the spa as three items of the bill");
  law("after the package check-out");
  check(List.size(walk().violations) == 0, "the oracle is empty after the package check-out: " # debug_show List.toArray(walk().violations));
  // a package stay still to come stays on the books, so the export carries live package lines
  let G5 = who(86);
  let stK = st(today() + 5, 3, 1, 2, 1);
  let qK = q(stK);
  let hK = switch (send(G5, #placeHold({ owner = G5; stay = stK; quoteHash = qK.hash; key = key(108) }))) { case (#ok a) a.effects[0]; case (#err r) { check(false, "the stay to come: " # Con.textOf(r)); 0 } };
  let K = ok(G5, confirm(G5, hK, 109, 805, Res.guaranteeOf(later, BB, bbPlan, qK)), "a package stay still to come")[0];
  asQuoted(K, qK, "the stay still to come");
  check(Res.livePackage(ctx(), K, 0).size() == 5, "three breakfasts, a transfer and a spa visit on the books");
  law("after the stay to come");
  check(List.size(walk().violations) == 0, "the oracle is empty with a package stay to come: " # debug_show List.toArray(walk().violations));
  Debug.print("count: package refusals that left the state untouched = " # Nat.toText(untouched));
  Debug.print("count: package controls that went red for their own rule = " # Nat.toText(pkgControls));
  Debug.print("count: package quote lines checked by hand = " # Nat.toText(linesRight));
  Debug.print("count: package audit steps = " # Nat.toText(steps));
};

// ── deposits and the card on file ────────────────────────────────────────────
//
// A deposit plan takes a whole percentage of the room's stay at confirmation. Once the hotel's card rule
// is on, every plan guaranteed by the first night or a deposit keeps the guest's card on file: the
// gateway's token, never a card, agreed by the guest at payment, or put on file later from the card link
// of a booking taken by phone (flagged on the desk's day list once its guarantee is due without one,
// never cancelled). At the night audit a no-show's penalty is captured from the guarantee as far as it
// goes and the rest charged once to the card on file; a decline stays outstanding, never tried again.
// The token is forgotten once the booking is settled. Each refusal is compared on five dimensions; then
// each law of I16 is shown a fault of its own.

do {
  let T = today();
  check(St.LATER_SECTIONS == St.laterTables(), "every later table is counted: " # Nat.toText(St.laterTables()));
  let DESKC = who(90);
  let REVC = who(91);
  let STRANGER = who(99);
  ignore ok(OWNER, #grantRole({ staff = OWNER; subject = DESKC; role = #frontDesk }), "a receptionist for the cards");
  ignore ok(OWNER, #grantRole({ staff = OWNER; subject = REVC; role = #revenue }), "a revenue manager for the cards");
  ignore ok(OWNER, #upsertRoomType({ staff = OWNER; id = 0; facts = { code = "COVE"; nameEn = "Cove"; nameAr = "خليج"; descEn = ""; descAr = ""; sizeSqm = 34; maxAdults = 2;
    maxChildren = 1; maxOccupancy = 3; bedKind = #king; bedCount = 1; amenities = 1; photos = "almar/sea-room"; rank = 14; active = true } }), "the cove room type");
  let CT = s.nextRoomTypeId - 1;
  let CROOM = s.nextRoomId;
  for (n in ["5001", "5002", "5003", "5004", "5005", "5006", "5007", "5008"].vals()) ignore ok(OWNER, #upsertRoom({ staff = OWNER; id = 0; roomTypeId = CT; number = n; outOfOrder = false }), "room " # n);
  ignore ok(OWNER, #setNights({ staff = OWNER; edit = { roomTypeId = CT; fromDay = T; toDay = T + 30; weekdays = 127; allotment = ?8; bar = ?10_000; minStay = null; maxStay = null;
    closedToArrival = null; closedToDeparture = null; stopSell = null } }), "the cove nights");
  func plan(code : Text, refundable : Bool, freeDays : Nat, penaltyNights : Nat, g : E.Guarantee) : Nat {
    ignore ok(OWNER, #upsertRatePlan({ staff = OWNER; id = 0; facts = { code; nameEn = code; nameAr = code; kind = #bar; discountBps = 0; refundable;
      freeCancelDaysBefore = freeDays; penaltyNights; guarantee = g; modifiable = true; active = true } }), "the plan " # code);
    s.nextPlanId - 1
  };
  let FN = plan("CARD-FN", true, 2, 2, #firstNightAuthorised);
  let DEP = plan("CARD-DEP", true, 3, 1, #firstNightAuthorised);
  let PRE = plan("CARD-PRE", false, 0, 0, #prepaidInFull);

  func bk0() : R.RatePlan { Option.unwrap(St.plan(s, DEP)) };
  let cardT = St.later(later, St.CARD_TABLE);
  let depT = St.later(later, St.PLAN_DEPOSIT_TABLE);
  let polT = St.later(later, St.CARD_POLICY_TABLE);
  var untouched = 0;
  func unchanged(caller : Principal, c : Cmd.Command, kind : Text, words : Text, what : Text) {
    let fp = St.fingerprintHash(s, later);
    let len = DL.length(log);
    let arena = TA.bytesUsed(s.arena);
    let counters = (s.nextHoldId, s.nextBookingId, s.nextFolioId, s.nextPaymentId, s.capturedDone + s.paidTotal + s.refundsCommitted);
    let rows = (RowStore.size(cardT), RowStore.size(depT), RowStore.size(polT), RowStore.size(s.payments), RowStore.size(s.bookings));
    switch (send(caller, c)) {
      case (#ok _) check(false, what # ": accepted, expected " # kind);
      case (#err r) check(Con.kindOf(r) == kind and Text.contains(Con.textOf(r), #text words),
        what # ": refused as " # Con.kindOf(r) # " (" # Con.textOf(r) # "), expected " # kind # " saying \"" # words # "\"");
    };
    let same = St.fingerprintHash(s, later) == fp and DL.length(log) == len and TA.bytesUsed(s.arena) == arena
      and (s.nextHoldId, s.nextBookingId, s.nextFolioId, s.nextPaymentId, s.capturedDone + s.paidTotal + s.refundsCommitted) == counters
      and (RowStore.size(cardT), RowStore.size(depT), RowStore.size(polT), RowStore.size(s.payments), RowStore.size(s.bookings)) == rows;
    check(same, what # ": the refusal moved state");
    if (same) untouched += 1;
  };
  func card(id : Nat) : R.CardOnFile { switch (St.card(later, id)) { case (?k) k; case null Runtime.trap("no card for booking " # Nat.toText(id)) } };
  func bk(id : Nat) : R.Booking { Option.unwrap(St.booking(s, id)) };
  func pay(id : Nat) : R.Payment { Option.unwrap(St.payment(s, id)) };
  func st(planId : Nat, arrival : Nat, nights : Nat) : Cmd.Stay { { roomTypeId = CT; planId; arrival; nights; rooms = 1; adults = 2; children = 0 } };
  func q(x : Cmd.Stay) : Q.Quote { switch (Res.quoteStay(ctx(), x)) { case (#ok c) c.quote; case (#err r) Runtime.trap("a card quote: " # debug_show r) } };
  var nextKey : Nat8 = 120;
  func placed(g : Principal, x : Cmd.Stay) : Nat {
    nextKey += 1;
    switch (send(g, #placeHold({ owner = g; stay = x; quoteHash = q(x).hash; key = key(nextKey) }))) { case (#ok a) a.effects[0]; case (#err r) { check(false, "a card hold: " # Con.textOf(r)); 0 } }
  };
  func onFile(g : Principal, holdId : Nat, authId : Nat, amount : Nat, token : Nat) : Cmd.Command {
    nextKey += 1;
    #confirmHoldOnFile({ owner = g; holdId; guestName = "Guest " # Nat.toText(holdId); guestEmail = "lxe1.card"; note = ""; manageKey = key(nextKey); account = null;
      auth = { authId; amount; currency = "EUR"; merchantRef = holdId }; token })
  };
  func noCard(g : Principal, holdId : Nat, authId : Nat, amount : Nat) : Cmd.Command {
    nextKey += 1;
    #confirmHold({ owner = g; holdId; guestName = "Guest " # Nat.toText(holdId); guestEmail = "lxe1.card"; note = ""; manageKey = key(nextKey); account = null;
      auth = { authId; amount; currency = "EUR"; merchantRef = holdId } })
  };
  func byPhone(planId : Nat, arrival : Nat, nights : Nat, name : Text) : Nat {
    let x = st(planId, arrival, nights);
    nextKey += 1;
    ok(DESKC, #bookByStaff({ staff = DESKC; channel = #phone; stay = x; quoteHash = q(x).hash; guestName = name; guestEmail = ""; note = ""; manageKey = key(nextKey); roomIds = [] }),
      "a booking by phone for " # name)[0]
  };
  func land(id : Nat, kind : E.PaymentKind) {
    for ((pid, p) in St.paymentsOf(s, id).vals()) { if (p.kind == kind and p.state == #due) ignore ok(DESKC, #recordGatewayOutcome({ paymentId = pid; ok = true }), "a payment of " # Nat.toText(id) # " lands") };
  };
  func clean(what : Text) {
    law(what);
    check(List.size(walk().violations) == 0, "the oracle is empty " # what # ": " # debug_show List.toArray(walk().violations));
  };

  // the deposit, refused in every way it can be, then set
  unchanged(DESKC, #setPlanDeposit({ staff = DESKC; planId = DEP; depositBps = 3_000 }), "notAuthorised", "", "a receptionist setting a deposit");
  unchanged(REVC, #setPlanDeposit({ staff = REVC; planId = DEP; depositBps = 3_000 }), "notAuthorised", "", "revenue setting a deposit (a plan's guarantee is the owner's)");
  unchanged(OWNER, #setPlanDeposit({ staff = OWNER; planId = 999; depositBps = 3_000 }), "noSuchPlan", "", "a deposit on a plan that does not exist");
  unchanged(OWNER, #setPlanDeposit({ staff = OWNER; planId = PRE; depositBps = 3_000 }), "invalid", "paid in advance", "a deposit on a plan paid in advance");
  unchanged(OWNER, #setPlanDeposit({ staff = OWNER; planId = DEP; depositBps = 50 }), "invalid", "whole percentage", "a deposit of half a per cent");
  unchanged(OWNER, #setPlanDeposit({ staff = OWNER; planId = DEP; depositBps = 2_550 }), "invalid", "whole percentage", "a deposit of 25.5%");
  unchanged(OWNER, #setPlanDeposit({ staff = OWNER; planId = DEP; depositBps = 10_000 }), "invalid", "whole percentage", "a deposit of the whole stay");
  unchanged(OWNER, #setPlanDeposit({ staff = OWNER; planId = DEP; depositBps = 0 }), "invalid", "takes no deposit", "no deposit on a plan that takes none");
  check(ok(OWNER, #setPlanDeposit({ staff = OWNER; planId = DEP; depositBps = 3_000 }), "a deposit of 30%") == [DEP, 3_000], "the deposit is set");
  check((bk0()).guarantee == #deposit and St.depositBps(later, DEP) == 3_000, "the plan is guaranteed by its deposit of 30%");
  unchanged(OWNER, #upsertRatePlan({ staff = OWNER; id = DEP; facts = { code = "CARD-DEP"; nameEn = "x"; nameAr = "x"; kind = #bar; discountBps = 0; refundable = true;
    freeCancelDaysBefore = 3; penaltyNights = 1; guarantee = #deposit; modifiable = true; active = true } }), "invalid", "with its share", "a deposit set without its share");
  ignore ok(OWNER, #upsertRatePlan({ staff = OWNER; id = DEP; facts = { code = "CARD-DEP"; nameEn = "Deposit"; nameAr = "عربون"; kind = #bar; discountBps = 0; refundable = true;
    freeCancelDaysBefore = 3; penaltyNights = 1; guarantee = #firstNightAuthorised; modifiable = true; active = true } }), "the deposit plan renamed");
  check(bk0().guarantee == #deposit, "a plan not paid in advance keeps its deposit when it is edited");

  // the card rule: the owner's, once
  unchanged(DESKC, #requireCardOnFile({ staff = DESKC }), "notAuthorised", "", "a receptionist turning the card rule on");
  // before the rule a first-night plan books without a card, as it always did
  let hOld = placed(GUEST_A, st(FN, T + 14, 1));
  let OLD = ok(GUEST_A, noCard(GUEST_A, hOld, 930, 11_220), "a first-night booking before the card rule")[0];
  check(St.card(later, OLD) == null, "with no card on file");
  check(ok(OWNER, #requireCardOnFile({ staff = OWNER }), "the card rule turned on").size() == 1 and St.cardRequired(later), "the card rule is on");
  unchanged(OWNER, #requireCardOnFile({ staff = OWNER }), "invalid", "already on", "the card rule turned on twice");

  // the rule at confirmation
  let hF = placed(GUEST_A, st(FN, T + 12, 1));
  unchanged(GUEST_A, noCard(GUEST_A, hF, 931, 11_220), "payment", "has not agreed", "a first-night rate confirmed without the card on file");
  unchanged(GUEST_A, onFile(GUEST_A, hF, 931, 11_220, 0), "payment", "not kept on file", "a confirmation that names no token");
  let GP = who(97);
  let hP = placed(GP, st(PRE, T + 12, 1));
  unchanged(GP, onFile(GP, hP, 932, q(st(PRE, T + 12, 1)).total, 700), "payment", "keeps no card", "a card kept on a rate paid in advance");
  check(ok(GP, noCard(GP, hP, 932, q(st(PRE, T + 12, 1)).total), "a prepaid stay confirmed with no card").size() > 0, "a rate paid in advance needs no card");
  ignore ok(GUEST_A, onFile(GUEST_A, hF, 931, 11_220, 700), "a first-night stay with its card on file");

  // a deposit of 30%: captured at confirmation, refunded in full on a cancellation in time
  let G1 = who(92);
  let x1 = st(DEP, T + 10, 3);
  check(q(x1).total == 33_660 and Res.guaranteeOf(later, DEP, bk0(), q(x1)) == 10_098, "three nights at 112.20 with their taxes; a deposit of 30% is 100.98");
  let h1 = placed(G1, x1);
  unchanged(G1, onFile(G1, h1, 941, 11_220, 501), "payment", "is due", "a deposit plan authorised for its first night");
  let D1out = ok(G1, onFile(G1, h1, 941, 10_098, 501), "a deposit stay with its card on file");
  let D1 = D1out[0];
  check(D1out[1] != 0 and pay(D1out[1]).kind == #captured and pay(D1out[1]).amount == 10_098 and pay(D1out[1]).state == #due, "the deposit's capture is queued at once");
  check(card(D1).state == #kept and card(D1).token == 501 and card(D1).firstAuth == 941 and card(D1).agreedBlock == DL.length(log) - 1, "the card is kept on file: the token, on the guest's payment, agreed in that block");
  check(bk(D1).penalty == 11_220, "the penalty is the room's first night");
  land(D1, #captured);
  check(bk(D1).paid == 10_098, "the deposit is paid");
  clean("after the deposit");
  ignore ok(G1, #cancelBooking({ by = #manageKey; bookingId = D1 }), "the deposit stay cancelled in time");
  var back1 = 0;
  for ((_, p) in St.paymentsOf(s, D1).vals()) { if (p.kind == #refunded and p.gatewayAuth == 941) back1 += p.amount };
  check(back1 == 10_098 and card(D1).state == #forgetDue, "the deposit is refunded in full to its card, and the card is to be forgotten");
  land(D1, #refunded);
  check(ok(DESKC, #recordCardForgotten({ bookingId = D1; ok = true }), "the gateway deleted the card") == [D1, 1] and card(D1).state == #forgotten, "the card is forgotten");
  unchanged(DESKC, #recordCardForgotten({ bookingId = D1; ok = true }), "invalid", "is forgotten", "a card forgotten twice");
  unchanged(DESKC, #recordCardForgotten({ bookingId = OLD; ok = true }), "invalid", "no card", "a card forgotten that was never kept");
  clean("after the cancellation in time");

  // a deposit of 70%, the rest paid at the desk on a second card, cancelled late: kept down to the
  // penalty, refunded across the two cards, the newest first
  ignore ok(OWNER, #setPlanDeposit({ staff = OWNER; planId = DEP; depositBps = 7_000 }), "a deposit of 70%");
  let G2 = who(93);
  let x2 = st(DEP, T + 2, 3);
  let h2 = placed(G2, x2);
  let D2 = ok(G2, onFile(G2, h2, 942, 23_562, 502), "a deposit of 70% with its card on file")[0];
  land(D2, #captured);
  let rest = Res.guestOpen(ctx(), D2, bk(D2));
  check(rest == 10_098, "the desk is asked for the rest, 100.98, got " # Nat.toText(rest));
  ignore ok(DESKC, #settleAtDesk({ staff = DESKC; bookingId = D2; auth = { authId = 943; amount = rest; currency = "EUR"; merchantRef = St.BOOKING_REF_BASE + D2 } }), "the rest at the desk");
  land(D2, #captured);
  check(bk(D2).paid == 33_660, "the stay is paid in full on two cards");
  ignore ok(G2, #cancelBooking({ by = #manageKey; bookingId = D2 }), "the deposit stay cancelled late");
  var to942 = 0; var to943 = 0;
  for ((_, p) in St.paymentsOf(s, D2).vals()) { if (p.kind == #refunded) { if (p.gatewayAuth == 942) to942 += p.amount; if (p.gatewayAuth == 943) to943 += p.amount } };
  check(to943 == 10_098 and to942 == 12_342 and bk(D2).paid == 11_220, "kept down to the penalty of 112.20: 100.98 back to the desk's card, 123.42 to the deposit's");
  check(card(D2).state == #forgetDue, "and its card is to be forgotten");
  land(D2, #refunded);
  ignore ok(DESKC, #recordCardForgotten({ bookingId = D2; ok = true }), "the gateway deleted the second card");
  clean("after the late cancellation");

  // bookings by phone: the card link, and the flag once the guarantee is due without a card
  let W0 = byPhone(FN, T, 1, "Walid");
  let W1 = byPhone(FN, T + 1, 2, "Wafaa");
  let W2 = byPhone(FN, T + 8, 2, "Wessam");
  let W3 = byPhone(FN, T, 1, "Hesham");
  let P0 = byPhone(PRE, T + 8, 1, "Pakinam");
  check(card(W0).state == #wanted and card(W0).deadline == T - 2 and card(W2).deadline == T + 6 and St.card(later, P0) == null,
    "a booking by phone on a rate that keeps a card waits for one, due by its last free cancellation day; one paid in advance does not");
  func wantedBy(d : Nat) : [Nat] { Array.map<(Nat, R.CardOnFile), Nat>(St.cardsWanted(later, d, null, 50).rows, func((id, _)) { id }) };
  check(wantedBy(T) == [W0, W3, W1] or Array.sort<Nat>(wantedBy(T), Nat.compare) == Array.sort<Nat>([W0, W1, W3], Nat.compare), "the day list flags the three whose guarantee is due: " # debug_show wantedBy(T));
  check(Array.find<Nat>(wantedBy(T), func(i) { i == W2 }) == null, "and not the one due in six days");
  func putCard(by : Cmd.GuestActor, id : Nat, authId : Nat, amount : Nat, token : Nat) : Cmd.Command {
    #putCardOnFile({ by; bookingId = id; auth = { authId; amount; currency = "EUR"; merchantRef = St.BOOKING_REF_BASE + id }; token })
  };
  unchanged(STRANGER, putCard(#account(STRANGER), W2, 950, 11_220, 610), "notTheOwner", "", "a card put on someone else's booking");
  unchanged(GUEST_A, putCard(#manageKey, W2, 950, 10_000, 610), "payment", "is due", "a card link paying less than the first night");
  unchanged(GUEST_A, putCard(#manageKey, W2, 950, 11_220, 0), "payment", "not kept on file", "a card link that kept no card");
  unchanged(GUEST_A, putCard(#manageKey, P0, 950, 11_220, 610), "payment", "keeps no card", "a card link on a booking paid in advance");
  unchanged(GUEST_A, putCard(#manageKey, W2, 930, 11_220, 610), "authUsed", "", "a card link paying with a payment already used");
  check(Res.cardLinkDue(ctx(), W2) == 11_220 and Res.cardLinkDue(ctx(), P0) == 0 and Res.cardLinkDue(ctx(), D1) == 0,
    "the card link asks for the first night of a booking waiting for a card, and nothing of one that is not");
  check(ok(GUEST_A, putCard(#manageKey, W2, 950, 11_220, 610), "the guest puts a card on file from the link")[0] == W2, "the card link takes the first night and keeps the card");
  check(Res.cardLinkDue(ctx(), W2) == 0, "and nothing once the card is kept");
  check(card(W2).state == #kept and card(W2).token == 610 and card(W2).deadline == T + 6 and Res.authOf(s, W2) != null, "the card is kept, the day it was due by kept with it");
  unchanged(GUEST_A, putCard(#manageKey, W2, 951, 11_220, 611), "invalid", "is kept", "a second card on the same booking");
  ignore ok(DESKC, #checkIn({ staff = DESKC; bookingId = W3; roomIds = [CROOM] }), "Hesham arrives with no card on file");
  check(card(W3).state == #closed and Array.find<Nat>(wantedBy(T), func(i) { i == W3 }) == null, "a guest who arrived no longer needs the card, and leaves the list");
  clean("after the bookings by phone");

  // the night audit: two no-shows with cards on file, one with none
  let x3 = st(FN, T, 3);
  check(q(x3).total == 33_660, "three nights at 112.20");
  let N1 = ok(who(94), onFile(who(94), placed(who(94), x3), 961, 11_220, 601), "a stay arriving today with its card on file")[0];
  let N2 = ok(who(95), onFile(who(95), placed(who(95), st(FN, T, 2)), 962, 11_220, 602), "a stay arriving today on a card that declines later charges")[0];
  check(bk(N1).penalty == 22_440 and bk(N2).penalty == 22_440, "a no-show owes two nights");
  ignore ok(OWNER, #openAudit({ staff = OWNER; day = T }), "the audit of the card day");
  var steps = 0;
  label run loop {
    switch (send(OWNER, #advanceAudit({ staff = OWNER; day = T; limit = 8 }))) {
      case (#ok _) { steps += 1; if (steps > 400) break run };
      case (#err _) break run;
    };
  };
  ignore ok(OWNER, #closeDay({ staff = OWNER; day = T }), "the card day closed");
  check(bk(N1).status == #noShow and bk(N2).status == #noShow and bk(W0).status == #noShow, "the three who did not come are no-shows");
  func chargeOf(id : Nat) : Nat { card(id).chargeId };
  check(chargeOf(N1) != 0 and pay(chargeOf(N1)).kind == #chargedOnFile and pay(chargeOf(N1)).amount == 11_220 and pay(chargeOf(N1)).state == #due and pay(chargeOf(N1)).gatewayAuth == 0,
    "the second night of the penalty is charged to the card on file, once, by the gateway queue");
  check(Res.capturesDue(s, N1) == 22_440, "the first night captured from the guarantee and the second charged on file, both due");
  check(card(W0).state == #closed, "a no-show with no card: the desk's wait is over, and the penalty stays outstanding");
  land(N1, #captured); land(N2, #captured);
  let c1 = chargeOf(N1);
  let capN1 = Option.unwrap(Array.find<(Nat, R.Payment)>(St.paymentsOf(s, N1), func((_, p)) { p.kind == #captured })).0;
  unchanged(DESKC, #recordChargeOutcome({ paymentId = capN1; ok = true; authId = 970 }), "invalid", "not a charge on file", "a capture recorded as a charge on file");
  unchanged(DESKC, #recordChargeOutcome({ paymentId = c1; ok = true; authId = 0 }), "invalid", "no new authorisation", "a charge made under no authorisation");
  unchanged(DESKC, #recordChargeOutcome({ paymentId = c1; ok = true; authId = 961 }), "invalid", "no new authorisation", "a charge made under the guarantee's own authorisation");
  check(ok(DESKC, #recordChargeOutcome({ paymentId = c1; ok = true; authId = 971 }), "the charge on file is made") == [c1, 1], "the gateway made the charge");
  check(pay(c1).state == #done and pay(c1).gatewayAuth == 971 and bk(N1).paid == 22_440 and bk(N1).outstanding == 0 and card(N1).state == #forgetDue,
    "the no-show's penalty is paid, the charge under the authorisation the gateway gave, and the card is to be forgotten");
  unchanged(DESKC, #recordChargeOutcome({ paymentId = c1; ok = true; authId = 972 }), "invalid", "is done", "a charge recorded twice");
  let c2 = chargeOf(N2);
  check(ok(DESKC, #recordChargeOutcome({ paymentId = c2; ok = false; authId = 0 }), "the charge on file is declined") == [c2, 0], "the gateway declined the charge");
  check(pay(c2).state == #failed and bk(N2).outstanding == 11_220 and card(N2).state == #forgetDue and card(N2).declinedDay == today(),
    "a decline stays outstanding for the desk, marked on the day it was declined; the card is to be forgotten, never tried again");
  check(Array.find<(Nat, R.CardOnFile)>(St.cardsDeclined(later, today() - 6, today(), 50), func((id, _)) { id == N2 }) != null, "the day list shows the declined charge");
  unchanged(DESKC, #recordChargeOutcome({ paymentId = c2; ok = true; authId = 973 }), "invalid", "is failed", "a declined charge tried again");
  clean("after the charges on file");

  // the tokens forgotten at the gateway: N1's at once, N2's refused three times and shown to the desk
  ignore ok(DESKC, #recordCardForgotten({ bookingId = N1; ok = true }), "N1's card deleted");
  for (i in Nat.range(0, 3)) ignore ok(DESKC, #recordCardForgotten({ bookingId = N2; ok = false }), "the gateway refuses to delete N2's card");
  check(card(N1).state == #forgotten and card(N2).state == #forgetFailed and card(N2).attempts == 3, "one card forgotten; the other refused three times");
  check(St.cardsForgetFailed(later, 50).size() == 1 and St.cardsToForget(later, 50).size() == 0, "the refused deletion is shown to the desk, and nothing more is asked of the gateway");
  // a charge on file is refunded as any capture: the penalty waived, the charge first (the newest)
  let pw = ok(OWNER, #propose({ staff = OWNER; act = #waivePenalty({ bookingId = N1 }); justification = "the guest's flight was cancelled" }), "propose a waiver of the no-show");
  ignore ok(OWNER2, #approve({ staff = OWNER2; proposalId = pw[0] }), "the waiver approved");
  var to971 = 0; var to961 = 0;
  for ((_, p) in St.paymentsOf(s, N1).vals()) { if (p.kind == #refunded) { if (p.gatewayAuth == 971) to971 += p.amount; if (p.gatewayAuth == 961) to961 += p.amount } };
  check(to971 == 11_220 and to961 == 11_220, "the waiver refunds the charge on file to the authorisation the gateway gave it, and the capture to the guarantee's");
  land(N1, #refunded);
  // the guest who arrives tomorrow comes, and the one booked for next week cancels
  ignore ok(DESKC, #checkIn({ staff = DESKC; bookingId = W1; roomIds = [CROOM + 1] }), "Wafaa arrives");
  check(card(W1).state == #closed, "her wanted card is closed");
  ignore ok(GUEST_A, #cancelBooking({ by = #manageKey; bookingId = W2 }), "Wessam cancels in time");
  check(card(W2).state == #forgetDue, "his card is to be forgotten");
  ignore ok(DESKC, #recordCardForgotten({ bookingId = W2; ok = true }), "his card deleted");
  land(W2, #voided);
  clean("after the tokens are forgotten");

  // ── I16, each clause shown a fault of its own ──
  var cardControls = 0;
  func i16(words : Text) : Bool {
    var hit = false; var stray = false;
    for (v in List.values(walk().violations)) { if (Text.startsWith(v, #text "I16 card on file")) { if (Text.contains(v, #text words)) hit := true } else stray := true };
    hit and not stray
  };
  func control(caught : Bool, what : Text) { check(caught, what); if (caught) cardControls += 1 };
  func withCard(id : Nat, k : R.CardOnFile, words : Text, what : Text) {
    let was = card(id);
    RowStore.put<R.CardOnFile>(cardT, R.cardOnFile, id, k);
    control(i16(words), what);
    RowStore.put<R.CardOnFile>(cardT, R.cardOnFile, id, was);
  };
  withCard(D1, { card(D1) with state = #kept }, "is still kept, and the booking is settled", "a card kept after its booking was cancelled is named I16");
  withCard(N1, { card(N1) with state = #kept }, "is still kept, and the booking is settled", "a no-show's card kept after its charge was made is named I16");
  withCard(W0, { card(W0) with state = #wanted }, "is still wanted, and the booking is no-show", "a card still wanted for a no-show is named I16");
  withCard(W1, { card(W1) with token = 9 }, "has no card, and names a token", "a closed card naming a token is named I16");
  withCard(N1, { card(N1) with token = 0 }, "with no token or no agreement", "a card kept with no token is named I16");
  withCard(N1, { card(N1) with firstAuth = 999 }, "rests on no payment of the guest's", "a card resting on no payment of the guest's is named I16");
  withCard(N1, { card(N1) with agreedBlock = pay(c1).block }, "not after the guest agreed", "a charge made before the guest agreed is named I16");
  withCard(N1, { card(N1) with declinedDay = today() }, "is marked declined, and its charge is done", "a made charge marked declined is named I16");
  withCard(D1, { card(D1) with chargeId = c1 }, "not a no-show", "a charge on a booking that is no no-show is named I16");
  withCard(N1, { card(N1) with chargeId = 0 }, "is not its card's charge", "a charge on file its card does not name is named I16");
  withCard(W0, { card(W0) with declinedDay = 3 }, "is marked declined with no charge", "a card marked declined with no charge is named I16");
  // a forgotten card whose charge is still due
  let p2 = pay(c2);
  RowStore.put<R.Payment>(s.payments, R.payment, c2, { p2 with state = #due });
  control(i16("forgetFailed with its charge still due"), "a card forgotten while its charge is due is named I16");
  RowStore.put<R.Payment>(s.payments, R.payment, c2, p2);
  // a charge past the penalty less what the guarantee covered
  let n1 = bk(N1);
  RowStore.put<R.Booking>(s.bookings, R.booking, N1, { n1 with penalty = n1.penalty - 1 });
  control(i16("past the penalty"), "a charge past the penalty is named I16");
  RowStore.put<R.Booking>(s.bookings, R.booking, N1, n1);
  // the deposit's share
  let dep = Option.unwrap(RowStore.get<R.PlanDeposit>(depT, R.planDeposit, DEP));
  RowStore.put<R.PlanDeposit>(depT, R.planDeposit, DEP, { dep with depositBps = 2_550 });
  control(i16("not a whole percentage"), "a deposit not a whole percentage is named I16");
  RowStore.put<R.PlanDeposit>(depT, R.planDeposit, DEP, { dep with depositBps = 0 });
  control(i16("takes a deposit with no share set"), "a deposit plan with no share is named I16");
  RowStore.put<R.PlanDeposit>(depT, R.planDeposit, DEP, dep);
  clean("after the I16 controls are put back");

  Debug.print("count: card refusals that left the state untouched = " # Nat.toText(untouched));
  Debug.print("count: card controls that went red for their own rule = " # Nat.toText(cardControls));
  Debug.print("count: card audit steps = " # Nat.toText(steps));
};

// ── guest emails ─────────────────────────────────────────────────────────────
//
// A guest who gives an address (sealed in the browser to the relay's mail key) is owed four messages:
// the confirmation, a note two days before arrival, the receipt at check-out and a cancellation notice.
// Each is an outbox row written by the act that owes it. The relay pulls the due rows through its mailer
// key and records what became of each; nobody else can, the owner included. Guest email is on only after
// the owner authorised the hotel's account and the relay tested it. Each refusal is compared on five
// dimensions; then each clause of I17 is shown a fault of its own.

do {
  let T = today();
  let MAILER = who(70);
  let MAILER2 = who(71);
  let DESKM = who(72);
  let STRANGER = who(73);
  ignore ok(OWNER, #grantRole({ staff = OWNER; subject = DESKM; role = #frontDesk }), "a receptionist for guest email");
  ignore ok(OWNER, #upsertRoomType({ staff = OWNER; id = 0; facts = { code = "MAIL"; nameEn = "Garden"; nameAr = "حديقة"; descEn = ""; descAr = ""; sizeSqm = 30; maxAdults = 2;
    maxChildren = 1; maxOccupancy = 3; bedKind = #king; bedCount = 1; amenities = 1; photos = "almar/sea-room"; rank = 15; active = true } }), "the garden room type");
  let MT = s.nextRoomTypeId - 1;
  let MROOM = s.nextRoomId;
  for (n in ["6001", "6002", "6003", "6004", "6005", "6006"].vals()) ignore ok(OWNER, #upsertRoom({ staff = OWNER; id = 0; roomTypeId = MT; number = n; outOfOrder = false }), "room " # n);
  ignore ok(OWNER, #setNights({ staff = OWNER; edit = { roomTypeId = MT; fromDay = T; toDay = T + 40; weekdays = 127; allotment = ?6; bar = ?10_000; minStay = null; maxStay = null;
    closedToArrival = null; closedToDeparture = null; stopSell = null } }), "the garden nights");
  ignore ok(OWNER, #upsertRatePlan({ staff = OWNER; id = 0; facts = { code = "MAIL-PRE"; nameEn = "Garden rate"; nameAr = "سعر الحديقة"; kind = #bar; discountBps = 0;
    refundable = true; freeCancelDaysBefore = 1; penaltyNights = 1; guarantee = #prepaidInFull; modifiable = true; active = true } }), "the garden plan");
  let MP = s.nextPlanId - 1;

  let outT = St.later(later, St.OUTBOX_TABLE);
  let addrT = St.later(later, St.MAIL_ADDRESS_TABLE);
  let setT = St.later(later, St.MAIL_SETUP_TABLE);
  var untouched = 0;
  func unchanged(caller : Principal, c : Cmd.Command, kind : Text, words : Text, what : Text) {
    let fp = St.fingerprintHash(s, later);
    let len = DL.length(log);
    let arena = TA.bytesUsed(s.arena);
    let counters = (s.nextGrantId, s.nextBookingId, s.nextFolioId, s.nextPaymentId);
    let rows = (RowStore.size(outT), RowStore.size(addrT), RowStore.size(setT), RowStore.size(s.grants), RowStore.size(s.bookings));
    switch (send(caller, c)) {
      case (#ok _) check(false, what # ": accepted, expected " # kind);
      case (#err r) check(Con.kindOf(r) == kind and Text.contains(Con.textOf(r), #text words),
        what # ": refused as " # Con.kindOf(r) # " (" # Con.textOf(r) # "), expected " # kind # " saying \"" # words # "\"");
    };
    let same = St.fingerprintHash(s, later) == fp and DL.length(log) == len and TA.bytesUsed(s.arena) == arena
      and (s.nextGrantId, s.nextBookingId, s.nextFolioId, s.nextPaymentId) == counters
      and (RowStore.size(outT), RowStore.size(addrT), RowStore.size(setT), RowStore.size(s.grants), RowStore.size(s.bookings)) == rows;
    check(same, what # ": the refusal moved state");
    if (same) untouched += 1;
  };
  func bk(id : Nat) : R.Booking { Option.unwrap(St.booking(s, id)) };
  func msg(id : Nat) : R.Outbox { switch (St.outboxRow(later, id)) { case (?o) o; case null Runtime.trap("no message " # Nat.toText(id)) } };
  func addr(id : Nat) : R.MailAddress { switch (St.mailAddress(later, id)) { case (?m) m; case null Runtime.trap("no address for booking " # Nat.toText(id)) } };
  func setup() : R.MailSetup { Mail.setup(ctx()) };
  func st(arrival : Nat, nights : Nat) : Cmd.Stay { { roomTypeId = MT; planId = MP; arrival; nights; rooms = 1; adults = 2; children = 0 } };
  func q(x : Cmd.Stay) : Q.Quote { switch (Res.quoteStay(ctx(), x)) { case (#ok c) c.quote; case (#err r) Runtime.trap("a garden quote: " # debug_show r) } };
  var nextKey : Nat8 = 180;
  func byPhone(arrival : Nat, nights : Nat, name : Text) : Nat {
    let x = st(arrival, nights);
    nextKey += 1;
    ok(DESKM, #bookByStaff({ staff = DESKM; channel = #phone; stay = x; quoteHash = q(x).hash; guestName = name; guestEmail = ""; note = ""; manageKey = key(nextKey); roomIds = [] }),
      "a garden booking for " # name)[0]
  };
  // an address as a browser seals one: "lxe1." and base64url (the contract can only check its shape)
  func sealed(seed : Text) : Text {
    var body = "";
    var i = 0;
    while (Text.size(body) < 128) { body #= seed # Nat.toText(i) # "-_Az"; i += 1 };
    "lxe1." # Text.fromIter(Iter.take(Text.toIter(body), 128))
  };
  func rep(x : Text, n : Nat) : Text { var out = ""; for (_ in Nat.range(0, n)) out #= x; out };
  func digest(b : Nat8) : Blob { Blob.fromArray(Array.repeat<Nat8>(b, 32)) };
  let MAILKEY : Blob = Blob.fromArray(Array.tabulate<Nat8>(65, func(i) { if (i == 0) 4 else Nat8.fromNat(i) }));
  func dueBy(day : Nat) : [Nat] { Array.map<(Nat, R.Outbox), Nat>(St.mailDue(later, day, null, 200).rows, func((id, _)) { id }) };
  func has(xs : [Nat], x : Nat) : Bool { Array.find<Nat>(xs, func(y) { y == x }) != null };
  func clean(what : Text) {
    law(what);
    check(List.size(walk().violations) == 0, "the oracle is empty " # what # ": " # debug_show List.toArray(walk().violations));
  };
  func closeToday() {
    let d = today();
    ignore ok(OWNER, #openAudit({ staff = OWNER; day = d }), "the audit of day " # Nat.toText(d));
    var steps = 0;
    label run loop {
      switch (send(OWNER, #advanceAudit({ staff = OWNER; day = d; limit = 8 }))) {
        case (#ok _) { steps += 1; if (steps > 400) break run };
        case (#err _) break run;
      };
    };
    ignore ok(OWNER, #closeDay({ staff = OWNER; day = d }), "day " # Nat.toText(d) # " closed");
  };

  // before the relay is connected: no key to seal to, so no address is taken
  let B1 = byPhone(T + 5, 2, "Basma");
  unchanged(DESKM, #attachMailByStaff({ staff = DESKM; bookingId = B1; sealed = sealed("b1"); lang = #ar }), "invalid", "has not connected guest email", "an address before the relay is connected");

  // connecting the relay: the owner's, a signed key that is nobody's at the hotel, a P-256 mail key
  unchanged(DESKM, #setMailRelay({ staff = DESKM; mailer = MAILER; mailKey = MAILKEY }), "notAuthorised", "", "a receptionist connecting the relay");
  unchanged(OWNER, #setMailRelay({ staff = OWNER; mailer = Principal.anonymous(); mailKey = MAILKEY }), "invalid", "not the anonymous one", "the anonymous key as the relay");
  unchanged(OWNER, #setMailRelay({ staff = OWNER; mailer = MAILER; mailKey = Blob.fromArray([4, 1]) }), "invalid", "raw uncompressed P-256", "a mail key that is not a point");
  unchanged(OWNER, #setMailRelay({ staff = OWNER; mailer = DESKM; mailKey = MAILKEY }), "invalid", "already holds a staff role", "a receptionist's key as the relay");
  unchanged(OWNER, #grantRole({ staff = OWNER; subject = MAILER; role = #mailer }), "invalid", "connected under Guest email", "the mailer role granted by hand");
  let g1 = ok(OWNER, #setMailRelay({ staff = OWNER; mailer = MAILER; mailKey = MAILKEY }), "the relay connected")[0];
  check(St.holdsRole(s, MAILER, #mailer) and setup().mailerGrant == g1 and setup().mailKey == MAILKEY and not setup().on, "the relay's key is the hotel's mailer, guest email off");
  check(not Staff.may(s, MAILER, "desk.checkIn") and not Staff.may(s, MAILER, "setup.mailOn") and not Staff.may(s, OWNER, "mail.outcome"),
    "the mailer holds nothing of the hotel's, and the owner nothing of the mailer's");

  // the hotel's account: authorised by the owner, tested by the relay, then turned on
  unchanged(MAILER, #recordMailTest({ mailer = MAILER; digest = digest(0x11) }), "invalid", "No email account is authorised", "a test before any account");
  unchanged(DESKM, #authoriseMailCredential({ staff = DESKM; digest = digest(0x11) }), "notAuthorised", "", "a receptionist authorising an account");
  unchanged(OWNER, #authoriseMailCredential({ staff = OWNER; digest = Blob.fromArray([0x11, 0x22]) }), "invalid", "32 bytes", "a digest of two bytes");
  unchanged(OWNER, #authoriseMailCredential({ staff = OWNER; digest = digest(0) }), "invalid", "32 bytes", "a digest of nothing");
  ignore ok(OWNER, #authoriseMailCredential({ staff = OWNER; digest = digest(0x11) }), "the hotel's account authorised");
  unchanged(OWNER, #authoriseMailCredential({ staff = OWNER; digest = digest(0x11) }), "invalid", "already the one", "the same account authorised twice");
  unchanged(OWNER, #setMailOn({ staff = OWNER; on = true }), "invalid", "Send the test email first", "guest email on before the test");
  unchanged(OWNER, #recordMailTest({ mailer = OWNER; digest = digest(0x11) }), "notAuthorised", "", "the owner recording the relay's test");
  unchanged(MAILER, #recordMailTest({ mailer = MAILER; digest = digest(0x12) }), "invalid", "not the account the owner authorised", "a test of another account");
  ignore ok(MAILER, #recordMailTest({ mailer = MAILER; digest = digest(0x11) }), "the relay sent the test email");
  unchanged(MAILER, #recordMailTest({ mailer = MAILER; digest = digest(0x11) }), "invalid", "already recorded", "a test recorded twice");
  unchanged(DESKM, #setMailOn({ staff = DESKM; on = true }), "notAuthorised", "", "a receptionist turning guest email on");
  ignore ok(OWNER, #setMailOn({ staff = OWNER; on = true }), "guest email on");
  unchanged(OWNER, #setMailOn({ staff = OWNER; on = true }), "invalid", "already on", "guest email on twice");
  // a new account: tested again before it sends anything
  ignore ok(OWNER, #authoriseMailCredential({ staff = OWNER; digest = digest(0x21) }), "a new account authorised");
  check(not setup().on and setup().tested == Mail.noDigest(), "a new account turns guest email off until it is tested");
  unchanged(OWNER, #setMailOn({ staff = OWNER; on = true }), "invalid", "Send the test email first", "the new account on before its test");
  ignore ok(MAILER, #recordMailTest({ mailer = MAILER; digest = digest(0x21) }), "the new account tested");
  ignore ok(OWNER, #setMailOn({ staff = OWNER; on = true }), "guest email on again");
  clean("after guest email is connected");

  // the address: sealed, once per booking, by the desk or the booking's own guest
  unchanged(DESKM, #attachMailByStaff({ staff = DESKM; bookingId = B1; sealed = "basma@example.com"; lang = #ar }), "invalid", "never sent plain", "an address in the clear");
  unchanged(DESKM, #attachMailByStaff({ staff = DESKM; bookingId = B1; sealed = "lxe1.abc"; lang = #ar }), "invalid", "too short", "a sealed address too short to hold one");
  unchanged(DESKM, #attachMailByStaff({ staff = DESKM; bookingId = B1; sealed = sealed("b1") # rep("a", 400); lang = #ar }),
    "tooLong", "", "a sealed address past 512 bytes");
  unchanged(DESKM, #attachMailByStaff({ staff = DESKM; bookingId = B1; sealed = "lxe1." # rep("+", 128); lang = #ar }),
    "invalid", "not base64url", "a sealed address that is not base64url");
  unchanged(DESKM, #attachMailByStaff({ staff = DESKM; bookingId = 999_999; sealed = sealed("x"); lang = #ar }), "noSuchBooking", "", "an address for no booking");
  unchanged(STRANGER, #attachMailByStaff({ staff = STRANGER; bookingId = B1; sealed = sealed("b1"); lang = #ar }), "notAuthorised", "", "a stranger giving an address");
  unchanged(MAILER, #attachMailByStaff({ staff = MAILER; bookingId = B1; sealed = sealed("b1"); lang = #ar }), "notAuthorised", "", "the relay giving an address");
  unchanged(GUEST_A, #attachMail({ by = #account(GUEST_A); bookingId = B1; sealed = sealed("b1"); lang = #ar }), "notTheOwner", "", "an account that does not hold the booking");
  let a1 = ok(DESKM, #attachMailByStaff({ staff = DESKM; bookingId = B1; sealed = sealed("b1"); lang = #ar }), "Basma's address, by the desk");
  let C1 = a1[1];
  let P1 = a1[2];
  check(a1[0] == B1 and C1 != 0 and P1 != 0, "a booking five days ahead is owed its confirmation and a note before arrival");
  check(msg(C1).kind == #confirmation and msg(C1).state == #due and msg(C1).notBefore == 0 and msg(P1).kind == #preArrival and msg(P1).notBefore == T + 3,
    "the confirmation at once, the note two days before arrival");
  check(addr(B1).lang == #ar and addr(B1).confirmation == C1 and addr(B1).preArrival == P1 and addr(B1).receipt == 0, "the address names its messages, in Arabic");
  check(has(dueBy(T), C1) and not has(dueBy(T), P1) and has(dueBy(T + 3), P1), "today the confirmation is due; the note on its day");
  unchanged(DESKM, #attachMailByStaff({ staff = DESKM; bookingId = B1; sealed = sealed("b1x"); lang = #en }), "invalid", "already has an address", "a second address for a booking");
  let B2 = byPhone(T + 1, 1, "Bahaa");
  let a2 = ok(GUEST_A, #attachMail({ by = #manageKey; bookingId = B2; sealed = sealed("b2"); lang = #en }), "Bahaa's address, from his manage link");
  let C2 = a2[1];
  check(a2[2] == 0 and addr(B2).preArrival == 0, "a booking arriving tomorrow is owed no note before arrival: the confirmation says it all");
  check(Option.unwrap(St.booking(s, B2)).manageNonce > 0, "the manage link's signature is spent");
  clean("after the addresses");

  // what the relay records: only the mailer, only a due message, only on its day
  unchanged(OWNER, #recordMailOutcome({ mailer = OWNER; outboxId = C1; sent = true; failure = #none }), "notAuthorised", "", "the owner marking a message sent");
  unchanged(DESKM, #recordMailOutcome({ mailer = DESKM; outboxId = C1; sent = true; failure = #none }), "notAuthorised", "", "the desk marking a message sent");
  unchanged(MAILER, #recordMailOutcome({ mailer = MAILER; outboxId = 999_999; sent = true; failure = #none }), "invalid", "no message", "an outcome for no message");
  unchanged(MAILER, #recordMailOutcome({ mailer = MAILER; outboxId = P1; sent = true; failure = #none }), "invalid", "not due until day", "a note sent before its day");
  unchanged(MAILER, #recordMailOutcome({ mailer = MAILER; outboxId = C1; sent = true; failure = #rejected }), "invalid", "has no failure", "a message sent with a failure");
  unchanged(MAILER, #recordMailOutcome({ mailer = MAILER; outboxId = C1; sent = false; failure = #none }), "invalid", "Say why", "a failure with no reason");
  check(ok(MAILER, #recordMailOutcome({ mailer = MAILER; outboxId = C1; sent = true; failure = #none }), "Basma's confirmation sent") == [C1, 1], "the relay sent the confirmation");
  check(msg(C1).state == #sent and not has(dueBy(T), C1), "a message sent leaves the due list");
  unchanged(MAILER, #recordMailOutcome({ mailer = MAILER; outboxId = C1; sent = true; failure = #none }), "invalid", "is sent, not due", "a message sent twice");
  check(ok(MAILER, #recordMailOutcome({ mailer = MAILER; outboxId = C2; sent = false; failure = #unavailable }), "the provider could not be reached") == [C2, 1]
    and msg(C2).state == #due and msg(C2).failure == #unavailable, "a first failure leaves the message due, its reason kept");
  ignore ok(MAILER, #recordMailOutcome({ mailer = MAILER; outboxId = C2; sent = false; failure = #unavailable }), "a second failure");
  check(ok(MAILER, #recordMailOutcome({ mailer = MAILER; outboxId = C2; sent = false; failure = #rejected }), "a third failure") == [C2, 3]
    and msg(C2).state == #failed and msg(C2).attempts == 3, "the third failure is the last: the message is failed");
  unchanged(MAILER, #recordMailOutcome({ mailer = MAILER; outboxId = C2; sent = true; failure = #none }), "invalid", "is failed, not due", "a fourth attempt");
  // off: nothing may be recorded as sent
  let B3 = byPhone(T + 6, 1, "Bassem");
  let a3 = ok(DESKM, #attachMailByStaff({ staff = DESKM; bookingId = B3; sealed = sealed("b3"); lang = #en }), "Bassem's address");
  ignore ok(OWNER, #setMailOn({ staff = OWNER; on = false }), "guest email off");
  unchanged(MAILER, #recordMailOutcome({ mailer = MAILER; outboxId = a3[1]; sent = true; failure = #none }), "invalid", "not turned on", "a message recorded while guest email is off");
  check(has(dueBy(T), a3[1]), "while it is off a message stays due");
  check(Mail.waiting(ctx(), T, 99).count >= 1, "and the day list counts it as waiting");
  ignore ok(OWNER, #setMailOn({ staff = OWNER; on = true }), "guest email on again");
  clean("after the outcomes");

  // the acts that owe a message, or make one unneeded
  ignore ok(GUEST_A, #cancelBooking({ by = #manageKey; bookingId = B3 }), "Bassem cancels");
  let m3 = addr(B3);
  check(msg(m3.confirmation).state == #skipped and msg(m3.preArrival).state == #skipped, "a cancelled booking's unsent confirmation and note are not sent");
  check(m3.cancellation != 0 and msg(m3.cancellation).kind == #cancellation and msg(m3.cancellation).state == #due, "and its cancellation notice is owed");
  // the stay moved: the note moves with it
  let x1 = { st(T + 5, 2) with arrival = T + 7 };
  ignore ok(GUEST_A, #modifyBooking({ by = #manageKey; bookingId = B1; stay = x1; quoteHash = q(x1).hash;
    auth = ?{ authId = 7_101; amount = q(x1).total; currency = "EUR"; merchantRef = St.BOOKING_REF_BASE + B1 } }), "Basma moves her stay two days later");
  check(msg(P1).state == #due and msg(P1).notBefore == T + 5, "the note before arrival moves with the stay");
  // arrived, did not come, checked out: the note is not sent, the receipt is owed
  let B4 = byPhone(T + 3, 1, "Bothaina");
  let P4 = ok(DESKM, #attachMailByStaff({ staff = DESKM; bookingId = B4; sealed = sealed("b4"); lang = #ar }), "Bothaina's address")[2];
  let B5 = byPhone(T + 3, 1, "Boutros");
  let P5 = ok(DESKM, #attachMailByStaff({ staff = DESKM; bookingId = B5; sealed = sealed("b5"); lang = #en }), "Boutros's address")[2];
  check(P4 != 0 and P5 != 0 and msg(P4).notBefore == T + 1, "both are owed a note on day T+1");
  clean("before the days pass");
  closeToday();
  check(has(dueBy(today()), P4) and has(dueBy(today()), P5), "on its day the note is due");
  ignore ok(MAILER, #recordMailOutcome({ mailer = MAILER; outboxId = P4; sent = true; failure = #none }), "Bothaina's note sent");
  closeToday();
  closeToday();
  check(today() == T + 3, "three days have passed");
  ignore ok(DESKM, #checkIn({ staff = DESKM; bookingId = B4; roomIds = [MROOM] }), "Bothaina arrives");
  check(msg(P4).state == #sent, "a note already sent stays sent");
  let open4 = Res.guestOpen(ctx(), B4, bk(B4));
  ignore ok(DESKM, #settleAtDesk({ staff = DESKM; bookingId = B4; auth = { authId = 7_401; amount = open4; currency = "EUR"; merchantRef = St.BOOKING_REF_BASE + B4 } }), "Bothaina pays at the desk");
  for ((pid, p) in St.paymentsOf(s, B4).vals()) { if (p.kind == #captured and p.state == #due) ignore ok(DESKM, #recordGatewayOutcome({ paymentId = pid; ok = true }), "her capture lands") };
  ignore ok(DESKM, #checkOut({ staff = DESKM; bookingId = B4 }), "Bothaina leaves");
  let R4 = addr(B4).receipt;
  check(R4 != 0 and msg(R4).kind == #receipt and msg(R4).state == #due and has(dueBy(today()), R4), "her receipt is owed at once");
  ignore ok(MAILER, #recordMailOutcome({ mailer = MAILER; outboxId = R4; sent = true; failure = #none }), "her receipt sent");
  // Boutros's note was never sent; he does not come
  check(msg(P5).state == #due, "Boutros's note is still due on his arrival day");
  closeToday();
  check(bk(B5).status == #noShow and msg(P5).state == #skipped, "a guest who did not come is not sent the note");
  clean("after the stays");

  // another relay: the first key stops being the mailer, and its account must be connected again
  let g2 = ok(OWNER, #setMailRelay({ staff = OWNER; mailer = MAILER2; mailKey = MAILKEY }), "a new relay connected")[0];
  check(g2 != g1 and St.holdsRole(s, MAILER2, #mailer) and not St.holdsRole(s, MAILER, #mailer), "the old relay's key is no longer the mailer");
  check(not setup().on and setup().authorised == Mail.noDigest(), "a new relay starts with no account and guest email off");
  unchanged(MAILER, #recordMailOutcome({ mailer = MAILER; outboxId = m3.cancellation; sent = true; failure = #none }), "notAuthorised", "", "the old relay recording an outcome");
  ignore ok(OWNER, #authoriseMailCredential({ staff = OWNER; digest = digest(0x31) }), "the account connected to the new relay");
  ignore ok(MAILER2, #recordMailTest({ mailer = MAILER2; digest = digest(0x31) }), "the new relay's test");
  ignore ok(OWNER, #setMailOn({ staff = OWNER; on = true }), "guest email on with the new relay");
  ignore ok(MAILER2, #recordMailOutcome({ mailer = MAILER2; outboxId = m3.cancellation; sent = true; failure = #none }), "Bassem's cancellation notice sent");
  clean("after the new relay");

  // the days this section passed made the earlier group's pickups no-shows: a garden block with a pickup
  // ahead keeps a live pickup in the state, for the block laws' controls (here and in the twin)
  let gb = ok(OWNER, #upsertBlock({ staff = OWNER; id = 0; name = "Garden party"; companyId = 0; roomTypeId = MT; planId = MP; arrival = T + 22; nights = 2;
    rooms = 2; cutoff = T + 10 }), "a garden block")[0];
  let gq = switch (Res.checkStayAs(ctx(), Res.newPending(), st(T + 22, 2), null, { companyId = 0; promoId = 0 }, true)) {
    case (#ok c) c.quote; case (#err r) Runtime.trap("the garden pickup's quote: " # debug_show r)
  };
  ignore ok(DESKM, #pickUpFromBlock({ staff = DESKM; blockId = gb; stay = st(T + 22, 2); quoteHash = gq.hash; guestName = "Guest of the party"; guestEmail = "";
    note = "party"; manageKey = key(199) }), "a pickup from the garden block");
  clean("after the garden block");

  // ── I17, each clause shown a fault of its own ──
  var mailControls = 0;
  func i17(words : Text) : Bool {
    var hit = false; var stray = false;
    for (v in List.values(walk().violations)) { if (Text.startsWith(v, #text "I17 mail")) { if (Text.contains(v, #text words)) hit := true } else stray := true };
    hit and not stray
  };
  func control(caught : Bool, what : Text) { check(caught, what); if (caught) mailControls += 1 };
  func withMsg(id : Nat, o : R.Outbox, words : Text, what : Text) {
    let was = msg(id);
    RowStore.put<R.Outbox>(outT, R.outbox, id, o);
    control(i17(words), what);
    RowStore.put<R.Outbox>(outT, R.outbox, id, was);
  };
  func withAddr(id : Nat, m : R.MailAddress, words : Text, what : Text) {
    let was = addr(id);
    RowStore.put<R.MailAddress>(addrT, R.mailAddress, id, m);
    control(i17(words), what);
    RowStore.put<R.MailAddress>(addrT, R.mailAddress, id, was);
  };
  func withSetup(m : R.MailSetup, words : Text, what : Text) {
    let was = setup();
    RowStore.put<R.MailSetup>(setT, R.mailSetup, St.MAIL_SETUP_ID, m);
    control(i17(words), what);
    RowStore.put<R.MailSetup>(setT, R.mailSetup, St.MAIL_SETUP_ID, was);
  };
  let B6 = byPhone(T + 20, 1, "Bilal");
  withMsg(C1, { msg(C1) with bookingId = B6 }, "the booking gave no address", "a message for a booking with no address is named I17");
  withMsg(C1, { msg(C1) with kind = #receipt }, "a receipt, and the booking is confirmed", "a receipt owed for a stay not checked out is named I17");
  withMsg(C1, { msg(C1) with kind = #cancellation }, "a cancellation notice, and the booking is confirmed", "a cancellation owed for a booking not cancelled is named I17");
  withMsg(P5, { msg(P5) with state = #due }, "a note before arrival still due, and the booking is no-show", "a note still due for a no-show is named I17");
  withMsg(P1, { msg(P1) with notBefore = bk(B1).arrival }, "a note before arrival due on day", "a note due on the arrival itself is named I17");
  withMsg(C1, { msg(C1) with notBefore = 5 }, "only a note before arrival waits", "a confirmation that waits for a day is named I17");
  withMsg(C1, { msg(C1) with attempts = 4 }, "past three", "a message tried four times is named I17");
  withMsg(C1, { msg(C1) with failure = #rejected }, "sent, with", "a message sent with a failure is named I17");
  withMsg(C2, { msg(C2) with attempts = 2 }, "failed after 2 attempts", "a message failed before its third try is named I17");
  withMsg(P1, { msg(P1) with attempts = 3; failure = #unavailable }, "still due after 3 attempts", "a message still due after three tries is named I17");
  withMsg(P1, { msg(P1) with attempts = 1 }, "due with 1 attempts and failure ''", "a failed try with no reason is named I17");
  withMsg(C1, { msg(C1) with queuedBlock = 0 }, "queued in block 0", "a message queued in no block is named I17");
  withAddr(B1, { addr(B1) with sealed = bk(B1).guestName }, "is not sealed", "an address in the clear is named I17");
  withAddr(B1, { addr(B1) with preArrival = 999_999 }, "which does not exist", "an address naming a message that does not exist is named I17");
  withAddr(B1, { addr(B1) with receipt = C1 }, "for its receipt, which is not", "an address naming a confirmation as its receipt is named I17");
  withAddr(B1, { addr(B1) with confirmation = 0 }, "has no confirmation", "an address with no confirmation is named I17");
  withAddr(B3, { addr(B3) with cancellation = 0 }, "no cancellation notice is owed", "a cancelled booking with no cancellation notice is named I17");
  withAddr(B4, { addr(B4) with receipt = 0 }, "no receipt is owed", "a stay checked out with no receipt is named I17");
  withSetup({ setup() with tested = Mail.noDigest() }, "has not tested", "guest email on with an untested account is named I17");
  withSetup({ setup() with mailKey = Mail.noKey() }, "no relay connected", "guest email on with no relay is named I17");
  withSetup({ setup() with on = false; tested = digest(0x77) }, "is not the one authorised", "a test of another account is named I17");
  withSetup({ setup() with mailKey = Blob.fromArray(Array.tabulate<Nat8>(65, func(i) { if (i == 0) 5 else 1 })) }, "not a raw P-256 point", "a mail key that is no point is named I17");
  withSetup({ setup() with mailerGrant = g1 }, "is not an active mailer grant", "a relay whose grant was ended is named I17");
  withSetup({ setup() with mailerGrant = 999_999 }, "does not exist", "a relay with no grant is named I17");
  clean("after the I17 controls are put back");

  Debug.print("count: mail refusals that left the state untouched = " # Nat.toText(untouched));
  Debug.print("count: mail controls that went red for their own rule = " # Nat.toText(mailControls));
};

// ── replay ───────────────────────────────────────────────────────────────────

do {
  let r = Con.replayAll(log);
  check(r.refusals.size() == 0, "every block replays: " # debug_show r.refusals);
  check(St.fingerprintHash(r.stores, r.later) == St.fingerprintHash(s, later), "the log rebuilds the state byte for byte");
  check(St.hotelClock(r.later) == St.hotelClock(later), "the log rebuilds the hotel clock");
  check(RowStore.size(St.later(r.later, St.HK_TABLE)) == RowStore.size(St.later(later, St.HK_TABLE)) and RowStore.size(St.later(later, St.HK_TABLE)) > 0
    and St.housekeeping(r.later, 1) == St.housekeeping(later, 1), "the log rebuilds the housekeeping rows");
  // control: a row changed beside the fold is a different state
  let id = R.nightId(2, DAY + 29);
  let ?n = RowStore.get<R.Night>(s.nights, R.night, id) else Runtime.trap("night");
  RowStore.put<R.Night>(s.nights, R.night, id, { n with bar = n.bar + 1 });
  check(St.fingerprintHash(r.stores, r.later) != St.fingerprintHash(s, later), "a row changed beside the fold changes the fingerprint");
  RowStore.put<R.Night>(s.nights, R.night, id, n);
  Debug.print("count: blocks replayed = " # Nat.toText(DL.length(log)));
};

// ── references ───────────────────────────────────────────────────────────────

do {
  var n = 0;
  for (id in [1, 2, 99, 12_345, 100_000].vals()) { check(Ref.parse(Ref.of(id)) == ?id, "reference round-trips for " # Nat.toText(id)); n += 1 };
  let bad = Text.replace(Ref.of(7), #text "-", "-");
  let chars = Text.toArray(bad);
  let flipped = Text.fromArray(Array.tabulate<Char>(chars.size(), func(i) { if (i == 10) (if (chars[10] == '0') '1' else '0') else chars[i] }));
  check(Ref.parse(flipped) == null, "a wrong check character is refused");
  Debug.print("count: references checked = " # Nat.toText(n));
};

// ── the export, for the independent reader (tools/oracle_twin.py) ─────────────
//
// Every row of the tables the laws read, as the bytes the store holds, with the business day, the
// fold's cash counters and the contract oracle's own verdict. The twin decodes the bytes from the
// declared layouts with code it wrote itself and must reach the same verdict.

do {
  var exported = 0;
  func dump<Row>(name : Text, store : RowStore.Store, decl : RowStore.Decl<Row>, hi : Nat) {
    var cursor : ?Blob = null;
    label pages loop {
      let pg = RowStore.pageById<Row>(store, decl, 0, hi, cursor, 200);
      for ((id, row) in pg.rows.vals()) {
        Debug.print("export: row " # name # " " # Nat.toText(id) # " " # C.hex(decl.encode(row)));
        exported += 1;
      };
      switch (pg.next) { case (?c) cursor := ?c; case null break pages };
    };
  };
  dump<R.RoomType>("roomType", s.roomTypes, R.roomType, St.MAX_ID);
  dump<R.Room>("room", s.rooms, R.room, St.MAX_ID);
  dump<R.Night>("night", s.nights, R.night, St.pow256(R.NIGHT_ID_BYTES) - 1);
  dump<R.Hold>("hold", s.holds, R.hold, St.MAX_ID);
  dump<R.Booking>("booking", s.bookings, R.booking, St.MAX_ID);
  dump<R.FolioLine>("folio", s.folio, R.folioLine, St.MAX_ID);
  dump<R.Payment>("payment", s.payments, R.payment, St.MAX_ID);
  dump<R.Housekeeping>("housekeeping", St.later(later, St.HK_TABLE), R.housekeeping, St.MAX_ID);
  dump<R.Charge>("charge", St.later(later, St.CHARGE_TABLE), R.charge, St.MAX_ID);
  dump<R.Payer>("payer", St.later(later, St.PAYER_TABLE), R.payer, St.MAX_ID);
  dump<R.Route>("lineRoute", St.later(later, St.LINE_ROUTE_TABLE), R.lineRoute, St.MAX_ID);
  dump<R.Route>("paymentRoute", St.later(later, St.PAYMENT_ROUTE_TABLE), R.paymentRoute, St.MAX_ID);
  dump<R.RefundSlice>("refundSlice", St.later(later, St.REFUND_SLICE_TABLE), R.refundSlice, St.MAX_ID);
  dump<R.Invoice>("invoice", St.later(later, St.INVOICE_TABLE), R.invoice, St.MAX_ID);
  dump<R.CreditNote>("creditNote", St.later(later, St.CREDIT_NOTE_TABLE), R.creditNote, St.MAX_ID);
  dump<R.CreditLine>("creditLine", St.later(later, St.CREDIT_LINE_TABLE), R.creditLine, St.MAX_ID);
  dump<R.DeskRefund>("deskRefund", St.later(later, St.DESK_REFUND_TABLE), R.deskRefund, St.MAX_ID);
  dump<R.StaffBooking>("staffBooking", St.later(later, St.STAFF_BOOKING_TABLE), R.staffBooking, St.MAX_ID);
  dump<R.DayFigures>("dayFigures", St.later(later, St.DAY_FIGURES_TABLE), R.dayFigures, St.MAX_ID);
  dump<R.DayRevenue>("dayRevenue", St.later(later, St.DAY_REVENUE_TABLE), R.dayRevenue, St.MAX_ID);
  dump<R.Proposal>("proposal", s.proposals, R.proposal, St.MAX_ID);
  dump<R.Company>("company", St.later(later, St.COMPANY_TABLE), R.company, St.MAX_ID);
  dump<R.PlanAccess>("planAccess", St.later(later, St.PLAN_ACCESS_TABLE), R.planAccess, St.MAX_ID);
  dump<R.RateGrant>("holdRate", St.later(later, St.HOLD_RATE_TABLE), R.holdRate, St.MAX_ID);
  dump<R.RateGrant>("bookingRate", St.later(later, St.BOOKING_RATE_TABLE), R.bookingRate, St.MAX_ID);
  dump<R.Promo>("promo", St.later(later, St.PROMO_TABLE), R.promo, St.MAX_ID);
  dump<R.Block>("block", St.later(later, St.BLOCK_TABLE), R.block, St.MAX_ID);
  dump<R.BlockNight>("blockNight", St.later(later, St.BLOCK_NIGHT_TABLE), R.blockNight, St.MAX_ID);
  dump<R.NightBlock>("nightBlock", St.later(later, St.NIGHT_BLOCK_TABLE), R.nightBlock, St.pow256(R.NIGHT_ID_BYTES) - 1);
  dump<R.BookingBlock>("bookingBlock", St.later(later, St.BOOKING_BLOCK_TABLE), R.bookingBlock, St.MAX_ID);
  dump<R.FolioLine>("holdLine", s.holdLines, R.folioLine, St.MAX_ID);
  dump<R.Extra>("extra", St.later(later, St.EXTRA_TABLE), R.extra, St.MAX_ID);
  dump<R.PlanInclusion>("planInclusion", St.later(later, St.PLAN_INCLUSION_TABLE), R.planInclusion, St.MAX_ID);
  dump<R.PackageLine>("packageLine", St.later(later, St.PACKAGE_LINE_TABLE), R.packageLine, St.MAX_ID);
  dump<R.PackageLine>("holdPackage", St.later(later, St.HOLD_PACKAGE_TABLE), R.holdPackage, St.MAX_ID);
  dump<R.RatePlan>("ratePlan", s.plans, R.ratePlan, St.MAX_PLANS);
  dump<R.CardOnFile>("cardOnFile", St.later(later, St.CARD_TABLE), R.cardOnFile, St.MAX_ID);
  dump<R.PlanDeposit>("planDeposit", St.later(later, St.PLAN_DEPOSIT_TABLE), R.planDeposit, St.MAX_ID);
  dump<R.CardPolicy>("cardPolicy", St.later(later, St.CARD_POLICY_TABLE), R.cardPolicy, St.MAX_ID);
  dump<R.Outbox>("outbox", St.later(later, St.OUTBOX_TABLE), R.outbox, St.MAX_ID);
  dump<R.MailAddress>("mailAddress", St.later(later, St.MAIL_ADDRESS_TABLE), R.mailAddress, St.MAX_ID);
  dump<R.MailSetup>("mailSetup", St.later(later, St.MAIL_SETUP_TABLE), R.mailSetup, St.MAX_ID);
  dump<R.Rules>("rules", St.later(later, St.RULES_TABLE), R.rules, St.MAX_ID);
  // the audit's walk as it stands, for the reader to hold against the span the rules row gives it
  Debug.print("export: walk " # Nat.toText(s.walk.section) # " " # (if (s.walk.done) "1" else "0"));
  dump<R.Grant>("grant", s.grants, R.grant, St.MAX_ID);
  // each address's sealed text, as the arena holds it: the twin checks its shape, as the oracle does
  for ((id, m) in RowStore.pageById<R.MailAddress>(St.later(later, St.MAIL_ADDRESS_TABLE), R.mailAddress, 0, St.MAX_ID, null, 1_000).rows.vals()) {
    Debug.print("export: sealed " # Nat.toText(id) # " " # TA.get(s.arena, m.sealed));
  };
  // what each permission guards, by its place in the catalogue: a proposal names its permission by place
  for (i in Nat.range(0, Staff.catalogue().size())) Debug.print("export: permission " # Nat.toText(i) # " " # Staff.guardOf(i));
  Debug.print("export: day " # Nat.toText(today()));
  Debug.print("export: counter paidTotal " # Nat.toText(s.paidTotal));
  Debug.print("export: counter capturedDone " # Nat.toText(s.capturedDone));
  Debug.print("export: counter refundsCommitted " # Nat.toText(s.refundsCommitted));
  // the contract's verdict over the same state, every page of every section
  var verdicts = 0;
  for (section in Nat.range(0, O.SECTIONS)) {
    var cursor : ?Blob = null;
    label pages loop {
      let r = O.page(ctx(), section, cursor, 200);
      for (x in r.violations.vals()) { Debug.print("export: oracle " # x.rule # " | " # x.detail); verdicts += 1 };
      switch (r.next) { case (?c) cursor := ?c; case null break pages };
    };
  };
  Debug.print("export: oracle done " # Nat.toText(verdicts));
  Debug.print("count: rows exported = " # Nat.toText(exported));
};

Debug.print("count: checks = " # Nat.toText(checks));
if (failures > 0) { Debug.print("FAIL: " # Nat.toText(failures) # " check(s) failed"); Runtime.trap("battery red") };
