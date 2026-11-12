#!/usr/bin/env bash
# The outcall-and-secret check's control: one injection per class it claims to catch, each in a copy of
# the tree, and each must turn it red. A credential in a command, in a row and in a public method; an
# address, a name and a key in the outbox row; an outbound request at the replicated default and one
# set explicitly replicated; and an unreplicated one added without raising the pin (the scan must see
# a site at all, or its green over none means nothing).
#
# Attribution: Thebes Core Team. Licence: Apache 2.0.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

caught=0
missed=0

EXPECT=""
try() {
  local what="$1"; shift
  local broken="$TMP/$what"
  rm -rf "$broken"; mkdir -p "$broken"
  # every file the tree has, committed or not: an injection into a file the copy lacks is no catch
  ( cd "$HERE" && git ls-files -z --cached --others --exclude-standard | xargs -0 tar -c ) | tar -x -C "$broken"
  if ! ( cd "$broken" && "$@" ); then
    echo "CONTROL BROKEN: the $what injection command itself failed"; missed=$((missed+1)); return
  fi
  if diff -rq "$HERE/src" "$broken/src" > /dev/null 2>&1; then
    echo "CONTROL BROKEN: the $what injection changed nothing"; missed=$((missed+1)); return
  fi
  if ( cd "$broken" && ./tools/outcall_and_secrets.sh > "$TMP/$what.log" 2>&1 ); then
    echo "MISSED: the check stayed green with $what"; missed=$((missed+1))
  else
    echo "caught: $what"
    grep -E "^(CREDENTIAL|OUTBOX ROW|REPLICATED|FAILED)" "$TMP/$what.log" | head -2
    # a fault of a class with its own message must be red for that message, not for another rule
    if [ -n "$EXPECT" ] && ! grep -q "^$EXPECT" "$TMP/$what.log"; then
      echo "RED FOR ANOTHER REASON: $what did not report \"$EXPECT\""; missed=$((missed+1)); return
    fi
    caught=$((caught+1))
  fi
}

# the hotel's account password as a field of the command that authorises it
EXPECT="CREDENTIAL"; try credential-in-command \
  sed -i 's|    #authoriseMailCredential : { staff : Principal; digest : Blob };|    #authoriseMailCredential : { staff : Principal; digest : Blob; smtpPassword : Text };|' src/Command.mo
# the provider's key stored in the setup row
EXPECT="CREDENTIAL"; try credential-in-row \
  sed -i 's|  public type MailSetup = { mailKey : Blob; mailerGrant : Nat;|  public type MailSetup = { mailKey : Blob; apiKey : Blob; mailerGrant : Nat;|' src/Rows.mo
# an OAuth token taken by a public method, so it rides in the ingress message
EXPECT="CREDENTIAL"; try credential-in-method \
  sed -i 's|  public shared ({ caller }) func setMailOn(session : Text, on : Bool) : async Reply {|  public shared ({ caller }) func setMailOn(session : Text, on : Bool, refreshToken : Text) : async Reply {|' src/Luxor.mo
# the guest's address, name and a key on the outbox row
EXPECT="OUTBOX ROW CHANGED"; try address-in-outbox \
  sed -i 's|  public type Outbox = { bookingId : Nat; kind : E.MailKind;|  public type Outbox = { bookingId : Nat; guestEmail : Text; kind : E.MailKind;|' src/Rows.mo
EXPECT="OUTBOX ROW CHANGED"; try name-in-outbox \
  sed -i 's|  public type Outbox = { bookingId : Nat; kind : E.MailKind;|  public type Outbox = { bookingId : Nat; guestName : TA.Ref; kind : E.MailKind;|' src/Rows.mo
EXPECT="OUTBOX ROW CHANGED"; try key-in-outbox \
  sed -i 's|    queuedBlock : Nat; lastBlock : Nat };|    queuedBlock : Nat; mailKey : Blob; lastBlock : Nat };|' src/Rows.mo
# an outbound request left at the replicated default, then one explicitly replicated
cat > "$TMP/replicated.mo" <<'EOF'
module {
  public func send(ic : actor { http_request : shared { url : Text; is_replicated : ?Bool } -> async () }) : async () {
    await ic.http_request({ url = "https://relay.example/mail"; is_replicated = null });
  };
}
EOF
EXPECT="REPLICATED OUTBOUND REQUEST"; try replicated-default cp "$TMP/replicated.mo" src/Notify.mo
EXPECT="REPLICATED OUTBOUND REQUEST"; try explicitly-replicated sh -c "sed 's|is_replicated = null|is_replicated = ?true|' '$TMP/replicated.mo' > src/Notify.mo"
# an unreplicated request added with the pin left at zero: the scan must find it
EXPECT="FAILED: 2 outbound request line"; try unpinned-unreplicated sh -c "sed 's|is_replicated = null|is_replicated = ?false|' '$TMP/replicated.mo' > src/Notify.mo"

echo "count: injected faults = $((caught+missed))"
echo "count: caught = $caught"
[ "$missed" -eq 0 ] && [ "$caught" -eq 9 ] || { echo "OUTCALL CONTROL FAILED"; exit 1; }
echo "OUTCALL CONTROL GREEN"
