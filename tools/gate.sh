#!/usr/bin/env bash
# THE GATE: every check that needs no chain, run on a COMMIT. The tree under test is a clone of HEAD in a
# scratch directory, so an edit made while the gate runs cannot change what it reports on, and an
# uncommitted file cannot make it green.
#
#   1  the battery            test/run.sh: every battery, with no zero counts
#   2  the independent reader tools/oracle_twin.py: the battery's exported rows, decoded by code that
#                             shares nothing with the contract, must reach the contract's verdict; and
#                             its control (each law broken in the bytes, and caught)
#   3  the frontend           the type check and the unit tests
#   4  the time surface       tools/no_direct_clock.sh, and its control (each injected fault caught)
#   5  contrast               tools/contrast.mjs: WCAG AA for every theme token pair
#   6  the outcall and secret surface  tools/outcall_and_secrets.sh: no credential in a command, row or
#                             method; the outbox row's fields held to their list (law I17); every outbound
#                             request unreplicated and their number pinned; and its control
#   7  the mail relay         mailrelay/tests/run.py: every provider against capture servers (HTTP, SMTP
#                             with TLS, a sign-in with PKCE, DNS) and the pull against the contract's rules;
#                             and its control (each fault injected, caught by the test that names it)
#   8  the walk               tools/walk.py: a dev server started from the gated tree, every guest and
#                             console screen in a real browser at 390 and 1440 px, in English and Arabic,
#                             on the demo data source; and its control. The server is stopped after.
#
# Requirements: the kernel beside this repository, in vendor/thebes-kernel or at KERNEL (vendor/thebes-kernel/README.md), `mops install`
# run in this checkout, `npm ci` run in frontend/, wasmtime, Python 3 with the relay's packages
# (cryptography, dnspython) and Playwright with Chromium for the walk.
#
# Usage: gate.sh [--quick]     --quick skips the controls
#
# Attribution: Thebes Core Team. Licence: Apache 2.0.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
QUICK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) QUICK=1; shift ;;
    *) echo "gate.sh: unknown argument $1"; exit 2 ;;
  esac
done

OUT="${GATE_OUT:-$(mktemp -d)}"
TREE="$OUT/tree"
git clone -q --no-hardlinks "$HERE" "$TREE" && git -C "$TREE" checkout -q "$(git -C "$HERE" rev-parse HEAD)"
echo "gating commit $(git -C "$TREE" rev-parse --short HEAD) in $TREE"
# the dependencies are not part of a commit: the package cache, the frontend's installed modules, the kernel
ln -s "$HERE/.mops" "$TREE/.mops"
ln -s "$HERE/frontend/node_modules" "$TREE/frontend/node_modules"
if [ -z "${KERNEL:-}" ]; then
  if [ -d "$HERE/vendor/thebes-kernel/src/domain" ]; then KERNEL="$HERE/vendor/thebes-kernel"; else KERNEL="$(cd "$HERE/.." && pwd)/thebes-kernel"; fi
fi
export KERNEL
cd "$TREE"

fail=0
step() { echo; echo "── $1 ──────────────────────────────────────────────"; }
red()  { echo "GATE: $1"; fail=$((fail+1)); }
run()  { # run <name> <log> <grep pattern> <command...>
  local name="$1" log="$OUT/$2" pat="$3"; shift 3
  if "$@" > "$log" 2>&1; then grep -E "$pat" "$log"; else tail -25 "$log"; red "$name is red"; fi
}

step "the battery";          run "the battery" battery.log '^(=== |count:|tests: )' env TEST_OUT="$OUT/battery" ./test/run.sh
step "the independent reader"
if [ -s "$OUT/battery/Hotel.log" ]; then
                             run "the independent reader" twin.log '^(count:|not recomputed|TWIN GREEN)' python3 tools/oracle_twin.py "$OUT/battery/Hotel.log"
  [ "$QUICK" -eq 1 ] ||      run "the independent reader's control" twin_control.log '^(count:|caught:|TWIN CONTROL GREEN)' python3 tools/oracle_twin.py "$OUT/battery/Hotel.log" --control
else
  red "the battery left no log, so nothing independent read its rows"
fi
step "the frontend";         run "the type check" tsc.log '.' sh -c 'cd frontend && npx tsc -b && echo "type check clean"'
                             run "the unit tests" vitest.log '(Tests|Test Files)' sh -c 'cd frontend && npx vitest run'
step "the time surface";     run "the clock rule" clock.log '^(count:|the substrate|a pinned|TIME SURFACE GREEN)' ./tools/no_direct_clock.sh
[ "$QUICK" -eq 1 ] ||        run "the clock rule's control" clock_control.log '^(count:|caught:|CLOCK CONTROL GREEN)' ./tools/no_direct_clock_control.sh
step "contrast";             run "contrast" contrast.log '^(count:|CONTRAST GREEN)' node tools/contrast.mjs
step "the outcall and secret surface"
                             run "the outcall and secret check" outcall.log '^(count:|OUTCALL AND SECRET SURFACE GREEN)' ./tools/outcall_and_secrets.sh
[ "$QUICK" -eq 1 ] ||        run "the outcall and secret check's control" outcall_control.log '^(count:|caught:|OUTCALL CONTROL GREEN)' ./tools/outcall_and_secrets_control.sh
step "the mail relay";       run "the mail relay's tests" relay.log '^(count:|RED |RELAY GREEN)' python3 mailrelay/tests/run.py
[ "$QUICK" -eq 1 ] ||        run "the mail relay's control" relay_control.log '^(count:|caught:|MISSED|CONTROL BROKEN|RELAY CONTROL GREEN)' python3 mailrelay/tests/control.py
step "the walk"
# a free port, a server from the gated tree, stopped on every way out
WALK_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
cp frontend/node_modules/@thebes/sdk/runtime/memphis-connect.js frontend/node_modules/@thebes/sdk/runtime/noble-ed25519-3.1.0.js frontend/public/
( cd frontend && exec ./node_modules/.bin/vite --host 127.0.0.1 --port "$WALK_PORT" --strictPort ) > "$OUT/vite.log" 2>&1 &
WALK_PID=$!
trap 'kill "$WALK_PID" 2>/dev/null' EXIT
up=0; for _ in $(seq 1 60); do curl -sf -o /dev/null "http://127.0.0.1:$WALK_PORT/" && { up=1; break; }; sleep 1; done
if [ "$up" -eq 1 ]; then
                             run "the walk" walk.log '^(count:|RED |WALK GREEN)' python3 tools/walk.py --base "http://127.0.0.1:$WALK_PORT" --out "$OUT/walk"
  [ "$QUICK" -eq 1 ] ||      run "the walk's control" walk_control.log '^(count:|caught:|MISSED|CONTROL BROKEN|WALK CONTROL GREEN)' python3 tools/walk.py --base "http://127.0.0.1:$WALK_PORT" --out "$OUT/walk_control" --control
else
  tail -10 "$OUT/vite.log"; red "the dev server for the walk did not start"
fi
kill "$WALK_PID" 2>/dev/null; wait "$WALK_PID" 2>/dev/null; trap - EXIT

echo
if [ "$fail" -ne 0 ]; then echo "GATE FAILED: $fail check(s) red  (logs in $OUT)"; exit 1; fi
echo "GATE GREEN  (logs in $OUT)"
