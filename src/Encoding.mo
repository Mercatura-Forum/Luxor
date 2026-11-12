/// Encoding.mo - a command's canonical bytes, version 1, frozen.
///
/// A tag is written with the estate's escape (Mentat `putTag`): below 255 one byte; below 510 the
/// byte 0xFF and an offset; otherwise 0xFF 0xFF and a two-byte offset from 510. Luxor's tags start at
/// 1024, so every one of them takes the wide form, and an enterprise command written into the same
/// log later keeps its own one-byte tags. The escape is transcribed here with the same constants; the
/// battery checks the bytes of a tag at each boundary.
///
/// Reading is total: a tag nobody assigned, a byte an enum does not know, or trailing bytes after a
/// command are all `null`, never a guess.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Blob "mo:core/Blob";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";

import C "mo:kernel/codec/Canonical";
import KE "mo:kernel/domain/Encoding";

import Cmd "Command";
import E "Enums";

module {

  public type Command = Cmd.Command;

  public let DOMAIN_PREFIX : Text = "LUXOR-CMD";

  public let TAG_ESCAPE : Nat = 255;
  public let TAG_ESCAPE_WIDE : Nat = 510;

  public func putTag(w : C.Writer, tag : Nat) {
    if (tag < TAG_ESCAPE) { w.byte(Nat8.fromNat(tag)) }
    else if (tag < TAG_ESCAPE_WIDE) { w.byte(255); w.byte(Nat8.fromNat(tag - TAG_ESCAPE)) }
    else {
      let off = tag - TAG_ESCAPE_WIDE;
      assert (off < 65_536);
      w.byte(255); w.byte(255); w.byte(Nat8.fromNat(off / 256)); w.byte(Nat8.fromNat(off % 256));
    };
  };

  public func getTag(r : C.Reader) : ?Nat {
    let ?first = r.byte() else return null;
    let n = Nat8.toNat(first);
    if (n < TAG_ESCAPE) return ?n;
    let ?second = r.byte() else return null;
    let m = Nat8.toNat(second);
    if (m < TAG_ESCAPE) return ?(TAG_ESCAPE + m);
    let ?hi = r.byte() else return null;
    let ?lo = r.byte() else return null;
    ?(TAG_ESCAPE_WIDE + Nat8.toNat(hi) * 256 + Nat8.toNat(lo))
  };

  // ── field helpers ───────────────────────────────────────────────────────────

  func stay(w : C.Writer, s : Cmd.Stay) {
    w.nat(s.roomTypeId); w.nat(s.planId); w.nat(s.arrival); w.nat(s.nights); w.nat(s.rooms); w.nat(s.adults); w.nat(s.children);
  };
  func readStay(r : C.Reader) : ?Cmd.Stay {
    let ?roomTypeId = r.nat() else return null;
    let ?planId = r.nat() else return null;
    let ?arrival = r.nat() else return null;
    let ?nights = r.nat() else return null;
    let ?rooms = r.nat() else return null;
    let ?adults = r.nat() else return null;
    let ?children = r.nat() else return null;
    ?{ roomTypeId; planId; arrival; nights; rooms; adults; children }
  };

  func auth(w : C.Writer, a : Cmd.AuthFacts) { w.nat(a.authId); w.nat(a.amount); w.text(a.currency); w.nat(a.merchantRef) };
  func readAuth(r : C.Reader) : ?Cmd.AuthFacts {
    let ?authId = r.nat() else return null;
    let ?amount = r.nat() else return null;
    let ?currency = r.text() else return null;
    let ?merchantRef = r.nat() else return null;
    ?{ authId; amount; currency; merchantRef }
  };

  func guestActor(w : C.Writer, g : Cmd.GuestActor) {
    switch g { case (#account p) { w.byte(1); w.principal(p) }; case (#manageKey) { w.byte(2) } };
  };
  func readGuestActor(r : C.Reader) : ?Cmd.GuestActor {
    switch (r.byte()) {
      case (?1) { let ?p = r.principal() else return null; ?#account(p) };
      case (?2) ?#manageKey;
      case _ null;
    }
  };

  func optNatR(r : C.Reader) : ??Nat { r.optNat() };
  func optBoolR(r : C.Reader) : ??Bool { r.optBool() };

  func roomTypeFacts(w : C.Writer, f : Cmd.RoomTypeFacts) {
    w.text(f.code); w.text(f.nameEn); w.text(f.nameAr); w.text(f.descEn); w.text(f.descAr);
    w.nat(f.sizeSqm); w.nat(f.maxAdults); w.nat(f.maxChildren); w.nat(f.maxOccupancy);
    w.nat8(E.bedKindByte(f.bedKind)); w.nat(f.bedCount); w.nat(f.amenities); w.text(f.photos); w.nat(f.rank); w.bool(f.active);
  };
  func readRoomTypeFacts(r : C.Reader) : ?Cmd.RoomTypeFacts {
    let ?code = r.text() else return null;
    let ?nameEn = r.text() else return null;
    let ?nameAr = r.text() else return null;
    let ?descEn = r.text() else return null;
    let ?descAr = r.text() else return null;
    let ?sizeSqm = r.nat() else return null;
    let ?maxAdults = r.nat() else return null;
    let ?maxChildren = r.nat() else return null;
    let ?maxOccupancy = r.nat() else return null;
    let ?bb = r.nat8() else return null;
    let ?bedKind = E.bedKindOf(bb) else return null;
    let ?bedCount = r.nat() else return null;
    let ?amenities = r.nat() else return null;
    let ?photos = r.text() else return null;
    let ?rank = r.nat() else return null;
    let ?active = r.bool() else return null;
    ?{ code; nameEn; nameAr; descEn; descAr; sizeSqm; maxAdults; maxChildren; maxOccupancy; bedKind; bedCount; amenities; photos; rank; active }
  };

  func planFacts(w : C.Writer, f : Cmd.RatePlanFacts) {
    w.text(f.code); w.text(f.nameEn); w.text(f.nameAr); w.nat8(E.planKindByte(f.kind)); w.nat(f.discountBps);
    w.bool(f.refundable); w.nat(f.freeCancelDaysBefore); w.nat(f.penaltyNights); w.nat8(E.guaranteeByte(f.guarantee));
    w.bool(f.modifiable); w.bool(f.active);
  };
  func readPlanFacts(r : C.Reader) : ?Cmd.RatePlanFacts {
    let ?code = r.text() else return null;
    let ?nameEn = r.text() else return null;
    let ?nameAr = r.text() else return null;
    let ?kb = r.nat8() else return null;
    let ?kind = E.planKindOf(kb) else return null;
    let ?discountBps = r.nat() else return null;
    let ?refundable = r.bool() else return null;
    let ?freeCancelDaysBefore = r.nat() else return null;
    let ?penaltyNights = r.nat() else return null;
    let ?gb = r.nat8() else return null;
    let ?guarantee = E.guaranteeOf(gb) else return null;
    let ?modifiable = r.bool() else return null;
    let ?active = r.bool() else return null;
    ?{ code; nameEn; nameAr; kind; discountBps; refundable; freeCancelDaysBefore; penaltyNights; guarantee; modifiable; active }
  };

  func taxFacts(w : C.Writer, f : Cmd.TaxRuleFacts) {
    w.text(f.code); w.text(f.nameEn); w.text(f.nameAr); w.nat8(E.taxKindByte(f.kind)); w.nat(f.bps); w.nat(f.amount);
    w.nat8(E.taxBaseByte(f.base)); w.nat(f.rank); w.bool(f.active);
  };
  func readTaxFacts(r : C.Reader) : ?Cmd.TaxRuleFacts {
    let ?code = r.text() else return null;
    let ?nameEn = r.text() else return null;
    let ?nameAr = r.text() else return null;
    let ?kb = r.nat8() else return null;
    let ?kind = E.taxKindOf(kb) else return null;
    let ?bps = r.nat() else return null;
    let ?amount = r.nat() else return null;
    let ?bb = r.nat8() else return null;
    let ?base = E.taxBaseOf(bb) else return null;
    let ?rank = r.nat() else return null;
    let ?active = r.bool() else return null;
    ?{ code; nameEn; nameAr; kind; bps; amount; base; rank; active }
  };

  func dualAct(w : C.Writer, a : Cmd.DualAct) {
    switch a {
      case (#staffCancel x) { w.byte(1); w.nat(x.bookingId); w.bool(x.waivePenalty) };
      case (#waivePenalty x) { w.byte(2); w.nat(x.bookingId) };
      case (#refundOutsidePolicy x) { w.byte(3); w.nat(x.bookingId); w.nat(x.amount) };
      case (#compNights x) { w.byte(4); w.nat(x.bookingId) };
      case (#priceOverride x) { w.byte(5); w.nat(x.bookingId); w.nat(x.newTotal) };
      case (#editGuestRecord x) { w.byte(6); w.nat(x.bookingId); w.text(x.guestName) };
      case (#voidCharge x) { w.byte(7); w.nat(x.bookingId); w.nat(x.lineId) };
      case (#issueCreditNote x) { w.byte(8); w.nat(x.bookingId); w.nat(x.invoice); w.nats(x.lineIds); w.nats(x.amounts) };
      case (#refundAtDesk x) { w.byte(9); w.nat(x.bookingId); w.nat(x.paymentId); w.nat8(E.deskMethodByte(x.method)); w.text(x.reference) };
    }
  };
  func readDualAct(r : C.Reader) : ?Cmd.DualAct {
    switch (r.byte()) {
      case (?1) { let ?bookingId = r.nat() else return null; let ?waivePenalty = r.bool() else return null; ?#staffCancel({ bookingId; waivePenalty }) };
      case (?2) { let ?bookingId = r.nat() else return null; ?#waivePenalty({ bookingId }) };
      case (?3) { let ?bookingId = r.nat() else return null; let ?amount = r.nat() else return null; ?#refundOutsidePolicy({ bookingId; amount }) };
      case (?4) { let ?bookingId = r.nat() else return null; ?#compNights({ bookingId }) };
      case (?5) { let ?bookingId = r.nat() else return null; let ?newTotal = r.nat() else return null; ?#priceOverride({ bookingId; newTotal }) };
      case (?6) { let ?bookingId = r.nat() else return null; let ?guestName = r.text() else return null; ?#editGuestRecord({ bookingId; guestName }) };
      case (?7) { let ?bookingId = r.nat() else return null; let ?lineId = r.nat() else return null; ?#voidCharge({ bookingId; lineId }) };
      case (?8) {
        let ?bookingId = r.nat() else return null; let ?invoice = r.nat() else return null;
        let ?lineIds = r.nats() else return null; let ?amounts = r.nats() else return null;
        ?#issueCreditNote({ bookingId; invoice; lineIds; amounts })
      };
      case (?9) {
        let ?bookingId = r.nat() else return null; let ?paymentId = r.nat() else return null;
        let ?mb = r.nat8() else return null; let ?method = E.deskMethodOf(mb) else return null; let ?reference = r.text() else return null;
        ?#refundAtDesk({ bookingId; paymentId; method; reference })
      };
      case _ null;
    }
  };

  // ── the edits of a many-night save ──────────────────────────────────────────

  func nightsEdit(w : C.Writer, e : Cmd.NightsEdit) {
    w.nat(e.roomTypeId); w.nat(e.fromDay); w.nat(e.toDay); w.nat(e.weekdays);
    w.optNat(e.allotment); w.optNat(e.bar); w.optNat(e.minStay); w.optNat(e.maxStay);
    w.optBool(e.closedToArrival); w.optBool(e.closedToDeparture); w.optBool(e.stopSell);
  };
  func readNightsEdit(r : C.Reader) : ?Cmd.NightsEdit {
    let ?roomTypeId = r.nat() else return null;
    let ?fromDay = r.nat() else return null;
    let ?toDay = r.nat() else return null;
    let ?weekdays = r.nat() else return null;
    let ?allotment = optNatR(r) else return null;
    let ?bar = optNatR(r) else return null;
    let ?minStay = optNatR(r) else return null;
    let ?maxStay = optNatR(r) else return null;
    let ?closedToArrival = optBoolR(r) else return null;
    let ?closedToDeparture = optBoolR(r) else return null;
    let ?stopSell = optBoolR(r) else return null;
    ?{ roomTypeId; fromDay; toDay; weekdays; allotment; bar; minStay; maxStay; closedToArrival; closedToDeparture; stopSell }
  };

  /// The list: a two-byte count, then each edit, and after it 0 (no percentage) or 1, the direction
  /// (1 up, 0 down) and the basis points.
  public func manyEdits(w : C.Writer, edits : [Cmd.ManyEdit]) {
    w.len16(edits.size());
    for (m in edits.vals()) {
      nightsEdit(w, m.edit);
      switch (m.adjust) { case null w.byte(0); case (?a) { w.byte(1); w.bool(a.up); w.nat(a.bps) } };
    };
  };
  public func readManyEdits(r : C.Reader) : ?[Cmd.ManyEdit] {
    let ?n = r.len16() else return null;
    let out = List.empty<Cmd.ManyEdit>();
    var i = 0;
    while (i < n) {
      let ?edit = readNightsEdit(r) else return null;
      let adjust : ?Cmd.RateAdjust = switch (r.byte()) {
        case (?0) null;
        case (?1) { let ?up = r.bool() else return null; let ?bps = r.nat() else return null; ?{ up; bps } };
        case _ return null;
      };
      List.add(out, { edit; adjust });
      i += 1;
    };
    ?List.toArray(out)
  };
  /// The edits as a browser sends them: the hex of `manyEdits`, the whole of it and nothing after.
  public func readManyEditsHex(hex : Text) : ?[Cmd.ManyEdit] {
    let ?b = C.fromHex(hex) else return null;
    let r = C.Reader(Blob.toArray(b));
    let edits = readManyEdits(r);
    if (r.atEnd()) edits else null
  };

  /// A proposed act's canonical bytes: what a proposal records and an approval re-hashes.
  public func actBytes(a : Cmd.DualAct) : Blob { let w = C.Writer(); dualAct(w, a); w.toBlob() };
  public func readActBytes(b : Blob) : ?Cmd.DualAct {
    let r = C.Reader(Blob.toArray(b));
    let a = readDualAct(r);
    if (r.atEnd()) a else null
  };
  public let ACT_DOMAIN : Text = "LUXOR-DUAL-ACT-v1";
  public func actHash(b : Blob) : Blob { C.hashWithDomainBlob(ACT_DOMAIN, b) };

  // ── version 1 ───────────────────────────────────────────────────────────────

  func tag(w : C.Writer, i : Nat) { putTag(w, Cmd.LUXOR_BASE + i) };

  func writeV1(w : C.Writer, c : Command) : Bool {
    switch c {
      case (#configureProperty { staff; facts = f }) {
        tag(w, 0); w.principal(staff);
        w.text(f.currency); w.nat(f.minorUnits); w.text(f.nameEn); w.text(f.nameAr); w.text(f.checkInText); w.text(f.checkOutText);
        w.nat(f.holdTtlHeights); w.nat(f.heightsPerRealMinute); w.nat(f.maxStayNights); w.nat(f.horizonDays);
        w.nat(f.maxRoomsPerBooking); w.nat(f.idRetentionDays);
      };
      case (#upsertRoomType { staff; id; facts }) { tag(w, 1); w.principal(staff); w.nat(id); roomTypeFacts(w, facts) };
      case (#upsertRoom { staff; id; roomTypeId; number; outOfOrder }) {
        tag(w, 2); w.principal(staff); w.nat(id); w.nat(roomTypeId); w.text(number); w.bool(outOfOrder);
      };
      case (#upsertRatePlan { staff; id; facts }) { tag(w, 3); w.principal(staff); w.nat(id); planFacts(w, facts) };
      case (#upsertTaxRule { staff; id; facts }) { tag(w, 4); w.principal(staff); w.nat(id); taxFacts(w, facts) };
      case (#setNights { staff; edit = e }) { tag(w, 5); w.principal(staff); nightsEdit(w, e) };
      case (#releaseExpiredHolds { limit }) { tag(w, 6); w.nat(limit) };
      case (#placeHold { owner; stay = s; quoteHash; key }) { tag(w, 7); w.principal(owner); stay(w, s); w.blob(quoteHash); w.blob(key) };
      case (#releaseHold { owner; holdId }) { tag(w, 8); w.principal(owner); w.nat(holdId) };
      case (#confirmHold x) {
        tag(w, 9); w.principal(x.owner); w.nat(x.holdId); w.text(x.guestName); w.text(x.guestEmail); w.text(x.note);
        w.blob(x.manageKey); w.optPrincipal(x.account); auth(w, x.auth);
      };
      case (#modifyBooking x) {
        tag(w, 10); guestActor(w, x.by); w.nat(x.bookingId); stay(w, x.stay); w.blob(x.quoteHash);
        switch (x.auth) { case null w.byte(0); case (?a) { w.byte(1); auth(w, a) } };
      };
      case (#cancelBooking { by; bookingId }) { tag(w, 11); guestActor(w, by); w.nat(bookingId) };
      case (#claimBooking { account; bookingId }) { tag(w, 12); w.principal(account); w.nat(bookingId) };
      case (#joinWaitlist { account; stay = s }) { tag(w, 13); w.principal(account); stay(w, s) };
      case (#leaveWaitlist { account; entryId }) { tag(w, 14); w.principal(account); w.nat(entryId) };
      case (#checkIn { staff; bookingId; roomIds }) { tag(w, 15); w.principal(staff); w.nat(bookingId); w.nats(roomIds) };
      case (#checkOut { staff; bookingId }) { tag(w, 16); w.principal(staff); w.nat(bookingId) };
      case (#recordGatewayOutcome { paymentId; ok }) { tag(w, 17); w.nat(paymentId); w.bool(ok) };
      case (#openAudit { staff; day }) { tag(w, 18); w.principal(staff); w.nat(day) };
      case (#advanceAudit { staff; day; limit }) { tag(w, 19); w.principal(staff); w.nat(day); w.nat(limit) };
      case (#closeDay { staff; day }) { tag(w, 20); w.principal(staff); w.nat(day) };
      case (#bootstrapOwner { subject }) { tag(w, 21); w.principal(subject) };
      case (#grantRole { staff; subject; role }) { tag(w, 22); w.principal(staff); w.principal(subject); w.nat8(E.roleByte(role)) };
      case (#revokeRole { staff; subject; role }) { tag(w, 23); w.principal(staff); w.principal(subject); w.nat8(E.roleByte(role)) };
      case (#propose { staff; act; justification }) { tag(w, 24); w.principal(staff); dualAct(w, act); w.text(justification) };
      case (#approve { staff; proposalId }) { tag(w, 25); w.principal(staff); w.nat(proposalId) };
      case (#reject { staff; proposalId; reason }) { tag(w, 26); w.principal(staff); w.nat(proposalId); w.text(reason) };
      case (#settleAtDesk { staff; bookingId; auth = a }) { tag(w, 27); w.principal(staff); w.nat(bookingId); auth(w, a) };
      case (#setGuestDataKey { staff; key }) { tag(w, 28); w.principal(staff); w.blob(key) };
      case (#beginIdUpload { staff; bookingId; size; chunkHashes }) { tag(w, 29); w.principal(staff); w.nat(bookingId); w.nat(size); w.texts(chunkHashes) };
      case (#putIdChunk { staff; blobId; index; bytes }) { tag(w, 30); w.principal(staff); w.text(blobId); w.nat(index); w.blob(bytes) };
      case (#fileIdDocument x) { tag(w, 31); w.principal(x.staff); w.nat(x.bookingId); w.text(x.blobId); w.text(x.plainHash); w.nat(x.plainSize); w.text(x.mime); w.text(x.fileKey) };
      case (#setNightsMany { staff; edits }) { tag(w, 32); w.principal(staff); manyEdits(w, edits) };
      case (#setHotelClock x) { tag(w, 33); w.principal(x.staff); w.text(x.zoneName); w.text(x.zoneRule); w.nat(x.auditAt); w.bool(x.auto); w.principal(x.runner) };
      case (#markRoom { staff; roomId; cleaning }) { tag(w, 34); w.principal(staff); w.nat(roomId); w.nat8(E.cleaningByte(cleaning)) };
      case (#takeRoomOutOfOrder { staff; roomId; reason; untilDay }) { tag(w, 35); w.principal(staff); w.nat(roomId); w.text(reason); w.nat(untilDay) };
      case (#returnRoomToService { staff; roomId }) { tag(w, 36); w.principal(staff); w.nat(roomId) };
      case (#upsertExtra { staff; id; facts = f }) {
        tag(w, 37); w.principal(staff); w.nat(id); w.text(f.code); w.text(f.nameEn); w.text(f.nameAr);
        w.nat8(E.extraCategoryByte(f.category)); w.nat(f.price); w.bool(f.taxed); w.bool(f.active);
      };
      case (#postCharge x) { tag(w, 38); w.principal(x.staff); w.nat(x.bookingId); w.nat(x.extraId); w.nat(x.quantity); w.nat(x.amount); w.nat(x.payerId) };
      case (#addPayer { staff; bookingId; name }) { tag(w, 39); w.principal(staff); w.nat(bookingId); w.text(name) };
      case (#routeLines { staff; bookingId; lineIds; payerId }) { tag(w, 40); w.principal(staff); w.nat(bookingId); w.nats(lineIds); w.nat(payerId) };
      case (#settleShare { staff; bookingId; payerId; auth = a }) { tag(w, 41); w.principal(staff); w.nat(bookingId); w.nat(payerId); auth(w, a) };
      case (#issueInvoice { staff; bookingId; payerId }) { tag(w, 42); w.principal(staff); w.nat(bookingId); w.nat(payerId) };
      case (#setTaxEta { staff; taxRuleId; taxType; subType }) { tag(w, 43); w.principal(staff); w.nat(taxRuleId); w.text(taxType); w.text(subType) };
      case (#setEtaProfile { staff; facts = f }) {
        tag(w, 44); w.principal(staff); w.text(f.issuerId); w.text(f.activityCode); w.text(f.branchId); w.text(f.country);
        w.text(f.governate); w.text(f.regionCity); w.text(f.street); w.text(f.buildingNumber);
      };
      case (#bookByStaff x) {
        tag(w, 45); w.principal(x.staff); w.byte(E.channelByte(x.channel)); stay(w, x.stay); w.blob(x.quoteHash);
        w.text(x.guestName); w.text(x.guestEmail); w.text(x.note); w.blob(x.manageKey); w.nats(x.roomIds);
      };
      case (#moveRoom { staff; bookingId; fromRoomId; toRoomId }) { tag(w, 46); w.principal(staff); w.nat(bookingId); w.nat(fromRoomId); w.nat(toRoomId) };
      case (#upsertCompany { staff; id; code; name; active }) { tag(w, 47); w.principal(staff); w.nat(id); w.text(code); w.text(name); w.bool(active) };
      case (#setPlanAccess { staff; planId; companyId; closed }) { tag(w, 48); w.principal(staff); w.nat(planId); w.nat(companyId); w.bool(closed) };
      case (#placeHoldCoded { owner; stay = s; quoteHash; key; code }) { tag(w, 49); w.principal(owner); stay(w, s); w.blob(quoteHash); w.blob(key); w.text(code) };
      case (#bookByStaffCoded x) {
        tag(w, 50); w.principal(x.staff); w.byte(E.channelByte(x.channel)); stay(w, x.stay); w.blob(x.quoteHash);
        w.text(x.guestName); w.text(x.guestEmail); w.text(x.note); w.blob(x.manageKey); w.nats(x.roomIds); w.text(x.code);
      };
      case (#upsertPromo x) {
        tag(w, 51); w.principal(x.staff); w.nat(x.id); w.text(x.code); w.text(x.name); w.nat(x.planId);
        w.nat(x.bookFrom); w.nat(x.bookUntil); w.nat(x.stayFrom); w.nat(x.stayUntil); w.nat(x.maxUses); w.bool(x.active);
      };
      case (#upsertBlock x) {
        tag(w, 52); w.principal(x.staff); w.nat(x.id); w.text(x.name); w.nat(x.companyId); w.nat(x.roomTypeId); w.nat(x.planId);
        w.nat(x.arrival); w.nat(x.nights); w.nat(x.rooms); w.nat(x.cutoff);
      };
      case (#releaseBlock { staff; id }) { tag(w, 53); w.principal(staff); w.nat(id) };
      case (#setPlanInclusions x) {
        tag(w, 55); w.principal(x.staff); w.nat(x.planId); w.len16(x.inclusions.size());
        for (i in x.inclusions.vals()) { w.nat(i.extraId); w.nat(i.quantity); w.nat8(E.rhythmByte(i.rhythm)); w.nat8(E.perByte(i.per)) };
      };
      case (#setPlanDeposit { staff; planId; depositBps }) { tag(w, 56); w.principal(staff); w.nat(planId); w.nat(depositBps) };
      case (#requireCardOnFile { staff }) { tag(w, 57); w.principal(staff) };
      case (#confirmHoldOnFile x) {
        tag(w, 58); w.principal(x.owner); w.nat(x.holdId); w.text(x.guestName); w.text(x.guestEmail); w.text(x.note);
        w.blob(x.manageKey); w.optPrincipal(x.account); auth(w, x.auth); w.nat(x.token);
      };
      case (#putCardOnFile x) { tag(w, 59); guestActor(w, x.by); w.nat(x.bookingId); auth(w, x.auth); w.nat(x.token) };
      case (#recordChargeOutcome x) { tag(w, 60); w.nat(x.paymentId); w.bool(x.ok); w.nat(x.authId) };
      case (#recordCardForgotten x) { tag(w, 61); w.nat(x.bookingId); w.bool(x.ok) };
      case (#setMailRelay x) { tag(w, 62); w.principal(x.staff); w.principal(x.mailer); w.blob(x.mailKey) };
      case (#authoriseMailCredential x) { tag(w, 63); w.principal(x.staff); w.blob(x.digest) };
      case (#setMailOn x) { tag(w, 64); w.principal(x.staff); w.bool(x.on) };
      case (#attachMail x) { tag(w, 65); guestActor(w, x.by); w.nat(x.bookingId); w.text(x.sealed); w.nat8(E.langByte(x.lang)) };
      case (#attachMailByStaff x) { tag(w, 66); w.principal(x.staff); w.nat(x.bookingId); w.text(x.sealed); w.nat8(E.langByte(x.lang)) };
      case (#recordMailOutcome x) { tag(w, 67); w.principal(x.mailer); w.nat(x.outboxId); w.bool(x.sent); w.nat8(E.mailFailureByte(x.failure)) };
      case (#recordMailTest x) { tag(w, 68); w.principal(x.mailer); w.blob(x.digest) };
      case (#adoptRules { staff; epoch }) { tag(w, 69); w.principal(staff); w.nat(epoch) };
      case (#pickUpFromBlock x) {
        tag(w, 54); w.principal(x.staff); w.nat(x.blockId); stay(w, x.stay); w.blob(x.quoteHash);
        w.text(x.guestName); w.text(x.guestEmail); w.text(x.note); w.blob(x.manageKey);
      };
    };
    true
  };

  func readV1(r : C.Reader) : ?Command {
    let ?t = getTag(r) else return null;
    if (t < Cmd.LUXOR_BASE) return null;
    let i : Nat = t - Cmd.LUXOR_BASE;
    let out : ?Command = switch i {
      case 0 {
        let ?staff = r.principal() else return null;
        let ?currency = r.text() else return null;
        let ?minorUnits = r.nat() else return null;
        let ?nameEn = r.text() else return null;
        let ?nameAr = r.text() else return null;
        let ?checkInText = r.text() else return null;
        let ?checkOutText = r.text() else return null;
        let ?holdTtlHeights = r.nat() else return null;
        let ?heightsPerRealMinute = r.nat() else return null;
        let ?maxStayNights = r.nat() else return null;
        let ?horizonDays = r.nat() else return null;
        let ?maxRoomsPerBooking = r.nat() else return null;
        let ?idRetentionDays = r.nat() else return null;
        ?#configureProperty({ staff; facts = { currency; minorUnits; nameEn; nameAr; checkInText; checkOutText; holdTtlHeights;
          heightsPerRealMinute; maxStayNights; horizonDays; maxRoomsPerBooking; idRetentionDays } })
      };
      case 1 { let ?staff = r.principal() else return null; let ?id = r.nat() else return null; let ?facts = readRoomTypeFacts(r) else return null; ?#upsertRoomType({ staff; id; facts }) };
      case 2 {
        let ?staff = r.principal() else return null;
        let ?id = r.nat() else return null;
        let ?roomTypeId = r.nat() else return null;
        let ?number = r.text() else return null;
        let ?outOfOrder = r.bool() else return null;
        ?#upsertRoom({ staff; id; roomTypeId; number; outOfOrder })
      };
      case 3 { let ?staff = r.principal() else return null; let ?id = r.nat() else return null; let ?facts = readPlanFacts(r) else return null; ?#upsertRatePlan({ staff; id; facts }) };
      case 4 { let ?staff = r.principal() else return null; let ?id = r.nat() else return null; let ?facts = readTaxFacts(r) else return null; ?#upsertTaxRule({ staff; id; facts }) };
      case 5 { let ?staff = r.principal() else return null; let ?edit = readNightsEdit(r) else return null; ?#setNights({ staff; edit }) };
      case 6 { let ?limit = r.nat() else return null; ?#releaseExpiredHolds({ limit }) };
      case 7 { let ?owner = r.principal() else return null; let ?s = readStay(r) else return null; let ?quoteHash = r.blob() else return null; let ?key = r.blob() else return null; ?#placeHold({ owner; stay = s; quoteHash; key }) };
      case 8 { let ?owner = r.principal() else return null; let ?holdId = r.nat() else return null; ?#releaseHold({ owner; holdId }) };
      case 9 {
        let ?owner = r.principal() else return null;
        let ?holdId = r.nat() else return null;
        let ?guestName = r.text() else return null;
        let ?guestEmail = r.text() else return null;
        let ?note = r.text() else return null;
        let ?manageKey = r.blob() else return null;
        let ?account = r.optPrincipal() else return null;
        let ?a = readAuth(r) else return null;
        ?#confirmHold({ owner; holdId; guestName; guestEmail; note; manageKey; account; auth = a })
      };
      case 10 {
        let ?by = readGuestActor(r) else return null;
        let ?bookingId = r.nat() else return null;
        let ?s = readStay(r) else return null;
        let ?quoteHash = r.blob() else return null;
        let a : ?Cmd.AuthFacts = switch (r.byte()) {
          case (?0) null;
          case (?1) { let ?x = readAuth(r) else return null; ?x };
          case _ return null;
        };
        ?#modifyBooking({ by; bookingId; stay = s; quoteHash; auth = a })
      };
      case 11 { let ?by = readGuestActor(r) else return null; let ?bookingId = r.nat() else return null; ?#cancelBooking({ by; bookingId }) };
      case 12 { let ?account = r.principal() else return null; let ?bookingId = r.nat() else return null; ?#claimBooking({ account; bookingId }) };
      case 13 { let ?account = r.principal() else return null; let ?s = readStay(r) else return null; ?#joinWaitlist({ account; stay = s }) };
      case 14 { let ?account = r.principal() else return null; let ?entryId = r.nat() else return null; ?#leaveWaitlist({ account; entryId }) };
      case 15 { let ?staff = r.principal() else return null; let ?bookingId = r.nat() else return null; let ?roomIds = r.nats() else return null; ?#checkIn({ staff; bookingId; roomIds }) };
      case 16 { let ?staff = r.principal() else return null; let ?bookingId = r.nat() else return null; ?#checkOut({ staff; bookingId }) };
      case 17 { let ?paymentId = r.nat() else return null; let ?ok = r.bool() else return null; ?#recordGatewayOutcome({ paymentId; ok }) };
      case 18 { let ?staff = r.principal() else return null; let ?day = r.nat() else return null; ?#openAudit({ staff; day }) };
      case 19 { let ?staff = r.principal() else return null; let ?day = r.nat() else return null; let ?limit = r.nat() else return null; ?#advanceAudit({ staff; day; limit }) };
      case 20 { let ?staff = r.principal() else return null; let ?day = r.nat() else return null; ?#closeDay({ staff; day }) };
      case 21 { let ?subject = r.principal() else return null; ?#bootstrapOwner({ subject }) };
      case 22 {
        let ?staff = r.principal() else return null; let ?subject = r.principal() else return null;
        let ?rb = r.nat8() else return null; let ?role = E.roleOf(rb) else return null;
        ?#grantRole({ staff; subject; role })
      };
      case 23 {
        let ?staff = r.principal() else return null; let ?subject = r.principal() else return null;
        let ?rb = r.nat8() else return null; let ?role = E.roleOf(rb) else return null;
        ?#revokeRole({ staff; subject; role })
      };
      case 24 { let ?staff = r.principal() else return null; let ?act = readDualAct(r) else return null; let ?justification = r.text() else return null; ?#propose({ staff; act; justification }) };
      case 25 { let ?staff = r.principal() else return null; let ?proposalId = r.nat() else return null; ?#approve({ staff; proposalId }) };
      case 26 { let ?staff = r.principal() else return null; let ?proposalId = r.nat() else return null; let ?reason = r.text() else return null; ?#reject({ staff; proposalId; reason }) };
      case 27 { let ?staff = r.principal() else return null; let ?bookingId = r.nat() else return null; let ?a = readAuth(r) else return null; ?#settleAtDesk({ staff; bookingId; auth = a }) };
      case 28 { let ?staff = r.principal() else return null; let ?key = r.blob() else return null; ?#setGuestDataKey({ staff; key }) };
      case 29 { let ?staff = r.principal() else return null; let ?bookingId = r.nat() else return null; let ?size = r.nat() else return null; let ?chunkHashes = r.texts() else return null; ?#beginIdUpload({ staff; bookingId; size; chunkHashes }) };
      case 30 { let ?staff = r.principal() else return null; let ?blobId = r.text() else return null; let ?index = r.nat() else return null; let ?bytes = r.blob() else return null; ?#putIdChunk({ staff; blobId; index; bytes }) };
      case 31 {
        let ?staff = r.principal() else return null; let ?bookingId = r.nat() else return null; let ?blobId = r.text() else return null;
        let ?plainHash = r.text() else return null; let ?plainSize = r.nat() else return null; let ?mime = r.text() else return null; let ?fileKey = r.text() else return null;
        ?#fileIdDocument({ staff; bookingId; blobId; plainHash; plainSize; mime; fileKey })
      };
      case 32 { let ?staff = r.principal() else return null; let ?edits = readManyEdits(r) else return null; ?#setNightsMany({ staff; edits }) };
      case 33 {
        let ?staff = r.principal() else return null; let ?zoneName = r.text() else return null; let ?zoneRule = r.text() else return null;
        let ?auditAt = r.nat() else return null; let ?auto = r.bool() else return null; let ?runner = r.principal() else return null;
        ?#setHotelClock({ staff; zoneName; zoneRule; auditAt; auto; runner })
      };
      case 34 {
        let ?staff = r.principal() else return null; let ?roomId = r.nat() else return null;
        let ?cb = r.nat8() else return null; let ?cleaning = E.cleaningOf(cb) else return null;
        ?#markRoom({ staff; roomId; cleaning })
      };
      case 35 {
        let ?staff = r.principal() else return null; let ?roomId = r.nat() else return null;
        let ?reason = r.text() else return null; let ?untilDay = r.nat() else return null;
        ?#takeRoomOutOfOrder({ staff; roomId; reason; untilDay })
      };
      case 36 { let ?staff = r.principal() else return null; let ?roomId = r.nat() else return null; ?#returnRoomToService({ staff; roomId }) };
      case 37 {
        let ?staff = r.principal() else return null; let ?id = r.nat() else return null; let ?code = r.text() else return null;
        let ?nameEn = r.text() else return null; let ?nameAr = r.text() else return null;
        let ?cb = r.nat8() else return null; let ?category = E.extraCategoryOf(cb) else return null;
        let ?price = r.nat() else return null; let ?taxed = r.bool() else return null; let ?active = r.bool() else return null;
        ?#upsertExtra({ staff; id; facts = { code; nameEn; nameAr; category; price; taxed; active } })
      };
      case 38 {
        let ?staff = r.principal() else return null; let ?bookingId = r.nat() else return null; let ?extraId = r.nat() else return null;
        let ?quantity = r.nat() else return null; let ?amount = r.nat() else return null; let ?payerId = r.nat() else return null;
        ?#postCharge({ staff; bookingId; extraId; quantity; amount; payerId })
      };
      case 39 { let ?staff = r.principal() else return null; let ?bookingId = r.nat() else return null; let ?name = r.text() else return null; ?#addPayer({ staff; bookingId; name }) };
      case 40 {
        let ?staff = r.principal() else return null; let ?bookingId = r.nat() else return null; let ?lineIds = r.nats() else return null;
        let ?payerId = r.nat() else return null;
        ?#routeLines({ staff; bookingId; lineIds; payerId })
      };
      case 41 {
        let ?staff = r.principal() else return null; let ?bookingId = r.nat() else return null; let ?payerId = r.nat() else return null;
        let ?a = readAuth(r) else return null;
        ?#settleShare({ staff; bookingId; payerId; auth = a })
      };
      case 42 { let ?staff = r.principal() else return null; let ?bookingId = r.nat() else return null; let ?payerId = r.nat() else return null; ?#issueInvoice({ staff; bookingId; payerId }) };
      case 43 {
        let ?staff = r.principal() else return null; let ?taxRuleId = r.nat() else return null;
        let ?taxType = r.text() else return null; let ?subType = r.text() else return null;
        ?#setTaxEta({ staff; taxRuleId; taxType; subType })
      };
      case 44 {
        let ?staff = r.principal() else return null;
        let ?issuerId = r.text() else return null; let ?activityCode = r.text() else return null; let ?branchId = r.text() else return null;
        let ?country = r.text() else return null; let ?governate = r.text() else return null; let ?regionCity = r.text() else return null;
        let ?street = r.text() else return null; let ?buildingNumber = r.text() else return null;
        ?#setEtaProfile({ staff; facts = { issuerId; activityCode; branchId; country; governate; regionCity; street; buildingNumber } })
      };
      case 45 {
        let ?staff = r.principal() else return null;
        let ?cb = r.byte() else return null; let ?channel = E.channelOf(cb) else return null;
        let ?st = readStay(r) else return null; let ?quoteHash = r.blob() else return null;
        let ?guestName = r.text() else return null; let ?guestEmail = r.text() else return null; let ?note = r.text() else return null;
        let ?manageKey = r.blob() else return null; let ?roomIds = r.nats() else return null;
        ?#bookByStaff({ staff; channel; stay = st; quoteHash; guestName; guestEmail; note; manageKey; roomIds })
      };
      case 46 {
        let ?staff = r.principal() else return null; let ?bookingId = r.nat() else return null;
        let ?fromRoomId = r.nat() else return null; let ?toRoomId = r.nat() else return null;
        ?#moveRoom({ staff; bookingId; fromRoomId; toRoomId })
      };
      case 47 {
        let ?staff = r.principal() else return null; let ?id = r.nat() else return null;
        let ?code = r.text() else return null; let ?name = r.text() else return null; let ?active = r.bool() else return null;
        ?#upsertCompany({ staff; id; code; name; active })
      };
      case 48 {
        let ?staff = r.principal() else return null; let ?planId = r.nat() else return null;
        let ?companyId = r.nat() else return null; let ?closed = r.bool() else return null;
        ?#setPlanAccess({ staff; planId; companyId; closed })
      };
      case 49 {
        let ?owner = r.principal() else return null; let ?s = readStay(r) else return null; let ?quoteHash = r.blob() else return null;
        let ?key = r.blob() else return null; let ?code = r.text() else return null;
        ?#placeHoldCoded({ owner; stay = s; quoteHash; key; code })
      };
      case 50 {
        let ?staff = r.principal() else return null;
        let ?cb = r.byte() else return null; let ?channel = E.channelOf(cb) else return null;
        let ?st = readStay(r) else return null; let ?quoteHash = r.blob() else return null;
        let ?guestName = r.text() else return null; let ?guestEmail = r.text() else return null; let ?note = r.text() else return null;
        let ?manageKey = r.blob() else return null; let ?roomIds = r.nats() else return null; let ?code = r.text() else return null;
        ?#bookByStaffCoded({ staff; channel; stay = st; quoteHash; guestName; guestEmail; note; manageKey; roomIds; code })
      };
      case 51 {
        let ?staff = r.principal() else return null; let ?id = r.nat() else return null;
        let ?code = r.text() else return null; let ?name = r.text() else return null; let ?planId = r.nat() else return null;
        let ?bookFrom = r.nat() else return null; let ?bookUntil = r.nat() else return null;
        let ?stayFrom = r.nat() else return null; let ?stayUntil = r.nat() else return null;
        let ?maxUses = r.nat() else return null; let ?active = r.bool() else return null;
        ?#upsertPromo({ staff; id; code; name; planId; bookFrom; bookUntil; stayFrom; stayUntil; maxUses; active })
      };
      case 52 {
        let ?staff = r.principal() else return null; let ?id = r.nat() else return null; let ?name = r.text() else return null;
        let ?companyId = r.nat() else return null; let ?roomTypeId = r.nat() else return null; let ?planId = r.nat() else return null;
        let ?arrival = r.nat() else return null; let ?nights = r.nat() else return null; let ?rooms = r.nat() else return null;
        let ?cutoff = r.nat() else return null;
        ?#upsertBlock({ staff; id; name; companyId; roomTypeId; planId; arrival; nights; rooms; cutoff })
      };
      case 53 { let ?staff = r.principal() else return null; let ?id = r.nat() else return null; ?#releaseBlock({ staff; id }) };
      case 54 {
        let ?staff = r.principal() else return null; let ?blockId = r.nat() else return null;
        let ?st = readStay(r) else return null; let ?quoteHash = r.blob() else return null;
        let ?guestName = r.text() else return null; let ?guestEmail = r.text() else return null; let ?note = r.text() else return null;
        let ?manageKey = r.blob() else return null;
        ?#pickUpFromBlock({ staff; blockId; stay = st; quoteHash; guestName; guestEmail; note; manageKey })
      };
      case 55 {
        let ?staff = r.principal() else return null; let ?planId = r.nat() else return null;
        let ?n = r.len16() else return null;
        let incs = List.empty<Cmd.InclusionFacts>();
        var i = 0;
        while (i < n) {
          let ?extraId = r.nat() else return null; let ?quantity = r.nat() else return null;
          let ?rb = r.nat8() else return null; let ?rhythm = E.rhythmOf(rb) else return null;
          let ?pb = r.nat8() else return null; let ?per = E.perOf(pb) else return null;
          List.add(incs, { extraId; quantity; rhythm; per });
          i += 1;
        };
        ?#setPlanInclusions({ staff; planId; inclusions = List.toArray(incs) })
      };
      case 56 { let ?staff = r.principal() else return null; let ?planId = r.nat() else return null; let ?depositBps = r.nat() else return null; ?#setPlanDeposit({ staff; planId; depositBps }) };
      case 57 { let ?staff = r.principal() else return null; ?#requireCardOnFile({ staff }) };
      case 58 {
        let ?owner = r.principal() else return null; let ?holdId = r.nat() else return null;
        let ?guestName = r.text() else return null; let ?guestEmail = r.text() else return null; let ?note = r.text() else return null;
        let ?manageKey = r.blob() else return null; let ?account = r.optPrincipal() else return null;
        let ?a = readAuth(r) else return null; let ?token = r.nat() else return null;
        ?#confirmHoldOnFile({ owner; holdId; guestName; guestEmail; note; manageKey; account; auth = a; token })
      };
      case 59 {
        let ?by = readGuestActor(r) else return null; let ?bookingId = r.nat() else return null;
        let ?a = readAuth(r) else return null; let ?token = r.nat() else return null;
        ?#putCardOnFile({ by; bookingId; auth = a; token })
      };
      case 60 { let ?paymentId = r.nat() else return null; let ?ok = r.bool() else return null; let ?authId = r.nat() else return null; ?#recordChargeOutcome({ paymentId; ok; authId }) };
      case 61 { let ?bookingId = r.nat() else return null; let ?ok = r.bool() else return null; ?#recordCardForgotten({ bookingId; ok }) };
      case 62 { let ?staff = r.principal() else return null; let ?mailer = r.principal() else return null; let ?mailKey = r.blob() else return null; ?#setMailRelay({ staff; mailer; mailKey }) };
      case 63 { let ?staff = r.principal() else return null; let ?digest = r.blob() else return null; ?#authoriseMailCredential({ staff; digest }) };
      case 64 { let ?staff = r.principal() else return null; let ?on = r.bool() else return null; ?#setMailOn({ staff; on }) };
      case 65 {
        let ?by = readGuestActor(r) else return null; let ?bookingId = r.nat() else return null; let ?sealed = r.text() else return null;
        let ?lb = r.nat8() else return null; let ?lang = E.langOf(lb) else return null;
        ?#attachMail({ by; bookingId; sealed; lang })
      };
      case 66 {
        let ?staff = r.principal() else return null; let ?bookingId = r.nat() else return null; let ?sealed = r.text() else return null;
        let ?lb = r.nat8() else return null; let ?lang = E.langOf(lb) else return null;
        ?#attachMailByStaff({ staff; bookingId; sealed; lang })
      };
      case 67 {
        let ?mailer = r.principal() else return null; let ?outboxId = r.nat() else return null; let ?sent = r.bool() else return null;
        let ?fb = r.nat8() else return null; let ?failure = E.mailFailureOf(fb) else return null;
        ?#recordMailOutcome({ mailer; outboxId; sent; failure })
      };
      case 68 { let ?mailer = r.principal() else return null; let ?digest = r.blob() else return null; ?#recordMailTest({ mailer; digest }) };
      case 69 { let ?staff = r.principal() else return null; let ?epoch = r.nat() else return null; ?#adoptRules({ staff; epoch }) };
      case _ null;
    };
    // a command is the WHOLE of its bytes: anything left over is not this command
    if (not r.atEnd()) return null;
    out
  };

  public let registry : KE.Registry<Command> = {
    domainPrefix = DOMAIN_PREFIX;
    current = 1;
    encoders = [{ version = 1; write = writeV1; read = readV1 }];
  };

  public func bytesAt(version : Nat8, c : Command) : ?Blob { KE.bytesAt(registry, version, c) };
  public func hashAt(version : Nat8, c : Command) : ?Blob { KE.hashAt(registry, version, c) };
  public func read(version : Nat8, b : Blob) : ?Command { KE.readAt(registry, version, C.Reader(Blob.toArray(b))) };
  public func versionText() : Text { Nat.toText(Nat8.toNat(registry.current)) };
}
