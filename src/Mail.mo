/// Mail.mo - the messages the hotel owes a guest, and the relay that sends them.
///
/// THE OUTBOX. A guest who gives an address (sealed in their browser to the relay's mail key, so the
/// contract holds ciphertext it cannot read) is owed four messages: the confirmation at once, a
/// pre-arrival note two days before arrival, the receipt at check-out, and a cancellation notice if the
/// booking is cancelled. Each is an `outbox` row written by the act that owes it, in the same block, so a
/// message is owed exactly when its act happened (the transactional outbox). A row says which message,
/// for which booking, and what became of it; it has no field that could hold an address, a name or a key.
///
/// THE RELAY PULLS. The contract makes no outcall. The relay, a service off the chain holding the mail
/// key's private half and the hotel's email credential, reads the due rows through its `#mailer` key and
/// records each outcome with an act signed by that key (`recordMailOutcome`): sent, or failed with a code.
/// A row is sent at most once and tried at most three times; the relay's own store is keyed by
/// (contract, outbox id), so a lost reply never sends twice.
///
/// THE HOTEL'S OWN EMAIL. The owner connects the relay (its mailer key and mail key), seals the hotel's
/// email credential to the relay in the browser and authorises its digest here, the relay sends the
/// owner a test email with that credential and records the digest it tested, and only then may the owner
/// turn guest email on. Until it is on, messages stay due, and the day list says so.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Principal "mo:core/Principal";
import Text "mo:core/Text";

import RowStore "mo:kernel/rows/RowStore";

import E "Enums";
import R "Rows";
import Rf "Refusal";
import St "Store";
import TA "TextArena";
import W "Widths";

