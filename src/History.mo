/// A booking's history, read from the command log.
///
/// Every act on a booking is a block in the log, so the history is the log itself, read backwards a
/// bounded stretch at a time. A command names the booking it acts on directly (a cancel, a check-in),
/// through its hold (a confirmation), through a payment (a gateway outcome) or through a proposal (an
/// approval). The night audit acts on many bookings in one block; the folio lines and payments it
/// posts record that block, and the contract adds those to what the scan finds.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Nat "mo:core/Nat";
import C "mo:kernel/codec/Canonical";

import Cmd "Command";
import Enc "Encoding";
import R "Rows";
import St "Store";
import TA "TextArena";

module {

  /// The booking a proposal's act names, read back from the act bytes the proposal keeps.
  func proposalBooking(s : St.Stores, proposalId : Nat) : ?Nat {
    let ?p = St.proposal(s, proposalId) else return null;
    let ?bytes = C.fromHex(TA.get(s.arena, p.act)) else return null;
    let ?act = Enc.readActBytes(bytes) else return null;
    ?Cmd.dualActBooking(act)
  };

  /// Whether a logged command acted on this booking, and in what words.
  public func actOn(s : St.Stores, c : Cmd.Command, bookingId : Nat, b : R.Booking) : ?Text {
    let name = Cmd.familyOf(c);
    let hit = switch c {
      case (#confirmHold { holdId }) holdId == b.holdId;
      case (#modifyBooking { bookingId = id }) id == bookingId;
      case (#cancelBooking { bookingId = id }) id == bookingId;
      case (#claimBooking { bookingId = id }) id == bookingId;
      case (#checkIn { bookingId = id }) id == bookingId;
      case (#checkOut { bookingId = id }) id == bookingId;
      case (#moveRoom { bookingId = id }) id == bookingId;
      case (#settleAtDesk { bookingId = id }) id == bookingId;
      case (#postCharge { bookingId = id }) id == bookingId;
      case (#addPayer { bookingId = id }) id == bookingId;
      case (#routeLines { bookingId = id }) id == bookingId;
      case (#settleShare { bookingId = id }) id == bookingId;
      case (#issueInvoice { bookingId = id }) id == bookingId;
      case (#beginIdUpload { bookingId = id }) id == bookingId;
      case (#fileIdDocument { bookingId = id }) id == bookingId;
      case (#recordGatewayOutcome { paymentId }) switch (St.payment(s, paymentId)) { case (?p) p.bookingId == bookingId; case null false };
      case (#propose { act }) Cmd.dualActBooking(act) == bookingId;
      case (#approve { proposalId }) proposalBooking(s, proposalId) == ?bookingId;
      case (#reject { proposalId }) proposalBooking(s, proposalId) == ?bookingId;
      case _ false;
    };
    if (not hit) return null;
    switch c {
      case (#propose { act }) ?(name # ":" # Cmd.dualActName(act));
      case _ ?name;
    }
  };

  /// At most this many blocks are read for one page of a history.
  public let MAX_SCAN : Nat = 500;
}
