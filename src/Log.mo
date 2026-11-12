/// Log.mo - this hotel's block log: what a block records, and how it is written and read.
///
/// A block is one accepted command with the business date and the height it was accepted at, and the
/// encoding version its bytes were written under (so a later reader re-derives a hash with the version
/// the block recorded, never with `current`). The block's timestamp field carries the height; nothing
/// here reads a clock.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Blob "mo:core/Blob";

import C "mo:kernel/codec/Canonical";
import DL "mo:kernel/domain/DomainLog";
import KE "mo:kernel/domain/Encoding";

import Cmd "Command";
import Enc "Encoding";

module {

  public type Event = { day : Nat; height : Nat; version : Nat8; command : Cmd.Command };

  public let DOMAIN : Text = "LUXOR-BLOCK-v1";

  func write(w : C.Writer, e : Event) {
    w.nat(e.day);
    w.nat(e.height);
    w.nat8(e.version);
    switch (Enc.bytesAt(e.version, e.command)) {
      case (?b) w.blob(b);
      // the accept path binds a command to a version before it reaches the log; an empty body here
      // would fail to decode, loudly, rather than decode as some other command
      case null w.blob(Blob.fromArray([]));
    };
  };

  func read(r : C.Reader) : ?Event {
    let ?day = r.nat() else return null;
    let ?height = r.nat() else return null;
    let ?version = r.nat8() else return null;
    let ?body = r.blob() else return null;
    let ?command = Enc.read(version, body) else return null;
    ?{ day; height; version; command }
  };

  public let codec : DL.Codec<Event> = {
    version = 1;
    supports = func(v : Nat8) : Bool { v == 1 };
    domain = DOMAIN;
    write;
    read;
  };

  public func newState() : DL.State { DL.newState() };

  public func bind(day : Nat, height : Nat, c : Cmd.Command) : ?Event {
    switch (KE.bindCurrent(Enc.registry, c)) {
      case (?b) ?{ day; height; version = b.version; command = c };
      case null null;
    }
  };
}
