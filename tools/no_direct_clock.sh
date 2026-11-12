#!/usr/bin/env bash
# NOTHING IN LUXOR READS A CLOCK, AND NOTHING TAKES A TIME FROM ITS CALLER, except the contract, which
# supplies the substrate clock to everything else.
#
# After Hippocrates' tools/no_direct_clock.sh, whose reasons hold here unchanged: on Thebes `Time.now()`
# is the block height in seconds, so a module that reads it directly compiles, passes its own tests
# and then dates everything wrong (the banking core refused every dated act at f7e28bb). One module
# answers questions about time (src/ClockWiring.mo, over the kernel's time/Clock), and it reads the
# substrate through a `Source` record the contract supplies.
#
# 1. NO DIRECT CLOCK READ in src/, test/ or gateway-test/. The exemption is earned, not listed: it
#    belongs to whichever file in src/ SUPPLIES the Source (assigns substrateNow and substrateHeight),
#    and only if exactly one file does and that file is a persistent actor.
# 2. NO TIME FROM A CALLER: no parameter named nowNs, nowMs, nowSeconds or timestampNs.
# 3. VENDORED CODE IS PINNED CODE. src/vendor/ holds other repositories' files at a pinned commit
#    (deps/*_PIN). Their own clock reads are theirs and are named here, not hidden (MemphisAuth
#    compares a Memphis token's expiry with the substrate clock, as its library does everywhere). A
#    vendored file no pin names is refused, so the vendor directory cannot become a way around rule 1.
#
# Comment lines are not code.
#
# Attribution: Thebes Core Team. Licence: Apache 2.0.
set -u
cd "$(dirname "$0")/.."

code_of() { sed -e 's://.*::' "$1"; }
CLOCK='mo:base/Time|mo:core/Time|\bTime\.now\b|Prim\.time'
CALLER='\b(nowNs|nowMs|nowSeconds|timestampNs)[[:space:]]*:'

boundary=""
suppliers=0
while IFS= read -r f; do
  if code_of "$f" | grep -qE '\bsubstrateNow[[:space:]]*=' && code_of "$f" | grep -qE '\bsubstrateHeight[[:space:]]*='; then
    suppliers=$((suppliers+1)); boundary="$f"
    echo "the substrate clock is supplied by: $f"
  fi
done < <(find src -name '*.mo' -not -path 'src/vendor/*' | sort)

structural=0
if [ "$suppliers" -eq 0 ]; then
  echo "NO SUBSTRATE CLOCK: no file in src/ supplies the Source"; structural=1
elif [ "$suppliers" -gt 1 ]; then
  echo "TWO SUBSTRATE CLOCKS: $suppliers files supply the Source; a product has one clock"; boundary=""; structural=1
elif ! grep -qE '^[[:space:]]*persistent actor\b' "$boundary"; then
  echo "NOT A BOUNDARY: $boundary supplies the Source but is not the contract"; boundary=""; structural=1
fi

scanned=0; clockReads=0; callerTimes=0
while IFS= read -r f; do
  scanned=$((scanned+1))
  if code_of "$f" | grep -qE "$CLOCK"; then
    if [ "$f" = "$boundary" ]; then
      echo "the boundary reads the substrate clock, which is what a boundary is for: $f"
    else
      echo "DIRECT CLOCK READ: $f"; code_of "$f" | grep -nE "$CLOCK"; clockReads=$((clockReads+1))
    fi
  fi
  if code_of "$f" | grep -qE "$CALLER"; then
    echo "TIME TAKEN FROM THE CALLER: $f"; code_of "$f" | grep -nE "$CALLER"; callerTimes=$((callerTimes+1))
  fi
done < <(find src test gateway-test -name '*.mo' -not -path 'src/vendor/*' | sort)

vendored=0; unpinned=0
while IFS= read -r f; do
  vendored=$((vendored+1))
  name="src/$(basename "$f")"
  pin="$(grep -l -E "[[:space:]]$name\b" deps/*_PIN 2>/dev/null | head -1)"
  if [ -z "$pin" ]; then
    echo "UNPINNED VENDORED FILE: $f is in src/vendor/ and no deps/*_PIN names it"; unpinned=$((unpinned+1))
  elif code_of "$f" | grep -qE "$CLOCK"; then
    echo "a pinned dependency reads its own clock: $f ($(cat "$pin" | head -1))"
  fi
done < <(find src/vendor -name '*.mo' 2>/dev/null | sort)

echo "count: files supplying the substrate clock = $suppliers"
echo "count: source files scanned = $scanned"
echo "count: files free of a direct clock read = $((scanned-clockReads))"
echo "count: files free of a caller-supplied time = $((scanned-callerTimes))"
echo "count: vendored files, each pinned = $((vendored-unpinned))"

fail=0
[ "$scanned" -gt 0 ] || { echo "FAILED: nothing was scanned"; fail=1; }
[ "$clockReads" -eq 0 ] || { echo "FAILED: $clockReads file(s) read a clock directly"; fail=1; }
[ "$callerTimes" -eq 0 ] || { echo "FAILED: $callerTimes file(s) take a time from the caller"; fail=1; }
[ "$structural" -eq 0 ] || { echo "FAILED: the substrate clock is not supplied by exactly one contract"; fail=1; }
[ "$unpinned" -eq 0 ] || { echo "FAILED: $unpinned vendored file(s) are not pinned"; fail=1; }
[ "$fail" -eq 0 ] || exit 1
echo "TIME SURFACE GREEN"
