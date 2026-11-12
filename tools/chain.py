#!/usr/bin/env python3
"""A small client for Luxor on a Thebes chain: Candid for the argument types Luxor's interface uses
(nat, int, text, bool, principal, vec nat), calls and queries over a gateway's /api, and the P-256 keys
a guest's browser holds (hold keys, manage keys) with the exact messages the contract verifies.

Used by the mail relay's tests. Updates are signed by an Ed25519 key (see Chain): the
chain refuses an unsigned call that names a sender once its signed-sender gate is active. On a deployment
whose identity mode is "transportKey" the caller is that key's principal; that mode is for a deployment with no identity contract.

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import hashlib, json, re, time, urllib.error, urllib.request
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

def uleb(n):
    out = bytearray()
    while True:
        b = n & 0x7f
        n >>= 7
        if n == 0:
            out.append(b); return bytes(out)
        out.append(b | 0x80)


def sleb(n):
    out = bytearray()
    while True:
        b = n & 0x7f
        n >>= 7
        if (n == 0 and not (b & 0x40)) or (n == -1 and (b & 0x40)):
            out.append(b); return bytes(out)
        out.append(b | 0x80)


def encode(args):
    """args: list of (type, value); type in nat,int,text,bool,principal,'vecnat','blob' (value: bytes or hex), 'nat64'."""
    table = bytearray()
    ntypes = 0
    refs = []
    for t, _ in args:
        if t == "vecnat":
            table += sleb(-19) + sleb(-3)  # vec nat
            refs.append(uleb(ntypes)); ntypes += 1
        elif t == "blob":
            table += sleb(-19) + sleb(-5)  # vec nat8
            refs.append(uleb(ntypes)); ntypes += 1
        else:
            refs.append(sleb({"null": -1, "bool": -2, "nat": -3, "int": -4, "nat64": -8, "text": -15, "principal": -24}[t]))
    out = bytearray(b"DIDL") + uleb(ntypes) + table + uleb(len(args))
    for r in refs:
        out += r
    for t, v in args:
        if t == "nat": out += uleb(v)
        elif t == "int": out += sleb(v)
        elif t == "nat64": out += int(v).to_bytes(8, "little")
        elif t == "bool": out += bytes([1 if v else 0])
        elif t == "text":
            b = v.encode(); out += uleb(len(b)) + b
        elif t == "principal":
            b = bytes.fromhex(v) if isinstance(v, str) else v
            out += b"\x01" + uleb(len(b)) + b
        elif t == "vecnat":
            out += uleb(len(v))
            for x in v: out += uleb(x)
        elif t == "blob":
            b = bytes.fromhex(v) if isinstance(v, str) else v
            out += uleb(len(b)) + b
    return out.hex()


def field_hash(name):
    h = 0
    for c in name.encode():
        h = (h * 223 + c) & 0xffffffff
    return h


_ED25519_SPKI = bytes.fromhex("302a300506032b6570032100")


def ed25519_principal_hex(pub):
    """The caller a contract sees for an update signed by Ed25519 key `pub` (a self-authenticating
    principal): SHA-224(DER-SPKI(pub)) || 0x02."""
    return (hashlib.sha224(_ED25519_SPKI + pub).digest() + b"\x02").hex()


def call_signing_payload(cid, method, arg, sender, nonce):
    """The chain's ingress signing payload for a call (tag 0x02)."""
    lp = lambda b: len(b).to_bytes(4, "big") + b
    return (b"egypt-l1-ingress-v1" + b"\x02" + int(cid).to_bytes(8, "big") + lp(method.encode()) + lp(arg)
            + lp(sender) + int(nonce).to_bytes(8, "big"))


