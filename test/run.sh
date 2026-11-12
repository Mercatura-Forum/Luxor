#!/usr/bin/env bash
# Runs every test/*.test.mo compiled to WASI under wasmtime. A test passes when it exits 0 and prints
# at least one "count: <what> = <n>" line and no zero count: a battery that examined nothing and a
# battery that found nothing wrong both print "0 failures", and only one of them is a test.
# Attribution: Thebes Core Team. Licence: Apache 2.0.
set -u
cd "$(dirname "$0")/.."
MOC="${MOC:-$HOME/.cache/mops/moc/1.4.1/moc}"
SOURCES="$(./tools/packages.sh)"
OUT="${TEST_OUT:-$(mktemp -d)}"
mkdir -p "$OUT"
fail=0; total=0
for t in test/${1:-*}.test.mo; do
  [ -e "$t" ] || continue
  name="$(basename "$t" .test.mo)"; total=$((total+1))
  echo "=== $name"
  if ! $MOC -wasi-system-api $SOURCES -o "$OUT/$name.wasm" "$t" 2> "$OUT/$name.compile.log"; then
    echo "COMPILE FAILED: $name"; grep -v "warning" "$OUT/$name.compile.log" | head -12; fail=$((fail+1)); continue
  fi
  if ! wasmtime "$OUT/$name.wasm" > "$OUT/$name.log" 2>&1; then
    echo "FAILED: $name"; tail -20 "$OUT/$name.log"; fail=$((fail+1)); continue
  fi
  grep -E '^(count:|FAIL)' "$OUT/$name.log"
  if ! grep -Eq '^count: [^=]+ = [1-9][0-9]*$' "$OUT/$name.log"; then echo "FAILED: $name printed no count line"; fail=$((fail+1)); continue; fi
  if grep -Eq '^count: [^=]+ = 0$' "$OUT/$name.log"; then echo "FAILED: $name examined zero records"; fail=$((fail+1)); continue; fi
  if grep -q '^FAIL' "$OUT/$name.log"; then fail=$((fail+1)); fi
done
if [ "$total" -eq 0 ]; then echo "FAILED: no test matched ${1:-*}"; exit 1; fi
echo "tests: $total, failed: $fail  (logs in $OUT)"
[ "$fail" -eq 0 ]
