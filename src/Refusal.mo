/// Refusal.mo - every reason this hotel says no, typed, with the figures it said no on.
///
/// A refusal names the thing to fix. A guest told "sold out" is told which night; a hotelier told an
/// allotment is too low is told how many rooms are already sold there. The `kind` is a stable short
/// name a client can switch on; the text is the sentence a person reads.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Nat "mo:core/Nat";
import CivilDate "mo:kernel/num/CivilDate";

module {

  public type Refusal = {
    #notConfigured;
    #notAuthorised : { permission : Text };
    #fourEyes : { permission : Text };
    #invalid : { what : Text };
    #tooLong : { what : Text; max : Nat };
    #noSuchRoomType : { id : Nat };
    #noSuchRoom : { id : Nat };
    #noSuchPlan : { id : Nat };
    #noSuchTaxRule : { id : Nat };
    #noSuchHold : { id : Nat };
    #noSuchBooking : { id : Nat };
    #noSuchPayment : { id : Nat };
    #noSuchWaitEntry : { id : Nat };
    #noSuchProposal : { id : Nat };
    #codeTaken : { code : Text; id : Nat };
    /// A rate closed to a company or a promotion, asked for without the access it is sold under.
    #closedRate : { planId : Nat };
    /// A company or promotion code the hotel does not know, or no longer offers.
    #noSuchCode : { code : Text };
    #promoClosed : { code : Text; why : Text };
    #noSuchBlock : { id : Nat };
    /// A group block released (at its cut-off or by revenue): nothing more is picked up from it.
    #blockReleased : { id : Nat };
    /// A pickup wanting more rooms on a night than the block still holds.
    #blockFull : { id : Nat; day : Nat; open : Nat; wanted : Nat };
    #inactive : { what : Text; id : Nat };
    #tooManyRoomTypes : { max : Nat };
    #inThePast : { day : Nat; today : Nat };
    #beyondHorizon : { day : Nat; lastDay : Nat };
    #stayLength : { nights : Nat; max : Nat };
    #rooms : { rooms : Nat; max : Nat };
    #occupancy : { adults : Nat; children : Nat; roomTypeId : Nat };
    #nightClosed : { day : Nat };
    #stopSell : { day : Nat };
    #soldOut : { day : Nat; free : Nat; wanted : Nat };
    #closedToArrival : { day : Nat };
    #closedToDeparture : { day : Nat };
    #minStay : { nights : Nat; min : Nat };
    #maxStay : { nights : Nat; max : Nat };
    #priceChanged : { total : Nat };
    #tooManyHolds : { live : Nat; max : Nat };
    #holdShareCap : { day : Nat; cap : Nat };
    #holdNotLive : { id : Nat; state : Text };
    #holdExpired : { id : Nat; expiredAt : Nat; height : Nat };
    #notTheOwner;
    #nothingToRelease;
    #payment : { reason : Text };
    #authUsed : { authId : Nat };
    #bookingState : { id : Nat; state : Text; wanted : Text };
    #notModifiable : { planId : Nat };
    #allotmentBelowSold : { day : Nat; sold : Nat; held : Nat; allotment : Nat };
    #allotmentAboveRooms : { day : Nat; allotment : Nat; rooms : Nat };
    #editTooWide : { nights : Nat; max : Nat };
    #roomNotVacant : { id : Nat };
    #roomWrongType : { id : Nat; roomTypeId : Nat };
    #notTheDay : { day : Nat; today : Nat };
    #balanceOutstanding : { outstanding : Nat };
    #waitlistFull : { roomTypeId : Nat; max : Nat };
    #alreadyWaiting : { entryId : Nat };
    #audit : { reason : Text };
    #auditOpen : { day : Nat };
    #proposalState : { id : Nat; state : Text };
    #proposalExpired : { id : Nat };
    #hashMismatch;
    #alreadyOwned;
    #roleHeld;
    #roleNotHeld;
    #noSuchExtra : { id : Nat };
    #noSuchPayer : { id : Nat };
    #noSuchCharge : { lineId : Nat };
    /// The window's invoice has closed it: nothing is posted to it, moved in or out, or voided.
    #invoiced : { bookingId : Nat; payerId : Nat };
    #noSuchInvoice : { number : Nat };
    /// A credit note names a line that is not on the bill its invoice closed.
    #otherBill : { lineId : Nat; invoice : Nat };
    /// A credit note would take back more of a line than is left of it.
    #creditBeyondLine : { lineId : Nat; left : Nat };
  };

  func day(d : Nat) : Text { CivilDate.toText(d) };

  public func kind(r : Refusal) : Text {
    switch r {
      case (#notConfigured) "notConfigured"; case (#notAuthorised _) "notAuthorised"; case (#fourEyes _) "fourEyes";
      case (#invalid _) "invalid"; case (#tooLong _) "tooLong"; case (#noSuchRoomType _) "noSuchRoomType";
      case (#noSuchRoom _) "noSuchRoom"; case (#noSuchPlan _) "noSuchPlan"; case (#noSuchTaxRule _) "noSuchTaxRule";
      case (#noSuchHold _) "noSuchHold"; case (#noSuchBooking _) "noSuchBooking"; case (#noSuchPayment _) "noSuchPayment";
      case (#noSuchWaitEntry _) "noSuchWaitEntry"; case (#noSuchProposal _) "noSuchProposal"; case (#codeTaken _) "codeTaken"; case (#closedRate _) "closedRate"; case (#noSuchCode _) "noSuchCode"; case (#promoClosed _) "promoClosed";
      case (#noSuchBlock _) "noSuchBlock"; case (#blockReleased _) "blockReleased"; case (#blockFull _) "blockFull";
      case (#inactive _) "inactive"; case (#tooManyRoomTypes _) "tooManyRoomTypes"; case (#inThePast _) "inThePast";
      case (#beyondHorizon _) "beyondHorizon"; case (#stayLength _) "stayLength"; case (#rooms _) "rooms";
      case (#occupancy _) "occupancy"; case (#nightClosed _) "nightClosed"; case (#stopSell _) "stopSell";
      case (#soldOut _) "soldOut"; case (#closedToArrival _) "closedToArrival"; case (#closedToDeparture _) "closedToDeparture";
      case (#minStay _) "minStay"; case (#maxStay _) "maxStay"; case (#priceChanged _) "priceChanged";
      case (#tooManyHolds _) "tooManyHolds"; case (#holdShareCap _) "holdShareCap"; case (#holdNotLive _) "holdNotLive";
      case (#holdExpired _) "holdExpired"; case (#notTheOwner) "notTheOwner"; case (#nothingToRelease) "nothingToRelease";
      case (#payment _) "payment"; case (#authUsed _) "authUsed"; case (#bookingState _) "bookingState";
      case (#notModifiable _) "notModifiable"; case (#allotmentBelowSold _) "allotmentBelowSold";
      case (#allotmentAboveRooms _) "allotmentAboveRooms"; case (#editTooWide _) "editTooWide";
      case (#roomNotVacant _) "roomNotVacant"; case (#roomWrongType _) "roomWrongType"; case (#notTheDay _) "notTheDay";
      case (#balanceOutstanding _) "balanceOutstanding"; case (#waitlistFull _) "waitlistFull"; case (#alreadyWaiting _) "alreadyWaiting";
      case (#audit _) "audit"; case (#auditOpen _) "auditOpen"; case (#proposalState _) "proposalState";
      case (#proposalExpired _) "proposalExpired"; case (#hashMismatch) "hashMismatch"; case (#alreadyOwned) "alreadyOwned";
      case (#roleHeld) "roleHeld"; case (#roleNotHeld) "roleNotHeld";
      case (#noSuchExtra _) "noSuchExtra"; case (#noSuchPayer _) "noSuchPayer"; case (#noSuchCharge _) "noSuchCharge"; case (#invoiced _) "invoiced";
      case (#noSuchInvoice _) "noSuchInvoice"; case (#otherBill _) "otherBill"; case (#creditBeyondLine _) "creditBeyondLine";
    }
  };

  public func text(r : Refusal) : Text {
    switch r {
      case (#notConfigured) "The property is not set up yet.";
      case (#notAuthorised { permission }) "You do not have permission to " # permission # ".";
      case (#fourEyes { permission }) "To " # permission # " needs a second member of staff: propose it for approval.";
      case (#invalid { what }) what;
      case (#tooLong { what; max }) "The " # what # " is longer than " # Nat.toText(max) # " bytes.";
      case (#noSuchRoomType { id }) "There is no room type " # Nat.toText(id) # ".";
      case (#noSuchRoom { id }) "There is no room " # Nat.toText(id) # ".";
      case (#noSuchPlan { id }) "There is no rate plan " # Nat.toText(id) # ".";
      case (#noSuchTaxRule { id }) "There is no tax rule " # Nat.toText(id) # ".";
      case (#noSuchHold { id }) "There is no hold " # Nat.toText(id) # ".";
      case (#noSuchBooking { id }) "There is no booking " # Nat.toText(id) # ".";
      case (#noSuchPayment { id }) "There is no payment " # Nat.toText(id) # ".";
      case (#noSuchWaitEntry { id }) "There is no waitlist entry " # Nat.toText(id) # ".";
      case (#noSuchProposal { id }) "There is no proposal " # Nat.toText(id) # ".";
      case (#codeTaken { code; id }) "The code " # code # " is already used by " # Nat.toText(id) # ".";
      case (#closedRate { planId }) "Rate plan " # Nat.toText(planId) # " is sold only under its company's or its promotion's code.";
      case (#noSuchCode { code }) "The code " # code # " is not one the hotel offers.";
      case (#promoClosed { code; why }) "The promotion " # code # " " # why;
      case (#noSuchBlock { id }) "There is no group block " # Nat.toText(id) # ".";
      case (#blockReleased { id }) "Group block " # Nat.toText(id) # " has been released; its rooms are back on sale.";
      case (#blockFull { id; day = d; open; wanted }) "Group block " # Nat.toText(id) # " holds " # Nat.toText(open) # " room(s) on " # day(d) # "; " # Nat.toText(wanted) # " were asked for.";
      case (#inactive { what; id }) "The " # what # " " # Nat.toText(id) # " is not offered.";
      case (#tooManyRoomTypes { max }) "A property can have at most " # Nat.toText(max) # " room types.";
      case (#inThePast { day = d; today }) day(d) # " has passed; the hotel's date is " # day(today) # ".";
      case (#beyondHorizon { day = d; lastDay }) "Rooms can be booked up to " # day(lastDay) # ", and " # day(d) # " is later.";
      case (#stayLength { nights; max }) "A stay can be 1 to " # Nat.toText(max) # " nights, and this one is " # Nat.toText(nights) # ".";
      case (#rooms { rooms; max }) "One booking can hold 1 to " # Nat.toText(max) # " rooms, and this one asks for " # Nat.toText(rooms) # ".";
      case (#occupancy { adults; children; roomTypeId }) Nat.toText(adults) # " adults and " # Nat.toText(children) # " children do not fit room type " # Nat.toText(roomTypeId) # ".";
      case (#nightClosed { day = d }) "The night of " # day(d) # " is not open for sale.";
      case (#stopSell { day = d }) "The night of " # day(d) # " is closed for sale.";
      case (#soldOut { day = d; free; wanted }) "Only " # Nat.toText(free) # " room(s) are left on " # day(d) # ", and " # Nat.toText(wanted) # " were asked for.";
      case (#closedToArrival { day = d }) "Arrivals are not taken on " # day(d) # ".";
      case (#closedToDeparture { day = d }) "Departures are not taken on " # day(d) # ".";
      case (#minStay { nights; min }) "Stays from that date are at least " # Nat.toText(min) # " nights, and this one is " # Nat.toText(nights) # ".";
      case (#maxStay { nights; max }) "Stays from that date are at most " # Nat.toText(max) # " nights, and this one is " # Nat.toText(nights) # ".";
      case (#priceChanged { total }) "The price has changed to " # Nat.toText(total) # ". Please review it and try again.";
      case (#tooManyHolds { live; max }) "This browser already holds " # Nat.toText(live) # " rooms; the limit is " # Nat.toText(max) # ".";
      case (#holdShareCap { day = d; cap }) "Too many rooms are on hold for " # day(d) # " (limit " # Nat.toText(cap) # "). Please try again shortly.";
      case (#holdNotLive { id; state }) "Hold " # Nat.toText(id) # " is " # state # ".";
      case (#holdExpired { id; expiredAt = _; height = _ }) "Hold " # Nat.toText(id) # " has expired.";
      case (#notTheOwner) "This was made by someone else.";
      case (#nothingToRelease) "No hold has expired.";
      case (#payment { reason }) reason;
      case (#authUsed { authId }) "Payment authorisation " # Nat.toText(authId) # " has already been used.";
      case (#bookingState { id; state; wanted }) "Booking " # Nat.toText(id) # " is " # state # ", and this needs it " # wanted # ".";
      case (#notModifiable { planId }) "Bookings on rate plan " # Nat.toText(planId) # " cannot be changed.";
      case (#allotmentBelowSold { day = d; sold; held; allotment }) "On " # day(d) # " " # Nat.toText(sold) # " rooms are sold and " # Nat.toText(held) # " on hold, so the allotment cannot be " # Nat.toText(allotment) # ".";
      case (#allotmentAboveRooms { day = d; allotment; rooms }) "On " # day(d) # " the allotment of " # Nat.toText(allotment) # " is more than the " # Nat.toText(rooms) # " rooms of this type.";
      case (#editTooWide { nights; max }) "One edit can change at most " # Nat.toText(max) # " nights, and this one covers " # Nat.toText(nights) # ".";
      case (#roomNotVacant { id }) "Room " # Nat.toText(id) # " is occupied or out of order.";
      case (#roomWrongType { id; roomTypeId }) "Room " # Nat.toText(id) # " is not of room type " # Nat.toText(roomTypeId) # ".";
      case (#notTheDay { day = d; today }) "This is for " # day(d) # ", and the hotel's date is " # day(today) # ".";
      case (#balanceOutstanding { outstanding }) Nat.toText(outstanding) # " is still to pay.";
      case (#waitlistFull { roomTypeId; max }) "The waitlist for room type " # Nat.toText(roomTypeId) # " is full (" # Nat.toText(max) # ").";
      case (#alreadyWaiting { entryId }) "You are already on this waitlist (entry " # Nat.toText(entryId) # ").";
      case (#audit { reason }) reason;
      case (#auditOpen { day = d }) "The night audit for " # day(d) # " is running; acts on or before that day wait for it.";
      case (#proposalState { id; state }) "Proposal " # Nat.toText(id) # " is " # state # ".";
      case (#proposalExpired { id }) "Proposal " # Nat.toText(id) # " has expired.";
      case (#hashMismatch) "The command does not match what was approved.";
      case (#alreadyOwned) "The property already has an owner.";
      case (#roleHeld) "That role is already held.";
      case (#roleNotHeld) "That role is not held.";
      case (#noSuchExtra { id }) "There is no extra " # Nat.toText(id) # ".";
      case (#noSuchPayer { id }) "There is no payer " # Nat.toText(id) # " on this booking.";
      case (#noSuchCharge { lineId }) "Line " # Nat.toText(lineId) # " is not an extra on this booking.";
      case (#invoiced { payerId }) (if (payerId == 0) "The guest's bill" else "This payer's bill") # " is invoiced; nothing more goes on it or comes off it.";
      case (#noSuchInvoice { number }) "There is no invoice " # Nat.toText(number) # ".";
      case (#otherBill { lineId; invoice }) "Line " # Nat.toText(lineId) # " is not on the bill invoice " # Nat.toText(invoice) # " closed.";
      case (#creditBeyondLine { lineId; left }) "Only " # Nat.toText(left) # " of line " # Nat.toText(lineId) # " is left to take back.";
    }
  };
}
