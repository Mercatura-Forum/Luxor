/// Gateway.mo - the TEST gateway's state and rules, apart from the contract that serves them, so the
/// battery can drive them directly (test/Gateway.test.mo).
///
/// TEST MODE ONLY. It never receives a card number: the browser names a scenario and the gateway
/// answers with an authorisation. The merchant captures, refunds and voids against it, and each of
/// those is signed with the merchant's P-256 key. The gateway was given that key through its own
/// signed install (main.mo), never through a call anyone could make. A request is checked against the
/// key BEFORE anything else, including before its request key is remembered, so a request the merchant
/// did not sign can neither move money nor take a request key the merchant will use later.
///
/// The signed message: LUXOR-GW-v1 | gateway | act | authorisation | amount | request key, with the
/// gateway named by the hex of its principal's bytes, so a signature for one gateway is refused by
/// another. A charge on file and a card's deletion name the card's token where the others name an
/// authorisation.
///
/// A card kept on file: the guest's own payment (`authorizeOnFile`) also keeps the card, and the gateway
/// gives the merchant a token for it, bound to that merchant. The merchant may then charge it once the
/// guest is not there (`chargeOnFile`, a merchant-initiated charge, authorised and captured in one act,
/// resting on that first payment), and asks the gateway to delete it (`forgetCard`). The test card
/// `mitDeclined` (4000 0000 0000 0341) is kept on file and declines every later charge.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Iter "mo:core/Iter";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Sha256 "mo:sha2/Sha256";
import C "mo:kernel/codec/Canonical";
import P256 "mo:kernel/sig/P256";

