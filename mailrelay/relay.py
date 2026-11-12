"""The shared Thebes mail relay: it pulls each hotel's outbox, sends each message through the hotel's own
email account, and records what became of it on the hotel's chain.

The contract makes no outbound request: the relay asks (`mailDue_u`, signed with the hotel's mailer key),
and answers (`recordMailOutcome`). What the relay holds:

  - one master secret, from which every hotel's keys are derived (keys.py);
  - each hotel's email credential, encrypted, under the digest the owner authorised on the chain; only that
    one is ever used, so a credential posted by anyone else is inert;
  - one row per message sent (store.py), so a message is sent at most once: marked `sending` before the
    provider is called, and a pass that finds a message still `sending` (the relay stopped mid-call)
    records it as sent rather than risk a second copy.

Retries: a failure the chain recorded is tried again after 5 minutes, then after 30; the chain marks a
message failed after its third attempt. Failures leave as codes only, never the provider's words.

The HTTP API is for the owner's console: the hotel's public keys, a sealed credential to keep, a sign-in
with Google or Microsoft, the DNS check and the test email. None of it needs an account: what an owner
authorises is decided on the chain, where only the owner can act.

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import json, logging, re, secrets, threading, time, urllib.parse
from collections import defaultdict, deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import dnscheck, keys as K, messages, oauth, providers
from .chainclient import ChainClient, Refused
from .providers.base import Outcome

log = logging.getLogger("mailrelay")
BACKOFF = {1: 300, 2: 1800}      # seconds after a recorded failure, by the attempts the chain counts
PAGE, MAX_PAGES = 50, 40
MAX_BODY = 16 * 1024


class Limit:
    """At most `n` requests per `window` seconds for one key (a client address and a route)."""

    def __init__(self, n, window, clock=time.time):
        self.n, self.window, self.clock, self.seen, self.lock = n, window, clock, defaultdict(deque), threading.Lock()

    def ok(self, key):
        now = self.clock()
        with self.lock:
            q = self.seen[key]
            while q and q[0] <= now - self.window:
                q.popleft()
            if len(q) >= self.n:
                return False
            q.append(now)
            return True


class Refusal(Exception):
    def __init__(self, status, why):
        super().__init__(why)
        self.status, self.why = status, why


def contract_id(text):
    if not re.fullmatch(r"[0-9]{1,20}", str(text)) or not 0 < int(text) < 1 << 64:
        raise Refusal(400, "not a contract id")
    return int(text)


class Relay:
    def __init__(self, master, store, net, chain_for=None, chain_base="", public_url="", return_origins=(), clock=time.time, dns_resolver=None):
        self.master, self.store, self.net, self.clock = master, store, net, clock
        self.public_url = public_url.rstrip("/")
        self.return_origins = {o.rstrip("/") for o in return_origins}
        self.dns_resolver = dns_resolver
        self._chains, self._lock = {}, threading.Lock()
        self._chain_for = chain_for or (lambda cid: ChainClient(chain_base, cid, self.keys(cid).mailer))
        self.tests = Limit(5, 3600, clock)        # test emails per hotel per hour
        self.posts = Limit(20, 3600, clock)       # credentials and sign-ins started per hotel per hour

    def keys(self, cid):
        return K.Keys(self.master, cid)

    def chain(self, cid):
        with self._lock:
            if cid not in self._chains:
                self._chains[cid] = self._chain_for(cid)
            return self._chains[cid]

    # ── the pull ──────────────────────────────────────────────────────────────
    def pass_once(self):
        """One pass over every hotel with a credential on file."""
        report = []
        for cid in self.store.contracts():
            try:
                report.append(self.run_hotel(cid))
            except (ConnectionError, Refused) as e:
                log.warning("hotel %s: the chain did not answer (%s)", cid, type(e).__name__)
                report.append({"hotel": cid, "state": "chainUnreachable"})
        return report

    def run_hotel(self, cid):
        chain = self.chain(cid)
        setup = chain.setup()
        if setup is None:
            return {"hotel": cid, "state": "notMailer"}
        self.store.set_authorised(cid, setup["authorised"])
        if not setup["on"]:
            return {"hotel": cid, "state": "off"}
        credential = self.store.credential(cid, setup["authorised"])
        if credential is None:
            return {"hotel": cid, "state": "noCredential"}
        before = json.dumps(credential, sort_keys=True)
        out = {"hotel": cid, "state": "on", "sent": 0, "failed": 0, "recorded": 0, "waiting": 0}
        cursor, keys = "", self.keys(cid)
        for _ in range(MAX_PAGES):
            rows = chain.due(cursor, PAGE)
            for row in rows:
                self.one(chain, cid, row, credential, setup, keys, out)
            cursor = rows[-1]["next"] if rows else ""
            if not cursor:
                break
        if json.dumps(credential, sort_keys=True) != before:      # a refreshed or rotated OAuth token
            self.store.update_credential(cid, setup["authorised"], credential)
        return out

    def one(self, chain, cid, row, credential, setup, keys, out):
        oid, attempts = int(row["outboxId"]), int(row["attempts"])
        rec = self.store.send_of(cid, oid)
        if rec is not None:
            if rec["state"] in ("sent", "sending"):
                # sent, or the relay stopped while the provider was being called: never a second copy
                self.record(chain, cid, oid, True, "", out)
                return
            if rec["state"] == "failed" and rec["attempts"] > attempts:
                self.record(chain, cid, oid, False, rec["failure"], out)     # the chain has not heard yet
                return
            if rec["state"] == "failed" and self.clock() < rec["last"] + BACKOFF.get(attempts, 0):
                out["waiting"] += 1
                return
        attempt = attempts + 1
        self.store.mark(cid, oid, "sending", attempt, now=self.clock())
        outcome = self.send(cid, row, credential, setup, keys)
        self.store.mark(cid, oid, "sent" if outcome.ok else "failed", attempt, outcome.provider_id, outcome.failure, now=self.clock())
        out["sent" if outcome.ok else "failed"] += 1
        self.record(chain, cid, oid, outcome.ok, outcome.failure, out)

    def send(self, cid, row, credential, setup, keys):
        try:
            to = keys.open_address(row["sealed"]).strip()
        except Exception as e:      # any envelope that does not open, however it fails, is unreadable
            log.info("hotel %s message %s: the address does not open (%s)", cid, row["outboxId"], type(e).__name__)
            return Outcome.failed("unreadable")
        if not providers.plain_address(to):
            return Outcome.failed("unreadable")
        return deliver(credential, messages.render(row, setup, to, cid), self.net)

    def record(self, chain, cid, oid, sent, failure, out):
        try:
            reply = chain.record_outcome(oid, sent, "" if sent else failure)
        except ConnectionError:
            return            # its fate is not known: the next pass records it
        except Refused as e:
            log.warning("hotel %s message %s: the chain refused the outcome (%s)", cid, oid, e)
            return
        if not reply.get("ok"):
            log.info("hotel %s message %s: outcome refused, %s", cid, oid, reply.get("kind"))
        self.store.mark_recorded(cid, oid)
        out["recorded"] += 1

    # ── the console's requests ────────────────────────────────────────────────
    def hotel_setup(self, cid):
        """The hotel's state as its contract tells its mailer, or a refusal when this relay is not it."""
        try:
            setup = self.chain(cid).setup()
        except (ConnectionError, Refused):
            raise Refusal(503, "the hotel's chain did not answer; try again") from None
        if setup is None:
            raise Refusal(409, "connect this relay to the hotel first (Guest email, step 1)")
        return setup

    def accept_credential(self, cid, envelope):
        if not isinstance(envelope, str) or not envelope.startswith("lxc1.") or len(envelope) > 8192:
            raise Refusal(400, "not a sealed credential")
        if not self.posts.ok(("post", cid)):
            raise Refusal(429, "too many accounts sent for this hotel in the last hour")
        try:
            credential = json.loads(self.keys(cid).open_credential(envelope))
        except Exception:
            raise Refusal(400, "the credential does not open with this hotel's key") from None
        why = providers.check(credential)
        if why:
            raise Refusal(400, why)
        self.hotel_setup(cid)
        digest = K.digest_hex(envelope)
        self.store.put_credential(cid, digest, credential)
        return {"digest": digest, "provider": credential["provider"], "from": credential["from"]}

    def account(self, cid):
        """The account the chain names for this hotel, as the console shows it: the provider and the sending address,
        both of which the hotel's guests see on every email; never a field of the credential beyond those two."""
        digest = self.hotel_setup(cid)["authorised"]
        if not digest or digest == "00" * 32:   # the mailer's view names no account as the zero digest
            return {"digest": "", "onFile": False}
        credential = self.store.credential(cid, digest)
        if credential is None:
            return {"digest": digest, "onFile": False}
        return {"digest": digest, "onFile": True, "provider": credential["provider"], "from": credential["from"]}

    def test(self, cid, digest):
        if not re.fullmatch(r"[0-9a-f]{64}", str(digest)):
            raise Refusal(400, "not a digest")
        if not self.tests.ok(("test", cid)):
            raise Refusal(429, "five test emails an hour at most")
        setup = self.hotel_setup(cid)
        if setup["authorised"] != digest:
            raise Refusal(409, "authorise this account on the chain first (Guest email, step 3)")
        credential = self.store.credential(cid, digest)
        if credential is None:
            raise Refusal(404, "this account is not on file at the relay: connect it again")
        message = messages.test_message(credential["testTo"], setup, credential.get("lang", "en"), cid)
        outcome = deliver(credential, message, self.net)
        self.store.update_credential(cid, digest, credential)
        if not outcome.ok:
            return {"ok": False, "failure": outcome.failure}
        try:
            reply = self.chain(cid).record_test(digest)
        except (ConnectionError, Refused):
            return {"ok": True, "recorded": False, "why": "the email was sent; the chain did not take the record: test again"}
        return {"ok": True, "recorded": bool(reply.get("ok")), "kind": reply.get("kind", "")}

    def oauth_start(self, cid, provider, body):
        if provider not in providers.OAUTH or provider not in self.net.oauth:
            raise Refusal(400, "this relay has no sign-in for that provider")
        ret = str(body.get("returnTo", ""))
        u = urllib.parse.urlparse(ret)
        if f"{u.scheme}://{u.netloc}" not in self.return_origins or u.scheme not in ("https", "http") or u.fragment:
            raise Refusal(400, "the console's address is not one this relay returns to")
        fields = {"provider": provider, "from": str(body.get("from", "")).strip(), "fromName": str(body.get("fromName", "")).strip(),
                  "testTo": str(body.get("testTo", "")).strip(), "lang": "ar" if body.get("lang") == "ar" else "en"}
        if not providers.plain_address(fields["from"]) or not providers.plain_address(fields["testTo"]):
            raise Refusal(400, "an address is not a plain email address")
        if any(c in fields["fromName"] for c in "\r\n<>\"") or len(fields["fromName"]) > 120:
            raise Refusal(400, "the sender's name holds a character an email header cannot")
        if not self.posts.ok(("post", cid)):
            raise Refusal(429, "too many accounts sent for this hotel in the last hour")
        self.hotel_setup(cid)
        state = secrets.token_urlsafe(32)
        verifier, challenge = oauth.pkce()
        self.store.put_oauth(state, {"contract": cid, "verifier": verifier, "returnTo": ret, "fields": fields})
        return {"url": oauth.authorize_url(provider, self.net, self.callback_url(), state, challenge, fields["from"])}

    def callback_url(self):
        return self.public_url + "/v1/oauth/callback"

    def oauth_callback(self, query):
        rec = self.store.take_oauth(query.get("state", ""))
        if rec is None:
            raise Refusal(400, "this sign-in has expired or was already used: start again from the console")
        ret = rec["returnTo"]
        if query.get("error") or not query.get("code"):
            return ret + "#mailError=signIn"
        fields = rec["fields"]
        got = oauth.exchange(fields["provider"], self.net, query["code"], rec["verifier"], self.callback_url())
        if got is None:
            return ret + "#mailError=signIn"
        credential = {**fields, **got}
        digest = K.digest_hex("lxo1." + secrets.token_hex(32))
        self.store.put_credential(rec["contract"], digest, credential)
        return ret + "#" + urllib.parse.urlencode({"mailCredential": digest, "account": got.get("account", ""), "provider": fields["provider"]})

    def dns(self, query):
        r = self.dns_resolver or dnscheck.resolver()
        return dnscheck.check(query.get("domain", ""), query.get("provider", ""), query.get("selector", ""), r)


