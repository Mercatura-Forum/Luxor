#!/usr/bin/env bash
# The clock check's negative control: each fault the check claims to catch is injected into a scratch
# copy of the tree, and the check must go red on every one. A check only ever seen green is a check
# nobody knows is connected. After Hippocrates' control of the same name.
#
# Attribution: Thebes Core Team. Licence: Apache 2.0.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
caught=0; missed=0

try() {
  local what="$1"; shift
  local broken="$TMP/$what"
  mkdir -p "$broken"
  # every file the tree has, committed or not (untracked, non-ignored files too), so the copy is this tree
  ( cd "$HERE" && git ls-files -z --cached --others --exclude-standard | xargs -0 tar -c ) | tar -x -C "$broken"
  # the injection itself must succeed and must change something the check reads
  if ! ( cd "$broken" && "$@" ); then echo "CONTROL BROKEN: the $what injection failed"; missed=$((missed+1)); return; fi
  if diff -rq "$HERE/src" "$broken/src" >/dev/null 2>&1 && diff -rq "$HERE/test" "$broken/test" >/dev/null 2>&1; then
    echo "CONTROL BROKEN: the $what injection changed nothing"; missed=$((missed+1)); return
  fi
  if ( cd "$broken" && ./tools/no_direct_clock.sh > "$TMP/$what.log" 2>&1 ); then
    echo "MISSED: the check stayed green with $what"; missed=$((missed+1))
  else
    echo "caught: $what"; grep -E "^(DIRECT CLOCK READ|TIME TAKEN|TWO SUBSTRATE|NOT A BOUNDARY|UNPINNED|FAILED)" "$TMP/$what.log" | head -2
    caught=$((caught+1))
  fi
}

# 1. a domain module reading the clock itself
try direct-clock-read sed -i '0,/^import /s//import Time "mo:core\/Time";\nimport /' src/Quote.mo
# 2. a surface taking its time from the caller
try caller-supplied-time sh -c 'printf "\nlet nowNs : Int = 0;\n" >> test/Hotel.test.mo'
# 3. a second module supplying a substrate Source, which is a second clock
try second-substrate-clock sh -c 'printf "module {\n  public let source = { substrateNow = func() : Nat64 { 0 }; substrateHeight = func() : Nat { 0 }; blockTimestamp = func() : ?Nat64 { null } };\n}\n" > src/Second.mo'
# 4. the file that supplies the Source stops being the contract
try boundary-that-is-not-a-contract sed -i 's/^persistent actor class Luxor(/module Luxor(/' src/Luxor.mo
# 5. a vendored file no pin names, reading the clock: the vendor directory as a way around rule 1
try unpinned-vendored-clock sh -c 'printf "import Time \"mo:core/Time\";\nmodule { public func now() : Int { Time.now() } };\n" > src/vendor/Sneak.mo'

echo "count: clock faults injected = 5"
echo "count: clock faults the check caught = $caught"
if [ "$missed" -ne 0 ]; then echo "CLOCK CONTROL FAILED: $missed fault(s) passed; the check is not connected"; exit 1; fi
echo "CLOCK CONTROL GREEN"