module {

  public type Out = { #ok : [Nat]; #err : Rf.Refusal };

  /// How many times a message is tried before it is marked failed.
  public let MAX_ATTEMPTS : Nat = 3;
  /// The pre-arrival note goes this many business days before arrival.
  public let PRE_ARRIVAL_DAYS : Nat = 2;
  /// The largest sealed address: "lxe1." and the base64url of a 65-byte point, a 12-byte IV and an
  /// address of up to 254 bytes (RFC 5321) with its 16-byte tag.
  public let MAX_SEALED_BYTES : Nat = 512;
  /// The smallest: the point, the IV and the tag of an address of three bytes, "a@b".
  public let MIN_SEALED_BYTES : Nat = 133;

  /// A key or digest not given yet: its width of zero bytes.
  public func noKey() : Blob { Blob.fromArray(Array.repeat<Nat8>(0, W.MAIL_KEY)) };
  public func noDigest() : Blob { Blob.fromArray(Array.repeat<Nat8>(0, W.HASH)) };

  public func setup(c : St.Ctx) : R.MailSetup {
    switch (St.mailSetup(c.x)) {
      case (?m) m;
      case null { { mailKey = noKey(); mailerGrant = 0; authorised = noDigest(); tested = noDigest(); on = false; lastBlock = 0 } };
    }
  };

  /// Whether the relay is connected: guests' browsers have a key to seal to.
  public func connected(c : St.Ctx) : Bool { setup(c).mailKey != noKey() };

  func putSetup(c : St.Ctx, m : R.MailSetup) {
    RowStore.put<R.MailSetup>(St.later(c.x, St.MAIL_SETUP_TABLE), R.mailSetup, St.MAIL_SETUP_ID, { m with lastBlock = c.block });
  };

  func isPoint(key : Blob) : Bool { let k = Blob.toArray(key); k.size() == W.MAIL_KEY and k[0] == (4 : Nat8) };

  // ── the owner's acts ────────────────────────────────────────────────────────

  /// The relay connected: its key the hotel's mailer (a different previous key's grant ended), its mail key
  /// the one guests seal to. A credential authorised for an earlier relay is not this relay's, so the
  /// digests are cleared and guest email is off until the owner connects an account again.
  /// `grant` makes the mailer grant (Staff.holdMailerFor) once every check has passed; `endGrant` ends one.
  public func setRelay(c : St.Ctx, mailer : Principal, mailKey : Blob, grant : Principal -> Nat, endGrant : Nat -> ()) : Out {
    if (Principal.isAnonymous(mailer)) return #err(#invalid({ what = "The relay's key is a signed key, not the anonymous one." }));
    if (not isPoint(mailKey)) return #err(#invalid({ what = "The mail key is a raw uncompressed P-256 key." }));
    if (St.holdsRole(c.s, mailer, #owner) or St.holdsRole(c.s, mailer, #revenue) or St.holdsRole(c.s, mailer, #frontDesk)
        or St.holdsRole(c.s, mailer, #auditor) or St.holdsRole(c.s, mailer, #housekeeping)) {
      // a key that is someone's at the hotel would let that person mark messages sent
      return #err(#invalid({ what = "The relay's key already holds a staff role here." }));
    };
    let old = setup(c);
    // ── every check is above this line; nothing below can refuse ──
    let id = grant(mailer);
    if (old.mailerGrant != 0 and old.mailerGrant != id) endGrant(old.mailerGrant);
    putSetup(c, { mailKey; mailerGrant = id; authorised = noDigest(); tested = noDigest(); on = false; lastBlock = c.block });
    #ok([id])
  };

  /// The owner authorises the email account connected in their browser: the digest of the credential as
  /// sealed to the relay. A new account must be tested again before guest email is on.
  public func authorise(c : St.Ctx, digest : Blob) : Out {
    if (not connected(c)) return #err(#invalid({ what = "Connect the mail relay first." }));
    if (digest.size() != W.HASH or digest == noDigest()) return #err(#invalid({ what = "A credential's digest is 32 bytes." }));
    let m = setup(c);
    if (m.authorised == digest) return #err(#invalid({ what = "This account is already the one authorised." }));
    putSetup(c, { m with authorised = digest; tested = noDigest(); on = false });
    #ok([c.block])
  };

  /// Guest email on (only once the relay has tested the authorised account) or off.
  public func turn(c : St.Ctx, on : Bool) : Out {
    let m = setup(c);
    if (on == m.on) return #err(#invalid({ what = if on "Guest email is already on." else "Guest email is already off." }));
    if (on) {
      if (not connected(c)) return #err(#invalid({ what = "Connect the mail relay first." }));
      if (m.authorised == noDigest()) return #err(#invalid({ what = "Connect the hotel's email account first." }));
      if (m.tested != m.authorised) return #err(#invalid({ what = "Send the test email first: the account has not been tested." }));
    };
    putSetup(c, { m with on });
    #ok([c.block])
  };

  // ── the relay's acts ────────────────────────────────────────────────────────

  /// The relay sent the owner's test email with the credential of this digest.
  public func recordTest(c : St.Ctx, digest : Blob) : Out {
    let m = setup(c);
    if (m.authorised == noDigest()) return #err(#invalid({ what = "No email account is authorised." }));
    if (digest != m.authorised) return #err(#invalid({ what = "That is not the account the owner authorised." }));
    if (m.tested == digest) return #err(#invalid({ what = "This account's test is already recorded." }));
    putSetup(c, { m with tested = digest });
    #ok([c.block])
  };

  /// What became of one message. Only a due message, only while guest email is on, only on or after its
  /// day: the relay cannot record a message the hotel had not let it send.
  public func recordOutcome(c : St.Ctx, id : Nat, sent : Bool, failure : E.MailFailure) : Out {
    let ?o = St.outboxRow(c.x, id) else return #err(#invalid({ what = "There is no message " # Nat.toText(id) # "." }));
    if (o.state != #due) return #err(#invalid({ what = "Message " # Nat.toText(id) # " is " # E.mailStateText(o.state) # ", not due." }));
    if (not setup(c).on) return #err(#invalid({ what = "Guest email is not turned on." }));
    if (o.notBefore > c.day) return #err(#invalid({ what = "Message " # Nat.toText(id) # " is not due until day " # Nat.toText(o.notBefore) # "." }));
    if (sent and failure != #none) return #err(#invalid({ what = "A message sent has no failure." }));
    if (not sent and failure == #none) return #err(#invalid({ what = "Say why the message failed." }));
    let attempts = o.attempts + 1;
    let state : E.MailState = if sent #sent else if (attempts >= MAX_ATTEMPTS) #failed else #due;
    putOutbox(c, id, { o with state; attempts; failure });
    #ok([id, attempts])
  };

  // ── the address, and the messages it is owed ─────────────────────────────────

  /// Is this a sealed address, as a browser seals one? Checked for shape only: the contract cannot open
  /// it, and that is the point. Plain text (an address typed straight in) is refused.
  public func sealedShape(sealed : Text) : ?Rf.Refusal {
    let n = Text.encodeUtf8(sealed).size();
    if (not Text.startsWith(sealed, #text "lxe1.")) return ?#invalid({ what = "The address is sealed to the relay's key in the browser, never sent plain." });
    if (n > MAX_SEALED_BYTES) return ?#tooLong({ what = "sealed address"; max = MAX_SEALED_BYTES });
    if (n < MIN_SEALED_BYTES) return ?#invalid({ what = "The sealed address is too short to hold an address." });
    for (ch in Text.toIter(Text.trimStart(sealed, #text "lxe1."))) {
      if (not ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '-' or ch == '_')) {
        return ?#invalid({ what = "The sealed address is not base64url." });
      };
    };
    null
  };

  /// A booking's address given, and its messages owed: the confirmation at once, and a pre-arrival note
  /// two days before arrival when that day is still ahead. The booking's actor has been checked by the
  /// caller (Reservations.attachMail for a guest, the permission table for the desk).
  public func attach(c : St.Ctx, id : Nat, sealed : Text, lang : E.Lang) : Out {
    let ?b = St.booking(c.s, id) else return #err(#noSuchBooking({ id }));
    if (b.status != #confirmed and b.status != #checkedIn) return #err(#bookingState({ id; state = E.bookingStatusText(b.status); wanted = "confirmed or checked in" }));
    if (not connected(c)) return #err(#invalid({ what = "The hotel has not connected guest email." }));
    if (St.mailAddress(c.x, id) != null) return #err(#invalid({ what = "This booking already has an address for its messages." }));
    switch (sealedShape(sealed)) { case (?r) return #err(r); case null {} };
    switch (TA.fits(c.s.arena, [sealed], MAX_SEALED_BYTES)) { case (?why) return #err(#invalid({ what = why })); case null {} };
    // ── every check is above this line; nothing below can refuse ──
    let confirmation = queue(c, id, #confirmation, 0);
    let preArrival = if (b.status == #confirmed and b.arrival >= c.day + PRE_ARRIVAL_DAYS + 1) queue(c, id, #preArrival, b.arrival - PRE_ARRIVAL_DAYS) else 0;
    RowStore.put<R.MailAddress>(St.later(c.x, St.MAIL_ADDRESS_TABLE), R.mailAddress, id,
      { sealed = TA.put(c.s.arena, sealed); lang; attachedBlock = c.block; confirmation; preArrival; receipt = 0; cancellation = 0; lastBlock = c.block });
    #ok([id, confirmation, preArrival])
  };

  func outboxTable(c : St.Ctx) : RowStore.Store { St.later(c.x, St.OUTBOX_TABLE) };

  func putOutbox(c : St.Ctx, id : Nat, o : R.Outbox) {
    RowStore.put<R.Outbox>(outboxTable(c), R.outbox, id, { o with lastBlock = c.block });
  };

  /// A message owed: the next id (rows are never removed, so the count is the last id).
  func queue(c : St.Ctx, bookingId : Nat, kind : E.MailKind, notBefore : Nat) : Nat {
    let id = RowStore.size(outboxTable(c)) + 1;
    RowStore.put<R.Outbox>(outboxTable(c), R.outbox, id,
      { bookingId; kind; notBefore; state = #due; attempts = 0; failure = #none; queuedBlock = c.block; lastBlock = c.block });
    id
  };

  /// A message no longer needed, if it is still due.
  func skip(c : St.Ctx, id : Nat) {
    if (id == 0) return;
    switch (St.outboxRow(c.x, id)) { case (?o) { if (o.state == #due) putOutbox(c, id, { o with state = #skipped }) }; case null {} };
  };

  func putAddress(c : St.Ctx, id : Nat, m : R.MailAddress) {
    RowStore.put<R.MailAddress>(St.later(c.x, St.MAIL_ADDRESS_TABLE), R.mailAddress, id, { m with lastBlock = c.block });
  };

  // ── the hooks: the acts that owe a message, or make one unneeded ─────────────
  // Each is called by its act after the act's last check, and none can refuse.

  /// Cancelled: a confirmation or pre-arrival not yet sent is not sent, and the cancellation is owed.
  public func cancelled(c : St.Ctx, id : Nat) {
    let ?m = St.mailAddress(c.x, id) else return;
    skip(c, m.confirmation);
    skip(c, m.preArrival);
    if (m.cancellation == 0) putAddress(c, id, { m with cancellation = queue(c, id, #cancellation, 0) });
  };

  /// Arrived, or did not come: the pre-arrival note is not sent.
  public func arrivedOrNot(c : St.Ctx, id : Nat) {
    let ?m = St.mailAddress(c.x, id) else return;
    skip(c, m.preArrival);
  };

  /// Checked out: the receipt is owed.
  public func checkedOut(c : St.Ctx, id : Nat) {
    let ?m = St.mailAddress(c.x, id) else return;
    if (m.receipt == 0) putAddress(c, id, { m with receipt = queue(c, id, #receipt, 0) });
  };

  /// The stay moved to another arrival: a pre-arrival note still due moves with it, and is not sent if its
  /// day is no longer ahead.
  public func moved(c : St.Ctx, id : Nat, arrival : Nat) {
    let ?m = St.mailAddress(c.x, id) else return;
    if (m.preArrival == 0) return;
    let ?o = St.outboxRow(c.x, m.preArrival) else return;
    if (o.state != #due) return;
    if (arrival >= c.day + PRE_ARRIVAL_DAYS + 1) {
      // arrival is above PRE_ARRIVAL_DAYS here, by the line above
      let day = Nat.sub(arrival, PRE_ARRIVAL_DAYS);
      if (o.notBefore != day) putOutbox(c, m.preArrival, { o with notBefore = day });
    } else putOutbox(c, m.preArrival, { o with state = #skipped });
  };

  /// How many messages are due by `day` and waiting, counted up to `limit` (`more`: there are others):
  /// for the day list's notice while guest email is off.
  public func waiting(c : St.Ctx, day : Nat, limit : Nat) : { count : Nat; more : Bool } {
    let p = St.mailDue(c.x, day, null, limit);
    { count = p.rows.size(); more = p.next != null }
  };
}