def deliver(credential, message, net):
    """One provider call, its failures folded to the outbox's codes."""
    provider = providers.ALL.get(credential.get("provider"))
    if provider is None:
        return Outcome.failed("signIn")
    try:
        return provider.send(credential, message, net)
    except (ConnectionError, TimeoutError, OSError):
        return Outcome.failed("unavailable")
    except (KeyError, ValueError, TypeError):
        return Outcome.failed("signIn")      # a credential missing what its provider needs


# ── HTTP ──────────────────────────────────────────────────────────────────────

def handler_for(relay, trust_proxy=False):
    reads = Limit(120, 60)
    dns_limit = Limit(30, 600)

    class Handler(BaseHTTPRequestHandler):
        server_version = "luxor-mail-relay"
        sys_version = ""

        def log_message(self, fmt, *args):        # the path only: a query can hold a sign-in code
            log.info("%s %s", self.command, self.path.split("?")[0])

        def client(self):
            if trust_proxy and self.headers.get("X-Forwarded-For"):
                return self.headers["X-Forwarded-For"].split(",")[-1].strip()
            return self.client_address[0]

        def cors(self):
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.send_header("Cache-Control", "no-store")

        def reply(self, status, body):
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.cors()
            self.end_headers()
            self.wfile.write(data)

        def do_OPTIONS(self):
            self.send_response(204)
            self.cors()
            self.end_headers()

        def body(self):
            n = int(self.headers.get("Content-Length") or 0)
            if n > MAX_BODY:
                raise Refusal(413, "too large")
            try:
                b = json.loads(self.rfile.read(n) or b"{}")
            except ValueError:
                raise Refusal(400, "not JSON") from None
            if not isinstance(b, dict):
                raise Refusal(400, "not a JSON object")
            return b

        def route(self, method):
            u = urllib.parse.urlparse(self.path)
            q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
            parts = [p for p in u.path.split("/") if p]
            if not reads.ok((self.client(), method)):
                raise Refusal(429, "too many requests")
            if method == "GET" and parts == ["v1", "health"]:
                return 200, {"ok": True}
            if method == "GET" and parts == ["v1", "providers"]:
                return 200, {"providers": [{"name": p.NAME, "label": p.LABEL, "fields": p.FIELDS, "oauth": p.NAME in providers.OAUTH,
                                            "available": p.NAME not in providers.OAUTH or p.NAME in relay.net.oauth} for p in providers.ALL.values()]}
            if method == "GET" and parts == ["v1", "dns"]:
                if not dns_limit.ok(self.client()):
                    raise Refusal(429, "too many DNS checks")
                return 200, relay.dns(q)
            if method == "GET" and parts == ["v1", "oauth", "callback"]:
                return 303, relay.oauth_callback(q)
            if len(parts) >= 4 and parts[:2] == ["v1", "hotels"]:
                cid = contract_id(parts[2])
                if method == "GET" and parts[3:] == ["key"]:
                    return 200, relay.keys(cid).public()
                if method == "GET" and parts[3:] == ["account"]:
                    return 200, relay.account(cid)
                if method == "POST" and parts[3:] == ["credential"]:
                    return 200, relay.accept_credential(cid, self.body().get("envelope"))
                if method == "POST" and parts[3:] == ["test"]:
                    return 200, relay.test(cid, self.body().get("digest", ""))
                if method == "POST" and len(parts) == 6 and parts[3] == "oauth" and parts[5] == "start":
                    return 200, relay.oauth_start(cid, parts[4], self.body())
            raise Refusal(404, "no such route")

        def serve(self, method):
            try:
                status, body = self.route(method)
            except Refusal as r:
                return self.reply(r.status, {"ok": False, "why": r.why})
            except Exception:
                log.exception("a request failed")
                return self.reply(500, {"ok": False, "why": "the relay could not do that"})
            if status == 303:
                self.send_response(303)
                self.send_header("Location", body)
                self.send_header("Cache-Control", "no-store")
                self.send_header("Referrer-Policy", "no-referrer")
                self.end_headers()
                return
            self.reply(status, body)

        def do_GET(self):
            self.serve("GET")

        def do_POST(self):
            self.serve("POST")

    return Handler


def serve(relay, host, port, poll_seconds=60, trust_proxy=False, stop=None):
    """The HTTP API in its own thread, and the pull every `poll_seconds` until `stop` is set."""
    httpd = ThreadingHTTPServer((host, port), handler_for(relay, trust_proxy))
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    stop = stop or threading.Event()
    try:
        while not stop.is_set():
            try:
                for r in relay.pass_once():
                    if r.get("state") == "on" and (r["sent"] or r["failed"]):
                        log.info("hotel %s: sent %s, failed %s, recorded %s", r["hotel"], r["sent"], r["failed"], r["recorded"])
            except Exception:
                log.exception("a pass failed")
            stop.wait(poll_seconds)
    finally:
        httpd.shutdown()
    return httpd
