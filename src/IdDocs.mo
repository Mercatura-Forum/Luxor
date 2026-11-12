/// IdDocs.mo - a guest's identity document, captured at check-in, sealed, and erased on schedule.
///
/// The desk's browser encrypts the image with a key of its own (AES-GCM), seals that key to the
/// hotel's guest-data key, and uploads only ciphertext, in chunks, to the kernel's `Evidence` store.
/// Filing it records the document against the booking with an erasure day: the guest's departure plus
/// the property's retention period. The night audit erases what is due by destroying the sealed key;
/// the ciphertext and the record that a document existed (its fingerprint, its size, who filed it)
/// remain, and nobody, the hotel included, can open it again.
///
/// EVERY CHECK BEFORE ANY WRITE. `Evidence.sealUpload` writes before `Evidence.add` could refuse, so
/// filing asks every question `add` would ask first, and only then seals and adds.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Text "mo:core/Text";

import Evidence "mo:kernel/eco/Evidence";
import KeyRing "mo:kernel/eco/KeyRing";
import RowStore "mo:kernel/rows/RowStore";
import SR "mo:kernel/rows/StableRows";

import Rf "Refusal";
import St "Store";
import W "Widths";

module {

  public type Out = { #ok : [Nat]; #err : Rf.Refusal };

  public let RING : Text = "scope:hotel:team";
  // chunks travel as hex text: twice the bytes of the largest chunk Evidence accepts

  public type IdDoc = St.IdDocRow;
  let idDoc = St.ID_DOC_DECL;
  public func maxChunkHex() : Nat { Evidence.MAX_CHUNK * 2 };

  func ev(e : Evidence.Error) : Rf.Refusal { #invalid({ what = Evidence.errorText(e) }) };

  public func begin(c : St.Ctx, staff : Principal, bookingId : Nat, size : Nat, chunkHashes : [Text]) : Out {
    let ?b = St.booking(c.s, bookingId) else return #err(#noSuchBooking({ id = bookingId }));
    if (b.status != #confirmed and b.status != #checkedIn) return #err(#bookingState({ id = bookingId; state = "closed"; wanted = "arriving or in house" }));
    if (c.s.guestDataKey.size() == 0) return #err(#invalid({ what = "Set the hotel's guest-data key before capturing documents." }));
    switch (Evidence.beginUpload(c.s.evidence, staff, c.day, size, chunkHashes)) { case (#ok _) #ok([size]); case (#err e) #err(ev(e)) }
  };

  public func put(c : St.Ctx, staff : Principal, blobId : Text, index : Nat, bytes : Blob) : Out {
    switch (Evidence.putChunk(c.s.evidence, staff, blobId, index, bytes)) { case (#ok x) #ok([x.arrived, x.want]); case (#err e) #err(ev(e)) }
  };

  public func file(c : St.Ctx, staff : Principal, bookingId : Nat, blobId : Text, plainHash : Text, plainSize : Nat, mime : Text, fileKey : Text) : Out {
    let ?prop = St.property(c.s) else return #err(#notConfigured);
    let ?b = St.booking(c.s, bookingId) else return #err(#noSuchBooking({ id = bookingId }));
    // what `Evidence.add` would refuse, asked before `sealUpload` writes anything
    if (Text.size(mime) > Evidence.MAX_MIME or Text.size(mime) == 0) return #err(#invalid({ what = "The document's type is missing or too long." }));
    if (Text.size(plainHash) != 64) return #err(#invalid({ what = "A document's fingerprint is 64 hex characters." }));
    if (not Text.startsWith(fileKey, #text "lxe1.")) return #err(#invalid({ what = "The document's key must arrive sealed to the hotel's key." }));
    switch (Map.get(c.s.evidence.staging, Text.compare, blobId)) {
      case null return #err(#invalid({ what = "No upload has that id." }));
      case (?st) {
        if (st.owner != staff) return #err(#notTheOwner);
        if (Map.size(st.arrived) != st.chunkHashes.size()) return #err(#invalid({ what = "The upload has " # Nat.toText(Map.size(st.arrived)) # " of " # Nat.toText(st.chunkHashes.size()) # " parts." }));
      };
    };
    switch (KeyRing.currentEpochFor(c.s.keys, RING)) { case (#ok _) {}; case (#err e) return #err(#invalid({ what = KeyRing.errorText(e) })) };
    // every check has passed; the writes begin
    switch (Evidence.sealUpload(c.s.evidence, staff, c.day, blobId)) { case (#ok _) {}; case (#err e) { assert false; return #err(ev(e)) } };
    let doc = switch (Evidence.add(c.s.evidence, c.s.keys, staff, c.day, "booking:" # Nat.toText(bookingId), RING, blobId, plainHash, plainSize, "identity", mime, "", fileKey)) {
      case (#ok d) d;
      case (#err e) { assert false; return #err(ev(e)) };
    };
    let id = c.s.nextIdDocId;
    c.s.nextIdDocId += 1;
    RowStore.put<IdDoc>(c.s.idDocs, idDoc, id, { bookingId; documentId = doc.id; eraseDay = b.departure + prop.idRetentionDays; erased = false; lastBlock = c.block });
    #ok([id, doc.id])
  };

  public func due(s : St.Stores, day : Nat, limit : Nat) : [(Nat, IdDoc)] {
    switch (RowStore.page<IdDoc>(s.idDocs, idDoc, "due", SR.key2(0, W.DAY, 0, W.ID), SR.key2(day, W.DAY, St.MAX_ID, W.ID), null, limit)) { case (#ok p) p.rows; case (#err _) [] }
  };

  /// The audit's erasure: the sealed key is destroyed, the record stays.
  public func erase(c : St.Ctx, id : Nat, d : IdDoc) {
    switch (Evidence.erase(c.s.evidence, d.documentId, c.day, "retention period ended")) { case (#ok _) {}; case (#err _) {} };
    RowStore.put<IdDoc>(c.s.idDocs, idDoc, id, { d with erased = true; lastBlock = c.block });
  };
}
