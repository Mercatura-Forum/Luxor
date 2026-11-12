/// TextArena.mo - variable-length text in stable memory, addressed by (offset, length).
///
/// A row is fixed width and a room's description is not, so the row carries a reference and the
/// bytes live in an append-only region beside it. This is Mentat's `TextArena` shape over the
/// kernel's `rows/RegionStore`, with the same widths, written here because the enterprise system is
/// a later dependency of this product.
///
/// Append-only: a string is never moved or overwritten, so a reference taken at block N is valid at
/// every later block. Deterministic: offsets follow the order of writes, which is the order of the
/// log, so a replay produces byte-identical references. A refusal is typed rather than a trap, and
/// `fits` lets a fold size every string it will write **before** it writes any of them, so a refused
/// command leaves no arena bytes behind.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Text "mo:core/Text";

import RegionStore "mo:kernel/rows/RegionStore";
import SR "mo:kernel/rows/StableRows";

import W "Widths";

module {

  public type Arena = RegionStore.State;
  public type Ref = { offset : Nat; length : Nat };
  public let EMPTY : Ref = { offset = 0; length = 0 };

  public func newArena() : Arena { RegionStore.newState() };
  public func bytesUsed(a : Arena) : Nat { RegionStore.size(a) };

  func pow256(n : Nat) : Nat { var r = 1; var i = 0; while (i < n) { r *= 256; i += 1 }; r };
  public func maxLength() : Nat { pow256(W.ARENA_LEN) - 1 };
  public func maxOffset() : Nat { pow256(W.ARENA_OFFSET) - 1 };

  /// Would these strings fit, together, if written now? Asked before any of them is written.
  public func fits(a : Arena, texts : [Text], maxEach : Nat) : ?Text {
    var total = 0;
    for (t in texts.vals()) {
      let n = Text.encodeUtf8(t).size();
      if (n > maxEach or n > maxLength()) return ?("a text of " # Nat.toText(n) # " bytes is longer than the " # Nat.toText(Nat.min(maxEach, maxLength())) # "-byte limit");
      total += n;
    };
    if (RegionStore.size(a) + total > maxOffset()) return ?"the text arena is full";
    null
  };

  /// Store a string. Only called after `fits` has answered for it, so it cannot refuse; a string
  /// that does not fit here is a fold written out of order, which is a trap, not a refusal.
  public func put(a : Arena, t : Text) : Ref {
    let bytes = Text.encodeUtf8(t);
    let n = bytes.size();
    if (n == 0) return EMPTY;
    assert (n <= maxLength());
    let offset = RegionStore.size(a);
    ignore RegionStore.append(a, bytes);
    { offset; length = n }
  };

  public func get(a : Arena, r : Ref) : Text {
    if (r.length == 0) return "";
    if (r.offset + r.length > RegionStore.size(a)) return "";
    switch (Text.decodeUtf8(RegionStore.read(a, r.offset, r.length))) { case (?t) t; case null "" }
  };

  public func putRef(b : SR.Buf, r : Ref) {
    SR.putNat(b, r.offset, W.ARENA_OFFSET);
    SR.putNat(b, r.length, W.ARENA_LEN);
  };

  public func getRef(a : [Nat8], off : Nat) : Ref {
    { offset = SR.getNat(a, off, W.ARENA_OFFSET); length = SR.getNat(a, off + W.ARENA_OFFSET, W.ARENA_LEN) }
  };

  public func blobOf(a : Arena, r : Ref) : Blob {
    if (r.length == 0) Blob.fromArray([]) else RegionStore.read(a, r.offset, r.length)
  };
}
