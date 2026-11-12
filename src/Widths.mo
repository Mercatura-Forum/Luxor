/// Widths.mo - every fixed width in this product, declared once, with the arithmetic that checks it.
///
/// The primitive widths are the estate's (Mentat's `Widths`): an id is six bytes here and there, a
/// day three, a principal thirty, so a row one system writes means the same thing to the other when
/// the enterprise dependency arrives. What is Luxor's own is the rows, and each row's width is
/// written as the sum of its fields so `checkSums` catches a field added without widening the row.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import List "mo:core/List";
import Nat "mo:core/Nat";

module {

  public let ID : Nat = 6;
  /// A room type inside a composite key. A property declares at most `MAX_ROOM_TYPES`.
  public let RT : Nat = 2;
  public let DAY : Nat = 3;
  public let HEIGHT : Nat = 6;
  public let BLOCK : Nat = 6;
  public let PRINCIPAL : Nat = 30;
  public let MONEY : Nat = 8;
  public let COUNT : Nat = 2;
  public let BPS : Nat = 2;
  public let ARENA_OFFSET : Nat = 6;
  public let ARENA_LEN : Nat = 2;
  public let ARENA_REF : Nat = 8;
  public let ENUM : Nat = 1;
  public let FLAG : Nat = 1;
  public let SMALL : Nat = 1;
  public let HASH : Nat = 32;
  /// A compressed P-256 point: the booking's manage key.
  public let PUBKEY : Nat = 33;
  public let NONCE : Nat = 4;
  public let CODE : Nat = 16;
  public let ROOM_NUMBER : Nat = 8;
  public let CURRENCY : Nat = 3;
  public let AMENITIES : Nat = 4;
  public let RATIO : Nat = 4;
  /// A local time of day in seconds after midnight, below 86,400.
  public let SECOND_OF_DAY : Nat = 3;
  /// A code of the tax authority's tables (a tax type such as T1, a sub-type such as V009, an activity
  /// code such as 5510): short ASCII, padded.
  public let ETA_CODE : Nat = 8;
  /// An ISO 3166 alpha-2 country code.
  public let COUNTRY : Nat = 2;

  public let MAX_ROOM_TYPES : Nat = 64;

  /// `property`: currency minorUnits name_en name_ar checkInText checkOutText holdTtlHeights
  ///   heightsPerRealMinute maxStayNights horizonDays maxRoomsPerBooking idRetentionDays lastBlock
  ///   = 3+1+8+8+8+8+6+4+1+2+1+2+6 = 58
  public let PROPERTY_ROW : Nat = 58;

  /// `roomType`: code name_en name_ar desc_en desc_ar sizeSqm maxAdults maxChildren maxOccupancy
  ///   bedKind bedCount amenities photos rank active lastBlock
  ///   = 16+8+8+8+8+2+1+1+1+1+1+4+8+1+1+6 = 75
  public let ROOM_TYPE_ROW : Nat = 75;

  /// `room`: roomTypeId number status occupiedBy lastBlock = 6+8+1+6+6 = 27
  public let ROOM_ROW : Nat = 27;

  /// `ratePlan`: code name_en name_ar kind discountBps refundable freeCancelDaysBefore penaltyNights
  ///   guarantee modifiable active lastBlock = 16+8+8+1+2+1+1+1+1+1+1+6 = 47
  public let RATE_PLAN_ROW : Nat = 47;

  /// `taxRule`: code name_en name_ar kind bps amount base rank active lastBlock
  ///   = 16+8+8+1+2+8+1+1+1+6 = 52
  public let TAX_RULE_ROW : Nat = 52;

  /// `night`: allotment sold held bar minStay maxStay closedToArrival closedToDeparture stopSell
  ///   lastBlock = 2+2+2+8+1+1+1+1+1+6 = 25
  public let NIGHT_ROW : Nat = 25;

  /// `hold`: roomTypeId planId arrival nights rooms adults children owner expiresAt state
  ///   quotedTotal quoteHash fromWaitlist key lastBlock = 6+6+3+1+1+1+1+30+6+1+8+32+6+33+6 = 141
  public let HOLD_ROW : Nat = 141;

  /// `booking`: roomTypeId planId arrival departure rooms adults children status account manageKey
  ///   manageNonce guestName guestEmail note charged credited paid outstanding cancelDeadline penalty
  ///   checkedMinStay checkedMaxStay holdId assignedRoom createdBlock lastBlock
  ///   = 6+6+3+3+1+1+1+1+30+33+4+8+8+8+8+8+8+8+3+8+1+1+6+6+6+6 = 182
  public let BOOKING_ROW : Nat = 182;

  /// `folioLine`: bookingId kind code night amount block = 6+1+1+3+8+6 = 25
  public let FOLIO_ROW : Nat = 25;

  /// `payment`: bookingId gatewayAuth kind amount state attempts block = 6+6+1+8+1+1+6 = 29
  public let PAYMENT_ROW : Nat = 29;

  /// `waitlist`: account roomTypeId arrival nights rooms adults children state offeredHold lastBlock
  ///   = 30+6+3+1+1+1+1+1+6+6 = 56
  public let WAITLIST_ROW : Nat = 56;

  /// `grant`: subject role active lastBlock = 30+1+1+6 = 38
  public let GRANT_ROW : Nat = 38;

  /// `proposal`: maker permission proposedBlock expiresAt status checker resolvedBlock commandHash act
  ///   = 30+1+6+6+1+30+6+32+8 = 120
  public let PROPOSAL_ROW : Nat = 120;

  /// `idDoc`: bookingId documentId eraseDay erased lastBlock = 6+6+3+1+6 = 22
  public let ID_DOC_ROW : Nat = 22;

  /// `hotelClock`: zoneName zoneRule auditAt auto actor lastBlock = 8+8+3+1+30+6 = 56
  public let HOTEL_CLOCK_ROW : Nat = 56;

  /// `housekeeping`: cleaning cleanedBy inspectedBy outReason outFrom outUntil changedDay lastBlock
  ///   = 1+30+30+8+3+3+3+6 = 84
  public let HOUSEKEEPING_ROW : Nat = 84;

  /// `extra` (the catalogue): code name_en name_ar category price taxed active lastBlock = 16+8+8+1+8+1+1+6 = 49
  public let EXTRA_ROW : Nat = 49;

  /// `charge` (an extra posted, under its folio line's id): bookingId extraId quantity unitAmount taxLines
  ///   postedBy voidLine lastBlock = 6+6+2+8+1+30+6+6 = 65
  public let CHARGE_ROW : Nat = 65;

  /// `payer` (a window of a booking's bill other than the guest's): bookingId name lastBlock = 6+8+6 = 20
  public let PAYER_ROW : Nat = 20;

  /// `lineRoute` / `paymentRoute` (the window a folio line or a payment belongs to): payerId lastBlock = 6+6 = 12
  public let ROUTE_ROW : Nat = 12;

  /// `invoice` (under its number): bookingId payerId issuedDay charges credits taxes paid issuedBy lastBlock
  ///   = 6+6+3+8+8+8+8+30+6 = 83
  public let INVOICE_ROW : Nat = 83;

  /// `creditNote` (under its number, a run of its own): invoice bookingId payerId issuedDay net taxes total
  ///   firstLine lines proposal lastBlock = 6+6+6+3+8+8+8+6+1+6+6 = 64
  public let CREDIT_NOTE_ROW : Nat = 64;

  /// `creditLine` (under the credit's folio line id): note source lastBlock = 6+6+6 = 18
  public let CREDIT_LINE_ROW : Nat = 18;

  /// `deskRefund` (under the failed refund's payment id): bookingId method reference day proposal lastBlock
  ///   = 6+1+8+3+6+6 = 30
  public let DESK_REFUND_ROW : Nat = 30;

  /// `taxEta` (under the tax rule's id): taxType subType lastBlock = 8+8+6 = 22
  public let TAX_ETA_ROW : Nat = 22;

  /// `etaProfile` (one row): issuerId activityCode branchId country governate regionCity street
  ///   buildingNumber lastBlock = 8+8+8+2+8+8+8+8+6 = 64
  public let ETA_PROFILE_ROW : Nat = 64;

  /// `staffBooking` (under the booking's id): channel madeBy day lastBlock = 1+30+3+6 = 40
  public let STAFF_BOOKING_ROW : Nat = 40;

  /// A count the night audit keeps: rooms, bookings, room nights. Four bytes (4,294,967,295), so a
  /// day's pickup in room nights cannot wrap where two bytes (`COUNT`) would at 65,535.
  public let TALLY : Nat = 4;

  /// `dayFigures` (under the business day): roomsTotal roomsSeen roomsOut roomsSold roomRevenue
  ///   inHouse houseSeen arrivals noShows pickupFrom pickupCount pickupBookings pickupNights
  ///   pickupRevenue cursorDay cursorId lastBlock = 4+4+4+4+8+4+4+4+4+6+4+4+4+8+3+6+6 = 81
  public let DAY_FIGURES_ROW : Nat = 81;

  /// `dayRevenue` (a run of its own, keyed by day, room type and plan): day roomTypeId planId
  ///   roomNights revenue lastBlock = 3+6+6+4+8+6 = 33
  public let DAY_REVENUE_ROW : Nat = 33;

  /// `refundSlice` (under the refund's payment id): firstSlice excess written = 6+8+6 = 20
  public let REFUND_SLICE_ROW : Nat = 20;

  /// `company` (a corporate account with negotiated rates): code name active lastBlock = 16+8+1+6 = 31
  public let COMPANY_ROW : Nat = 31;

  /// `planAccess` (under the plan's id; no row: on public sale): companyId closed lastBlock = 6+1+6 = 13
  public let PLAN_ACCESS_ROW : Nat = 13;

  /// A count of uses: 4 bytes, so a promotion's uses fit any hotel's year many times over.
  public let USES : Nat = 4;
  /// The key of a promotion's use: the promotion's id, then the use's number = 6+4.
  public let USE_KEY : Nat = 10;

  /// `holdRate` and `bookingRate` (under the hold's or booking's id): the access a closed rate was sold
  /// under, and for a booking under a promotion the number of its use: companyId promoId use lastBlock
  /// = 6+6+4+6 = 22
  public let RATE_GRANT_ROW : Nat = 22;

  /// `promo` (a promotion's code opening a plan closed to everyone else): code name planId bookFrom
  /// bookUntil stayFrom stayUntil maxUses used active lastBlock = 16+8+6+3+3+3+3+4+4+1+6 = 57
  public let PROMO_ROW : Nat = 57;

  /// A night's id: the room type, then the day = 2+3 (`R.NIGHT_ID_BYTES`).
  public let NIGHT_ID : Nat = 5;

  /// `block` (a group's rooms of one type taken out of sale, picked up from its rooming list until the
  /// cut-off): name companyId roomTypeId planId arrival departure rooms cutoff open lastBlock
  /// = 8+6+6+6+3+3+2+3+1+6 = 44
  public let BLOCK_ROW : Nat = 44;
  /// The key of an open block in cut-off order: the cut-off day, then the block = 3+6.
  public let CUTOFF_KEY : Nat = 9;

  /// `blockNight` (under the block and the day): night picked open lastBlock = 5+2+2+6 = 15
  public let BLOCK_NIGHT_ROW : Nat = 15;
  /// The key of a block's night under the hotel's night: the night's id, then the block = 5+6.
  public let NIGHT_BLOCK_KEY : Nat = 11;

  /// `nightBlock` (under the night's id): the rooms every open block still holds that night, lastBlock
  /// = 2+6 = 8
  public let NIGHT_BLOCK_ROW : Nat = 8;

  /// `bookingBlock` (under the booking's id): the block it was picked up from, lastBlock = 6+6 = 12
  public let BOOKING_BLOCK_ROW : Nat = 12;
  /// The key of a booking in its block's rooming list: the block, then the booking = 6+6.
  public let BLOCK_BOOKING_KEY : Nat = 12;

  /// `auditBlocks` (under the business day): the blocks at their cut-off when the day's audit opened,
  /// lastBlock = 4+6 = 10
  public let AUDIT_BLOCKS_ROW : Nat = 10;

  /// `planInclusion` (a package's inclusion, under `planId × 16 + slot`): planId extraId quantity rhythm
  /// per on lastBlock = 6+6+2+1+1+1+6 = 23
  public let PLAN_INCLUSION_ROW : Nat = 23;

  /// `packageLine` and `holdPackage` (an inclusion's line, under the folio line's or the hold line's id):
  /// slot extraId quantity unitAmount rhythm taxed taxLines lastBlock = 1+6+2+8+1+1+1+6 = 26
  public let PACKAGE_LINE_ROW : Nat = 26;

  /// `planDeposit` (a deposit plan's share of the room's stay, under the plan's id): depositBps lastBlock
  /// = 2+6 = 8
  public let PLAN_DEPOSIT_ROW : Nat = 8;

  /// `cardOnFile` (a booking's card, under the booking's id): token firstAuth agreedBlock deadline state
  /// chargeId attempts declinedDay lastBlock = 6+6+6+3+1+6+1+3+6 = 38. The token is the gateway's handle
  /// for the card, bound to this merchant; never a card number.
  public let CARD_ROW : Nat = 38;
  /// A wanted card's key: the day its guarantee is due ‖ the booking = 3+6 = 9.
  public let CARD_WANTED_KEY : Nat = 9;

  /// `cardPolicy` (row 1): the block from which every plan guaranteed by the first night or a deposit
  /// keeps a card on file, and the block that wrote it = 6+6 = 12.
  public let CARD_POLICY_ROW : Nat = 12;

  /// `outbox` (a message the hotel owes a guest, under its own id): bookingId kind notBefore state attempts
  /// failure queuedBlock lastBlock = 6+1+3+1+1+1+6+6 = 25. No field can hold an address, a name or a key:
  /// the row says which message, for which booking, and what became of it (tools/outcall_and_secrets.sh holds
  /// its fields to that list).
  public let OUTBOX_ROW : Nat = 25;
  /// A due message's key: the first business day it may go ‖ its id = 3+6 = 9.
  public let OUTBOX_DUE_KEY : Nat = 9;

  /// `mailAddress` (a booking's address for its messages, under the booking's id): the address sealed to
  /// the relay's mail key, in the arena; the guest's language; the block it was given in; the outbox ids of
  /// its four messages (0: not queued); lastBlock = 8+1+6+6+6+6+6+6 = 45.
  public let MAIL_ADDRESS_ROW : Nat = 45;

  /// The relay's mail key: a raw uncompressed P-256 point.
  public let MAIL_KEY : Nat = 65;
  /// `mailSetup` (row 1): the relay's mail key, the mailer grant, the digest of the credential the owner
  /// authorised, the digest the relay tested, on, lastBlock = 65+6+32+32+1+6 = 142.
  public let MAIL_SETUP_ROW : Nat = 142;

  /// `rules` (row 1): the rules epoch the log has adopted, the span of the audit walk as it opened (its
  /// sections), lastBlock = 1+1+6 = 8. An epoch and a span each fit a byte: the epochs are counted from 0
  /// and the oracle's sections are fewer than 256 (the battery holds `SECTIONS_AT` below both).
  public let RULES_ROW : Nat = 8;

  /// Every row's declared width against the sum of its fields. A disagreement is named.
  public func checkSums() : [Text] {
    let out = List.empty<Text>();
    func agree(name : Text, declared : Nat, parts : [Nat]) {
      var s = 0;
      for (p in parts.vals()) s += p;
      if (s != declared) List.add(out, name # " declares " # Nat.toText(declared) # " bytes and its fields sum to " # Nat.toText(s));
    };
    let R = ARENA_REF;
    agree("property", PROPERTY_ROW, [CURRENCY, SMALL, R, R, R, R, HEIGHT, RATIO, SMALL, COUNT, SMALL, COUNT, BLOCK]);
    agree("roomType", ROOM_TYPE_ROW, [CODE, R, R, R, R, COUNT, SMALL, SMALL, SMALL, ENUM, SMALL, AMENITIES, R, SMALL, FLAG, BLOCK]);
    agree("room", ROOM_ROW, [ID, ROOM_NUMBER, ENUM, ID, BLOCK]);
    agree("ratePlan", RATE_PLAN_ROW, [CODE, R, R, ENUM, BPS, FLAG, SMALL, SMALL, ENUM, FLAG, FLAG, BLOCK]);
    agree("taxRule", TAX_RULE_ROW, [CODE, R, R, ENUM, BPS, MONEY, ENUM, SMALL, FLAG, BLOCK]);
    agree("night", NIGHT_ROW, [COUNT, COUNT, COUNT, MONEY, SMALL, SMALL, FLAG, FLAG, FLAG, BLOCK]);
    agree("hold", HOLD_ROW, [ID, ID, DAY, SMALL, SMALL, SMALL, SMALL, PRINCIPAL, HEIGHT, ENUM, MONEY, HASH, ID, PUBKEY, BLOCK]);
    agree("booking", BOOKING_ROW, [ID, ID, DAY, DAY, SMALL, SMALL, SMALL, ENUM, PRINCIPAL, PUBKEY, NONCE, R, R, R,
      MONEY, MONEY, MONEY, MONEY, DAY, MONEY, SMALL, SMALL, ID, ID, BLOCK, BLOCK]);
    agree("folioLine", FOLIO_ROW, [ID, ENUM, SMALL, DAY, MONEY, BLOCK]);
    agree("payment", PAYMENT_ROW, [ID, ID, ENUM, MONEY, ENUM, SMALL, BLOCK]);
    agree("waitlist", WAITLIST_ROW, [PRINCIPAL, ID, DAY, SMALL, SMALL, SMALL, SMALL, ENUM, ID, BLOCK]);
    agree("grant", GRANT_ROW, [PRINCIPAL, ENUM, FLAG, BLOCK]);
    agree("proposal", PROPOSAL_ROW, [PRINCIPAL, ENUM, BLOCK, HEIGHT, ENUM, PRINCIPAL, BLOCK, HASH, R]);
    agree("idDoc", ID_DOC_ROW, [ID, ID, DAY, FLAG, BLOCK]);
    agree("hotelClock", HOTEL_CLOCK_ROW, [R, R, SECOND_OF_DAY, FLAG, PRINCIPAL, BLOCK]);
    agree("housekeeping", HOUSEKEEPING_ROW, [ENUM, PRINCIPAL, PRINCIPAL, R, DAY, DAY, DAY, BLOCK]);
    agree("extra", EXTRA_ROW, [CODE, R, R, ENUM, MONEY, FLAG, FLAG, BLOCK]);
    agree("charge", CHARGE_ROW, [ID, ID, COUNT, MONEY, SMALL, PRINCIPAL, ID, BLOCK]);
    agree("payer", PAYER_ROW, [ID, R, BLOCK]);
    agree("route", ROUTE_ROW, [ID, BLOCK]);
    agree("invoice", INVOICE_ROW, [ID, ID, DAY, MONEY, MONEY, MONEY, MONEY, PRINCIPAL, BLOCK]);
    agree("creditNote", CREDIT_NOTE_ROW, [ID, ID, ID, DAY, MONEY, MONEY, MONEY, ID, SMALL, ID, BLOCK]);
    agree("creditLine", CREDIT_LINE_ROW, [ID, ID, BLOCK]);
    agree("deskRefund", DESK_REFUND_ROW, [ID, ENUM, R, DAY, ID, BLOCK]);
    agree("taxEta", TAX_ETA_ROW, [ETA_CODE, ETA_CODE, BLOCK]);
    agree("etaProfile", ETA_PROFILE_ROW, [R, ETA_CODE, R, COUNTRY, R, R, R, R, BLOCK]);
    agree("staffBooking", STAFF_BOOKING_ROW, [ENUM, PRINCIPAL, DAY, BLOCK]);
    agree("dayFigures", DAY_FIGURES_ROW, [TALLY, TALLY, TALLY, TALLY, MONEY, TALLY, TALLY, TALLY, TALLY, ID, TALLY, TALLY, TALLY, MONEY, DAY, ID, BLOCK]);
    agree("dayRevenue", DAY_REVENUE_ROW, [DAY, ID, ID, TALLY, MONEY, BLOCK]);
    agree("refundSlice", REFUND_SLICE_ROW, [ID, MONEY, BLOCK]);
    agree("company", COMPANY_ROW, [CODE, ARENA_REF, FLAG, BLOCK]);
    agree("planAccess", PLAN_ACCESS_ROW, [ID, FLAG, BLOCK]);
    agree("rateGrant", RATE_GRANT_ROW, [ID, ID, USES, BLOCK]);
    agree("useKey", USE_KEY, [ID, USES]);
    agree("promo", PROMO_ROW, [CODE, ARENA_REF, ID, DAY, DAY, DAY, DAY, USES, USES, FLAG, BLOCK]);
    agree("arenaRef", ARENA_REF, [ARENA_OFFSET, ARENA_LEN]);
    agree("nightId", NIGHT_ID, [RT, DAY]);
    agree("block", BLOCK_ROW, [ARENA_REF, ID, ID, ID, DAY, DAY, COUNT, DAY, FLAG, BLOCK]);
    agree("cutoffKey", CUTOFF_KEY, [DAY, ID]);
    agree("blockNight", BLOCK_NIGHT_ROW, [NIGHT_ID, COUNT, COUNT, BLOCK]);
    agree("nightBlockKey", NIGHT_BLOCK_KEY, [NIGHT_ID, ID]);
    agree("nightBlock", NIGHT_BLOCK_ROW, [COUNT, BLOCK]);
    agree("bookingBlock", BOOKING_BLOCK_ROW, [ID, BLOCK]);
    agree("blockBookingKey", BLOCK_BOOKING_KEY, [ID, ID]);
    agree("auditBlocks", AUDIT_BLOCKS_ROW, [TALLY, BLOCK]);
    agree("planInclusion", PLAN_INCLUSION_ROW, [ID, ID, COUNT, ENUM, ENUM, FLAG, BLOCK]);
    agree("packageLine", PACKAGE_LINE_ROW, [SMALL, ID, COUNT, MONEY, ENUM, FLAG, SMALL, BLOCK]);
    agree("planDeposit", PLAN_DEPOSIT_ROW, [BPS, BLOCK]);
    agree("cardOnFile", CARD_ROW, [ID, ID, BLOCK, DAY, ENUM, ID, SMALL, DAY, BLOCK]);
    agree("cardWantedKey", CARD_WANTED_KEY, [DAY, ID]);
    agree("cardPolicy", CARD_POLICY_ROW, [BLOCK, BLOCK]);
    agree("outbox", OUTBOX_ROW, [ID, ENUM, DAY, ENUM, SMALL, ENUM, BLOCK, BLOCK]);
    agree("outboxDueKey", OUTBOX_DUE_KEY, [DAY, ID]);
    agree("mailAddress", MAIL_ADDRESS_ROW, [R, ENUM, BLOCK, ID, ID, ID, ID, BLOCK]);
    agree("mailSetup", MAIL_SETUP_ROW, [MAIL_KEY, ID, HASH, HASH, FLAG, BLOCK]);
    agree("rules", RULES_ROW, [SMALL, SMALL, BLOCK]);
    List.toArray(out)
  };

  /// How many row widths `checkSums` examined. A check that examined nothing proves nothing.
  public let ROWS_CHECKED : Nat = 56;
}
