#!/usr/bin/env bash
# NO CREDENTIAL TRAVELS IN A COMMAND, A ROW OR A METHOD; NO OUTBOX ROW CAN HOLD A GUEST'S ADDRESS;
# AND NO OUTBOUND REQUEST IS REPLICATED. After Mentat's tools/outcall_and_secrets.sh.
#
# 1. NO CREDENTIAL IN A COMMAND, A ROW OR A PUBLIC METHOD. A command is written to the log, and the log
#    is for ever; a row is in every validator's state; a method's arguments are in its ingress message.
#    The hotel's email credential is sealed to the mail relay in the owner's browser and never reaches
#    the contract: the contract holds only its digest. Any field or parameter named like a credential
#    fails this check.
#
# 2. THE OUTBOX HOLDS NOTHING PRIVATE (law I17's last clause). The `Outbox` row's fields are held to the
#    list below: which message, for which booking, and what became of it. A field that could carry the
#    address, the guest's name or a key is a new field, and fails here before it can be written.
#
# 3. EVERY OUTBOUND REQUEST IS UNREPLICATED, AND THEIR NUMBER IS PINNED. A request left at the replicated
#    default is sent once per validator: a guest would get one email per node. This contract makes no
#    outbound request at all (the mail relay pulls the outbox; the gateway is another contract, called
#    by an inter-contract call), so the number of outbound sites is pinned at OUTCALLS below. A site
#    added is a count that disagrees with the pin, and fails until it decides `?false` and the pin is
#    raised with it. That is what keeps an empty set honest: the control (outcall_and_secrets_control.sh)
#    injects a site and shows the scan finds it.
#
# Attribution: Thebes Core Team. Licence: Apache 2.0.
set -u
cd "$(dirname "$0")/.."

# The outbound request sites this contract declares. 0: the relay pulls; nothing goes out.
OUTCALLS=0
OUTBOX_FIELDS="attempts bookingId failure kind lastBlock notBefore queuedBlock state"

# a comment starts at `//` at the start of a line or after a space; a URL's `https://` is not one
code_of() { sed -E 's#(^|[[:space:]])//.*$#\1#' "$1"; }

SECRETS='apiKey|api_key|apiToken|authToken|bearerToken|accessToken|refreshToken|clientSecret|secretKey|privateKey|password|passphrase|smtpPassword|credential|credentials|oauthToken|sharedSecret'

fail=0
scanned=0
for f in src/Command.mo src/Rows.mo src/Luxor.mo src/Encoding.mo; do
  [ -f "$f" ] || { echo "FAILED: $f is missing, so nothing was scanned in it"; fail=1; continue; }
  scanned=$((scanned+1))
  if code_of "$f" | grep -qE "\b($SECRETS)\s*:"; then
    echo "CREDENTIAL IN THE CONTRACT'S SURFACE: $f"
    code_of "$f" | grep -nE "\b($SECRETS)\s*:" | head -3
    fail=1
  fi
done

# ── the outbox row's fields ─────────────────────────────────────────────────
fields="$(awk '/public type Outbox = \{/{on=1} on{print} on&&/\};/{exit}' src/Rows.mo | sed -e 's://.*::' -e 's/public type Outbox = {//' -e 's/};//' \
  | tr ';' '\n' | sed -n 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*:.*/\1/p' | sort | tr '\n' ' ' | sed 's/ $//')"
if [ -z "$fields" ]; then
  echo "FAILED: no Outbox row type found in src/Rows.mo, so its fields were not checked"; fail=1
elif [ "$fields" != "$OUTBOX_FIELDS" ]; then
  echo "OUTBOX ROW CHANGED: its fields are [$fields], the list allows [$OUTBOX_FIELDS]"; fail=1
fi
nfields="$(printf '%s\n' $fields | grep -c .)"

# ── the outbound requests ───────────────────────────────────────────────────
sites=0; replicated=0
while IFS= read -r f; do
  n="$(code_of "$f" | grep -cE 'http_request|is_replicated[[:space:]]*=|Outcall\.|Http\.request')"
  sites=$((sites+n))
  while IFS= read -r line; do
    value="$(printf '%s' "$line" | sed -e 's/.*is_replicated[[:space:]]*=[[:space:]]*//' -e 's/[;,}].*//' -e 's/[[:space:]]*$//')"
    if [ "$value" != "?false" ]; then echo "REPLICATED OUTBOUND REQUEST: $f sets is_replicated = $value"; replicated=$((replicated+1)); fi
  done < <(code_of "$f" | grep -E 'is_replicated[[:space:]]*=')
done < <(find src gateway-test -name '*.mo' -not -path '*/vendor/*' | sort)
files="$(find src gateway-test -name '*.mo' -not -path '*/vendor/*' | wc -l)"

echo "count: files scanned for a credential = $scanned"
echo "count: outbox fields held to the list = $nfields"
echo "count: contract files scanned for an outbound request = $files"
echo "count: outbound request lines found = $sites (pinned at $OUTCALLS)"
if [ "$replicated" -ne 0 ]; then echo "FAILED: $replicated outbound request(s) are replicated"; fail=1; fi
if [ "$sites" -ne "$OUTCALLS" ]; then echo "FAILED: $sites outbound request line(s) found where $OUTCALLS are pinned: make each unreplicated, then raise the pin"; fail=1; fi
if [ "$files" -eq 0 ]; then echo "FAILED: no contract file was scanned"; fail=1; fi
[ "$fail" -eq 0 ] || exit 1
echo "OUTCALL AND SECRET SURFACE GREEN"
