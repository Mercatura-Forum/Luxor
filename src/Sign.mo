/// Sign.mo - ECDSA P-256 signing with SHA-256, for the merchant's requests to the payment gateway.
///
/// The kernel verifies P-256 signatures (mo:kernel/sig/P256) and does not sign, so the signing half
/// lives here: the same curve and the same field arithmetic (after the kernel's P256.mo, whose
/// arithmetic is private to it), a scalar multiplication of the base point, and the nonce of RFC 6979
/// §3.2, which is derived from the key and the message with HMAC-SHA-256 (RFC 2104) rather than drawn,
/// so no signature depends on randomness at the moment of signing. The private key itself is drawn
/// once from the substrate (see Luxor.mo, merchantKey).
///
/// Checked against RFC 4231 (HMAC-SHA-256) and RFC 6979 §A.2.5 (P-256, SHA-256) in test/Crypto.test.mo,
/// and every signature against the kernel's own verifier.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Int "mo:core/Int";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Sha256 "mo:sha2/Sha256";

module {

  public let p : Nat = 0xffffffff00000001000000000000000000000000ffffffffffffffffffffffff;
  public let n : Nat = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551;
  let gx : Nat = 0x6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296;
  let gy : Nat = 0x4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5;

  // ── bytes ──

  public func natOf(bytes : [Nat8]) : Nat {
    var v = 0;
    for (b in bytes.vals()) v := v * 256 + Nat8.toNat(b);
    v
  };

  /// A number as exactly 32 big-endian bytes (it is below 2^256).
  public func bytes32(v : Nat) : [Nat8] {
    var x = v;
    let le = Array.tabulate<Nat8>(32, func(_) { let b = Nat8.fromNat(x % 256); x /= 256; b });
    Array.tabulate<Nat8>(32, func(i) { le[31 - i] })
  };

  func sha256(bytes : [Nat8]) : [Nat8] { Blob.toArray(Sha256.fromArray(#sha256, bytes)) };

  // ── HMAC-SHA-256, RFC 2104 ──

  public func hmac(key : [Nat8], message : [Nat8]) : [Nat8] {
    let k = if (key.size() > 64) sha256(key) else key;
    let block = Array.tabulate<Nat8>(64, func(i) { if (i < k.size()) k[i] else 0 });
    let inner = sha256(Array.concat(Array.map<Nat8, Nat8>(block, func(b) { b ^ 0x36 }), message));
    sha256(Array.concat(Array.map<Nat8, Nat8>(block, func(b) { b ^ 0x5c }), inner))
  };

  // ── the field and the curve (the kernel's arithmetic, restated) ──

  func fadd(x : Nat, y : Nat) : Nat { let s = x + y; if (s >= p) s - p else s };
  func fsub(x : Nat, y : Nat) : Nat { if (x >= y) x - y else x + p - y };
  func fmul(x : Nat, y : Nat) : Nat { (x * y) % p };

  /// The inverse of x modulo m (m prime, 0 < x < m).
  public func inv(x : Nat, m : Nat) : Nat {
    var r0 : Int = m; var r1 : Int = x; var t0 : Int = 0; var t1 : Int = 1;
    while (r1 != 0) {
      let q = r0 / r1;
      let r2 = r0 - q * r1; r0 := r1; r1 := r2;
      let t2 = t0 - q * t1; t0 := t1; t1 := t2;
    };
    let t = t0 % m;
    Int.abs(if (t < 0) t + m else t)
  };

  type Pt = (Nat, Nat, Nat);   // Jacobian; z = 0 is the point at infinity
  let INF : Pt = (1, 1, 0);

  func dbl(pt : Pt) : Pt {
    let (x1, y1, z1) = pt;
    if (z1 == 0 or y1 == 0) return INF;
    let delta = fmul(z1, z1);
    let gamma = fmul(y1, y1);
    let beta = fmul(x1, gamma);
    let alpha = fmul(3, fmul(fsub(x1, delta), fadd(x1, delta)));
    let x3 = fsub(fmul(alpha, alpha), fmul(8, beta));
    let z3 = fsub(fsub(fmul(fadd(y1, z1), fadd(y1, z1)), gamma), delta);
    let y3 = fsub(fmul(alpha, fsub(fmul(4, beta), x3)), fmul(8, fmul(gamma, gamma)));
    (x3, y3, z3)
  };

  func add(pa : Pt, pb : Pt) : Pt {
    let (x1, y1, z1) = pa;
    let (x2, y2, z2) = pb;
    if (z1 == 0) return pb;
    if (z2 == 0) return pa;
    let z1z1 = fmul(z1, z1); let z2z2 = fmul(z2, z2);
    let u1 = fmul(x1, z2z2); let u2 = fmul(x2, z1z1);
    let s1 = fmul(y1, fmul(z2, z2z2)); let s2 = fmul(y2, fmul(z1, z1z1));
    let h = fsub(u2, u1);
    let rr = fmul(2, fsub(s2, s1));
    if (h == 0) return if (rr == 0) dbl(pa) else INF;
    let i = fmul(fmul(2, h), fmul(2, h));
    let j = fmul(h, i);
    let v = fmul(u1, i);
    let x3 = fsub(fsub(fmul(rr, rr), j), fmul(2, v));
    let y3 = fsub(fmul(rr, fsub(v, x3)), fmul(2, fmul(s1, j)));
    let z3 = fmul(fsub(fsub(fmul(fadd(z1, z2), fadd(z1, z2)), z1z1), z2z2), h);
    (x3, y3, z3)
  };

  /// k·G in affine coordinates; null for the point at infinity (k a multiple of n).
  public func baseMul(k : Nat) : ?(Nat, Nat) {
    var acc = INF;
    var bit = 255;
    loop {
      acc := dbl(acc);
      if ((k / Nat.pow(2, bit)) % 2 == 1) acc := add(acc, (gx, gy, 1));
      if (bit == 0) return affine(acc);
      bit -= 1;
    }
  };

  func affine(pt : Pt) : ?(Nat, Nat) {
    let (x, y, z) = pt;
    if (z == 0) return null;
    let zi = inv(z, p);
    let zi2 = fmul(zi, zi);
    ?(fmul(x, zi2), fmul(y, fmul(zi2, zi)))
  };

  // ── keys and signatures ──

  /// A usable private key from 32 drawn bytes, or null in the negligible case they are not in [1, n).
  public func privateKeyOf(bytes : [Nat8]) : ?Nat {
    if (bytes.size() != 32) return null;
    let d = natOf(bytes);
    if (d == 0 or d >= n) null else ?d
  };

  /// The public key for a private key, as its affine coordinates.
  public func publicKey(d : Nat) : (Nat, Nat) {
    switch (baseMul(d)) { case (?q) q; case null (0, 0) }   // d is in [1, n), so d·G is never infinity
  };

  /// The public key as the 65 uncompressed SEC1 bytes (04 ‖ x ‖ y).
  public func publicKeyBytes(d : Nat) : [Nat8] {
    let (x, y) = publicKey(d);
    Array.concat<Nat8>([0x04], Array.concat(bytes32(x), bytes32(y)))
  };

  /// The deterministic nonces of RFC 6979 §3.2 for a private key and a SHA-256 digest: each call of
  /// the generator gives the next candidate, as step h of the RFC does when a candidate is refused.
  public func nonces(d : Nat, digest : [Nat8]) : () -> Nat {
    let x = bytes32(d);
    let h = bytes32(natOf(digest) % n);           // bits2octets: qlen = hlen = 256
    var v = Array.tabulate<Nat8>(32, func(_) { 0x01 });
    var k = Array.tabulate<Nat8>(32, func(_) { 0x00 });
    k := hmac(k, Array.concat(Array.concat(Array.concat(v, [0x00 : Nat8]), x), h));
    v := hmac(k, v);
    k := hmac(k, Array.concat(Array.concat(Array.concat(v, [0x01 : Nat8]), x), h));
    v := hmac(k, v);
    var started = false;
    func() : Nat {
      loop {
        if (started) { k := hmac(k, Array.concat(v, [0x00 : Nat8])); v := hmac(k, v) };
        started := true;
        v := hmac(k, v);
        let t = natOf(v);
        if (t >= 1 and t < n) return t;
      }
    }
  };

  /// Sign a SHA-256 digest: (r, s). The nonce is RFC 6979's, so the same key and digest always give
  /// the same signature.
  public func signDigest(d : Nat, digest : [Nat8]) : (Nat, Nat) {
    let e = natOf(digest) % n;
    let next = nonces(d, digest);
    loop {
      let k = next();
      switch (baseMul(k)) {
        case (?(x, _)) {
          let r = x % n;
          if (r != 0) {
            let s = inv(k, n) * ((e + r * d) % n) % n;
            if (s != 0) return (r, s);
          };
        };
        case null {};
      };
    }
  };

  /// Sign a message (hashed here with SHA-256): the 64 bytes r ‖ s.
  public func sign(d : Nat, message : [Nat8]) : [Nat8] {
    let (r, s) = signDigest(d, sha256(message));
    Array.concat(bytes32(r), bytes32(s))
  };
}
