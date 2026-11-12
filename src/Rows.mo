/// Rows.mo - every table in this product, as fixed-width rows in stable memory with declared indexes.
///
/// THE NIGHT GRID IS KEYED SO A STAY IS ONE READ. A night's primary id is `roomType(2) ‖ day(3)`, so
/// the nights of a stay for a room type are one contiguous range of the primary index, read with one
/// `RowStore.pageById`: one descent and then sibling leaves, with no slot scanned to answer an
/// overlap question.
///
/// A PARTIAL INDEX IS HOW WORK IS FOUND. The live holds by expiry, the arrivals still confirmed, the
/// guests in house, the payments due at the gateway, the vacant rooms of a type, the waitlist still
/// waiting: each is an index whose key function answers `null` once the row is done, so a sweep reads
/// the index and a row leaves it by being acted on (kernel DISCIPLINE §7).
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import Array "mo:core/Array";

import RowStore "mo:kernel/rows/RowStore";
import SR "mo:kernel/rows/StableRows";

import E "Enums";
import TA "TextArena";
import W "Widths";

module {

  // ── shared field helpers ────────────────────────────────────────────────────

  /// A principal as length(1) ‖ bytes padded to 29. The empty principal field (length 0) is "none".
  public func putPrincipal(b : SR.Buf, p : ?Principal) {
    switch p {
      case null { SR.putNat(b, 0, 1); var i = 0; while (i < 29) { SR.putByte(b, 0); i += 1 } };
      case (?q) {
        let bytes = Blob.toArray(Principal.toBlob(q));
        if (bytes.size() > 29) Runtime.trap("Rows: a principal of " # Nat.toText(bytes.size()) # " bytes");
        SR.putNat(b, bytes.size(), 1);
        var i = 0;
        while (i < 29) { SR.putByte(b, if (i < bytes.size()) bytes[i] else 0); i += 1 };
      };
    }
  };

  public func getPrincipal(a : [Nat8], off : Nat) : ?Principal {
    let n = Nat8.toNat(a[off]);
    if (n == 0) return null;
    ?Principal.fromBlob(Blob.fromArray(Array.tabulate<Nat8>(n, func(i) { a[off + 1 + i] })))
  };

  /// The 30-byte key field of a principal, for an index.
  public func principalField(p : Principal) : Blob {
    let b = SR.buf();
    putPrincipal(b, ?p);
    SR.done(b, W.PRINCIPAL)
  };

  func enumOf<T>(r : ?T, table : Text, field : Text) : T {
    switch r { case (?v) v; case null Runtime.trap("Rows: " # table # "." # field # " holds a byte nobody assigned") }
  };

  func blobField(t : Blob, width : Nat) : Blob {
    if (t.size() != width) Runtime.trap("Rows: a " # Nat.toText(t.size()) # "-byte field where " # Nat.toText(width) # " was declared");
    t
  };

  /// A code as a fixed field: the UTF-8 bytes, zero-padded. Refused past the width by the fold.
  public func codeKey(code : Text) : Blob { SR.textKey(code, W.CODE) };

  // ── property (one row, id 1) ────────────────────────────────────────────────

  public type Property = {
    currency : Text;
    minorUnits : Nat;
    nameEn : TA.Ref;
    nameAr : TA.Ref;
    checkInText : TA.Ref;
    checkOutText : TA.Ref;
    holdTtlHeights : Nat;
    heightsPerRealMinute : Nat;
    maxStayNights : Nat;
    horizonDays : Nat;
    maxRoomsPerBooking : Nat;
    idRetentionDays : Nat;
    lastBlock : Nat;
  };

  public let property : RowStore.Decl<Property> = {
    table = "property";
    idBytes = W.ID;
    rowBytes = W.PROPERTY_ROW;
    encode = func(x : Property) : Blob {
      let b = SR.buf();
      SR.putText(b, x.currency, W.CURRENCY);
      SR.putNat(b, x.minorUnits, W.SMALL);
      TA.putRef(b, x.nameEn); TA.putRef(b, x.nameAr); TA.putRef(b, x.checkInText); TA.putRef(b, x.checkOutText);
      SR.putNat(b, x.holdTtlHeights, W.HEIGHT);
      SR.putNat(b, x.heightsPerRealMinute, W.RATIO);
      SR.putNat(b, x.maxStayNights, W.SMALL);
      SR.putNat(b, x.horizonDays, W.COUNT);
      SR.putNat(b, x.maxRoomsPerBooking, W.SMALL);
      SR.putNat(b, x.idRetentionDays, W.COUNT);
      SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.PROPERTY_ROW)
    };
    decode = func(a : [Nat8]) : Property {
      var o = 0;
      let currency = SR.getText(a, o, W.CURRENCY); o += W.CURRENCY;
      let minorUnits = SR.getNat(a, o, W.SMALL); o += W.SMALL;
      let nameEn = TA.getRef(a, o); o += W.ARENA_REF;
      let nameAr = TA.getRef(a, o); o += W.ARENA_REF;
      let checkInText = TA.getRef(a, o); o += W.ARENA_REF;
      let checkOutText = TA.getRef(a, o); o += W.ARENA_REF;
      let holdTtlHeights = SR.getNat(a, o, W.HEIGHT); o += W.HEIGHT;
      let heightsPerRealMinute = SR.getNat(a, o, W.RATIO); o += W.RATIO;
      let maxStayNights = SR.getNat(a, o, W.SMALL); o += W.SMALL;
      let horizonDays = SR.getNat(a, o, W.COUNT); o += W.COUNT;
      let maxRoomsPerBooking = SR.getNat(a, o, W.SMALL); o += W.SMALL;
      let idRetentionDays = SR.getNat(a, o, W.COUNT); o += W.COUNT;
      let lastBlock = SR.getNat(a, o, W.BLOCK);
      { currency; minorUnits; nameEn; nameAr; checkInText; checkOutText; holdTtlHeights; heightsPerRealMinute;
        maxStayNights; horizonDays; maxRoomsPerBooking; idRetentionDays; lastBlock }
    };
    indexes = [];
  };

  // ── room type ───────────────────────────────────────────────────────────────

  public type RoomType = {
    code : Text;
    nameEn : TA.Ref;
    nameAr : TA.Ref;
    descEn : TA.Ref;
    descAr : TA.Ref;
    sizeSqm : Nat;
    maxAdults : Nat;
    maxChildren : Nat;
    maxOccupancy : Nat;
    bedKind : E.BedKind;
    bedCount : Nat;
    amenities : Nat;
    photos : TA.Ref;
    rank : Nat;
    active : Bool;
    lastBlock : Nat;
  };

  public let roomType : RowStore.Decl<RoomType> = {
    table = "roomType";
    idBytes = W.ID;
    rowBytes = W.ROOM_TYPE_ROW;
    encode = func(x : RoomType) : Blob {
      let b = SR.buf();
      SR.putText(b, x.code, W.CODE);
      TA.putRef(b, x.nameEn); TA.putRef(b, x.nameAr); TA.putRef(b, x.descEn); TA.putRef(b, x.descAr);
      SR.putNat(b, x.sizeSqm, W.COUNT);
      SR.putNat(b, x.maxAdults, W.SMALL); SR.putNat(b, x.maxChildren, W.SMALL); SR.putNat(b, x.maxOccupancy, W.SMALL);
      SR.putByte(b, E.bedKindByte(x.bedKind)); SR.putNat(b, x.bedCount, W.SMALL);
      SR.putNat(b, x.amenities, W.AMENITIES);
      TA.putRef(b, x.photos);
      SR.putNat(b, x.rank, W.SMALL); SR.putBool(b, x.active);
      SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.ROOM_TYPE_ROW)
    };
    decode = func(a : [Nat8]) : RoomType {
      var o = 0;
      let code = SR.getText(a, o, W.CODE); o += W.CODE;
      let nameEn = TA.getRef(a, o); o += 8;
      let nameAr = TA.getRef(a, o); o += 8;
      let descEn = TA.getRef(a, o); o += 8;
      let descAr = TA.getRef(a, o); o += 8;
      let sizeSqm = SR.getNat(a, o, W.COUNT); o += W.COUNT;
      let maxAdults = SR.getNat(a, o, 1); o += 1;
      let maxChildren = SR.getNat(a, o, 1); o += 1;
      let maxOccupancy = SR.getNat(a, o, 1); o += 1;
      let bedKind = enumOf(E.bedKindOf(a[o]), "roomType", "bedKind"); o += 1;
      let bedCount = SR.getNat(a, o, 1); o += 1;
      let amenities = SR.getNat(a, o, W.AMENITIES); o += W.AMENITIES;
      let photos = TA.getRef(a, o); o += 8;
      let rank = SR.getNat(a, o, 1); o += 1;
      let active = SR.getBool(a, o); o += 1;
      let lastBlock = SR.getNat(a, o, W.BLOCK);
      { code; nameEn; nameAr; descEn; descAr; sizeSqm; maxAdults; maxChildren; maxOccupancy; bedKind; bedCount;
        amenities; photos; rank; active; lastBlock }
    };
    indexes = [
      { name = "by_code"; keyBytes = W.CODE; keyOf = func(_ : Nat, x : RoomType) : ?Blob { ?codeKey(x.code) } },
    ];
  };

  // ── physical room ───────────────────────────────────────────────────────────

  public type Room = { roomTypeId : Nat; number : Text; status : E.RoomStatus; occupiedBy : Nat; lastBlock : Nat };

  public let ROOM_TYPE_KEY : Nat = 12;   // roomTypeId(6) ‖ roomId(6)

  public let room : RowStore.Decl<Room> = {
    table = "room";
    idBytes = W.ID;
    rowBytes = W.ROOM_ROW;
    encode = func(x : Room) : Blob {
      let b = SR.buf();
      SR.putNat(b, x.roomTypeId, W.ID);
      SR.putText(b, x.number, W.ROOM_NUMBER);
      SR.putByte(b, E.roomStatusByte(x.status));
      SR.putNat(b, x.occupiedBy, W.ID);
      SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.ROOM_ROW)
    };
    decode = func(a : [Nat8]) : Room {
      {
        roomTypeId = SR.getNat(a, 0, W.ID);
        number = SR.getText(a, 6, W.ROOM_NUMBER);
        status = enumOf(E.roomStatusOf(a[14]), "room", "status");
        occupiedBy = SR.getNat(a, 15, W.ID);
        lastBlock = SR.getNat(a, 21, W.BLOCK);
      }
    };
    indexes = [
      { name = "by_type"; keyBytes = ROOM_TYPE_KEY; keyOf = func(id : Nat, x : Room) : ?Blob { ?SR.key2(x.roomTypeId, W.ID, id, W.ID) } },
      { name = "vacant_by_type"; keyBytes = ROOM_TYPE_KEY;
        keyOf = func(id : Nat, x : Room) : ?Blob {
          if (x.status == #active and x.occupiedBy == 0) ?SR.key2(x.roomTypeId, W.ID, id, W.ID) else null
        } },
      { name = "by_number"; keyBytes = W.ROOM_NUMBER; keyOf = func(_ : Nat, x : Room) : ?Blob { ?SR.textKey(x.number, W.ROOM_NUMBER) } },
    ];
  };

  // ── rate plan ───────────────────────────────────────────────────────────────

  public type RatePlan = {
    code : Text;
    nameEn : TA.Ref;
    nameAr : TA.Ref;
    kind : E.PlanKind;
    discountBps : Nat;
    refundable : Bool;
    freeCancelDaysBefore : Nat;
    penaltyNights : Nat;
    guarantee : E.Guarantee;
    modifiable : Bool;
    active : Bool;
    lastBlock : Nat;
  };

  public let ratePlan : RowStore.Decl<RatePlan> = {
    table = "ratePlan";
    idBytes = W.ID;
    rowBytes = W.RATE_PLAN_ROW;
    encode = func(x : RatePlan) : Blob {
      let b = SR.buf();
      SR.putText(b, x.code, W.CODE);
      TA.putRef(b, x.nameEn); TA.putRef(b, x.nameAr);
      SR.putByte(b, E.planKindByte(x.kind));
      SR.putNat(b, x.discountBps, W.BPS);
      SR.putBool(b, x.refundable);
      SR.putNat(b, x.freeCancelDaysBefore, W.SMALL);
      SR.putNat(b, x.penaltyNights, W.SMALL);
      SR.putByte(b, E.guaranteeByte(x.guarantee));
      SR.putBool(b, x.modifiable); SR.putBool(b, x.active);
      SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.RATE_PLAN_ROW)
    };
    decode = func(a : [Nat8]) : RatePlan {
      {
        code = SR.getText(a, 0, W.CODE);
        nameEn = TA.getRef(a, 16);
        nameAr = TA.getRef(a, 24);
        kind = enumOf(E.planKindOf(a[32]), "ratePlan", "kind");
        discountBps = SR.getNat(a, 33, W.BPS);
        refundable = SR.getBool(a, 35);
        freeCancelDaysBefore = SR.getNat(a, 36, 1);
        penaltyNights = SR.getNat(a, 37, 1);
        guarantee = enumOf(E.guaranteeOf(a[38]), "ratePlan", "guarantee");
        modifiable = SR.getBool(a, 39);
        active = SR.getBool(a, 40);
        lastBlock = SR.getNat(a, 41, W.BLOCK);
      }
    };
    indexes = [
      { name = "by_code"; keyBytes = W.CODE; keyOf = func(_ : Nat, x : RatePlan) : ?Blob { ?codeKey(x.code) } },
    ];
  };

  // ── tax rule ────────────────────────────────────────────────────────────────

  public type TaxRule = {
    code : Text;
    nameEn : TA.Ref;
    nameAr : TA.Ref;
    kind : E.TaxKind;
    bps : Nat;
    amount : Nat;
    base : E.TaxBase;
    rank : Nat;
    active : Bool;
    lastBlock : Nat;
  };

  public let taxRule : RowStore.Decl<TaxRule> = {
    table = "taxRule";
    idBytes = W.ID;
    rowBytes = W.TAX_RULE_ROW;
    encode = func(x : TaxRule) : Blob {
      let b = SR.buf();
      SR.putText(b, x.code, W.CODE);
      TA.putRef(b, x.nameEn); TA.putRef(b, x.nameAr);
      SR.putByte(b, E.taxKindByte(x.kind));
      SR.putNat(b, x.bps, W.BPS);
      SR.putNat(b, x.amount, W.MONEY);
      SR.putByte(b, E.taxBaseByte(x.base));
      SR.putNat(b, x.rank, W.SMALL);
      SR.putBool(b, x.active);
      SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.TAX_RULE_ROW)
    };
    decode = func(a : [Nat8]) : TaxRule {
      {
        code = SR.getText(a, 0, W.CODE);
        nameEn = TA.getRef(a, 16);
        nameAr = TA.getRef(a, 24);
        kind = enumOf(E.taxKindOf(a[32]), "taxRule", "kind");
        bps = SR.getNat(a, 33, W.BPS);
        amount = SR.getNat(a, 35, W.MONEY);
        base = enumOf(E.taxBaseOf(a[43]), "taxRule", "base");
        rank = SR.getNat(a, 44, 1);
        active = SR.getBool(a, 45);
        lastBlock = SR.getNat(a, 46, W.BLOCK);
      }
    };
    indexes = [
      { name = "by_code"; keyBytes = W.CODE; keyOf = func(_ : Nat, x : TaxRule) : ?Blob { ?codeKey(x.code) } },
    ];
  };

  // ── the night grid ──────────────────────────────────────────────────────────

  public type Night = {
    allotment : Nat;
    sold : Nat;
    held : Nat;
    bar : Nat;
    minStay : Nat;
    maxStay : Nat;
    closedToArrival : Bool;
    closedToDeparture : Bool;
    stopSell : Bool;
    lastBlock : Nat;
  };

  public let NIGHT_ID_BYTES : Nat = 5;   // RT(2) ‖ DAY(3)

  /// The composite primary id of a night: room type in the high bytes, day in the low three.
  public func nightId(rt : Nat, day : Nat) : Nat { rt * 16_777_216 + day };
  public func nightDay(id : Nat) : Nat { id % 16_777_216 };
  public func nightRoomType(id : Nat) : Nat { id / 16_777_216 };

  public let night : RowStore.Decl<Night> = {
    table = "night";
    idBytes = NIGHT_ID_BYTES;
    rowBytes = W.NIGHT_ROW;
    encode = func(x : Night) : Blob {
      let b = SR.buf();
      SR.putNat(b, x.allotment, W.COUNT);
      SR.putNat(b, x.sold, W.COUNT);
      SR.putNat(b, x.held, W.COUNT);
      SR.putNat(b, x.bar, W.MONEY);
      SR.putNat(b, x.minStay, W.SMALL);
      SR.putNat(b, x.maxStay, W.SMALL);
      SR.putBool(b, x.closedToArrival);
      SR.putBool(b, x.closedToDeparture);
      SR.putBool(b, x.stopSell);
      SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.NIGHT_ROW)
    };
    decode = func(a : [Nat8]) : Night {
      {
        allotment = SR.getNat(a, 0, 2);
        sold = SR.getNat(a, 2, 2);
        held = SR.getNat(a, 4, 2);
        bar = SR.getNat(a, 6, W.MONEY);
        minStay = SR.getNat(a, 14, 1);
        maxStay = SR.getNat(a, 15, 1);
        closedToArrival = SR.getBool(a, 16);
        closedToDeparture = SR.getBool(a, 17);
        stopSell = SR.getBool(a, 18);
        lastBlock = SR.getNat(a, 19, W.BLOCK);
      }
    };
    indexes = [];
  };

  public func free(n : Night) : Nat {
    if (n.sold + n.held >= n.allotment) 0 else n.allotment - n.sold - n.held
  };

  // ── hold ────────────────────────────────────────────────────────────────────

  public type Hold = {
    roomTypeId : Nat;
    planId : Nat;
    arrival : Nat;
    nights : Nat;
    rooms : Nat;
    adults : Nat;
    children : Nat;
    owner : Principal;
    expiresAt : Nat;
    state : E.HoldState;
    quotedTotal : Nat;
    quoteHash : Blob;
    fromWaitlist : Nat;
    /// The browser's P-256 key for this hold: a release or a confirmation is signed with it, so a hold
    /// is not owned by a transport sender anyone could claim.
    key : Blob;
    lastBlock : Nat;
  };

  public let HOLD_EXPIRY_KEY : Nat = 12;   // expiresAt(6) ‖ holdId(6)
  public let DAY_KEY : Nat = 9;            // day(3) ‖ id(6)
  public let OWNER_KEY : Nat = 36;         // principal(30) ‖ id(6)

  public let hold : RowStore.Decl<Hold> = {
    table = "hold";
    idBytes = W.ID;
    rowBytes = W.HOLD_ROW;
    encode = func(x : Hold) : Blob {
      let b = SR.buf();
      SR.putNat(b, x.roomTypeId, W.ID);
      SR.putNat(b, x.planId, W.ID);
      SR.putNat(b, x.arrival, W.DAY);
      SR.putNat(b, x.nights, 1);
      SR.putNat(b, x.rooms, 1);
      SR.putNat(b, x.adults, 1);
      SR.putNat(b, x.children, 1);
      putPrincipal(b, ?x.owner);
      SR.putNat(b, x.expiresAt, W.HEIGHT);
      SR.putByte(b, E.holdStateByte(x.state));
      SR.putNat(b, x.quotedTotal, W.MONEY);
      SR.putBlob(b, blobField(x.quoteHash, W.HASH), W.HASH);
      SR.putNat(b, x.fromWaitlist, W.ID);
      SR.putBlob(b, blobField(x.key, W.PUBKEY), W.PUBKEY);
      SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.HOLD_ROW)
    };
    decode = func(a : [Nat8]) : Hold {
      let owner = switch (getPrincipal(a, 19)) { case (?p) p; case null Runtime.trap("Rows: a hold with no owner") };
      {
        roomTypeId = SR.getNat(a, 0, 6);
        planId = SR.getNat(a, 6, 6);
        arrival = SR.getNat(a, 12, 3);
        nights = SR.getNat(a, 15, 1);
        rooms = SR.getNat(a, 16, 1);
        adults = SR.getNat(a, 17, 1);
        children = SR.getNat(a, 18, 1);
        owner;
        expiresAt = SR.getNat(a, 49, W.HEIGHT);
        state = enumOf(E.holdStateOf(a[55]), "hold", "state");
        quotedTotal = SR.getNat(a, 56, W.MONEY);
        quoteHash = SR.getBlob(a, 64, W.HASH);
        fromWaitlist = SR.getNat(a, 96, W.ID);
        key = SR.getBlob(a, 102, W.PUBKEY);
        lastBlock = SR.getNat(a, 135, W.BLOCK);
      }
    };
    indexes = [
      { name = "live_by_expiry"; keyBytes = HOLD_EXPIRY_KEY;
        keyOf = func(id : Nat, x : Hold) : ?Blob { if (x.state == #live) ?SR.key2(x.expiresAt, W.HEIGHT, id, W.ID) else null } },
      { name = "live_by_arrival"; keyBytes = DAY_KEY;
        keyOf = func(id : Nat, x : Hold) : ?Blob { if (x.state == #live) ?SR.key2(x.arrival, W.DAY, id, W.ID) else null } },
      { name = "live_by_owner"; keyBytes = OWNER_KEY;
        keyOf = func(id : Nat, x : Hold) : ?Blob {
          if (x.state == #live) ?Blob.fromArray(Array.concat(Blob.toArray(principalField(x.owner)), Blob.toArray(SR.key(id, W.ID)))) else null
        } },
    ];
  };

  // ── booking ─────────────────────────────────────────────────────────────────

  public type Booking = {
    roomTypeId : Nat;
    planId : Nat;
    arrival : Nat;
    departure : Nat;
    rooms : Nat;
    adults : Nat;
    children : Nat;
    status : E.BookingStatus;
    account : ?Principal;
    manageKey : Blob;
    manageNonce : Nat;
    guestName : TA.Ref;
    guestEmail : TA.Ref;
    note : TA.Ref;
    charged : Nat;
    credited : Nat;
    paid : Nat;
    outstanding : Nat;
    cancelDeadline : Nat;
    penalty : Nat;
    checkedMinStay : Nat;
    checkedMaxStay : Nat;
    holdId : Nat;
    assignedRoom : Nat;
    createdBlock : Nat;
    lastBlock : Nat;
  };


  public let booking : RowStore.Decl<Booking> = {
    table = "booking";
    idBytes = W.ID;
    rowBytes = W.BOOKING_ROW;
    encode = func(x : Booking) : Blob {
      let b = SR.buf();
      SR.putNat(b, x.roomTypeId, W.ID);
      SR.putNat(b, x.planId, W.ID);
      SR.putNat(b, x.arrival, W.DAY);
      SR.putNat(b, x.departure, W.DAY);
      SR.putNat(b, x.rooms, 1); SR.putNat(b, x.adults, 1); SR.putNat(b, x.children, 1);
      SR.putByte(b, E.bookingStatusByte(x.status));
      putPrincipal(b, x.account);
      SR.putBlob(b, blobField(x.manageKey, W.PUBKEY), W.PUBKEY);
      SR.putNat(b, x.manageNonce, W.NONCE);
      TA.putRef(b, x.guestName); TA.putRef(b, x.guestEmail); TA.putRef(b, x.note);
      SR.putNat(b, x.charged, W.MONEY); SR.putNat(b, x.credited, W.MONEY);
      SR.putNat(b, x.paid, W.MONEY); SR.putNat(b, x.outstanding, W.MONEY);
      SR.putNat(b, x.cancelDeadline, W.DAY);
      SR.putNat(b, x.penalty, W.MONEY);
      SR.putNat(b, x.checkedMinStay, 1); SR.putNat(b, x.checkedMaxStay, 1);
      SR.putNat(b, x.holdId, W.ID); SR.putNat(b, x.assignedRoom, W.ID);
      SR.putNat(b, x.createdBlock, W.BLOCK); SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.BOOKING_ROW)
    };
    decode = func(a : [Nat8]) : Booking {
      var o = 0;
      let roomTypeId = SR.getNat(a, o, 6); o += 6;
      let planId = SR.getNat(a, o, 6); o += 6;
      let arrival = SR.getNat(a, o, 3); o += 3;
      let departure = SR.getNat(a, o, 3); o += 3;
      let rooms = SR.getNat(a, o, 1); o += 1;
      let adults = SR.getNat(a, o, 1); o += 1;
      let children = SR.getNat(a, o, 1); o += 1;
      let status = enumOf(E.bookingStatusOf(a[o]), "booking", "status"); o += 1;
      let account = getPrincipal(a, o); o += W.PRINCIPAL;
      let manageKey = SR.getBlob(a, o, W.PUBKEY); o += W.PUBKEY;
      let manageNonce = SR.getNat(a, o, W.NONCE); o += W.NONCE;
      let guestName = TA.getRef(a, o); o += 8;
      let guestEmail = TA.getRef(a, o); o += 8;
      let note = TA.getRef(a, o); o += 8;
      let charged = SR.getNat(a, o, 8); o += 8;
      let credited = SR.getNat(a, o, 8); o += 8;
      let paid = SR.getNat(a, o, 8); o += 8;
      let outstanding = SR.getNat(a, o, 8); o += 8;
      let cancelDeadline = SR.getNat(a, o, 3); o += 3;
      let penalty = SR.getNat(a, o, 8); o += 8;
      let checkedMinStay = SR.getNat(a, o, 1); o += 1;
      let checkedMaxStay = SR.getNat(a, o, 1); o += 1;
      let holdId = SR.getNat(a, o, 6); o += 6;
      let assignedRoom = SR.getNat(a, o, 6); o += 6;
      let createdBlock = SR.getNat(a, o, 6); o += 6;
      let lastBlock = SR.getNat(a, o, 6);
      { roomTypeId; planId; arrival; departure; rooms; adults; children; status; account; manageKey; manageNonce;
        guestName; guestEmail; note; charged; credited; paid; outstanding; cancelDeadline; penalty;
        checkedMinStay; checkedMaxStay; holdId; assignedRoom; createdBlock; lastBlock }
    };
    indexes = [
      { name = "by_account"; keyBytes = OWNER_KEY;
        keyOf = func(id : Nat, x : Booking) : ?Blob {
          switch (x.account) {
            case (?p) ?Blob.fromArray(Array.concat(Blob.toArray(principalField(p)), Blob.toArray(SR.key(id, W.ID))));
            case null null;
          }
        } },
      { name = "arrivals"; keyBytes = DAY_KEY;
        keyOf = func(id : Nat, x : Booking) : ?Blob { if (x.status == #confirmed) ?SR.key2(x.arrival, W.DAY, id, W.ID) else null } },
      { name = "in_house"; keyBytes = DAY_KEY;
        keyOf = func(id : Nat, x : Booking) : ?Blob { if (x.status == #checkedIn) ?SR.key2(x.departure, W.DAY, id, W.ID) else null } },
      { name = "by_arrival"; keyBytes = DAY_KEY;
        keyOf = func(id : Nat, x : Booking) : ?Blob { ?SR.key2(x.arrival, W.DAY, id, W.ID) } },
    ];
  };

  // ── folio line ──────────────────────────────────────────────────────────────

  public type FolioLine = { bookingId : Nat; kind : E.FolioKind; code : Nat; night : Nat; amount : Nat; block : Nat };

  public let BY_BOOKING_KEY : Nat = 12;   // bookingId(6) ‖ id(6)

  public let folioLine : RowStore.Decl<FolioLine> = {
    table = "folioLine";
    idBytes = W.ID;
    rowBytes = W.FOLIO_ROW;
    encode = func(x : FolioLine) : Blob {
      let b = SR.buf();
      SR.putNat(b, x.bookingId, W.ID);
      SR.putByte(b, E.folioKindByte(x.kind));
      SR.putNat(b, x.code, 1);
      SR.putNat(b, x.night, W.DAY);
      SR.putNat(b, x.amount, W.MONEY);
      SR.putNat(b, x.block, W.BLOCK);
      SR.done(b, W.FOLIO_ROW)
    };
    decode = func(a : [Nat8]) : FolioLine {
      {
        bookingId = SR.getNat(a, 0, 6);
        kind = enumOf(E.folioKindOf(a[6]), "folioLine", "kind");
        code = SR.getNat(a, 7, 1);
        night = SR.getNat(a, 8, 3);
        amount = SR.getNat(a, 11, 8);
        block = SR.getNat(a, 19, 6);
      }
    };
    indexes = [
      { name = "by_booking"; keyBytes = BY_BOOKING_KEY; keyOf = func(id : Nat, x : FolioLine) : ?Blob { ?SR.key2(x.bookingId, W.ID, id, W.ID) } },
    ];
  };

  // ── payment ─────────────────────────────────────────────────────────────────

  public type Payment = {
    bookingId : Nat;
    gatewayAuth : Nat;
    kind : E.PaymentKind;
    amount : Nat;
    state : E.PaymentState;
    attempts : Nat;
    block : Nat;
  };

  public let AUTH_KEY : Nat = 13;   // gatewayAuth(6) ‖ kind(1) ‖ id(6)

  public func authKey(auth : Nat, kind : E.PaymentKind, id : Nat) : Blob {
    let b = SR.buf();
    SR.putNat(b, auth, W.ID);
    SR.putByte(b, E.paymentKindByte(kind));
    SR.putNat(b, id, W.ID);
    SR.done(b, AUTH_KEY)
  };

  public let payment : RowStore.Decl<Payment> = {
    table = "payment";
    idBytes = W.ID;
    rowBytes = W.PAYMENT_ROW;
    encode = func(x : Payment) : Blob {
      let b = SR.buf();
      SR.putNat(b, x.bookingId, W.ID);
      SR.putNat(b, x.gatewayAuth, W.ID);
      SR.putByte(b, E.paymentKindByte(x.kind));
      SR.putNat(b, x.amount, W.MONEY);
      SR.putByte(b, E.paymentStateByte(x.state));
      SR.putNat(b, x.attempts, 1);
      SR.putNat(b, x.block, W.BLOCK);
      SR.done(b, W.PAYMENT_ROW)
    };
    decode = func(a : [Nat8]) : Payment {
      {
        bookingId = SR.getNat(a, 0, 6);
        gatewayAuth = SR.getNat(a, 6, 6);
        kind = enumOf(E.paymentKindOf(a[12]), "payment", "kind");
        amount = SR.getNat(a, 13, 8);
        state = enumOf(E.paymentStateOf(a[21]), "payment", "state");
        attempts = SR.getNat(a, 22, 1);
        block = SR.getNat(a, 23, 6);
      }
    };
    indexes = [
      { name = "by_booking"; keyBytes = BY_BOOKING_KEY; keyOf = func(id : Nat, x : Payment) : ?Blob { ?SR.key2(x.bookingId, W.ID, id, W.ID) } },
      { name = "by_auth"; keyBytes = AUTH_KEY; keyOf = func(id : Nat, x : Payment) : ?Blob { ?authKey(x.gatewayAuth, x.kind, id) } },
      { name = "gateway_due"; keyBytes = W.ID; keyOf = func(id : Nat, x : Payment) : ?Blob { if (x.state == #due) ?SR.key(id, W.ID) else null } },
    ];
  };

  // ── waitlist ────────────────────────────────────────────────────────────────

  public type WaitEntry = {
    account : Principal;
    roomTypeId : Nat;
    arrival : Nat;
    nights : Nat;
    rooms : Nat;
    adults : Nat;
    children : Nat;
    state : E.WaitState;
    offeredHold : Nat;
    lastBlock : Nat;
  };

  public let waitlist : RowStore.Decl<WaitEntry> = {
    table = "waitlist";
    idBytes = W.ID;
    rowBytes = W.WAITLIST_ROW;
    encode = func(x : WaitEntry) : Blob {
      let b = SR.buf();
      putPrincipal(b, ?x.account);
      SR.putNat(b, x.roomTypeId, W.ID);
      SR.putNat(b, x.arrival, W.DAY);
      SR.putNat(b, x.nights, 1); SR.putNat(b, x.rooms, 1); SR.putNat(b, x.adults, 1); SR.putNat(b, x.children, 1);
      SR.putByte(b, E.waitStateByte(x.state));
      SR.putNat(b, x.offeredHold, W.ID);
      SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.WAITLIST_ROW)
    };
    decode = func(a : [Nat8]) : WaitEntry {
      let account = switch (getPrincipal(a, 0)) { case (?p) p; case null Runtime.trap("Rows: a waitlist entry with no account") };
      {
        account;
        roomTypeId = SR.getNat(a, 30, 6);
        arrival = SR.getNat(a, 36, 3);
        nights = SR.getNat(a, 39, 1);
        rooms = SR.getNat(a, 40, 1);
        adults = SR.getNat(a, 41, 1);
        children = SR.getNat(a, 42, 1);
        state = enumOf(E.waitStateOf(a[43]), "waitlist", "state");
        offeredHold = SR.getNat(a, 44, 6);
        lastBlock = SR.getNat(a, 50, 6);
      }
    };
    indexes = [
      { name = "waiting_by_type"; keyBytes = ROOM_TYPE_KEY;
        keyOf = func(id : Nat, x : WaitEntry) : ?Blob { if (x.state == #waiting) ?SR.key2(x.roomTypeId, W.ID, id, W.ID) else null } },
      { name = "by_account"; keyBytes = OWNER_KEY;
        keyOf = func(id : Nat, x : WaitEntry) : ?Blob {
          ?Blob.fromArray(Array.concat(Blob.toArray(principalField(x.account)), Blob.toArray(SR.key(id, W.ID))))
        } },
    ];
  };

  // ── staff grant ─────────────────────────────────────────────────────────────

  public type Grant = { subject : Principal; role : E.Role; active : Bool; lastBlock : Nat };

  public let SUBJECT_ROLE_KEY : Nat = 31;   // principal(30) ‖ role(1)

  public func subjectRoleKey(p : Principal, r : E.Role) : Blob {
    Blob.fromArray(Array.concat(Blob.toArray(principalField(p)), [E.roleByte(r)]))
  };

  public let grant : RowStore.Decl<Grant> = {
    table = "grant";
    idBytes = W.ID;
    rowBytes = W.GRANT_ROW;
    encode = func(x : Grant) : Blob {
      let b = SR.buf();
      putPrincipal(b, ?x.subject);
      SR.putByte(b, E.roleByte(x.role));
      SR.putBool(b, x.active);
      SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.GRANT_ROW)
    };
    decode = func(a : [Nat8]) : Grant {
      let subject = switch (getPrincipal(a, 0)) { case (?p) p; case null Runtime.trap("Rows: a grant with no subject") };
      { subject; role = enumOf(E.roleOf(a[30]), "grant", "role"); active = SR.getBool(a, 31); lastBlock = SR.getNat(a, 32, 6) }
    };
    indexes = [
      { name = "active_by_subject"; keyBytes = SUBJECT_ROLE_KEY;
        keyOf = func(_ : Nat, x : Grant) : ?Blob { if (x.active) ?subjectRoleKey(x.subject, x.role) else null } },
    ];
  };

  // ── four-eyes proposal ──────────────────────────────────────────────────────

  public type Proposal = {
    maker : Principal;
    permission : Nat;
    proposedBlock : Nat;
    expiresAt : Nat;
    status : E.ProposalStatus;
    checker : ?Principal;
    resolvedBlock : Nat;
    commandHash : Blob;
    /// The proposed act's canonical bytes, kept so the approval re-derives the hash from them.
    act : TA.Ref;
  };

  public let proposal : RowStore.Decl<Proposal> = {
    table = "proposal";
    idBytes = W.ID;
    rowBytes = W.PROPOSAL_ROW;
    encode = func(x : Proposal) : Blob {
      let b = SR.buf();
      putPrincipal(b, ?x.maker);
      SR.putNat(b, x.permission, 1);
      SR.putNat(b, x.proposedBlock, W.BLOCK);
      SR.putNat(b, x.expiresAt, W.HEIGHT);
      SR.putByte(b, E.proposalStatusByte(x.status));
      putPrincipal(b, x.checker);
      SR.putNat(b, x.resolvedBlock, W.BLOCK);
      SR.putBlob(b, blobField(x.commandHash, W.HASH), W.HASH);
      TA.putRef(b, x.act);
      SR.done(b, W.PROPOSAL_ROW)
    };
    decode = func(a : [Nat8]) : Proposal {
      let maker = switch (getPrincipal(a, 0)) { case (?p) p; case null Runtime.trap("Rows: a proposal with no maker") };
      {
        maker;
        permission = SR.getNat(a, 30, 1);
        proposedBlock = SR.getNat(a, 31, 6);
        expiresAt = SR.getNat(a, 37, 6);
        status = enumOf(E.proposalStatusOf(a[43]), "proposal", "status");
        checker = getPrincipal(a, 44);
        resolvedBlock = SR.getNat(a, 74, 6);
        commandHash = SR.getBlob(a, 80, W.HASH);
        act = TA.getRef(a, 112);
      }
    };
    indexes = [
      { name = "awaiting"; keyBytes = W.ID; keyOf = func(id : Nat, x : Proposal) : ?Blob { if (x.status == #awaiting) ?SR.key(id, W.ID) else null } },
    ];
  };

  // ── the hotel clock (a later table: see Store.Later) ────────────────────────

  /// The hotel's own clock: the time zone its day is kept in, the local time the night audit runs at,
  /// whether the contract runs it by itself, and the principal that holds the audit when it does (the
  /// contract's own, written by the command that turned it on).
  public type HotelClock = { zoneName : TA.Ref; zoneRule : TA.Ref; auditAt : Nat; auto : Bool; runner : ?Principal; lastBlock : Nat };

  public let hotelClock : RowStore.Decl<HotelClock> = {
    table = "hotelClock";
    idBytes = W.ID;
    rowBytes = W.HOTEL_CLOCK_ROW;
    encode = func(x : HotelClock) : Blob {
      let b = SR.buf();
      TA.putRef(b, x.zoneName); TA.putRef(b, x.zoneRule);
      SR.putNat(b, x.auditAt, W.SECOND_OF_DAY);
      SR.putBool(b, x.auto);
      putPrincipal(b, x.runner);
      SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.HOTEL_CLOCK_ROW)
    };
    decode = func(a : [Nat8]) : HotelClock {
      { zoneName = TA.getRef(a, 0); zoneRule = TA.getRef(a, 8); auditAt = SR.getNat(a, 16, 3); auto = SR.getBool(a, 19);
        runner = getPrincipal(a, 20); lastBlock = SR.getNat(a, 50, 6) }
    };
    indexes = [];
  };

  // ── housekeeping (a later table: see Store.Later) ───────────────────────────

  /// A room's housekeeping record, under the room's own id. `cleanedBy` is who last cleaned it and
  /// `inspectedBy` who inspected that cleaning, a different person; both are cleared when it is dirty
  /// again. A room out of order with dates has its reason, the day it went out and `outUntil`, the
  /// first night it is back in the count (0: no dates). `changedDay` is the business day of the last
  /// change, for the board.
  public type Housekeeping = {
    cleaning : E.Cleaning;
    cleanedBy : ?Principal;
    inspectedBy : ?Principal;
    outReason : TA.Ref;
    outFrom : Nat;
    outUntil : Nat;
    changedDay : Nat;
    lastBlock : Nat;
  };

  public let housekeeping : RowStore.Decl<Housekeeping> = {
    table = "housekeeping";
    idBytes = W.ID;
    rowBytes = W.HOUSEKEEPING_ROW;
    encode = func(x : Housekeeping) : Blob {
      let b = SR.buf();
      SR.putByte(b, E.cleaningByte(x.cleaning));
      putPrincipal(b, x.cleanedBy);
      putPrincipal(b, x.inspectedBy);
      TA.putRef(b, x.outReason);
      SR.putNat(b, x.outFrom, W.DAY);
      SR.putNat(b, x.outUntil, W.DAY);
      SR.putNat(b, x.changedDay, W.DAY);
      SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.HOUSEKEEPING_ROW)
    };
    decode = func(a : [Nat8]) : Housekeeping {
      {
        cleaning = enumOf(E.cleaningOf(a[0]), "housekeeping", "cleaning");
        cleanedBy = getPrincipal(a, 1);
        inspectedBy = getPrincipal(a, 31);
        outReason = TA.getRef(a, 61);
        outFrom = SR.getNat(a, 69, W.DAY);
        outUntil = SR.getNat(a, 72, W.DAY);
        changedDay = SR.getNat(a, 75, W.DAY);
        lastBlock = SR.getNat(a, 78, W.BLOCK);
      }
    };
    indexes = [];
  };

  // ── the bill: extras, payers and invoices (later tables: see Store.Later) ───

  /// An item of the hotel's extras catalogue. `price` 0 is an item whose amount is entered when it is
  /// posted (a restaurant bill); `taxed` applies the hotel's percentage taxes to it.
  public type Extra = { code : Text; nameEn : TA.Ref; nameAr : TA.Ref; category : E.ExtraCategory; price : Nat; taxed : Bool; active : Bool; lastBlock : Nat };

  public let extra : RowStore.Decl<Extra> = {
    table = "extra";
    idBytes = W.ID;
    rowBytes = W.EXTRA_ROW;
    encode = func(x : Extra) : Blob {
      let b = SR.buf();
      SR.putText(b, x.code, W.CODE);
      TA.putRef(b, x.nameEn); TA.putRef(b, x.nameAr);
      SR.putByte(b, E.extraCategoryByte(x.category));
      SR.putNat(b, x.price, W.MONEY);
      SR.putBool(b, x.taxed); SR.putBool(b, x.active);
      SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.EXTRA_ROW)
    };
    decode = func(a : [Nat8]) : Extra {
      { code = SR.getText(a, 0, W.CODE); nameEn = TA.getRef(a, 16); nameAr = TA.getRef(a, 24);
        category = enumOf(E.extraCategoryOf(a[32]), "extra", "category"); price = SR.getNat(a, 33, W.MONEY);
        taxed = SR.getBool(a, 41); active = SR.getBool(a, 42); lastBlock = SR.getNat(a, 43, W.BLOCK) }
    };
    indexes = [
      { name = "by_code"; keyBytes = W.CODE; keyOf = func(_ : Nat, x : Extra) : ?Blob { ?codeKey(x.code) } },
    ];
  };

  /// An extra posted to a stay, under the id of its folio line (kind `extra`, the amount before tax).
  /// Its tax lines are the `taxLines` lines that follow it. `voidLine` is the credit line that voided
  /// it, 0 while it stands.
  public type Charge = { bookingId : Nat; extraId : Nat; quantity : Nat; unitAmount : Nat; taxLines : Nat; postedBy : Principal; voidLine : Nat; lastBlock : Nat };

  public let charge : RowStore.Decl<Charge> = {
    table = "charge";
    idBytes = W.ID;
    rowBytes = W.CHARGE_ROW;
    encode = func(x : Charge) : Blob {
      let b = SR.buf();
      SR.putNat(b, x.bookingId, W.ID); SR.putNat(b, x.extraId, W.ID);
      SR.putNat(b, x.quantity, W.COUNT); SR.putNat(b, x.unitAmount, W.MONEY); SR.putNat(b, x.taxLines, W.SMALL);
      putPrincipal(b, ?x.postedBy);
      SR.putNat(b, x.voidLine, W.ID);
      SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.CHARGE_ROW)
    };
    decode = func(a : [Nat8]) : Charge {
      let postedBy = switch (getPrincipal(a, 23)) { case (?p) p; case null Runtime.trap("Rows: a charge with no poster") };
      { bookingId = SR.getNat(a, 0, W.ID); extraId = SR.getNat(a, 6, W.ID); quantity = SR.getNat(a, 12, W.COUNT); unitAmount = SR.getNat(a, 14, W.MONEY);
        taxLines = SR.getNat(a, 22, W.SMALL); postedBy; voidLine = SR.getNat(a, 53, W.ID); lastBlock = SR.getNat(a, 59, W.BLOCK) }
    };
    indexes = [];
  };

  /// A window of a booking's bill paid by someone other than the guest (a company, a relative). The
  /// guest's own window is 0 and has no row.
  public type Payer = { bookingId : Nat; name : TA.Ref; lastBlock : Nat };

  public let payer : RowStore.Decl<Payer> = {
    table = "payer";
    idBytes = W.ID;
    rowBytes = W.PAYER_ROW;
    encode = func(x : Payer) : Blob {
      let b = SR.buf();
      SR.putNat(b, x.bookingId, W.ID); TA.putRef(b, x.name); SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.PAYER_ROW)
    };
    decode = func(a : [Nat8]) : Payer { { bookingId = SR.getNat(a, 0, W.ID); name = TA.getRef(a, 6); lastBlock = SR.getNat(a, 14, W.BLOCK) } };
    indexes = [
      { name = "by_booking"; keyBytes = 12; keyOf = func(id : Nat, x : Payer) : ?Blob { ?SR.key2(x.bookingId, W.ID, id, W.ID) } },
    ];
  };

  /// The window a folio line or a payment belongs to, under that line's or payment's id. No row: the
  /// guest's window (0).
  public type Route = { payerId : Nat; lastBlock : Nat };

  public let lineRoute : RowStore.Decl<Route> = {
    table = "lineRoute";
    idBytes = W.ID;
    rowBytes = W.ROUTE_ROW;
    encode = func(x : Route) : Blob { let b = SR.buf(); SR.putNat(b, x.payerId, W.ID); SR.putNat(b, x.lastBlock, W.BLOCK); SR.done(b, W.ROUTE_ROW) };
    decode = func(a : [Nat8]) : Route { { payerId = SR.getNat(a, 0, W.ID); lastBlock = SR.getNat(a, 6, W.BLOCK) } };
    indexes = [];
  };

  public let paymentRoute : RowStore.Decl<Route> = {
    table = "paymentRoute";
    idBytes = W.ID;
    rowBytes = W.ROUTE_ROW;
    encode = func(x : Route) : Blob { let b = SR.buf(); SR.putNat(b, x.payerId, W.ID); SR.putNat(b, x.lastBlock, W.BLOCK); SR.done(b, W.ROUTE_ROW) };
    decode = func(a : [Nat8]) : Route { { payerId = SR.getNat(a, 0, W.ID); lastBlock = SR.getNat(a, 6, W.BLOCK) } };
    indexes = [];
  };

  /// An invoice, under its number (1, 2, … with no gap): one window of one booking's bill, closed
  /// when issued. The figures are the window's at that moment; nothing is posted to it, moved in or
  /// out of it, or voided on it afterwards, so they stay its figures.
  public type Invoice = { bookingId : Nat; payerId : Nat; issuedDay : Nat; charges : Nat; credits : Nat; taxes : Nat; paid : Nat; issuedBy : Principal; lastBlock : Nat };

  public let INVOICE_WINDOW_KEY : Nat = 12;   // bookingId(6) ‖ payerId(6)

  public let invoice : RowStore.Decl<Invoice> = {
    table = "invoice";
    idBytes = W.ID;
    rowBytes = W.INVOICE_ROW;
    encode = func(x : Invoice) : Blob {
      let b = SR.buf();
      SR.putNat(b, x.bookingId, W.ID); SR.putNat(b, x.payerId, W.ID); SR.putNat(b, x.issuedDay, W.DAY);
      SR.putNat(b, x.charges, W.MONEY); SR.putNat(b, x.credits, W.MONEY); SR.putNat(b, x.taxes, W.MONEY); SR.putNat(b, x.paid, W.MONEY);
      putPrincipal(b, ?x.issuedBy);
      SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.INVOICE_ROW)
    };
    decode = func(a : [Nat8]) : Invoice {
      let issuedBy = switch (getPrincipal(a, 47)) { case (?p) p; case null Runtime.trap("Rows: an invoice with no issuer") };
      { bookingId = SR.getNat(a, 0, W.ID); payerId = SR.getNat(a, 6, W.ID); issuedDay = SR.getNat(a, 12, W.DAY);
        charges = SR.getNat(a, 15, W.MONEY); credits = SR.getNat(a, 23, W.MONEY); taxes = SR.getNat(a, 31, W.MONEY); paid = SR.getNat(a, 39, W.MONEY);
        issuedBy; lastBlock = SR.getNat(a, 77, W.BLOCK) }
    };
    indexes = [
      { name = "by_window"; keyBytes = INVOICE_WINDOW_KEY; keyOf = func(_ : Nat, x : Invoice) : ?Blob { ?SR.key2(x.bookingId, W.ID, x.payerId, W.ID) } },
    ];
  };

  // ── credit notes ─────────────────────────────────────────────────────────────

  /// A credit note, under its number in a run of its own (CN-1, CN-2, …), against an invoice that stays
  /// as it was issued. Its credit lines are the `lines` folio lines from `firstLine`, all on the invoice's
  /// bill; `net` is what they take off the goods and services, `taxes` what they take off the taxes.
  /// `proposal` is the four-eyes proposal that issued it (its maker and its approver).
  public type CreditNote = { invoice : Nat; bookingId : Nat; payerId : Nat; issuedDay : Nat; net : Nat; taxes : Nat; total : Nat;
    firstLine : Nat; lines : Nat; proposal : Nat; lastBlock : Nat };

  public let CREDIT_NOTE_INVOICE_KEY : Nat = 12;   // invoice(6) ‖ number(6)

  public let creditNote : RowStore.Decl<CreditNote> = {
    table = "creditNote";
    idBytes = W.ID;
    rowBytes = W.CREDIT_NOTE_ROW;
    encode = func(x : CreditNote) : Blob {
      let b = SR.buf();
      SR.putNat(b, x.invoice, W.ID); SR.putNat(b, x.bookingId, W.ID); SR.putNat(b, x.payerId, W.ID); SR.putNat(b, x.issuedDay, W.DAY);
      SR.putNat(b, x.net, W.MONEY); SR.putNat(b, x.taxes, W.MONEY); SR.putNat(b, x.total, W.MONEY);
      SR.putNat(b, x.firstLine, W.ID); SR.putNat(b, x.lines, W.SMALL); SR.putNat(b, x.proposal, W.ID);
      SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.CREDIT_NOTE_ROW)
    };
    decode = func(a : [Nat8]) : CreditNote {
      { invoice = SR.getNat(a, 0, W.ID); bookingId = SR.getNat(a, 6, W.ID); payerId = SR.getNat(a, 12, W.ID); issuedDay = SR.getNat(a, 18, W.DAY);
        net = SR.getNat(a, 21, W.MONEY); taxes = SR.getNat(a, 29, W.MONEY); total = SR.getNat(a, 37, W.MONEY);
        firstLine = SR.getNat(a, 45, W.ID); lines = SR.getNat(a, 51, W.SMALL); proposal = SR.getNat(a, 52, W.ID); lastBlock = SR.getNat(a, 58, W.BLOCK) }
    };
    indexes = [
      { name = "by_invoice"; keyBytes = CREDIT_NOTE_INVOICE_KEY; keyOf = func(id : Nat, x : CreditNote) : ?Blob { ?SR.key2(x.invoice, W.ID, id, W.ID) } },
    ];
  };

  /// One line of a credit note, under the id of its credit folio line: the note, and the line it takes
  /// back (a room night, an extra, a penalty, or one of their tax lines).
  public type CreditLine = { note : Nat; source : Nat; lastBlock : Nat };

  public let CREDIT_LINE_SOURCE_KEY : Nat = 12;   // source(6) ‖ credit line(6)

  public let creditLine : RowStore.Decl<CreditLine> = {
    table = "creditLine";
    idBytes = W.ID;
    rowBytes = W.CREDIT_LINE_ROW;
    encode = func(x : CreditLine) : Blob {
      let b = SR.buf();
      SR.putNat(b, x.note, W.ID); SR.putNat(b, x.source, W.ID); SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.CREDIT_LINE_ROW)
    };
    decode = func(a : [Nat8]) : CreditLine { { note = SR.getNat(a, 0, W.ID); source = SR.getNat(a, 6, W.ID); lastBlock = SR.getNat(a, 12, W.BLOCK) } };
    indexes = [
      { name = "by_source"; keyBytes = CREDIT_LINE_SOURCE_KEY; keyOf = func(id : Nat, x : CreditLine) : ?Blob { ?SR.key2(x.source, W.ID, id, W.ID) } },
    ];
  };

  /// A refund the gateway would not make (its payment `failed`), paid at the desk instead, under that
  /// payment's id: how, the reference of the cash receipt or the transfer, the day, and the proposal.
  public type DeskRefund = { bookingId : Nat; method : E.DeskMethod; reference : TA.Ref; day : Nat; proposal : Nat; lastBlock : Nat };

  public let deskRefund : RowStore.Decl<DeskRefund> = {
    table = "deskRefund";
    idBytes = W.ID;
    rowBytes = W.DESK_REFUND_ROW;
    encode = func(x : DeskRefund) : Blob {
      let b = SR.buf();
      SR.putNat(b, x.bookingId, W.ID); SR.putByte(b, E.deskMethodByte(x.method)); TA.putRef(b, x.reference);
      SR.putNat(b, x.day, W.DAY); SR.putNat(b, x.proposal, W.ID); SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.DESK_REFUND_ROW)
    };
    decode = func(a : [Nat8]) : DeskRefund {
      { bookingId = SR.getNat(a, 0, W.ID); method = enumOf(E.deskMethodOf(a[6]), "deskRefund", "method"); reference = TA.getRef(a, 7);
        day = SR.getNat(a, 15, W.DAY); proposal = SR.getNat(a, 18, W.ID); lastBlock = SR.getNat(a, 24, W.BLOCK) }
    };
    indexes = [];
  };

  /// A booking staff took for a guest on the phone or at the desk (no hold, no card), under the
  /// booking's id: how it came, who took it, and the business day it was taken.
  public type StaffBooking = { channel : E.Channel; madeBy : Principal; day : Nat; lastBlock : Nat };

  public let staffBooking : RowStore.Decl<StaffBooking> = {
    table = "staffBooking";
    idBytes = W.ID;
    rowBytes = W.STAFF_BOOKING_ROW;
    encode = func(x : StaffBooking) : Blob {
      let b = SR.buf();
      SR.putByte(b, E.channelByte(x.channel)); putPrincipal(b, ?x.madeBy); SR.putNat(b, x.day, W.DAY); SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.STAFF_BOOKING_ROW)
    };
    decode = func(a : [Nat8]) : StaffBooking {
      let madeBy = switch (getPrincipal(a, 1)) { case (?p) p; case null Runtime.trap("staffBooking: no maker") };
      { channel = enumOf(E.channelOf(a[0]), "staffBooking", "channel"); madeBy; day = SR.getNat(a, 31, W.DAY); lastBlock = SR.getNat(a, 34, W.BLOCK) }
    };
    indexes = [];
  };

  /// A business day's figures, under the day, written by that day's night audit. The plan's counts
  /// (rooms, guests in house, bookings made) are fixed when the audit opens; each job adds what it
  /// saw, so on a closed day every `...Seen` equals the count it was planned from.
  ///   rooms        the hotel's rooms when the audit opened, how many were looked at, how many were
  ///                out of order, and how many were sold for the night (rooms of guests in house who
  ///                stay the night: arrived on or before the day, leaving after it)
  ///   roomRevenue  the room charges of that night on those bookings, before tax
  ///   inHouse      the bookings in house staying the night, and how many were looked at; arrivals:
  ///                those of them that arrived that day; noShows: the arrivals the audit marked
  ///   pickup       the bookings made since the last day's figures: booking ids from `pickupFrom`,
  ///                `pickupCount` of them; how many were looked at, their room nights and room revenue
  ///   cursor       the last guest in house looked at (departure, id), where the next job goes on
  public type DayFigures = {
    roomsTotal : Nat; roomsSeen : Nat; roomsOut : Nat; roomsSold : Nat; roomRevenue : Nat;
    inHouse : Nat; houseSeen : Nat; arrivals : Nat; noShows : Nat;
    pickupFrom : Nat; pickupCount : Nat; pickupBookings : Nat; pickupNights : Nat; pickupRevenue : Nat;
    cursorDay : Nat; cursorId : Nat; lastBlock : Nat;
  };

  public let dayFigures : RowStore.Decl<DayFigures> = {
    table = "dayFigures";
    idBytes = W.ID;
    rowBytes = W.DAY_FIGURES_ROW;
    encode = func(x : DayFigures) : Blob {
      let b = SR.buf();
      SR.putNat(b, x.roomsTotal, W.TALLY); SR.putNat(b, x.roomsSeen, W.TALLY); SR.putNat(b, x.roomsOut, W.TALLY); SR.putNat(b, x.roomsSold, W.TALLY);
      SR.putNat(b, x.roomRevenue, W.MONEY);
      SR.putNat(b, x.inHouse, W.TALLY); SR.putNat(b, x.houseSeen, W.TALLY); SR.putNat(b, x.arrivals, W.TALLY); SR.putNat(b, x.noShows, W.TALLY);
      SR.putNat(b, x.pickupFrom, W.ID); SR.putNat(b, x.pickupCount, W.TALLY); SR.putNat(b, x.pickupBookings, W.TALLY); SR.putNat(b, x.pickupNights, W.TALLY);
      SR.putNat(b, x.pickupRevenue, W.MONEY);
      SR.putNat(b, x.cursorDay, W.DAY); SR.putNat(b, x.cursorId, W.ID); SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.DAY_FIGURES_ROW)
    };
    decode = func(a : [Nat8]) : DayFigures {
      {
        roomsTotal = SR.getNat(a, 0, W.TALLY); roomsSeen = SR.getNat(a, 4, W.TALLY); roomsOut = SR.getNat(a, 8, W.TALLY); roomsSold = SR.getNat(a, 12, W.TALLY);
        roomRevenue = SR.getNat(a, 16, W.MONEY);
        inHouse = SR.getNat(a, 24, W.TALLY); houseSeen = SR.getNat(a, 28, W.TALLY); arrivals = SR.getNat(a, 32, W.TALLY); noShows = SR.getNat(a, 36, W.TALLY);
        pickupFrom = SR.getNat(a, 40, W.ID); pickupCount = SR.getNat(a, 46, W.TALLY); pickupBookings = SR.getNat(a, 50, W.TALLY); pickupNights = SR.getNat(a, 54, W.TALLY);
        pickupRevenue = SR.getNat(a, 58, W.MONEY);
        cursorDay = SR.getNat(a, 66, W.DAY); cursorId = SR.getNat(a, 69, W.ID); lastBlock = SR.getNat(a, 75, W.BLOCK);
      }
    };
    indexes = [];
  };

  /// A night's room nights and room revenue for one room type and rate plan, from the same audit
  /// job that counts the night's guests in house. A run of its own, found by (day, type, plan).
  public type DayRevenue = { day : Nat; roomTypeId : Nat; planId : Nat; roomNights : Nat; revenue : Nat; lastBlock : Nat };

  public let DAY_REVENUE_KEY : Nat = 15;   // day(3) ‖ roomTypeId(6) ‖ planId(6)

  public func dayRevenueKey(day : Nat, roomTypeId : Nat, planId : Nat) : Blob {
    SR.key2(day, W.DAY, roomTypeId * 281_474_976_710_656 + planId, 2 * W.ID)
  };

  public let dayRevenue : RowStore.Decl<DayRevenue> = {
    table = "dayRevenue";
    idBytes = W.ID;
    rowBytes = W.DAY_REVENUE_ROW;
    encode = func(x : DayRevenue) : Blob {
      let b = SR.buf();
      SR.putNat(b, x.day, W.DAY); SR.putNat(b, x.roomTypeId, W.ID); SR.putNat(b, x.planId, W.ID);
      SR.putNat(b, x.roomNights, W.TALLY); SR.putNat(b, x.revenue, W.MONEY); SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.DAY_REVENUE_ROW)
    };
    decode = func(a : [Nat8]) : DayRevenue {
      { day = SR.getNat(a, 0, W.DAY); roomTypeId = SR.getNat(a, 3, W.ID); planId = SR.getNat(a, 9, W.ID);
        roomNights = SR.getNat(a, 15, W.TALLY); revenue = SR.getNat(a, 19, W.MONEY); lastBlock = SR.getNat(a, 27, W.BLOCK) }
    };
    indexes = [
      { name = "by_key"; keyBytes = DAY_REVENUE_KEY; keyOf = func(_ : Nat, x : DayRevenue) : ?Blob { ?dayRevenueKey(x.day, x.roomTypeId, x.planId) } },
    ];
  };

  /// A slice of a refund to the guest, under the refund's payment id: the settle that wrote it split
  /// `excess` across the guest's cards, newest first, its slices are the payments from `firstSlice` on
  /// that carry the same first slice, and `written` is the block of that settle (a payment's own block
  /// moves with its state; this one does not).
  public type RefundSlice = { firstSlice : Nat; excess : Nat; written : Nat };

  public let refundSlice : RowStore.Decl<RefundSlice> = {
    table = "refundSlice";
    idBytes = W.ID;
    rowBytes = W.REFUND_SLICE_ROW;
    encode = func(x : RefundSlice) : Blob {
      let b = SR.buf();
      SR.putNat(b, x.firstSlice, W.ID); SR.putNat(b, x.excess, W.MONEY); SR.putNat(b, x.written, W.BLOCK);
      SR.done(b, W.REFUND_SLICE_ROW)
    };
    decode = func(a : [Nat8]) : RefundSlice {
      { firstSlice = SR.getNat(a, 0, W.ID); excess = SR.getNat(a, 6, W.MONEY); written = SR.getNat(a, 14, W.BLOCK) }
    };
    indexes = [];
  };

  /// A company with an account at the hotel: its code (what its bookers give to see its rates), its
  /// name, and whether its rates are on sale. Its negotiated rates are rate plans closed to it.
  public type Company = { code : Text; name : TA.Ref; active : Bool; lastBlock : Nat };

  public let company : RowStore.Decl<Company> = {
    table = "company";
    idBytes = W.ID;
    rowBytes = W.COMPANY_ROW;
    encode = func(x : Company) : Blob {
      let b = SR.buf();
      SR.putText(b, x.code, W.CODE); TA.putRef(b, x.name); SR.putBool(b, x.active); SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.COMPANY_ROW)
    };
    decode = func(a : [Nat8]) : Company {
      { code = SR.getText(a, 0, W.CODE); name = TA.getRef(a, 16); active = SR.getBool(a, 24); lastBlock = SR.getNat(a, 25, W.BLOCK) }
    };
    indexes = [
      { name = "by_code"; keyBytes = W.CODE; keyOf = func(_ : Nat, x : Company) : ?Blob { ?codeKey(x.code) } },
    ];
  };

  /// Who a rate plan is sold to, under the plan's id. No row, or `closed` false: on public sale. Closed
  /// with a company: only to that company's bookings. Closed with no company: only under a promotion
  /// code that names the plan.
  public type PlanAccess = { companyId : Nat; closed : Bool; lastBlock : Nat };

  public let planAccess : RowStore.Decl<PlanAccess> = {
    table = "planAccess";
    idBytes = W.ID;
    rowBytes = W.PLAN_ACCESS_ROW;
    encode = func(x : PlanAccess) : Blob {
      let b = SR.buf();
      SR.putNat(b, x.companyId, W.ID); SR.putBool(b, x.closed); SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.PLAN_ACCESS_ROW)
    };
    decode = func(a : [Nat8]) : PlanAccess { { companyId = SR.getNat(a, 0, W.ID); closed = SR.getBool(a, 6); lastBlock = SR.getNat(a, 7, W.BLOCK) } };
    indexes = [];
  };

  /// The access a hold or a booking was sold its rate under (no row: the public sale): the company
  /// whose code was given, or the promotion whose code was given. A booking under a promotion carries
  /// the number of its use (1 for the first booking the promotion made, and so on), so that the uses a
  /// promotion counts are proved one row at a time: each use is found under its own number, and each but
  /// the first has the one before it. A hold carries no use (0): a use is counted when it is confirmed.
  /// The same layout serves both tables.
  public type RateGrant = { companyId : Nat; promoId : Nat; use : Nat; lastBlock : Nat };

  func encodeGrant(x : RateGrant) : Blob {
    let b = SR.buf();
    SR.putNat(b, x.companyId, W.ID); SR.putNat(b, x.promoId, W.ID); SR.putNat(b, x.use, W.USES); SR.putNat(b, x.lastBlock, W.BLOCK);
    SR.done(b, W.RATE_GRANT_ROW)
  };
  func decodeGrant(a : [Nat8]) : RateGrant {
    { companyId = SR.getNat(a, 0, W.ID); promoId = SR.getNat(a, 6, W.ID); use = SR.getNat(a, 12, W.USES); lastBlock = SR.getNat(a, 16, W.BLOCK) }
  };
  /// The key of a promotion's use: the promotion, then the number of the use.
  public func useKey(promoId : Nat, use : Nat) : Blob { SR.key2(promoId, W.ID, use, W.USES) };
  public let holdRate : RowStore.Decl<RateGrant> = { table = "holdRate"; idBytes = W.ID; rowBytes = W.RATE_GRANT_ROW; encode = encodeGrant; decode = decodeGrant; indexes = [] };
  public let bookingRate : RowStore.Decl<RateGrant> = {
    table = "bookingRate"; idBytes = W.ID; rowBytes = W.RATE_GRANT_ROW; encode = encodeGrant; decode = decodeGrant;
    indexes = [
      { name = "by_use"; keyBytes = W.USE_KEY; keyOf = func(_ : Nat, x : RateGrant) : ?Blob { if (x.promoId == 0) null else ?useKey(x.promoId, x.use) } },
    ];
  };

  /// A promotion: a code that opens one rate plan closed to everyone but its codes, while the day it is
  /// booked is in its booking window and every night of the stay in its stay window, until its uses are
  /// spent (`maxUses` 0: no limit). Its name is what the guest is shown. A use is counted when a booking
  /// is confirmed under it and is not given back when the booking is cancelled.
  public type Promo = { code : Text; name : TA.Ref; planId : Nat; bookFrom : Nat; bookUntil : Nat; stayFrom : Nat; stayUntil : Nat;
    maxUses : Nat; used : Nat; active : Bool; lastBlock : Nat };

  public let promo : RowStore.Decl<Promo> = {
    table = "promo";
    idBytes = W.ID;
    rowBytes = W.PROMO_ROW;
    encode = func(x : Promo) : Blob {
      let b = SR.buf();
      SR.putText(b, x.code, W.CODE); TA.putRef(b, x.name); SR.putNat(b, x.planId, W.ID);
      SR.putNat(b, x.bookFrom, W.DAY); SR.putNat(b, x.bookUntil, W.DAY); SR.putNat(b, x.stayFrom, W.DAY); SR.putNat(b, x.stayUntil, W.DAY);
      SR.putNat(b, x.maxUses, W.USES); SR.putNat(b, x.used, W.USES); SR.putBool(b, x.active); SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.PROMO_ROW)
    };
    decode = func(a : [Nat8]) : Promo {
      { code = SR.getText(a, 0, W.CODE); name = TA.getRef(a, 16); planId = SR.getNat(a, 24, W.ID);
        bookFrom = SR.getNat(a, 30, W.DAY); bookUntil = SR.getNat(a, 33, W.DAY); stayFrom = SR.getNat(a, 36, W.DAY); stayUntil = SR.getNat(a, 39, W.DAY);
        maxUses = SR.getNat(a, 42, W.USES); used = SR.getNat(a, 46, W.USES); active = SR.getBool(a, 50); lastBlock = SR.getNat(a, 51, W.BLOCK) }
    };
    indexes = [
      { name = "by_code"; keyBytes = W.CODE; keyOf = func(_ : Nat, x : Promo) : ?Blob { ?codeKey(x.code) } },
    ];
  };

  /// A group block, under its id: `rooms` rooms of one room type taken out of sale for every night from
  /// `arrival` to the night before `departure`, sold at one plan under the group's company (0: none).
  /// The desk picks the rooms up as bookings from the group's rooming list until the `cutoff` day; at
  /// that day's night audit (or when revenue releases it) whatever is not picked up goes back on sale
  /// and the block is no longer `open`. A released block keeps its row and its rooming list.
  public type Block = { name : TA.Ref; companyId : Nat; roomTypeId : Nat; planId : Nat; arrival : Nat; departure : Nat; rooms : Nat; cutoff : Nat;
    open : Bool; lastBlock : Nat };

  public let block : RowStore.Decl<Block> = {
    table = "block";
    idBytes = W.ID;
    rowBytes = W.BLOCK_ROW;
    encode = func(x : Block) : Blob {
      let b = SR.buf();
      TA.putRef(b, x.name); SR.putNat(b, x.companyId, W.ID); SR.putNat(b, x.roomTypeId, W.ID); SR.putNat(b, x.planId, W.ID);
      SR.putNat(b, x.arrival, W.DAY); SR.putNat(b, x.departure, W.DAY); SR.putNat(b, x.rooms, W.COUNT); SR.putNat(b, x.cutoff, W.DAY);
      SR.putBool(b, x.open); SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.BLOCK_ROW)
    };
    decode = func(a : [Nat8]) : Block {
      { name = TA.getRef(a, 0); companyId = SR.getNat(a, 8, W.ID); roomTypeId = SR.getNat(a, 14, W.ID); planId = SR.getNat(a, 20, W.ID);
        arrival = SR.getNat(a, 26, W.DAY); departure = SR.getNat(a, 29, W.DAY); rooms = SR.getNat(a, 32, W.COUNT); cutoff = SR.getNat(a, 34, W.DAY);
        open = SR.getBool(a, 37); lastBlock = SR.getNat(a, 38, W.BLOCK) }
    };
    indexes = [
      // the open blocks in cut-off order: what the night audit releases; a released block leaves it
      { name = "open_by_cutoff"; keyBytes = W.CUTOFF_KEY; keyOf = func(id : Nat, x : Block) : ?Blob { if (x.open) ?SR.key2(x.cutoff, W.DAY, id, W.ID) else null } },
    ];
  };

  /// A block's night, under `blockNightId(block, day)`: the hotel's night it is on, the rooms picked up
  /// for it, and the rooms the block still holds that night (its rooms less those picked up while it is
  /// open; none once released).
  public type BlockNight = { night : Nat; picked : Nat; open : Nat; lastBlock : Nat };

  public func blockNightId(blockId : Nat, day : Nat) : Nat { blockId * 16_777_216 + day };
  public func blockNightBlock(id : Nat) : Nat { id / 16_777_216 };

  public let blockNight : RowStore.Decl<BlockNight> = {
    table = "blockNight";
    idBytes = W.ID;
    rowBytes = W.BLOCK_NIGHT_ROW;
    encode = func(x : BlockNight) : Blob {
      let b = SR.buf();
      SR.putNat(b, x.night, W.NIGHT_ID); SR.putNat(b, x.picked, W.COUNT); SR.putNat(b, x.open, W.COUNT); SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.BLOCK_NIGHT_ROW)
    };
    decode = func(a : [Nat8]) : BlockNight {
      { night = SR.getNat(a, 0, W.NIGHT_ID); picked = SR.getNat(a, 5, W.COUNT); open = SR.getNat(a, 7, W.COUNT); lastBlock = SR.getNat(a, 9, W.BLOCK) }
    };
    indexes = [
      // every block's share of one hotel night: what that night's `nightBlock` sums
      { name = "by_night"; keyBytes = W.NIGHT_BLOCK_KEY; keyOf = func(id : Nat, x : BlockNight) : ?Blob { ?SR.key2(x.night, W.NIGHT_ID, blockNightBlock(id), W.ID) } },
    ];
  };

  /// A hotel night's rooms held by open blocks, under the night's id: taken out of what is free.
  public type NightBlock = { open : Nat; lastBlock : Nat };

  public let nightBlock : RowStore.Decl<NightBlock> = {
    table = "nightBlock";
    idBytes = NIGHT_ID_BYTES;
    rowBytes = W.NIGHT_BLOCK_ROW;
    encode = func(x : NightBlock) : Blob {
      let b = SR.buf();
      SR.putNat(b, x.open, W.COUNT); SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.NIGHT_BLOCK_ROW)
    };
    decode = func(a : [Nat8]) : NightBlock { { open = SR.getNat(a, 0, W.COUNT); lastBlock = SR.getNat(a, 2, W.BLOCK) } };
    indexes = [];
  };

  /// A booking picked up from a block, under the booking's id: the block, so the rooming list is the
  /// block's bookings and a cancellation gives its rooms back to the block while it is open.
  public type BookingBlock = { blockId : Nat; lastBlock : Nat };

  public let bookingBlock : RowStore.Decl<BookingBlock> = {
    table = "bookingBlock";
    idBytes = W.ID;
    rowBytes = W.BOOKING_BLOCK_ROW;
    encode = func(x : BookingBlock) : Blob {
      let b = SR.buf();
      SR.putNat(b, x.blockId, W.ID); SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.BOOKING_BLOCK_ROW)
    };
    decode = func(a : [Nat8]) : BookingBlock { { blockId = SR.getNat(a, 0, W.ID); lastBlock = SR.getNat(a, 6, W.BLOCK) } };
    indexes = [
      { name = "by_block"; keyBytes = W.BLOCK_BOOKING_KEY; keyOf = func(id : Nat, x : BookingBlock) : ?Blob { ?SR.key2(x.blockId, W.ID, id, W.ID) } },
    ];
  };

  /// The blocks at their cut-off when a business day's audit opened, under the day: the count the
  /// audit's release job is planned from.
  public type AuditBlocks = { due : Nat; lastBlock : Nat };

  public let auditBlocks : RowStore.Decl<AuditBlocks> = {
    table = "auditBlocks";
    idBytes = W.ID;
    rowBytes = W.AUDIT_BLOCKS_ROW;
    encode = func(x : AuditBlocks) : Blob {
      let b = SR.buf();
      SR.putNat(b, x.due, W.TALLY); SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.AUDIT_BLOCKS_ROW)
    };
    decode = func(a : [Nat8]) : AuditBlocks { { due = SR.getNat(a, 0, W.TALLY); lastBlock = SR.getNat(a, 4, W.BLOCK) } };
    indexes = [];
  };

  /// A package's inclusion, under `inclusionId(planId, slot)` (slots 1 to 8): an extra sold with every
  /// stay on the plan, added to its rate at the extra's catalogue price, `quantity` of it per room, per
  /// adult or per guest, every night or on the arrival night only. A slot taken off the plan is kept,
  /// not `on`, because a row is never removed.
  public type PlanInclusion = { planId : Nat; extraId : Nat; quantity : Nat; rhythm : E.Rhythm; per : E.Per; on : Bool; lastBlock : Nat };

  public let MAX_INCLUSIONS : Nat = 8;
  public func inclusionId(planId : Nat, slot : Nat) : Nat { planId * 16 + slot };

  public let planInclusion : RowStore.Decl<PlanInclusion> = {
    table = "planInclusion";
    idBytes = W.ID;
    rowBytes = W.PLAN_INCLUSION_ROW;
    encode = func(x : PlanInclusion) : Blob {
      let b = SR.buf();
      SR.putNat(b, x.planId, W.ID); SR.putNat(b, x.extraId, W.ID); SR.putNat(b, x.quantity, W.COUNT);
      SR.putByte(b, E.rhythmByte(x.rhythm)); SR.putByte(b, E.perByte(x.per)); SR.putBool(b, x.on); SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.PLAN_INCLUSION_ROW)
    };
    decode = func(a : [Nat8]) : PlanInclusion {
      { planId = SR.getNat(a, 0, W.ID); extraId = SR.getNat(a, 6, W.ID); quantity = SR.getNat(a, 12, W.COUNT);
        rhythm = enumOf(E.rhythmOf(a[14]), "planInclusion", "rhythm"); per = enumOf(E.perOf(a[15]), "planInclusion", "per");
        on = SR.getBool(a, 16); lastBlock = SR.getNat(a, 17, W.BLOCK) }
    };
    indexes = [];
  };

  /// A package's line, under the id of the line it describes (a booking's folio line in `packageLine`, a
  /// hold's line in `holdPackage`): the inclusion's slot, the extra, how many of it (the inclusion's
  /// quantity times the rooms, adults or guests), its price frozen by the quote, when it is given,
  /// whether it was taxed, and how many tax lines follow it.
  public type PackageLine = { slot : Nat; extraId : Nat; quantity : Nat; unitAmount : Nat; rhythm : E.Rhythm; taxed : Bool; taxLines : Nat; lastBlock : Nat };

  func encodePackage(x : PackageLine) : Blob {
    let b = SR.buf();
    SR.putNat(b, x.slot, W.SMALL); SR.putNat(b, x.extraId, W.ID); SR.putNat(b, x.quantity, W.COUNT); SR.putNat(b, x.unitAmount, W.MONEY);
    SR.putByte(b, E.rhythmByte(x.rhythm)); SR.putBool(b, x.taxed); SR.putNat(b, x.taxLines, W.SMALL); SR.putNat(b, x.lastBlock, W.BLOCK);
    SR.done(b, W.PACKAGE_LINE_ROW)
  };
  func decodePackage(a : [Nat8]) : PackageLine {
    { slot = SR.getNat(a, 0, W.SMALL); extraId = SR.getNat(a, 1, W.ID); quantity = SR.getNat(a, 7, W.COUNT); unitAmount = SR.getNat(a, 9, W.MONEY);
      rhythm = enumOf(E.rhythmOf(a[17]), "packageLine", "rhythm"); taxed = SR.getBool(a, 18); taxLines = SR.getNat(a, 19, W.SMALL); lastBlock = SR.getNat(a, 20, W.BLOCK) }
  };

  public let packageLine : RowStore.Decl<PackageLine> = {
    table = "packageLine"; idBytes = W.ID; rowBytes = W.PACKAGE_LINE_ROW; encode = encodePackage; decode = decodePackage; indexes = [];
  };
  public let holdPackage : RowStore.Decl<PackageLine> = {
    table = "holdPackage"; idBytes = W.ID; rowBytes = W.PACKAGE_LINE_ROW; encode = encodePackage; decode = decodePackage; indexes = [];
  };

  // ── deposits and the card on file ──────────────────────────────────────────

  /// A deposit plan's share of the room's stay, in basis points (1 to 9,900), under the plan's id.
  public type PlanDeposit = { depositBps : Nat; lastBlock : Nat };

  public let planDeposit : RowStore.Decl<PlanDeposit> = {
    table = "planDeposit"; idBytes = W.ID; rowBytes = W.PLAN_DEPOSIT_ROW;
    encode = func(x : PlanDeposit) : Blob { let b = SR.buf(); SR.putNat(b, x.depositBps, W.BPS); SR.putNat(b, x.lastBlock, W.BLOCK); SR.done(b, W.PLAN_DEPOSIT_ROW) };
    decode = func(a : [Nat8]) : PlanDeposit { { depositBps = SR.getNat(a, 0, W.BPS); lastBlock = SR.getNat(a, 2, W.BLOCK) } };
    indexes = [];
  };

  /// A booking's card on file, under the booking's id. `token` is the gateway's handle for the card (0
  /// while it is wanted); `firstAuth` the guest's own payment it was kept on; `agreedBlock` the block the
  /// guest agreed in; `deadline` the business day a wanted card is due by (the booking's last free
  /// cancellation day); `chargeId` the no-show charge made on it (0: none); `attempts` the gateway's
  /// refusals to forget it; `declinedDay` the business day the gateway declined its no-show charge (0:
  /// it did not), for the desk's day list.
  public type CardOnFile = { token : Nat; firstAuth : Nat; agreedBlock : Nat; deadline : Nat; state : E.CardState; chargeId : Nat; attempts : Nat;
    declinedDay : Nat; lastBlock : Nat };

  public let cardOnFile : RowStore.Decl<CardOnFile> = {
    table = "cardOnFile"; idBytes = W.ID; rowBytes = W.CARD_ROW;
    encode = func(x : CardOnFile) : Blob {
      let b = SR.buf();
      SR.putNat(b, x.token, W.ID); SR.putNat(b, x.firstAuth, W.ID); SR.putNat(b, x.agreedBlock, W.BLOCK); SR.putNat(b, x.deadline, W.DAY);
      SR.putByte(b, E.cardStateByte(x.state)); SR.putNat(b, x.chargeId, W.ID); SR.putNat(b, x.attempts, W.SMALL); SR.putNat(b, x.declinedDay, W.DAY);
      SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.CARD_ROW)
    };
    decode = func(a : [Nat8]) : CardOnFile {
      { token = SR.getNat(a, 0, W.ID); firstAuth = SR.getNat(a, 6, W.ID); agreedBlock = SR.getNat(a, 12, W.BLOCK); deadline = SR.getNat(a, 18, W.DAY);
        state = enumOf(E.cardStateOf(a[21]), "cardOnFile", "state"); chargeId = SR.getNat(a, 22, W.ID); attempts = SR.getNat(a, 28, W.SMALL);
        declinedDay = SR.getNat(a, 29, W.DAY); lastBlock = SR.getNat(a, 32, W.BLOCK) }
    };
    indexes = [
      // the cards the desk is waiting for, by the day each is due: a row leaves the set once the card is
      // kept or no longer needed
      { name = "wanted"; keyBytes = W.CARD_WANTED_KEY; keyOf = func(id : Nat, x : CardOnFile) : ?Blob { if (x.state == #wanted) ?SR.key2(x.deadline, W.DAY, id, W.ID) else null } },
      // the tokens to delete at the gateway: a row leaves the set by being forgotten (or refused three times)
      { name = "forget_due"; keyBytes = W.ID; keyOf = func(id : Nat, x : CardOnFile) : ?Blob { if (x.state == #forgetDue) ?SR.key(id, W.ID) else null } },
      // the no-show charges the gateway declined, by the day it did, for the desk's day list
      { name = "declined"; keyBytes = W.CARD_WANTED_KEY; keyOf = func(id : Nat, x : CardOnFile) : ?Blob { if (x.declinedDay > 0) ?SR.key2(x.declinedDay, W.DAY, id, W.ID) else null } },
      // the tokens the gateway would not delete, shown to the desk until the gateway does
      { name = "forget_failed"; keyBytes = W.ID; keyOf = func(id : Nat, x : CardOnFile) : ?Blob { if (x.state == #forgetFailed) ?SR.key(id, W.ID) else null } },
    ];
  };

  /// The hotel's card rule (row 1): from `fromBlock` on, every plan guaranteed by the first night or a
  /// deposit keeps the guest's card on file. A block in the log says so, so a replay folds every earlier
  /// confirmation under the rules it was made under.
  public type CardPolicy = { fromBlock : Nat; lastBlock : Nat };

  public let cardPolicy : RowStore.Decl<CardPolicy> = {
    table = "cardPolicy"; idBytes = W.ID; rowBytes = W.CARD_POLICY_ROW;
    encode = func(x : CardPolicy) : Blob { let b = SR.buf(); SR.putNat(b, x.fromBlock, W.BLOCK); SR.putNat(b, x.lastBlock, W.BLOCK); SR.done(b, W.CARD_POLICY_ROW) };
    decode = func(a : [Nat8]) : CardPolicy { { fromBlock = SR.getNat(a, 0, W.BLOCK); lastBlock = SR.getNat(a, 6, W.BLOCK) } };
    indexes = [];
  };

  // ── guest emails: the outbox, each booking's sealed address, the relay's setup ─────

  /// A message the hotel owes a guest, under its own id. `notBefore` is the first business day it may go
  /// (0: at once); `attempts` counts the relay's sends, failed or not; `failure` is why the last one
  /// failed, as a code. Nothing in it is private: which message, for which booking, and what became of it.
  public type Outbox = { bookingId : Nat; kind : E.MailKind; notBefore : Nat; state : E.MailState; attempts : Nat; failure : E.MailFailure;
    queuedBlock : Nat; lastBlock : Nat };

  public let outbox : RowStore.Decl<Outbox> = {
    table = "outbox"; idBytes = W.ID; rowBytes = W.OUTBOX_ROW;
    encode = func(x : Outbox) : Blob {
      let b = SR.buf();
      SR.putNat(b, x.bookingId, W.ID); SR.putByte(b, E.mailKindByte(x.kind)); SR.putNat(b, x.notBefore, W.DAY); SR.putByte(b, E.mailStateByte(x.state));
      SR.putNat(b, x.attempts, W.SMALL); SR.putByte(b, E.mailFailureByte(x.failure)); SR.putNat(b, x.queuedBlock, W.BLOCK); SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.OUTBOX_ROW)
    };
    decode = func(a : [Nat8]) : Outbox {
      { bookingId = SR.getNat(a, 0, W.ID); kind = enumOf(E.mailKindOf(a[6]), "outbox", "kind"); notBefore = SR.getNat(a, 7, W.DAY);
        state = enumOf(E.mailStateOf(a[10]), "outbox", "state"); attempts = SR.getNat(a, 11, W.SMALL); failure = enumOf(E.mailFailureOf(a[12]), "outbox", "failure");
        queuedBlock = SR.getNat(a, 13, W.BLOCK); lastBlock = SR.getNat(a, 19, W.BLOCK) }
    };
    indexes = [
      // the messages the relay may send, by the first day each may go: a row leaves the set by being sent,
      // failing for the third time, or being skipped
      { name = "due"; keyBytes = W.OUTBOX_DUE_KEY; keyOf = func(id : Nat, x : Outbox) : ?Blob { if (x.state == #due) ?SR.key2(x.notBefore, W.DAY, id, W.ID) else null } },
    ];
  };

  /// A booking's address for its messages, under the booking's id: sealed in the guest's (or the desk's)
  /// browser to the relay's mail key, so only the relay can read it; the language its messages are in;
  /// and the outbox ids of its four messages, each queued at most once (0: not queued).
  public type MailAddress = { sealed : TA.Ref; lang : E.Lang; attachedBlock : Nat; confirmation : Nat; preArrival : Nat; receipt : Nat; cancellation : Nat;
    lastBlock : Nat };

  public let mailAddress : RowStore.Decl<MailAddress> = {
    table = "mailAddress"; idBytes = W.ID; rowBytes = W.MAIL_ADDRESS_ROW;
    encode = func(x : MailAddress) : Blob {
      let b = SR.buf();
      TA.putRef(b, x.sealed); SR.putByte(b, E.langByte(x.lang)); SR.putNat(b, x.attachedBlock, W.BLOCK);
      SR.putNat(b, x.confirmation, W.ID); SR.putNat(b, x.preArrival, W.ID); SR.putNat(b, x.receipt, W.ID); SR.putNat(b, x.cancellation, W.ID);
      SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.MAIL_ADDRESS_ROW)
    };
    decode = func(a : [Nat8]) : MailAddress {
      { sealed = TA.getRef(a, 0); lang = enumOf(E.langOf(a[8]), "mailAddress", "lang"); attachedBlock = SR.getNat(a, 9, W.BLOCK);
        confirmation = SR.getNat(a, 15, W.ID); preArrival = SR.getNat(a, 21, W.ID); receipt = SR.getNat(a, 27, W.ID); cancellation = SR.getNat(a, 33, W.ID);
        lastBlock = SR.getNat(a, 39, W.BLOCK) }
    };
    indexes = [];
  };

  /// The hotel's guest email (row 1): the relay's mail key (the public half; guests' browsers seal to it),
  /// the grant that made the relay's key the mailer, the digest of the sealed credential the owner
  /// authorised, the digest the relay sent its test email with, and whether the owner turned it on. All
  /// zero bytes where not yet given. The credential itself is never here: it is sealed to the relay.
  public type MailSetup = { mailKey : Blob; mailerGrant : Nat; authorised : Blob; tested : Blob; on : Bool; lastBlock : Nat };

  public let mailSetup : RowStore.Decl<MailSetup> = {
    table = "mailSetup"; idBytes = W.ID; rowBytes = W.MAIL_SETUP_ROW;
    encode = func(x : MailSetup) : Blob {
      let b = SR.buf();
      SR.putBlob(b, blobField(x.mailKey, W.MAIL_KEY), W.MAIL_KEY); SR.putNat(b, x.mailerGrant, W.ID);
      SR.putBlob(b, blobField(x.authorised, W.HASH), W.HASH); SR.putBlob(b, blobField(x.tested, W.HASH), W.HASH);
      SR.putBool(b, x.on); SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.MAIL_SETUP_ROW)
    };
    decode = func(a : [Nat8]) : MailSetup {
      { mailKey = SR.getBlob(a, 0, W.MAIL_KEY); mailerGrant = SR.getNat(a, 65, W.ID); authorised = SR.getBlob(a, 71, W.HASH); tested = SR.getBlob(a, 103, W.HASH);
        on = SR.getBool(a, 135); lastBlock = SR.getNat(a, 136, W.BLOCK) }
    };
    indexes = [];
  };

  /// A tax rule's codes in the tax authority's tables, under the rule's id.
  public type TaxEta = { taxType : Text; subType : Text; lastBlock : Nat };

  public let taxEta : RowStore.Decl<TaxEta> = {
    table = "taxEta";
    idBytes = W.ID;
    rowBytes = W.TAX_ETA_ROW;
    encode = func(x : TaxEta) : Blob {
      let b = SR.buf();
      SR.putText(b, x.taxType, W.ETA_CODE); SR.putText(b, x.subType, W.ETA_CODE); SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.TAX_ETA_ROW)
    };
    decode = func(a : [Nat8]) : TaxEta { { taxType = SR.getText(a, 0, W.ETA_CODE); subType = SR.getText(a, 8, W.ETA_CODE); lastBlock = SR.getNat(a, 16, W.BLOCK) } };
    indexes = [];
  };

  /// The hotel as the tax authority registered it: what an issued document names as its issuer.
  public type EtaProfile = { issuerId : TA.Ref; activityCode : Text; branchId : TA.Ref; country : Text; governate : TA.Ref; regionCity : TA.Ref;
    street : TA.Ref; buildingNumber : TA.Ref; lastBlock : Nat };

  public let etaProfile : RowStore.Decl<EtaProfile> = {
    table = "etaProfile";
    idBytes = W.ID;
    rowBytes = W.ETA_PROFILE_ROW;
    encode = func(x : EtaProfile) : Blob {
      let b = SR.buf();
      TA.putRef(b, x.issuerId); SR.putText(b, x.activityCode, W.ETA_CODE); TA.putRef(b, x.branchId); SR.putText(b, x.country, W.COUNTRY);
      TA.putRef(b, x.governate); TA.putRef(b, x.regionCity); TA.putRef(b, x.street); TA.putRef(b, x.buildingNumber);
      SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.ETA_PROFILE_ROW)
    };
    decode = func(a : [Nat8]) : EtaProfile {
      { issuerId = TA.getRef(a, 0); activityCode = SR.getText(a, 8, W.ETA_CODE); branchId = TA.getRef(a, 16); country = SR.getText(a, 24, W.COUNTRY);
        governate = TA.getRef(a, 26); regionCity = TA.getRef(a, 34); street = TA.getRef(a, 42); buildingNumber = TA.getRef(a, 50); lastBlock = SR.getNat(a, 58, W.BLOCK) }
    };
    indexes = [];
  };

  /// The rules the log was folded under (row 1, written first by `#adoptRules`): the epoch adopted, and
  /// the span of the audit's walk as the walk opened, so a walk under way keeps its end across an
  /// adoption. No row is epoch 0 with a walk of `Rules.SECTIONS_AT[0]` sections.
  public type Rules = { epoch : Nat; walkSections : Nat; lastBlock : Nat };

  public let rules : RowStore.Decl<Rules> = {
    table = "rules"; idBytes = W.ID; rowBytes = W.RULES_ROW;
    encode = func(x : Rules) : Blob {
      let b = SR.buf();
      SR.putNat(b, x.epoch, W.SMALL); SR.putNat(b, x.walkSections, W.SMALL); SR.putNat(b, x.lastBlock, W.BLOCK);
      SR.done(b, W.RULES_ROW)
    };
    decode = func(a : [Nat8]) : Rules { { epoch = SR.getNat(a, 0, W.SMALL); walkSections = SR.getNat(a, 1, W.SMALL); lastBlock = SR.getNat(a, 2, W.BLOCK) } };
    indexes = [];
  };

}
