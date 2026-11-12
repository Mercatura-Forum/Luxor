/// Luxor.mo - the contract: one hotel's log, its fold, and the edge in front of them.
///
/// THE EDGE ESTABLISHES WHO, THE FOLD DECIDES WHAT. A guest's hold is owned by the browser key that
/// made it; an account holder and every member of staff are identified by a Memphis passkey session,
/// verified here with `await*` before anything is accepted; a guest without an account acts through a
/// manage-key signature checked here; a payment is whatever the TEST gateway says it authorised, read
/// from the gateway here. Each of those is settled BEFORE the accept path runs, and the accept path
/// itself (clock, bind, fold, append) has no await in it, so a capacity check and its writes are one
/// step. A capture that follows a confirmation is recorded by its own command.
///
/// THIS IS THE ONE FILE THAT READS A CLOCK: it supplies the kernel's `Source` record, and the rest of
/// the product reads time through it.
///
/// Every reply is a flat record, or a vector of them, of scalar fields: that is what the SDK decodes.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Nat8 "mo:core/Nat8";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Timer "mo:core/Timer";
import Random "mo:core/Random";
import Runtime "mo:core/Runtime";

import C "mo:kernel/codec/Canonical";
import Evidence "mo:kernel/eco/Evidence";
import BatchCore "mo:kernel/batch/BatchCore";
import Zone "mo:kernel/time/Zone";
import DL "mo:kernel/domain/DomainLog";
import Page "mo:kernel/rows/Page";
import RowStore "mo:kernel/rows/RowStore";
import RateLimit "mo:kernel/sweep/RateLimit";
import SR "mo:kernel/rows/StableRows";

import Clk "ClockWiring";
import Cmd "Command";
import Con "Contract";
import E "Enums";
import Enc "Encoding";
import CN "CreditNote";
import Eta "Eta";
import H "History";
import HotelClock "HotelClock";
import Hk "Housekeeping";
import Mail "Mail";
import Bill "Bill";
import Win "Windows";
import Sign "Sign";
import GW "../gateway-test/Gateway";
import Acc "Access";
import Blocks "Blocks";
import Rf "Refusal";
import Log "Log";
import MK "ManageKey";
import O "Oracle";
import Q "Quote";
import R "Rows";
import Ref "Ref";
import Res "Reservations";
import RP "RateProducts";
import Rules "Rules";
import St "Store";
import TA "TextArena";
import W "Widths";
import MA "vendor/MemphisAuth";

