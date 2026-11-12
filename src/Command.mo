/// Command.mo - every act this hotel accepts, as one flat variant.
///
/// A family's tag is `LUXOR_BASE + its position in FAMILIES`, and the list is append-only: a new
/// family may join the end, an existing family's position never moves. The base is a fixed number far
/// past any enterprise family list (Hippocrates' `CLINICAL_BASE` rule), so when the enterprise system
/// joins this log as `#ent` no Luxor command's bytes move and no approval hash stops verifying.
///
/// WHO ACTED IS IN THE COMMAND. The edge authenticates a person - a browser key for a hold, a
/// passkey-derived principal for an account or a member of staff, a signature for a manage key - and
/// the command records the principal it established. The fold decides what that person may do; a
/// replay trusts the recorded principal exactly as a block records its caller.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import E "Enums";

module {

  public type PropertyFacts = {
    currency : Text;
    minorUnits : Nat;
    nameEn : Text;
    nameAr : Text;
    checkInText : Text;
    checkOutText : Text;
    holdTtlHeights : Nat;
    heightsPerRealMinute : Nat;
    maxStayNights : Nat;
    horizonDays : Nat;
    maxRoomsPerBooking : Nat;
    idRetentionDays : Nat;
  };

  public type RoomTypeFacts = {
    code : Text;
    nameEn : Text;
    nameAr : Text;
    descEn : Text;
    descAr : Text;
    sizeSqm : Nat;
    maxAdults : Nat;
    maxChildren : Nat;
    maxOccupancy : Nat;
    bedKind : E.BedKind;
    bedCount : Nat;
    amenities : Nat;
    photos : Text;
    rank : Nat;
    active : Bool;
  };

  public type RatePlanFacts = {
    code : Text;
    nameEn : Text;
    nameAr : Text;
    kind : E.PlanKind;
    discountBps : Nat;
    refundable : Bool;
    freeCancelDaysBefore : Nat;
    penaltyNights : Nat;
    guarantee : E.Guarantee;
    modifiable : Bool;
    active : Bool;
  };

  public type TaxRuleFacts = {
    code : Text;
    nameEn : Text;
    nameAr : Text;
    kind : E.TaxKind;
    bps : Nat;
    amount : Nat;
    base : E.TaxBase;
    rank : Nat;
    active : Bool;
  };

  /// A range edit on the grid: nights `from ≤ day < to` of one room type whose weekday is in the
  /// mask (bit 0 = Monday … bit 6 = Sunday). An absent field is left as it is.
  public type NightsEdit = {
    roomTypeId : Nat;
    fromDay : Nat;
    toDay : Nat;
    weekdays : Nat;
    allotment : ?Nat;
    bar : ?Nat;
    minStay : ?Nat;
    maxStay : ?Nat;
    closedToArrival : ?Bool;
    closedToDeparture : ?Bool;
    stopSell : ?Bool;
  };

  /// An item of the extras catalogue. `price` 0: the amount is entered when it is posted.
  public type ExtraFacts = { code : Text; nameEn : Text; nameAr : Text; category : E.ExtraCategory; price : Nat; taxed : Bool; active : Bool };

  /// A change to the nightly rate by a percentage of the rate each night already has, in basis points.
  public type RateAdjust = { up : Bool; bps : Nat };

  /// One change in a save of several: a grid edit, and in place of a rate, optionally a percentage.
  public type ManyEdit = { edit : NightsEdit; adjust : ?RateAdjust };

  public type Stay = {
    roomTypeId : Nat;
    planId : Nat;
    arrival : Nat;
    nights : Nat;
    rooms : Nat;
    adults : Nat;
    children : Nat;
  };

  /// What the test gateway says it authorised, read by the edge from the gateway contract itself.
  public type AuthFacts = { authId : Nat; amount : Nat; currency : Text; merchantRef : Nat };

  /// Who may act on a booking after it is made: its account holder, or whoever holds its manage key.
  public type GuestActor = { #account : Principal; #manageKey };

  /// The acts that need a second member of staff: each moves money or a person's record.
  public type DualAct = {
    #staffCancel : { bookingId : Nat; waivePenalty : Bool };
    #waivePenalty : { bookingId : Nat };
    #refundOutsidePolicy : { bookingId : Nat; amount : Nat };
    #compNights : { bookingId : Nat };
    #priceOverride : { bookingId : Nat; newTotal : Nat };
    #editGuestRecord : { bookingId : Nat; guestName : Text };
    /// A posted extra (its folio line) voided, with its taxes, by a credit of the same amount.
    #voidCharge : { bookingId : Nat; lineId : Nat };
    /// A credit note against an issued invoice: for each line named, the amount taken back before
    /// tax (`lineIds[i]` and `amounts[i]`); its taxes are taken back in proportion (CreditNote.mo).
    #issueCreditNote : { bookingId : Nat; invoice : Nat; lineIds : [Nat]; amounts : [Nat] };
    /// A refund the gateway would not make, paid at the desk instead: cash or a transfer, with its reference.
    #refundAtDesk : { bookingId : Nat; paymentId : Nat; method : E.DeskMethod; reference : Text };
  };

  /// The hotel as the tax authority registered it (CreditNote.setEtaProfile).
  public type EtaProfileFacts = { issuerId : Text; activityCode : Text; branchId : Text; country : Text; governate : Text; regionCity : Text;
    street : Text; buildingNumber : Text };

  public type Command = {
    #configureProperty : { staff : Principal; facts : PropertyFacts };
    #upsertRoomType : { staff : Principal; id : Nat; facts : RoomTypeFacts };
    #upsertRoom : { staff : Principal; id : Nat; roomTypeId : Nat; number : Text; outOfOrder : Bool };
    #upsertRatePlan : { staff : Principal; id : Nat; facts : RatePlanFacts };
    #upsertTaxRule : { staff : Principal; id : Nat; facts : TaxRuleFacts };
    #setNights : { staff : Principal; edit : NightsEdit };
    #releaseExpiredHolds : { limit : Nat };
    #placeHold : { owner : Principal; stay : Stay; quoteHash : Blob; key : Blob };
    #releaseHold : { owner : Principal; holdId : Nat };
    #confirmHold : { owner : Principal; holdId : Nat; guestName : Text; guestEmail : Text; note : Text;
                     manageKey : Blob; account : ?Principal; auth : AuthFacts };
    #modifyBooking : { by : GuestActor; bookingId : Nat; stay : Stay; quoteHash : Blob; auth : ?AuthFacts };
    #cancelBooking : { by : GuestActor; bookingId : Nat };
    #claimBooking : { account : Principal; bookingId : Nat };
    #joinWaitlist : { account : Principal; stay : Stay };
    #leaveWaitlist : { account : Principal; entryId : Nat };
    #checkIn : { staff : Principal; bookingId : Nat; roomIds : [Nat] };
    #checkOut : { staff : Principal; bookingId : Nat };
    #recordGatewayOutcome : { paymentId : Nat; ok : Bool };
    #openAudit : { staff : Principal; day : Nat };
    #advanceAudit : { staff : Principal; day : Nat; limit : Nat };
    #closeDay : { staff : Principal; day : Nat };
    #bootstrapOwner : { subject : Principal };
    #grantRole : { staff : Principal; subject : Principal; role : E.Role };
    #revokeRole : { staff : Principal; subject : Principal; role : E.Role };
    #propose : { staff : Principal; act : DualAct; justification : Text };
    #approve : { staff : Principal; proposalId : Nat };
    #reject : { staff : Principal; proposalId : Nat; reason : Text };
    #settleAtDesk : { staff : Principal; bookingId : Nat; auth : AuthFacts };
    /// The hotel's guest-data public key (P-256, raw): guests' contact details are sealed to it.
    #setGuestDataKey : { staff : Principal; key : Blob };
    /// An identity document at check-in: begin the upload, send its encrypted parts, file it.
    #beginIdUpload : { staff : Principal; bookingId : Nat; size : Nat; chunkHashes : [Text] };
    #putIdChunk : { staff : Principal; blobId : Text; index : Nat; bytes : Blob };
    #fileIdDocument : { staff : Principal; bookingId : Nat; blobId : Text; plainHash : Text; plainSize : Nat; mime : Text; fileKey : Text };
    /// Several grid edits saved together, all or nothing: room types side by side, a percentage on the
    /// rate, the undo of an earlier save. No two edits may touch the same night.
    #setNightsMany : { staff : Principal; edits : [ManyEdit] };
    /// The hotel's clock: the time zone (a display name and its POSIX TZ rule), the local time of day the
    /// night audit runs at, in seconds after midnight, and whether the contract runs it by itself.
    /// `runner` is the contract's own principal, filled in by the contract, never by the caller.
    #setHotelClock : { staff : Principal; zoneName : Text; zoneRule : Text; auditAt : Nat; auto : Bool; runner : Principal };
    /// Housekeeping marks a room in service dirty, clean, or inspected (by someone other than its cleaner).
    #markRoom : { staff : Principal; roomId : Nat; cleaning : E.Cleaning };
    /// A vacant room out of order from today until `untilDay`, the first night it is back in the count,
    /// with the reason; sent again for a room already out, it changes the reason and the date.
    #takeRoomOutOfOrder : { staff : Principal; roomId : Nat; reason : Text; untilDay : Nat };
    /// A room out of order back in service, dirty until it is cleaned.
    #returnRoomToService : { staff : Principal; roomId : Nat };
    /// The extras catalogue: an item added (id 0) or changed.
    #upsertExtra : { staff : Principal; id : Nat; facts : ExtraFacts };
    /// An extra posted to a guest in house: a quantity of a catalogue item, the amount when the item
    /// has none of its own, on the bill of the guest (payer 0) or of a payer of the booking.
    #postCharge : { staff : Principal; bookingId : Nat; extraId : Nat; quantity : Nat; amount : Nat; payerId : Nat };
    /// Someone besides the guest who pays part of the bill: a window of its own.
    #addPayer : { staff : Principal; bookingId : Nat; name : Text };
    /// Lines moved to a window (payer 0 is the guest's).
    #routeLines : { staff : Principal; bookingId : Nat; lineIds : [Nat]; payerId : Nat };
    /// A payer's share paid at the desk on the TEST gateway.
    #settleShare : { staff : Principal; bookingId : Nat; payerId : Nat; auth : AuthFacts };
    /// The invoice for a window, under the next number; it closes the window.
    #issueInvoice : { staff : Principal; bookingId : Nat; payerId : Nat };
    #setTaxEta : { staff : Principal; taxRuleId : Nat; taxType : Text; subType : Text };
    #setEtaProfile : { staff : Principal; facts : EtaProfileFacts };
    /// A booking staff take for a guest on the phone or at the desk: no hold and no card; it is paid at
    /// the desk or later. A walk-in arrives today and is checked in to `roomIds` in the same act; a
    /// booking by phone names no rooms (they are given at check-in). The manage key and the sealed email
    /// are made in the member of staff's browser, as a guest's are in theirs; the email may be empty.
    #bookByStaff : { staff : Principal; channel : E.Channel; stay : Stay; quoteHash : Blob; guestName : Text; guestEmail : Text;
                     note : Text; manageKey : Blob; roomIds : [Nat] };
    /// A guest in house moves from one of their rooms to a free room of the same type. The room left is
    /// dirty until housekeeping cleans it, as a room left at check-out is.
    #moveRoom : { staff : Principal; bookingId : Nat; fromRoomId : Nat; toRoomId : Nat };
    /// A company with an account at the hotel, added (id 0) or changed: its code, which its bookers
    /// give to see its rates, its name, and whether its rates are on sale.
    #upsertCompany : { staff : Principal; id : Nat; code : Text; name : Text; active : Bool };
    /// Who a rate plan is sold to: everyone (`closed` false), only one company's bookings (`companyId`),
    /// or, closed with no company, only under a promotion's code that names it.
    #setPlanAccess : { staff : Principal; planId : Nat; companyId : Nat; closed : Bool };
    /// A hold placed under a company's or a promotion's code: the code opens the rates closed to it.
    #placeHoldCoded : { owner : Principal; stay : Stay; quoteHash : Blob; key : Blob; code : Text };
    /// A booking staff take under a company's or a promotion's code, otherwise as `bookByStaff`.
    #bookByStaffCoded : { staff : Principal; channel : E.Channel; stay : Stay; quoteHash : Blob; guestName : Text; guestEmail : Text;
                          note : Text; manageKey : Blob; roomIds : [Nat]; code : Text };
    /// A promotion, added (id 0) or changed: its code, the name the guest is shown, the plan it opens,
    /// the days it may be booked on and the nights it may be stayed, and how many bookings may use it
    /// (0: no limit). Windows are business days, inclusive.
    #upsertPromo : { staff : Principal; id : Nat; code : Text; name : Text; planId : Nat; bookFrom : Nat; bookUntil : Nat; stayFrom : Nat; stayUntil : Nat;
                     maxUses : Nat; active : Bool };
    /// A group block, added (id 0) or changed: the group's name, its company (0: none), the room type,
    /// plan, first night and nights, the rooms held each night, and the cut-off day.
    #upsertBlock : { staff : Principal; id : Nat; name : Text; companyId : Nat; roomTypeId : Nat; planId : Nat; arrival : Nat; nights : Nat; rooms : Nat;
                     cutoff : Nat };
    /// A group block released before its cut-off: every room it holds goes back on sale.
    #releaseBlock : { staff : Principal; id : Nat };
    /// A guest of a group's rooming list, picked up from the block as a booking, otherwise as a booking
    /// by phone.
    #pickUpFromBlock : { staff : Principal; blockId : Nat; stay : Stay; quoteHash : Blob; guestName : Text; guestEmail : Text; note : Text; manageKey : Blob };
    /// A plan's package set whole: its inclusions in slot order (an empty list: a plain rate again).
    #setPlanInclusions : { staff : Principal; planId : Nat; inclusions : [InclusionFacts] };
    /// A plan taken by a deposit: its share of the room's stay in basis points (100 to 9,900, whole per
    /// cent), captured at confirmation. 0: the plan is guaranteed by its first night again.
    #setPlanDeposit : { staff : Principal; planId : Nat; depositBps : Nat };
    /// The hotel's card rule turned on, once: from this block every plan guaranteed by the first night or
    /// a deposit keeps the guest's card on file.
    #requireCardOnFile : { staff : Principal };
    /// A hold confirmed as `#confirmHold`, the guest's card kept on file: `token` is the gateway's handle
    /// for it, which the gateway gave for this payment because the guest agreed in their browser.
    #confirmHoldOnFile : { owner : Principal; holdId : Nat; guestName : Text; guestEmail : Text; note : Text;
                           manageKey : Blob; account : ?Principal; auth : AuthFacts; token : Nat };
    /// The guest puts a card on file for a booking taken by staff, from the booking's card link: the
    /// guarantee paid by the guest (`auth`), and the card kept (`token`).
    #putCardOnFile : { by : GuestActor; bookingId : Nat; auth : AuthFacts; token : Nat };
    /// What the gateway said of a no-show charge on file: made (under the authorisation `authId` it
    /// gave) or declined.
    #recordChargeOutcome : { paymentId : Nat; ok : Bool; authId : Nat };
    /// What the gateway said when asked to delete a booking's card token.
    #recordCardForgotten : { bookingId : Nat; ok : Bool };
    /// The owner connects the mail relay: its key becomes the hotel's mailer (a previous relay's key stops
    /// being one), and guests' addresses are sealed to `mailKey` from this block. Guest email starts off.
    #setMailRelay : { staff : Principal; mailer : Principal; mailKey : Blob };
    /// The owner authorises the email account the hotel connected: the SHA-256 of the credential as the
    /// owner's browser sealed it to the relay. The relay uses only the credential with this digest.
    #authoriseMailCredential : { staff : Principal; digest : Blob };
    /// The owner turns guest email on (only after the relay's test with the authorised credential) or off.
    #setMailOn : { staff : Principal; on : Bool };
    /// A guest gives the address the booking's messages go to, sealed in their browser to the relay's mail
    /// key, and the language to write them in.
    #attachMail : { by : GuestActor; bookingId : Nat; sealed : Text; lang : E.Lang };
    /// The same, by the desk, for a booking it took or a guest who asks at the desk.
    #attachMailByStaff : { staff : Principal; bookingId : Nat; sealed : Text; lang : E.Lang };
    /// The relay says what became of one message: sent, or failed and why (a code, never the provider's
    /// words). Only the mailer's key may say it.
    #recordMailOutcome : { mailer : Principal; outboxId : Nat; sent : Bool; failure : E.MailFailure };
    /// The relay says it sent the owner's test email with the credential of this digest.
    #recordMailTest : { mailer : Principal; digest : Blob };
    /// The owner moves the hotel's rules to the next epoch (`Rules`): the first block after an upgrade
    /// that brings new rules.
    #adoptRules : { staff : Principal; epoch : Nat };
  };

  /// One inclusion of a package: the extra, how many of it, every night or the arrival night only, and
  /// per room, adult or guest.
  public type InclusionFacts = { extraId : Nat; quantity : Nat; rhythm : E.Rhythm; per : E.Per };

  /// Far past any enterprise family list, written with the two-byte tag escape.
  public let LUXOR_BASE : Nat = 1024;

  /// THE FAMILIES, IN TAG ORDER. Append only; the battery freezes a vector per family.
  public let FAMILIES : [Text] = [
    "configureProperty", "upsertRoomType", "upsertRoom", "upsertRatePlan", "upsertTaxRule", "setNights",
    "releaseExpiredHolds", "placeHold", "releaseHold", "confirmHold", "modifyBooking", "cancelBooking",
    "claimBooking", "joinWaitlist", "leaveWaitlist", "checkIn", "checkOut", "recordGatewayOutcome",
    "openAudit", "advanceAudit", "closeDay", "bootstrapOwner", "grantRole", "revokeRole",
    "propose", "approve", "reject", "settleAtDesk", "setGuestDataKey", "beginIdUpload", "putIdChunk", "fileIdDocument",
    "setNightsMany", "setHotelClock", "markRoom", "takeRoomOutOfOrder", "returnRoomToService",
    "upsertExtra", "postCharge", "addPayer", "routeLines", "settleShare", "issueInvoice",
    "setTaxEta", "setEtaProfile", "bookByStaff", "moveRoom",
    "upsertCompany", "setPlanAccess", "placeHoldCoded", "bookByStaffCoded", "upsertPromo",
    "upsertBlock", "releaseBlock", "pickUpFromBlock",
    "setPlanInclusions",
    "setPlanDeposit", "requireCardOnFile", "confirmHoldOnFile", "putCardOnFile", "recordChargeOutcome", "recordCardForgotten",
    "setMailRelay", "authoriseMailCredential", "setMailOn", "attachMail", "attachMailByStaff", "recordMailOutcome", "recordMailTest",
    "adoptRules",
  ];

  public func familyOf(c : Command) : Text {
    switch c {
      case (#configureProperty _) "configureProperty";
      case (#upsertRoomType _) "upsertRoomType";
      case (#upsertRoom _) "upsertRoom";
      case (#upsertRatePlan _) "upsertRatePlan";
      case (#upsertTaxRule _) "upsertTaxRule";
      case (#setNights _) "setNights";
      case (#releaseExpiredHolds _) "releaseExpiredHolds";
      case (#placeHold _) "placeHold";
      case (#releaseHold _) "releaseHold";
      case (#confirmHold _) "confirmHold";
      case (#modifyBooking _) "modifyBooking";
      case (#cancelBooking _) "cancelBooking";
      case (#claimBooking _) "claimBooking";
      case (#joinWaitlist _) "joinWaitlist";
      case (#leaveWaitlist _) "leaveWaitlist";
      case (#checkIn _) "checkIn";
      case (#checkOut _) "checkOut";
      case (#recordGatewayOutcome _) "recordGatewayOutcome";
      case (#openAudit _) "openAudit";
      case (#advanceAudit _) "advanceAudit";
      case (#closeDay _) "closeDay";
      case (#bootstrapOwner _) "bootstrapOwner";
      case (#grantRole _) "grantRole";
      case (#revokeRole _) "revokeRole";
      case (#propose _) "propose";
      case (#approve _) "approve";
      case (#reject _) "reject";
      case (#settleAtDesk _) "settleAtDesk";
      case (#setGuestDataKey _) "setGuestDataKey";
      case (#beginIdUpload _) "beginIdUpload";
      case (#putIdChunk _) "putIdChunk";
      case (#fileIdDocument _) "fileIdDocument";
      case (#setNightsMany _) "setNightsMany";
      case (#setHotelClock _) "setHotelClock";
      case (#markRoom _) "markRoom";
      case (#takeRoomOutOfOrder _) "takeRoomOutOfOrder";
      case (#returnRoomToService _) "returnRoomToService";
      case (#upsertExtra _) "upsertExtra";
      case (#postCharge _) "postCharge";
      case (#addPayer _) "addPayer";
      case (#routeLines _) "routeLines";
      case (#settleShare _) "settleShare";
      case (#issueInvoice _) "issueInvoice";
      case (#setTaxEta _) "setTaxEta";
      case (#setEtaProfile _) "setEtaProfile";
      case (#bookByStaff _) "bookByStaff";
      case (#moveRoom _) "moveRoom";
      case (#upsertCompany _) "upsertCompany";
      case (#setPlanAccess _) "setPlanAccess";
      case (#placeHoldCoded _) "placeHoldCoded";
      case (#bookByStaffCoded _) "bookByStaffCoded";
      case (#upsertPromo _) "upsertPromo";
      case (#upsertBlock _) "upsertBlock";
      case (#releaseBlock _) "releaseBlock";
      case (#pickUpFromBlock _) "pickUpFromBlock";
      case (#setPlanInclusions _) "setPlanInclusions";
      case (#setPlanDeposit _) "setPlanDeposit";
      case (#requireCardOnFile _) "requireCardOnFile";
      case (#confirmHoldOnFile _) "confirmHoldOnFile";
      case (#putCardOnFile _) "putCardOnFile";
      case (#recordChargeOutcome _) "recordChargeOutcome";
      case (#recordCardForgotten _) "recordCardForgotten";
      case (#setMailRelay _) "setMailRelay";
      case (#authoriseMailCredential _) "authoriseMailCredential";
      case (#setMailOn _) "setMailOn";
      case (#attachMail _) "attachMail";
      case (#attachMailByStaff _) "attachMailByStaff";
      case (#recordMailOutcome _) "recordMailOutcome";
      case (#recordMailTest _) "recordMailTest";
      case (#adoptRules _) "adoptRules";
    }
  };

  public func dualActName(a : DualAct) : Text {
    switch a {
      case (#staffCancel _) "staffCancel";
      case (#waivePenalty _) "waivePenalty";
      case (#refundOutsidePolicy _) "refundOutsidePolicy";
      case (#compNights _) "compNights";
      case (#priceOverride _) "priceOverride";
      case (#editGuestRecord _) "editGuestRecord";
      case (#voidCharge _) "voidCharge";
      case (#issueCreditNote _) "issueCreditNote";
      case (#refundAtDesk _) "refundAtDesk";
    }
  };

  public func dualActBooking(a : DualAct) : Nat {
    switch a {
      case (#staffCancel x) x.bookingId;
      case (#waivePenalty x) x.bookingId;
      case (#refundOutsidePolicy x) x.bookingId;
      case (#compNights x) x.bookingId;
      case (#priceOverride x) x.bookingId;
      case (#editGuestRecord x) x.bookingId;
      case (#voidCharge x) x.bookingId;
      case (#issueCreditNote x) x.bookingId;
      case (#refundAtDesk x) x.bookingId;
    }
  };
}