module {

  public type Status = { #authorised; #declined; #voided };

  public type Auth = {
    id : Nat;
    scenario : Text;
    amount : Nat;
    currency : Text;
    merchant : Principal;
    merchantRef : Nat;
    status : Status;
    captured : Nat;
    refunded : Nat;
  };

  public type Outcome = { ok : Bool; reason : Text; amount : Nat };
  /// `cardToken`: the card kept on file at this payment (0: none).
  public type View = { found : Bool; amount : Nat; currency : Text; merchant : Principal; merchantRef : Nat; status : Text; captured : Nat; refunded : Nat; cardToken : Nat };
  /// A charge on file's outcome: the authorisation it was made under (0 when it was not).
  public type ChargeOutcome = { ok : Bool; reason : Text; amount : Nat; authId : Nat };

  /// A card on file: whose it is, the test scenario of the card, the guest's payment it was kept on, and
  /// whether it is still kept.
  public type Card = { merchant : Principal; scenario : Text; firstAuth : Nat; currency : Text; kept : Bool };
  public type CardView = { found : Bool; merchant : Principal; firstAuth : Nat; kept : Bool; charges : Nat };

  /// The cards on file, apart from `State` so the gateway's upgrade keeps the state it had.
  public type Cards = {
    var nextToken : Nat;
    cards : Map.Map<Nat, Card>;
    /// authorisation -> the card kept at it
    byAuth : Map.Map<Nat, Nat>;
    /// (merchant, act, request key) -> the charge's outcome, so a repeated request repeats its answer
    doneCharge : Map.Map<Text, ChargeOutcome>;
    /// token -> the charges made on it
    charges : Map.Map<Nat, Nat>;
  };

  public func newCards() : Cards {
    { var nextToken = 1; cards = Map.empty(); byAuth = Map.empty(); doneCharge = Map.empty(); charges = Map.empty() }
  };

  public type State = {
    var nextId : Nat;
    auths : Map.Map<Nat, Auth>;
    /// (merchant, act, request key) -> the outcome it already had, so a repeated request repeats its answer.
    done : Map.Map<Text, Outcome>;
    /// Each merchant's P-256 public key, as its affine coordinates.
    merchants : Map.Map<Principal, (Nat, Nat)>;
    var capturedTotal : Nat;
    var refundedTotal : Nat;
  };

  public func newState() : State {
    { var nextId = 1; auths = Map.empty(); done = Map.empty(); merchants = Map.empty(); var capturedTotal = 0; var refundedTotal = 0 }
  };

  /// Register a merchant's public key: 65 uncompressed SEC1 bytes in hex, on the curve. A key that is
  /// not is refused with the reason, and nothing is registered.
  public func setMerchant(s : State, merchant : Principal, keyHex : Text) : ?Text {
    let ?raw = C.fromHex(keyHex) else return ?"The merchant key is not hex.";
    let b = Blob.toArray(raw);
    if (b.size() != 65 or b[0] != 0x04) return ?"The merchant key is not 65 uncompressed bytes.";
    let x = P256.natOf(Array.sliceToArray(b, 1, 33));
    let y = P256.natOf(Array.sliceToArray(b, 33, 65));
    if (not P256.onCurve(x, y)) return ?"The merchant key is not a point of P-256.";
    Map.add(s.merchants, Principal.compare, merchant, (x, y));
    null
  };

  public func statusText(st : Status) : Text { switch st { case (#authorised) "authorised"; case (#declined) "declined"; case (#voided) "voided" } };

  public func authorize(s : State, scenario : Text, amount : Nat, currency : Text, merchant : Principal, merchantRef : Nat) : { ok : Bool; authId : Nat; reason : Text } {
    if (amount == 0) return { ok = false; authId = 0; reason = "An authorisation is for more than zero." };
    if (Text.size(currency) != 3) return { ok = false; authId = 0; reason = "A currency is three letters." };
    let (status, reason) : (Status, Text) = switch scenario {
      case "approve" (#authorised, "");
      case "decline" (#declined, "The card was declined.");
      case "insufficient" (#declined, "Not enough funds on this card.");
      // a card that pays and is captured as any other, whose issuer refuses every refund to it (a
      // closed account): the hotel's refund to it fails, and the hotel pays it back at the desk
      case "refundDeclined" (#authorised, "");
      // a card that pays as any other and is kept on file, whose issuer declines every later charge
      case "mitDeclined" (#authorised, "");
      case _ return { ok = false; authId = 0; reason = "Unknown test scenario." };
    };
    let id = s.nextId;
    s.nextId += 1;
    Map.add(s.auths, Nat.compare, id, { id; scenario; amount; currency; merchant; merchantRef; status; captured = 0; refunded = 0 });
    { ok = status == #authorised; authId = if (status == #authorised) id else 0; reason }
  };

  /// The guest's payment that also keeps the card on file: authorised as `authorize`, and when it is, the
  /// card kept under a new token bound to the merchant. A declined payment keeps nothing.
  public func authorizeOnFile(s : State, k : Cards, scenario : Text, amount : Nat, currency : Text, merchant : Principal, merchantRef : Nat) : { ok : Bool; authId : Nat; reason : Text } {
    let r = authorize(s, scenario, amount, currency, merchant, merchantRef);
    if (r.ok) {
      let token = k.nextToken;
      k.nextToken += 1;
      Map.add(k.cards, Nat.compare, token, { merchant; scenario; firstAuth = r.authId; currency; kept = true });
      Map.add(k.byAuth, Nat.compare, r.authId, token);
    };
    r
  };

  public func view(s : State, k : Cards, id : Nat) : View {
    let cardToken = switch (Map.get(k.byAuth, Nat.compare, id)) { case (?t) t; case null 0 };
    switch (Map.get(s.auths, Nat.compare, id)) {
      case (?a) { { found = true; amount = a.amount; currency = a.currency; merchant = a.merchant; merchantRef = a.merchantRef; status = statusText(a.status); captured = a.captured; refunded = a.refunded; cardToken } };
      case null { { found = false; amount = 0; currency = ""; merchant = Principal.fromText("aaaaa-aa"); merchantRef = 0; status = ""; captured = 0; refunded = 0; cardToken = 0 } };
    }
  };

  public func cardView(k : Cards, token : Nat) : CardView {
    let charges = switch (Map.get(k.charges, Nat.compare, token)) { case (?n) n; case null 0 };
    switch (Map.get(k.cards, Nat.compare, token)) {
      case (?c) { { found = true; merchant = c.merchant; firstAuth = c.firstAuth; kept = c.kept; charges } };
      case null { { found = false; merchant = Principal.fromText("aaaaa-aa"); firstAuth = 0; kept = false; charges } };
    }
  };

  /// The bytes a merchant signs for one request.
  public func message(gatewayHex : Text, act : Text, authId : Nat, amount : Nat, requestKey : Nat) : [Nat8] {
    Blob.toArray(Text.encodeUtf8("LUXOR-GW-v1|" # gatewayHex # "|" # act # "|" # Nat.toText(authId) # "|" # Nat.toText(amount) # "|" # Nat.toText(requestKey)))
  };

  /// Whether the authorisation's own merchant signed this request (r ‖ s, 64 bytes, in hex).
  func signedByMerchant(s : State, a : Auth, gatewayHex : Text, act : Text, amount : Nat, requestKey : Nat, sigHex : Text) : Bool {
    signedBy(s, a.merchant, gatewayHex, act, a.id, amount, requestKey, sigHex)
  };

  /// Whether `merchant` signed this request over `subject` (an authorisation, or a card's token).
  func signedBy(s : State, merchant : Principal, gatewayHex : Text, act : Text, subject : Nat, amount : Nat, requestKey : Nat, sigHex : Text) : Bool {
    let ?(qx, qy) = Map.get(s.merchants, Principal.compare, merchant) else return false;
    let ?raw = C.fromHex(sigHex) else return false;
    let sig = Blob.toArray(raw);
    if (sig.size() != 64) return false;
    let e = P256.natOf(Blob.toArray(Sha256.fromArray(#sha256, message(gatewayHex, act, subject, amount, requestKey))));
    P256.verify(qx, qy, e, P256.natOf(Array.sliceToArray(sig, 0, 32)), P256.natOf(Array.sliceToArray(sig, 32, 64)))
  };

  func once(s : State, key : Text, run : () -> Outcome) : Outcome {
    switch (Map.get(s.done, Text.compare, key)) {
      case (?o) o;
      case null { let o = run(); Map.add(s.done, Text.compare, key, o); o };
    }
  };

  let UNSIGNED : Outcome = { ok = false; reason = "The request is not signed by the merchant."; amount = 0 };

  public func capture(s : State, gatewayHex : Text, id : Nat, amount : Nat, requestKey : Nat, sigHex : Text) : Outcome {
    let ?a0 = Map.get(s.auths, Nat.compare, id) else return { ok = false; reason = "No such authorisation."; amount = 0 };
    if (not signedByMerchant(s, a0, gatewayHex, "capture", amount, requestKey, sigHex)) return UNSIGNED;
    once(s, Principal.toText(a0.merchant) # "/capture/" # Nat.toText(requestKey), func() : Outcome {
      let ?a = Map.get(s.auths, Nat.compare, id) else return { ok = false; reason = "No such authorisation."; amount = 0 };
      if (a.status != #authorised) return { ok = false; reason = "The authorisation is " # statusText(a.status) # "."; amount = 0 };
      if (amount == 0 or a.captured + amount > a.amount) return { ok = false; reason = "The capture exceeds what is authorised."; amount = 0 };
      Map.add(s.auths, Nat.compare, id, { a with captured = a.captured + amount });
      s.capturedTotal += amount;
      { ok = true; reason = ""; amount }
    })
  };

  public func refund(s : State, gatewayHex : Text, id : Nat, amount : Nat, requestKey : Nat, sigHex : Text) : Outcome {
    let ?a0 = Map.get(s.auths, Nat.compare, id) else return { ok = false; reason = "No such authorisation."; amount = 0 };
    if (not signedByMerchant(s, a0, gatewayHex, "refund", amount, requestKey, sigHex)) return UNSIGNED;
    once(s, Principal.toText(a0.merchant) # "/refund/" # Nat.toText(requestKey), func() : Outcome {
      let ?a = Map.get(s.auths, Nat.compare, id) else return { ok = false; reason = "No such authorisation."; amount = 0 };
      if (amount == 0 or a.refunded + amount > a.captured) return { ok = false; reason = "The refund exceeds what was captured."; amount = 0 };
      if (a.scenario == "refundDeclined") return { ok = false; reason = "The card's issuer refused the refund."; amount = 0 };
      Map.add(s.auths, Nat.compare, id, { a with refunded = a.refunded + amount });
      s.refundedTotal += amount;
      { ok = true; reason = ""; amount }
    })
  };

  public func void(s : State, gatewayHex : Text, id : Nat, requestKey : Nat, sigHex : Text) : Outcome {
    let ?a0 = Map.get(s.auths, Nat.compare, id) else return { ok = false; reason = "No such authorisation."; amount = 0 };
    if (not signedByMerchant(s, a0, gatewayHex, "void", 0, requestKey, sigHex)) return UNSIGNED;
    once(s, Principal.toText(a0.merchant) # "/void/" # Nat.toText(requestKey), func() : Outcome {
      let ?a = Map.get(s.auths, Nat.compare, id) else return { ok = false; reason = "No such authorisation."; amount = 0 };
      if (a.captured > 0) return { ok = false; reason = "Captured money is refunded, not voided."; amount = 0 };
      Map.add(s.auths, Nat.compare, id, { a with status = #voided });
      { ok = true; reason = ""; amount = a.amount }
    })
  };

  /// A merchant-initiated charge to a card on file, authorised and captured in one act, as a new
  /// authorisation resting on the guest's first payment. Signed by the card's merchant over its token,
  /// checked before anything else; idempotent on the request key. A card no longer kept is never charged.
  public func chargeOnFile(s : State, k : Cards, gatewayHex : Text, token : Nat, amount : Nat, merchantRef : Nat, requestKey : Nat, sigHex : Text) : ChargeOutcome {
    let ?c0 = Map.get(k.cards, Nat.compare, token) else return { ok = false; reason = "No such card on file."; amount = 0; authId = 0 };
    if (not signedBy(s, c0.merchant, gatewayHex, "chargeOnFile", token, amount, requestKey, sigHex)) return { UNSIGNED with authId = 0 };
    let key = Principal.toText(c0.merchant) # "/chargeOnFile/" # Nat.toText(requestKey);
    switch (Map.get(k.doneCharge, Text.compare, key)) { case (?o) return o; case null {} };
    let o = charge(s, k, token, amount, merchantRef);
    Map.add(k.doneCharge, Text.compare, key, o);
    o
  };

  func charge(s : State, k : Cards, token : Nat, amount : Nat, merchantRef : Nat) : ChargeOutcome {
    func no(reason : Text) : ChargeOutcome { { ok = false; reason; amount = 0; authId = 0 } };
    let ?c = Map.get(k.cards, Nat.compare, token) else return no("No such card on file.");
    if (not c.kept) return no("The card is no longer on file.");
    if (amount == 0) return no("A charge is for more than zero.");
    if (c.scenario == "mitDeclined") return no("The card's issuer declined the charge.");
    let id = s.nextId;
    s.nextId += 1;
    Map.add(s.auths, Nat.compare, id, { id; scenario = "mit:" # Nat.toText(c.firstAuth); amount; currency = c.currency; merchant = c.merchant; merchantRef;
      status = #authorised; captured = amount; refunded = 0 });
    s.capturedTotal += amount;
    Map.add(k.charges, Nat.compare, token, (switch (Map.get(k.charges, Nat.compare, token)) { case (?n) n; case null 0 }) + 1);
    { ok = true; reason = ""; amount; authId = id }
  };

  /// The card deleted: its token is never charged again. Signed by its merchant; deleting a card already
  /// deleted says so and succeeds, so a retry after a lost reply is harmless.
  public func forgetCard(s : State, k : Cards, gatewayHex : Text, token : Nat, requestKey : Nat, sigHex : Text) : Outcome {
    let ?c = Map.get(k.cards, Nat.compare, token) else return { ok = false; reason = "No such card on file."; amount = 0 };
    if (not signedBy(s, c.merchant, gatewayHex, "forgetCard", token, 0, requestKey, sigHex)) return UNSIGNED;
    Map.add(k.cards, Nat.compare, token, { c with kept = false });
    { ok = true; reason = if (c.kept) "" else "The card was already deleted."; amount = 0 }
  };

  func bytes32(v : Nat) : [Nat8] {
    var x = v;
    let le = Array.tabulate<Nat8>(32, func(_) { let b = Nat8.fromNat(x % 256); x /= 256; b });
    Array.tabulate<Nat8>(32, func(i) { le[31 - i] })
  };

  /// The merchants whose signed requests are taken, each with its key's x coordinate in hex.
  public func merchantList(s : State) : [{ merchant : Principal; keyX : Text }] {
    Array.map<(Principal, (Nat, Nat)), { merchant : Principal; keyX : Text }>(Iter.toArray(Map.entries(s.merchants)),
      func((m, (x, _))) { { merchant = m; keyX = C.hex(Blob.fromArray(bytes32(x))) } })
  };

  public func ledger(s : State) : { authorisations : Nat; captured : Nat; refunded : Nat; testMode : Bool } {
    { authorisations = Map.size(s.auths); captured = s.capturedTotal; refunded = s.refundedTotal; testMode = true }
  };
}