class Chain:
    """`sender` picks how calls are sent (the chain refuses an unsigned call that names a sender once its
    signed-sender gate is active, V150):
      ""            anonymous, unsigned;
      64 hex chars  an Ed25519 seed: every update is signed by that key, and `principal` is the caller the
                    contract sees (queries name the same key);
      anything else a claimed principal, sent unsigned. Only the impostor checks use this: below the gate
                    the contract refuses it, above the gate the node does."""
    def __init__(self, base, cid, sender=""):
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        self.base, self.cid = base.rstrip("/"), int(cid)
        self._key, self.seed = None, None
        if re.fullmatch(r"[0-9a-fA-F]{64}", sender or ""):
            self._key, self.seed = Ed25519PrivateKey.from_private_bytes(bytes.fromhex(sender)), sender
            pub = self._key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
            self.sender, self.principal = pub.hex(), ed25519_principal_hex(pub)
        else:
            self.sender, self.principal = sender, sender
        self._nonce = 0

    def _signed(self, method, arg_hex):
        if self._key is None:
            return {"sender": self.sender, "nonce": time.time_ns() // 1000}
        self._nonce = max(time.time_ns() // 1000, self._nonce + 1)
        pub = bytes.fromhex(self.sender)
        sig = self._key.sign(call_signing_payload(self.cid, method, bytes.fromhex(arg_hex), pub, self._nonce))
        return {"sender": self.sender, "nonce": self._nonce, "signature": sig.hex()}

    def _post(self, path, body):
        # A gateway shared by many clients answers 503 when it is momentarily full. The request was not
        # accepted, so sending it again is safe (a call refused at submission never ran); anything else,
        # or a 503 that persists past the retries, is raised.
        data = json.dumps(body).encode()
        for attempt in range(6):
            req = urllib.request.Request(self.base + path, data=data, headers={"content-type": "application/json"}, method="POST")
            try:
                with urllib.request.urlopen(req, timeout=30) as r:
                    return json.loads(r.read())
            except urllib.error.HTTPError as e:
                if e.code != 503 or attempt == 5:
                    if e.code in (400, 403):   # refused at admission (e.g. UNSIGNED_NAMED_SENDER): a stated refusal
                        raise RuntimeError(f"{path} refused {e.code}: {e.read().decode('utf-8', 'replace')[:300]}")
                    raise
                time.sleep(0.5 * 2 ** attempt)

    def query(self, method, args=()):
        r = self._post("/api/query", {"canister_id": self.cid, "method": method, "arg": encode(list(args)), "sender": self.sender})
        if r.get("status") != "success":
            raise RuntimeError(f"query {method}: {r}")
        return r.get("reply_candid", "")

    def call(self, method, args=(), timeout=90):
        arg = encode(list(args))
        body = {"canister_id": self.cid, "method": method, "arg": arg, **self._signed(method, arg)}
        r = self._post("/api/call", body)
        if r.get("error") or not r.get("message_hash"):
            raise RuntimeError(f"call {method}: {r}")
        h = r["message_hash"]
        end = time.time() + timeout
        while time.time() < end:
            time.sleep(0.15)
            with urllib.request.urlopen(f"{self.base}/api/receipt?hash={h}", timeout=10) as rr:
                rec = json.loads(rr.read())
            if rec.get("status") in ("success", "error"):
                if rec["status"] == "error":
                    raise RuntimeError(f"call {method}: {rec}")
                return rec.get("reply_candid") or rec.get("reply", "")
        raise RuntimeError(f"call {method}: receipt timed out")


def outcome(candid):
    """The first Outcome record of a reply: ok, kind, reason, block, a, b, c."""
    def num(name):
        m = re.search(rf"\b{field_hash(name):_}\s*=\s*([\d_]+)\s*:\s*nat", candid) or re.search(rf"\b{name}\s*=\s*([\d_]+)", candid)
        return int(m.group(1).replace("_", "")) if m else 0
    def txt(name):
        m = re.search(rf"\b{field_hash(name):_}\s*=\s*\"((?:[^\"\\]|\\.)*)\"", candid) or re.search(rf"\b{name}\s*=\s*\"((?:[^\"\\]|\\.)*)\"", candid)
        return m.group(1) if m else ""
    m = re.search(rf"\b{field_hash('ok'):_}\s*=\s*(true|false)", candid) or re.search(r"\bok\s*=\s*(true|false)", candid)
    return {"ok": bool(m and m.group(1) == "true"), "kind": txt("kind"), "reason": txt("reason"), "block": num("block"), "a": num("a"), "b": num("b"), "c": num("c")}


# ── the guest's details, sealed to the hotel's key as the page seals them ───────

def seal(text, hotel_hex):
    """ECDH on P-256 with the hotel's guest-data key, HKDF-SHA256, AES-GCM: `lxe1.` and the base64url of
    the ephemeral point, the IV and the ciphertext (the page's keys.ts seal)."""
    import base64, os
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    hotel = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), bytes.fromhex(hotel_hex))
    eph = ec.generate_private_key(ec.SECP256R1())
    key = HKDF(algorithm=hashes.SHA256(), length=32, salt=b"", info=b"LUXOR-GUEST-DATA-v1").derive(eph.exchange(ec.ECDH(), hotel))
    iv = os.urandom(12)
    ct = AESGCM(key).encrypt(iv, text.encode(), None)
    ephraw = eph.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    return "lxe1." + base64.urlsafe_b64encode(ephraw + iv + ct).decode().rstrip("=")


