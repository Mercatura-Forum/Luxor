/// Staff.mo - who may do what at the hotel, and the acts that need two people.
///
/// AUTHORITY IS A TABLE. Each staff command has a row in the catalogue (the kernel's `Permissions`),
/// naming the roles that may exercise it; the battery checks the catalogue total in both directions
/// against the command list. A guest's own acts are not in it: they are authorised by the terms the
/// guest booked under and by the guest's own key, and the battery states that split.
///
/// FOUR EYES BY COMPARING PRINCIPALS. Anything that moves money or a guest's record at a member of
/// staff's discretion - a cancellation with a refund, a waived fee, a refund outside the terms, a
/// comp, a price override, a change to a guest's name - is proposed by one person and approved by a
/// different one. The proposal keeps the act's canonical bytes and their hash; the approval re-derives
/// the hash from the stored bytes and refuses if they differ, so the approver approves the act that
/// then executes and nothing else.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Text "mo:core/Text";

import AuthTypes "mo:kernel/auth/AuthTypes";
import Permissions "mo:kernel/auth/Permissions";
import C "mo:kernel/codec/Canonical";
import RowStore "mo:kernel/rows/RowStore";

import Bill "Bill";
import Cmd "Command";
import CN "CreditNote";
import E "Enums";
import Enc "Encoding";
import R "Rows";
import Rf "Refusal";
import Res "Reservations";
import St "Store";
import TA "TextArena";

