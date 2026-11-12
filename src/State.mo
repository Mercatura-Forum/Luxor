/// State.mo - one command, applied to the hotel's state: the fold's single entry point.
///
/// A replay goes through this function and so does a live command; there is no second writer. Staff
/// commands check their permission here, against the catalogue, before anything else.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Cmd "Command";
import Audit "Audit";
import Bill "Bill";
import Blocks "Blocks";
import CN "CreditNote";
import Acc "Access";
import RP "RateProducts";
import Res "Reservations";
import Rf "Refusal";
import IdDocs "IdDocs";
import HotelClock "HotelClock";
import Hk "Housekeeping";
import Mail "Mail";
import Rules "Rules";
import Setup "Setup";
import Staff "Staff";
import St "Store";

module {

  public type Out = { #ok : [Nat]; #err : Rf.Refusal };

  func guarded(c : St.Ctx, staff : Principal, command : Text, run : () -> Out) : Out {
    switch (Staff.require(c.s, staff, command)) { case (?r) #err(r); case null run() }
  };

  public func apply(c : St.Ctx, command : Cmd.Command) : Out {
    let out = switch command {
      case (#configureProperty { staff; facts }) guarded(c, staff, "configureProperty", func() { Setup.configureProperty(c, facts) });
      case (#upsertRoomType { staff; id; facts }) guarded(c, staff, "upsertRoomType", func() { Setup.upsertRoomType(c, id, facts) });
      case (#upsertRoom { staff; id; roomTypeId; number; outOfOrder }) guarded(c, staff, "upsertRoom", func() { Setup.upsertRoom(c, id, roomTypeId, number, outOfOrder) });
      case (#upsertRatePlan { staff; id; facts }) guarded(c, staff, "upsertRatePlan", func() { Setup.upsertRatePlan(c, id, facts) });
      case (#upsertTaxRule { staff; id; facts }) guarded(c, staff, "upsertTaxRule", func() { Setup.upsertTaxRule(c, id, facts) });
      case (#setNights { staff; edit }) guarded(c, staff, "setNights", func() { Setup.setNights(c, edit) });
      case (#setNightsMany { staff; edits }) guarded(c, staff, "setNightsMany", func() { Setup.setNightsMany(c, edits) });
      case (#setHotelClock x) guarded(c, x.staff, "setHotelClock", func() { HotelClock.set(c, x.zoneName, x.zoneRule, x.auditAt, x.auto, x.runner, x.staff) });
      case (#releaseExpiredHolds { limit }) Res.releaseExpired(c, limit);
      case (#placeHold { owner; stay; quoteHash; key }) Res.placeHold(c, owner, stay, quoteHash, key, Acc.PUBLIC);
      case (#placeHoldCoded { owner; stay; quoteHash; key; code }) {
        switch (Acc.resolve(c, code)) { case (#ok g) Res.placeHold(c, owner, stay, quoteHash, key, Acc.forPlan(c, g, stay.planId)); case (#err r) #err(r) }
      };
      case (#releaseHold { owner; holdId }) Res.releaseHold(c, owner, holdId);
      case (#confirmHold x) Res.confirmHold(c, x.owner, x.holdId, { guestName = x.guestName; guestEmail = x.guestEmail; note = x.note; manageKey = x.manageKey; account = x.account }, x.auth);
      case (#modifyBooking { by; bookingId; stay; quoteHash; auth }) {
        let o = Res.modify(c, by, bookingId, stay, quoteHash, auth);
        switch (o, by) { case (#ok _, #manageKey) Res.bumpNonce(c, bookingId); case _ {} };
        o
      };
      case (#cancelBooking { by; bookingId }) {
        let o = Res.cancel(c, by, bookingId);
        switch (o, by) { case (#ok _, #manageKey) Res.bumpNonce(c, bookingId); case _ {} };
        o
      };
      case (#claimBooking { account; bookingId }) Res.claim(c, account, bookingId);
      case (#joinWaitlist { account; stay }) Res.joinWaitlist(c, account, stay);
      case (#leaveWaitlist { account; entryId }) Res.leaveWaitlist(c, account, entryId);
      case (#checkIn { staff; bookingId; roomIds }) guarded(c, staff, "checkIn", func() { Res.checkIn(c, bookingId, roomIds) });
      case (#checkOut { staff; bookingId }) guarded(c, staff, "checkOut", func() { Res.checkOut(c, bookingId) });
      case (#recordGatewayOutcome { paymentId; ok }) Res.gatewayOutcome(c, paymentId, ok);
      case (#openAudit { staff; day }) guarded(c, staff, "openAudit", func() { Audit.open(c, day) });
      case (#advanceAudit { staff; day; limit }) guarded(c, staff, "advanceAudit", func() { Audit.advance(c, day, limit) });
      case (#closeDay { staff; day }) guarded(c, staff, "closeDay", func() { Audit.close(c, day) });
      case (#bootstrapOwner { subject }) Staff.bootstrapOwner(c, subject);
      case (#grantRole { staff; subject; role }) Staff.grantRole(c, staff, subject, role);
      case (#revokeRole { staff; subject; role }) Staff.revokeRole(c, staff, subject, role);
      case (#propose { staff; act; justification }) Staff.propose(c, staff, act, justification);
      case (#approve { staff; proposalId }) Staff.approve(c, staff, proposalId);
      case (#reject { staff; proposalId; reason }) Staff.reject(c, staff, proposalId, reason);
      case (#settleAtDesk { staff; bookingId; auth }) guarded(c, staff, "settleAtDesk", func() { Res.settleAtDesk(c, bookingId, auth) });
      case (#setGuestDataKey { staff; key }) guarded(c, staff, "setGuestDataKey", func() { Setup.setGuestDataKey(c, key) });
      case (#beginIdUpload { staff; bookingId; size; chunkHashes }) guarded(c, staff, "beginIdUpload", func() { IdDocs.begin(c, staff, bookingId, size, chunkHashes) });
      case (#putIdChunk { staff; blobId; index; bytes }) guarded(c, staff, "putIdChunk", func() { IdDocs.put(c, staff, blobId, index, bytes) });
      case (#fileIdDocument x) guarded(c, x.staff, "fileIdDocument", func() { IdDocs.file(c, x.staff, x.bookingId, x.blobId, x.plainHash, x.plainSize, x.mime, x.fileKey) });
      case (#markRoom { staff; roomId; cleaning }) guarded(c, staff, "markRoom", func() { Hk.mark(c, staff, roomId, cleaning) });
      case (#takeRoomOutOfOrder { staff; roomId; reason; untilDay }) guarded(c, staff, "takeRoomOutOfOrder", func() { Hk.takeOut(c, roomId, reason, untilDay) });
      case (#returnRoomToService { staff; roomId }) guarded(c, staff, "returnRoomToService", func() { Hk.returnToService(c, roomId) });
      case (#upsertExtra { staff; id; facts }) guarded(c, staff, "upsertExtra", func() { Bill.upsertExtra(c, id, facts) });
      case (#postCharge x) guarded(c, x.staff, "postCharge", func() { Bill.post(c, x.staff, x.bookingId, x.extraId, x.quantity, x.amount, x.payerId) });
      case (#addPayer { staff; bookingId; name }) guarded(c, staff, "addPayer", func() { Bill.addPayer(c, bookingId, name) });
      case (#routeLines { staff; bookingId; lineIds; payerId }) guarded(c, staff, "routeLines", func() { Bill.routeLines(c, bookingId, lineIds, payerId) });
      case (#settleShare { staff; bookingId; payerId; auth }) guarded(c, staff, "settleShare", func() { Bill.settleShare(c, bookingId, payerId, auth) });
      case (#issueInvoice { staff; bookingId; payerId }) guarded(c, staff, "issueInvoice", func() { Bill.issueInvoice(c, staff, bookingId, payerId) });
      case (#bookByStaff x) guarded(c, x.staff, "bookByStaff", func() {
        Res.bookByStaff(c, x.staff, x.channel, x.stay, x.quoteHash, { guestName = x.guestName; guestEmail = x.guestEmail; note = x.note; manageKey = x.manageKey; account = null }, x.roomIds, Acc.PUBLIC, 0)
      });
      case (#bookByStaffCoded x) guarded(c, x.staff, "bookByStaffCoded", func() {
        switch (Acc.resolve(c, x.code)) {
          case (#ok g) Res.bookByStaff(c, x.staff, x.channel, x.stay, x.quoteHash, { guestName = x.guestName; guestEmail = x.guestEmail; note = x.note; manageKey = x.manageKey; account = null }, x.roomIds, Acc.forPlan(c, g, x.stay.planId), 0);
          case (#err r) #err(r);
        }
      });
      case (#upsertCompany { staff; id; code; name; active }) guarded(c, staff, "upsertCompany", func() { RP.upsertCompany(c, id, code, name, active) });
      case (#upsertPromo x) guarded(c, x.staff, "upsertPromo", func() {
        RP.upsertPromo(c, x.id, { code = x.code; name = x.name; planId = x.planId; bookFrom = x.bookFrom; bookUntil = x.bookUntil;
          stayFrom = x.stayFrom; stayUntil = x.stayUntil; maxUses = x.maxUses; active = x.active })
      });
      case (#upsertBlock x) guarded(c, x.staff, "upsertBlock", func() {
        Blocks.upsert(c, x.id, { name = x.name; companyId = x.companyId; roomTypeId = x.roomTypeId; planId = x.planId; arrival = x.arrival; nights = x.nights;
          rooms = x.rooms; cutoff = x.cutoff })
      });
      case (#releaseBlock { staff; id }) guarded(c, staff, "releaseBlock", func() { Blocks.release(c, id) });
      case (#pickUpFromBlock x) guarded(c, x.staff, "pickUpFromBlock", func() {
        // the block's access: its company's, or the public sale
        let grant : Acc.Grant = switch (St.block(c.x, x.blockId)) { case (?b) ({ companyId = b.companyId; promoId = 0 }); case null Acc.PUBLIC };
        Res.bookByStaff(c, x.staff, #group, x.stay, x.quoteHash, { guestName = x.guestName; guestEmail = x.guestEmail; note = x.note; manageKey = x.manageKey; account = null },
          [], grant, x.blockId)
      });
      case (#setPlanInclusions { staff; planId; inclusions }) guarded(c, staff, "setPlanInclusions", func() { RP.setPlanInclusions(c, planId, inclusions) });
      case (#setPlanDeposit { staff; planId; depositBps }) guarded(c, staff, "setPlanDeposit", func() { RP.setPlanDeposit(c, planId, depositBps) });
      case (#requireCardOnFile { staff }) guarded(c, staff, "requireCardOnFile", func() { Res.requireCardOnFile(c) });
      case (#confirmHoldOnFile x) Res.confirmHoldOnFile(c, x.owner, x.holdId, { guestName = x.guestName; guestEmail = x.guestEmail; note = x.note; manageKey = x.manageKey; account = x.account }, x.auth, x.token);
      case (#putCardOnFile { by; bookingId; auth; token }) {
        let o = Res.putCardOnFile(c, by, bookingId, auth, token);
        switch (o, by) { case (#ok _, #manageKey) Res.bumpNonce(c, bookingId); case _ {} };
        o
      };
      case (#recordChargeOutcome { paymentId; ok; authId }) Res.chargeOutcome(c, paymentId, ok, authId);
      case (#recordCardForgotten { bookingId; ok }) Res.cardForgotten(c, bookingId, ok);
      case (#setMailRelay { staff; mailer; mailKey }) guarded(c, staff, "setMailRelay", func() {
        Mail.setRelay(c, mailer, mailKey, func(m : Principal) : Nat { Staff.holdMailerFor(c, m) }, func(g : Nat) { Staff.endGrant(c, g) })
      });
      case (#authoriseMailCredential { staff; digest }) guarded(c, staff, "authoriseMailCredential", func() { Mail.authorise(c, digest) });
      case (#setMailOn { staff; on }) guarded(c, staff, "setMailOn", func() { Mail.turn(c, on) });
      case (#attachMail { by; bookingId; sealed; lang }) {
        let o = Res.attachMail(c, by, bookingId, sealed, lang);
        switch (o, by) { case (#ok _, #manageKey) Res.bumpNonce(c, bookingId); case _ {} };
        o
      };
      case (#attachMailByStaff { staff; bookingId; sealed; lang }) guarded(c, staff, "attachMailByStaff", func() { Mail.attach(c, bookingId, sealed, lang) });
      case (#recordMailOutcome { mailer; outboxId; sent; failure }) guarded(c, mailer, "recordMailOutcome", func() { Mail.recordOutcome(c, outboxId, sent, failure) });
      case (#recordMailTest { mailer; digest }) guarded(c, mailer, "recordMailTest", func() { Mail.recordTest(c, digest) });
      case (#adoptRules { staff; epoch }) guarded(c, staff, "adoptRules", func() { Rules.adopt(c, epoch) });
      case (#setPlanAccess { staff; planId; companyId; closed }) guarded(c, staff, "setPlanAccess", func() { RP.setPlanAccess(c, planId, companyId, closed) });
      case (#moveRoom { staff; bookingId; fromRoomId; toRoomId }) guarded(c, staff, "moveRoom", func() { Res.moveRoom(c, bookingId, fromRoomId, toRoomId) });
      case (#setTaxEta { staff; taxRuleId; taxType; subType }) guarded(c, staff, "setTaxEta", func() { CN.setTaxEta(c, taxRuleId, taxType, subType) });
      case (#setEtaProfile { staff; facts }) guarded(c, staff, "setEtaProfile", func() { CN.setEtaProfile(c, facts) });
    };
    switch out { case (#ok _) c.s.blocksApplied += 1; case (#err _) {} };
    out
  };
}
