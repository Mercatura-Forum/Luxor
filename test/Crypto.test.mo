/// The merchant's signing: HMAC-SHA-256 against RFC 4231, ECDSA P-256 against RFC 6979 §A.2.5 (the
/// public key, the deterministic nonce and both published signatures), and every signature made here
/// accepted by the kernel's own verifier, which shares none of this file's code, and refused once
/// altered.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import Sha256 "mo:sha2/Sha256";
import C "mo:kernel/codec/Canonical";
import P256 "mo:kernel/sig/P256";

import Sign "../src/Sign";

var checks = 0;
var failures = 0;
func check(cond : Bool, what : Text) { checks += 1; if (not cond) { failures += 1; Debug.print("FAIL: " # what) } };
func bytes(t : Text) : [Nat8] { Blob.toArray(Text.encodeUtf8(t)) };
func hex(b : [Nat8]) : Text { C.hexOf(b) };

// ── HMAC-SHA-256, RFC 4231 ───────────────────────────────────────────────────

check(hex(Sign.hmac(Array.tabulate<Nat8>(20, func(_) { 0x0b }), bytes("Hi There"))) == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7", "RFC 4231 case 1");
check(hex(Sign.hmac(bytes("Jefe"), bytes("what do ya want for nothing?"))) == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", "RFC 4231 case 2");
check(hex(Sign.hmac(Array.tabulate<Nat8>(131, func(_) { 0xaa }), bytes("Test Using Larger Than Block-Size Key - Hash Key First")))
  == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54", "RFC 4231 case 6: a key longer than the block is hashed first");
Debug.print("count: HMAC vectors = 3");

// ── ECDSA P-256 with SHA-256, RFC 6979 §A.2.5 ────────────────────────────────

let d : Nat = 0xC9AFA9D845BA75166B5C215767B1D6934E50C3DB36E89B127B8A622B120F6721;
let (ux, uy) = Sign.publicKey(d);
check(ux == 0x60FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6 and uy == 0x7903FE1008B8BC99A41AE9E95628BC64F2F1B20C2D7E9F5177A3C294D4462299, "the public key of the RFC's private key");

func digest(t : Text) : [Nat8] { Blob.toArray(Sha256.fromArray(#sha256, bytes(t))) };
check(Sign.nonces(d, digest("sample"))() == 0xA6E3C57DD01ABE90086538398355DD4C3B17AA873382B0F24D6129493D8AAD60, "the deterministic nonce for \"sample\"");
check(Sign.nonces(d, digest("test"))() == 0xD16B6AE827F17175E040871A1C7EC3500192C4C92677336EC2537ACAEE0008E0, "the deterministic nonce for \"test\"");
let (r1, s1) = Sign.signDigest(d, digest("sample"));
check(r1 == 0xEFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716 and s1 == 0xF7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8, "the signature of \"sample\"");
let (r2, s2) = Sign.signDigest(d, digest("test"));
check(r2 == 0xF1ABB023518351CD71D881567B1EA663ED3EFCF6C5132B354F28D3B0B7D38367 and s2 == 0x019F4113742A2B14BD25926B49C649155F267E60D3814B4C0CC84250E46F0083, "the signature of \"test\"");
Debug.print("count: ECDSA vectors = 5");

// ── made here, accepted by the kernel's verifier, refused once altered ───────

var verified = 0;
for (m in ["sample", "test", "LUXOR-GW-v1|900000000002|capture|7|20020|42"].vals()) {
  let sig = Sign.sign(d, bytes(m));
  let r = Sign.natOf(Array.sliceToArray(sig, 0, 32));
  let s = Sign.natOf(Array.sliceToArray(sig, 32, 64));
  let e = Sign.natOf(digest(m));
  check(P256.verify(ux, uy, e, r, s), "the kernel's verifier accepts the signature of " # m);
  check(not P256.verify(ux, uy, Sign.natOf(digest(m # "x")), r, s), "the kernel's verifier refuses it for another message: " # m);
  check(not P256.verify(ux, uy, e, r, (s + 1) % Sign.n), "the kernel's verifier refuses an altered signature: " # m);
  verified += 1;
};
let other = Sign.publicKey(d + 1);
check(not P256.verify(other.0, other.1, Sign.natOf(digest("sample")), r1, s1), "another key does not verify the signature");
check(Sign.publicKeyBytes(d).size() == 65 and Sign.publicKeyBytes(d)[0] == 0x04, "the public key is 65 uncompressed bytes");
check(Sign.privateKeyOf(Array.tabulate<Nat8>(32, func(_) { 0 })) == null and Sign.privateKeyOf(Array.tabulate<Nat8>(32, func(_) { 0xff })) == null,
  "zero and a value past the order are not keys");
Debug.print("count: signatures checked by the kernel = " # Nat.toText(verified));

Debug.print("count: checks = " # Nat.toText(checks));
if (failures > 0) { Debug.print("FAIL: " # Nat.toText(failures) # " check(s) failed"); Runtime.trap("battery red") };