# ── the keys a guest's browser holds ─────────────────────────────────────────

class Key:
    def __init__(self):
        self.sk = ec.generate_private_key(ec.SECP256R1())

    def compressed_hex(self):
        return self.sk.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.CompressedPoint).hex()

    def sign_hex(self, message: bytes):
        der = self.sk.sign(message, ec.ECDSA(hashes.SHA256()))
        r, s = decode_dss_signature(der)
        return (r.to_bytes(32, "big") + s.to_bytes(32, "big")).hex()


def hold_message(contract_text, hold_id, act):
    return f"LUXOR-HOLD-v1|{contract_text}|{hold_id}|{act}".encode()


def manage_message(contract_text, booking_id, act, args_hash, nonce):
    return f"LUXOR-MANAGE-v1|{contract_text}|{booking_id}|{act}|{args_hash}|{nonce}".encode()


def sha256_hex(b):
    return hashlib.sha256(b).hexdigest()


def rows(candid):
    """Split a vec-of-records reply into one text per record, whether the gateway printed the records
    one per line or all on one line, and whatever braces a text field holds. A reply with no record
    (an empty vector) gives no rows."""
    out, i, n = [], 0, len(candid)
    while True:
        i = candid.find("record {", i)
        if i < 0:
            return out
        j, depth, in_text = i + len("record {"), 1, False
        while j < n and depth:
            ch = candid[j]
            if in_text:
                if ch == "\\": j += 1
                elif ch == '"': in_text = False
            elif ch == '"': in_text = True
            elif ch == "{": depth += 1
            elif ch == "}": depth -= 1
            j += 1
        out.append(candid[i + len("record {"):j - 1])
        i = j


def field(rec, name, kind="nat"):
    """A field of one record by name, as nat or int (a Python int), bool or text; None when absent."""
    h = f"{field_hash(name):_}"
    if kind == "nat":
        m = re.search(rf"(?:\b{h}|\b{name})\s*=\s*([\d_]+)", rec); return int(m.group(1).replace("_", "")) if m else None
    if kind == "int":
        m = re.search(rf"(?:\b{h}|\b{name})\s*=\s*([+-]?[\d_]+)", rec); return int(m.group(1).replace("_", "")) if m else None
    if kind == "bool":
        m = re.search(rf"(?:\b{h}|\b{name})\s*=\s*(true|false)", rec); return m and m.group(1) == "true"
    m = re.search(rf"(?:\b{h}|\b{name})\s*=\s*\"((?:[^\"\\]|\\.)*)\"", rec); return unescape(m.group(1)) if m else None


def unescape(t):
    """A Candid text literal's contents as the text it stands for: \\n \\r \\t, an escaped quote or
    backslash, \\u{hex} and a \\hh byte (the printer's form for bytes it does not print), as UTF-8."""
    out, i, n = bytearray(), 0, len(t)
    while i < n:
        ch = t[i]
        if ch != "\\" or i + 1 >= n:
            out += ch.encode(); i += 1; continue
        nx = t[i + 1]
        if nx in "nrt":
            out += {"n": b"\n", "r": b"\r", "t": b"\t"}[nx]; i += 2
        elif nx in "\"'\\":
            out += nx.encode(); i += 2
        elif nx == "u" and i + 2 < n and t[i + 2] == "{":
            j = t.index("}", i); out += chr(int(t[i + 3:j], 16)).encode(); i = j + 1
        elif re.fullmatch(r"[0-9a-fA-F]{2}", t[i + 1:i + 3]):
            out.append(int(t[i + 1:i + 3], 16)); i += 3
        else:
            out += b"\\"; i += 1
    return out.decode("utf-8", errors="replace")


