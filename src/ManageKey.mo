/// ManageKey.mo - the guest's manage key: a P-256 key the browser made, whose private half never
/// leaves the guest's link, and a signature the contract checks before a guest without an account may
/// view, change or cancel their booking.
///
/// The booking stores the public key compressed (33 bytes). Verification decompresses it (P-256's
/// modulus is 3 mod 4, so the square root is one exponentiation), checks the point is on the curve,
/// and verifies the signature the browser's WebCrypto made: raw r ‖ s over SHA-256 of a message that
/// names this contract, the booking, the act, a hash of its arguments and the booking's nonce. The
/// nonce moves with every act, so a signature cannot be used twice; a view is signed over the current
/// nonce and changes nothing.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Text "mo:core/Text";

import C "mo:kernel/codec/Canonical";
import P256 "mo:kernel/sig/P256";

module {

  public let DOMAIN : Text = "LUXOR-MANAGE-v1";

  func powMod(base : Nat, exp : Nat, m : Nat) : Nat {
    var r = 1; var b = base % m; var e = exp;
    while (e > 0) { if (e % 2 == 1) r := (r * b) % m; b := (b * b) % m; e /= 2 };
    r
  };

  /// A compressed point's coordinates, or null if it is not a point of the curve.
  public func decompress(key : Blob) : ?(Nat, Nat) {
    let a = Blob.toArray(key);
    if (a.size() != 33 or (a[0] != (2 : Nat8) and a[0] != (3 : Nat8))) return null;
    let x = P256.natOf(Array.sliceToArray(a, 1, 33));
    if (x >= P256.p) return null;
    let p = P256.p;
    let rhs = (powMod(x, 3, p) + p - (3 * x) % p + P256.b) % p;
    let y0 = powMod(rhs, (p + 1) / 4, p);
    if ((y0 * y0) % p != rhs) return null;
    let odd = a[0] == (3 : Nat8);
    let y = if ((y0 % 2 == 1) == odd) y0 else p - y0;
    if (not P256.onCurve(x, y)) return null;
    ?(x, y)
  };

  /// The exact message a browser signs for an act on a booking.
  public func message(contract : Text, bookingId : Nat, act : Text, argsHash : Text, nonce : Nat) : Blob {
    Text.encodeUtf8(DOMAIN # "|" # contract # "|" # Nat.toText(bookingId) # "|" # act # "|" # argsHash # "|" # Nat.toText(nonce))
  };

  /// Does `sig` (raw r ‖ s, 64 bytes) sign `msg` under the compressed key?
  public func verify(key : Blob, msg : Blob, sig : Blob) : Bool {
    let s = Blob.toArray(sig);
    if (s.size() != 64) return false;
    let ?(qx, qy) = decompress(key) else return false;
    let e = P256.natOf(Blob.toArray(C.sha256(msg)));
    P256.verify(qx, qy, e, P256.natOf(Array.sliceToArray(s, 0, 32)), P256.natOf(Array.sliceToArray(s, 32, 64)))
  };
}
