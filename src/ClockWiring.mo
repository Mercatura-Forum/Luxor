/// ClockWiring.mo - the one place in this product that answers a question about time.
///
/// On Thebes `Time.now()` is the substrate's clock in seconds, which this product also uses as the
/// height. On the chain the hotel runs on it reads Unix time and advances a second a second (measured
/// 28 September 2026); a Thebes subnet may run it from its own start. So the hotel's date is a
/// **business date**, rolled one day at a time by the night audit (the kernel's `#businessDate`
/// authority), and anything that expires - a hold, a proposal - expires at a **height**. The one
/// reader of the clock as wall time is the automatic night audit (HotelClock.mo), which only decides
/// WHEN to issue the audit's commands; on a chain whose clock is not wall time it finds no day due. Nothing outside the actor reads a clock; the actor
/// supplies the kernel's `Source` record, and `tools/no_direct_clock.sh` keeps that true.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Nat64 "mo:core/Nat64";
import Result "mo:core/Result";

import Clock "mo:kernel/time/Clock";

module {

  public type Day = Clock.Day;
  public type Config = Clock.Config;
  public type Source = Clock.Source;
  public type Reading = Clock.Reading;
  public type Error = Clock.Error;

  /// The genesis configuration: the business-date authority, no date until the first roll, and a
  /// roll bound. A hotel's calendar moves one day at a time; the first roll sets it.
  public func genesisConfig() : Config {
    { authority = #businessDate; businessDate = null; maxRollDays = 1; calendar = null }
  };

  public func selectedAuthority() : Clock.Authority { #businessDate };

  public func today(c : Config, s : Source) : Result.Result<Day, Error> { Clock.today(c, s) };

  /// Day and height as one reading, so a decision cannot straddle a block boundary.
  public func read(c : Config, s : Source) : Result.Result<Reading, Error> { Clock.read(c, s) };

  /// The block's timestamp field carries the height, never a wall-clock instant.
  public func stamp(r : Reading) : Nat64 { Nat64.fromNat(r.height) };

  public func roll(c : Config, to : Day) : Result.Result<Config, Error> { Clock.roll(c, to) };

  public func errorText(e : Error) : Text { Clock.errorText(e) };
}
