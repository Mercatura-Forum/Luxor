/// Luxor TEST gateway - a payment service provider for test mode, as its own contract.
///
/// TEST MODE ONLY. It never receives a card number: the browser recognises the published test cards
/// and sends a scenario (approve, decline, insufficient), and the gateway answers with an
/// authorisation reference. The merchant (the hotel's contract) looks the authorisation up, and
/// captures, refunds and voids against it with requests signed by its P-256 key. The merchants' keys
/// arrive as this contract's install (or upgrade) arguments, through the signed deploy path, and each
/// install or upgrade may add or replace them; no call registers a key. Capture, refund and void are
/// idempotent on the merchant's request key, so a retry after a lost reply can never move money twice.
/// Its ledger is public, so the hotel's cash law can be checked against a record the hotel did not
/// write. The rules live in Gateway.mo.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import C "mo:kernel/codec/Canonical";

import G "Gateway";

persistent actor class TestGateway(init : { merchants : [{ merchant : Principal; publicKey : Text }] }) = this {

  let s = G.newState();
  /// The cards on file, a state of their own: the state above keeps the type it had, so an upgrade of a
  /// gateway already running keeps every authorisation, and this starts empty.
  let cards = G.newCards();

  /// The merchants' keys from this install's or upgrade's arguments. A key that is not a point of the
  /// curve stops the install, rather than leaving a merchant that could never be paid.
  transient let _merchants : () = for (m in init.merchants.vals()) {
    switch (G.setMerchant(s, m.merchant, m.publicKey)) { case (?why) Runtime.trap("TestGateway: " # why); case null {} };
  };

  func selfHex() : Text { C.hex(Principal.toBlob(Principal.fromActor(this))) };

  public shared func authorize(scenario : Text, amount : Nat, currency : Text, merchant : Principal, merchantRef : Nat)
    : async [{ ok : Bool; authId : Nat; reason : Text; testMode : Bool }] {
    let r = G.authorize(s, scenario, amount, currency, merchant, merchantRef);
    [{ r with testMode = true }]
  };

  /// The guest's payment that also keeps the card on file, because the guest agreed to it on the
  /// payment page: the merchant reads the card's token from the authorisation.
  public shared func authorizeOnFile(scenario : Text, amount : Nat, currency : Text, merchant : Principal, merchantRef : Nat)
    : async [{ ok : Bool; authId : Nat; reason : Text; testMode : Bool }] {
    let r = G.authorizeOnFile(s, cards, scenario, amount, currency, merchant, merchantRef);
    [{ r with testMode = true }]
  };

  /// The update form, for a contract: an inter-contract await on a query export gets no reply here.
  public shared func authorization_u(id : Nat) : async G.View { G.view(s, cards, id) };
  public query func authorizationView(id : Nat) : async [G.View] { [G.view(s, cards, id)] };

  public shared func capture_u(id : Nat, amount : Nat, requestKey : Nat, sigHex : Text) : async G.Outcome { G.capture(s, selfHex(), id, amount, requestKey, sigHex) };
  public shared func refund_u(id : Nat, amount : Nat, requestKey : Nat, sigHex : Text) : async G.Outcome { G.refund(s, selfHex(), id, amount, requestKey, sigHex) };
  public shared func void_u(id : Nat, requestKey : Nat, sigHex : Text) : async G.Outcome { G.void(s, selfHex(), id, requestKey, sigHex) };
  public shared func chargeOnFile_u(token : Nat, amount : Nat, merchantRef : Nat, requestKey : Nat, sigHex : Text) : async G.ChargeOutcome {
    G.chargeOnFile(s, cards, selfHex(), token, amount, merchantRef, requestKey, sigHex)
  };
  public shared func forgetCard_u(token : Nat, requestKey : Nat, sigHex : Text) : async G.Outcome { G.forgetCard(s, cards, selfHex(), token, requestKey, sigHex) };

  /// A card on file as the gateway holds it: its merchant, whether it is still kept, how many charges.
  public query func cardView(token : Nat) : async [G.CardView] { [G.cardView(cards, token)] };

  /// The public ledger: what was captured and refunded, for a cash check the hotel did not write.
  public query func ledgerView() : async [{ authorisations : Nat; captured : Nat; refunded : Nat; testMode : Bool }] { [G.ledger(s)] };

  /// The merchants this gateway will take signed requests from, with their keys' x coordinate in hex.
  public query func merchantsView() : async [{ merchant : Principal; keyX : Text }] {
    G.merchantList(s)
  };
}
