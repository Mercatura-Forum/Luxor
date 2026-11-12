/// The TEST gateway's rules (gateway-test/Gateway.mo), driven directly: a merchant is known only by
/// the key its install gave it, and every capture, refund and void is refused unless that key signed
/// exactly this gateway, act, authorisation, amount and request key. A request nobody signed can
/// neither move money nor take a request key the merchant will use later.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Blob "mo:core/Blob";
import Debug "mo:core/Debug";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import C "mo:kernel/codec/Canonical";

import G "../gateway-test/Gateway";
import Sign "../src/Sign";

var checks = 0;
var failures = 0;
func check(cond : Bool, what : Text) { checks += 1; if (not cond) { failures += 1; Debug.print("FAIL: " # what) } };

let HOTEL = Principal.fromBlob(Blob.fromArray([0, 0, 0x65, 0xf9, 0x12, 0x78, 0xff, 0xe3]));
let OTHER = Principal.fromBlob(Blob.fromArray([0, 0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66]));
let GW = "0000615626b24c05";          // this gateway's principal, as the hotel names it in what it signs
let HOTEL_KEY : Nat = 0x1d6a8c1e5f02b7a9c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f607182930;
let WRONG_KEY : Nat = 0x2e7b9d2f6013c8bad4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a41;

func sig(key : Nat, gw : Text, act : Text, id : Nat, amount : Nat, requestKey : Nat) : Text {
  C.hexOf(Sign.sign(key, G.message(gw, act, id, amount, requestKey)))
};

let s = G.newState();
let k = G.newCards();

// ── the merchant's key, from the install ─────────────────────────────────────

check(G.setMerchant(s, HOTEL, "zz") != null, "a key that is not hex is refused");
check(G.setMerchant(s, HOTEL, C.hexOf(Sign.bytes32(1))) != null, "a key of the wrong length is refused");
check(G.setMerchant(s, HOTEL, "04" # C.hexOf(Sign.bytes32(1)) # C.hexOf(Sign.bytes32(2))) != null, "a key off the curve is refused");
check(G.setMerchant(s, HOTEL, C.hexOf(Sign.publicKeyBytes(HOTEL_KEY))) == null, "the hotel's key is taken");
check(G.merchantList(s).size() == 1, "only the hotel is a merchant");
Debug.print("count: key registrations checked = 5");

// ── capture ──────────────────────────────────────────────────────────────────

let a1 = G.authorize(s, "approve", 20_020, "EUR", HOTEL, 7);
check(a1.ok and a1.authId == 1, "an approved authorisation");
check(not G.capture(s, GW, 1, 20_020, 100, sig(WRONG_KEY, GW, "capture", 1, 20_020, 100)).ok, "a capture signed by another key is refused");
check(not G.capture(s, GW, 1, 20_020, 100, sig(HOTEL_KEY, GW, "capture", 1, 20_000, 100)).ok, "a capture whose amount differs from what was signed is refused");
check(not G.capture(s, GW, 1, 20_020, 100, sig(HOTEL_KEY, GW, "capture", 1, 20_020, 101)).ok, "a capture whose request key differs from what was signed is refused");
check(not G.capture(s, GW, 1, 20_020, 100, sig(HOTEL_KEY, "00000000000000ff", "capture", 1, 20_020, 100)).ok, "a signature made for another gateway is refused");
check(not G.capture(s, GW, 1, 20_020, 100, sig(HOTEL_KEY, GW, "refund", 1, 20_020, 100)).ok, "a signature for another act is refused");
check(not G.capture(s, GW, 1, 20_020, 100, "00").ok, "a malformed signature is refused");
check(G.ledger(s).captured == 0, "no refused request moved money");
// the refused requests above used request key 100; none of them may have taken it
let c1 = G.capture(s, GW, 1, 20_020, 100, sig(HOTEL_KEY, GW, "capture", 1, 20_020, 100));
check(c1.ok and c1.amount == 20_020, "the hotel's signed capture lands, on the request key the refused ones named");
let again = G.capture(s, GW, 1, 20_020, 100, sig(HOTEL_KEY, GW, "capture", 1, 20_020, 100));
check(again.ok and G.ledger(s).captured == 20_020, "the same request again repeats its answer and moves nothing twice");
check(not G.capture(s, GW, 1, 1, 102, sig(HOTEL_KEY, GW, "capture", 1, 1, 102)).ok, "a capture past what was authorised is refused");
Debug.print("count: capture cases = 10");

// ── refund and void ──────────────────────────────────────────────────────────

check(not G.refund(s, GW, 1, 5_000, 200, sig(WRONG_KEY, GW, "refund", 1, 5_000, 200)).ok, "a refund signed by another key is refused");
check(G.refund(s, GW, 1, 5_000, 200, sig(HOTEL_KEY, GW, "refund", 1, 5_000, 200)).ok, "the hotel's signed refund lands");
check(not G.refund(s, GW, 1, 20_000, 201, sig(HOTEL_KEY, GW, "refund", 1, 20_000, 201)).ok, "a refund past what was captured is refused");
check(not G.void(s, GW, 1, 300, sig(HOTEL_KEY, GW, "void", 1, 0, 300)).ok, "captured money is refunded, not voided");
let a2 = G.authorize(s, "approve", 9_000, "EUR", HOTEL, 8);
check(not G.void(s, GW, a2.authId, 301, sig(WRONG_KEY, GW, "void", a2.authId, 0, 301)).ok, "a void signed by another key is refused");
check(G.void(s, GW, a2.authId, 301, sig(HOTEL_KEY, GW, "void", a2.authId, 0, 301)).ok and G.view(s, k, a2.authId).status == "voided", "the hotel's signed void lands");
check(not G.capture(s, GW, a2.authId, 9_000, 302, sig(HOTEL_KEY, GW, "capture", a2.authId, 9_000, 302)).ok, "a voided authorisation cannot be captured");
Debug.print("count: refund and void cases = 7");

// ── a merchant the install did not name ──────────────────────────────────────

let a3 = G.authorize(s, "approve", 1_000, "EUR", OTHER, 9);
check(not G.capture(s, GW, a3.authId, 1_000, 400, sig(HOTEL_KEY, GW, "capture", a3.authId, 1_000, 400)).ok,
  "an authorisation for a merchant with no key cannot be captured, whoever signs");
check(G.ledger(s).captured == 20_020 and G.ledger(s).refunded == 5_000 and G.ledger(s).authorisations == 3, "the ledger is what the signed requests did");
Debug.print("count: ledger cases = 2");

// ── a card whose issuer refuses refunds ──────────────────────────────────────

let a4 = G.authorize(s, "refundDeclined", 4_000, "EUR", HOTEL, 10);
check(a4.ok and a4.authId > 0, "a card whose issuer refuses refunds still authorises");
check(G.capture(s, GW, a4.authId, 4_000, 500, sig(HOTEL_KEY, GW, "capture", a4.authId, 4_000, 500)).ok, "and is captured as any other");
let r4 = G.refund(s, GW, a4.authId, 1_000, 501, sig(HOTEL_KEY, GW, "refund", a4.authId, 1_000, 501));
check(not r4.ok and r4.reason == "The card's issuer refused the refund.", "the hotel's signed refund to it is refused, for that reason");
check(G.view(s, k, a4.authId).refunded == 0 and G.ledger(s).refunded == 5_000, "and nothing was refunded");
check(G.refund(s, GW, a4.authId, 1_000, 502, sig(WRONG_KEY, GW, "refund", a4.authId, 1_000, 502)).reason == "The request is not signed by the merchant." and G.ledger(s).refunded == 5_000,
  "an unsigned refund to it is refused before its issuer is asked");
Debug.print("count: refund-declined cases = 5");

// ── a card kept on file ──────────────────────────────────────────────────────

let plain = G.view(s, k, a1.authId);
check(plain.cardToken == 0, "a payment made without the guest's agreement keeps no card");
let declinedFirst = G.authorizeOnFile(s, k, "decline", 6_000, "EUR", HOTEL, 11);
check(not declinedFirst.ok and Map.size(k.cards) == 0, "a declined payment keeps no card on file");
let f1 = G.authorizeOnFile(s, k, "approve", 6_000, "EUR", HOTEL, 12);
let t1 = G.view(s, k, f1.authId).cardToken;
check(f1.ok and t1 > 0, "the guest's own payment with the agreement keeps the card, under a token the merchant reads from the payment");
check(G.cardView(k, t1).kept and G.cardView(k, t1).firstAuth == f1.authId and G.cardView(k, t1).merchant == HOTEL, "the card rests on that payment, bound to that merchant");
Debug.print("count: cards kept = 1");

// ── a charge on file: signed, idempotent, never on a card no longer kept ─────

let capturedBefore = G.ledger(s).captured;
let authsBefore = G.ledger(s).authorisations;
let u1 = G.chargeOnFile(s, k, GW, t1, 6_000, 12, 700, sig(WRONG_KEY, GW, "chargeOnFile", t1, 6_000, 700));
check(not u1.ok and u1.reason == "The request is not signed by the merchant.", "a charge signed by another key is refused");
check(not G.chargeOnFile(s, k, GW, t1, 6_000, 12, 700, sig(HOTEL_KEY, GW, "chargeOnFile", t1, 5_000, 700)).ok, "a charge whose amount differs from what was signed is refused");
check(not G.chargeOnFile(s, k, GW, t1, 6_000, 12, 700, sig(HOTEL_KEY, GW, "capture", t1, 6_000, 700)).ok, "a signature for another act is refused");
check(not G.chargeOnFile(s, k, GW, t1 + 99, 6_000, 12, 700, sig(HOTEL_KEY, GW, "chargeOnFile", t1 + 99, 6_000, 700)).ok, "a token the gateway never gave is refused");
check(G.ledger(s).captured == capturedBefore and G.ledger(s).authorisations == authsBefore, "no refused charge moved money or made an authorisation");
// the refused requests above used request key 700; none of them may have taken it
let m1 = G.chargeOnFile(s, k, GW, t1, 6_000, 12, 700, sig(HOTEL_KEY, GW, "chargeOnFile", t1, 6_000, 700));
check(m1.ok and m1.amount == 6_000 and m1.authId > 0, "the hotel's signed charge lands, on the request key the refused ones named, under a new authorisation");
check(G.view(s, k, m1.authId).captured == 6_000 and G.view(s, k, m1.authId).status == "authorised", "authorised and captured in one act");
let m1again = G.chargeOnFile(s, k, GW, t1, 6_000, 12, 700, sig(HOTEL_KEY, GW, "chargeOnFile", t1, 6_000, 700));
check(m1again.ok and m1again.authId == m1.authId and G.ledger(s).captured == capturedBefore + 6_000 and G.cardView(k, t1).charges == 1,
  "the same request again repeats its answer and charges nothing twice");
check(G.refund(s, GW, m1.authId, 1_000, 701, sig(HOTEL_KEY, GW, "refund", m1.authId, 1_000, 701)).ok, "a charge on file is refunded as any capture");
Debug.print("count: charge-on-file cases = 9");

// ── mitDeclined: kept on file, every later charge declined ───────────────────

let f2 = G.authorizeOnFile(s, k, "mitDeclined", 3_000, "EUR", HOTEL, 13);
let t2 = G.view(s, k, f2.authId).cardToken;
check(f2.ok and t2 > 0 and t2 != t1, "the mitDeclined card pays and is kept on file, under a token of its own");
let d2 = G.chargeOnFile(s, k, GW, t2, 3_000, 13, 710, sig(HOTEL_KEY, GW, "chargeOnFile", t2, 3_000, 710));
check(not d2.ok and d2.reason == "The card's issuer declined the charge." and d2.authId == 0, "its charge is declined, for that reason, under no authorisation");
check(G.ledger(s).captured == capturedBefore + 6_000 and G.cardView(k, t2).charges == 0, "and moved nothing");
let d2again = G.chargeOnFile(s, k, GW, t2, 3_000, 13, 710, sig(HOTEL_KEY, GW, "chargeOnFile", t2, 3_000, 710));
check(not d2again.ok and d2again.reason == d2.reason, "the same request again repeats the decline");
Debug.print("count: mitDeclined cases = 4");

// ── forgetting a card ────────────────────────────────────────────────────────

let w1 = G.forgetCard(s, k, GW, t1, 800, sig(WRONG_KEY, GW, "forgetCard", t1, 0, 800));
check(not w1.ok and G.cardView(k, t1).kept, "a deletion signed by another key is refused, and the card stays");
check(G.forgetCard(s, k, GW, t1, 800, sig(HOTEL_KEY, GW, "forgetCard", t1, 0, 800)).ok and not G.cardView(k, t1).kept, "the hotel's signed deletion lands");
let gone = G.chargeOnFile(s, k, GW, t1, 1_000, 12, 801, sig(HOTEL_KEY, GW, "chargeOnFile", t1, 1_000, 801));
check(not gone.ok and gone.reason == "The card is no longer on file." and G.cardView(k, t1).charges == 1, "a forgotten card is never charged");
let twice = G.forgetCard(s, k, GW, t1, 802, sig(HOTEL_KEY, GW, "forgetCard", t1, 0, 802));
check(twice.ok and twice.reason == "The card was already deleted.", "deleting it again says so and succeeds, so a retry is harmless");
check(not G.forgetCard(s, k, GW, 9_999, 803, sig(HOTEL_KEY, GW, "forgetCard", 9_999, 0, 803)).ok, "a token the gateway never gave cannot be deleted");
Debug.print("count: forget cases = 5");

Debug.print("count: checks = " # Nat.toText(checks));
if (failures > 0) { Debug.print("FAIL: " # Nat.toText(failures) # " check(s) failed"); Runtime.trap("battery red") };