/// The install's arguments: the only way a Luxor is set up. They reach the contract through the signed
/// deploy path (thebes-deploy with the installer's key), never through a call anyone could make. On an
/// upgrade they may bind an identity contract to a deployment that has none, once; everything else is
/// read on the first install only.
persistent actor class Luxor(init : {
  firstDay : Nat;
  gateway : Nat;
  identity : ?{ memphis : Nat; origin : Text; audience : Text };
  firstOwner : ?Principal;
}) = this {

  // ── the state: the log and the fold of it ─────────────────────────────────

  let log = Log.newState();
  let s = St.newStores();
  /// The tables that came after go-live (Store.Later): a new top-level record, because `s` is frozen.
  let later = St.newLater();
  let clock : Con.ClockCell = { var config = Clk.genesisConfig() };

  /// Set on the first install, from its arguments.
  var setUp : Bool = false;
  var gateway : ?Principal = null;
  /// The merchant's P-256 private key for signing requests to the gateway: drawn once from the
  /// substrate, never leaves this contract. Its public key is what the gateway's install is given.
  var merchantKey : ?Nat = null;
  /// How staff and account holders are identified: by a Memphis session, or, on a
  /// deployment with no identity contract, by the transport key (a Thebes subnet before Memphis runs).
  var memphis : ?MA.State = null;
  var audience : Text = "";
  var upgrades : Nat = 0;
  let calls = Map.empty<Principal, [Int]>();

  system func postupgrade() { upgrades += 1; St.ensureLater(later) };

  // ── the substrate: the only clock in the product ─────────────────────────

  transient let source : Clk.Source = {
    substrateNow = func() : Nat64 { Nat64.fromIntWrap(Time.now()) };
    // On this substrate the clock advances about a second per block, so the second is the height.
    substrateHeight = func() : Nat { Int.abs(Time.now() / 1_000_000_000) };
    blockTimestamp = func() : ?Nat64 { null };
  };

  func height() : Nat { source.substrateHeight() };
  func self() : Principal { Principal.fromActor(this) };
  /// How a signed message names this contract: the hex of its principal's bytes.
  func selfHex() : Text { C.hex(Principal.toBlob(self())) };

  // ── replies ───────────────────────────────────────────────────────────────

  public type Outcome = { ok : Bool; kind : Text; reason : Text; block : Nat; a : Nat; b : Nat; c : Nat };
  /// What every update returns: one outcome, as a one-row vector (the SDK decodes vectors of records).
  public type Reply = [Outcome];

  func accept(caller : Principal, command : Cmd.Command) : Outcome {
    switch (Con.accept(log, s, later, clock, source, caller, command)) {
      case (#ok x) {
        let e = x.effects;
        { ok = true; kind = ""; reason = ""; block = x.block + 1; a = if (e.size() > 0) e[0] else 0; b = if (e.size() > 1) e[1] else 0; c = if (e.size() > 2) e[2] else 0 }
      };
      case (#err r) { { ok = false; kind = Con.kindOf(r); reason = Con.textOf(r); block = DL.length(log); a = 0; b = 0; c = 0 } };
    }
  };

  func refusal(kind : Text, reason : Text) : Outcome { { ok = false; kind; reason; block = DL.length(log); a = 0; b = 0; c = 0 } };

  func today() : Nat { switch (Clk.today(clock.config, source)) { case (#ok d) d; case (#err _) 0 } };
  func ctx() : St.Ctx { { s; x = later; block = DL.length(log); day = today(); height = height() } };

  // ── setup, from the install ───────────────────────────────────────────────

  func setup() {
    if (not setUp) {
      switch (Clk.roll(clock.config, init.firstDay)) { case (#ok c) clock.config := c; case (#err e) Runtime.trap("Luxor: the first day: " # Clk.errorText(e)) };
      gateway := ?MA.principalOfCid(Nat64.fromNat(init.gateway));
      switch (init.identity) {
        case (?i) { memphis := ?MA.initFromCid(Nat64.fromNat(i.memphis), i.origin, 1); audience := i.audience };
        case null {};
      };
      switch (init.firstOwner) {
        // the grant is a block like any other, so the log says who owns the hotel from its first entry
        case (?o) {
          let r = accept(o, #bootstrapOwner({ subject = o }));
          if (not r.ok) Runtime.trap("Luxor: the first owner: " # r.reason);
          // a hotel installed by this build keeps its books under the newest rules it knows, from its
          // first blocks, each adoption a block of the log like any other (`Rules`)
          for (e in Nat.range(1, Rules.CURRENT + 1)) {
            let a = accept(o, #adoptRules({ staff = o; epoch = e }));
            if (not a.ok) Runtime.trap("Luxor: the rules of epoch " # Nat.toText(e) # ": " # a.reason);
          };
        };
        case null {};
      };
      setUp := true;
    } else {
      // An identity contract, once bound, is never changed: its origin names every account's principal.
      switch (memphis, init.identity) {
        case (null, ?i) { memphis := ?MA.initFromCid(Nat64.fromNat(i.memphis), i.origin, 1); audience := i.audience };
        case _ {};
      };
    };
  };

  // ── the merchant's key ────────────────────────────────────────────────────

  func merchantKeyHex() : Text { switch merchantKey { case (?d) C.hexOf(Sign.publicKeyBytes(d)); case null "" } };

  /// Draw the merchant's key from the substrate's randomness, once, and give its public key, which the
  /// gateway's install is then given. Anyone may ask: drawing it is harmless and only the first counts.
  public shared func drawMerchantKey() : async [{ publicKey : Text }] {
    if (merchantKey == null) {
      let drawn = Blob.toArray(await Random.blob());
      // another call may have drawn while this one waited; the first draw stands
      if (merchantKey == null) merchantKey := Sign.privateKeyOf(drawn);
    };
    [{ publicKey = merchantKeyHex() }]
  };

  public query func merchantKeyView() : async [{ publicKey : Text }] { [{ publicKey = merchantKeyHex() }] };


  // ── identity ──────────────────────────────────────────────────────────────

  /// A session token travels as hex text: the SDK encodes text, not blobs.
  func tok(hex : Text) : Blob { switch (C.fromHex(hex)) { case (?b) b; case null Blob.fromArray([]) } };

  /// Who a signed-in person is: their Memphis principal, verified with the identity contract. On a
  /// deployment with no identity contract (a Thebes subnet before Memphis runs) the transport key stands
  /// in; that key is claimed by the client, not proven, so such a deployment is for a Thebes subnet only,
  /// and `propertyView` says which mode is in force.
  func identify(caller : Principal, token : Blob) : async* { #ok : Principal; #err : Text } {
    switch memphis {
      case null { if (Principal.isAnonymous(caller)) #err("Sign in first.") else #ok(caller) };
      case (?gate) {
        switch (await* MA.verifyWithAudience(gate, token, audience)) {
          case (#ok id) #ok(id.principal);
          case (#err (#Memphis(#Unauthorized))) #err("You are signed in for another site.");
          case (#err (#Expired)) #err("Your session has ended. Please sign in again.");
          case (#err _) #err("Your sign-in could not be checked.");
        }
      };
    }
  };

  /// A query cannot await, so a session is opened once with an update and read from the cache after.
  func identifyCached(caller : Principal, token : Blob) : ?Principal {
    switch memphis {
      case null { if (Principal.isAnonymous(caller)) null else ?caller };
      case (?gate) {
        switch (Map.get(gate.cache, Blob.compare, token)) {
          // an expired session is not an identity, even if the cache still holds it
          case (?c) { if (c.expiresNs > source.substrateNow()) ?c.principal else null };
          case null null;
        }
      };
    }
  };

  public shared ({ caller }) func openSession(session : Text) : async Reply {
    switch (await* identify(caller, tok(session))) {
      case (#ok _) [{ ok = true; kind = ""; reason = ""; block = DL.length(log); a = 0; b = 0; c = 0 }];
      case (#err why) [refusal("session", why)];
    }
  };

  /// The staff member or account holder behind a call, then the command they asked for.
  func asPerson(caller : Principal, session : Text, make : Principal -> Cmd.Command) : async* Outcome {
    switch (await* identify(caller, tok(session))) {
      case (#err why) refusal("session", why);
      case (#ok who) accept(caller, make(who));
    }
  };

  // ── abuse bounds on the open surface ──────────────────────────────────────

  let HOLD_WINDOWS : [RateLimit.Window] = [(600, 5, "five holds in ten minutes"), (60, 2, "two holds a minute")];

  func limited(caller : Principal) : ?Text {
    let prior = switch (Map.get(calls, Principal.compare, caller)) { case (?l) l; case null [] };
    switch (RateLimit.check(prior, height(), HOLD_WINDOWS, RateLimit.widestOf(HOLD_WINDOWS))) {
      case (#ok next) { Map.add(calls, Principal.compare, caller, next); null };
      case (#limited x) ?("Too many holds from this browser (" # x.windowLabel # "). Please wait a moment.");
    }
  };

  // ── the guest ─────────────────────────────────────────────────────────────

  /// A hold is proven by the browser's hold key: the release and the confirmation are signed over
  /// this contract, the hold and the act. Both acts end the hold, so a signature cannot be used twice.
  func holdSigned(holdId : Nat, act : Text, sigHex : Text) : Bool {
    let ?h = St.hold(s, holdId) else return false;
    let ?sig = C.fromHex(sigHex) else return false;
    MK.verify(h.key, Text.encodeUtf8("LUXOR-HOLD-v1|" # selfHex() # "|" # Nat.toText(holdId) # "|" # act), sig)
  };

  /// Hold a stay at the price the guest was shown. Expired holds at the head of the expiry index are
  /// released first, as their own block, so a sweep never shares a block with a command that can refuse.
  public shared ({ caller }) func placeHold(roomTypeId : Nat, planId : Nat, arrival : Nat, nights : Nat, rooms : Nat, adults : Nat, children : Nat, quoteHashHex : Text, holdKeyHex : Text) : async Reply {
    if (Principal.isAnonymous(caller)) return [refusal("notTheOwner", "Sign the call.")];
    switch (limited(caller)) { case (?why) return [refusal("rateLimited", why)]; case null {} };
    let ?hash = C.fromHex(quoteHashHex) else return [refusal("invalid", "The price reference is malformed.")];
    let ?key = C.fromHex(holdKeyHex) else return [refusal("invalid", "The hold key is malformed.")];
    if (Res.expiredHolds(s, height(), 1).size() > 0) ignore accept(caller, #releaseExpiredHolds({ limit = 16 }));
    // a: hold id, b: the height it expires at, c: the total held
    [accept(caller, #placeHold({ owner = caller; stay = { roomTypeId; planId; arrival; nights; rooms; adults; children }; quoteHash = hash; key }))]
  };

  public shared ({ caller }) func releaseHold(holdId : Nat, sigHex : Text) : async Reply {
    let ?h = St.hold(s, holdId) else return [refusal("noSuchHold", "There is no such hold.")];
    if (not holdSigned(holdId, "release", sigHex)) return [refusal("notTheOwner", "This browser did not make that hold.")];
    [accept(caller, #releaseHold({ owner = h.owner; holdId }))]
  };

  /// `cardToken`: the card kept on file at this payment, when the guest agreed to it (0: none).
  type GatewayView = { found : Bool; amount : Nat; currency : Text; merchant : Principal; merchantRef : Nat; status : Text; captured : Nat; refunded : Nat; cardToken : Nat };
  type GatewayOutcome = { ok : Bool; reason : Text; amount : Nat };
  type ChargeOutcome = { ok : Bool; reason : Text; amount : Nat; authId : Nat };
  type Gateway = actor {
    authorization_u : (Nat) -> async GatewayView;
    capture_u : (Nat, Nat, Nat, Text) -> async GatewayOutcome;
    refund_u : (Nat, Nat, Nat, Text) -> async GatewayOutcome;
    void_u : (Nat, Nat, Text) -> async GatewayOutcome;
    chargeOnFile_u : (Nat, Nat, Nat, Nat, Text) -> async ChargeOutcome;
    forgetCard_u : (Nat, Nat, Text) -> async GatewayOutcome;
  };

  func gw() : ?Gateway { switch gateway { case (?p) ?(actor (Principal.toText(p)) : Gateway); case null null } };

  /// What the gateway says it authorised. Checked here for the merchant; the fold checks the rest.
  func authFacts(authId : Nat) : async* { #ok : Cmd.AuthFacts; #err : Text } {
    switch (await* authAndCard(authId)) { case (#ok(f, _)) #ok(f); case (#err why) #err(why) }
  };

  /// The same, with the card the gateway kept on file at this payment (0: none). The token is the
  /// gateway's word, read here from the gateway, never a caller's.
  func authAndCard(authId : Nat) : async* { #ok : (Cmd.AuthFacts, Nat); #err : Text } {
    let ?g = gw() else return #err("No payment gateway is set.");
    let v = await g.authorization_u(authId);
    if (not v.found) return #err("The payment was not found.");
    if (v.merchant != self()) return #err("The payment was made to another merchant.");
    if (v.status != "authorised") return #err("The payment is " # v.status # ".");
    #ok(({ authId; amount = v.amount; currency = v.currency; merchantRef = v.merchantRef }, v.cardToken))
  };

  /// Run one queued payment at the gateway and record what it said, as its own block.
  func runPayment(caller : Principal, pid : Nat) : async* Bool {
    let ?p = St.payment(s, pid) else return false;
    if (p.state != #due) return false;
    let ?g = gw() else return false;
    let ?gp = gateway else return false;
    // without the merchant's key nothing can be signed; the payment stays due until it is drawn
    let ?d = merchantKey else return false;
    let signed = func(act : Text, amount : Nat) : Text {
      C.hexOf(Sign.sign(d, GW.message(C.hex(Principal.toBlob(gp)), act, p.gatewayAuth, amount, pid)))
    };
    let r = switch (p.kind) {
      case (#captured) await g.capture_u(p.gatewayAuth, p.amount, pid, signed("capture", p.amount));
      case (#refunded) await g.refund_u(p.gatewayAuth, p.amount, pid, signed("refund", p.amount));
      case (#voided) await g.void_u(p.gatewayAuth, pid, signed("void", 0));
      case (#authorised) return false;
      case (#chargedOnFile) {
        // only a card still kept, and only the charge it was queued for: a forgotten token is never charged
        let ?k = St.card(later, p.bookingId) else return false;
        if (k.state != #kept or k.chargeId != pid or k.token == 0) return false;
        let sig = C.hexOf(Sign.sign(d, GW.message(C.hex(Principal.toBlob(gp)), "chargeOnFile", k.token, p.amount, pid)));
        let c = await g.chargeOnFile_u(k.token, p.amount, St.BOOKING_REF_BASE + p.bookingId, pid, sig);
        return accept(caller, #recordChargeOutcome({ paymentId = pid; ok = c.ok; authId = if (c.ok) c.authId else 0 })).ok and c.ok;
      };
    };
    accept(caller, #recordGatewayOutcome({ paymentId = pid; ok = r.ok })).ok and r.ok
  };

  /// Ask the gateway to delete a settled booking's card token, and record what it said, as its own block.
  func runForget(caller : Principal, bookingId : Nat) : async* Bool {
    let ?k = St.card(later, bookingId) else return false;
    if (k.state != #forgetDue) return false;
    let ?g = gw() else return false;
    let ?gp = gateway else return false;
    let ?d = merchantKey else return false;
    let sig = C.hexOf(Sign.sign(d, GW.message(C.hex(Principal.toBlob(gp)), "forgetCard", k.token, 0, bookingId)));
    let r = await g.forgetCard_u(k.token, bookingId, sig);
    accept(caller, #recordCardForgotten({ bookingId; ok = r.ok })).ok and r.ok
  };

  /// The gateway queue pushed forward, a bounded number of each: the payments due, then the tokens to
  /// delete. Returns (payments run, payments done, tokens run, tokens forgotten).
  func pump(caller : Principal, limit : Nat) : async* (Nat, Nat, Nat, Nat) {
    let n = Nat.min(Nat.max(limit, 1), 16);
    let due = switch (RowStore.page<R.Payment>(s.payments, R.payment, "gateway_due", SR.key(0, W.ID), SR.key(St.MAX_ID, W.ID), null, n)) {
      case (#ok p) p.rows; case (#err _) [];
    };
    var done = 0;
    for ((pid, _) in due.vals()) { if (await* runPayment(caller, pid)) done += 1 };
    let forget = St.cardsToForget(later, n);
    var forgotten = 0;
    for ((bid, _) in forget.vals()) { if (await* runForget(caller, bid)) forgotten += 1 };
    (due.size(), done, forget.size(), forgotten)
  };

  /// Run a booking's queued payments now, a bounded number of them.
  func drain(caller : Principal, bookingId : Nat, limit : Nat) : async* Nat {
    var n = 0;
    for ((pid, p) in St.paymentsOf(s, bookingId).vals()) {
      if (n < limit and p.state == #due) { ignore await* runPayment(caller, pid); n += 1 };
    };
    n
  };

  /// Confirm a hold. The hold is proven by its key (or, for a waitlist offer, by the account's
  /// session); the payment is read from the gateway; then the synchronous accept; then the capture.
  /// a: booking id, b: the capture queued (0 if none), c: the total.
  public shared ({ caller }) func confirmHold(holdId : Nat, holdSigHex : Text, guestName : Text, guestEmail : Text, note : Text, manageKeyHex : Text, session : Text, authId : Nat) : async [BookingReply] {
    let ?key = C.fromHex(manageKeyHex) else return bookingReply(refusal("invalid", "The manage key is malformed."), 0, 0, 0);
    let ?h = St.hold(s, holdId) else return bookingReply(refusal("noSuchHold", "There is no such hold."), 0, 0, 0);
    let account : ?Principal = if (session == "") null else switch (await* identify(caller, tok(session))) { case (#ok p) ?p; case (#err why) return bookingReply(refusal("session", why), 0, 0, 0) };
    let byKey = holdSigned(holdId, "confirm", holdSigHex);
    let byAccount = switch account { case (?a) h.owner == a and h.fromWaitlist != 0; case null false };
    if (not byKey and not byAccount) return bookingReply(refusal("notTheOwner", "This browser did not make that hold."), 0, 0, 0);
    let (facts, token) = switch (await* authAndCard(authId)) { case (#ok f) f; case (#err why) return bookingReply(refusal("payment", why), 0, 0, 0) };
    // the gateway kept the card because the guest agreed in their browser: the booking keeps its token
    let out = if (token == 0) accept(caller, #confirmHold({ owner = h.owner; holdId; guestName; guestEmail; note; manageKey = key; account; auth = facts }))
      else accept(caller, #confirmHoldOnFile({ owner = h.owner; holdId; guestName; guestEmail; note; manageKey = key; account; auth = facts; token }));
    if (out.ok and out.b != 0) ignore await* runPayment(caller, out.b);
    bookingReply(out, out.a, 0, 0)
  };

  /// A guest acting with the manage key: the signature is over this contract, the booking, the act,
  /// the arguments and the booking's current nonce.
  func signed(bookingId : Nat, act : Text, argsHash : Text, sigHex : Text) : Bool {
    let ?b = St.booking(s, bookingId) else return false;
    let ?sig = C.fromHex(sigHex) else return false;
    MK.verify(b.manageKey, MK.message(selfHex(), bookingId, act, argsHash, b.manageNonce), sig)
  };

  func guestActor(caller : Principal, id : Nat, act : Text, argsHash : Text, sigHex : Text, session : Text) : async* { #ok : Cmd.GuestActor; #err : Outcome } {
    if (session != "") {
      switch (await* identify(caller, tok(session))) { case (#ok p) #ok(#account(p)); case (#err why) #err(refusal("session", why)) }
    } else if (signed(id, act, argsHash, sigHex)) #ok(#manageKey)
    else #err(refusal("notTheOwner", "This link cannot change the booking."))
  };

  /// a cancellation's reply carries the fee kept and the money committed back to the guest
  public shared ({ caller }) func cancelBooking(ref : Text, sigHex : Text, session : Text) : async [BookingReply] {
    let ?id = Ref.parse(ref) else return bookingReply(refusal("notFound", "No booking has that reference."), 0, 0, 0);
    let by = switch (await* guestActor(caller, id, "cancel", "", sigHex, session)) { case (#ok g) g; case (#err o) return bookingReply(o, 0, 0, 0) };
    let out = accept(caller, #cancelBooking({ by; bookingId = id }));
    if (out.ok) ignore await* drain(caller, id, 4);
    bookingReply(out, id, out.b, out.c)
  };

  public shared ({ caller }) func modifyBooking(ref : Text, roomTypeId : Nat, planId : Nat, arrival : Nat, nights : Nat, rooms : Nat, adults : Nat, children : Nat, quoteHashHex : Text, sigHex : Text, session : Text, authId : Nat) : async Reply {
    let ?id = Ref.parse(ref) else return [refusal("notFound", "No booking has that reference.")];
    let ?hash = C.fromHex(quoteHashHex) else return [refusal("invalid", "The price reference is malformed.")];
    let by = switch (await* guestActor(caller, id, "modify", quoteHashHex, sigHex, session)) { case (#ok g) g; case (#err o) return [o] };
    let auth : ?Cmd.AuthFacts = if (authId == 0) null else switch (await* authFacts(authId)) { case (#ok f) ?f; case (#err why) return [refusal("payment", why)] };
    let out = accept(caller, #modifyBooking({ by; bookingId = id; stay = { roomTypeId; planId; arrival; nights; rooms; adults; children }; quoteHash = hash; auth }));
    if (out.ok) ignore await* drain(caller, id, 4);
    [out]
  };

  public shared ({ caller }) func claimBooking(ref : Text, sigHex : Text, session : Text) : async Reply {
    let ?id = Ref.parse(ref) else return [refusal("notFound", "No booking has that reference.")];
    if (not signed(id, "claim", "", sigHex)) return [refusal("notTheOwner", "This link cannot change the booking.")];
    [await* asPerson(caller, session, func(p) { #claimBooking({ account = p; bookingId = id }) })]
  };

  public shared ({ caller }) func joinWaitlist(session : Text, roomTypeId : Nat, arrival : Nat, nights : Nat, rooms : Nat, adults : Nat, children : Nat) : async Reply {
    [await* asPerson(caller, session, func(p) { #joinWaitlist({ account = p; stay = { roomTypeId; planId = 0; arrival; nights; rooms; adults; children } }) })]
  };

  public shared ({ caller }) func leaveWaitlist(session : Text, entryId : Nat) : async Reply {
    [await* asPerson(caller, session, func(p) { #leaveWaitlist({ account = p; entryId }) })]
  };

  /// Anyone may push the gateway queue forward: it only does what is already owed. a: payments run, b:
  /// payments done, c: card tokens forgotten.
  public shared ({ caller }) func processGatewayQueue(limit : Nat) : async Reply {
    let (ran, done, _, forgotten) = await* pump(caller, limit);
    [{ ok = true; kind = ""; reason = ""; block = DL.length(log); a = ran; b = done; c = forgotten }]
  };

  /// A guest puts a card on file for their booking, from its card link: the manage key's signature over
  /// the act (or the account's session), the guarantee's payment read from the gateway with the card it
  /// kept, then the act, then the deposit's capture. a: the booking, b: the capture queued.
  public shared ({ caller }) func putCardOnFile(ref : Text, sigHex : Text, session : Text, authId : Nat) : async Reply {
    let ?id = Ref.parse(ref) else return [refusal("notFound", "No booking has that reference.")];
    let by = switch (await* guestActor(caller, id, "card", Nat.toText(authId), sigHex, session)) { case (#ok g) g; case (#err o) return [o] };
    let (facts, token) = switch (await* authAndCard(authId)) { case (#ok f) f; case (#err why) return [refusal("payment", why)] };
    let out = accept(caller, #putCardOnFile({ by; bookingId = id; auth = facts; token }));
    if (out.ok) ignore await* drain(caller, id, 4);
    [out]
  };

  func langOf(t : Text) : ?E.Lang { switch t { case "en" ?#en; case "ar" ?#ar; case _ null } };

  /// A guest gives the address their booking's messages go to, sealed in their browser to the relay's
  /// mail key: signed by the manage key over the act "mail" and the SHA-256 of the sealed text (or the
  /// account's session). a: the booking, b: the confirmation's message id, c: the pre-arrival's (0: none).
  public shared ({ caller }) func attachMail(ref : Text, sigHex : Text, session : Text, sealed : Text, lang : Text) : async Reply {
    let ?id = Ref.parse(ref) else return [refusal("notFound", "No booking has that reference.")];
    let ?l = langOf(lang) else return [refusal("invalid", "A message is written in en or ar.")];
    let by = switch (await* guestActor(caller, id, "mail", C.hex(C.sha256(Text.encodeUtf8(sealed))), sigHex, session)) { case (#ok g) g; case (#err o) return [o] };
    [accept(caller, #attachMail({ by; bookingId = id; sealed; lang = l }))]
  };

  // ── staff: one typed endpoint per act, each resolving the person, then the command ──

  /// The desk gives a guest's address for a booking, sealed in the desk's browser to the relay's mail key.
  public shared ({ caller }) func attachMailByStaff(session : Text, bookingId : Nat, sealed : Text, lang : Text) : async Reply {
    let ?l = langOf(lang) else return [refusal("invalid", "A message is written in en or ar.")];
    [await* asPerson(caller, session, func(p) { #attachMailByStaff({ staff = p; bookingId; sealed; lang = l }) })]
  };

  /// The owner connects the mail relay: its key (as the relay names it, the principal's bytes in hex)
  /// becomes the hotel's mailer, and its mail key (raw P-256, hex) the key guests' addresses are sealed to.
  public shared ({ caller }) func setMailRelay(session : Text, mailerHex : Text, mailKeyHex : Text) : async Reply {
    let ?mb = C.fromHex(mailerHex) else return [refusal("invalid", "The relay's key is malformed.")];
    if (mb.size() == 0 or mb.size() > 29) return [refusal("invalid", "The relay's key is malformed.")];
    let ?key = C.fromHex(mailKeyHex) else return [refusal("invalid", "The mail key is malformed.")];
    [await* asPerson(caller, session, func(p) { #setMailRelay({ staff = p; mailer = Principal.fromBlob(mb); mailKey = key }) })]
  };

  /// The owner authorises the email account sealed to the relay in their browser, by its digest.
  public shared ({ caller }) func authoriseMailCredential(session : Text, digestHex : Text) : async Reply {
    let ?d = C.fromHex(digestHex) else return [refusal("invalid", "The digest is malformed.")];
    [await* asPerson(caller, session, func(p) { #authoriseMailCredential({ staff = p; digest = d }) })]
  };

  public shared ({ caller }) func setMailOn(session : Text, on : Bool) : async Reply {
    [await* asPerson(caller, session, func(p) { #setMailOn({ staff = p; on }) })]
  };

  // ── the mail relay: its key, by the call's signature, never a session ──
  // These are updates, not queries: an update's sender is signed on this chain, a query's is only named.

  func failureOf(t : Text) : ?E.MailFailure {
    switch t { case "" ?#none; case "rejected" ?#rejected; case "unavailable" ?#unavailable; case "unreadable" ?#unreadable; case "signIn" ?#signIn; case _ null }
  };

  /// What became of one message: sent (`failure` ""), or failed with a code. a: the message, b: its attempts.
  public shared ({ caller }) func recordMailOutcome(outboxId : Nat, sent : Bool, failure : Text) : async Reply {
    let ?f = failureOf(failure) else return [refusal("invalid", "A failure is rejected, unavailable, unreadable or signIn.")];
    [accept(caller, #recordMailOutcome({ mailer = caller; outboxId; sent; failure = f }))]
  };

  /// The relay sent the owner's test email with the credential of this digest.
  public shared ({ caller }) func recordMailTest(digestHex : Text) : async Reply {
    let ?d = C.fromHex(digestHex) else return [refusal("invalid", "The digest is malformed.")];
    [accept(caller, #recordMailTest({ mailer = caller; digest = d }))]
  };

  /// The hotel as its messages name it, and the state of guest email, for the mailer's key only.
  public type MailerSetup = { on : Bool; authorised : Text; tested : Text; mailKey : Text; today : Nat; nameEn : Text; nameAr : Text; currency : Text;
    minorUnits : Nat; checkInText : Text; checkOutText : Text; atBlock : Nat };

  public shared ({ caller }) func mailerSetup_u() : async [MailerSetup] {
    if (not St.holdsRole(s, caller, #mailer)) return [];
    let m = Mail.setup(ctx());
    let (nameEn, nameAr, currency, minorUnits, checkInText, checkOutText) = switch (St.property(s)) {
      case (?p) (TA.get(s.arena, p.nameEn), TA.get(s.arena, p.nameAr), p.currency, p.minorUnits, TA.get(s.arena, p.checkInText), TA.get(s.arena, p.checkOutText));
      case null ("", "", "", 0, "", "");
    };
    [{ on = m.on; authorised = C.hex(m.authorised); tested = C.hex(m.tested); mailKey = C.hex(m.mailKey); today = today(); nameEn; nameAr; currency; minorUnits;
       checkInText; checkOutText; atBlock = DL.length(log) }]
  };

  /// A message due today or earlier, with what its relay needs to write it: the sealed address, the
  /// language, and the booking's figures as its guest's manage page shows them. Only while guest email is
  /// on: a hotel that has not turned it on has no message the relay may send.
  public type MailDueRow = { outboxId : Nat; kind : Text; attempts : Nat; sealed : Text; lang : Text; bookingId : Nat; ref : Text; status : Text; guestName : Text;
    roomEn : Text; roomAr : Text; planEn : Text; planAr : Text; arrival : Nat; departure : Nat; rooms : Nat; adults : Nat; children : Nat;
    roomTotal : Nat; extras : Nat; taxes : Nat; charged : Nat; credited : Nat; paid : Nat; outstanding : Nat; penalty : Nat; cancelDeadline : Nat; refundable : Bool;
    next : Text; atBlock : Nat };

  public shared ({ caller }) func mailDue_u(cursor : Text, limit : Nat) : async [MailDueRow] {
    if (not St.holdsRole(s, caller, #mailer)) return [];
    let c = ctx();
    if (not Mail.setup(c).on) return [];
    let from : ?Blob = if (cursor == "") null else C.fromHex(cursor);
    let p = St.mailDue(later, c.day, from, Nat.min(Nat.max(limit, 1), 50));
    let next = switch (p.next) { case (?k) C.hex(k); case null "" };
    let out = List.empty<MailDueRow>();
    for ((oid, o) in p.rows.vals()) {
      switch (St.booking(s, o.bookingId), St.mailAddress(later, o.bookingId)) {
        case (?b, ?m) {
          let r = bookingRow(o.bookingId, b);
          let (roomEn, roomAr) = switch (St.roomType(s, b.roomTypeId)) { case (?rt) (TA.get(s.arena, rt.nameEn), TA.get(s.arena, rt.nameAr)); case null ("", "") };
          let (planEn, planAr) = switch (St.plan(s, b.planId)) { case (?pl) (TA.get(s.arena, pl.nameEn), TA.get(s.arena, pl.nameAr)); case null ("", "") };
          var roomSum = 0; var extras = 0; var taxes = 0;
          for ((_, l) in St.folioOf(s, o.bookingId).vals()) {
            switch (l.kind) { case (#roomNight) roomSum += l.amount; case (#extra) extras += l.amount; case (#tax or #extraTax) taxes += l.amount; case _ {} };
          };
          List.add(out, { outboxId = oid; kind = E.mailKindText(o.kind); attempts = o.attempts; sealed = TA.get(s.arena, m.sealed); lang = E.langText(m.lang);
            bookingId = o.bookingId; ref = r.ref; status = r.status; guestName = r.guestName; roomEn; roomAr; planEn; planAr; arrival = b.arrival; departure = b.departure;
            rooms = b.rooms; adults = b.adults; children = b.children; roomTotal = roomSum; extras; taxes; charged = b.charged; credited = b.credited; paid = b.paid;
            outstanding = b.outstanding; penalty = b.penalty; cancelDeadline = b.cancelDeadline; refundable = r.refundable; next; atBlock = DL.length(log) });
        };
        case _ {};
      };
    };
    List.toArray(out)
  };

  /// The relay's mail key and whether guest email is on, for a guest's browser to seal an address to.
  /// The key is public by design; "" while no relay is connected.
  public query func mailKeyView() : async [{ mailKey : Text; on : Bool; atBlock : Nat }] {
    let m = Mail.setup(ctx());
    [{ mailKey = if (Mail.connected(ctx())) C.hex(m.mailKey) else ""; on = m.on; atBlock = DL.length(log) }]
  };

  /// Guest email as the console shows it: connected (and to which relay key), the account authorised and
  /// tested, on or off, and the messages waiting (counted up to 99).
  public type MailSetupRow = { connected : Bool; mailer : Text; authorised : Text; tested : Text; on : Bool; waiting : Nat; more : Bool; atBlock : Nat };

  public shared query ({ caller }) func mailSetupView(session : Text) : async [MailSetupRow] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let c = ctx();
    let m = Mail.setup(c);
    let mailer = if (m.mailerGrant == 0) "" else switch (RowStore.get<R.Grant>(s.grants, R.grant, m.mailerGrant)) { case (?g) C.hex(Principal.toBlob(g.subject)); case null "" };
    let w = Mail.waiting(c, c.day, 99);
    let zero = Mail.noDigest();
    [{ connected = Mail.connected(c); mailer; authorised = if (m.authorised == zero) "" else C.hex(m.authorised); tested = if (m.tested == zero) "" else C.hex(m.tested);
       on = m.on; waiting = w.count; more = w.more; atBlock = DL.length(log) }]
  };

  /// A booking's messages as staff read them: kind, state, attempts, why the last failed (never an
  /// address: the contract cannot read it).
  public type MailRow = { outboxId : Nat; kind : Text; state : Text; attempts : Nat; failure : Text; notBefore : Nat; atBlock : Nat };

  func mailRows(id : Nat) : [MailRow] {
    let ?m = St.mailAddress(later, id) else return [];
    let out = List.empty<MailRow>();
    for (oid in [m.confirmation, m.preArrival, m.receipt, m.cancellation].vals()) {
      switch (if (oid == 0) null else St.outboxRow(later, oid)) {
        case (?o) List.add(out, { outboxId = oid; kind = E.mailKindText(o.kind); state = E.mailStateText(o.state); attempts = o.attempts;
          failure = E.mailFailureText(o.failure); notBefore = o.notBefore; atBlock = DL.length(log) });
        case null {};
      };
    };
    List.toArray(out)
  };

  public shared query ({ caller }) func bookingMailView(session : Text, bookingId : Nat) : async [MailRow] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    mailRows(bookingId)
  };

  /// A guest's own booking's messages, signed like `manageView`.
  public query func manageMailView(ref : Text, sigHex : Text) : async [MailRow] {
    let ?id = Ref.parse(ref) else return [];
    if (not signed(id, "view", "", sigHex)) return [];
    mailRows(id)
  };


  public shared ({ caller }) func configureProperty(session : Text, currency : Text, minorUnits : Nat, nameEn : Text, nameAr : Text, checkInText : Text, checkOutText : Text,
    holdTtlHeights : Nat, heightsPerRealMinute : Nat, maxStayNights : Nat, horizonDays : Nat, maxRoomsPerBooking : Nat, idRetentionDays : Nat) : async Reply {
    [await* asPerson(caller, session, func(p) { #configureProperty({ staff = p; facts = { currency; minorUnits; nameEn; nameAr; checkInText; checkOutText;
      holdTtlHeights; heightsPerRealMinute; maxStayNights; horizonDays; maxRoomsPerBooking; idRetentionDays } }) })]
  };

  func bedOf(t : Text) : E.BedKind { switch t { case "queen" #queen; case "double" #double; case "twin" #twin; case "single" #single; case _ #king } };

  public shared ({ caller }) func upsertRoomType(session : Text, id : Nat, code : Text, nameEn : Text, nameAr : Text, descEn : Text, descAr : Text, sizeSqm : Nat,
    maxAdults : Nat, maxChildren : Nat, maxOccupancy : Nat, bedKind : Text, bedCount : Nat, amenities : Nat, photos : Text, rank : Nat, active : Bool) : async Reply {
    [await* asPerson(caller, session, func(p) { #upsertRoomType({ staff = p; id; facts = { code; nameEn; nameAr; descEn; descAr; sizeSqm; maxAdults; maxChildren;
      maxOccupancy; bedKind = bedOf(bedKind); bedCount; amenities; photos; rank; active } }) })]
  };

  public shared ({ caller }) func upsertRoom(session : Text, id : Nat, roomTypeId : Nat, number : Text, outOfOrder : Bool) : async Reply {
    [await* asPerson(caller, session, func(p) { #upsertRoom({ staff = p; id; roomTypeId; number; outOfOrder }) })]
  };

  public shared ({ caller }) func upsertRatePlan(session : Text, id : Nat, code : Text, nameEn : Text, nameAr : Text, discountBps : Nat, refundable : Bool,
    freeCancelDaysBefore : Nat, penaltyNights : Nat, prepaid : Bool, modifiable : Bool, active : Bool) : async Reply {
    [await* asPerson(caller, session, func(p) { #upsertRatePlan({ staff = p; id; facts = { code; nameEn; nameAr; kind = if (discountBps == 0) #bar else #discountOffBar;
      discountBps; refundable; freeCancelDaysBefore; penaltyNights; guarantee = if (prepaid) #prepaidInFull else #firstNightAuthorised; modifiable; active } }) })]
  };

  public shared ({ caller }) func upsertTaxRule(session : Text, id : Nat, code : Text, nameEn : Text, nameAr : Text, kind : Text, bps : Nat, amount : Nat, onPriorTaxes : Bool, rank : Nat, active : Bool) : async Reply {
    let k : E.TaxKind = switch kind { case "perRoomNight" #perRoomNight; case "perStay" #perStay; case _ #percent };
    [await* asPerson(caller, session, func(p) { #upsertTaxRule({ staff = p; id; facts = { code; nameEn; nameAr; kind = k; bps; amount;
      base = if (onPriorTaxes) #roomAndPriorTaxes else #room; rank; active } }) })]
  };

  /// A grid edit. Each optional field is sent as a flag and a value: the SDK encodes no options.
  public shared ({ caller }) func setNights(session : Text, roomTypeId : Nat, fromDay : Nat, toDay : Nat, weekdays : Nat,
    setAllotment : Bool, allotment : Nat, setBar : Bool, bar : Nat, setMinStay : Bool, minStay : Nat, setMaxStay : Bool, maxStay : Nat,
    cta : Nat, ctd : Nat, stopSell : Nat) : async Reply {
    func tri(v : Nat) : ?Bool { if (v == 1) ?true else if (v == 2) ?false else null };
    [await* asPerson(caller, session, func(p) { #setNights({ staff = p; edit = { roomTypeId; fromDay; toDay; weekdays;
      allotment = if (setAllotment) ?allotment else null; bar = if (setBar) ?bar else null; minStay = if (setMinStay) ?minStay else null;
      maxStay = if (setMaxStay) ?maxStay else null; closedToArrival = tri(cta); closedToDeparture = tri(ctd); stopSell = tri(stopSell) } }) })]
  };

  /// Several grid edits saved together, all or nothing: room types side by side, a percentage on the
  /// rate, the undo of an earlier save. The SDK encodes no lists, so the edits travel as the hex of their
  /// canonical bytes (`Encoding.manyEdits`); bytes that do not read back whole are refused before anything runs.
  public shared ({ caller }) func setNightsMany(session : Text, editsHex : Text) : async Reply {
    switch (Enc.readManyEditsHex(editsHex)) {
      case null [refusal("invalid", "The changes could not be read.")];
      case (?edits) [await* asPerson(caller, session, func(p) { #setNightsMany({ staff = p; edits }) })];
    }
  };

  public shared ({ caller }) func setGuestDataKey(session : Text, keyHex : Text) : async Reply {
    let ?key = C.fromHex(keyHex) else return [refusal("invalid", "The key is malformed.")];
    [await* asPerson(caller, session, func(p) { #setGuestDataKey({ staff = p; key }) })]
  };

  /// An identity document at check-in. The chunk hashes arrive as one comma-separated text and each
  /// chunk as hex: the SDK encodes no vectors of text and no blobs. a: the upload's size.
  public shared ({ caller }) func beginIdUpload(session : Text, bookingId : Nat, size : Nat, chunkHashes : Text) : async [{ ok : Bool; kind : Text; reason : Text; block : Nat; blobId : Text }] {
    let hashes = Iter.toArray(Text.split(chunkHashes, #char ','));
    let out = await* asPerson(caller, session, func(p) { #beginIdUpload({ staff = p; bookingId; size; chunkHashes = hashes }) });
    [{ ok = out.ok; kind = out.kind; reason = out.reason; block = out.block; blobId = if (out.ok) Evidence.blobIdOf(hashes, size, s.evidence.dedupEpoch) else "" }]
  };

  public shared ({ caller }) func putIdChunk(session : Text, blobId : Text, index : Nat, chunkHex : Text) : async Reply {
    let ?bytes = C.fromHex(chunkHex) else return [refusal("invalid", "The part is not hex.")];
    [await* asPerson(caller, session, func(p) { #putIdChunk({ staff = p; blobId; index; bytes }) })]
  };

  public shared ({ caller }) func fileIdDocument(session : Text, bookingId : Nat, blobId : Text, plainHash : Text, plainSize : Nat, mime : Text, fileKey : Text) : async Reply {
    [await* asPerson(caller, session, func(p) { #fileIdDocument({ staff = p; bookingId; blobId; plainHash; plainSize; mime; fileKey }) })]
  };

  /// A booking's identity documents, for staff: what exists, and the sealed key while it is not erased.
  public shared query ({ caller }) func idDocumentsView(session : Text, bookingId : Nat) : async [{ documentId : Nat; blobId : Text; chunks : Nat; mime : Text;
    plainSize : Nat; fileKey : Text; erased : Bool; eraseDay : Nat }] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let (lo, hi) = SR.prefixRange(bookingId, W.ID, W.ID);
    let out = List.empty<{ documentId : Nat; blobId : Text; chunks : Nat; mime : Text; plainSize : Nat; fileKey : Text; erased : Bool; eraseDay : Nat }>();
    for ((_, row) in St.rangeRows<St.IdDocRow>(s.idDocs, St.ID_DOC_DECL, "by_booking", lo, hi).vals()) {
      switch (Evidence.get(s.evidence, row.documentId)) {
        case (?d) {
          let chunks = switch (Map.get(s.evidence.stored, Text.compare, d.blobId)) { case (?st) st.chunks.size(); case null 0 };
          List.add(out, { documentId = d.id; blobId = d.blobId; chunks; mime = d.mime; plainSize = d.plainSize;
            fileKey = switch (d.fileKey) { case (?k) k; case null "" }; erased = row.erased; eraseDay = row.eraseDay });
        };
        case null {};
      };
    };
    List.toArray(out)
  };

  public shared query ({ caller }) func idChunkView(session : Text, blobId : Text, index : Nat) : async [{ hex : Text }] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    switch (Evidence.readChunk(s.evidence, blobId, index)) { case (?b) [{ hex = C.hex(b) }]; case null [] }
  };

  public shared ({ caller }) func checkIn(session : Text, bookingId : Nat, roomIds : [Nat]) : async Reply {
    [await* asPerson(caller, session, func(p) { #checkIn({ staff = p; bookingId; roomIds }) })]
  };

  /// A booking staff take for a guest on the phone ("phone") or at the desk ("walkIn", checked in to
  /// `roomIds` at once). The price is the one the member of staff was shown (its hash); the email, if
  /// the guest gave one, arrives sealed, and the manage key was made in the staff member's browser.
  /// a: the booking's id, b: what it costs, outstanding until it is paid at the desk.
  public shared ({ caller }) func bookByStaff(session : Text, channel : Text, roomTypeId : Nat, planId : Nat, arrival : Nat, nights : Nat, rooms : Nat,
      adults : Nat, children : Nat, quoteHashHex : Text, guestName : Text, guestEmail : Text, note : Text, manageKeyHex : Text, roomIds : [Nat]) : async Reply {
    let ch : E.Channel = switch channel { case "phone" #phone; case "walkIn" #walkIn; case _ return [refusal("invalid", "A booking by staff is by phone or a walk-in.")] };
    let ?hash = C.fromHex(quoteHashHex) else return [refusal("invalid", "The price reference is malformed.")];
    let ?manageKey = C.fromHex(manageKeyHex) else return [refusal("invalid", "The manage key is malformed.")];
    [await* asPerson(caller, session, func(p) { #bookByStaff({ staff = p; channel = ch; stay = { roomTypeId; planId; arrival; nights; rooms; adults; children };
      quoteHash = hash; guestName; guestEmail; note; manageKey; roomIds }) })]
  };

  /// Hold a stay on a rate a code opens: a company's negotiated rate, or a promotion's. The code is
  /// resolved by the fold, so a code withdrawn before this block refuses here, not at the desk.
  /// a: hold id, b: the height it expires at, c: the total held.
  public shared ({ caller }) func placeHoldWithCode(roomTypeId : Nat, planId : Nat, arrival : Nat, nights : Nat, rooms : Nat, adults : Nat, children : Nat, quoteHashHex : Text, holdKeyHex : Text, code : Text) : async Reply {
    if (Principal.isAnonymous(caller)) return [refusal("notTheOwner", "Sign the call.")];
    switch (limited(caller)) { case (?why) return [refusal("rateLimited", why)]; case null {} };
    let ?hash = C.fromHex(quoteHashHex) else return [refusal("invalid", "The price reference is malformed.")];
    let ?key = C.fromHex(holdKeyHex) else return [refusal("invalid", "The hold key is malformed.")];
    if (Res.expiredHolds(s, height(), 1).size() > 0) ignore accept(caller, #releaseExpiredHolds({ limit = 16 }));
    [accept(caller, #placeHoldCoded({ owner = caller; stay = { roomTypeId; planId; arrival; nights; rooms; adults; children }; quoteHash = hash; key; code }))]
  };

  /// A booking taken by staff on a rate a code opens (a company calling in a booking on its rate).
  /// Everything else is as `bookByStaff`. a: the booking's id, b: what it costs.
  public shared ({ caller }) func bookByStaffWithCode(session : Text, channel : Text, roomTypeId : Nat, planId : Nat, arrival : Nat, nights : Nat, rooms : Nat,
      adults : Nat, children : Nat, quoteHashHex : Text, guestName : Text, guestEmail : Text, note : Text, manageKeyHex : Text, roomIds : [Nat], code : Text) : async Reply {
    let ch : E.Channel = switch channel { case "phone" #phone; case "walkIn" #walkIn; case _ return [refusal("invalid", "A booking by staff is by phone or a walk-in.")] };
    let ?hash = C.fromHex(quoteHashHex) else return [refusal("invalid", "The price reference is malformed.")];
    let ?manageKey = C.fromHex(manageKeyHex) else return [refusal("invalid", "The manage key is malformed.")];
    [await* asPerson(caller, session, func(p) { #bookByStaffCoded({ staff = p; channel = ch; stay = { roomTypeId; planId; arrival; nights; rooms; adults; children };
      quoteHash = hash; guestName; guestEmail; note; manageKey; roomIds; code }) })]
  };

  /// A company with negotiated rates: id 0 adds one. The code is what its bookers type (capitals,
  /// digits, dashes); a company taken off sale keeps its row, so its bookings keep naming it. a: its id.
  public shared ({ caller }) func upsertCompany(session : Text, id : Nat, code : Text, name : Text, active : Bool) : async Reply {
    [await* asPerson(caller, session, func(p) { #upsertCompany({ staff = p; id; code; name; active }) })]
  };

  /// A promotion: id 0 adds one. Its windows are the hotel's business days, inclusive; maxUses 0 is no
  /// limit. It keeps its plan and the uses it counted. a: its id.
  public shared ({ caller }) func upsertPromo(session : Text, id : Nat, code : Text, name : Text, planId : Nat, bookFrom : Nat, bookUntil : Nat,
      stayFrom : Nat, stayUntil : Nat, maxUses : Nat, active : Bool) : async Reply {
    [await* asPerson(caller, session, func(p) { #upsertPromo({ staff = p; id; code; name; planId; bookFrom; bookUntil; stayFrom; stayUntil; maxUses; active }) })]
  };

  public type PromoRow = { id : Nat; code : Text; name : Text; planId : Nat; bookFrom : Nat; bookUntil : Nat; stayFrom : Nat; stayUntil : Nat;
    maxUses : Nat; used : Nat; active : Bool; atBlock : Nat };

  /// The promotions, in id order, with the uses each has counted. Staff only.
  public shared query ({ caller }) func promosView(session : Text) : async [PromoRow] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let pg = RowStore.pageById<R.Promo>(St.later(later, St.PROMO_TABLE), R.promo, 1, RP.MAX_PROMOS, null, RP.MAX_PROMOS);
    let at = DL.length(log);
    Array.map<(Nat, R.Promo), PromoRow>(pg.rows, func((id, p)) {
      { id; code = p.code; name = TA.get(s.arena, p.name); planId = p.planId; bookFrom = p.bookFrom; bookUntil = p.bookUntil; stayFrom = p.stayFrom;
        stayUntil = p.stayUntil; maxUses = p.maxUses; used = p.used; active = p.active; atBlock = at }
    })
  };

  /// A group block: rooms of one type on one plan held off sale for a group (a wedding, a tour, a
  /// conference) from its arrival for `nights` nights, until `cutoff`, the business day the night audit
  /// gives what is not picked up back to sale. id 0 adds one; an edit renames it, changes its rooms or
  /// moves its cut-off, while it is open. companyId 0 is a block on a public plan. a: its id.
  public shared ({ caller }) func upsertBlock(session : Text, id : Nat, name : Text, companyId : Nat, roomTypeId : Nat, planId : Nat, arrival : Nat,
      nights : Nat, rooms : Nat, cutoff : Nat) : async Reply {
    [await* asPerson(caller, session, func(p) { #upsertBlock({ staff = p; id; name; companyId; roomTypeId; planId; arrival; nights; rooms; cutoff }) })]
  };

  /// Give a block's rooms not picked up back to sale now, before its cut-off. Its pickups stay. a: its id.
  public shared ({ caller }) func releaseBlock(session : Text, id : Nat) : async Reply {
    [await* asPerson(caller, session, func(p) { #releaseBlock({ staff = p; id }) })]
  };

  /// A booking picked up from a group block: a guest of the group, on the block's room type and plan,
  /// within its dates, at the price the member of staff was shown (`blockQuoteView`'s hash).
  /// a: the booking's id, b: what it costs.
  public shared ({ caller }) func pickUpFromBlock(session : Text, blockId : Nat, arrival : Nat, nights : Nat, rooms : Nat, adults : Nat, children : Nat,
      quoteHashHex : Text, guestName : Text, guestEmail : Text, note : Text, manageKeyHex : Text) : async Reply {
    let ?hash = C.fromHex(quoteHashHex) else return [refusal("invalid", "The price reference is malformed.")];
    let ?manageKey = C.fromHex(manageKeyHex) else return [refusal("invalid", "The manage key is malformed.")];
    let (roomTypeId, planId) = switch (St.block(later, blockId)) { case (?b) (b.roomTypeId, b.planId); case null (0, 0) };
    [await* asPerson(caller, session, func(p) { #pickUpFromBlock({ staff = p; blockId; stay = { roomTypeId; planId; arrival; nights; rooms; adults; children };
      quoteHash = hash; guestName; guestEmail; note; manageKey }) })]
  };

  public type BlockRow = { id : Nat; name : Text; companyId : Nat; roomTypeId : Nat; planId : Nat; arrival : Nat; departure : Nat; rooms : Nat;
    cutoff : Nat; open : Bool; roomNights : Nat; pickedNights : Nat; heldNights : Nat; atBlock : Nat };

  /// The group blocks from id `fromId` on, 50 at most, each with its room nights picked up and still
  /// held. Staff only.
  public shared query ({ caller }) func blocksView(session : Text, fromId : Nat) : async [BlockRow] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let pg = RowStore.pageById<R.Block>(St.later(later, St.BLOCK_TABLE), R.block, Nat.max(fromId, 1), Blocks.MAX_BLOCKS, null, 50);
    let at = DL.length(log);
    Array.map<(Nat, R.Block), BlockRow>(pg.rows, func((id, b)) {
      var picked = 0; var held = 0; var d = b.arrival;
      while (d < b.departure) {
        switch (St.blockNight(later, id, d)) { case (?bn) { picked += bn.picked; held += bn.open }; case null {} };
        d += 1;
      };
      { id; name = TA.get(s.arena, b.name); companyId = b.companyId; roomTypeId = b.roomTypeId; planId = b.planId; arrival = b.arrival;
        departure = b.departure; rooms = b.rooms; cutoff = b.cutoff; open = b.open; roomNights = b.rooms * (b.departure - b.arrival : Nat);
        pickedNights = picked; heldNights = held; atBlock = at }
    })
  };

  /// A block's nights: the rooms picked up and the rooms it still holds on each. Staff only.
  public shared query ({ caller }) func blockNightsView(session : Text, blockId : Nat) : async [{ day : Nat; picked : Nat; held : Nat; atBlock : Nat }] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let ?b = St.block(later, blockId) else return [];
    let at = DL.length(log);
    let out = List.empty<{ day : Nat; picked : Nat; held : Nat; atBlock : Nat }>();
    var d = b.arrival;
    while (d < b.departure) {
      switch (St.blockNight(later, blockId, d)) { case (?bn) List.add(out, { day = d; picked = bn.picked; held = bn.open; atBlock = at }); case null {} };
      d += 1;
    };
    List.toArray(out)
  };

  /// A block's rooming list: the bookings picked up from it, in booking order, 50 a page after booking
  /// `afterId` (0 for the first page). Cancelled pickups stay on it with their status. Staff only.
  public shared query ({ caller }) func roomingListView(session : Text, blockId : Nat, afterId : Nat) : async [BookingRow] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let lo = SR.key2(blockId, W.ID, afterId + 1, W.ID);
    let hi = SR.key2(blockId, W.ID, St.MAX_ID, W.ID);
    if (Blob.compare(lo, hi) == #greater) return [];
    let pg = switch (RowStore.page<R.BookingBlock>(St.later(later, St.BOOKING_BLOCK_TABLE), R.bookingBlock, "by_block", lo, hi, null, 50)) { case (#ok p) p; case (#err _) return [] };
    let out = List.empty<BookingRow>();
    for ((id, _) in pg.rows.vals()) { switch (St.booking(s, id)) { case (?b) List.add(out, bookingRow(id, b)); case null {} } };
    List.toArray(out)
  };

  /// The price of a pickup from a block, for the member of staff taking it: one offer row, or the
  /// reason there is none. `left` is the fewest rooms the block still holds on the stay's nights.
  public shared query ({ caller }) func blockQuoteView(session : Text, blockId : Nat, arrival : Nat, nights : Nat, rooms : Nat, adults : Nat, children : Nat) : async [OfferRow] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let c = ctx();
    let no = func(rt : Nat, pid : Nat, f : Rf.Refusal) : [OfferRow] {
      [{ roomTypeId = rt; planId = pid; ok = false; kind = Rf.kind(f); reason = Rf.text(f); total = 0; roomSubtotal = 0; taxTotal = 0; packageTotal = 0;
        left = 0; cancelDeadline = 0; refundable = false; guarantee = 0; quoteHash = ""; atBlock = c.block }]
    };
    let ?b = St.block(later, blockId) else return no(0, 0, #noSuchBlock({ id = blockId }));
    switch (Blocks.checkPickup(c, blockId, b.roomTypeId, b.planId, arrival, nights, rooms)) { case (?f) return no(b.roomTypeId, b.planId, f); case null {} };
    let grant : Acc.Grant = { companyId = b.companyId; promoId = 0 };
    let stay = { roomTypeId = b.roomTypeId; planId = b.planId; arrival; nights; rooms; adults; children };
    switch (Res.checkStayAs(c, Res.newPending(), stay, null, grant, true)) {
      case (#err f) no(b.roomTypeId, b.planId, f);
      case (#ok ch) {
        var left = 65_535; var d = arrival;
        while (d < arrival + nights) { switch (St.blockNight(later, blockId, d)) { case (?bn) left := Nat.min(left, bn.open); case null left := 0 }; d += 1 };
        var g = 0;
        g := Res.guaranteeOf(later, b.planId, ch.plan, ch.quote);
        let p = ch.plan;
        [{ roomTypeId = b.roomTypeId; planId = b.planId; ok = true; kind = ""; reason = ""; total = ch.quote.total; roomSubtotal = ch.quote.roomSubtotal;
          taxTotal = ch.quote.taxTotal; packageTotal = ch.quote.packageTotal; left; cancelDeadline = if (p.refundable) (if (arrival > p.freeCancelDaysBefore) arrival - p.freeCancelDaysBefore else 0) else 0;
          refundable = p.refundable; guarantee = g; quoteHash = Q.hashHex(ch.quote); atBlock = c.block }]
      };
    }
  };

  /// A plan's package, set whole. The SDK encodes no lists, so the inclusions travel as text, each
  /// `extraId:quantity:rhythm:per` (rhythm `everyNight` or `arrivalNight`, per `room`, `adult` or `guest`),
  /// separated by `;`; the empty text makes the plan a plain rate again. Text that does not read back
  /// whole is refused before anything runs.
  /// A plan's deposit: a whole percentage of the room's stay in basis points (100 to 9,900), or 0 for none.
  public shared ({ caller }) func setPlanDeposit(session : Text, planId : Nat, depositBps : Nat) : async Reply {
    [await* asPerson(caller, session, func(p) { #setPlanDeposit({ staff = p; planId; depositBps }) })]
  };

  /// The hotel's card rule turned on, once, by the owner.
  public shared ({ caller }) func requireCardOnFile(session : Text) : async Reply {
    [await* asPerson(caller, session, func(p) { #requireCardOnFile({ staff = p }) })]
  };

  /// Whether the hotel's card rule is on, and the block it was turned on in.
  /// The owner moves the hotel's rules to the next epoch: the first act after an upgrade that brings new
  /// rules (the live-upgrade plan sends it).
  public shared ({ caller }) func adoptRules(session : Text, epoch : Nat) : async Reply {
    [await* asPerson(caller, session, func(p) { #adoptRules({ staff = p; epoch }) })]
  };

  /// The rules the hotel's books are kept under, the newest this build knows, the audit walk's span, and
  /// the span the newest rules walk.
  public query func rulesView() : async [{ epoch : Nat; current : Nat; walkSections : Nat; newestSections : Nat; atBlock : Nat }] {
    [{ epoch = Rules.epoch(later); current = Rules.CURRENT; walkSections = Rules.walkSections(later); newestSections = Rules.SECTIONS_AT[Rules.CURRENT]; atBlock = DL.length(log) }]
  };

  public query func cardRuleView() : async [{ on : Bool; fromBlock : Nat; atBlock : Nat }] {
    switch (RowStore.get<R.CardPolicy>(St.later(later, St.CARD_POLICY_TABLE), R.cardPolicy, St.CARD_POLICY_ID)) {
      case (?p) [{ on = true; fromBlock = p.fromBlock; atBlock = DL.length(log) }];
      case null [{ on = false; fromBlock = 0; atBlock = DL.length(log) }];
    }
  };

  public shared ({ caller }) func setPlanInclusions(session : Text, planId : Nat, inclusions : Text) : async Reply {
    switch (readInclusions(inclusions)) {
      case null [refusal("invalid", "The inclusions could not be read.")];
      case (?incs) [await* asPerson(caller, session, func(p) { #setPlanInclusions({ staff = p; planId; inclusions = incs }) })];
    }
  };

  func readInclusions(t : Text) : ?[Cmd.InclusionFacts] {
    if (t == "") return ?[];
    let out = List.empty<Cmd.InclusionFacts>();
    for (part in Text.split(t, #char ';')) {
      let f = Iter.toArray(Text.split(part, #char ':'));
      if (f.size() != 4 or out.size() >= R.MAX_INCLUSIONS) return null;
      let ?extraId = Nat.fromText(f[0]) else return null;
      let ?quantity = Nat.fromText(f[1]) else return null;
      let rhythm : E.Rhythm = switch (f[2]) { case "everyNight" #everyNight; case "arrivalNight" #arrivalNight; case _ return null };
      let per : E.Per = switch (f[3]) { case "room" #room; case "adult" #adult; case "guest" #guest; case _ return null };
      List.add(out, { extraId; quantity; rhythm; per });
    };
    ?List.toArray(out)
  };

  public type InclusionRow = { slot : Nat; extraId : Nat; code : Text; nameEn : Text; nameAr : Text; category : Text; price : Nat; quantity : Nat;
    rhythm : Text; per : Text; atBlock : Nat };

  /// A plan's package as the guest site shows it under the plan's name: each inclusion on sale, the
  /// extra's names and catalogue price, how many per room, adult or guest, and when it is given. Public:
  /// what a rate includes is what it sells. Empty for a plain rate.
  public query func packageView(planId : Nat) : async [InclusionRow] {
    let blk = DL.length(log);
    let out = List.empty<InclusionRow>();
    for ((slot, inc) in St.inclusionsOf(later, planId).vals()) {
      switch (St.extra(later, inc.extraId)) {
        case (?e) List.add(out, { slot; extraId = inc.extraId; code = e.code; nameEn = TA.get(s.arena, e.nameEn); nameAr = TA.get(s.arena, e.nameAr);
          category = E.extraCategoryText(e.category); price = e.price; quantity = inc.quantity; rhythm = E.rhythmText(inc.rhythm); per = E.perText(inc.per); atBlock = blk });
        case null {};
      };
    };
    List.toArray(out)
  };

  public type PackageLineRow = { day : Nat; slot : Nat; extraId : Nat; quantity : Nat; unit : Nat; net : Nat; tax : Nat };

  /// The package lines of a quote, night by night: the breakdown a guest opens under the one price. The
  /// room's own lines are `quoteNightsView`; together they are the whole total.
  public query func quotePackageView(roomTypeId : Nat, planId : Nat, arrival : Nat, nights : Nat, rooms : Nat, adults : Nat, children : Nat, code : Text) : async [PackageLineRow] {
    let c = ctx();
    let grant = if (code == "") Acc.PUBLIC else switch (Acc.resolve(c, code)) { case (#ok g) g; case (#err _) return [] };
    switch (Res.quoteStayFor(c, { roomTypeId; planId; arrival; nights; rooms; adults; children }, Acc.forPlan(c, grant, planId))) {
      case (#err _) [];
      case (#ok ch) Array.map<Q.IncLine, PackageLineRow>(ch.quote.inclusions, func(l) {
        var tax = 0;
        for ((_, a) in l.taxes.vals()) tax += a;
        { day = l.night; slot = l.slot; extraId = l.extraId; quantity = l.quantity; unit = l.unit; net = l.net; tax }
      });
    }
  };

  /// Who a rate plan is sold to: everyone (closed false, no company), one company (closed, its id), or
  /// only under a promotion's code (closed, no company). a: the plan.
  public shared ({ caller }) func setPlanAccess(session : Text, planId : Nat, companyId : Nat, closed : Bool) : async Reply {
    [await* asPerson(caller, session, func(p) { #setPlanAccess({ staff = p; planId; companyId; closed }) })]
  };

  /// The companies with negotiated rates, in id order. Staff only: the list of a hotel's corporate
  /// accounts is its own business.
  public shared query ({ caller }) func companiesView(session : Text) : async [{ id : Nat; code : Text; name : Text; active : Bool; atBlock : Nat }] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let pg = RowStore.pageById<R.Company>(St.later(later, St.COMPANY_TABLE), R.company, 1, RP.MAX_COMPANIES, null, RP.MAX_COMPANIES);
    let at = DL.length(log);
    Array.map<(Nat, R.Company), { id : Nat; code : Text; name : Text; active : Bool; atBlock : Nat }>(pg.rows, func((id, co)) {
      { id; code = co.code; name = TA.get(s.arena, co.name); active = co.active; atBlock = at }
    })
  };

  /// Who each plan with an access row is sold to. Staff only. A plan with no row is on public sale.
  public shared query ({ caller }) func planAccessView(session : Text) : async [{ planId : Nat; companyId : Nat; closed : Bool; atBlock : Nat }] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let pg = RowStore.pageById<R.PlanAccess>(St.later(later, St.PLAN_ACCESS_TABLE), R.planAccess, 1, St.MAX_PLANS, null, St.MAX_PLANS);
    let at = DL.length(log);
    Array.map<(Nat, R.PlanAccess), { planId : Nat; companyId : Nat; closed : Bool; atBlock : Nat }>(pg.rows, func((planId, a)) {
      { planId; companyId = a.companyId; closed = a.closed; atBlock = at }
    })
  };

  /// What a code opens, for the guest who typed it: whose rate it is and which plans it admits that the
  /// public search does not show, one row per plan (a single row with plan 0 when it opens none). A code
  /// that opens nothing says so, in the same words a hold would.
  public query func codeView(code : Text) : async [{ ok : Bool; kind : Text; reason : Text; name : Text; planId : Nat; atBlock : Nat }] {
    let c = ctx();
    switch (Acc.resolve(c, code)) {
      case (#err f) [{ ok = false; kind = Rf.kind(f); reason = Rf.text(f); name = ""; planId = 0; atBlock = c.block }];
      case (#ok g) {
        let (kind, name) = if (g.companyId != 0) ("company", switch (St.company(later, g.companyId)) { case (?co) TA.get(s.arena, co.name); case null "" })
          else ("promotion", switch (St.promo(later, g.promoId)) { case (?pr) TA.get(s.arena, pr.name); case null "" });
        let opens = Acc.opens(c, g);
        if (opens.size() == 0) return [{ ok = true; kind; reason = ""; name; planId = 0; atBlock = c.block }];
        Array.map<Nat, { ok : Bool; kind : Text; reason : Text; name : Text; planId : Nat; atBlock : Nat }>(opens, func(planId) { { ok = true; kind; reason = ""; name; planId; atBlock = c.block } })
      };
    }
  };

  /// A guest in house moves from one of their rooms to a free room of the same type. a: the booking, b: the room.
  public shared ({ caller }) func moveRoom(session : Text, bookingId : Nat, fromRoomId : Nat, toRoomId : Nat) : async Reply {
    [await* asPerson(caller, session, func(p) { #moveRoom({ staff = p; bookingId; fromRoomId; toRoomId }) })]
  };

  /// How a booking came, when staff took it: "phone" or "walkIn", who took it and on which business day.
  /// Empty for a booking a guest made online.
  public shared query ({ caller }) func staffBookingView(session : Text, bookingId : Nat) : async [{ channel : Text; madeBy : Text; day : Nat; atBlock : Nat }] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    switch (St.staffBooking(later, bookingId)) {
      case (?x) [{ channel = E.channelText(x.channel); madeBy = St.principalHex(x.madeBy); day = x.day; atBlock = DL.length(log) }];
      case null [];
    }
  };

  /// The night audit's figures are the hotel's management figures: the owner, revenue management and
  /// the auditor read them; the front desk and housekeeping do not.
  func seesFigures(who : Principal) : Bool {
    St.holdsRole(s, who, #owner) or St.holdsRole(s, who, #revenue) or St.holdsRole(s, who, #auditor)
  };

  public type FiguresRow = {
    day : Nat; roomsTotal : Nat; roomsOut : Nat; roomsSold : Nat; roomRevenue : Nat; arrivals : Nat; noShows : Nat;
    pickupBookings : Nat; pickupNights : Nat; pickupRevenue : Nat; pickupFrom : Nat; closed : Bool; atBlock : Nat;
  };

  /// The audited days' figures from `fromDay`, at most 62 days. A day the audit has not written has no
  /// row; `closed` is true once that day's audit has closed it (the figures of an open day are partial).
  /// Occupancy is roomsSold over roomsTotal less roomsOut; ADR is roomRevenue over roomsSold; RevPAR is
  /// roomRevenue over roomsTotal less roomsOut. Room revenue is the night's room charges before tax as
  /// posted; credit notes are documents of their own, dated the day they are issued.
  public shared query ({ caller }) func dayFiguresView(session : Text, fromDay : Nat, days : Nat) : async [FiguresRow] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not seesFigures(who)) return [];
    let n = Nat.min(Nat.max(days, 1), 62);
    let t = St.later(later, St.DAY_FIGURES_TABLE);
    let pg = RowStore.pageById<R.DayFigures>(t, R.dayFigures, fromDay, fromDay + n - 1, null, n);
    let open = today();
    Array.map<(Nat, R.DayFigures), FiguresRow>(pg.rows, func((day, f)) {
      { day; roomsTotal = f.roomsTotal; roomsOut = f.roomsOut; roomsSold = f.roomsSold; roomRevenue = f.roomRevenue; arrivals = f.arrivals; noShows = f.noShows;
        pickupBookings = f.pickupBookings; pickupNights = f.pickupNights; pickupRevenue = f.pickupRevenue; pickupFrom = f.pickupFrom;
        closed = day < open; atBlock = DL.length(log) }
    })
  };

  /// The audited nights' room nights and room revenue by room type and rate plan, from `fromDay`, at
  /// most 62 nights: one row per night, type and plan that sold a room.
  public shared query ({ caller }) func dayRevenueView(session : Text, fromDay : Nat, days : Nat) : async [{ day : Nat; roomTypeId : Nat; planId : Nat; roomNights : Nat; revenue : Nat; atBlock : Nat }] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not seesFigures(who)) return [];
    let n = Nat.min(Nat.max(days, 1), 62);
    let at = DL.length(log);
    let out = List.empty<{ day : Nat; roomTypeId : Nat; planId : Nat; roomNights : Nat; revenue : Nat; atBlock : Nat }>();
    for (d in Nat.range(fromDay, fromDay + n)) {
      for ((_, r) in St.dayRevenueOf(later, d).vals()) List.add(out, { day = d; roomTypeId = r.roomTypeId; planId = r.planId; roomNights = r.roomNights; revenue = r.revenue; atBlock = at });
    };
    List.toArray(out)
  };

  /// What is on the books for the nights [fromDay, fromDay + days), days at most 62: room nights and
  /// room revenue by night, room type and plan, from the confirmed bookings and the guests in house
  /// that cover those nights. Read in pages of at most 50 bookings, in arrival order; a page names
  /// where the next one starts (`nextArrival`, `nextId`), and `done` is true on the last. The caller
  /// adds the pages up; a row repeats (night, type, plan) only across pages.
  public shared query ({ caller }) func onTheBooksView(session : Text, fromDay : Nat, days : Nat, afterArrival : Nat, afterId : Nat, limit : Nat) :
    async [{ night : Nat; roomTypeId : Nat; planId : Nat; roomNights : Nat; revenue : Nat; nextArrival : Nat; nextId : Nat; done : Bool; atBlock : Nat }] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not seesFigures(who)) return [];
    let n = Nat.min(Nat.max(days, 1), 62);
    let maxStay = switch (St.property(s)) { case (?p) p.maxStayNights; case null 1 };
    let firstArrival : Nat = if (fromDay + 1 > maxStay) fromDay + 1 - maxStay else 0;
    let lo = if (afterArrival == 0 and afterId == 0) SR.key2(firstArrival, W.DAY, 0, W.ID) else SR.key2(afterArrival, W.DAY, afterId + 1, W.ID);
    let hi = SR.key2(fromDay + n - 1, W.DAY, St.MAX_ID, W.ID);
    if (Blob.compare(lo, hi) == #greater) return [];
    let pg = switch (RowStore.page<R.Booking>(s.bookings, R.booking, "by_arrival", lo, hi, null, Nat.min(Nat.max(limit, 1), 50))) { case (#ok p) p; case (#err _) return [] };
    let sums = Map.empty<Text, (Nat, Nat, Nat, Nat, Nat)>();
    var lastArrival = afterArrival; var lastId = afterId;
    for ((id, b) in pg.rows.vals()) {
      lastArrival := b.arrival; lastId := id;
      if (b.status == #confirmed or b.status == #checkedIn) {
        for ((_, l) in St.folioOf(s, id).vals()) {
          if (l.kind == #roomNight and l.night >= fromDay and l.night < fromDay + n) {
            let k = Nat.toText(l.night) # "/" # Nat.toText(b.roomTypeId) # "/" # Nat.toText(b.planId);
            let (_, _, _, rn, rv) = switch (Map.get(sums, Text.compare, k)) { case (?x) x; case null (l.night, b.roomTypeId, b.planId, 0, 0) };
            Map.add(sums, Text.compare, k, (l.night, b.roomTypeId, b.planId, rn + b.rooms, rv + l.amount));
          };
        };
      };
    };
    let done = pg.next == null;
    let at = DL.length(log);
    let rows = List.empty<{ night : Nat; roomTypeId : Nat; planId : Nat; roomNights : Nat; revenue : Nat; nextArrival : Nat; nextId : Nat; done : Bool; atBlock : Nat }>();
    for ((_, (night, rt, plan, rn, rv)) in Map.entries(sums)) List.add(rows, { night; roomTypeId = rt; planId = plan; roomNights = rn; revenue = rv; nextArrival = lastArrival; nextId = lastId; done; atBlock = at });
    // a page with no night to add still says where the next one starts
    if (List.size(rows) == 0) List.add(rows, { night = 0; roomTypeId = 0; planId = 0; roomNights = 0; revenue = 0; nextArrival = lastArrival; nextId = lastId; done; atBlock = at });
    List.toArray(rows)
  };

  public shared ({ caller }) func checkOut(session : Text, bookingId : Nat) : async Reply {
    [await* asPerson(caller, session, func(p) { #checkOut({ staff = p; bookingId }) })]
  };

  public shared ({ caller }) func settleAtDesk(session : Text, bookingId : Nat, authId : Nat) : async Reply {
    let facts = switch (await* authFacts(authId)) { case (#ok f) f; case (#err why) return [refusal("payment", why)] };
    let out = await* asPerson(caller, session, func(p) { #settleAtDesk({ staff = p; bookingId; auth = facts }) });
    if (out.ok) ignore await* drain(caller, bookingId, 2);
    [out]
  };

  public shared ({ caller }) func openAudit(session : Text, day : Nat) : async Reply { [await* asPerson(caller, session, func(p) { #openAudit({ staff = p; day }) })] };
  public shared ({ caller }) func advanceAudit(session : Text, day : Nat, limit : Nat) : async Reply { [await* asPerson(caller, session, func(p) { #advanceAudit({ staff = p; day; limit }) })] };
  public shared ({ caller }) func closeDay(session : Text, day : Nat) : async Reply { [await* asPerson(caller, session, func(p) { #closeDay({ staff = p; day }) })] };

  // ── the bill ──────────────────────────────────────────────────────────────

  func categoryOf(t : Text) : ?E.ExtraCategory {
    switch t { case "restaurant" ?#restaurant; case "minibar" ?#minibar; case "spa" ?#spa; case "parking" ?#parking; case "breakfast" ?#breakfast; case "other" ?#other; case _ null }
  };

  public shared ({ caller }) func upsertExtra(session : Text, id : Nat, code : Text, nameEn : Text, nameAr : Text, category : Text, price : Nat, taxed : Bool, active : Bool) : async Reply {
    let ?cat = categoryOf(category) else return [refusal("invalid", "There is no category " # category # ".")];
    [await* asPerson(caller, session, func(p) { #upsertExtra({ staff = p; id; facts = { code; nameEn; nameAr; category = cat; price; taxed; active } }) })]
  };

  /// The extras catalogue, in id order. Nothing here is private: it is the hotel's price list.
  public query func extrasView() : async [{ id : Nat; code : Text; nameEn : Text; nameAr : Text; category : Text; price : Nat; taxed : Bool; active : Bool; atBlock : Nat }] {
    let p = RowStore.pageById<R.Extra>(St.later(later, St.EXTRA_TABLE), R.extra, 1, St.MAX_ID, null, Bill.MAX_EXTRAS);
    let at = DL.length(log);
    Array.map<(Nat, R.Extra), { id : Nat; code : Text; nameEn : Text; nameAr : Text; category : Text; price : Nat; taxed : Bool; active : Bool; atBlock : Nat }>(p.rows, func((id, e)) {
      { id; code = e.code; nameEn = TA.get(s.arena, e.nameEn); nameAr = TA.get(s.arena, e.nameAr); category = E.extraCategoryText(e.category); price = e.price; taxed = e.taxed; active = e.active; atBlock = at }
    })
  };

  public shared ({ caller }) func postCharge(session : Text, bookingId : Nat, extraId : Nat, quantity : Nat, amount : Nat, payerId : Nat) : async Reply {
    let out = await* asPerson(caller, session, func(p) { #postCharge({ staff = p; bookingId; extraId; quantity; amount; payerId }) });
    // a charge on the guest's bill may have queued a capture on the guest's card
    if (out.ok) ignore await* drain(caller, bookingId, 2);
    [out]
  };

  public shared ({ caller }) func addPayer(session : Text, bookingId : Nat, name : Text) : async Reply {
    [await* asPerson(caller, session, func(p) { #addPayer({ staff = p; bookingId; name }) })]
  };

  public shared ({ caller }) func routeLines(session : Text, bookingId : Nat, lineIds : [Nat], payerId : Nat) : async Reply {
    let out = await* asPerson(caller, session, func(p) { #routeLines({ staff = p; bookingId; lineIds; payerId }) });
    if (out.ok) ignore await* drain(caller, bookingId, 2);
    [out]
  };

  public shared ({ caller }) func settleShare(session : Text, bookingId : Nat, payerId : Nat, authId : Nat) : async Reply {
    let facts = switch (await* authFacts(authId)) { case (#ok f) f; case (#err why) return [refusal("payment", why)] };
    let out = await* asPerson(caller, session, func(p) { #settleShare({ staff = p; bookingId; payerId; auth = facts }) });
    if (out.ok) ignore await* drain(caller, bookingId, 2);
    [out]
  };

  public shared ({ caller }) func issueInvoice(session : Text, bookingId : Nat, payerId : Nat) : async Reply {
    [await* asPerson(caller, session, func(p) { #issueInvoice({ staff = p; bookingId; payerId }) })]
  };

  // ── credit notes ──────────────────────────────────────────────────────────

  /// Propose a credit note against invoice `invoice` of booking `bookingId`: the lines it takes back and
  /// how much of each before tax (`amounts`, in the order of `lineIds`); their taxes on the bill go with
  /// them. A second member of staff approves it (`approve`), and the bill's card is refunded then.
  public shared ({ caller }) func proposeCreditNote(session : Text, bookingId : Nat, invoice : Nat, lineIds : [Nat], amounts : [Nat], justification : Text) : async Reply {
    [await* asPerson(caller, session, func(p) { #propose({ staff = p; act = #issueCreditNote({ bookingId; invoice; lineIds; amounts }); justification }) })]
  };

  func deskMethodOf(t : Text) : ?E.DeskMethod { switch t { case "cash" ?#cash; case "transfer" ?#transfer; case _ null } };

  /// Propose recording a refund the gateway would not make as paid at the desk, in cash or by transfer,
  /// with the receipt number or the transfer's reference. A second member of staff approves it.
  public shared ({ caller }) func proposeDeskRefund(session : Text, bookingId : Nat, paymentId : Nat, method : Text, reference : Text, justification : Text) : async Reply {
    let ?m = deskMethodOf(method) else return [refusal("invalid", "A refund at the desk is paid in cash or by transfer.")];
    [await* asPerson(caller, session, func(p) { #propose({ staff = p; act = #refundAtDesk({ bookingId; paymentId; method = m; reference }); justification }) })]
  };

  /// The tax authority's type and sub-type of a tax rule (T1 and V009 for VAT, for example). The owner's.
  public shared ({ caller }) func setTaxEta(session : Text, taxRuleId : Nat, taxType : Text, subType : Text) : async Reply {
    [await* asPerson(caller, session, func(p) { #setTaxEta({ staff = p; taxRuleId; taxType; subType }) })]
  };

  /// The hotel's registration with the tax authority, as its documents name the issuer. The owner's.
  public shared ({ caller }) func setEtaProfile(session : Text, issuerId : Text, activityCode : Text, branchId : Text, country : Text, governate : Text,
    regionCity : Text, street : Text, buildingNumber : Text) : async Reply {
    [await* asPerson(caller, session, func(p) { #setEtaProfile({ staff = p; facts = { issuerId; activityCode; branchId; country; governate; regionCity; street; buildingNumber } }) })]
  };

  func chargeName(lineId : Nat) : Text {
    switch (St.charge(later, lineId)) {
      case (?ch) { switch (St.extra(later, ch.extraId)) { case (?e) TA.get(s.arena, e.nameEn); case null "" } };
      case null "";
    }
  };

  public type BillWindow = { payerId : Nat; name : Text; charges : Nat; credits : Nat; taxes : Nat; paid : Nat; due : Nat; open : Nat; invoice : Nat; atBlock : Nat };

  /// The windows of a booking's bill, the guest's first (its name is the guest's).
  public shared query ({ caller }) func billView(session : Text, bookingId : Nat) : async [BillWindow] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let ?b = St.booking(s, bookingId) else return [];
    let at = DL.length(log);
    Array.map<Win.Window, BillWindow>(Win.all(s, later, bookingId), func(w) {
      let name = if (w.payerId == 0) TA.get(s.arena, b.guestName) else switch (St.payer(later, w.payerId)) { case (?p) TA.get(s.arena, p.name); case null "" };
      let invoice = switch (St.invoiceOf(later, bookingId, w.payerId)) { case (?(n, _)) n; case null 0 };
      { payerId = w.payerId; name; charges = w.charges; credits = w.credits; taxes = w.taxes; paid = w.paid; due = w.due; open = Win.open(w); invoice; atBlock = at }
    })
  };

  public type BillLine = { id : Nat; kind : Text; code : Nat; night : Nat; amount : Nat; payerId : Nat; title : Text; titleAr : Text; quantity : Nat; unitAmount : Nat;
    voided : Bool; voidable : Bool; atBlock : Nat };

  /// Every line of a booking's bill with its window and what it is: the extra's name and quantity, the
  /// tax rule's name. `voided` marks a voided charge, its taxes and the credit that voided it.
  public shared query ({ caller }) func billLinesView(session : Text, bookingId : Nat) : async [BillLine] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let at = DL.length(log);
    let out = List.empty<BillLine>();
    for (w in Win.all(s, later, bookingId).vals()) {
      for ((id, l, voided) in Bill.linesOf(s, later, bookingId, w.payerId).vals()) {
        let (title, titleAr, quantity, unitAmount, voidable) : (Text, Text, Nat, Nat, Bool) = switch (l.kind) {
          case (#extra) {
            switch (St.charge(later, id)) {
              case (?ch) {
                let (en, ar) = switch (St.extra(later, ch.extraId)) { case (?e) (TA.get(s.arena, e.nameEn), TA.get(s.arena, e.nameAr)); case null ("", "") };
                // a package's inclusion is credited, never voided alone (Bill.voidCharge refuses it)
                (en, ar, ch.quantity, ch.unitAmount, ch.voidLine == 0 and St.invoiceOf(later, bookingId, w.payerId) == null and St.packageLine(later, id) == null)
              };
              case null ("", "", 1, l.amount, false);
            }
          };
          case (#tax or #extraTax) { switch (taxName(l.code)) { case (en, ar) (en, ar, 1, l.amount, false) } };
          case _ ("", "", 1, l.amount, false);
        };
        List.add(out, { id; kind = E.folioKindText(l.kind); code = l.code; night = l.night; amount = l.amount; payerId = w.payerId; title; titleAr; quantity; unitAmount;
          voided; voidable; atBlock = at });
      };
    };
    List.toArray(out)
  };

  func taxName(ruleId : Nat) : (Text, Text) {
    switch (RowStore.get<R.TaxRule>(s.taxes, R.taxRule, ruleId)) { case (?r) (TA.get(s.arena, r.nameEn), TA.get(s.arena, r.nameAr)); case null ("", "") }
  };

  /// An invoice as the hotel prints it: the hotel, the number, the day, who pays, and its figures.
  /// Its lines are `billLinesView` of its window, less the lines of its credit notes (kind "credit",
  /// code 2): nothing else goes on an invoiced bill. Its notes are `creditNotesView` of its booking.
  public shared query ({ caller }) func invoiceView(session : Text, number : Nat) : async [{ number : Nat; bookingId : Nat; ref : Text; payerId : Nat; payerName : Text;
    guestName : Text; issuedDay : Nat; charges : Nat; credits : Nat; taxes : Nat; paid : Nat; hotelEn : Text; hotelAr : Text; currency : Text; minorUnits : Nat }] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let ?inv = St.invoice(later, number) else return [];
    let ?b = St.booking(s, inv.bookingId) else return [];
    let ?p = St.property(s) else return [];
    let payerName = if (inv.payerId == 0) TA.get(s.arena, b.guestName) else switch (St.payer(later, inv.payerId)) { case (?x) TA.get(s.arena, x.name); case null "" };
    [{ number; bookingId = inv.bookingId; ref = Ref.of(inv.bookingId); payerId = inv.payerId; payerName; guestName = TA.get(s.arena, b.guestName); issuedDay = inv.issuedDay;
      charges = inv.charges; credits = inv.credits; taxes = inv.taxes; paid = inv.paid; hotelEn = TA.get(s.arena, p.nameEn); hotelAr = TA.get(s.arena, p.nameAr);
      currency = p.currency; minorUnits = p.minorUnits }]
  };

  func principalHex(p : Principal) : Text { C.hex(Principal.toBlob(p)) };

  /// Who proposed and who approved the act a proposal carried.
  func makerChecker(proposal : Nat) : (Text, Text) {
    switch (St.proposal(s, proposal)) {
      case (?p) (principalHex(p.maker), switch (p.checker) { case (?k) principalHex(k); case null "" });
      case null ("", "");
    }
  };

  public type CreditNoteRow = { number : Nat; invoice : Nat; bookingId : Nat; payerId : Nat; issuedDay : Nat; net : Nat; taxes : Nat; total : Nat;
    lines : Nat; maker : Text; checker : Text; atBlock : Nat };

  func noteRow(n : Nat, cn : R.CreditNote) : CreditNoteRow {
    let (maker, checker) = makerChecker(cn.proposal);
    { number = n; invoice = cn.invoice; bookingId = cn.bookingId; payerId = cn.payerId; issuedDay = cn.issuedDay; net = cn.net; taxes = cn.taxes; total = cn.total;
      lines = cn.lines; maker; checker; atBlock = DL.length(log) }
  };

  /// The credit notes against a booking's invoices, bill by bill, each in number order.
  public shared query ({ caller }) func creditNotesView(session : Text, bookingId : Nat) : async [CreditNoteRow] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let out = List.empty<CreditNoteRow>();
    for (w in Win.all(s, later, bookingId).vals()) {
      switch (St.invoiceOf(later, bookingId, w.payerId)) {
        case (?(inv, _)) { for ((n, cn) in St.notesOf(later, inv).vals()) List.add(out, noteRow(n, cn)) };
        case null {};
      };
    };
    List.toArray(out)
  };

  /// A credit note as the hotel prints it: the hotel, its number, the invoice it amends, who receives it,
  /// its figures, and who proposed and approved it.
  public shared query ({ caller }) func creditNoteView(session : Text, number : Nat) : async [{ number : Nat; invoice : Nat; invoiceDay : Nat; bookingId : Nat; ref : Text;
    payerId : Nat; payerName : Text; guestName : Text; issuedDay : Nat; net : Nat; taxes : Nat; total : Nat; maker : Text; checker : Text; hotelEn : Text; hotelAr : Text;
    currency : Text; minorUnits : Nat; atBlock : Nat }] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let ?cn = St.creditNote(later, number) else return [];
    let ?b = St.booking(s, cn.bookingId) else return [];
    let ?p = St.property(s) else return [];
    let invoiceDay = switch (St.invoice(later, cn.invoice)) { case (?i) i.issuedDay; case null 0 };
    let payerName = if (cn.payerId == 0) TA.get(s.arena, b.guestName) else switch (St.payer(later, cn.payerId)) { case (?x) TA.get(s.arena, x.name); case null "" };
    let (maker, checker) = makerChecker(cn.proposal);
    [{ number; invoice = cn.invoice; invoiceDay; bookingId = cn.bookingId; ref = Ref.of(cn.bookingId); payerId = cn.payerId; payerName; guestName = TA.get(s.arena, b.guestName);
      issuedDay = cn.issuedDay; net = cn.net; taxes = cn.taxes; total = cn.total; maker; checker; hotelEn = TA.get(s.arena, p.nameEn); hotelAr = TA.get(s.arena, p.nameAr);
      currency = p.currency; minorUnits = p.minorUnits; atBlock = DL.length(log) }]
  };

  /// A credit note's lines, in order: each credit, the line it takes back, and what that line was.
  public shared query ({ caller }) func creditNoteLinesView(session : Text, number : Nat) : async [{ id : Nat; source : Nat; sourceKind : Text; title : Text; titleAr : Text;
    night : Nat; amount : Nat; tax : Bool }] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let ?cn = St.creditNote(later, number) else return [];
    let out = List.empty<{ id : Nat; source : Nat; sourceKind : Text; title : Text; titleAr : Text; night : Nat; amount : Nat; tax : Bool }>();
    for (id in Nat.range(cn.firstLine, cn.firstLine + cn.lines)) {
      switch (St.folioLine(s, id), St.creditLine(later, id)) {
        case (?l, ?cl) {
          switch (St.folioLine(s, cl.source)) {
            case (?src) {
              let (title, titleAr) = switch (src.kind) {
                case (#extra) { let t = chargeName(cl.source); (t, switch (St.charge(later, cl.source)) { case (?ch) { switch (St.extra(later, ch.extraId)) { case (?e) TA.get(s.arena, e.nameAr); case null t } }; case null t }) };
                case (#tax or #extraTax) taxName(src.code);
                case _ ("", "");
              };
              List.add(out, { id; source = cl.source; sourceKind = E.folioKindText(src.kind); title; titleAr; night = src.night; amount = l.amount; tax = CN.isTax(src.kind) });
            };
            case null {};
          };
        };
        case _ {};
      };
    };
    List.toArray(out)
  };

  /// How much of each line of a booking credit notes have taken back, for the lines that have had any.
  public shared query ({ caller }) func creditedLinesView(session : Text, bookingId : Nat) : async [{ lineId : Nat; credited : Nat; atBlock : Nat }] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let out = List.empty<{ lineId : Nat; credited : Nat; atBlock : Nat }>();
    for ((id, l) in St.folioOf(s, bookingId).vals()) {
      if (CN.reversible(l.kind) or CN.isTax(l.kind)) {
        let c = St.creditedOf(s, later, id);
        if (c > 0) List.add(out, { lineId = id; credited = c; atBlock = DL.length(log) });
      };
    };
    List.toArray(out)
  };

  /// A credit note as the tax authority's document (type C): its JSON, the SHA-256 of the authority's
  /// serialisation of it (what a seal is made over), its total, and what a submission still needs, one
  /// item a line. Luxor does not submit it.
  public shared query ({ caller }) func creditNoteEtaView(session : Text, number : Nat) : async [{ json : Text; digest : Text; total : Nat; missing : Text; atBlock : Nat }] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let ?r = Eta.creditNote(ctx(), number) else return [];
    let t = Eta.totals(r.doc);
    [{ json = Eta.json(r.doc); digest = C.hex(Eta.digest(r.doc)); total = t.sales + t.tax; missing = Text.join(r.missing.vals(), "\n"); atBlock = DL.length(log) }]
  };

  /// The hotel's registration with the tax authority ("" everywhere until the owner gives it).
  public shared query ({ caller }) func etaProfileView(session : Text) : async [{ issuerId : Text; activityCode : Text; branchId : Text; country : Text; governate : Text;
    regionCity : Text; street : Text; buildingNumber : Text; atBlock : Nat }] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let a = s.arena;
    switch (St.etaProfile(later)) {
      case (?f) [{ issuerId = TA.get(a, f.issuerId); activityCode = f.activityCode; branchId = TA.get(a, f.branchId); country = f.country; governate = TA.get(a, f.governate);
        regionCity = TA.get(a, f.regionCity); street = TA.get(a, f.street); buildingNumber = TA.get(a, f.buildingNumber); atBlock = DL.length(log) }];
      case null [{ issuerId = ""; activityCode = ""; branchId = ""; country = ""; governate = ""; regionCity = ""; street = ""; buildingNumber = ""; atBlock = DL.length(log) }];
    }
  };

  /// Every tax rule's codes with the authority ("" for a rule not yet given them).
  public shared query ({ caller }) func taxEtaView(session : Text) : async [{ taxRuleId : Nat; taxType : Text; subType : Text; atBlock : Nat }] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let pg = RowStore.pageById<R.TaxRule>(s.taxes, R.taxRule, 1, St.MAX_TAX_RULES, null, St.MAX_TAX_RULES);
    Array.map<(Nat, R.TaxRule), { taxRuleId : Nat; taxType : Text; subType : Text; atBlock : Nat }>(pg.rows, func((id, _)) {
      switch (St.taxEta(later, id)) {
        case (?e) ({ taxRuleId = id; taxType = e.taxType; subType = e.subType; atBlock = DL.length(log) });
        case null ({ taxRuleId = id; taxType = ""; subType = ""; atBlock = DL.length(log) });
      }
    })
  };

  /// A refund as staff and the guest read it: the card it goes back to as the gateway names it (0: no
  /// card, the desk pays it), the bill it is on, and where it stands: due at the gateway, done, failed
  /// (the gateway would not make it), or paid at the desk. A refund to the guest also names the settle
  /// that split it across the guest's cards: its first slice, the whole it split, and the block.
  public type RefundRow = { paymentId : Nat; payerId : Nat; card : Nat; amount : Nat; state : Text; attempts : Nat; firstSlice : Nat; excess : Nat; written : Nat };

  func refundRow(pid : Nat, p : R.Payment) : RefundRow {
    let state = switch (p.state) {
      case (#due) "due";
      case (#done) "done";
      case (#failed) { if (St.deskRefund(later, pid) != null) "paidAtDesk" else "failed" };
    };
    let (firstSlice, excess, written) = switch (St.refundSlice(later, pid)) { case (?r) (r.firstSlice, r.excess, r.written); case null (0, 0, 0) };
    { paymentId = pid; payerId = St.paymentWindow(later, pid); card = p.gatewayAuth; amount = p.amount; state; attempts = p.attempts; firstSlice; excess; written }
  };

  /// Every refund of a booking, in the order written.
  public shared query ({ caller }) func refundsView(session : Text, bookingId : Nat) : async [RefundRow] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let out = List.empty<RefundRow>();
    for ((id, p) in St.paymentsOf(s, bookingId).vals()) { if (p.kind == #refunded) List.add(out, refundRow(id, p)) };
    List.toArray(out)
  };

  /// Where a credit note's refund went: the slices its approval wrote across the guest's own cards, in
  /// the order drawn. A note that left nothing paid over its bill wrote none. A note on another payer's
  /// bill refunds through that payer's own card, never split; that refund is on the bill.
  public shared query ({ caller }) func creditNoteRefundView(session : Text, number : Nat) : async [RefundRow] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let ?cn = St.creditNote(later, number) else return [];
    let out = List.empty<RefundRow>();
    for ((id, p) in St.paymentsOf(s, cn.bookingId).vals()) {
      switch (St.refundSlice(later, id)) { case (?r) { if (r.written == cn.lastBlock) List.add(out, refundRow(id, p)) }; case null {} };
    };
    List.toArray(out)
  };

  /// The refunds of a booking paid at the desk because the gateway would not make them.
  public shared query ({ caller }) func deskRefundsView(session : Text, bookingId : Nat) : async [{ paymentId : Nat; method : Text; reference : Text; day : Nat;
    maker : Text; checker : Text; atBlock : Nat }] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let out = List.empty<{ paymentId : Nat; method : Text; reference : Text; day : Nat; maker : Text; checker : Text; atBlock : Nat }>();
    for ((id, p) in St.paymentsOf(s, bookingId).vals()) {
      if (p.kind == #refunded and p.state == #failed) {
        switch (St.deskRefund(later, id)) {
          case (?d) {
            let (maker, checker) = makerChecker(d.proposal);
            List.add(out, { paymentId = id; method = E.deskMethodText(d.method); reference = TA.get(s.arena, d.reference); day = d.day; maker; checker; atBlock = DL.length(log) });
          };
          case null {};
        };
      };
    };
    List.toArray(out)
  };

  // ── housekeeping ──────────────────────────────────────────────────────────

  func cleaningOf(t : Text) : ?E.Cleaning { switch t { case "dirty" ?#dirty; case "clean" ?#clean; case "inspected" ?#inspected; case _ null } };

  public shared ({ caller }) func markRoom(session : Text, roomId : Nat, cleaning : Text) : async Reply {
    let ?c = cleaningOf(cleaning) else return [refusal("invalid", "A room is marked dirty, clean or inspected.")];
    [await* asPerson(caller, session, func(p) { #markRoom({ staff = p; roomId; cleaning = c }) })]
  };

  public shared ({ caller }) func takeRoomOutOfOrder(session : Text, roomId : Nat, reason : Text, untilDay : Nat) : async Reply {
    [await* asPerson(caller, session, func(p) { #takeRoomOutOfOrder({ staff = p; roomId; reason; untilDay }) })]
  };

  public shared ({ caller }) func returnRoomToService(session : Text, roomId : Nat) : async Reply {
    [await* asPerson(caller, session, func(p) { #returnRoomToService({ staff = p; roomId }) })]
  };

  public type BoardRow = { id : Nat; number : Text; roomTypeId : Nat; outOfOrder : Bool; cleaning : Text; cleanedBy : Text; inspectedBy : Text;
    cleanedByMe : Bool; inspectedByMe : Bool; outReason : Text; outFrom : Nat; outUntil : Nat; changedDay : Nat; occupiedBy : Nat; departure : Nat; atBlock : Nat };

  /// The housekeeping board: every room after `afterId`, in id order, at most 200 a page; the last row's
  /// id is where the next page starts. `cleaning` is "" for a room with no record yet.
  public shared query ({ caller }) func housekeepingView(session : Text, afterId : Nat, limit : Nat) : async [BoardRow] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    // the board is housekeeping's own screen: its people read it as well as the desk
    if (not isStaff(who) and not St.holdsRole(s, who, #housekeeping)) return [];
    let pg = RowStore.pageById<R.Room>(s.rooms, R.room, afterId + 1, St.MAX_ID, null, Nat.min(Nat.max(limit, 1), 200));
    Array.map<(Nat, R.Room), BoardRow>(pg.rows, func((id, r)) {
      let h = St.housekeeping(later, id);
      let p = func(x : ?Principal) : Text { switch x { case (?q) Principal.toText(q); case null "" } };
      let departure = if (r.occupiedBy == 0) 0 else switch (St.booking(s, r.occupiedBy)) { case (?b) b.departure; case null 0 };
      switch h {
        case (?x) ({ id; number = r.number; roomTypeId = r.roomTypeId; outOfOrder = r.status == #outOfOrder; cleaning = E.cleaningText(x.cleaning);
          cleanedBy = p(x.cleanedBy); inspectedBy = p(x.inspectedBy); cleanedByMe = x.cleanedBy == ?who; inspectedByMe = x.inspectedBy == ?who; outReason = TA.get(s.arena, x.outReason);
          outFrom = x.outFrom; outUntil = x.outUntil; changedDay = x.changedDay; occupiedBy = r.occupiedBy; departure; atBlock = DL.length(log) });
        case null ({ id; number = r.number; roomTypeId = r.roomTypeId; outOfOrder = r.status == #outOfOrder; cleaning = ""; cleanedBy = ""; inspectedBy = "";
          cleanedByMe = false; inspectedByMe = false; outReason = ""; outFrom = 0; outUntil = 0; changedDay = 0; occupiedBy = r.occupiedBy; departure; atBlock = DL.length(log) });
      }
    })
  };

  // ── the hotel clock and the night audit by itself ─────────────────────────

  /// The hotel's time zone (a name and its POSIX TZ rule), the local time the night audit runs at in
  /// seconds after midnight, and whether the contract runs it by itself. The runner is this contract.
  public shared ({ caller }) func setHotelClock(session : Text, zoneName : Text, zoneRule : Text, auditAt : Nat, auto : Bool) : async Reply {
    [await* asPerson(caller, session, func(p) { #setHotelClock({ staff = p; zoneName; zoneRule; auditAt; auto; runner = self() }) })]
  };

  /// What the last tick of the automatic audit did. Kept for the console, not state: an upgrade clears it.
  transient var autoLast = { utc = 0; day = 0; act = ""; ok = true; reason = ""; steps = 0 };
  /// The most acts one tick takes; a tick a minute closes a day of this hotel's size in a few ticks.
  transient let AUTO_STEPS_PER_TICK : Nat = 24;
  /// How many gateway acts the tick runs after the audit's steps.
  transient let AUTO_GATEWAY_PER_TICK : Nat = 8;

  /// Whether the contract runs its own audit and the gateway is owed something: a payment due or a
  /// token to delete. A hotel that does not run its audit by itself pushes its queue by hand.
  func gatewayOwed() : Bool {
    switch (St.hotelClock(later)) { case (?clk) { if (not clk.auto) return false }; case null return false };
    let due = switch (RowStore.page<R.Payment>(s.payments, R.payment, "gateway_due", SR.key(0, W.ID), SR.key(St.MAX_ID, W.ID), null, 1)) { case (#ok p) p.rows.size(); case (#err _) 0 };
    due > 0 or St.cardsToForget(later, 1).size() > 0
  };

  /// The substrate clock as Unix seconds. On a chain whose clock started at its own genesis this reads a
  /// day in 1970, no business day is due, and the automatic audit issues nothing.
  func wallSeconds() : Int { Nat64.toNat(source.substrateNow()) / 1_000_000_000 };

  /// One tick of the automatic audit: every business day whose audit is due, through HotelClock.runDue,
  /// as the runner the roster names, through the same accept path a person's command takes.
  func autoAuditTick() {
    let ?clk = St.hotelClock(later) else return;
    if (not clk.auto) return;
    let ?runner = clk.runner else return;
    let utc = wallSeconds();
    let rule = switch (Zone.parse(TA.get(s.arena, clk.zoneRule))) {
      case (#ok r) r;
      case (#err e) { autoLast := { utc = Int.abs(utc); day = today(); act = ""; ok = false; reason = e; steps = 0 }; return };
    };
    let ?due = HotelClock.dueThrough(rule, clk.auditAt, utc) else return;
    if (today() > due) return;
    let r = HotelClock.runDue(s, today, runner, due, AUTO_STEPS_PER_TICK, func(cmd) { let o = accept(runner, cmd); { ok = o.ok; reason = o.reason } });
    autoLast := { utc = Int.abs(utc); day = r.day; act = r.act; ok = r.ok; reason = r.reason; steps = r.steps };
  };

  /// The hotel clock as the console shows it: the setting, the local time now, the last business day
  /// whose audit is due, and what the automatic audit last did. Nothing here is private.
  public query func hotelClockView() : async [{ set : Bool; zoneName : Text; zoneRule : Text; auditAt : Nat; auto : Bool; runnerIsSelf : Bool;
    localDay : Int; localSecond : Nat; zoneNow : Text; dueThrough : Int; businessDate : Nat;
    lastUtc : Nat; lastDay : Nat; lastAct : Text; lastOk : Bool; lastReason : Text; lastSteps : Nat }] {
    let a = autoLast;
    let utc = wallSeconds();
    switch (St.hotelClock(later)) {
      case null [{ set = false; zoneName = ""; zoneRule = ""; auditAt = 0; auto = false; runnerIsSelf = false; localDay = 0; localSecond = 0; zoneNow = "";
        dueThrough = -1; businessDate = today(); lastUtc = a.utc; lastDay = a.day; lastAct = a.act; lastOk = a.ok; lastReason = a.reason; lastSteps = a.steps }];
      case (?c) {
        let ruleText = TA.get(s.arena, c.zoneRule);
        let (localDay, localSecond, zoneNow, due) = switch (Zone.parse(ruleText)) {
          case (#ok r) { let (d, sec) = Zone.localDayAndSecond(r, utc); (d, sec, Zone.nameAt(r, utc), switch (HotelClock.dueThrough(r, c.auditAt, utc)) { case (?x) (x : Int); case null -1 }) };
          case (#err _) (0, 0, "", -1);
        };
        [{ set = true; zoneName = TA.get(s.arena, c.zoneName); zoneRule = ruleText; auditAt = c.auditAt; auto = c.auto; runnerIsSelf = c.runner == ?self();
          localDay; localSecond; zoneNow; dueThrough = due; businessDate = today();
          lastUtc = a.utc; lastDay = a.day; lastAct = a.act; lastOk = a.ok; lastReason = a.reason; lastSteps = a.steps }]
      };
    }
  };

  func roleOf(t : Text) : ?E.Role {
    switch t { case "owner" ?#owner; case "revenue" ?#revenue; case "frontDesk" ?#frontDesk; case "auditor" ?#auditor; case "housekeeping" ?#housekeeping; case _ null }
  };

  public shared ({ caller }) func grantRole(session : Text, subject : Principal, role : Text) : async Reply {
    let ?r = roleOf(role) else return [refusal("invalid", "There is no role " # role # ".")];
    [await* asPerson(caller, session, func(p) { #grantRole({ staff = p; subject; role = r }) })]
  };

  public shared ({ caller }) func revokeRole(session : Text, subject : Principal, role : Text) : async Reply {
    let ?r = roleOf(role) else return [refusal("invalid", "There is no role " # role # ".")];
    [await* asPerson(caller, session, func(p) { #revokeRole({ staff = p; subject; role = r }) })]
  };

  /// Propose an act that needs a second person. `act` names it; `amount` and `text` carry its figure
  /// or its words where it has one.
  public shared ({ caller }) func propose(session : Text, act : Text, bookingId : Nat, amount : Nat, text : Text, justification : Text) : async Reply {
    let a : Cmd.DualAct = switch act {
      case "staffCancel" #staffCancel({ bookingId; waivePenalty = amount == 1 });
      case "waivePenalty" #waivePenalty({ bookingId });
      case "refundOutsidePolicy" #refundOutsidePolicy({ bookingId; amount });
      case "compNights" #compNights({ bookingId });
      case "priceOverride" #priceOverride({ bookingId; newTotal = amount });
      case "editGuestRecord" #editGuestRecord({ bookingId; guestName = text });
      // the line of the charge is carried in `amount`
      case "voidCharge" #voidCharge({ bookingId; lineId = amount });
      case _ return [refusal("invalid", "There is no act " # act # ".")];
    };
    [await* asPerson(caller, session, func(p) { #propose({ staff = p; act = a; justification }) })]
  };

  public shared ({ caller }) func approve(session : Text, proposalId : Nat) : async Reply {
    let out = await* asPerson(caller, session, func(p) { #approve({ staff = p; proposalId }) });
    // an approved act may have queued refunds or captures; run them now
    if (out.ok) switch (St.proposal(s, proposalId)) {
      case (?pr) { switch (C.fromHex(TA.get(s.arena, pr.act))) { case (?bytes) { switch (Enc.readActBytes(bytes)) { case (?a) ignore await* drain(caller, Cmd.dualActBooking(a), 4); case null {} } }; case null {} } };
      case null {};
    };
    [out]
  };

  public shared ({ caller }) func reject(session : Text, proposalId : Nat, reason : Text) : async Reply {
    [await* asPerson(caller, session, func(p) { #reject({ staff = p; proposalId; reason }) })]
  };

  // ── what a reader may ask (queries: bounded, flat, and stamped with the block they read) ──

  public query func propertyView() : async [{ nameEn : Text; nameAr : Text; currency : Text; minorUnits : Nat; businessDate : Nat;
    checkInEn : Text; checkOutEn : Text; maxStayNights : Nat; maxRoomsPerBooking : Nat; holdRealSeconds : Nat; height : Nat; atBlock : Nat; identity : Text; idRetentionDays : Nat }] {
    switch (St.property(s)) {
      case null [];
      case (?p) [{
        nameEn = TA.get(s.arena, p.nameEn); nameAr = TA.get(s.arena, p.nameAr); currency = p.currency; minorUnits = p.minorUnits;
        businessDate = today(); checkInEn = TA.get(s.arena, p.checkInText); checkOutEn = TA.get(s.arena, p.checkOutText);
        maxStayNights = p.maxStayNights; maxRoomsPerBooking = p.maxRoomsPerBooking;
        holdRealSeconds = if (p.heightsPerRealMinute == 0) 0 else p.holdTtlHeights * 60 / p.heightsPerRealMinute;
        height = height(); atBlock = DL.length(log); identity = switch memphis { case null "transportKey"; case (?_) "memphis" }; idRetentionDays = p.idRetentionDays;
      }];
    }
  };

  public query func roomTypesView() : async [{ id : Nat; code : Text; nameEn : Text; nameAr : Text; descEn : Text; descAr : Text; sizeSqm : Nat;
    maxAdults : Nat; maxChildren : Nat; maxOccupancy : Nat; bedKind : Text; bedCount : Nat; amenities : Nat; photos : Text; rooms : Nat; active : Bool }] {
    let pg = RowStore.pageById<R.RoomType>(s.roomTypes, R.roomType, 1, W.MAX_ROOM_TYPES, null, W.MAX_ROOM_TYPES);
    Array.map<(Nat, R.RoomType), { id : Nat; code : Text; nameEn : Text; nameAr : Text; descEn : Text; descAr : Text; sizeSqm : Nat; maxAdults : Nat; maxChildren : Nat; maxOccupancy : Nat; bedKind : Text; bedCount : Nat; amenities : Nat; photos : Text; rooms : Nat; active : Bool }>(pg.rows, func((id, r)) {
      { id; code = r.code; nameEn = TA.get(s.arena, r.nameEn); nameAr = TA.get(s.arena, r.nameAr); descEn = TA.get(s.arena, r.descEn); descAr = TA.get(s.arena, r.descAr);
        sizeSqm = r.sizeSqm; maxAdults = r.maxAdults; maxChildren = r.maxChildren; maxOccupancy = r.maxOccupancy; bedKind = E.bedKindText(r.bedKind);
        bedCount = r.bedCount; amenities = r.amenities; photos = TA.get(s.arena, r.photos); rooms = St.activeRooms(s, id); active = r.active }
    })
  };

  /// `guarantee`: firstNight, prepaid or deposit; `depositBps` a deposit plan's share; `keepsCard` whether
  /// the hotel's card rule keeps the guest's card on file for it (the guest is shown the agreement).
  public type PlanRow = { id : Nat; code : Text; nameEn : Text; nameAr : Text; refundable : Bool; freeCancelDaysBefore : Nat; penaltyNights : Nat; prepaid : Bool; discountBps : Nat; active : Bool;
    guarantee : Text; depositBps : Nat; keepsCard : Bool };

  /// The plans on public sale. A plan closed to a company or a promotion is not listed here: its name
  /// and its discount are shown only to a guest who gave its code (`plansCodedView`).
  public query func plansView() : async [PlanRow] { planRows(ctx(), Acc.PUBLIC) };

  /// The plans on public sale and those a code opens. A code that opens nothing lists the public plans.
  public query func plansCodedView(code : Text) : async [PlanRow] {
    let c = ctx();
    planRows(c, switch (Acc.resolve(c, code)) { case (#ok g) g; case (#err _) Acc.PUBLIC })
  };

  func planRows(c : St.Ctx, grant : Acc.Grant) : [PlanRow] {
    let pg = RowStore.pageById<R.RatePlan>(s.plans, R.ratePlan, 1, St.MAX_PLANS, null, St.MAX_PLANS);
    let shown = Array.filter<(Nat, R.RatePlan)>(pg.rows, func((id, _)) { Acc.onPublicSale(later, id) or (not Acc.isPublic(grant) and Acc.admits(c, id, grant, null) == null) });
    Array.map<(Nat, R.RatePlan), PlanRow>(shown, func((id, p)) {
      { id; code = p.code; nameEn = TA.get(s.arena, p.nameEn); nameAr = TA.get(s.arena, p.nameAr); refundable = p.refundable; freeCancelDaysBefore = p.freeCancelDaysBefore;
        penaltyNights = p.penaltyNights; prepaid = p.guarantee == #prepaidInFull; discountBps = p.discountBps; active = p.active;
        guarantee = E.guaranteeText(p.guarantee); depositBps = if (p.guarantee == #deposit) St.depositBps(later, id) else 0; keepsCard = St.keepsCard(later, p) }
    })
  };

  public query func taxesView() : async [{ id : Nat; code : Text; nameEn : Text; nameAr : Text }] {
    Array.map<Q.TaxInput, { id : Nat; code : Text; nameEn : Text; nameAr : Text }>(St.taxes(s), func(t) { { id = t.id; code = t.rule.code; nameEn = TA.get(s.arena, t.rule.nameEn); nameAr = TA.get(s.arena, t.rule.nameAr) } })
  };

  // ── setup: each record as the owner edits it, every field its setup act takes ──
  //
  // The guest-facing views above are frozen shapes the pages already read; these are the console's own,
  // staff only, and return inactive records too, so an owner can see and bring back what is off sale.

  public type SetupProperty = { nameEn : Text; nameAr : Text; currency : Text; minorUnits : Nat; checkInText : Text; checkOutText : Text;
    holdTtlHeights : Nat; heightsPerRealMinute : Nat; maxStayNights : Nat; horizonDays : Nat; maxRoomsPerBooking : Nat; idRetentionDays : Nat; atBlock : Nat };

  public shared query ({ caller }) func setupPropertyView(session : Text) : async [SetupProperty] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let ?p = St.property(s) else return [];
    [{ nameEn = TA.get(s.arena, p.nameEn); nameAr = TA.get(s.arena, p.nameAr); currency = p.currency; minorUnits = p.minorUnits;
       checkInText = TA.get(s.arena, p.checkInText); checkOutText = TA.get(s.arena, p.checkOutText); holdTtlHeights = p.holdTtlHeights;
       heightsPerRealMinute = p.heightsPerRealMinute; maxStayNights = p.maxStayNights; horizonDays = p.horizonDays;
       maxRoomsPerBooking = p.maxRoomsPerBooking; idRetentionDays = p.idRetentionDays; atBlock = DL.length(log) }]
  };

  public type SetupRoomType = { id : Nat; code : Text; nameEn : Text; nameAr : Text; descEn : Text; descAr : Text; sizeSqm : Nat; maxAdults : Nat;
    maxChildren : Nat; maxOccupancy : Nat; bedKind : Text; bedCount : Nat; amenities : Nat; photos : Text; rank : Nat; active : Bool; rooms : Nat; atBlock : Nat };

  /// Every room type the property declared, active or not, in id order (at most `MAX_ROOM_TYPES`).
  public shared query ({ caller }) func setupRoomTypesView(session : Text) : async [SetupRoomType] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let pg = RowStore.pageById<R.RoomType>(s.roomTypes, R.roomType, 1, W.MAX_ROOM_TYPES, null, W.MAX_ROOM_TYPES);
    Array.map<(Nat, R.RoomType), SetupRoomType>(pg.rows, func((id, r)) {
      { id; code = r.code; nameEn = TA.get(s.arena, r.nameEn); nameAr = TA.get(s.arena, r.nameAr); descEn = TA.get(s.arena, r.descEn); descAr = TA.get(s.arena, r.descAr);
        sizeSqm = r.sizeSqm; maxAdults = r.maxAdults; maxChildren = r.maxChildren; maxOccupancy = r.maxOccupancy; bedKind = E.bedKindText(r.bedKind);
        bedCount = r.bedCount; amenities = r.amenities; photos = TA.get(s.arena, r.photos); rank = r.rank; active = r.active; rooms = St.activeRooms(s, id);
        atBlock = DL.length(log) }
    })
  };

  public type SetupPlan = { id : Nat; code : Text; nameEn : Text; nameAr : Text; discountBps : Nat; refundable : Bool; freeCancelDaysBefore : Nat;
    penaltyNights : Nat; prepaid : Bool; modifiable : Bool; active : Bool; guarantee : Text; depositBps : Nat; atBlock : Nat };

  /// Every rate plan, active or not, in id order (at most `MAX_PLANS`).
  public shared query ({ caller }) func setupPlansView(session : Text) : async [SetupPlan] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let pg = RowStore.pageById<R.RatePlan>(s.plans, R.ratePlan, 1, St.MAX_PLANS, null, St.MAX_PLANS);
    Array.map<(Nat, R.RatePlan), SetupPlan>(pg.rows, func((id, p)) {
      { id; code = p.code; nameEn = TA.get(s.arena, p.nameEn); nameAr = TA.get(s.arena, p.nameAr); discountBps = p.discountBps; refundable = p.refundable;
        freeCancelDaysBefore = p.freeCancelDaysBefore; penaltyNights = p.penaltyNights; prepaid = p.guarantee == #prepaidInFull; modifiable = p.modifiable;
        active = p.active; guarantee = E.guaranteeText(p.guarantee); depositBps = if (p.guarantee == #deposit) St.depositBps(later, id) else 0; atBlock = DL.length(log) }
    })
  };

  public type SetupTax = { id : Nat; code : Text; nameEn : Text; nameAr : Text; kind : Text; bps : Nat; amount : Nat; onPriorTaxes : Bool; rank : Nat;
    active : Bool; atBlock : Nat };

  /// Every tax rule, active or not, in id order (at most `MAX_TAX_RULES`). The guest pages read the
  /// active ones, in the order they apply, from `taxesView`.
  public shared query ({ caller }) func setupTaxesView(session : Text) : async [SetupTax] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let pg = RowStore.pageById<R.TaxRule>(s.taxes, R.taxRule, 1, St.MAX_TAX_RULES, null, St.MAX_TAX_RULES);
    Array.map<(Nat, R.TaxRule), SetupTax>(pg.rows, func((id, t)) {
      { id; code = t.code; nameEn = TA.get(s.arena, t.nameEn); nameAr = TA.get(s.arena, t.nameAr);
        kind = switch (t.kind) { case (#percent) "percent"; case (#perRoomNight) "perRoomNight"; case (#perStay) "perStay" };
        bps = t.bps; amount = t.amount; onPriorTaxes = t.base == #roomAndPriorTaxes; rank = t.rank; active = t.active; atBlock = DL.length(log) }
    })
  };

  /// Per day: the lowest nightly rate on public sale across the room types asked for (0 = all), whether
  /// any is bookable, and the restrictions. At most 62 days, one range read per room type. A plan closed
  /// to a company or a promotion never sets the price the public calendar shows.
  public query func calendarView(roomTypeId : Nat, fromDay : Nat, days : Nat) : async [{ day : Nat; lowest : Nat; bookable : Bool; closedToArrival : Bool; closedToDeparture : Bool; minStay : Nat }] {
    let n = Nat.min(days, 62);
    let types = if (roomTypeId != 0) [roomTypeId] else Array.map<(Nat, R.RoomType), Nat>(Array.filter<(Nat, R.RoomType)>(RowStore.pageById<R.RoomType>(s.roomTypes, R.roomType, 1, W.MAX_ROOM_TYPES, null, W.MAX_ROOM_TYPES).rows, func((_, r)) { r.active }), func((id, _)) { id });
    let plans = Array.filter<(Nat, R.RatePlan)>(RowStore.pageById<R.RatePlan>(s.plans, R.ratePlan, 1, St.MAX_PLANS, null, St.MAX_PLANS).rows, func((id, p)) { p.active and Acc.onPublicSale(later, id) });
    let lowest = Array.toVarArray<Nat>(Array.tabulate<Nat>(n, func(_) { 0 }));
    let cta = Array.toVarArray<Bool>(Array.tabulate<Bool>(n, func(_) { true }));
    let ctd = Array.toVarArray<Bool>(Array.tabulate<Bool>(n, func(_) { true }));
    let minS = Array.toVarArray<Nat>(Array.tabulate<Nat>(n, func(_) { 255 }));
    for (rt in types.vals()) {
      let rows = St.nightsRange(s, rt, fromDay, fromDay + n);
      var i = 0;
      while (i < n) {
        switch (rows[i]) {
          case (?nt) {
            if (not nt.stopSell and St.freeOn(later, rt, fromDay + i, nt) > 0) {
              for ((_, p) in plans.vals()) {
                let r = Q.displayRate(nt.bar, p);
                if (lowest[i] == 0 or r < lowest[i]) lowest[i] := r;
              };
              cta[i] := cta[i] and nt.closedToArrival;
              ctd[i] := ctd[i] and nt.closedToDeparture;
              minS[i] := Nat.min(minS[i], if (nt.minStay == 0) 1 else nt.minStay);
            };
          };
          case null {};
        };
        i += 1;
      };
    };
    let t = today();
    Array.tabulate<{ day : Nat; lowest : Nat; bookable : Bool; closedToArrival : Bool; closedToDeparture : Bool; minStay : Nat }>(n, func(i) {
      let open = lowest[i] > 0 and fromDay + i >= t;
      { day = fromDay + i; lowest = lowest[i]; bookable = open; closedToArrival = open and cta[i]; closedToDeparture = open and ctd[i]; minStay = if (open) minS[i] else 1 }
    })
  };

  /// `packageTotal`: a package's inclusions with their taxes, part of `total` (0 for a plain rate). The
  /// guarantee is the first night's room for a plan that authorises it: never the package.
  public type OfferRow = { roomTypeId : Nat; planId : Nat; ok : Bool; kind : Text; reason : Text; total : Nat; roomSubtotal : Nat; taxTotal : Nat; packageTotal : Nat;
    left : Nat; cancelDeadline : Nat; refundable : Bool; guarantee : Nat; quoteHash : Text; atBlock : Nat };

  /// Every room type and rate for a stay: the offer, or the reason there is none.
  public query func searchView(arrival : Nat, nights : Nat, rooms : Nat, adults : Nat, children : Nat) : async [OfferRow] {
    offers(ctx(), arrival, nights, rooms, adults, children, Acc.PUBLIC)
  };

  /// The search of a guest who gave a code: the public plans and the closed plans the code opens, each
  /// priced under that access. A code that opens nothing is one row saying why (room type and plan 0).
  public query func searchCodedView(arrival : Nat, nights : Nat, rooms : Nat, adults : Nat, children : Nat, code : Text) : async [OfferRow] {
    let c = ctx();
    switch (Acc.resolve(c, code)) {
      case (#ok g) offers(c, arrival, nights, rooms, adults, children, g);
      case (#err f) [{ roomTypeId = 0; planId = 0; ok = false; kind = Rf.kind(f); reason = Rf.text(f); total = 0; roomSubtotal = 0; taxTotal = 0; packageTotal = 0;
        left = 0; cancelDeadline = 0; refundable = false; guarantee = 0; quoteHash = ""; atBlock = c.block }];
    }
  };

  func offers(c : St.Ctx, arrival : Nat, nights : Nat, rooms : Nat, adults : Nat, children : Nat, grant : Acc.Grant) : [OfferRow] {
    let out = List.empty<OfferRow>();
    let types = RowStore.pageById<R.RoomType>(s.roomTypes, R.roomType, 1, W.MAX_ROOM_TYPES, null, W.MAX_ROOM_TYPES).rows;
    let plans = RowStore.pageById<R.RatePlan>(s.plans, R.ratePlan, 1, St.MAX_PLANS, null, St.MAX_PLANS).rows;
    for ((rt, r) in types.vals()) {
      if (r.active) {
        for ((pid, p) in plans.vals()) {
          // a closed plan is shown only to an access it admits; the public search never shows one
          if (p.active and (Acc.onPublicSale(later, pid) or (not Acc.isPublic(grant) and Acc.admits(c, pid, grant, null) == null))) {
            switch (Res.quoteStayFor(c, { roomTypeId = rt; planId = pid; arrival; nights; rooms; adults; children }, Acc.forPlan(c, grant, pid))) {
              case (#ok ch) {
                var left = 65_535;
                var d = arrival;
                for (nt in ch.nights.vals()) { left := Nat.min(left, St.freeOn(later, rt, d, nt)); d += 1 };
                let g = Res.guaranteeOf(later, pid, p, ch.quote);
                List.add(out, { roomTypeId = rt; planId = pid; ok = true; kind = ""; reason = ""; total = ch.quote.total; roomSubtotal = ch.quote.roomSubtotal;
                  taxTotal = ch.quote.taxTotal; packageTotal = ch.quote.packageTotal; left; cancelDeadline = if (p.refundable) (if (arrival > p.freeCancelDaysBefore) arrival - p.freeCancelDaysBefore else 0) else 0;
                  refundable = p.refundable; guarantee = g; quoteHash = Q.hashHex(ch.quote); atBlock = c.block });
              };
              case (#err f) {
                List.add(out, { roomTypeId = rt; planId = pid; ok = false; kind = Rf.kind(f); reason = Rf.text(f); total = 0; roomSubtotal = 0; taxTotal = 0; packageTotal = 0;
                  left = 0; cancelDeadline = 0; refundable = p.refundable; guarantee = 0; quoteHash = ""; atBlock = c.block });
              };
            };
          };
        };
      };
    };
    List.toArray(out)
  };

  /// The lines of a quote: each night's room charge and each tax's share of it (ruleId 0 = room).
  public query func quoteNightsView(roomTypeId : Nat, planId : Nat, arrival : Nat, nights : Nat, rooms : Nat, adults : Nat, children : Nat) : async [{ day : Nat; ruleId : Nat; amount : Nat }] {
    quoteNights(ctx(), { roomTypeId; planId; arrival; nights; rooms; adults; children }, Acc.PUBLIC)
  };

  /// The night-by-night quote of a stay on a rate a code opens; empty when the code opens nothing.
  public query func quoteNightsCodedView(roomTypeId : Nat, planId : Nat, arrival : Nat, nights : Nat, rooms : Nat, adults : Nat, children : Nat, code : Text) : async [{ day : Nat; ruleId : Nat; amount : Nat }] {
    let c = ctx();
    switch (Acc.resolve(c, code)) {
      case (#ok g) quoteNights(c, { roomTypeId; planId; arrival; nights; rooms; adults; children }, g);
      case (#err _) [];
    }
  };

  func quoteNights(c : St.Ctx, stay : Cmd.Stay, grant : Acc.Grant) : [{ day : Nat; ruleId : Nat; amount : Nat }] {
    switch (Res.quoteStayFor(c, stay, Acc.forPlan(c, grant, stay.planId))) {
      case (#err _) [];
      case (#ok ch) Array.map<(E.FolioKind, Nat, Nat, Nat), { day : Nat; ruleId : Nat; amount : Nat }>(Res.quoteLines(ch.quote), func((_, code, night, amount)) { { day = night; ruleId = code; amount } });
    }
  };

  /// What a booking act returns: its outcome and the booking as that same update left it, so a guest
  /// is shown the booking from the reply itself and never from a read that may predate the write.
  public type BookingReply = { ok : Bool; kind : Text; reason : Text; block : Nat; fee : Nat; refund : Nat; id : Nat; ref : Text; status : Text;
    roomTypeId : Nat; planId : Nat; arrival : Nat; departure : Nat; rooms : Nat; adults : Nat; children : Nat; guestName : Text;
    charged : Nat; credited : Nat; paid : Nat; outstanding : Nat; penalty : Nat; cancelDeadline : Nat; refundable : Bool; nonce : Nat };

  func bookingReply(o : Outcome, id : Nat, fee : Nat, refund : Nat) : [BookingReply] {
    switch (if (o.ok) St.booking(s, id) else null) {
      case (?b) {
        let r = bookingRow(id, b);
        [{ ok = true; kind = ""; reason = ""; block = DL.length(log); fee; refund; id; ref = r.ref; status = r.status; roomTypeId = r.roomTypeId; planId = r.planId;
           arrival = r.arrival; departure = r.departure; rooms = r.rooms; adults = r.adults; children = r.children; guestName = r.guestName; charged = r.charged;
           credited = r.credited; paid = r.paid; outstanding = r.outstanding; penalty = r.penalty; cancelDeadline = r.cancelDeadline; refundable = r.refundable; nonce = r.nonce }]
      };
      case null {
        [{ ok = false; kind = o.kind; reason = o.reason; block = o.block; fee = 0; refund = 0; id = 0; ref = ""; status = ""; roomTypeId = 0; planId = 0; arrival = 0;
           departure = 0; rooms = 0; adults = 0; children = 0; guestName = ""; charged = 0; credited = 0; paid = 0; outstanding = 0; penalty = 0; cancelDeadline = 0;
           refundable = false; nonce = 0 }]
      };
    }
  };

  public type BookingRow = { id : Nat; ref : Text; status : Text; roomTypeId : Nat; planId : Nat; arrival : Nat; departure : Nat; rooms : Nat; adults : Nat; children : Nat;
    guestName : Text; charged : Nat; credited : Nat; paid : Nat; outstanding : Nat; penalty : Nat; cancelDeadline : Nat; refundable : Bool; nonce : Nat; atBlock : Nat };

  func bookingRow(id : Nat, b : R.Booking) : BookingRow {
    let refundable = switch (St.plan(s, b.planId)) { case (?p) p.refundable; case null false };
    { id; ref = Ref.of(id); status = E.bookingStatusText(b.status); roomTypeId = b.roomTypeId; planId = b.planId; arrival = b.arrival; departure = b.departure;
      rooms = b.rooms; adults = b.adults; children = b.children; guestName = TA.get(s.arena, b.guestName); charged = b.charged; credited = b.credited;
      paid = b.paid; outstanding = b.outstanding; penalty = b.penalty; cancelDeadline = b.cancelDeadline; refundable; nonce = b.manageNonce; atBlock = DL.length(log) }
  };

  /// A guest's own booking, read with the manage key: the signature is over the act "view" and the
  /// booking's current nonce, so the link alone opens it and a guess does not.
  public query func manageView(ref : Text, sigHex : Text) : async [BookingRow] {
    let ?id = Ref.parse(ref) else return [];
    if (not signed(id, "view", "", sigHex)) return [];
    switch (St.booking(s, id)) { case (?b) [bookingRow(id, b)]; case null [] }
  };

  /// The plan a booking is on, for its guest: signed like `manageView`, so a plan closed to a company is
  /// named to the company's guest without being listed to the public.
  public query func managePlanView(ref : Text, sigHex : Text) : async [PlanRow] {
    let ?id = Ref.parse(ref) else return [];
    if (not signed(id, "view", "", sigHex)) return [];
    let ?b = St.booking(s, id) else return [];
    let ?p = St.plan(s, b.planId) else return [];
    [{ id = b.planId; code = p.code; nameEn = TA.get(s.arena, p.nameEn); nameAr = TA.get(s.arena, p.nameAr); refundable = p.refundable; freeCancelDaysBefore = p.freeCancelDaysBefore;
      penaltyNights = p.penaltyNights; prepaid = p.guarantee == #prepaidInFull; discountBps = p.discountBps; active = p.active;
        guarantee = E.guaranteeText(p.guarantee); depositBps = if (p.guarantee == #deposit) St.depositBps(later, b.planId) else 0; keepsCard = St.keepsCard(later, p) }]
  };

  /// A booking's card on file as its guest reads it, signed like `manageView`: whether one is kept, or
  /// wanted (and by which day), or was; never the token. `charge`: a no-show charge's state ("" none).
  /// `due`: what the card link takes now, while the card is wanted (0 otherwise).
  public type CardRow = { state : Text; deadline : Nat; agreedBlock : Nat; charge : Text; chargeAmount : Nat; due : Nat; atBlock : Nat };

  func cardRow(id : Nat) : [CardRow] {
    let ?k = St.card(later, id) else return [];
    let (charge, amount) = switch (if (k.chargeId == 0) null else St.payment(s, k.chargeId)) { case (?p) (E.paymentStateText(p.state), p.amount); case null ("", 0) };
    [{ state = E.cardStateText(k.state); deadline = k.deadline; agreedBlock = k.agreedBlock; charge; chargeAmount = amount; due = Res.cardLinkDue(ctx(), id);
      atBlock = DL.length(log) }]
  };

  public query func manageCardView(ref : Text, sigHex : Text) : async [CardRow] {
    let ?id = Ref.parse(ref) else return [];
    if (not signed(id, "view", "", sigHex)) return [];
    cardRow(id)
  };

  /// The cards the desk acts on for a day: bookings whose guarantee is due by `day` with no card on file
  /// (flagged, never cancelled), no-show charges the gateway declined in the week to `day`, and tokens the
  /// gateway would not delete. Each list at most 50.
  public type CardDeskRow = { bookingId : Nat; ref : Text; guestName : Text; arrival : Nat; kind : Text; day : Nat; amount : Nat; outstanding : Nat; atBlock : Nat };

  public shared query ({ caller }) func cardsView(session : Text, day : Nat) : async [CardDeskRow] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let out = List.empty<CardDeskRow>();
    let at = DL.length(log);
    func add(id : Nat, kind : Text, d : Nat, amount : Nat) {
      switch (St.booking(s, id)) {
        case (?b) List.add(out, { bookingId = id; ref = Ref.of(id); guestName = TA.get(s.arena, b.guestName); arrival = b.arrival; kind; day = d; amount;
          outstanding = b.outstanding; atBlock = at });
        case null {};
      };
    };
    for ((id, k) in St.cardsWanted(later, day, null, 50).rows.vals()) add(id, "unguaranteed", k.deadline, 0);
    for ((id, k) in St.cardsDeclined(later, if (day > 6) day - 6 else 0, day, 50).vals()) {
      add(id, "declined", k.declinedDay, switch (St.payment(s, k.chargeId)) { case (?p) p.amount; case null 0 });
    };
    for ((id, _) in St.cardsForgetFailed(later, 50).vals()) add(id, "forgetFailed", 0, 0);
    List.toArray(out)
  };

  /// A booking's public key, so the browser can confirm its link matches before it signs anything.
  public query func manageNonceView(ref : Text) : async [{ nonce : Nat; key : Text }] {
    let ?id = Ref.parse(ref) else return [];
    switch (St.booking(s, id)) { case (?b) [{ nonce = b.manageNonce; key = C.hex(b.manageKey) }]; case null [] }
  };

  public shared query ({ caller }) func myStaysView(session : Text) : async [BookingRow] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    let rows = St.prefixRows<R.Booking>(s.bookings, R.booking, "by_account", R.principalField(who), W.ID, Page.MAX_LIMIT);
    Array.map<(Nat, R.Booking), BookingRow>(rows, func((id, b)) { bookingRow(id, b) })
  };

  /// The account holder's own waitlist places, with any hold offered to them and when it ends.
  public shared query ({ caller }) func myWaitlistView(session : Text) : async [{ id : Nat; roomTypeId : Nat; arrival : Nat; nights : Nat; rooms : Nat;
    adults : Nat; children : Nat; state : Text; offeredHold : Nat; offerTotal : Nat; offerExpiresAt : Nat; height : Nat }] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    let rows = St.prefixRows<R.WaitEntry>(s.waitlist, R.waitlist, "by_account", R.principalField(who), W.ID, 50);
    Array.map<(Nat, R.WaitEntry), { id : Nat; roomTypeId : Nat; arrival : Nat; nights : Nat; rooms : Nat; adults : Nat; children : Nat; state : Text; offeredHold : Nat;
      offerTotal : Nat; offerExpiresAt : Nat; height : Nat }>(rows, func((id, w)) {
      let (total, exp) = switch (if (w.state == #offered) St.hold(s, w.offeredHold) else null) { case (?h) (h.quotedTotal, h.expiresAt); case null (0, 0) };
      { id; roomTypeId = w.roomTypeId; arrival = w.arrival; nights = w.nights; rooms = w.rooms; adults = w.adults; children = w.children;
        state = E.waitStateText(w.state); offeredHold = w.offeredHold; offerTotal = total; offerExpiresAt = exp; height = height() }
    })
  };

  func isStaff(who : Principal) : Bool {
    St.holdsRole(s, who, #owner) or St.holdsRole(s, who, #revenue) or St.holdsRole(s, who, #frontDesk) or St.holdsRole(s, who, #auditor)
  };

  /// The staff roles the session's person holds, none for a guest or a stranger. The console asks this
  /// rather than reading an empty grid as a refusal, since a new property's grid is empty for its owner too.
  public shared query ({ caller }) func rolesView(session : Text) : async [{ role : Text }] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    let held = Array.filter<E.Role>([#owner, #revenue, #frontDesk, #auditor, #housekeeping], func(r) { St.holdsRole(s, who, r) });
    Array.map<E.Role, { role : Text }>(held, func(r) { { role = E.roleText(r) } })
  };

  /// Who this contract takes the session's person to be, as the hex of their principal's bytes: the id a
  /// new member of staff sends the owner, who grants it a role. Nothing for a call it cannot identify.
  public shared query ({ caller }) func whoAmIView(session : Text) : async [{ principalHex : Text; atBlock : Nat }] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    [{ principalHex = C.hex(Principal.toBlob(who)); atBlock = DL.length(log) }]
  };

  /// One role held by one person: the grant that gave it (its id and the block it was given in), the
  /// person as the hex of their principal, whether it is the reader, and whether it is the automatic night
  /// audit's own grant (the contract, ended only by turning that audit off).
  public type RosterRow = { kind : Text; grantId : Nat; subject : Text; role : Text; mine : Bool; automatic : Bool; since : Nat; next : Nat; atBlock : Nat };

  /// The hotel's staff: every role held, in grant order, for anyone who holds a role. A page examines at
  /// most 200 grants after `afterId`; a role that was ended is not listed. Every row carries in `next` the
  /// grant id to continue after (0 when the roster is done); a page whose grants were all ended answers
  /// one row of `kind` "more" so the reader goes on.
  public shared query ({ caller }) func rosterView(session : Text, afterId : Nat, limit : Nat) : async [RosterRow] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who) and not St.holdsRole(s, who, #housekeeping)) return [];
    let pg = RowStore.pageById<R.Grant>(s.grants, R.grant, afterId + 1, St.MAX_ID, null, Nat.min(Nat.max(limit, 1), 200));
    let at = DL.length(log);
    let next = switch (pg.next) { case null 0; case (?_) { if (pg.rows.size() == 0) 0 else pg.rows[pg.rows.size() - 1].0 } };
    let runner = switch (St.hotelClock(later)) { case (?{ auto = true; runner = ?r }) ?r; case _ null };
    let out = List.empty<RosterRow>();
    for ((id, g) in pg.rows.vals()) {
      if (g.active) List.add(out, { kind = "grant"; grantId = id; subject = C.hex(Principal.toBlob(g.subject)); role = E.roleText(g.role); mine = g.subject == who;
        automatic = runner == ?g.subject and g.role == #auditor; since = g.lastBlock; next; atBlock = at });
    };
    if (List.size(out) == 0 and next != 0) return [{ kind = "more"; grantId = 0; subject = ""; role = ""; mine = false; automatic = false; since = 0; next; atBlock = at }];
    List.toArray(out)
  };

  /// The rates and availability grid, for staff: at most 31 days and 16 room types a call.
  public shared query ({ caller }) func gridView(session : Text, fromDay : Nat, days : Nat, rtFrom : Nat, rtCount : Nat) : async [{ roomTypeId : Nat; day : Nat; allotment : Nat;
    sold : Nat; held : Nat; blocked : Nat; bar : Nat; minStay : Nat; maxStay : Nat; closedToArrival : Bool; closedToDeparture : Bool; stopSell : Bool; exists : Bool }] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let n = Nat.min(days, 31);
    let out = List.empty<{ roomTypeId : Nat; day : Nat; allotment : Nat; sold : Nat; held : Nat; blocked : Nat; bar : Nat; minStay : Nat; maxStay : Nat; closedToArrival : Bool; closedToDeparture : Bool; stopSell : Bool; exists : Bool }>();
    var rt = Nat.max(rtFrom, 1);
    let last = rt + Nat.min(rtCount, 16);
    while (rt < last and rt < s.nextRoomTypeId) {
      let rows = St.nightsRange(s, rt, fromDay, fromDay + n);
      var i = 0;
      while (i < n) {
        switch (rows[i]) {
          case (?x) List.add(out, { roomTypeId = rt; day = fromDay + i; allotment = x.allotment; sold = x.sold; held = x.held; blocked = St.blockedOn(later, rt, fromDay + i); bar = x.bar; minStay = x.minStay; maxStay = x.maxStay;
            closedToArrival = x.closedToArrival; closedToDeparture = x.closedToDeparture; stopSell = x.stopSell; exists = true });
          case null List.add(out, { roomTypeId = rt; day = fromDay + i; allotment = 0; sold = 0; held = 0; blocked = 0; bar = 0; minStay = 1; maxStay = 0; closedToArrival = false; closedToDeparture = false; stopSell = false; exists = false });
        };
        i += 1;
      };
      rt += 1;
    };
    List.toArray(out)
  };

  /// The arrivals of a day, for the front desk: a page over the arrivals index.
  public shared query ({ caller }) func arrivalsView(session : Text, day : Nat) : async [BookingRow] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let rows = St.rangeRows<R.Booking>(s.bookings, R.booking, "arrivals", SR.key2(day, W.DAY, 0, W.ID), SR.key2(day, W.DAY, St.MAX_ID, W.ID));
    Array.map<(Nat, R.Booking), BookingRow>(rows, func((id, b)) { bookingRow(id, b) })
  };

  func roomNumbersOf(bookingId : Nat, rt : Nat) : Text {
    let (lo, hi) = SR.prefixRange(rt, W.ID, W.ID);
    var out = "";
    for ((_, r) in St.rangeRows<R.Room>(s.rooms, R.room, "by_type", lo, hi).vals()) {
      if (r.occupiedBy == bookingId) out := (if (out == "") "" else out # ",") # r.number;
    };
    out
  };

  /// The guests in house, with the rooms they hold, for the front desk.
  public type DeskRow = { id : Nat; ref : Text; status : Text; roomTypeId : Nat; planId : Nat; arrival : Nat; departure : Nat; rooms : Nat; adults : Nat; children : Nat;
    guestName : Text; charged : Nat; credited : Nat; paid : Nat; outstanding : Nat; penalty : Nat; cancelDeadline : Nat; refundable : Bool; nonce : Nat; atBlock : Nat; roomNumbers : Text };

  public shared query ({ caller }) func inHouseView(session : Text) : async [DeskRow] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let rows = St.rangeRows<R.Booking>(s.bookings, R.booking, "in_house", SR.key2(0, W.DAY, 0, W.ID), SR.key2(16_777_215, W.DAY, St.MAX_ID, W.ID));
    Array.map<(Nat, R.Booking), DeskRow>(rows, func((id, b)) { { bookingRow(id, b) with roomNumbers = roomNumbersOf(id, b.roomTypeId) } })
  };

  /// The vacant rooms of a type for check-in, readiest first: inspected, clean, not recorded, dirty;
  /// by room id within each.
  public shared query ({ caller }) func vacantRoomsView(session : Text, roomTypeId : Nat) : async [{ id : Nat; number : Text; cleaning : Text; atBlock : Nat }] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let (lo, hi) = SR.prefixRange(roomTypeId, W.ID, W.ID);
    let rows = Array.map<(Nat, R.Room), { id : Nat; number : Text; cleaning : Text; rank : Nat }>(St.rangeRows<R.Room>(s.rooms, R.room, "vacant_by_type", lo, hi), func((id, r)) {
      let h = St.housekeeping(later, id);
      { id; number = r.number; cleaning = switch h { case (?x) E.cleaningText(x.cleaning); case null "" }; rank = Hk.readiness(h) }
    });
    let sorted = Array.sort<{ id : Nat; number : Text; cleaning : Text; rank : Nat }>(rows, func(a, b) {
      switch (Nat.compare(a.rank, b.rank)) { case (#equal) Nat.compare(a.id, b.id); case o o }
    });
    let at = DL.length(log);
    Array.map<{ id : Nat; number : Text; cleaning : Text; rank : Nat }, { id : Nat; number : Text; cleaning : Text; atBlock : Nat }>(sorted, func(x) { { id = x.id; number = x.number; cleaning = x.cleaning; atBlock = at } })
  };

  /// Every booking, newest first, a page at a time: `beforeId` 0 starts at the newest; the reply's last
  /// id is where the next page starts. At most 50 a page.
  public shared query ({ caller }) func bookingsView(session : Text, beforeId : Nat, limit : Nat) : async [BookingRow] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let top : Nat = if (beforeId == 0) s.nextBookingId else beforeId;
    let n = Nat.min(Nat.max(limit, 1), 50);
    let out = List.empty<BookingRow>();
    var id = top;
    while (id > 1 and List.size(out) < n) {
      id -= 1;
      switch (St.booking(s, id)) { case (?b) List.add(out, bookingRow(id, b)); case null {} };
    };
    List.toArray(out)
  };

  /// A page of bookings by arrival window and status, through the arrival index, for staff. The window
  /// is inclusive; a status of "" is every status. `cursorHex` "" starts at the window's first arrival.
  /// Each row is a booking (`kind` "booking") and carries where the next page starts in `next` ("" when
  /// the window is done). A read examines at most 500 index entries; when that budget runs out before a
  /// match, the reply is one row of `kind` "more" whose `next` resumes the scan and whose other fields
  /// are zero.
  public type BookingPageRow = BookingRow and { kind : Text; next : Text };

  public shared query ({ caller }) func bookingsPageView(session : Text, status : Text, fromDay : Nat, toDay : Nat, cursorHex : Text, limit : Nat) : async [BookingPageRow] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who) or fromDay > toDay) return [];
    let n = Nat.min(Nat.max(limit, 1), 50);
    let lo = SR.key2(fromDay, W.DAY, 0, W.ID);
    let hi = SR.key2(toDay, W.DAY, St.MAX_ID, W.ID);
    var cursor : ?Page.Cursor = if (cursorHex == "") null else switch (C.fromHex(cursorHex)) { case (?c) ?c; case null return [] };
    let found = List.empty<BookingRow>();
    var examined = 0;
    label scan while (List.size(found) < n and examined < 500) {
      switch (RowStore.page<R.Booking>(s.bookings, R.booking, "by_arrival", lo, hi, cursor, n)) {
        case (#err _) return [];
        case (#ok p) {
          examined += p.examined;
          for ((id, b) in p.rows.vals()) {
            if (List.size(found) < n and (status == "" or E.bookingStatusText(b.status) == status)) List.add(found, bookingRow(id, b));
          };
          cursor := p.next;
          if (p.next == null) break scan;
        };
      };
    };
    let next = switch cursor { case (?c) C.hex(c); case null "" };
    if (List.size(found) == 0 and next != "") {
      return [{ id = 0; ref = ""; status = ""; roomTypeId = 0; planId = 0; arrival = 0; departure = 0; rooms = 0; adults = 0; children = 0; guestName = "";
        charged = 0; credited = 0; paid = 0; outstanding = 0; penalty = 0; cancelDeadline = 0; refundable = false; nonce = 0; atBlock = DL.length(log);
        kind = "more"; next }];
    };
    Array.map<BookingRow, BookingPageRow>(List.toArray(found), func(r) { { r with kind = "booking"; next } })
  };

  /// The booking a reference names, for staff: none for a malformed reference, one that fails its check
  /// character, or one no booking has.
  public shared query ({ caller }) func bookingByRefView(session : Text, ref : Text) : async [BookingRow] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let ?id = Ref.parse(ref) else return [];
    switch (St.booking(s, id)) { case (?b) [bookingRow(id, b)]; case null [] }
  };

  /// A booking's folio, line by line, with the block that posted each, for staff.
  public shared query ({ caller }) func folioView(session : Text, bookingId : Nat) : async [{ id : Nat; kind : Text; night : Nat; amount : Nat; block : Nat }] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    Array.map<(Nat, R.FolioLine), { id : Nat; kind : Text; night : Nat; amount : Nat; block : Nat }>(St.folioOf(s, bookingId),
      func((id, l)) { { id; kind = E.folioKindText(l.kind); night = l.night; amount = l.amount; block = l.block } })
  };

  /// A booking's payments: authorisations, captures and refunds, their state and the block of each, for staff.
  public shared query ({ caller }) func paymentsView(session : Text, bookingId : Nat) : async [{ id : Nat; kind : Text; state : Text; amount : Nat; gatewayAuth : Nat; attempts : Nat; block : Nat }] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    Array.map<(Nat, R.Payment), { id : Nat; kind : Text; state : Text; amount : Nat; gatewayAuth : Nat; attempts : Nat; block : Nat }>(St.paymentsOf(s, bookingId),
      func((id, p)) { { id; kind = E.paymentKindText(p.kind); state = E.paymentStateText(p.state); amount = p.amount; gatewayAuth = p.gatewayAuth; attempts = p.attempts; block = p.block } })
  };

  /// The blocks that acted on a booking, newest first, read from the log a bounded stretch at a time,
  /// for staff. `beforeBlock` 0 starts at the tip. A stretch ends at most 500 blocks down or at the block
  /// that confirmed the booking. Rows are acts (`kind` "act"); when the stretch ends above the
  /// confirmation, a last row of `kind` "more" gives the block to continue from in `block`.
  public shared query ({ caller }) func bookingHistoryView(session : Text, bookingId : Nat, beforeBlock : Nat) : async [{ kind : Text; block : Nat; day : Nat; act : Text }] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let ?b = St.booking(s, bookingId) else return [];
    let folio = St.folioOf(s, bookingId);
    let payments = St.paymentsOf(s, bookingId);
    // the booking's folio is written by the block that confirmed it, so nothing below that block acts on it
    var first = DL.length(log);
    for ((_, l) in folio.vals()) { if (l.block < first) first := l.block };
    let tip = DL.length(log);
    var i = if (beforeBlock == 0 or beforeBlock > tip) tip else beforeBlock;
    let floor = Nat.max(first, if (i > H.MAX_SCAN) i - H.MAX_SCAN else 0);
    let recorded = func(blk : Nat) : Bool {
      for ((_, l) in folio.vals()) { if (l.block == blk) return true };
      for ((_, p) in payments.vals()) { if (p.block == blk) return true };
      false
    };
    let out = List.empty<{ kind : Text; block : Nat; day : Nat; act : Text }>();
    while (i > floor) {
      i -= 1;
      switch (DL.get<Log.Event>(log, Log.codec, i)) {
        case (?blk) {
          switch (H.actOn(s, blk.event.command, bookingId, b)) {
            case (?act) List.add(out, { kind = "act"; block = i; day = blk.event.day; act });
            // the night audit and the gateway pump act on many bookings in one block; what they posted says so
            case null { if (recorded(i)) List.add(out, { kind = "act"; block = i; day = blk.event.day; act = Cmd.familyOf(blk.event.command) }) };
          };
        };
        case null {};
      };
    };
    if (floor > first) List.add(out, { kind = "more"; block = floor; day = 0; act = "" });
    List.toArray(out)
  };

  /// Proposals waiting for a second person, with what each would do, for staff.
  public shared query ({ caller }) func proposalsView(session : Text) : async [{ id : Nat; act : Text; bookingId : Nat; ref : Text; amount : Nat; text : Text;
    maker : Text; mine : Bool; expiresAt : Nat; height : Nat }] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let rows = switch (RowStore.page<R.Proposal>(s.proposals, R.proposal, "awaiting", SR.key(0, W.ID), SR.key(St.MAX_ID, W.ID), null, 100)) { case (#ok p) p.rows; case (#err _) [] };
    let out = List.empty<{ id : Nat; act : Text; bookingId : Nat; ref : Text; amount : Nat; text : Text; maker : Text; mine : Bool; expiresAt : Nat; height : Nat }>();
    for ((id, p) in rows.vals()) {
      switch (C.fromHex(TA.get(s.arena, p.act))) {
        case (?bytes) {
          switch (Enc.readActBytes(bytes)) {
            case (?a) {
              let (amount, text) : (Nat, Text) = switch a {
                case (#staffCancel x) (if (x.waivePenalty) 1 else 0, "");
                case (#refundOutsidePolicy x) (x.amount, "");
                case (#priceOverride x) (x.newTotal, "");
                case (#editGuestRecord x) (0, x.guestName);
                case (#voidCharge x) (x.lineId, chargeName(x.lineId));
                // the note's figure before tax, and the invoice it amends
                case (#issueCreditNote x) { var t = 0; for (a in x.amounts.vals()) t += a; (t, Eta.invoiceId(x.invoice)) };
                case (#refundAtDesk x) (x.paymentId, E.deskMethodText(x.method) # " " # x.reference);
                case _ (0, "");
              };
              let bid = Cmd.dualActBooking(a);
              List.add(out, { id; act = Cmd.dualActName(a); bookingId = bid; ref = Ref.of(bid); amount; text; maker = C.hex(Principal.toBlob(p.maker)); mine = p.maker == who; expiresAt = p.expiresAt; height = height() });
            };
            case null {};
          };
        };
        case null {};
      };
    };
    List.toArray(out)
  };

  /// Where the night audit stands for a day: its plan, its progress, and the books walk.
  public shared query ({ caller }) func auditView(session : Text, day : Nat) : async [{ open : Bool; completed : Bool; items : Nat; done : Nat; failures : Nat;
    walkDone : Bool; examined : Nat; violations : Nat; firstViolation : Text; businessDate : Nat }] {
    let ?who = identifyCached(caller, tok(session)) else return [];
    if (not isStaff(who)) return [];
    let w = s.walk;
    switch (BatchCore.get(s.audit, "night", day)) {
      case (?run) [{ open = true; completed = run.state == #completed; items = run.items; done = run.cursor; failures = BatchCore.unresolvedFailures(run);
        walkDone = w.day == day and w.done; examined = if (w.day == day) w.examined else 0; violations = if (w.day == day) w.violations.size() else 0;
        firstViolation = if (w.day == day and w.violations.size() > 0) w.violations[0] else ""; businessDate = today() }];
      case null [{ open = false; completed = false; items = 0; done = 0; failures = 0; walkDone = false; examined = 0; violations = 0; firstViolation = ""; businessDate = today() }];
    }
  };

  // ── the proofs ────────────────────────────────────────────────────────────

  public query func invariantPageView(section : Nat, cursorHex : Text, limit : Nat) : async [{ rule : Text; detail : Text; examined : Nat; next : Text; done : Bool }] {
    let cursor = if (cursorHex == "") null else C.fromHex(cursorHex);
    let r = O.page(ctx(), section, cursor, limit);
    let next = switch (r.next) { case (?c) C.hex(c); case null "" };
    if (r.violations.size() == 0) return [{ rule = ""; detail = ""; examined = r.examined; next; done = r.done }];
    Array.map<O.Violation, { rule : Text; detail : Text; examined : Nat; next : Text; done : Bool }>(r.violations, func(v) { { rule = v.rule; detail = v.detail; examined = r.examined; next; done = r.done } })
  };

  public query func sealView() : async [{ cashOk : Bool; paid : Nat; captured : Nat; refunds : Nat; invariants : Nat; lastAuditDay : Nat; lastAuditExamined : Nat;
    lastAuditViolations : Nat; closedDays : Nat; atBlock : Nat }] {
    [{ cashOk = s.paidTotal + s.refundsCommitted == s.capturedDone; paid = s.paidTotal; captured = s.capturedDone; refunds = s.refundsCommitted;
       invariants = O.INVARIANTS; lastAuditDay = s.walk.day; lastAuditExamined = s.walk.examined; lastAuditViolations = s.walk.violations.size();
       closedDays = s.closedDays; atBlock = DL.length(log) }]
  };

  public query func contractView() : async [{ principalHex : Text; guestDataKey : Text; identity : Text; atBlock : Nat }] {
    [{ principalHex = selfHex(); guestDataKey = C.hex(s.guestDataKey); identity = switch memphis { case null "transportKey"; case (?_) "memphis" }; atBlock = DL.length(log) }]
  };

  public query func fingerprintView() : async Text { C.hex(St.fingerprintHash(s, later)) };
  public query func logLength() : async Nat { DL.length(log) };
  public query func tipHash() : async ?Blob { DL.tipHash(log) };
  public query func blockBytes(index : Nat) : async ?Blob { DL.rawBlock(log, index) };
  public query func upgradeCount() : async Nat { upgrades };
  public query func refOf(id : Nat) : async Text { Ref.of(id) };

  // the install's arguments, applied last, when everything they touch exists
  transient let _setup : () = setup();

  // ── the timer ─────────────────────────────────────────────────────────────

  /// A minute's tick for the automatic night audit. Timers do not survive an upgrade; a transient
  /// declaration is evaluated again by every install and upgrade, so the tick is armed by both.
  /// After the audit's steps the tick pushes the gateway queue, so what the audit queued (a capture, a
  /// no-show's charge on file, a token to delete) is done by the contract itself, as its own blocks.
  transient let _autoAuditTimer = Timer.recurringTimer<system>(#seconds 60, func() : async () {
    autoAuditTick();
    if (gatewayOwed()) ignore await* pump(self(), AUTO_GATEWAY_PER_TICK);
  });
};
