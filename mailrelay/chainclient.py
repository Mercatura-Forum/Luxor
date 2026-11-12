"""The relay's calls to a hotel's contract, signed with that hotel's mailer key.

Every call is an update, because only an update's sender is signed on this chain (a query's is merely
named), and the contract answers its mailer's methods only to the mailer. The reply is read from its bytes
(`candid.decode`), never from printed text.

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import json, threading, time, urllib.error, urllib.request
from . import candid

SETUP = ["on", "authorised", "tested", "mailKey", "today", "nameEn", "nameAr", "currency", "minorUnits", "checkInText", "checkOutText", "atBlock"]
DUE = ["outboxId", "kind", "attempts", "sealed", "lang", "bookingId", "ref", "status", "guestName", "roomEn", "roomAr", "planEn", "planAr", "arrival",
       "departure", "rooms", "adults", "children", "roomTotal", "extras", "taxes", "charged", "credited", "paid", "outstanding", "penalty", "cancelDeadline",
       "refundable", "next", "atBlock"]
REPLY = ["ok", "kind", "reason", "block", "a", "b", "c"]


def signing_payload(cid, method, arg, sender, nonce):
    """The chain's ingress signing payload for a call (tag 0x02)."""
    lp = lambda b: len(b).to_bytes(4, "big") + b
    return b"egypt-l1-ingress-v1" + b"\x02" + int(cid).to_bytes(8, "big") + lp(method.encode()) + lp(arg) + lp(sender) + int(nonce).to_bytes(8, "big")


class Refused(Exception):
    """The chain answered and refused the call (a stated refusal, not a lost one)."""


class ChainClient:
    def __init__(self, base, cid, mailer_key, timeout=90):
        from cryptography.hazmat.primitives import serialization
        self.base, self.cid, self.key, self.timeout = base.rstrip("/"), int(cid), mailer_key, timeout
        self.pub = mailer_key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        self.nonce = 0
        self.lock = threading.Lock()

    def _post(self, path, body):
        data = json.dumps(body).encode()
        for attempt in range(5):
            req = urllib.request.Request(self.base + path, data=data, headers={"content-type": "application/json"}, method="POST")
            try:
                with urllib.request.urlopen(req, timeout=30) as r:
                    return json.loads(r.read())
            except urllib.error.HTTPError as e:
                if e.code in (400, 403):
                    raise Refused(f"{path} {e.code}") from None
                if e.code != 503 or attempt == 4:
                    raise ConnectionError(f"{path} {e.code}") from None
                time.sleep(0.5 * 2 ** attempt)
            except (urllib.error.URLError, OSError) as e:
                raise ConnectionError(str(e)) from None

    def update(self, method, args):
        """The decoded reply of a signed update; ConnectionError when its fate is not known."""
        arg = candid.encode(args)
        with self.lock:     # the pass and the HTTP threads share one client per hotel: nonces never repeat
            self.nonce = nonce = max(time.time_ns() // 1000, self.nonce + 1)
        sig = self.key.sign(signing_payload(self.cid, method, arg, self.pub, nonce))
        r = self._post("/api/call", {"canister_id": self.cid, "method": method, "arg": arg.hex(), "sender": self.pub.hex(), "nonce": nonce,
                                     "signature": sig.hex()})
        if r.get("error") or not r.get("message_hash"):
            raise Refused(f"{method}: {str(r.get('error'))[:200]}")
        end = time.time() + self.timeout
        while time.time() < end:
            time.sleep(0.15)
            try:
                with urllib.request.urlopen(f"{self.base}/api/receipt?hash={r['message_hash']}", timeout=10) as rr:
                    rec = json.loads(rr.read())
            except (urllib.error.URLError, OSError):
                continue
            if rec.get("status") == "success":
                return candid.decode(bytes.fromhex(rec.get("reply") or ""))
            if rec.get("status") == "error":
                raise Refused(f"{method}: {str(rec.get('error'))[:200]}")
        raise ConnectionError(f"{method}: no receipt")

    # ── the four methods the relay uses ──
    def setup(self):
        rows = self.update("mailerSetup_u", [])[0]
        return candid.named(rows[0], SETUP) if rows else None

    def due(self, cursor, limit):
        return [candid.named(x, DUE) for x in self.update("mailDue_u", [("text", cursor), ("nat", limit)])[0]]

    def record_outcome(self, outbox_id, sent, failure):
        return candid.named(self.update("recordMailOutcome", [("nat", outbox_id), ("bool", sent), ("text", failure)])[0][0], REPLY)

    def record_test(self, digest_hex):
        return candid.named(self.update("recordMailTest", [("text", digest_hex)])[0][0], REPLY)
