/// Enums.mo - the closed vocabularies, and the byte each value is stored as.
///
/// Each value is one byte, assigned once and never renumbered. Reading goes through a total function
/// that answers `null` for a byte nobody assigned, and a row carrying such a byte traps at decode
/// rather than becoming some other value: a booking read back as the wrong status is worse than a
/// store that stops.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Nat8 "mo:core/Nat8";

module {

  public type BookingStatus = { #confirmed; #checkedIn; #checkedOut; #cancelled; #noShow };
  public func bookingStatusByte(s : BookingStatus) : Nat8 {
    switch s { case (#confirmed) 1; case (#checkedIn) 2; case (#checkedOut) 3; case (#cancelled) 4; case (#noShow) 5 }
  };
  public func bookingStatusOf(b : Nat8) : ?BookingStatus {
    switch b { case 1 ?#confirmed; case 2 ?#checkedIn; case 3 ?#checkedOut; case 4 ?#cancelled; case 5 ?#noShow; case _ null }
  };
  public func bookingStatusText(s : BookingStatus) : Text {
    switch s { case (#confirmed) "confirmed"; case (#checkedIn) "checked-in"; case (#checkedOut) "checked-out"; case (#cancelled) "cancelled"; case (#noShow) "no-show" }
  };
  /// The bookings counted in a night's `sold`: those that will use it, are using it, or used it.
  /// A checked-out booking's nights stay sold (an early departure first shortens the stay to what
  /// was used); a cancelled or no-show booking gives every night back.
  public func holdsNights(s : BookingStatus) : Bool {
    switch s { case (#confirmed or #checkedIn or #checkedOut) true; case _ false }
  };

  public type HoldState = { #live; #confirmed; #released; #expired };
  public func holdStateByte(s : HoldState) : Nat8 {
    switch s { case (#live) 1; case (#confirmed) 2; case (#released) 3; case (#expired) 4 }
  };
  public func holdStateOf(b : Nat8) : ?HoldState {
    switch b { case 1 ?#live; case 2 ?#confirmed; case 3 ?#released; case 4 ?#expired; case _ null }
  };
  public func holdStateText(s : HoldState) : Text {
    switch s { case (#live) "live"; case (#confirmed) "confirmed"; case (#released) "released"; case (#expired) "expired" }
  };

  public type PlanKind = { #bar; #discountOffBar };
  public func planKindByte(k : PlanKind) : Nat8 { switch k { case (#bar) 1; case (#discountOffBar) 2 } };
  public func planKindOf(b : Nat8) : ?PlanKind { switch b { case 1 ?#bar; case 2 ?#discountOffBar; case _ null } };

  /// What a plan takes at confirmation: the first night authorised as a guarantee, the whole stay, or a
  /// deposit (a share of the room's stay, its plan's `planDeposit` row) captured at once.
  public type Guarantee = { #firstNightAuthorised; #prepaidInFull; #deposit };
  public func guaranteeByte(g : Guarantee) : Nat8 { switch g { case (#firstNightAuthorised) 1; case (#prepaidInFull) 2; case (#deposit) 3 } };
  public func guaranteeOf(b : Nat8) : ?Guarantee { switch b { case 1 ?#firstNightAuthorised; case 2 ?#prepaidInFull; case 3 ?#deposit; case _ null } };
  public func guaranteeText(g : Guarantee) : Text { switch g { case (#firstNightAuthorised) "firstNight"; case (#prepaidInFull) "prepaid"; case (#deposit) "deposit" } };

  public type TaxKind = { #percent; #perRoomNight; #perStay };
  public func taxKindByte(k : TaxKind) : Nat8 { switch k { case (#percent) 1; case (#perRoomNight) 2; case (#perStay) 3 } };
  public func taxKindOf(b : Nat8) : ?TaxKind { switch b { case 1 ?#percent; case 2 ?#perRoomNight; case 3 ?#perStay; case _ null } };

  /// What a percent rule is charged on: the room subtotal, or the room subtotal plus every rule of a
  /// lower rank (the Egyptian compound: service charge first, then VAT on room plus service).
  public type TaxBase = { #room; #roomAndPriorTaxes };
  public func taxBaseByte(k : TaxBase) : Nat8 { switch k { case (#room) 1; case (#roomAndPriorTaxes) 2 } };
  public func taxBaseOf(b : Nat8) : ?TaxBase { switch b { case 1 ?#room; case 2 ?#roomAndPriorTaxes; case _ null } };

  /// `extra` is a charge from the hotel's catalogue (code: its category) and `extraTax` a tax on it
  /// (code: the tax rule): kinds of their own, so nothing that works night by night on the room
  /// (shortening a stay gives back its nights) can mistake one for the room's.
  public type FolioKind = { #roomNight; #tax; #penalty; #credit; #adjustment; #extra; #extraTax };
  public func folioKindByte(k : FolioKind) : Nat8 {
    switch k { case (#roomNight) 1; case (#tax) 2; case (#penalty) 3; case (#credit) 4; case (#adjustment) 5; case (#extra) 6; case (#extraTax) 7 }
  };
  public func folioKindOf(b : Nat8) : ?FolioKind {
    switch b { case 1 ?#roomNight; case 2 ?#tax; case 3 ?#penalty; case 4 ?#credit; case 5 ?#adjustment; case 6 ?#extra; case 7 ?#extraTax; case _ null }
  };
  /// A credit line reduces what the guest owes; every other line adds to it.
  public func folioKindText(k : FolioKind) : Text {
    switch k { case (#roomNight) "roomNight"; case (#tax) "tax"; case (#penalty) "penalty"; case (#credit) "credit"; case (#adjustment) "adjustment";
      case (#extra) "extra"; case (#extraTax) "extraTax" }
  };
  /// A line that belongs to the stay's nights (room, its taxes, a penalty), as against an extra.
  public func isRoomLine(k : FolioKind) : Bool { switch k { case (#roomNight or #tax or #penalty) true; case _ false } };

  /// What an extra is, for the bill and the reports.
  public type ExtraCategory = { #restaurant; #minibar; #spa; #parking; #breakfast; #other };
  public func extraCategoryByte(k : ExtraCategory) : Nat8 {
    switch k { case (#restaurant) 1; case (#minibar) 2; case (#spa) 3; case (#parking) 4; case (#breakfast) 5; case (#other) 6 }
  };
  public func extraCategoryOf(b : Nat8) : ?ExtraCategory {
    switch b { case 1 ?#restaurant; case 2 ?#minibar; case 3 ?#spa; case 4 ?#parking; case 5 ?#breakfast; case 6 ?#other; case _ null }
  };
  public func extraCategoryText(k : ExtraCategory) : Text {
    switch k { case (#restaurant) "restaurant"; case (#minibar) "minibar"; case (#spa) "spa"; case (#parking) "parking"; case (#breakfast) "breakfast"; case (#other) "other" }
  };
  /// When a package's inclusion is given: every night of the stay, or the arrival night only.
  public type Rhythm = { #everyNight; #arrivalNight };
  public func rhythmByte(r : Rhythm) : Nat8 { switch r { case (#everyNight) 1; case (#arrivalNight) 2 } };
  public func rhythmOf(b : Nat8) : ?Rhythm { switch b { case 1 ?#everyNight; case 2 ?#arrivalNight; case _ null } };
  public func rhythmText(r : Rhythm) : Text { switch r { case (#everyNight) "everyNight"; case (#arrivalNight) "arrivalNight" } };

  /// What an inclusion's quantity is counted per: each room, each adult, or each guest (adults and
  /// children).
  public type Per = { #room; #adult; #guest };
  public func perByte(p : Per) : Nat8 { switch p { case (#room) 1; case (#adult) 2; case (#guest) 3 } };
  public func perOf(b : Nat8) : ?Per { switch b { case 1 ?#room; case 2 ?#adult; case 3 ?#guest; case _ null } };
  public func perText(p : Per) : Text { switch p { case (#room) "room"; case (#adult) "adult"; case (#guest) "guest" } };

  public func isCredit(k : FolioKind) : Bool { switch k { case (#credit) true; case _ false } };

  /// How a refund the gateway would not make was paid at the desk instead.
  public type DeskMethod = { #cash; #transfer };
  public func deskMethodByte(m : DeskMethod) : Nat8 { switch m { case (#cash) 1; case (#transfer) 2 } };
  public func deskMethodOf(b : Nat8) : ?DeskMethod { switch b { case 1 ?#cash; case 2 ?#transfer; case _ null } };
  public func deskMethodText(m : DeskMethod) : Text { switch m { case (#cash) "cash"; case (#transfer) "transfer" } };

  /// How a booking taken by staff reached the hotel: a call, or a guest at the desk (checked in at once).
  /// How a booking staff took came: by phone, a walk-in, or from a group's rooming list (a block).
  public type Channel = { #phone; #walkIn; #group };
  public func channelByte(c : Channel) : Nat8 { switch c { case (#phone) 1; case (#walkIn) 2; case (#group) 3 } };
  public func channelOf(b : Nat8) : ?Channel { switch b { case 1 ?#phone; case 2 ?#walkIn; case 3 ?#group; case _ null } };
  public func channelText(c : Channel) : Text { switch c { case (#phone) "phone"; case (#walkIn) "walkIn"; case (#group) "group" } };

  /// `#chargedOnFile`: a no-show's penalty charged by the hotel to the card the guest kept on file (a
  /// merchant-initiated charge, authorised and captured in one act). Until the gateway answers its
  /// `gatewayAuth` is 0; once it is made, the authorisation the gateway gave it, so it is refunded as
  /// any capture is.
  public type PaymentKind = { #authorised; #captured; #refunded; #voided; #chargedOnFile };
  public func paymentKindByte(k : PaymentKind) : Nat8 { switch k { case (#authorised) 1; case (#captured) 2; case (#refunded) 3; case (#voided) 4; case (#chargedOnFile) 5 } };
  public func paymentKindOf(b : Nat8) : ?PaymentKind {
    switch b { case 1 ?#authorised; case 2 ?#captured; case 3 ?#refunded; case 4 ?#voided; case 5 ?#chargedOnFile; case _ null }
  };
  public func paymentKindText(k : PaymentKind) : Text {
    switch k { case (#authorised) "authorised"; case (#captured) "captured"; case (#refunded) "refunded"; case (#voided) "voided"; case (#chargedOnFile) "chargedOnFile" }
  };
  /// Money a payment moves into the hotel: a capture, or a charge on file.
  public func takesMoney(k : PaymentKind) : Bool { k == #captured or k == #chargedOnFile };

  /// A booking's card on file. `#wanted`: a booking staff took on a plan that keeps a card, waiting for the
  /// guest to put one on file through its card link; `#kept`: the gateway holds a token for it, which the
  /// guest agreed to; `#forgetDue`: the booking is settled and the token is to be deleted at the gateway;
  /// `#forgotten`: it was; `#forgetFailed`: the gateway refused three times, shown to the desk; `#closed`:
  /// a wanted card the booking no longer needs (it was settled, or the guest arrived, without one).
  public type CardState = { #wanted; #kept; #forgetDue; #forgotten; #forgetFailed; #closed };
  public func cardStateByte(s : CardState) : Nat8 {
    switch s { case (#wanted) 1; case (#kept) 2; case (#forgetDue) 3; case (#forgotten) 4; case (#forgetFailed) 5; case (#closed) 6 }
  };
  public func cardStateOf(b : Nat8) : ?CardState {
    switch b { case 1 ?#wanted; case 2 ?#kept; case 3 ?#forgetDue; case 4 ?#forgotten; case 5 ?#forgetFailed; case 6 ?#closed; case _ null }
  };
  public func cardStateText(s : CardState) : Text {
    switch s { case (#wanted) "wanted"; case (#kept) "kept"; case (#forgetDue) "forgetDue"; case (#forgotten) "forgotten"; case (#forgetFailed) "forgetFailed"; case (#closed) "closed" }
  };

  /// `due` waits for the gateway queue; `done` is confirmed by the gateway; `failed` was refused by it.
  public type PaymentState = { #due; #done; #failed };
  public func paymentStateByte(s : PaymentState) : Nat8 { switch s { case (#due) 1; case (#done) 2; case (#failed) 3 } };
  public func paymentStateOf(b : Nat8) : ?PaymentState { switch b { case 1 ?#due; case 2 ?#done; case 3 ?#failed; case _ null } };
  public func paymentStateText(s : PaymentState) : Text { switch s { case (#due) "due"; case (#done) "done"; case (#failed) "failed" } };

  public type RoomStatus = { #active; #outOfOrder };
  public func roomStatusByte(s : RoomStatus) : Nat8 { switch s { case (#active) 1; case (#outOfOrder) 2 } };
  public func roomStatusOf(b : Nat8) : ?RoomStatus { switch b { case 1 ?#active; case 2 ?#outOfOrder; case _ null } };

  public type BedKind = { #king; #queen; #double; #twin; #single };
  public func bedKindByte(k : BedKind) : Nat8 { switch k { case (#king) 1; case (#queen) 2; case (#double) 3; case (#twin) 4; case (#single) 5 } };
  public func bedKindOf(b : Nat8) : ?BedKind {
    switch b { case 1 ?#king; case 2 ?#queen; case 3 ?#double; case 4 ?#twin; case 5 ?#single; case _ null }
  };
  public func bedKindText(k : BedKind) : Text {
    switch k { case (#king) "king"; case (#queen) "queen"; case (#double) "double"; case (#twin) "twin"; case (#single) "single" }
  };

  public type WaitState = { #waiting; #offered; #left };
  public func waitStateByte(s : WaitState) : Nat8 { switch s { case (#waiting) 1; case (#offered) 2; case (#left) 3 } };
  public func waitStateOf(b : Nat8) : ?WaitState { switch b { case 1 ?#waiting; case 2 ?#offered; case 3 ?#left; case _ null } };
  public func waitStateText(s : WaitState) : Text { switch s { case (#waiting) "waiting"; case (#offered) "offered"; case (#left) "left" } };

  /// Staff roles. The owner grants the others; revenue sets rates and inventory; the front desk runs
  /// arrivals and departures; the auditor reads and runs the night audit; housekeeping keeps the rooms.
  /// `#mailer` is not a person: it is the mail relay's key, given by the owner's `setMailRelay` and by
  /// nothing else. It reads the messages owed and records what became of each, and holds no other
  /// permission, the owner's included.
  public type Role = { #owner; #revenue; #frontDesk; #auditor; #housekeeping; #mailer };
  public func roleByte(r : Role) : Nat8 { switch r { case (#owner) 1; case (#revenue) 2; case (#frontDesk) 3; case (#auditor) 4; case (#housekeeping) 5; case (#mailer) 6 } };
  public func roleOf(b : Nat8) : ?Role { switch b { case 1 ?#owner; case 2 ?#revenue; case 3 ?#frontDesk; case 4 ?#auditor; case 5 ?#housekeeping; case 6 ?#mailer; case _ null } };
  public func roleText(r : Role) : Text {
    switch r { case (#owner) "owner"; case (#revenue) "revenue"; case (#frontDesk) "front-desk"; case (#auditor) "auditor"; case (#housekeeping) "housekeeping"; case (#mailer) "mailer" }
  };

  /// The four messages the hotel owes a guest who gave an email address.
  public type MailKind = { #confirmation; #preArrival; #receipt; #cancellation };
  public func mailKindByte(k : MailKind) : Nat8 { switch k { case (#confirmation) 1; case (#preArrival) 2; case (#receipt) 3; case (#cancellation) 4 } };
  public func mailKindOf(b : Nat8) : ?MailKind { switch b { case 1 ?#confirmation; case 2 ?#preArrival; case 3 ?#receipt; case 4 ?#cancellation; case _ null } };
  public func mailKindText(k : MailKind) : Text {
    switch k { case (#confirmation) "confirmation"; case (#preArrival) "preArrival"; case (#receipt) "receipt"; case (#cancellation) "cancellation" }
  };

  /// A message owed: `#due` until the relay sends it, `#sent` once it has, `#failed` after three failed
  /// attempts, `#skipped` when the booking no longer needs it (a pre-arrival for a guest who arrived).
  public type MailState = { #due; #sent; #failed; #skipped };
  public func mailStateByte(s : MailState) : Nat8 { switch s { case (#due) 1; case (#sent) 2; case (#failed) 3; case (#skipped) 4 } };
  public func mailStateOf(b : Nat8) : ?MailState { switch b { case 1 ?#due; case 2 ?#sent; case 3 ?#failed; case 4 ?#skipped; case _ null } };
  public func mailStateText(s : MailState) : Text { switch s { case (#due) "due"; case (#sent) "sent"; case (#failed) "failed"; case (#skipped) "skipped" } };

  /// Why a send failed, as a code and never as the provider's words (which may quote the address):
  /// the provider refused the message, the provider could not be reached, the address could not be
  /// unsealed, or the hotel's email account refused the relay's sign-in.
  public type MailFailure = { #none; #rejected; #unavailable; #unreadable; #signIn };
  public func mailFailureByte(f : MailFailure) : Nat8 { switch f { case (#none) 0; case (#rejected) 1; case (#unavailable) 2; case (#unreadable) 3; case (#signIn) 4 } };
  public func mailFailureOf(b : Nat8) : ?MailFailure { switch b { case 0 ?#none; case 1 ?#rejected; case 2 ?#unavailable; case 3 ?#unreadable; case 4 ?#signIn; case _ null } };
  public func mailFailureText(f : MailFailure) : Text {
    switch f { case (#none) ""; case (#rejected) "rejected"; case (#unavailable) "unavailable"; case (#unreadable) "unreadable"; case (#signIn) "signIn" }
  };

  /// The language a guest's messages are written in: the one the guest booked in.
  public type Lang = { #en; #ar };
  public func langByte(l : Lang) : Nat8 { switch l { case (#en) 1; case (#ar) 2 } };
  public func langOf(b : Nat8) : ?Lang { switch b { case 1 ?#en; case 2 ?#ar; case _ null } };
  public func langText(l : Lang) : Text { switch l { case (#en) "en"; case (#ar) "ar" } };

  /// A room's state of cleaning. A guest leaving makes it dirty; it is cleaned, then inspected by a
  /// second person. A room with no housekeeping record yet has none of these: it is "not recorded".
  public type Cleaning = { #dirty; #clean; #inspected };
  public func cleaningByte(c : Cleaning) : Nat8 { switch c { case (#dirty) 1; case (#clean) 2; case (#inspected) 3 } };
  public func cleaningOf(b : Nat8) : ?Cleaning { switch b { case 1 ?#dirty; case 2 ?#clean; case 3 ?#inspected; case _ null } };
  public func cleaningText(c : Cleaning) : Text { switch c { case (#dirty) "dirty"; case (#clean) "clean"; case (#inspected) "inspected" } };

  public type ProposalStatus = { #awaiting; #executed; #rejected; #expired };
  public func proposalStatusByte(s : ProposalStatus) : Nat8 { switch s { case (#awaiting) 1; case (#executed) 2; case (#rejected) 3; case (#expired) 4 } };
  public func proposalStatusOf(b : Nat8) : ?ProposalStatus {
    switch b { case 1 ?#awaiting; case 2 ?#executed; case 3 ?#rejected; case 4 ?#expired; case _ null }
  };
  public func proposalStatusText(s : ProposalStatus) : Text {
    switch s { case (#awaiting) "awaiting"; case (#executed) "executed"; case (#rejected) "rejected"; case (#expired) "expired" }
  };
}
