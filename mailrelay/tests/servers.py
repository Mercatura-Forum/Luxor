"""Capture servers for the relay's tests: everything a provider would receive, recorded on this machine.

  HttpCapture   an HTTPS-less loopback HTTP server: every request kept (method, path, headers, body); the
                answer per path set by the test. Also plays Google's and Microsoft's sign-in: an authorise
                endpoint that hands back a code bound to the PKCE challenge, and a token endpoint that
                checks the verifier against it (RFC 7636 4.6) before it answers.
  SmtpCapture   an SMTP server with TLS (implicit, or STARTTLS), AUTH PLAIN and LOGIN, and configurable
                refusals; it records whether each AUTH arrived over TLS.
  DnsServer     a UDP DNS server answering TXT and CNAME from a dict.
  FakeChain     the hotel contract's mail methods as the relay sees them, with the contract's rules: only
                due rows are listed, an outcome for a row that is not due is refused, three attempts mark
                a row failed, a test is recorded only for the authorised digest.

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import base64, datetime, hashlib, json, os, socket, socketserver, ssl, threading, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import dns.message, dns.rdataclass, dns.rdatatype, dns.rrset
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID


# ── a certificate for localhost ─────────────────────────────────────────────────

def make_cert(directory):
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "localhost")])
    now = datetime.datetime.now(datetime.timezone.utc)
    import ipaddress
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - datetime.timedelta(minutes=5)).not_valid_after(now + datetime.timedelta(days=1))
            .add_extension(x509.SubjectAlternativeName([x509.DNSName("localhost"), x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]), critical=False)
            .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
            .sign(key, hashes.SHA256()))
    cert_path, key_path = os.path.join(directory, "cert.pem"), os.path.join(directory, "key.pem")
    with open(cert_path, "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))
    with open(key_path, "wb") as f:
        f.write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    return cert_path, key_path


# ── HTTP ────────────────────────────────────────────────────────────────────────

class HttpCapture:
    def __init__(self):
        self.requests, self.answers, self.codes, self.tokens = [], {}, {}, {}
        self.refresh_rotates = False
        cap = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def handle_one(self, method):
                n = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(n) if n else b""
                u = urllib.parse.urlparse(self.path)
                cap.requests.append({"method": method, "path": u.path, "query": dict(urllib.parse.parse_qsl(u.query)), "headers": {k.lower(): v for k, v in self.headers.items()}, "body": body})
                if u.path.endswith("/authorize"):
                    return self.authorize(dict(urllib.parse.parse_qsl(u.query)))
                if u.path.endswith("/token"):
                    return self.token(dict(urllib.parse.parse_qsl(body.decode())))
                status, answer, headers = cap.answers.get(u.path, (200, {}, {}))
                if callable(answer):
                    status, answer, headers = answer(cap.requests[-1])
                data = json.dumps(answer).encode()
                self.send_response(status)
                for k, v in headers.items():
                    self.send_header(k, v)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def authorize(self, q):
                code = base64.urlsafe_b64encode(os.urandom(18)).decode()
                cap.codes[code] = {"challenge": q.get("code_challenge"), "method": q.get("code_challenge_method"), "redirect": q.get("redirect_uri"),
                                   "client": q.get("client_id"), "scope": q.get("scope")}
                loc = q["redirect_uri"] + "?" + urllib.parse.urlencode({"state": q["state"], "code": code})
                self.send_response(302)
                self.send_header("Location", loc)
                self.end_headers()

            def token(self, form):
                def answer(status, body):
                    data = json.dumps(body).encode()
                    self.send_response(status)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                if form.get("client_secret") != "relay-client-secret":
                    return answer(401, {"error": "invalid_client"})
                if form.get("grant_type") == "authorization_code":
                    c = cap.codes.pop(form.get("code", ""), None)
                    if c is None or c["redirect"] != form.get("redirect_uri") or c["method"] != "S256":
                        return answer(400, {"error": "invalid_grant"})
                    want = base64.urlsafe_b64encode(hashlib.sha256(form.get("code_verifier", "").encode()).digest()).decode().rstrip("=")
                    if want != c["challenge"]:
                        return answer(400, {"error": "invalid_grant", "error_description": "PKCE verifier does not match"})
                    refresh = "rt-" + os.urandom(8).hex()
                    access = "at-" + os.urandom(8).hex()
                    cap.tokens[refresh] = access
                    claims = base64.urlsafe_b64encode(json.dumps({"email": "owner@hotel.example"}).encode()).decode().rstrip("=")
                    return answer(200, {"access_token": access, "refresh_token": refresh, "expires_in": 3600, "id_token": f"e30.{claims}.sig"})
                if form.get("grant_type") == "refresh_token":
                    old = form.get("refresh_token", "")
                    if old not in cap.tokens:
                        return answer(400, {"error": "invalid_grant"})
                    access = "at-" + os.urandom(8).hex()
                    body = {"access_token": access, "expires_in": 3600}
                    if cap.refresh_rotates:
                        new = "rt-" + os.urandom(8).hex()
                        del cap.tokens[old]
                        cap.tokens[new] = access
                        body["refresh_token"] = new
                    else:
                        cap.tokens[old] = access
                    return answer(200, body)
                return answer(400, {"error": "unsupported_grant_type"})

            def do_GET(self):
                self.handle_one("GET")

            def do_POST(self):
                self.handle_one("POST")

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def live_access(self):
        return set(self.tokens.values())

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


# ── SMTP ────────────────────────────────────────────────────────────────────────

class SmtpCapture:
    """mode: "starttls", "tls" (implicit) or "plain" (no STARTTLS, and AUTH offered in the clear: the
    server a relay must refuse to give a password to)."""

    def __init__(self, cert, key, mode="starttls", username="hotel", password="pw"):
        self.messages, self.auths, self.connections = [], [], 0
        self.mode, self.username, self.password = mode, username, password
        self.rcpt_reply = (250, "OK")
        ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        ctx.load_cert_chain(cert, key)
        cap = self

        class H(socketserver.StreamRequestHandler):
            def handle(self):
                try:
                    self.talk()
                except (ssl.SSLError, OSError):
                    pass                     # a client that refused the certificate, or hung up: nothing captured

            def talk(self):
                cap.connections += 1
                tls = False
                conn = self.connection
                if cap.mode == "tls":
                    conn = ctx.wrap_socket(conn, server_side=True)
                    tls = True
                f = conn.makefile("rwb")
                say = lambda line: (f.write(line.encode() + b"\r\n"), f.flush())
                say("220 capture ready")
                mail_from, rcpts, authed = None, [], False
                while True:
                    raw = f.readline()
                    if not raw:
                        return
                    line = raw.decode("utf-8", "replace").rstrip("\r\n")
                    verb = line.split(" ", 1)[0].upper()
                    if verb in ("EHLO", "HELO"):
                        exts = ["250-capture"]
                        if cap.mode == "starttls" and not tls:
                            exts.append("250-STARTTLS")
                        if tls or cap.mode == "plain":     # "plain" is a careless server: AUTH offered with no TLS at all
                            exts.append("250-AUTH PLAIN LOGIN")
                        exts.append("250 8BITMIME")
                        for e in exts:
                            f.write(e.encode() + b"\r\n")
                        f.flush()
                    elif verb == "STARTTLS" and cap.mode == "starttls" and not tls:
                        say("220 go ahead")
                        f.close()
                        conn = ctx.wrap_socket(conn, server_side=True)
                        f = conn.makefile("rwb")
                        say = lambda line, f=f: (f.write(line.encode() + b"\r\n"), f.flush())
                        tls = True
                    elif verb == "AUTH":
                        parts = line.split(" ")
                        if parts[1].upper() == "PLAIN":
                            blob = parts[2] if len(parts) > 2 else None
                            if blob is None:
                                say("334 ")
                                blob = f.readline().decode().strip()
                            _, user, pw = base64.b64decode(blob).decode().split("\x00")
                        else:
                            say("334 VXNlcm5hbWU6")
                            user = base64.b64decode(f.readline().strip()).decode()
                            say("334 UGFzc3dvcmQ6")
                            pw = base64.b64decode(f.readline().strip()).decode()
                        cap.auths.append({"tls": tls, "user": user})
                        if user == cap.username and pw == cap.password:
                            authed = True
                            say("235 ok")
                        else:
                            say("535 5.7.8 bad credentials")
                    elif verb == "MAIL":
                        if not authed:
                            say("530 auth first")
                            continue
                        mail_from, rcpts = line[10:].strip("<>"), []
                        say("250 ok")
                    elif verb == "RCPT":
                        code, text = cap.rcpt_reply
                        if code == 250:
                            rcpts.append(line[8:].strip("<>"))
                        say(f"{code} {text}")
                    elif verb == "DATA":
                        say("354 end with .")
                        data = bytearray()
                        while True:
                            l = f.readline()
                            if l in (b".\r\n", b".\n", b""):
                                break
                            data += l[1:] if l.startswith(b"..") else l
                        cap.messages.append({"from": mail_from, "to": rcpts, "data": bytes(data), "tls": tls})
                        say("250 queued")
                    elif verb == "QUIT":
                        say("221 bye")
                        return
                    elif verb in ("RSET", "NOOP"):
                        say("250 ok")
                    else:
                        say("502 no")

        class S(socketserver.ThreadingMixIn, socketserver.TCPServer):
            allow_reuse_address = True
            daemon_threads = True

        self.server = S(("127.0.0.1", 0), H)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


# ── DNS ─────────────────────────────────────────────────────────────────────────

class DnsServer:
    """records: {(name, "TXT"|"CNAME"): [values]}"""

    def __init__(self, records):
        self.records = records
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", 0))
        self.port = self.sock.getsockname()[1]
        self.running = True
        threading.Thread(target=self.loop, daemon=True).start()

    def loop(self):
        while self.running:
            try:
                data, peer = self.sock.recvfrom(4096)
            except OSError:
                return
            q = dns.message.from_wire(data)
            r = dns.message.make_response(q)
            question = q.question[0]
            name = str(question.name).rstrip(".").lower()
            kind = dns.rdatatype.to_text(question.rdtype)
            values = self.records.get((name, kind), [])
            known = any(n == name for n, _ in self.records)
            if values:
                if kind == "TXT":
                    texts = ['"' + v.replace('"', '\\"') + '"' for v in values]
                    r.answer.append(dns.rrset.from_text(question.name, 300, "IN", "TXT", *texts))
                else:
                    r.answer.append(dns.rrset.from_text(question.name, 300, "IN", kind, *[v + "." for v in values]))
            elif not known:
                r.set_rcode(dns.rcode.NXDOMAIN)
            self.sock.sendto(r.to_wire(), peer)

    def close(self):
        self.running = False
        self.sock.close()


import dns.rcode  # noqa: E402  (used above in the server loop)


# ── the contract, as its mailer sees it ─────────────────────────────────────────

class FakeChain:
    def __init__(self, authorised="", on=True, today=20_000):
        self.setup_row = {"on": on, "authorised": authorised or "00" * 32, "tested": "00" * 32, "mailKey": "", "today": today,
                          "nameEn": "Nile Garden Hotel", "nameAr": "فندق حديقة النيل", "currency": "EGP", "minorUnits": 2,
                          "checkInText": "14:00", "checkOutText": "12:00", "atBlock": 1}
        self.rows = {}        # outboxId -> row (with "state", "notBefore")
        self.calls = []
        self.mailer = True
        self.lose_next_outcome = 0

    def add(self, oid, kind, sealed, lang="en", not_before=0, **extra):
        base = {"outboxId": oid, "kind": kind, "attempts": 0, "sealed": sealed, "lang": lang, "bookingId": oid, "ref": f"LX-{oid:06d}", "status": "confirmed",
                "guestName": "Hesham Adel" if lang == "en" else "بلال حسن", "roomEn": "Garden room", "roomAr": "غرفة الحديقة", "planEn": "Flexible",
                "planAr": "مرن", "arrival": 20_010, "departure": 20_013, "rooms": 1, "adults": 2, "children": 0, "roomTotal": 450_000, "extras": 0,
                "taxes": 63_000, "charged": 513_000, "credited": 0, "paid": 513_000, "outstanding": 0, "penalty": 0, "cancelDeadline": 20_008,
                "refundable": True, "atBlock": 1}
        base.update(extra)
        self.rows[oid] = {**base, "state": "due", "notBefore": not_before}

    def due_now(self):
        t = self.setup_row["today"]
        return sorted((r for r in self.rows.values() if r["state"] == "due" and r["notBefore"] <= t), key=lambda r: (r["notBefore"], r["outboxId"]))

    def setup(self):
        self.calls.append(("setup",))
        return dict(self.setup_row) if self.mailer else None

    def due(self, cursor, limit):
        self.calls.append(("due", cursor, limit))
        if not self.mailer or not self.setup_row["on"]:
            return []
        rows = self.due_now()
        if cursor:
            rows = [r for r in rows if r["outboxId"] > int(cursor)]
        page = rows[:limit]
        more = len(rows) > limit
        return [{**{k: v for k, v in r.items() if k not in ("state", "notBefore")}, "next": str(page[-1]["outboxId"]) if more else ""} for r in page]

    def record_outcome(self, oid, sent, failure):
        self.calls.append(("outcome", oid, sent, failure))
        if self.lose_next_outcome:
            self.lose_next_outcome -= 1
            raise ConnectionError("the reply was lost")
        r = self.rows.get(oid)
        if not self.mailer:
            return {"ok": False, "kind": "unauthorised"}
        if r is None or r["state"] != "due" or r["notBefore"] > self.setup_row["today"] or not self.setup_row["on"]:
            return {"ok": False, "kind": "conflict"}
        if sent != (failure == ""):
            return {"ok": False, "kind": "invalid"}
        r["attempts"] += 1
        if sent:
            r["state"] = "sent"
        elif r["attempts"] >= 3:
            r["state"] = "failed"
        r["failure"] = failure
        return {"ok": True, "kind": "", "a": oid, "b": r["attempts"]}

    def record_test(self, digest):
        self.calls.append(("test", digest))
        if digest != self.setup_row["authorised"]:
            return {"ok": False, "kind": "conflict"}
        self.setup_row["tested"] = digest
        return {"ok": True, "kind": ""}
