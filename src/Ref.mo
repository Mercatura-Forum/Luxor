/// Ref.mo - a booking's reference, LX-XXXXXX-C: its id, spread over six Crockford base-32 characters
/// so neighbouring bookings do not read as neighbours, with a check character that catches a mistyped
/// or transposed character. It is not a secret: knowing a reference opens nothing.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Char "mo:core/Char";
import Nat "mo:core/Nat";
import Text "mo:core/Text";

module {

  let ALPHABET : [Char] = ['0','1','2','3','4','5','6','7','8','9','A','B','C','D','E','F','G','H','J','K','M','N','P','Q','R','S','T','V','W','X','Y','Z'];
  let MUL : Nat = 7_919;
  let ADD : Nat = 104_729;
  let SPAN : Nat = 1_073_741_824;   // 32^6

  func indexOf(c : Char) : ?Nat {
    var i = 0;
    while (i < 32) { if (ALPHABET[i] == c) return ?i; i += 1 };
    null
  };

  func check(digits : [Nat]) : Nat {
    var c = 0;
    for (d in digits.vals()) c := (c * 31 + d) % 32;
    c
  };

  public func of(id : Nat) : Text {
    var n = (id * MUL + ADD) % SPAN;
    let ds = [var 0, 0, 0, 0, 0, 0];
    var i = 6;
    while (i > 0) { i -= 1; ds[i] := n % 32; n /= 32 };
    var body = "";
    for (d in ds.vals()) body #= Char.toText(ALPHABET[d]);
    "LX-" # body # "-" # Char.toText(ALPHABET[check([ds[0], ds[1], ds[2], ds[3], ds[4], ds[5]])])
  };

  /// The id a reference names, or null for a reference that is malformed or fails its check.
  public func parse(ref : Text) : ?Nat {
    let cs = Text.toArray(Text.toUpper(ref));
    if (cs.size() != 11 or cs[0] != 'L' or cs[1] != 'X' or cs[2] != '-' or cs[9] != '-') return null;
    let ds = [var 0, 0, 0, 0, 0, 0];
    var i = 0;
    while (i < 6) { let ?d = indexOf(cs[3 + i]) else return null; ds[i] := d; i += 1 };
    let ?c = indexOf(cs[10]) else return null;
    if (c != check([ds[0], ds[1], ds[2], ds[3], ds[4], ds[5]])) return null;
    var n = 0;
    for (d in ds.vals()) n := n * 32 + d;
    if (n < ADD or (n - ADD) % MUL != 0) return null;
    ?((n - ADD) / MUL)
  };

}