module {

  public type Out = { #ok : [Nat]; #err : Rf.Refusal };

  /// The catalogue. `guards` names the command (or, for a four-eyes act, `propose:<act>`).
  public func catalogue() : Permissions.Catalogue { [
    Permissions.p("setup.property", "property", #update, #command("configureProperty"), false, false, false),
    Permissions.p("setup.roomType", "roomType", #update, #command("upsertRoomType"), false, false, false),
    Permissions.p("setup.room", "room", #update, #command("upsertRoom"), false, false, false),
    Permissions.p("setup.ratePlan", "ratePlan", #update, #command("upsertRatePlan"), false, false, false),
    // a package is part of its plan: the owner's, as the plan is
    Permissions.p("setup.planInclusions", "ratePlan", #update, #command("setPlanInclusions"), false, false, false),
    // a deposit is part of its plan's guarantee: the owner's, as the plan is
    Permissions.p("setup.planDeposit", "ratePlan", #update, #command("setPlanDeposit"), false, false, false),
    // the hotel's card rule is the owner's alone, and turned on once
    Permissions.p("setup.cardPolicy", "property", #update, #command("requireCardOnFile"), false, false, false),
    // guest email is connected, authorised and turned on by the owner alone
    Permissions.p("setup.mailRelay", "property", #update, #command("setMailRelay"), false, false, false),
    Permissions.p("setup.mailCredential", "property", #update, #command("authoriseMailCredential"), false, false, false),
    Permissions.p("setup.mailOn", "property", #update, #command("setMailOn"), false, false, false),
    // the desk gives a guest's address as it takes the booking
    Permissions.p("booking.attachMail", "booking", #update, #command("attachMailByStaff"), false, false, false),
    // the mail relay's own acts: the mailer's key alone, not even the owner's, so nobody at the hotel can
    // mark a message sent that the relay never sent
    Permissions.p("mail.outcome", "outbox", #update, #command("recordMailOutcome"), false, false, false),
    Permissions.p("mail.test", "property", #update, #command("recordMailTest"), false, false, false),
    Permissions.p("setup.taxRule", "taxRule", #update, #command("upsertTaxRule"), false, false, false),
    Permissions.p("setup.dataKey", "property", #update, #command("setGuestDataKey"), false, false, false),
    Permissions.p("setup.clock", "property", #update, #command("setHotelClock"), false, false, false),
    Permissions.p("rates.edit", "night", #update, #command("setNights"), false, false, false),
    Permissions.p("rates.editMany", "night", #update, #command("setNightsMany"), false, false, false),
    Permissions.p("desk.checkIn", "booking", #activate, #command("checkIn"), false, false, false),
    Permissions.p("desk.checkOut", "booking", #close, #command("checkOut"), false, false, false),
    // the guest presents their own document in person; staff neither author nor change it, and it is
    // erased on a fixed rule: not an alteration of a person's record, so one person at the desk
    Permissions.p("desk.idBegin", "identityDocument", #create, #command("beginIdUpload"), false, false, false),
    Permissions.p("desk.idPut", "identityDocument", #create, #command("putIdChunk"), false, false, false),
    Permissions.p("desk.idFile", "identityDocument", #create, #command("fileIdDocument"), false, false, false),
    // the guest's own card authorisation, verified at the gateway, is what moves the money here
    Permissions.p("desk.settle", "payment", #create, #command("settleAtDesk"), false, false, false),
    // housekeeping: inspection is by a second person, compared in the fold (Housekeeping.mark), not a proposal
    Permissions.p("hk.mark", "room", #update, #command("markRoom"), false, false, false),
    Permissions.p("hk.outOfOrder", "room", #update, #command("takeRoomOutOfOrder"), false, false, false),
    Permissions.p("hk.return", "room", #update, #command("returnRoomToService"), false, false, false),
    Permissions.p("setup.extra", "extra", #update, #command("upsertExtra"), false, false, false),
    // a charge, a payer, a move between bills and an invoice are recorded acts at the desk, each
    // undone only by a voiding credit (four eyes, below) or not at all (an invoice); a payer's share is
    // moved by their own card at the gateway, like the guest's settlement
    Permissions.p("desk.charge", "folio", #create, #command("postCharge"), false, false, false),
    Permissions.p("desk.payer", "folio", #update, #command("addPayer"), false, false, false),
    Permissions.p("desk.route", "folio", #update, #command("routeLines"), false, false, false),
    Permissions.p("desk.settleShare", "payment", #create, #command("settleShare"), false, false, false),
    Permissions.p("desk.invoice", "invoice", #create, #command("issueInvoice"), false, false, false),
    Permissions.p("audit.open", "audit", #create, #command("openAudit"), false, false, false),
    Permissions.p("audit.advance", "audit", #update, #command("advanceAudit"), false, false, false),
    Permissions.p("audit.close", "audit", #close, #command("closeDay"), false, false, false),
    Permissions.p("roles.grant", "grant", #create, #command("grantRole"), false, false, false),
    Permissions.p("roles.revoke", "grant", #delete, #command("revokeRole"), false, false, false),
    Permissions.p("proposal.approve", "proposal", #approve, #command("approve"), false, false, false),
    Permissions.p("proposal.reject", "proposal", #reject, #command("reject"), false, false, false),
    Permissions.p("booking.staffCancel", "booking", #close, #command("propose:staffCancel"), true, false, true),
    Permissions.p("booking.waivePenalty", "folio", #waive, #command("propose:waivePenalty"), true, false, true),
    Permissions.p("booking.refundOutsidePolicy", "payment", #reverse, #command("propose:refundOutsidePolicy"), true, false, true),
    Permissions.p("booking.compNights", "folio", #waive, #command("propose:compNights"), true, false, true),
    Permissions.p("booking.priceOverride", "folio", #update, #command("propose:priceOverride"), true, false, true),
    Permissions.p("booking.editGuestRecord", "guest", #update, #command("propose:editGuestRecord"), false, true, true),
    Permissions.p("booking.voidCharge", "folio", #reverse, #command("propose:voidCharge"), true, false, true),
    // a credit note amends an issued invoice and sends money back; a refund paid at the desk records money
    // that left the till: each by one person, approved by another
    Permissions.p("booking.creditNote", "invoice", #reverse, #command("propose:issueCreditNote"), true, false, true),
    Permissions.p("booking.refundAtDesk", "payment", #reverse, #command("propose:refundAtDesk"), true, false, true),
    // the codes the tax authority's documents carry: the owner's, like the rest of the setup
    Permissions.p("setup.taxEta", "taxRule", #update, #command("setTaxEta"), false, false, false),
    Permissions.p("setup.etaProfile", "property", #update, #command("setEtaProfile"), false, false, false),
    // a booking taken for a guest on the phone or at the desk: the same stay, price and nights a guest
    // books online, and no money moves until the guest pays at the desk
    Permissions.p("desk.book", "booking", #create, #command("bookByStaff"), false, false, false),
    // a guest in house given another free room of the same type: no price changes, the room left goes dirty
    Permissions.p("desk.moveRoom", "room", #update, #command("moveRoom"), false, false, false),
    // rate products: a company's account and who each plan is sold to are revenue's, as the rates are
    Permissions.p("rates.company", "company", #update, #command("upsertCompany"), false, false, false),
    Permissions.p("rates.planAccess", "ratePlan", #update, #command("setPlanAccess"), false, false, false),
    Permissions.p("rates.promo", "promo", #update, #command("upsertPromo"), false, false, false),
    // a booking taken under a company's or a promotion's code: as `desk.book`, at the rate the code opens
    Permissions.p("desk.bookCoded", "booking", #create, #command("bookByStaffCoded"), false, false, false),
    // group blocks: taking rooms out of sale for a group is revenue's; picking its guests up is the desk's
    Permissions.p("rates.block", "block", #update, #command("upsertBlock"), false, false, false),
    Permissions.p("rates.releaseBlock", "block", #update, #command("releaseBlock"), false, false, false),
    Permissions.p("desk.pickUp", "booking", #create, #command("pickUpFromBlock"), false, false, false),
    // the rules the hotel's books are kept under move by the owner alone, one epoch at a time
    Permissions.p("setup.rules", "property", #update, #command("adoptRules"), false, false, false),
  ] };

  /// The staff command names the catalogue is checked against, and the four-eyes acts.
  public let STAFF_COMMANDS : [Text] = [
    "configureProperty", "upsertRoomType", "upsertRoom", "upsertRatePlan", "upsertTaxRule", "setGuestDataKey", "setHotelClock", "setNights", "setNightsMany",
    "checkIn", "checkOut", "settleAtDesk", "beginIdUpload", "putIdChunk", "fileIdDocument", "openAudit", "advanceAudit", "closeDay", "grantRole", "revokeRole",
    "approve", "reject", "markRoom", "takeRoomOutOfOrder", "returnRoomToService",
    "upsertExtra", "postCharge", "addPayer", "routeLines", "settleShare", "issueInvoice", "setTaxEta", "setEtaProfile", "bookByStaff", "moveRoom",
    "upsertCompany", "setPlanAccess", "bookByStaffCoded", "upsertPromo", "upsertBlock", "releaseBlock", "pickUpFromBlock",
    "setPlanInclusions", "setPlanDeposit", "requireCardOnFile",
    "setMailRelay", "authoriseMailCredential", "setMailOn", "attachMailByStaff", "recordMailOutcome", "recordMailTest",
    "adoptRules",
    "propose:staffCancel", "propose:waivePenalty", "propose:refundOutsidePolicy", "propose:compNights",
    "propose:priceOverride", "propose:editGuestRecord", "propose:voidCharge", "propose:issueCreditNote", "propose:refundAtDesk",
  ];

  /// Commands a guest or the system issues. Not staff authority, so not in the catalogue.
  public let NON_STAFF_COMMANDS : [Text] = [
    "releaseExpiredHolds", "placeHold", "releaseHold", "confirmHold", "modifyBooking", "cancelBooking",
    "claimBooking", "joinWaitlist", "leaveWaitlist", "recordGatewayOutcome", "bootstrapOwner", "propose", "placeHoldCoded",
    "confirmHoldOnFile", "putCardOnFile", "recordChargeOutcome", "recordCardForgotten",
    "attachMail",
  ];

  /// Which roles hold a permission. The owner holds every one but the mail relay's own (`mail.`), which
  /// only the mailer's key holds.
  public func rolesFor(permission : Text) : [E.Role] {
    if (Text.startsWith(permission, #text "mail.")) return [#mailer];
    if (Text.startsWith(permission, #text "setup.") or Text.startsWith(permission, #text "roles.") or Text.startsWith(permission, #text "proposal.")) return [#owner];
    if (Text.startsWith(permission, #text "rates.")) return [#owner, #revenue];
    if (Text.startsWith(permission, #text "desk.")) return [#owner, #frontDesk];
    if (Text.startsWith(permission, #text "audit.")) return [#owner, #auditor, #frontDesk];
    if (Text.startsWith(permission, #text "hk.")) return [#owner, #frontDesk, #housekeeping];
    if (Text.startsWith(permission, #text "booking.")) return [#owner, #frontDesk, #revenue];
    [#owner]
  };

  public func may(s : St.Stores, who : Principal, permission : Text) : Bool {
    for (r in rolesFor(permission).vals()) { if (St.holdsRole(s, who, r)) return true };
    false
  };

  public func require(s : St.Stores, who : Principal, command : Text) : ?Rf.Refusal {
    switch (Permissions.byCommand(catalogue(), command)) {
      case null ?#notAuthorised({ permission = command });
      case (?p) { if (may(s, who, p.id)) null else ?#notAuthorised({ permission = p.id }) };
    }
  };

  // ── the roster ──────────────────────────────────────────────────────────────

  /// The first owner, and only while there is nobody: a contract just installed has no roster to ask.
  public func bootstrapOwner(c : St.Ctx, subject : Principal) : Out {
    if (St.hasAnyGrant(c.s)) return #err(#alreadyOwned);
    if (Principal.isAnonymous(subject)) return #err(#notTheOwner);
    writeGrant(c, subject, #owner)
  };

  func writeGrant(c : St.Ctx, subject : Principal, role : E.Role) : Out {
    let id = c.s.nextGrantId;
    c.s.nextGrantId += 1;
    RowStore.put<R.Grant>(c.s.grants, R.grant, id, { subject; role; active = true; lastBlock = c.block });
    #ok([id])
  };

  public func grantRole(c : St.Ctx, staff : Principal, subject : Principal, role : E.Role) : Out {
    switch (require(c.s, staff, "grantRole")) { case (?r) return #err(r); case null {} };
    if (Principal.isAnonymous(subject)) return #err(#invalid({ what = "A role goes to a signed-in person." }));
    // the mailer is the relay's key, made one by connecting the relay (setMailRelay), never by hand
    if (role == #mailer) return #err(#invalid({ what = "The mail relay is connected under Guest email." }));
    if (St.holdsRole(c.s, subject, role)) return #err(#roleHeld);
    writeGrant(c, subject, role)
  };

  /// The mail relay's key made the hotel's mailer (Mail.setRelay, once its checks have passed): the grant's
  /// id, the one already active if the key holds the role.
  public func holdMailerFor(c : St.Ctx, mailer : Principal) : Nat {
    let k = R.subjectRoleKey(mailer, #mailer);
    switch (RowStore.page<R.Grant>(c.s.grants, R.grant, "active_by_subject", k, k, null, 1)) {
      case (#ok p) { if (p.rows.size() > 0) return p.rows[0].0 };
      case (#err _) {};
    };
    switch (writeGrant(c, mailer, #mailer)) { case (#ok ids) ids[0]; case (#err _) 0 }
  };

  /// A mailer grant ended, when another relay's key replaces it.
  public func endGrant(c : St.Ctx, grantId : Nat) {
    switch (RowStore.get<R.Grant>(c.s.grants, R.grant, grantId)) {
      case (?g) { if (g.active) RowStore.put<R.Grant>(c.s.grants, R.grant, grantId, { g with active = false; lastBlock = c.block }) };
      case null {};
    };
  };

  public func revokeRole(c : St.Ctx, staff : Principal, subject : Principal, role : E.Role) : Out {
    switch (require(c.s, staff, "revokeRole")) { case (?r) return #err(r); case null {} };
    switch (St.hotelClock(c.x)) {
      // the automatic audit's grant is ended by turning the automatic audit off, never left half-on
      case (?{ auto = true; runner = ?r }) { if (r == subject and role == #auditor) return #err(#invalid({ what = "The automatic night audit holds this role; turn it off under Night audit." })) };
      case _ {};
    };
    let k = R.subjectRoleKey(subject, role);
    let rows = switch (RowStore.page<R.Grant>(c.s.grants, R.grant, "active_by_subject", k, k, null, 1)) { case (#ok p) p.rows; case (#err _) [] };
    if (rows.size() == 0) return #err(#roleNotHeld);
    if (role == #owner) {
      // the last owner cannot be removed: a hotel with no owner has nobody who can grant anything
      if (countOwners(c.s) <= 1) return #err(#invalid({ what = "The last owner cannot be removed." }));
    };
    let (gid, g) = rows[0];
    RowStore.put<R.Grant>(c.s.grants, R.grant, gid, { g with active = false; lastBlock = c.block });
    #ok([gid])
  };

  /// The automatic night audit's authority, given by the clock command (HotelClock.set) once its checks
  /// have passed: the auditor role for the contract's own principal. Returns the grant id, 0 if held.
  public func holdAuditFor(c : St.Ctx, runner : Principal) : Nat {
    if (St.holdsRole(c.s, runner, #auditor)) return 0;
    switch (writeGrant(c, runner, #auditor)) { case (#ok ids) ids[0]; case (#err _) 0 }
  };

  /// Ends that authority. A runner holds at most one active auditor grant (grantRole refuses a second).
  public func endAuditFor(c : St.Ctx, runner : Principal) {
    let k = R.subjectRoleKey(runner, #auditor);
    let rows = switch (RowStore.page<R.Grant>(c.s.grants, R.grant, "active_by_subject", k, k, null, 1)) { case (#ok p) p.rows; case (#err _) [] };
    for ((gid, g) in rows.vals()) RowStore.put<R.Grant>(c.s.grants, R.grant, gid, { g with active = false; lastBlock = c.block });
  };

  func countOwners(s : St.Stores) : Nat {
    var n = 0;
    let pg = RowStore.pageById<R.Grant>(s.grants, R.grant, 1, St.MAX_ID, null, 1_000);
    for ((_, g) in pg.rows.vals()) { if (g.active and g.role == #owner) n += 1 };
    n
  };

  // ── four eyes ───────────────────────────────────────────────────────────────

  /// How long a proposal waits for its second person: seven real days, in heights.
  func proposalTtl(s : St.Stores) : Nat {
    switch (St.property(s)) { case (?p) p.heightsPerRealMinute * 60 * 24 * 7; case null 0 }
  };

  func permissionOf(a : Cmd.DualAct) : Text { "propose:" # Cmd.dualActName(a) };

  /// What a permission guards, by its place in the catalogue ("" past its end): the oracle reads a
  /// proposal's permission back through it.
  public func guardOf(permission : Nat) : Text {
    let cat = catalogue();
    if (permission >= cat.size()) return "";
    switch (cat[permission].guards) { case (#command c) c; case _ "" }
  };

  func permissionIndex(name : Text) : Nat {
    let cat = catalogue();
    var i = 0;
    while (i < cat.size()) {
      switch (cat[i].guards) { case (#command c) { if (c == name) return i }; case _ {} };
      i += 1;
    };
    0
  };

  /// Is this act one that could execute now? Checked when it is proposed and again when it is approved.
  func checkAct(c : St.Ctx, a : Cmd.DualAct) : ?Rf.Refusal {
    let id = Cmd.dualActBooking(a);
    let ?b = St.booking(c.s, id) else return ?#noSuchBooking({ id });
    let liability : Nat = if (b.charged >= b.credited) b.charged - b.credited else 0;
    switch a {
      case (#staffCancel _) { if (b.status != #confirmed) return ?#bookingState({ id; state = E.bookingStatusText(b.status); wanted = "confirmed" }) };
      case (#waivePenalty _) { if (b.status != #cancelled and b.status != #noShow) return ?#bookingState({ id; state = E.bookingStatusText(b.status); wanted = "cancelled or no-show" }); if (liability == 0) return ?#invalid({ what = "There is no fee to waive." }) };
      case (#refundOutsidePolicy { amount }) { if (amount == 0 or amount > b.paid) return ?#invalid({ what = "A refund is between 1 and what was paid, " # Nat.toText(b.paid) # "." }) };
      case (#compNights _) { if (liability == 0) return ?#invalid({ what = "Nothing is left to comp." }) };
      case (#priceOverride { newTotal }) { if (newTotal >= liability) return ?#invalid({ what = "An override lowers the price below " # Nat.toText(liability) # "." }) };
      case (#editGuestRecord { guestName }) { let n = Text.encodeUtf8(guestName).size(); if (n == 0 or n > Res.MAX_NAME_BYTES) return ?#tooLong({ what = "guest name"; max = Res.MAX_NAME_BYTES }) };
      case (#voidCharge { lineId }) { switch (Bill.checkVoid(c, id, lineId)) { case (#err r) return ?r; case (#ok _) {} } };
      case (#issueCreditNote { invoice; lineIds; amounts }) { switch (CN.check(c, id, invoice, lineIds, amounts)) { case (#err r) return ?r; case (#ok _) {} } };
      case (#refundAtDesk { paymentId; reference }) { switch (CN.checkDeskRefund(c, id, paymentId, reference)) { case (?r) return ?r; case null {} } };
    };
    null
  };

  public func propose(c : St.Ctx, staff : Principal, act : Cmd.DualAct, justification : Text) : Out {
    let perm = permissionOf(act);
    switch (require(c.s, staff, perm)) { case (?r) return #err(r); case null {} };
    let j = Text.encodeUtf8(justification).size();
    if (j == 0) return #err(#invalid({ what = "Say why, for the person who will approve it." }));
    if (j > AuthTypes.MAX_JUSTIFICATION_BYTES) return #err(#tooLong({ what = "reason"; max = AuthTypes.MAX_JUSTIFICATION_BYTES }));
    switch (checkAct(c, act)) { case (?r) return #err(r); case null {} };
    let bytes = Enc.actBytes(act);
    let hex = C.hex(bytes);
    switch (TA.fits(c.s.arena, [hex], 4_096)) { case (?why) return #err(#invalid({ what = why })); case null {} };
    let id = c.s.nextProposalId;
    c.s.nextProposalId += 1;
    RowStore.put<R.Proposal>(c.s.proposals, R.proposal, id, {
      maker = staff; permission = permissionIndex(perm); proposedBlock = c.block; expiresAt = c.height + proposalTtl(c.s);
      status = #awaiting; checker = null; resolvedBlock = 0; commandHash = Enc.actHash(bytes); act = TA.put(c.s.arena, hex);
    });
    #ok([id])
  };

  func loadAct(c : St.Ctx, p : R.Proposal) : { #ok : Cmd.DualAct; #err : Rf.Refusal } {
    let ?bytes = C.fromHex(TA.get(c.s.arena, p.act)) else return #err(#hashMismatch);
    // the approver approves the stored act: its hash is re-derived from its bytes, not compared field to field
    if (Enc.actHash(bytes) != p.commandHash) return #err(#hashMismatch);
    switch (Enc.readActBytes(bytes)) { case (?a) #ok(a); case null #err(#hashMismatch) }
  };

  public func approve(c : St.Ctx, staff : Principal, id : Nat) : Out {
    switch (require(c.s, staff, "approve")) { case (?r) return #err(r); case null {} };
    let ?p = St.proposal(c.s, id) else return #err(#noSuchProposal({ id }));
    if (p.status != #awaiting) return #err(#proposalState({ id; state = E.proposalStatusText(p.status) }));
    if (p.expiresAt <= c.height) return #err(#proposalExpired({ id }));
    if (p.maker == staff) return #err(#fourEyes({ permission = catalogue()[p.permission].id }));
    let act = switch (loadAct(c, p)) { case (#ok a) a; case (#err r) return #err(r) };
    switch (checkAct(c, act)) { case (?r) return #err(r); case null {} };
    // the act runs in this step; if it refuses, the approval is refused with it and nothing is written
    let out = execute(c, act, id);
    switch out {
      case (#ok _) RowStore.put<R.Proposal>(c.s.proposals, R.proposal, id, { p with status = #executed; checker = ?staff; resolvedBlock = c.block });
      case (#err _) {};
    };
    out
  };

  public func reject(c : St.Ctx, staff : Principal, id : Nat, reason : Text) : Out {
    switch (require(c.s, staff, "reject")) { case (?r) return #err(r); case null {} };
    let ?p = St.proposal(c.s, id) else return #err(#noSuchProposal({ id }));
    if (p.status != #awaiting) return #err(#proposalState({ id; state = E.proposalStatusText(p.status) }));
    if (Text.encodeUtf8(reason).size() == 0) return #err(#invalid({ what = "Say why it is rejected." }));
    RowStore.put<R.Proposal>(c.s.proposals, R.proposal, id, { p with status = #rejected; checker = ?staff; resolvedBlock = c.block });
    #ok([id])
  };

  /// `proposal` is the approved proposal's id: a document an act issues names it, and through it its maker
  /// and its approver.
  func execute(c : St.Ctx, act : Cmd.DualAct, proposal : Nat) : Out {
    switch act {
      case (#staffCancel { bookingId; waivePenalty }) Res.staffCancel(c, bookingId, waivePenalty);
      case (#waivePenalty { bookingId }) {
        let ?b = St.booking(c.s, bookingId) else return #err(#noSuchBooking({ id = bookingId }));
        Res.creditBy(c, bookingId, if (b.charged >= b.credited) b.charged - b.credited else 0)
      };
      case (#refundOutsidePolicy { bookingId; amount }) Res.creditBy(c, bookingId, amount);
      case (#compNights { bookingId }) {
        let ?b = St.booking(c.s, bookingId) else return #err(#noSuchBooking({ id = bookingId }));
        Res.creditBy(c, bookingId, if (b.charged >= b.credited) b.charged - b.credited else 0)
      };
      case (#priceOverride { bookingId; newTotal }) {
        let ?b = St.booking(c.s, bookingId) else return #err(#noSuchBooking({ id = bookingId }));
        let liability : Nat = if (b.charged >= b.credited) b.charged - b.credited else 0;
        Res.creditBy(c, bookingId, liability - newTotal)
      };
      case (#editGuestRecord { bookingId; guestName }) Res.editGuestName(c, bookingId, guestName);
      case (#voidCharge { bookingId; lineId }) Bill.voidCharge(c, bookingId, lineId);
      case (#issueCreditNote { bookingId; invoice; lineIds; amounts }) CN.issue(c, bookingId, invoice, lineIds, amounts, proposal);
      case (#refundAtDesk { bookingId; paymentId; method; reference }) CN.refundAtDesk(c, bookingId, paymentId, method, reference, proposal);
    }
  };
}
