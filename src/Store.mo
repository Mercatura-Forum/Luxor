/// Store.mo - the hotel's state: every table, every counter, and the fingerprint over all of them.
///
/// THE FINGERPRINT COVERS EVERYTHING A COMMAND CAN MOVE. Every table is walked row by row through
/// the same paged cursor a reader uses, every id counter and money counter is written, and the arena's
/// strings are written beside the rows that point at them. A table or counter missing from it is one
/// whose corruption a replay comparison would never notice, so the battery asserts the section count.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";

import BatchCore "mo:kernel/batch/BatchCore";
import Evidence "mo:kernel/eco/Evidence";
import KeyRing "mo:kernel/eco/KeyRing";
import C "mo:kernel/codec/Canonical";
import Fold "mo:kernel/domain/Fold";
import Page "mo:kernel/rows/Page";
import RowStore "mo:kernel/rows/RowStore";
import SR "mo:kernel/rows/StableRows";

import E "Enums";
import Q "Quote";
import R "Rows";
import TA "TextArena";
import W "Widths";

module {

  /// The identity-document table's row (the fold is in IdDocs.mo; the row lives here, where the stores do).
  public type IdDocRow = { bookingId : Nat; documentId : Nat; eraseDay : Nat; erased : Bool; lastBlock : Nat };

  public let ID_DOC_DECL : RowStore.Decl<IdDocRow> = {
    table = "idDoc";
    idBytes = W.ID;
    rowBytes = W.ID_DOC_ROW;
    encode = func(x : IdDocRow) : Blob {
      let b = SR.buf();
      SR.putNat(b, x.bookingId, W.ID);
      SR.putNat(b, x.documentId, W.ID);
      SR.putNat(b, x.eraseDay, W.DAY);
      SR.putBool(b, x.erased);
      SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.ID_DOC_ROW)
    };
    decode = func(a : [Nat8]) : IdDocRow {
      { bookingId = SR.getNat(a, 0, 6); documentId = SR.getNat(a, 6, 6); eraseDay = SR.getNat(a, 12, 3); erased = SR.getBool(a, 15); lastBlock = SR.getNat(a, 16, 6) }
    };
    indexes = [
      { name = "due"; keyBytes = 9; keyOf = func(id : Nat, x : IdDocRow) : ?Blob { if (x.erased) null else ?SR.key2(x.eraseDay, W.DAY, id, W.ID) } },
      { name = "by_booking"; keyBytes = 12; keyOf = func(id : Nat, x : IdDocRow) : ?Blob { ?SR.key2(x.bookingId, W.ID, id, W.ID) } },
    ];
  };

  public let PROPERTY_ID : Nat = 1;
  public let MAX_TAX_RULES : Nat = 8;
  public let MAX_PLANS : Nat = 16;
  public let MAX_ROOMS_PER_TYPE : Nat = 1_000;
  public let MAX_LIVE_HOLDS_PER_OWNER : Nat = 2;
  public let MAX_WAITLIST_PER_TYPE : Nat = 16;
  /// A merchant reference at or above this names a booking rather than a hold.
  public let BOOKING_REF_BASE : Nat = 1_000_000_000_000;

  /// The resumable walk the night audit drives the oracle through.
  public type OracleWalk = {
    var day : Nat;
    var section : Nat;
    var cursor : ?Blob;
    var examined : Nat;
    var violations : [Text];
    var done : Bool;
  };

  public type Stores = {
    var property : RowStore.Store;
    var roomTypes : RowStore.Store;
    var rooms : RowStore.Store;
    var plans : RowStore.Store;
    var taxes : RowStore.Store;
    var nights : RowStore.Store;
    var holds : RowStore.Store;
    var holdLines : RowStore.Store;
    var bookings : RowStore.Store;
    var folio : RowStore.Store;
    var payments : RowStore.Store;
    var waitlist : RowStore.Store;
    var grants : RowStore.Store;
    var proposals : RowStore.Store;
    var idDocs : RowStore.Store;
    arena : TA.Arena;
    /// Identity documents: ciphertext, file keys sealed to the hotel's key, erased by destroying them.
    evidence : Evidence.State;
    keys : KeyRing.State;
    audit : BatchCore.State;
    walk : OracleWalk;
    var nextRoomTypeId : Nat;
    var nextRoomId : Nat;
    var nextPlanId : Nat;
    var nextTaxId : Nat;
    var nextHoldId : Nat;
    var nextHoldLineId : Nat;
    var nextBookingId : Nat;
    var nextFolioId : Nat;
    var nextPaymentId : Nat;
    var nextWaitId : Nat;
    var nextGrantId : Nat;
    var nextProposalId : Nat;
    var nextIdDocId : Nat;
    /// Money the gateway has confirmed captured, and money committed back to guests (refunds queued
    /// or done). Their difference is what the hotel holds for its bookings: the cash identity I5.
    var capturedDone : Nat;
    var refundsCommitted : Nat;
    /// The sum of every booking's `paid`, kept by the fold beside the rows it sums.
    var paidTotal : Nat;
    var blocksApplied : Nat;
    var closedDays : Nat;
    /// The counts the open audit's plan was fixed from: (day, expired holds, arrivals). The plan is
    /// recomputed from these at every step and checked against the run's recorded hash.
    var auditCounts : (Nat, Nat, Nat, Nat);
    /// The hotel's guest-data public key (raw P-256, 65 bytes), empty until the owner sets one.
    var guestDataKey : Blob;
  };

  public func newStores() : Stores {
    {
      var property = RowStore.newStore<R.Property>(R.property);
      var roomTypes = RowStore.newStore<R.RoomType>(R.roomType);
      var rooms = RowStore.newStore<R.Room>(R.room);
      var plans = RowStore.newStore<R.RatePlan>(R.ratePlan);
      var taxes = RowStore.newStore<R.TaxRule>(R.taxRule);
      var nights = RowStore.newStore<R.Night>(R.night);
      var holds = RowStore.newStore<R.Hold>(R.hold);
      var holdLines = RowStore.newStore<R.FolioLine>(R.folioLine);
      var bookings = RowStore.newStore<R.Booking>(R.booking);
      var folio = RowStore.newStore<R.FolioLine>(R.folioLine);
      var payments = RowStore.newStore<R.Payment>(R.payment);
      var waitlist = RowStore.newStore<R.WaitEntry>(R.waitlist);
      var grants = RowStore.newStore<R.Grant>(R.grant);
      var proposals = RowStore.newStore<R.Proposal>(R.proposal);
      var idDocs = RowStore.newStore<IdDocRow>(ID_DOC_DECL);
      arena = TA.newArena();
      evidence = Evidence.newState();
      keys = KeyRing.newState();
      audit = BatchCore.newState();
      walk = { var day = 0; var section = 0; var cursor = null; var examined = 0; var violations = []; var done = false };
      var nextRoomTypeId = 1;
      var nextRoomId = 1;
      var nextPlanId = 1;
      var nextTaxId = 1;
      var nextHoldId = 1;
      var nextHoldLineId = 1;
      var nextBookingId = 1;
      var nextFolioId = 1;
      var nextPaymentId = 1;
      var nextWaitId = 1;
      var nextGrantId = 1;
      var nextProposalId = 1;
      var nextIdDocId = 1;
      var capturedDone = 0;
      var refundsCommitted = 0;
      var paidTotal = 0;
      var blocksApplied = 0;
      var closedDays = 0;
      var auditCounts = (0, 0, 0, 0);
      var guestDataKey = "";
    }
  };

  // ── the tables that came after go-live ──────────────────────────────────────

  /// `Stores` is frozen: it is one persistent record, and a field added to it is an upgrade the substrate
  /// refuses (M0170, measured with moc's own --stable-compatible). A table that arrives after go-live is
  /// a NAMED store here instead, declared in `LATER` and made when this record is first made or, for a
  /// contract that already has the record, on the upgrade that brings the declaration (`ensureLater`).
  /// The fold reaches it through `later`, whose names are constants of this module.
  public type Later = { tables : Map.Map<Text, RowStore.Store> };

  public let CLOCK_TABLE : Text = "hotelClock";
  /// The hotel clock is one row: its id.
  public let CLOCK_ID : Nat = 1;

  /// Housekeeping: one row per room that has a record, under the room's id.
  public let HK_TABLE : Text = "housekeeping";

  /// The bill: the extras catalogue, extras posted, the payers of split bills, the window of each line
  /// and payment, and the invoices. Rows are never removed, so a table's next id is its size plus one.
  public let EXTRA_TABLE : Text = "extra";
  public let CHARGE_TABLE : Text = "charge";
  public let PAYER_TABLE : Text = "payer";
  public let LINE_ROUTE_TABLE : Text = "lineRoute";
  public let PAYMENT_ROUTE_TABLE : Text = "paymentRoute";
  public let INVOICE_TABLE : Text = "invoice";

  /// Credit notes: each under its number in a run of its own, its lines under their credit folio line
  /// ids; refunds paid at the desk when the gateway would not make them; and what the tax authority's
  /// documents need: each tax rule's codes and the hotel's registration.
  public let CREDIT_NOTE_TABLE : Text = "creditNote";
  public let CREDIT_LINE_TABLE : Text = "creditLine";
  public let DESK_REFUND_TABLE : Text = "deskRefund";
  public let TAX_ETA_TABLE : Text = "taxEta";
  public let ETA_PROFILE_TABLE : Text = "etaProfile";
  /// The hotel's registration is one row: its id.
  public let ETA_PROFILE_ID : Nat = 1;

  /// The bookings staff took (by phone, or a guest at the desk), under the booking's id.
  public let STAFF_BOOKING_TABLE : Text = "staffBooking";

  /// The night audit's figures: one row per audited business day, under the day; and each night's
  /// room nights and room revenue by room type and rate plan, in a run of their own.
  public let DAY_FIGURES_TABLE : Text = "dayFigures";
  /// The night audit's batch scope (its runs are keyed by it and the business day).
  public let AUDIT_SCOPE : Text = "night";
  public let DAY_REVENUE_TABLE : Text = "dayRevenue";

  /// The slices of each refund to a guest across the guest's own cards, under the refund's payment id.
  public let REFUND_SLICE_TABLE : Text = "refundSlice";
  /// Rate products: companies with negotiated rates, who each plan is sold to, and the access a hold
  /// or a booking was sold its rate under.
  public let COMPANY_TABLE : Text = "company";
  public let PLAN_ACCESS_TABLE : Text = "planAccess";
  public let HOLD_RATE_TABLE : Text = "holdRate";
  public let BOOKING_RATE_TABLE : Text = "bookingRate";
  public let PROMO_TABLE : Text = "promo";
  /// Group blocks: the block, each of its nights, the rooms open blocks hold on each hotel night, the
  /// block a booking was picked up from, and the blocks each day's audit found at their cut-off.
  public let BLOCK_TABLE : Text = "block";
  public let BLOCK_NIGHT_TABLE : Text = "blockNight";
  public let NIGHT_BLOCK_TABLE : Text = "nightBlock";
  public let BOOKING_BLOCK_TABLE : Text = "bookingBlock";
  public let AUDIT_BLOCKS_TABLE : Text = "auditBlocks";
  /// Packages: each plan's inclusions, and the inclusion behind each package line of a booking's folio
  /// and of a hold.
  public let PLAN_INCLUSION_TABLE : Text = "planInclusion";
  public let PACKAGE_LINE_TABLE : Text = "packageLine";
  public let HOLD_PACKAGE_TABLE : Text = "holdPackage";
  /// Deposits and the card on file: each deposit plan's share, each booking's card, the hotel's card rule.
  public let PLAN_DEPOSIT_TABLE : Text = "planDeposit";
  public let CARD_TABLE : Text = "cardOnFile";
  public let CARD_POLICY_TABLE : Text = "cardPolicy";
  public let CARD_POLICY_ID : Nat = 1;
  /// Guest emails: the messages owed, each booking's sealed address, the relay's setup.
  public let OUTBOX_TABLE : Text = "outbox";
  public let MAIL_ADDRESS_TABLE : Text = "mailAddress";
  public let MAIL_SETUP_TABLE : Text = "mailSetup";
  public let MAIL_SETUP_ID : Nat = 1;
  /// The rules the log adopted (`Rules`): one row, written first by `#adoptRules`.
  public let RULES_TABLE : Text = "rules";
  public let RULES_ID : Nat = 1;

  /// Every later table, in the order the fingerprint writes them.
  let LATER : [(Text, () -> RowStore.Store)] = [
    (CLOCK_TABLE, func() : RowStore.Store { RowStore.newStore<R.HotelClock>(R.hotelClock) }),
    (HK_TABLE, func() : RowStore.Store { RowStore.newStore<R.Housekeeping>(R.housekeeping) }),
    (EXTRA_TABLE, func() : RowStore.Store { RowStore.newStore<R.Extra>(R.extra) }),
    (CHARGE_TABLE, func() : RowStore.Store { RowStore.newStore<R.Charge>(R.charge) }),
    (PAYER_TABLE, func() : RowStore.Store { RowStore.newStore<R.Payer>(R.payer) }),
    (LINE_ROUTE_TABLE, func() : RowStore.Store { RowStore.newStore<R.Route>(R.lineRoute) }),
    (PAYMENT_ROUTE_TABLE, func() : RowStore.Store { RowStore.newStore<R.Route>(R.paymentRoute) }),
    (INVOICE_TABLE, func() : RowStore.Store { RowStore.newStore<R.Invoice>(R.invoice) }),
    (CREDIT_NOTE_TABLE, func() : RowStore.Store { RowStore.newStore<R.CreditNote>(R.creditNote) }),
    (CREDIT_LINE_TABLE, func() : RowStore.Store { RowStore.newStore<R.CreditLine>(R.creditLine) }),
    (DESK_REFUND_TABLE, func() : RowStore.Store { RowStore.newStore<R.DeskRefund>(R.deskRefund) }),
    (TAX_ETA_TABLE, func() : RowStore.Store { RowStore.newStore<R.TaxEta>(R.taxEta) }),
    (ETA_PROFILE_TABLE, func() : RowStore.Store { RowStore.newStore<R.EtaProfile>(R.etaProfile) }),
    (STAFF_BOOKING_TABLE, func() : RowStore.Store { RowStore.newStore<R.StaffBooking>(R.staffBooking) }),
    (DAY_FIGURES_TABLE, func() : RowStore.Store { RowStore.newStore<R.DayFigures>(R.dayFigures) }),
    (DAY_REVENUE_TABLE, func() : RowStore.Store { RowStore.newStore<R.DayRevenue>(R.dayRevenue) }),
    (REFUND_SLICE_TABLE, func() : RowStore.Store { RowStore.newStore<R.RefundSlice>(R.refundSlice) }),
    (COMPANY_TABLE, func() : RowStore.Store { RowStore.newStore<R.Company>(R.company) }),
    (PLAN_ACCESS_TABLE, func() : RowStore.Store { RowStore.newStore<R.PlanAccess>(R.planAccess) }),
    (HOLD_RATE_TABLE, func() : RowStore.Store { RowStore.newStore<R.RateGrant>(R.holdRate) }),
    (BOOKING_RATE_TABLE, func() : RowStore.Store { RowStore.newStore<R.RateGrant>(R.bookingRate) }),
    (PROMO_TABLE, func() : RowStore.Store { RowStore.newStore<R.Promo>(R.promo) }),
    (BLOCK_TABLE, func() : RowStore.Store { RowStore.newStore<R.Block>(R.block) }),
    (BLOCK_NIGHT_TABLE, func() : RowStore.Store { RowStore.newStore<R.BlockNight>(R.blockNight) }),
    (NIGHT_BLOCK_TABLE, func() : RowStore.Store { RowStore.newStore<R.NightBlock>(R.nightBlock) }),
    (BOOKING_BLOCK_TABLE, func() : RowStore.Store { RowStore.newStore<R.BookingBlock>(R.bookingBlock) }),
    (AUDIT_BLOCKS_TABLE, func() : RowStore.Store { RowStore.newStore<R.AuditBlocks>(R.auditBlocks) }),
    (PLAN_INCLUSION_TABLE, func() : RowStore.Store { RowStore.newStore<R.PlanInclusion>(R.planInclusion) }),
    (PACKAGE_LINE_TABLE, func() : RowStore.Store { RowStore.newStore<R.PackageLine>(R.packageLine) }),
    (HOLD_PACKAGE_TABLE, func() : RowStore.Store { RowStore.newStore<R.PackageLine>(R.holdPackage) }),
    (PLAN_DEPOSIT_TABLE, func() : RowStore.Store { RowStore.newStore<R.PlanDeposit>(R.planDeposit) }),
    (CARD_TABLE, func() : RowStore.Store { RowStore.newStore<R.CardOnFile>(R.cardOnFile) }),
    (CARD_POLICY_TABLE, func() : RowStore.Store { RowStore.newStore<R.CardPolicy>(R.cardPolicy) }),
    (OUTBOX_TABLE, func() : RowStore.Store { RowStore.newStore<R.Outbox>(R.outbox) }),
    (MAIL_ADDRESS_TABLE, func() : RowStore.Store { RowStore.newStore<R.MailAddress>(R.mailAddress) }),
    (MAIL_SETUP_TABLE, func() : RowStore.Store { RowStore.newStore<R.MailSetup>(R.mailSetup) }),
    (RULES_TABLE, func() : RowStore.Store { RowStore.newStore<R.Rules>(R.rules) }),
  ];

  /// How many later tables are declared: the battery holds `LATER_SECTIONS` to it.
  public func laterTables() : Nat { LATER.size() };

  public func newLater() : Later { let x : Later = { tables = Map.empty() }; ensureLater(x); x };

  /// Makes every declared table the record does not hold yet. Idempotent; run on every upgrade.
  public func ensureLater(x : Later) {
    for ((name, make) in LATER.vals()) {
      if (not Map.containsKey(x.tables, Text.compare, name)) Map.add(x.tables, Text.compare, name, make());
    };
  };

  /// A declared later table. Every name passed here is one of `LATER`'s, and `newLater` / `ensureLater`
  /// made each of them before any command could run, so the null arm is a build fault, not a state.
  public func later(x : Later, name : Text) : RowStore.Store {
    switch (Map.get(x.tables, Text.compare, name)) { case (?t) t; case null Runtime.trap("Store: no later table " # name) }
  };

  public func hotelClock(x : Later) : ?R.HotelClock { RowStore.get<R.HotelClock>(later(x, CLOCK_TABLE), R.hotelClock, CLOCK_ID) };

  public func housekeeping(x : Later, roomId : Nat) : ?R.Housekeeping { RowStore.get<R.Housekeeping>(later(x, HK_TABLE), R.housekeeping, roomId) };

  public func extra(x : Later, id : Nat) : ?R.Extra { RowStore.get<R.Extra>(later(x, EXTRA_TABLE), R.extra, id) };
  public func charge(x : Later, lineId : Nat) : ?R.Charge { RowStore.get<R.Charge>(later(x, CHARGE_TABLE), R.charge, lineId) };
  public func payer(x : Later, id : Nat) : ?R.Payer { RowStore.get<R.Payer>(later(x, PAYER_TABLE), R.payer, id) };
  public func invoice(x : Later, number : Nat) : ?R.Invoice { RowStore.get<R.Invoice>(later(x, INVOICE_TABLE), R.invoice, number) };
  public func creditNote(x : Later, number : Nat) : ?R.CreditNote { RowStore.get<R.CreditNote>(later(x, CREDIT_NOTE_TABLE), R.creditNote, number) };
  public func creditLine(x : Later, lineId : Nat) : ?R.CreditLine { RowStore.get<R.CreditLine>(later(x, CREDIT_LINE_TABLE), R.creditLine, lineId) };
  public func deskRefund(x : Later, paymentId : Nat) : ?R.DeskRefund { RowStore.get<R.DeskRefund>(later(x, DESK_REFUND_TABLE), R.deskRefund, paymentId) };
  public func staffBooking(x : Later, bookingId : Nat) : ?R.StaffBooking { RowStore.get<R.StaffBooking>(later(x, STAFF_BOOKING_TABLE), R.staffBooking, bookingId) };
  public func refundSlice(x : Later, paymentId : Nat) : ?R.RefundSlice { RowStore.get<R.RefundSlice>(later(x, REFUND_SLICE_TABLE), R.refundSlice, paymentId) };
  public func company(x : Later, id : Nat) : ?R.Company { RowStore.get<R.Company>(later(x, COMPANY_TABLE), R.company, id) };
  public func planAccess(x : Later, planId : Nat) : ?R.PlanAccess { RowStore.get<R.PlanAccess>(later(x, PLAN_ACCESS_TABLE), R.planAccess, planId) };
  public func holdRate(x : Later, holdId : Nat) : ?R.RateGrant { RowStore.get<R.RateGrant>(later(x, HOLD_RATE_TABLE), R.holdRate, holdId) };
  public func bookingRate(x : Later, bookingId : Nat) : ?R.RateGrant { RowStore.get<R.RateGrant>(later(x, BOOKING_RATE_TABLE), R.bookingRate, bookingId) };
  public func promo(x : Later, id : Nat) : ?R.Promo { RowStore.get<R.Promo>(later(x, PROMO_TABLE), R.promo, id) };
  public func block(x : Later, id : Nat) : ?R.Block { RowStore.get<R.Block>(later(x, BLOCK_TABLE), R.block, id) };
  public func blockNight(x : Later, blockId : Nat, day : Nat) : ?R.BlockNight { RowStore.get<R.BlockNight>(later(x, BLOCK_NIGHT_TABLE), R.blockNight, R.blockNightId(blockId, day)) };
  public func bookingBlock(x : Later, bookingId : Nat) : ?R.BookingBlock { RowStore.get<R.BookingBlock>(later(x, BOOKING_BLOCK_TABLE), R.bookingBlock, bookingId) };
  public func auditBlocks(x : Later, day : Nat) : ?R.AuditBlocks { RowStore.get<R.AuditBlocks>(later(x, AUDIT_BLOCKS_TABLE), R.auditBlocks, day) };
  /// A plan's inclusion rows, every slot written so far (on or off), in slot order.
  public func inclusionSlots(x : Later, planId : Nat) : [(Nat, R.PlanInclusion)] {
    let rows = RowStore.pageById<R.PlanInclusion>(later(x, PLAN_INCLUSION_TABLE), R.planInclusion, R.inclusionId(planId, 1), R.inclusionId(planId, R.MAX_INCLUSIONS), null, R.MAX_INCLUSIONS).rows;
    Array.map<(Nat, R.PlanInclusion), (Nat, R.PlanInclusion)>(rows, func((id, r)) { (id % 16, r) })
  };
  /// A plan's inclusions on sale now: its package (empty for a plain rate), by slot.
  public func inclusionsOf(x : Later, planId : Nat) : [(Nat, R.PlanInclusion)] {
    Array.filter<(Nat, R.PlanInclusion)>(inclusionSlots(x, planId), func((_, r)) { r.on })
  };
  public func packageLine(x : Later, lineId : Nat) : ?R.PackageLine { RowStore.get<R.PackageLine>(later(x, PACKAGE_LINE_TABLE), R.packageLine, lineId) };
  public func holdPackage(x : Later, holdLineId : Nat) : ?R.PackageLine { RowStore.get<R.PackageLine>(later(x, HOLD_PACKAGE_TABLE), R.holdPackage, holdLineId) };

  /// A deposit plan's share of the room's stay, in basis points (0: the plan has none set).
  public func depositBps(x : Later, planId : Nat) : Nat {
    switch (RowStore.get<R.PlanDeposit>(later(x, PLAN_DEPOSIT_TABLE), R.planDeposit, planId)) { case (?d) d.depositBps; case null 0 }
  };
  public func card(x : Later, bookingId : Nat) : ?R.CardOnFile { RowStore.get<R.CardOnFile>(later(x, CARD_TABLE), R.cardOnFile, bookingId) };
  /// Whether the hotel's card rule is on: guaranteed plans keep a card on file.
  /// The rules row, or null before the log adopted any (epoch 0).
  public func rulesRow(x : Later) : ?R.Rules { RowStore.get<R.Rules>(later(x, RULES_TABLE), R.rules, RULES_ID) };

  public func cardRequired(x : Later) : Bool { RowStore.get<R.CardPolicy>(later(x, CARD_POLICY_TABLE), R.cardPolicy, CARD_POLICY_ID) != null };
  /// Whether a plan keeps the guest's card on file under the hotel's rule: guaranteed by the first night
  /// or a deposit. A prepaid plan has taken the whole stay and has nothing to charge later.
  public func keepsCard(x : Later, plan : R.RatePlan) : Bool { cardRequired(x) and plan.guarantee != #prepaidInFull };
  /// The cards wanted by `day` or earlier, a page of them.
  public func cardsWanted(x : Later, day : Nat, cursor : ?Blob, limit : Nat) : { rows : [(Nat, R.CardOnFile)]; next : ?Blob } {
    switch (RowStore.page<R.CardOnFile>(later(x, CARD_TABLE), R.cardOnFile, "wanted", SR.key2(0, W.DAY, 0, W.ID), SR.key2(day, W.DAY, MAX_ID, W.ID), cursor, limit)) {
      case (#ok p) { { rows = p.rows; next = p.next } }; case (#err _) { { rows = []; next = null } };
    }
  };
  /// The no-show charges the gateway declined from `fromDay` to `toDay`, a bounded number of them.
  public func cardsDeclined(x : Later, fromDay : Nat, toDay : Nat, limit : Nat) : [(Nat, R.CardOnFile)] {
    switch (RowStore.page<R.CardOnFile>(later(x, CARD_TABLE), R.cardOnFile, "declined", SR.key2(fromDay, W.DAY, 0, W.ID), SR.key2(toDay, W.DAY, MAX_ID, W.ID), null, limit)) {
      case (#ok p) p.rows; case (#err _) [];
    }
  };
  /// The tokens the gateway would not delete, a bounded number of them.
  public func cardsForgetFailed(x : Later, limit : Nat) : [(Nat, R.CardOnFile)] {
    switch (RowStore.page<R.CardOnFile>(later(x, CARD_TABLE), R.cardOnFile, "forget_failed", SR.key(0, W.ID), SR.key(MAX_ID, W.ID), null, limit)) {
      case (#ok p) p.rows; case (#err _) [];
    }
  };
  /// The tokens to delete at the gateway, a bounded number of them.
  public func cardsToForget(x : Later, limit : Nat) : [(Nat, R.CardOnFile)] {
    switch (RowStore.page<R.CardOnFile>(later(x, CARD_TABLE), R.cardOnFile, "forget_due", SR.key(0, W.ID), SR.key(MAX_ID, W.ID), null, limit)) {
      case (#ok p) p.rows; case (#err _) [];
    }
  };
  public func outboxRow(x : Later, id : Nat) : ?R.Outbox { RowStore.get<R.Outbox>(later(x, OUTBOX_TABLE), R.outbox, id) };
  public func mailAddress(x : Later, bookingId : Nat) : ?R.MailAddress { RowStore.get<R.MailAddress>(later(x, MAIL_ADDRESS_TABLE), R.mailAddress, bookingId) };
  public func mailSetup(x : Later) : ?R.MailSetup { RowStore.get<R.MailSetup>(later(x, MAIL_SETUP_TABLE), R.mailSetup, MAIL_SETUP_ID) };
  /// The messages due to go by `day`, a page of them in the order they may go.
  public func mailDue(x : Later, day : Nat, cursor : ?Blob, limit : Nat) : { rows : [(Nat, R.Outbox)]; next : ?Blob } {
    switch (RowStore.page<R.Outbox>(later(x, OUTBOX_TABLE), R.outbox, "due", SR.key2(0, W.DAY, 0, W.ID), SR.key2(day, W.DAY, MAX_ID, W.ID), cursor, limit)) {
      case (#ok p) { { rows = p.rows; next = p.next } }; case (#err _) { { rows = []; next = null } };
    }
  };
  /// The rooms open blocks hold on a hotel night: taken out of what that night has free.
  public func blockedOn(x : Later, roomTypeId : Nat, day : Nat) : Nat {
    switch (RowStore.get<R.NightBlock>(later(x, NIGHT_BLOCK_TABLE), R.nightBlock, R.nightId(roomTypeId, day))) { case (?n) n.open; case null 0 }
  };
  /// A night's rooms free to sell: its allotment less what is sold, held, and held by open blocks.
  public func freeOn(x : Later, roomTypeId : Nat, day : Nat, n : R.Night) : Nat {
    let f = R.free(n);
    let b = blockedOn(x, roomTypeId, day);
    if (f > b) f - b else 0
  };
  /// The bookings picked up from a block (its rooming list), in booking order, up to `limit`.
  public func blockBookings(x : Later, blockId : Nat, limit : Nat) : [(Nat, R.BookingBlock)] {
    let lo = SR.key2(blockId, W.ID, 0, W.ID);
    let hi = SR.key2(blockId, W.ID, MAX_ID, W.ID);
    switch (RowStore.page<R.BookingBlock>(later(x, BOOKING_BLOCK_TABLE), R.bookingBlock, "by_block", lo, hi, null, limit)) { case (#ok p) p.rows; case (#err _) [] }
  };
  /// Every booking ever picked up from a block, page by page to the end.
  public func blockBookingsAll(x : Later, blockId : Nat) : [(Nat, R.BookingBlock)] {
    let lo = SR.key2(blockId, W.ID, 0, W.ID);
    let hi = SR.key2(blockId, W.ID, MAX_ID, W.ID);
    let out = List.empty<(Nat, R.BookingBlock)>();
    var cursor : ?Page.Cursor = null;
    label pages loop {
      switch (RowStore.page<R.BookingBlock>(later(x, BOOKING_BLOCK_TABLE), R.bookingBlock, "by_block", lo, hi, cursor, Page.MAX_LIMIT)) {
        case (#err _) break pages;
        case (#ok p) {
          for (r in p.rows.vals()) List.add(out, r);
          switch (p.next) { case null break pages; case (?c) cursor := ?c };
        };
      };
    };
    List.toArray(out)
  };
  /// Every block's share of one hotel night, up to `limit`.
  public func blockNightsOn(x : Later, roomTypeId : Nat, day : Nat, limit : Nat) : [(Nat, R.BlockNight)] {
    let nid = R.nightId(roomTypeId, day);
    let lo = SR.key2(nid, W.NIGHT_ID, 0, W.ID);
    let hi = SR.key2(nid, W.NIGHT_ID, MAX_ID, W.ID);
    switch (RowStore.page<R.BlockNight>(later(x, BLOCK_NIGHT_TABLE), R.blockNight, "by_night", lo, hi, null, limit)) { case (#ok p) p.rows; case (#err _) [] }
  };
  /// The open blocks whose cut-off is on or before `day`, in cut-off order, up to `limit`.
  public func blocksDue(x : Later, day : Nat, limit : Nat) : [(Nat, R.Block)] {
    let lo = SR.key2(0, W.DAY, 0, W.ID);
    let hi = SR.key2(day, W.DAY, MAX_ID, W.ID);
    switch (RowStore.page<R.Block>(later(x, BLOCK_TABLE), R.block, "open_by_cutoff", lo, hi, null, limit)) { case (#ok p) p.rows; case (#err _) [] }
  };
  /// The promotion whose code this is, if any.
  public func promoByCode(x : Later, code : Text) : ?(Nat, R.Promo) {
    let k = R.codeKey(code);
    switch (RowStore.page<R.Promo>(later(x, PROMO_TABLE), R.promo, "by_code", k, k, null, 1)) {
      case (#ok p) { if (p.rows.size() > 0) ?p.rows[0] else null };
      case (#err _) null;
    }
  };
  /// The booking that made a promotion's use of this number, if any.
  public func bookingOfUse(x : Later, promoId : Nat, use : Nat) : ?(Nat, R.RateGrant) {
    let k = R.useKey(promoId, use);
    switch (RowStore.page<R.RateGrant>(later(x, BOOKING_RATE_TABLE), R.bookingRate, "by_use", k, k, null, 1)) {
      case (#ok p) { if (p.rows.size() > 0) ?p.rows[0] else null };
      case (#err _) null;
    }
  };
  /// The company whose code this is, if any.
  public func companyByCode(x : Later, code : Text) : ?(Nat, R.Company) {
    let k = R.codeKey(code);
    switch (RowStore.page<R.Company>(later(x, COMPANY_TABLE), R.company, "by_code", k, k, null, 1)) {
      case (#ok p) { if (p.rows.size() > 0) ?p.rows[0] else null };
      case (#err _) null;
    }
  };
  public func dayFigures(x : Later, day : Nat) : ?R.DayFigures { RowStore.get<R.DayFigures>(later(x, DAY_FIGURES_TABLE), R.dayFigures, day) };
  /// The revenue row of a night, type and plan, with its id, if the audit has written one.
  public func dayRevenueRow(x : Later, day : Nat, roomTypeId : Nat, planId : Nat) : ?(Nat, R.DayRevenue) {
    let k = R.dayRevenueKey(day, roomTypeId, planId);
    switch (RowStore.page<R.DayRevenue>(later(x, DAY_REVENUE_TABLE), R.dayRevenue, "by_key", k, k, null, 1)) {
      case (#ok p) { if (p.rows.size() > 0) ?p.rows[0] else null };
      case (#err _) null;
    }
  };
  /// Every revenue row of one night: at most one per room type and plan.
  public func dayRevenueOf(x : Later, day : Nat) : [(Nat, R.DayRevenue)] {
    let (lo, hi) = SR.prefixRange(day, W.DAY, 2 * W.ID);
    rangeRows<R.DayRevenue>(later(x, DAY_REVENUE_TABLE), R.dayRevenue, "by_key", lo, hi)
  };
  public func taxEta(x : Later, ruleId : Nat) : ?R.TaxEta { RowStore.get<R.TaxEta>(later(x, TAX_ETA_TABLE), R.taxEta, ruleId) };
  public func etaProfile(x : Later) : ?R.EtaProfile { RowStore.get<R.EtaProfile>(later(x, ETA_PROFILE_TABLE), R.etaProfile, ETA_PROFILE_ID) };

  /// The credit notes against an invoice, in number order. An invoice has at most as many as a bill has
  /// lines to take back, each a whole note; the read is a range over the notes' invoice index.
  public func notesOf(x : Later, invoice : Nat) : [(Nat, R.CreditNote)] {
    let (lo, hi) = SR.prefixRange(invoice, W.ID, W.ID);
    rangeRows<R.CreditNote>(later(x, CREDIT_NOTE_TABLE), R.creditNote, "by_invoice", lo, hi)
  };

  /// What credit notes have taken back of a line so far: the sum of the credit lines that name it.
  public func creditedOf(s : Stores, x : Later, source : Nat) : Nat {
    let (lo, hi) = SR.prefixRange(source, W.ID, W.ID);
    var t = 0;
    for ((id, _) in rangeRows<R.CreditLine>(later(x, CREDIT_LINE_TABLE), R.creditLine, "by_source", lo, hi).vals()) {
      switch (folioLine(s, id)) { case (?l) t += l.amount; case null {} };
    };
    t
  };

  public func folioLine(s : Stores, id : Nat) : ?R.FolioLine { RowStore.get<R.FolioLine>(s.folio, R.folioLine, id) };

  /// The window a folio line or a payment is in: its route, or the guest's (0).
  public func lineWindow(x : Later, lineId : Nat) : Nat {
    switch (RowStore.get<R.Route>(later(x, LINE_ROUTE_TABLE), R.lineRoute, lineId)) { case (?r) r.payerId; case null 0 }
  };
  public func paymentWindow(x : Later, paymentId : Nat) : Nat {
    switch (RowStore.get<R.Route>(later(x, PAYMENT_ROUTE_TABLE), R.paymentRoute, paymentId)) { case (?r) r.payerId; case null 0 }
  };

  /// The payers of a booking other than the guest, in the order they were added.
  public func payersOf(x : Later, bookingId : Nat) : [(Nat, R.Payer)] {
    let (lo, hi) = SR.prefixRange(bookingId, W.ID, W.ID);
    rangeRows<R.Payer>(later(x, PAYER_TABLE), R.payer, "by_booking", lo, hi)
  };

  /// The invoice that closed a window, if one did.
  public func invoiceOf(x : Later, bookingId : Nat, payerId : Nat) : ?(Nat, R.Invoice) {
    let k = SR.key2(bookingId, W.ID, payerId, W.ID);
    switch (RowStore.page<R.Invoice>(later(x, INVOICE_TABLE), R.invoice, "by_window", k, k, null, 1)) {
      case (#ok p) { if (p.rows.size() > 0) ?p.rows[0] else null };
      case (#err _) null;
    }
  };

  // ── rooms in service, night by night ────────────────────────────────────────

  /// The first night a room counts among its type's rooms: every night (0) in service, its first night
  /// back when out of order with dates, and none when out of order with no dates (set from the room's
  /// setup), which is out until it is put back. The one definition the folds and the law I1 count by.
  public func countsFrom(r : R.Room, hk : ?R.Housekeeping) : ?Nat {
    switch (r.status) {
      case (#active) ?0;
      case (#outOfOrder) { switch hk { case (?h) { if (h.outUntil > 0) ?h.outUntil else null }; case null null } };
    }
  };

  public func countsOn(r : R.Room, hk : ?R.Housekeeping, d : Nat) : Bool {
    switch (countsFrom(r, hk)) { case (?from) from <= d; case null false }
  };

  /// A type's rooms as a function of the night: those in service now, and the first night back of each
  /// room out of order with dates. Read once, asked for many nights.
  public type InService = { active : Nat; back : [Nat] };

  public func inService(s : Stores, x : Later, rt : Nat) : InService {
    let (lo, hi) = SR.prefixRange(rt, W.ID, W.ID);
    var active = 0;
    let back = List.empty<Nat>();
    for ((id, r) in rangeRows<R.Room>(s.rooms, R.room, "by_type", lo, hi).vals()) {
      // a room in service needs no housekeeping read
      if (r.status == #active) active += 1
      else switch (countsFrom(r, housekeeping(x, id))) { case (?from) List.add(back, from); case null {} };
    };
    { active; back = List.toArray(back) }
  };

  /// How many rooms of the type count on night `d`.
  public func inServiceOn(v : InService, d : Nat) : Nat {
    var n = v.active;
    for (u in v.back.vals()) { if (u <= d) n += 1 };
    n
  };

  /// What one command sees: the stores, the block it will be, the business date and the height.
  public type Ctx = { s : Stores; x : Later; block : Nat; day : Nat; height : Nat };

  public func pow256(n : Nat) : Nat { var r = 1; var i = 0; while (i < n) { r *= 256; i += 1 }; r };
  public let MAX_ID : Nat = 281_474_976_710_655;   // 2^48 − 1

  // ── lookups ─────────────────────────────────────────────────────────────────

  public func property(s : Stores) : ?R.Property { RowStore.get<R.Property>(s.property, R.property, PROPERTY_ID) };
  public func roomType(s : Stores, id : Nat) : ?R.RoomType { RowStore.get<R.RoomType>(s.roomTypes, R.roomType, id) };
  public func room(s : Stores, id : Nat) : ?R.Room { RowStore.get<R.Room>(s.rooms, R.room, id) };
  public func plan(s : Stores, id : Nat) : ?R.RatePlan { RowStore.get<R.RatePlan>(s.plans, R.ratePlan, id) };
  public func hold(s : Stores, id : Nat) : ?R.Hold { RowStore.get<R.Hold>(s.holds, R.hold, id) };
  public func booking(s : Stores, id : Nat) : ?R.Booking { RowStore.get<R.Booking>(s.bookings, R.booking, id) };
  public func payment(s : Stores, id : Nat) : ?R.Payment { RowStore.get<R.Payment>(s.payments, R.payment, id) };
  public func waitEntry(s : Stores, id : Nat) : ?R.WaitEntry { RowStore.get<R.WaitEntry>(s.waitlist, R.waitlist, id) };
  public func proposal(s : Stores, id : Nat) : ?R.Proposal { RowStore.get<R.Proposal>(s.proposals, R.proposal, id) };
  public func night(s : Stores, rt : Nat, day : Nat) : ?R.Night { RowStore.get<R.Night>(s.nights, R.night, R.nightId(rt, day)) };

  /// The nights `from ≤ day < to` of one room type: ONE range read over the primary index. A night
  /// with no row answers `null` (closed). The span is bounded by the caller (at most a stay plus one).
  public func nightsRange(s : Stores, rt : Nat, from : Nat, to : Nat) : [?R.Night] {
    if (to <= from) return [];
    let n : Nat = to - from;
    let found = Map.empty<Nat, R.Night>();
    var cursor : ?Page.Cursor = null;
    label pages loop {
      let p = RowStore.pageById<R.Night>(s.nights, R.night, R.nightId(rt, from), R.nightId(rt, to - 1), cursor, Page.MAX_LIMIT);
      for ((id, row) in p.rows.vals()) Map.add(found, Nat.compare, R.nightDay(id), row);
      switch (p.next) { case null break pages; case (?c) cursor := ?c };
    };
    Array.tabulate<?R.Night>(n, func(i) { Map.get(found, Nat.compare, from + i) })
  };

  /// The active tax rules, in the order they apply: by rank, then by id.
  public func taxes(s : Stores) : [Q.TaxInput] {
    let p = RowStore.pageById<R.TaxRule>(s.taxes, R.taxRule, 1, MAX_TAX_RULES, null, MAX_TAX_RULES);
    let active = List.empty<Q.TaxInput>();
    for ((id, rule) in p.rows.vals()) { if (rule.active) List.add(active, { id; rule }) };
    Array.sort<Q.TaxInput>(List.toArray(active), func(a, b) {
      switch (Nat.compare(a.rule.rank, b.rule.rank)) { case (#equal) Nat.compare(a.id, b.id); case o o }
    })
  };

  /// How many active rooms a type has: a range over the room table's type index.
  public func activeRooms(s : Stores, rt : Nat) : Nat {
    let (lo, hi) = SR.prefixRange(rt, W.ID, W.ID);
    var count = 0;
    var cursor : ?Page.Cursor = null;
    label pages loop {
      switch (RowStore.page<R.Room>(s.rooms, R.room, "by_type", lo, hi, cursor, Page.MAX_LIMIT)) {
        case (#err _) break pages;
        case (#ok p) {
          for ((_, r) in p.rows.vals()) { if (r.status == #active) count += 1 };
          switch (p.next) { case null break pages; case (?c) cursor := ?c };
        };
      };
    };
    count
  };

  public func holdsRole(s : Stores, who : Principal, role : E.Role) : Bool {
    let k = R.subjectRoleKey(who, role);
    switch (RowStore.page<R.Grant>(s.grants, R.grant, "active_by_subject", k, k, null, 1)) {
      case (#ok p) p.rows.size() > 0;
      case (#err _) false;
    }
  };

  public func hasAnyGrant(s : Stores) : Bool { RowStore.size(s.grants) > 0 };

  /// Rows of a secondary-index prefix range, up to `limit`.
  public func prefixRows<Row>(store : RowStore.Store, decl : RowStore.Decl<Row>, index : Text, prefix : Blob, restBytes : Nat, limit : Nat) : [(Nat, Row)] {
    let lo = Blob.fromArray(Array.concat(Blob.toArray(prefix), Array.tabulate<Nat8>(restBytes, func(_) { 0 })));
    let hi = Blob.fromArray(Array.concat(Blob.toArray(prefix), Array.tabulate<Nat8>(restBytes, func(_) { 255 })));
    switch (RowStore.page<Row>(store, decl, index, lo, hi, null, limit)) { case (#ok p) p.rows; case (#err _) [] }
  };

  /// Every row of an index range, walked in pages. The caller bounds the range.
  public func rangeRows<Row>(store : RowStore.Store, decl : RowStore.Decl<Row>, index : Text, lo : Blob, hi : Blob) : [(Nat, Row)] {
    let out = List.empty<(Nat, Row)>();
    var cursor : ?Page.Cursor = null;
    label pages loop {
      switch (RowStore.page<Row>(store, decl, index, lo, hi, cursor, Page.MAX_LIMIT)) {
        case (#err _) break pages;
        case (#ok p) {
          for (x in p.rows.vals()) List.add(out, x);
          switch (p.next) { case null break pages; case (?c) cursor := ?c };
        };
      };
    };
    List.toArray(out)
  };

  public func folioOf(s : Stores, bookingId : Nat) : [(Nat, R.FolioLine)] {
    let (lo, hi) = SR.prefixRange(bookingId, W.ID, W.ID);
    rangeRows<R.FolioLine>(s.folio, R.folioLine, "by_booking", lo, hi)
  };

  public func holdLinesOf(s : Stores, holdId : Nat) : [(Nat, R.FolioLine)] {
    let (lo, hi) = SR.prefixRange(holdId, W.ID, W.ID);
    rangeRows<R.FolioLine>(s.holdLines, R.folioLine, "by_booking", lo, hi)
  };

  public func paymentsOf(s : Stores, bookingId : Nat) : [(Nat, R.Payment)] {
    let (lo, hi) = SR.prefixRange(bookingId, W.ID, W.ID);
    rangeRows<R.Payment>(s.payments, R.payment, "by_booking", lo, hi)
  };

  /// Has this gateway authorisation been recorded already, under any kind?
  public func authUsed(s : Stores, authId : Nat) : Bool {
    let lo = R.authKey(authId, #authorised, 0);
    // every kind, a charge on file's included: an authorisation the gateway gave once is used once
    let hi = R.authKey(authId, #chargedOnFile, MAX_ID);
    switch (RowStore.page<R.Payment>(s.payments, R.payment, "by_auth", lo, hi, null, 1)) {
      case (#ok p) p.rows.size() > 0;
      case (#err _) false;
    }
  };

  // ── the fingerprint ─────────────────────────────────────────────────────────

  func tableInto<Row>(s : Stores, f : Fold.Fingerprint, name : Text, store : RowStore.Store, decl : RowStore.Decl<Row>, hi : Nat, texts : Row -> [TA.Ref]) {
    Fold.section(f, name, func(w) {
      w.nat(RowStore.size(store));
      var cursor : ?Page.Cursor = null;
      label pages loop {
        let p = RowStore.pageById<Row>(store, decl, 0, hi, cursor, Page.MAX_LIMIT);
        for ((id, row) in p.rows.vals()) {
          w.nat(id);
          w.blobRaw(decl.encode(row));
          for (r in texts(row).vals()) w.blob(TA.blobOf(s.arena, r));
        };
        switch (p.next) { case null break pages; case (?c) cursor := ?c };
      };
    });
  };

  /// meta, fifteen tables, evidence and audit: what every state writes.
  public let SECTIONS : Nat = 18;
  /// The later tables, each written once it holds a row: as many as `LATER` declares (the battery holds
  /// the two equal).
  public let LATER_SECTIONS : Nat = 37;

  /// The fingerprint and how many sections it wrote. The count is asserted by the battery against
  /// `SECTIONS`, so a table left out of the walk is a red battery, not a quiet hole in every replay check.
  public func fingerprintCounted(s : Stores, x : Later) : (Fold.Fingerprint, Nat) {
    let f = Fold.newFingerprint();
    var n = 0;
    func section(name : Text, write : C.Writer -> ()) { Fold.section(f, name, write); n += 1 };
    func table<Row>(name : Text, store : RowStore.Store, decl : RowStore.Decl<Row>, hi : Nat, texts : Row -> [TA.Ref]) {
      tableInto<Row>(s, f, name, store, decl, hi, texts); n += 1
    };
    section("meta", func(w) {
      w.nat(s.nextRoomTypeId); w.nat(s.nextRoomId); w.nat(s.nextPlanId); w.nat(s.nextTaxId);
      w.nat(s.nextHoldId); w.nat(s.nextHoldLineId); w.nat(s.nextBookingId); w.nat(s.nextFolioId);
      w.nat(s.nextPaymentId); w.nat(s.nextWaitId); w.nat(s.nextGrantId); w.nat(s.nextProposalId);
      w.nat(s.capturedDone); w.nat(s.refundsCommitted); w.nat(s.paidTotal); w.nat(s.blocksApplied); w.nat(s.closedDays);
      w.nat(s.auditCounts.0); w.nat(s.auditCounts.1); w.nat(s.auditCounts.2); w.nat(s.auditCounts.3);
      w.nat(s.nextIdDocId);
      w.blob(s.guestDataKey);
      w.nat(TA.bytesUsed(s.arena));
    });
    table<R.Property>("property", s.property, R.property, MAX_ID, func(x) { [x.nameEn, x.nameAr, x.checkInText, x.checkOutText] });
    table<R.RoomType>("roomType", s.roomTypes, R.roomType, MAX_ID, func(x) { [x.nameEn, x.nameAr, x.descEn, x.descAr, x.photos] });
    table<R.Room>("room", s.rooms, R.room, MAX_ID, func(_ : R.Room) : [TA.Ref] { [] });
    table<R.RatePlan>("ratePlan", s.plans, R.ratePlan, MAX_ID, func(x) { [x.nameEn, x.nameAr] });
    table<R.TaxRule>("taxRule", s.taxes, R.taxRule, MAX_ID, func(x) { [x.nameEn, x.nameAr] });
    table<R.Night>("night", s.nights, R.night, pow256(R.NIGHT_ID_BYTES) - 1, func(_ : R.Night) : [TA.Ref] { [] });
    table<R.Hold>("hold", s.holds, R.hold, MAX_ID, func(_ : R.Hold) : [TA.Ref] { [] });
    table<R.FolioLine>("holdLine", s.holdLines, R.folioLine, MAX_ID, func(_ : R.FolioLine) : [TA.Ref] { [] });
    table<R.Booking>("booking", s.bookings, R.booking, MAX_ID, func(x) { [x.guestName, x.guestEmail, x.note] });
    table<R.FolioLine>("folioLine", s.folio, R.folioLine, MAX_ID, func(_ : R.FolioLine) : [TA.Ref] { [] });
    table<R.Payment>("payment", s.payments, R.payment, MAX_ID, func(_ : R.Payment) : [TA.Ref] { [] });
    table<R.WaitEntry>("waitlist", s.waitlist, R.waitlist, MAX_ID, func(_ : R.WaitEntry) : [TA.Ref] { [] });
    table<R.Grant>("grant", s.grants, R.grant, MAX_ID, func(_ : R.Grant) : [TA.Ref] { [] });
    table<R.Proposal>("proposal", s.proposals, R.proposal, MAX_ID, func(x : R.Proposal) : [TA.Ref] { [x.act] });
    table<IdDocRow>("idDoc", s.idDocs, ID_DOC_DECL, MAX_ID, func(_ : IdDocRow) : [TA.Ref] { [] });
    section("evidence", func(w) {
      let fig = Evidence.figures(s.evidence);
      w.nat(fig.documents); w.nat(fig.erased); w.nat(fig.bytes); w.nat(s.evidence.dedupEpoch); w.nat(s.evidence.nextDocument);
      for ((id, d) in Map.entries(s.evidence.documents)) {
        w.nat(id); w.text(d.blobId); w.text(d.plainHash); w.nat(d.plainSize); w.nat(d.epoch); w.text(d.scope);
        w.optText(d.fileKey); w.optNat(d.erasedAtDay);
      };
      for ((id, r) in Map.entries(s.keys.rings)) { w.text(id); w.nat(r.epoch) };
    });
    section("audit", func(w) {
      BatchCore.fingerprintInto(w, s.audit);
      w.nat(s.walk.day); w.nat(s.walk.section); w.optBlob(s.walk.cursor); w.nat(s.walk.examined);
      w.texts(s.walk.violations); w.bool(s.walk.done);
    });
    // A later table writes its section once it holds a row: an empty one is the state the contract had
    // before the table existed, and an upgrade that brings the table must reproduce the fingerprint
    // the contract had, byte for byte.
    let clocks = later(x, CLOCK_TABLE);
    if (RowStore.size(clocks) > 0) table<R.HotelClock>(CLOCK_TABLE, clocks, R.hotelClock, MAX_ID, func(c : R.HotelClock) : [TA.Ref] { [c.zoneName, c.zoneRule] });
    let hk = later(x, HK_TABLE);
    if (RowStore.size(hk) > 0) table<R.Housekeeping>(HK_TABLE, hk, R.housekeeping, MAX_ID, func(h : R.Housekeeping) : [TA.Ref] { [h.outReason] });
    let extras = later(x, EXTRA_TABLE);
    if (RowStore.size(extras) > 0) table<R.Extra>(EXTRA_TABLE, extras, R.extra, MAX_ID, func(e : R.Extra) : [TA.Ref] { [e.nameEn, e.nameAr] });
    let charges = later(x, CHARGE_TABLE);
    if (RowStore.size(charges) > 0) table<R.Charge>(CHARGE_TABLE, charges, R.charge, MAX_ID, func(_ : R.Charge) : [TA.Ref] { [] });
    let payers = later(x, PAYER_TABLE);
    if (RowStore.size(payers) > 0) table<R.Payer>(PAYER_TABLE, payers, R.payer, MAX_ID, func(p : R.Payer) : [TA.Ref] { [p.name] });
    let lineRoutes = later(x, LINE_ROUTE_TABLE);
    if (RowStore.size(lineRoutes) > 0) table<R.Route>(LINE_ROUTE_TABLE, lineRoutes, R.lineRoute, MAX_ID, func(_ : R.Route) : [TA.Ref] { [] });
    let paymentRoutes = later(x, PAYMENT_ROUTE_TABLE);
    if (RowStore.size(paymentRoutes) > 0) table<R.Route>(PAYMENT_ROUTE_TABLE, paymentRoutes, R.paymentRoute, MAX_ID, func(_ : R.Route) : [TA.Ref] { [] });
    let invoices = later(x, INVOICE_TABLE);
    if (RowStore.size(invoices) > 0) table<R.Invoice>(INVOICE_TABLE, invoices, R.invoice, MAX_ID, func(_ : R.Invoice) : [TA.Ref] { [] });
    let notes = later(x, CREDIT_NOTE_TABLE);
    if (RowStore.size(notes) > 0) table<R.CreditNote>(CREDIT_NOTE_TABLE, notes, R.creditNote, MAX_ID, func(_ : R.CreditNote) : [TA.Ref] { [] });
    let creditLines = later(x, CREDIT_LINE_TABLE);
    if (RowStore.size(creditLines) > 0) table<R.CreditLine>(CREDIT_LINE_TABLE, creditLines, R.creditLine, MAX_ID, func(_ : R.CreditLine) : [TA.Ref] { [] });
    let deskRefunds = later(x, DESK_REFUND_TABLE);
    if (RowStore.size(deskRefunds) > 0) table<R.DeskRefund>(DESK_REFUND_TABLE, deskRefunds, R.deskRefund, MAX_ID, func(d : R.DeskRefund) : [TA.Ref] { [d.reference] });
    let taxEtas = later(x, TAX_ETA_TABLE);
    if (RowStore.size(taxEtas) > 0) table<R.TaxEta>(TAX_ETA_TABLE, taxEtas, R.taxEta, MAX_ID, func(_ : R.TaxEta) : [TA.Ref] { [] });
    let profiles = later(x, ETA_PROFILE_TABLE);
    if (RowStore.size(profiles) > 0) table<R.EtaProfile>(ETA_PROFILE_TABLE, profiles, R.etaProfile, MAX_ID,
      func(p : R.EtaProfile) : [TA.Ref] { [p.issuerId, p.branchId, p.governate, p.regionCity, p.street, p.buildingNumber] });
    let staffBookings = later(x, STAFF_BOOKING_TABLE);
    if (RowStore.size(staffBookings) > 0) table<R.StaffBooking>(STAFF_BOOKING_TABLE, staffBookings, R.staffBooking, MAX_ID, func(_ : R.StaffBooking) : [TA.Ref] { [] });
    let dayFiguresT = later(x, DAY_FIGURES_TABLE);
    if (RowStore.size(dayFiguresT) > 0) table<R.DayFigures>(DAY_FIGURES_TABLE, dayFiguresT, R.dayFigures, MAX_ID, func(_ : R.DayFigures) : [TA.Ref] { [] });
    let dayRevenueT = later(x, DAY_REVENUE_TABLE);
    if (RowStore.size(dayRevenueT) > 0) table<R.DayRevenue>(DAY_REVENUE_TABLE, dayRevenueT, R.dayRevenue, MAX_ID, func(_ : R.DayRevenue) : [TA.Ref] { [] });
    let refundSlices = later(x, REFUND_SLICE_TABLE);
    if (RowStore.size(refundSlices) > 0) table<R.RefundSlice>(REFUND_SLICE_TABLE, refundSlices, R.refundSlice, MAX_ID, func(_ : R.RefundSlice) : [TA.Ref] { [] });
    let companies = later(x, COMPANY_TABLE);
    if (RowStore.size(companies) > 0) table<R.Company>(COMPANY_TABLE, companies, R.company, MAX_ID, func(r : R.Company) : [TA.Ref] { [r.name] });
    let access = later(x, PLAN_ACCESS_TABLE);
    if (RowStore.size(access) > 0) table<R.PlanAccess>(PLAN_ACCESS_TABLE, access, R.planAccess, MAX_ID, func(_ : R.PlanAccess) : [TA.Ref] { [] });
    let holdRates = later(x, HOLD_RATE_TABLE);
    if (RowStore.size(holdRates) > 0) table<R.RateGrant>(HOLD_RATE_TABLE, holdRates, R.holdRate, MAX_ID, func(_ : R.RateGrant) : [TA.Ref] { [] });
    let bookingRates = later(x, BOOKING_RATE_TABLE);
    if (RowStore.size(bookingRates) > 0) table<R.RateGrant>(BOOKING_RATE_TABLE, bookingRates, R.bookingRate, MAX_ID, func(_ : R.RateGrant) : [TA.Ref] { [] });
    let promos = later(x, PROMO_TABLE);
    if (RowStore.size(promos) > 0) table<R.Promo>(PROMO_TABLE, promos, R.promo, MAX_ID, func(r : R.Promo) : [TA.Ref] { [r.name] });
    let blocks = later(x, BLOCK_TABLE);
    if (RowStore.size(blocks) > 0) table<R.Block>(BLOCK_TABLE, blocks, R.block, MAX_ID, func(r : R.Block) : [TA.Ref] { [r.name] });
    let blockNights = later(x, BLOCK_NIGHT_TABLE);
    if (RowStore.size(blockNights) > 0) table<R.BlockNight>(BLOCK_NIGHT_TABLE, blockNights, R.blockNight, MAX_ID, func(_ : R.BlockNight) : [TA.Ref] { [] });
    let nightBlocks = later(x, NIGHT_BLOCK_TABLE);
    if (RowStore.size(nightBlocks) > 0) table<R.NightBlock>(NIGHT_BLOCK_TABLE, nightBlocks, R.nightBlock, pow256(R.NIGHT_ID_BYTES) - 1, func(_ : R.NightBlock) : [TA.Ref] { [] });
    let bookingBlocks = later(x, BOOKING_BLOCK_TABLE);
    if (RowStore.size(bookingBlocks) > 0) table<R.BookingBlock>(BOOKING_BLOCK_TABLE, bookingBlocks, R.bookingBlock, MAX_ID, func(_ : R.BookingBlock) : [TA.Ref] { [] });
    let auditBlocksT = later(x, AUDIT_BLOCKS_TABLE);
    if (RowStore.size(auditBlocksT) > 0) table<R.AuditBlocks>(AUDIT_BLOCKS_TABLE, auditBlocksT, R.auditBlocks, MAX_ID, func(_ : R.AuditBlocks) : [TA.Ref] { [] });
    let inclusions = later(x, PLAN_INCLUSION_TABLE);
    if (RowStore.size(inclusions) > 0) table<R.PlanInclusion>(PLAN_INCLUSION_TABLE, inclusions, R.planInclusion, MAX_ID, func(_ : R.PlanInclusion) : [TA.Ref] { [] });
    let packageLines = later(x, PACKAGE_LINE_TABLE);
    if (RowStore.size(packageLines) > 0) table<R.PackageLine>(PACKAGE_LINE_TABLE, packageLines, R.packageLine, MAX_ID, func(_ : R.PackageLine) : [TA.Ref] { [] });
    let holdPackages = later(x, HOLD_PACKAGE_TABLE);
    if (RowStore.size(holdPackages) > 0) table<R.PackageLine>(HOLD_PACKAGE_TABLE, holdPackages, R.holdPackage, MAX_ID, func(_ : R.PackageLine) : [TA.Ref] { [] });
    let deposits = later(x, PLAN_DEPOSIT_TABLE);
    if (RowStore.size(deposits) > 0) table<R.PlanDeposit>(PLAN_DEPOSIT_TABLE, deposits, R.planDeposit, MAX_ID, func(_ : R.PlanDeposit) : [TA.Ref] { [] });
    let cards = later(x, CARD_TABLE);
    if (RowStore.size(cards) > 0) table<R.CardOnFile>(CARD_TABLE, cards, R.cardOnFile, MAX_ID, func(_ : R.CardOnFile) : [TA.Ref] { [] });
    let policy = later(x, CARD_POLICY_TABLE);
    if (RowStore.size(policy) > 0) table<R.CardPolicy>(CARD_POLICY_TABLE, policy, R.cardPolicy, MAX_ID, func(_ : R.CardPolicy) : [TA.Ref] { [] });
    let outbox = later(x, OUTBOX_TABLE);
    if (RowStore.size(outbox) > 0) table<R.Outbox>(OUTBOX_TABLE, outbox, R.outbox, MAX_ID, func(_ : R.Outbox) : [TA.Ref] { [] });
    let addresses = later(x, MAIL_ADDRESS_TABLE);
    if (RowStore.size(addresses) > 0) table<R.MailAddress>(MAIL_ADDRESS_TABLE, addresses, R.mailAddress, MAX_ID, func(m : R.MailAddress) : [TA.Ref] { [m.sealed] });
    let mail = later(x, MAIL_SETUP_TABLE);
    if (RowStore.size(mail) > 0) table<R.MailSetup>(MAIL_SETUP_TABLE, mail, R.mailSetup, MAX_ID, func(_ : R.MailSetup) : [TA.Ref] { [] });
    // no row before the first adoption: a log written before the rules were numbered folds to the
    // fingerprint it always had
    let rules = later(x, RULES_TABLE);
    if (RowStore.size(rules) > 0) table<R.Rules>(RULES_TABLE, rules, R.rules, MAX_ID, func(_ : R.Rules) : [TA.Ref] { [] });
    (f, n)
  };

  public func fingerprint(s : Stores, x : Later) : Fold.Fingerprint { fingerprintCounted(s, x).0 };

  public func fingerprintHash(s : Stores, x : Later) : Blob { Fold.fingerprintHash(fingerprint(s, x)) };

  public func principalHex(p : Principal) : Text { C.hex(Principal.toBlob(p)) };
}