# The contract's oracle sections (src/Oracle.mo SECTIONS): nights, bookings, holds, rooms, waitlist,
# housekeeping, charges, line routes, payment routes, invoices, credit notes, desk refunds, staff bookings. A contract built
# before a section existed answers it with an empty page, so the same walk reads an older contract too.
ORACLE_SECTIONS = 31


def oracle_walk_section(client, section, page=200):
    """Every page of one oracle section: (rows examined, violation details)."""
    examined, violations, cursor = 0, [], ""
    while True:
        pg = rows(client.query("invariantPageView", [("nat", section), ("text", cursor), ("nat", page)]))
        examined += field(pg[0], "examined") or 0
        violations += [field(p, "detail", "text") for p in pg if field(p, "rule", "text")]
        cursor = field(pg[0], "next", "text") or ""
        if field(pg[0], "done", "bool") or not cursor:
            return examined, violations


def oracle_walk(client, sections=ORACLE_SECTIONS, page=200):
    """Every page of every oracle section: (rows examined, violation details)."""
    examined, violations = 0, []
    for section in range(sections):
        cursor = ""
        while True:
            pg = rows(client.query("invariantPageView", [("nat", section), ("text", cursor), ("nat", page)]))
            examined += field(pg[0], "examined") or 0
            violations += [field(p, "detail", "text") for p in pg if field(p, "rule", "text")]
            cursor = field(pg[0], "next", "text") or ""
            if field(pg[0], "done", "bool") or not cursor:
                break
    return examined, violations


def principal_text(raw):
    """A principal's textual form: CRC-32 of the bytes, then the bytes, in lower-case base32 without
    padding, in groups of five joined by '-'."""
    import base64, binascii
    raw = bytes.fromhex(raw) if isinstance(raw, str) else raw
    body = binascii.crc32(raw).to_bytes(4, "big") + raw
    b32 = base64.b32encode(body).decode().lower().rstrip("=")
    return "-".join(b32[i:i + 5] for i in range(0, len(b32), 5))


def blob_of(text):
    """The bytes of a textual Candid blob, e.g. blob "\\01\\ab" or with printable characters."""
    m = re.search(r'blob "((?:[^"\\]|\\.)*)"', text)
    if not m:
        return None
    out, s, i = bytearray(), m.group(1), 0
    while i < len(s):
        if s[i] == "\\" and i + 2 < len(s) + 1 and re.match(r"[0-9a-fA-F]{2}", s[i + 1:i + 3] or ""):
            out.append(int(s[i + 1:i + 3], 16)); i += 3
        elif s[i] == "\\":
            out += s[i + 1].encode(); i += 2
        else:
            out += s[i].encode(); i += 1
    return bytes(out)


def memphis_principal(node, memphis_cid, token_hex, audience, origin, version=1):
    """The principal a Memphis session has in an app with this origin, derived exactly as the app's
    backend derives it (MemphisAuth.verifyWithAudience): the session's anchor from whoami_scoped_u,
    then derive_principal_for_u(anchor, origin, version). Returns the principal's bytes."""
    m = Chain(node, memphis_cid, "")
    who = m.call("whoami_scoped_u", [("blob", token_hex), ("text", audience)])
    anchor = None
    for block in re.findall(r"anchor_id\s*=\s*blob \"(?:[^\"\\]|\\.)*\"|\b%s\s*=\s*blob \"(?:[^\"\\]|\\.)*\"" % f"{field_hash('anchor_id'):_}", who):
        anchor = blob_of(block)
    if anchor is None:
        raise RuntimeError(f"whoami_scoped_u gave no anchor: {who[:300]}")
    d = m.call("derive_principal_for_u", [("blob", anchor), ("text", origin), ("nat64", version)])
    raw = blob_of(d)
    if raw is None:
        raise RuntimeError(f"derive_principal_for_u gave no principal: {d[:300]}")
    return raw
