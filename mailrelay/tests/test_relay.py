"""The mail relay against capture servers: every provider's request as the provider would receive it, the
SMTP server with TLS, a Google/Microsoft sign-in with PKCE, the DNS check, and the pull loop against a
contract that keeps the contract's rules (tests/servers.py FakeChain).

Run: python3 -m unittest mailrelay.tests.test_relay   (from the repository root)

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import base64, datetime, email, email.policy, hashlib, io, json, logging, os, tempfile, threading, unittest, urllib.error, urllib.parse, urllib.request

from mailrelay import dnscheck, keys as K, messages, oauth, providers
from mailrelay.providers import ses
from mailrelay.providers.base import Net
from mailrelay.relay import BACKOFF, Refusal, Relay, deliver, handler_for
from mailrelay.store import Store
from mailrelay.tests.servers import DnsServer, FakeChain, HttpCapture, SmtpCapture, make_cert

MASTER = bytes(range(32))
CID = 900000000001
GUEST_EN, GUEST_AR = "hesham.guest@mail.example", "bilal.guest@mail.example"
SECRET_WORDS = ["pw-very-secret", "SG.key-very-secret", "pm-key-very-secret", "re_key_very_secret", "mg-key-very-secret", "xkeysib-very-secret",
                "AKIAVERYSECRET", "ses/very/secret", GUEST_EN, GUEST_AR]


LOGS = io.StringIO()          # every test class's relay logs, read at the end by ZLogsTest
_h = logging.StreamHandler(LOGS)
_h.setLevel(logging.DEBUG)
logging.getLogger("mailrelay").addHandler(_h)
logging.getLogger("mailrelay").setLevel(logging.DEBUG)


class Clock:
    def __init__(self):
        self.t = 1_800_000_000.0

    def __call__(self):
        return self.t


def parse(raw):
    return email.message_from_bytes(raw, policy=email.policy.default)


class Base(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp(prefix="mailrelay-")
        cls.cert, cls.key = make_cert(cls.dir)
        cls.http = HttpCapture()

    @classmethod
    def tearDownClass(cls):
        cls.http.close()

    def net(self, **kw):
        ep = {name: self.http.url for name in ("sendgrid", "postmark", "resend", "mailgun", "brevo", "ses", "google.api", "microsoft.api")}
        ep.update({"google.auth": self.http.url + "/google/authorize", "google.token": self.http.url + "/google/token",
                   "microsoft.auth": self.http.url + "/microsoft/authorize", "microsoft.token": self.http.url + "/microsoft/token"})
        client = {"client_id": "relay-app", "client_secret": "relay-client-secret"}
        return Net(endpoints=ep, cafile=self.cert, allow_private=True, oauth={"google": client, "microsoft": client}, **kw)

    def message(self, to=GUEST_EN, lang="en"):
        return messages.Message(to=to, to_name="Hesham Adel", subject="Your booking", text="Hello", html="<p>Hello</p>", lang=lang,
                                message_id=f"<outbox-{CID}-7@luxor.mail>")


# ── keys ─────────────────────────────────────────────────────────────────────

class KeysTest(Base):
    def test_derived_per_hotel_and_stable(self):
        a, b, a2 = K.Keys(MASTER, CID).public(), K.Keys(MASTER, CID + 1).public(), K.Keys(MASTER, CID).public()
        self.assertEqual(a, a2)
        for f in ("mailer", "mailKey", "transportKey"):
            self.assertNotEqual(a[f], b[f])
        self.assertNotEqual(a["mailKey"], a["transportKey"])
        self.assertEqual(len(bytes.fromhex(a["mailKey"])), 65)

    def test_mailer_principal_matches_the_chain_client(self):
        import sys
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "tools"))
        import chain
        k = K.Keys(MASTER, CID)
        self.assertEqual(chain.Chain("http://127.0.0.1:1", CID, k.mailer_seed_hex()).principal, k.mailer_principal_hex())

    def test_seals_open_only_with_their_own_key(self):
        k = K.Keys(MASTER, CID)
        sealed = K.seal(GUEST_AR, k.public()["mailKey"])
        self.assertEqual(k.open_address(sealed), GUEST_AR)
        with self.assertRaises(Exception):
            K.Keys(MASTER, CID + 1).open_address(sealed)
        with self.assertRaises(Exception):
            k.open_credential(sealed)                                  # an address is not a credential
        cred = K.seal_credential(b'{"x":1}', k.public()["transportKey"])
        self.assertEqual(k.open_credential(cred), b'{"x":1}')
        with self.assertRaises(Exception):
            k.open_address(cred)

    def test_page_seal_matches(self):
        # the same envelope format as the page's own sealing (tools/chain.py seal)
        import sys
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "tools"))
        import chain
        k = K.Keys(MASTER, CID)
        self.assertEqual(k.open_address(chain.seal(GUEST_EN, k.public()["mailKey"])), GUEST_EN)

    def test_the_page_seals_what_the_relay_opens(self):
        # frontend/src/api/keys.ts itself, under Node: the envelopes and the digest must agree across languages
        import subprocess
        k = K.Keys(MASTER, CID).public()
        cred = json.dumps({"provider": "postmark", "from": "stay@hotel.example", "apiKey": "pm-key-very-secret"})
        out = subprocess.run(["node", "--experimental-strip-types", "--no-warnings", os.path.join(os.path.dirname(__file__), "browser_seal.mts"),
                              k["mailKey"], k["transportKey"], GUEST_AR, cred], capture_output=True, text=True, timeout=60)
        self.assertEqual(out.returncode, 0, out.stderr)
        got = json.loads(out.stdout)
        keys = K.Keys(MASTER, CID)
        self.assertEqual(keys.open_address(got["sealedAddress"]), GUEST_AR)
        self.assertEqual(keys.open_credential(got["sealedCredential"]).decode(), cred)
        self.assertEqual(K.digest_hex(got["sealedCredential"]), got["digest"])
        with self.assertRaises(Exception):
            keys.open_address(got["sealedCredential"])          # the two kinds never open as each other

    def test_at_rest_binds_the_record_name(self):
        r = K.AtRest(MASTER)
        blob = r.seal("credential/1/aa", b"secret")
        self.assertEqual(r.open("credential/1/aa", blob), b"secret")
        with self.assertRaises(Exception):
            r.open("credential/2/aa", blob)


# ── the API providers ────────────────────────────────────────────────────────

class ApiProvidersTest(Base):
    def send(self, credential, path, status=200, answer=None, headers=None):
        self.http.answers[path] = (status, answer or {}, headers or {})
        n = len(self.http.requests)
        out = deliver(credential, self.message(), self.net())
        return out, self.http.requests[n:]

    def test_sendgrid(self):
        c = {"provider": "sendgrid", "from": "stay@hotel.example", "fromName": "Nile Garden", "apiKey": "SG.key-very-secret"}
        out, reqs = self.send(c, "/v3/mail/send", 202, {}, {"X-Message-Id": "sg-1"})
        self.assertTrue(out.ok)
        self.assertEqual(out.provider_id, "sg-1")
        r = reqs[0]
        self.assertEqual(r["headers"]["authorization"], "Bearer SG.key-very-secret")
        b = json.loads(r["body"])
        self.assertEqual(b["personalizations"][0]["to"][0]["email"], GUEST_EN)
        self.assertEqual(b["from"]["email"], "stay@hotel.example")
        self.assertEqual(b["headers"]["X-Luxor-Message"], f"outbox-{CID}-7@luxor.mail")
        for status, code in ((401, "signIn"), (403, "signIn"), (400, "rejected"), (413, "rejected"), (429, "unavailable"), (500, "unavailable"), (503, "unavailable")):
            out, _ = self.send(c, "/v3/mail/send", status)
            self.assertEqual(out.failure, code, status)

    def test_postmark(self):
        c = {"provider": "postmark", "from": "stay@hotel.example", "fromName": "Nile Garden", "apiKey": "pm-key-very-secret"}
        out, reqs = self.send(c, "/email", 200, {"MessageID": "pm-1", "ErrorCode": 0})
        self.assertEqual((out.ok, out.provider_id), (True, "pm-1"))
        self.assertEqual(reqs[0]["headers"]["x-postmark-server-token"], "pm-key-very-secret")
        self.assertEqual(json.loads(reqs[0]["body"])["To"], GUEST_EN)
        out, _ = self.send(c, "/email", 422, {"ErrorCode": 10, "Message": "Bad or missing Server API token"})
        self.assertEqual(out.failure, "signIn")
        out, _ = self.send(c, "/email", 422, {"ErrorCode": 300, "Message": "Invalid email request"})
        self.assertEqual(out.failure, "rejected")

    def test_resend_sends_its_idempotency_key(self):
        c = {"provider": "resend", "from": "stay@hotel.example", "fromName": "", "apiKey": "re_key_very_secret"}
        out, reqs = self.send(c, "/emails", 200, {"id": "rs-1"})
        self.assertEqual((out.ok, out.provider_id), (True, "rs-1"))
        self.assertEqual(reqs[0]["headers"]["idempotency-key"], f"outbox-{CID}-7@luxor.mail")
        self.assertEqual(reqs[0]["headers"]["authorization"], "Bearer re_key_very_secret")

    def test_mailgun(self):
        c = {"provider": "mailgun", "from": "stay@hotel.example", "fromName": "Nile Garden", "apiKey": "mg-key-very-secret", "domain": "mg.hotel.example"}
        out, reqs = self.send(c, "/v3/mg.hotel.example/messages", 200, {"id": "<mg-1>"})
        self.assertTrue(out.ok)
        self.assertEqual(reqs[0]["headers"]["authorization"], "Basic " + base64.b64encode(b"api:mg-key-very-secret").decode())
        form = dict(urllib.parse.parse_qsl(reqs[0]["body"].decode()))
        self.assertEqual(form["to"], GUEST_EN)
        self.assertEqual(form["h:Reply-To"], "Nile Garden <stay@hotel.example>")
        bad = dict(c, domain="mg.hotel.example/../../v4")
        self.assertEqual(deliver(bad, self.message(), self.net()).failure, "rejected")

    def test_brevo(self):
        c = {"provider": "brevo", "from": "stay@hotel.example", "fromName": "Nile Garden", "apiKey": "xkeysib-very-secret"}
        out, reqs = self.send(c, "/v3/smtp/email", 201, {"messageId": "<br-1>"})
        self.assertEqual((out.ok, out.provider_id), (True, "<br-1>"))
        self.assertEqual(reqs[0]["headers"]["api-key"], "xkeysib-very-secret")

    def test_ses_request_is_signed(self):
        c = {"provider": "ses", "from": "stay@hotel.example", "fromName": "", "accessKeyId": "AKIAVERYSECRET", "secretAccessKey": "ses/very/secret", "region": "eu-west-1"}
        out, reqs = self.send(c, "/v2/email/outbound-emails", 200, {"MessageId": "ses-1"})
        self.assertEqual((out.ok, out.provider_id), (True, "ses-1"))
        auth = reqs[0]["headers"]["authorization"]
        self.assertTrue(auth.startswith("AWS4-HMAC-SHA256 Credential=AKIAVERYSECRET/"))
        self.assertIn("/eu-west-1/ses/aws4_request", auth)
        self.assertNotIn("ses/very/secret", auth)
        self.assertEqual(deliver(dict(c, region="eu-west-1.evil.example/"), self.message(), self.net()).failure, "signIn")

    def test_sigv4_matches_the_aws_worked_example(self):
        # AWS General Reference, "Signature Version 4 signing process", the IAM ListUsers example
        h = ses.signed_headers("GET", "https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08", b"", "AKIDEXAMPLE",
                               "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", "us-east-1",
                               now=datetime.datetime(2015, 8, 30, 12, 36, 0, tzinfo=datetime.timezone.utc), service="iam",
                               content_type="application/x-www-form-urlencoded; charset=utf-8")
        self.assertTrue(h["Authorization"].endswith("Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7"), h["Authorization"])

    def test_plain_http_refused_off_loopback(self):
        net = Net(endpoints={"sendgrid": "http://198.51.100.7"})
        c = {"provider": "sendgrid", "from": "stay@hotel.example", "fromName": "", "apiKey": "SG.key-very-secret"}
        self.assertEqual(deliver(c, self.message(), net).failure, "signIn")   # refused before any connection: a ValueError

    def test_unreachable_is_unavailable(self):
        net = Net(endpoints={"sendgrid": "http://127.0.0.1:9"})
        c = {"provider": "sendgrid", "from": "stay@hotel.example", "fromName": "", "apiKey": "SG.key-very-secret"}
        self.assertEqual(deliver(c, self.message(), net).failure, "unavailable")


# ── SMTP with TLS ────────────────────────────────────────────────────────────

class SmtpTest(Base):
    def cred(self, port, **kw):
        c = {"provider": "smtp", "from": "stay@hotel.example", "fromName": "Nile Garden", "host": "localhost", "port": port, "username": "hotel",
             "password": "pw-very-secret"}
        c.update(kw)
        return c

    def test_starttls(self):
        s = SmtpCapture(self.cert, self.key, "starttls", password="pw-very-secret")
        try:
            out = deliver(self.cred(587), self.message(GUEST_AR, "ar"), self.net(port_map={587: s.port}))
            self.assertTrue(out.ok, out)
            self.assertEqual(s.auths, [{"tls": True, "user": "hotel"}])
            m = s.messages[0]
            self.assertEqual((m["from"], m["to"], m["tls"]), ("stay@hotel.example", [GUEST_AR], True))
            p = parse(m["data"])
            self.assertEqual(p["Message-ID"], f"<outbox-{CID}-7@luxor.mail>")
            self.assertEqual(p["Reply-To"], "Nile Garden <stay@hotel.example>")
            self.assertEqual(p["Auto-Submitted"], "auto-generated")
        finally:
            s.close()

    def test_implicit_tls(self):
        s = SmtpCapture(self.cert, self.key, "tls", password="pw-very-secret")
        try:
            out = deliver(self.cred(465), self.message(), self.net(port_map={465: s.port}))
            self.assertTrue(out.ok, out)
            self.assertTrue(s.auths[0]["tls"])
        finally:
            s.close()

    def test_no_starttls_never_sends_the_password(self):
        s = SmtpCapture(self.cert, self.key, "plain", password="pw-very-secret")
        try:
            out = deliver(self.cred(587), self.message(), self.net(port_map={587: s.port}))
            self.assertEqual(out.failure, "signIn")
            self.assertEqual(s.auths, [])
            self.assertEqual(s.messages, [])
        finally:
            s.close()

    def test_certificate_checked(self):
        s = SmtpCapture(self.cert, self.key, "starttls", password="pw-very-secret")
        try:
            net = Net(allow_private=True, port_map={587: s.port})          # the system's roots: the capture's own certificate is not among them
            self.assertEqual(deliver(self.cred(587), self.message(), net).failure, "unavailable")
            self.assertEqual(s.auths, [])
        finally:
            s.close()

    def test_refusals(self):
        s = SmtpCapture(self.cert, self.key, "starttls", password="pw-very-secret")
        try:
            net = self.net(port_map={587: s.port})
            self.assertEqual(deliver(self.cred(587, password="wrong"), self.message(), net).failure, "signIn")
            s.rcpt_reply = (550, "5.1.1 no such user")
            self.assertEqual(deliver(self.cred(587), self.message(), net).failure, "rejected")
            s.rcpt_reply = (451, "4.3.0 try later")
            self.assertEqual(deliver(self.cred(587), self.message(), net).failure, "unavailable")
            self.assertEqual(s.messages, [])
        finally:
            s.close()

    def test_private_host_and_odd_port_refused_before_connecting(self):
        s = SmtpCapture(self.cert, self.key, "starttls", password="pw-very-secret")
        try:
            net = Net(cafile=self.cert, port_map={587: s.port})             # allow_private off, as in service
            self.assertEqual(deliver(self.cred(587), self.message(), net).failure, "signIn")
            self.assertEqual(deliver(self.cred(22), self.message(), self.net()).failure, "signIn")
            self.assertEqual(s.connections, 0)
        finally:
            s.close()


# ── sign-in with Google and Microsoft ────────────────────────────────────────

def follow(url):
    """The browser: open the provider's authorise page and return where it redirects."""
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **k):
            return None
    try:
        urllib.request.build_opener(NoRedirect).open(url)
    except urllib.error.HTTPError as e:
        return e.headers["Location"]
    raise AssertionError("no redirect")


class OAuthTest(Base):
    def relay(self, chain=None):
        self.chain = chain or FakeChain()
        store = Store(":memory:", K.AtRest(MASTER))
        return Relay(MASTER, store, self.net(), chain_for=lambda cid: self.chain, public_url="https://relay.example", return_origins=["https://hotel.example"])

    def sign_in(self, relay, provider):
        start = relay.oauth_start(CID, provider, {"from": "stay@hotel.example", "fromName": "Nile Garden", "testTo": "owner@hotel.example",
                                                  "returnTo": "https://hotel.example/console/email"})
        q = dict(urllib.parse.parse_qsl(urllib.parse.urlparse(start["url"]).query))
        self.assertEqual(q["code_challenge_method"], "S256")
        self.assertEqual(q["redirect_uri"], "https://relay.example/v1/oauth/callback")
        back = follow(start["url"])
        cb = dict(urllib.parse.parse_qsl(urllib.parse.urlparse(back).query))
        return relay.oauth_callback(cb), q

    def test_google_sign_in_then_send(self):
        relay = self.relay()
        dest, q = self.sign_in(relay, "google")
        self.assertIn("gmail.send", q["scope"])
        self.assertTrue(dest.startswith("https://hotel.example/console/email#"))
        frag = dict(urllib.parse.parse_qsl(dest.split("#", 1)[1]))
        self.assertEqual(frag["account"], "owner@hotel.example")
        cred = relay.store.credential(CID, frag["mailCredential"])
        self.assertTrue(cred["refreshToken"].startswith("rt-"))
        self.assertNotIn(cred["refreshToken"], dest)
        self.http.answers["/gmail/v1/users/me/messages/send"] = (200, {"id": "gm-1"}, {})
        n = len(self.http.requests)
        out = deliver(cred, self.message(), self.net())
        self.assertEqual((out.ok, out.provider_id), (True, "gm-1"))
        r = self.http.requests[n]
        self.assertEqual(r["headers"]["authorization"], "Bearer " + cred["accessToken"])
        raw = base64.urlsafe_b64decode(json.loads(r["body"])["raw"] + "==")
        self.assertEqual(parse(raw)["To"], f"Hesham Adel <{GUEST_EN}>")

    def test_a_state_is_used_once_and_a_wrong_verifier_refused(self):
        relay = self.relay()
        start = relay.oauth_start(CID, "google", {"from": "stay@hotel.example", "testTo": "owner@hotel.example", "returnTo": "https://hotel.example/c"})
        cb = dict(urllib.parse.parse_qsl(urllib.parse.urlparse(follow(start["url"])).query))
        rec = relay.store.take_oauth(cb["state"])
        relay.store.put_oauth(cb["state"], {**rec, "verifier": "not-the-verifier"})
        self.assertEqual(relay.oauth_callback(cb), "https://hotel.example/c#mailError=signIn")
        with self.assertRaises(Refusal):
            relay.oauth_callback(cb)                                        # the state was taken

    def test_return_origin_and_mailer_checked(self):
        relay = self.relay()
        with self.assertRaises(Refusal):
            relay.oauth_start(CID, "google", {"from": "a@b.example", "testTo": "a@b.example", "returnTo": "https://elsewhere.example/c"})
        self.chain.mailer = False
        with self.assertRaises(Refusal) as r:
            relay.oauth_start(CID, "google", {"from": "a@b.example", "testTo": "a@b.example", "returnTo": "https://hotel.example/c"})
        self.assertEqual(r.exception.status, 409)

    def test_microsoft_refresh_rotates_and_revocation_is_sign_in(self):
        relay = self.relay()
        dest, q = self.sign_in(relay, "microsoft")
        self.assertIn("Mail.Send", q["scope"])
        self.assertIn("offline_access", q["scope"])
        digest = dict(urllib.parse.parse_qsl(dest.split("#", 1)[1]))["mailCredential"]
        cred = relay.store.credential(CID, digest)
        cred["expires"] = 0                                                  # the access token has run out
        self.http.refresh_rotates = True
        self.http.answers["/v1.0/me/sendMail"] = (202, {}, {})
        old = cred["refreshToken"]
        n = len(self.http.requests)
        out = deliver(cred, self.message(), self.net())
        self.assertTrue(out.ok)
        self.assertNotEqual(cred["refreshToken"], old)                       # the rotated token kept, in place
        sent = [r for r in self.http.requests[n:] if r["path"] == "/v1.0/me/sendMail"][0]
        body = json.loads(sent["body"])
        self.assertEqual(body["message"]["toRecipients"][0]["emailAddress"]["address"], GUEST_EN)
        self.assertEqual(body["message"]["replyTo"][0]["emailAddress"]["address"], "stay@hotel.example")
        self.http.tokens.clear()                                             # the owner revoked the grant
        cred["expires"] = 0
        self.assertEqual(deliver(cred, self.message(), self.net()).failure, "signIn")
        self.http.refresh_rotates = False


# ── DNS ──────────────────────────────────────────────────────────────────────

class DnsTest(Base):
    def test_records(self):
        d = DnsServer({("hotel.example", "TXT"): ["v=spf1 include:_spf.google.com ~all", "google-site-verification=x"],
                       ("google._domainkey.hotel.example", "TXT"): ["v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAx"],
                       ("_dmarc.hotel.example", "TXT"): ["v=DMARC1; p=quarantine; rua=mailto:d@hotel.example"],
                       ("two.example", "TXT"): ["v=spf1 include:sendgrid.net ~all", "v=spf1 include:mailgun.org ~all"],
                       ("other.example", "TXT"): ["v=spf1 include:mailgun.org -all"],
                       ("s1._domainkey.other.example", "CNAME"): ["s1.domainkey.u1.wl.sendgrid.net"],
                       ("k1._domainkey.mg.hotel.example", "TXT"): ["k=rsa; p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQC1"]})
        try:
            r = dnscheck.resolver("127.0.0.1", d.port)
            ok = dnscheck.check("hotel.example", "google", r=r)
            self.assertTrue(ok["ok"], ok)
            self.assertEqual(ok["dmarc"]["policy"], "quarantine")
            ms = dnscheck.check("hotel.example", "microsoft", r=r)
            self.assertEqual(ms["spf"]["state"], "wrong")
            self.assertEqual(ms["spf"]["add"]["value"], "v=spf1 include:_spf.google.com include:spf.protection.outlook.com ~all")
            two = dnscheck.check("two.example", "sendgrid", r=r)
            self.assertEqual(two["spf"]["state"], "wrong")
            self.assertEqual(two["dmarc"]["state"], "missing")
            self.assertEqual(two["dmarc"]["add"]["name"], "_dmarc.two.example")
            sg = dnscheck.check("other.example", "sendgrid", r=r)            # SendGrid's own return address carries SPF
            self.assertEqual((sg["spf"]["state"], sg["dkim"]["state"]), ("pass", "pass"))
            self.assertIn("not needed", sg["spf"]["note"])
            mg = dnscheck.check("mg.hotel.example", "mailgun", "k1", r=r)    # a sending subdomain: DMARC found at the parent
            self.assertEqual((mg["dkim"]["state"], mg["dmarc"]["state"], mg["dmarc"]["at"]), ("pass", "pass", "_dmarc.hotel.example"))
            own = dnscheck.check("two.example", "smtp", r=r)
            self.assertEqual(own["spf"]["state"], "wrong")
            none = dnscheck.check("nothing.example", "microsoft", r=r)
            self.assertEqual((none["spf"]["state"], none["dkim"]["state"], none["dmarc"]["state"]), ("missing", "missing", "missing"))
            self.assertEqual(none["spf"]["add"]["value"], "v=spf1 include:spf.protection.outlook.com ~all")
            self.assertFalse(dnscheck.check("not a domain", "google", r=r)["ok"])
            self.assertFalse(dnscheck.check("hotel.example", "google", "bad selector!", r=r)["ok"])
        finally:
            d.close()


# ── the pull ─────────────────────────────────────────────────────────────────

class PullTest(Base):
    def setUp(self):
        self.smtp = SmtpCapture(self.cert, self.key, "starttls", password="pw-very-secret")
        self.clock = Clock()
        self.store = Store(":memory:", K.AtRest(MASTER))
        self.keys = K.Keys(MASTER, CID)
        self.credential = {"provider": "smtp", "from": "stay@hotel.example", "fromName": "Nile Garden", "host": "localhost", "port": 587,
                           "username": "hotel", "password": "pw-very-secret", "testTo": "owner@hotel.example"}
        self.envelope = K.seal_credential(json.dumps(self.credential).encode(), self.keys.public()["transportKey"])
        self.digest = K.digest_hex(self.envelope)
        self.chain = FakeChain(authorised=self.digest)
        self.relay = Relay(MASTER, self.store, self.net(port_map={587: self.smtp.port}), chain_for=lambda cid: self.chain, clock=self.clock)
        self.relay.accept_credential(CID, self.envelope)

    def tearDown(self):
        self.smtp.close()

    def seal(self, to):
        return K.seal(to, self.keys.public()["mailKey"])

    def test_en_and_ar_delivered(self):
        self.chain.add(1, "confirmation", self.seal(GUEST_EN), "en")
        self.chain.add(2, "confirmation", self.seal(GUEST_AR), "ar")
        rep = self.relay.pass_once()
        self.assertEqual(rep[0]["sent"], 2)
        self.assertEqual([r["state"] for r in self.chain.rows.values()], ["sent", "sent"])
        en, ar = (parse(m["data"]) for m in self.smtp.messages)
        self.assertEqual(self.smtp.messages[0]["to"], [GUEST_EN])
        self.assertEqual(en["Subject"], "Your booking at Nile Garden Hotel is confirmed (LX-000001)")
        self.assertIn("Dear Hesham Adel", en.get_body(("plain",)).get_content())
        self.assertIn("5,130.00 EGP", en.get_body(("plain",)).get_content())
        self.assertEqual(self.smtp.messages[1]["to"], [GUEST_AR])
        self.assertEqual(ar["Subject"], "تأكيد حجزك في فندق حديقة النيل (LX-000002)")
        html = ar.get_body(("html",)).get_content()
        self.assertIn('dir="rtl"', html)
        self.assertIn("بلال حسن", html)
        self.assertEqual(ar["Content-Language"], "ar")

    def test_all_four_kinds(self):
        for i, kind in enumerate(("confirmation", "preArrival", "receipt", "cancellation"), 1):
            self.chain.add(i, kind, self.seal(GUEST_EN))
        self.relay.pass_once()
        subjects = [parse(m["data"])["Subject"] for m in self.smtp.messages]
        self.assertEqual(len(subjects), 4)
        self.assertTrue(subjects[1].startswith("See you on "))
        self.assertTrue(subjects[2].startswith("Your receipt from "))
        self.assertTrue(subjects[3].endswith("is cancelled (LX-000004)"))

    def test_not_due_is_not_sent_and_refused(self):
        self.chain.add(1, "preArrival", self.seal(GUEST_EN), not_before=self.chain.setup_row["today"] + 5)
        self.relay.pass_once()
        self.assertEqual(self.smtp.messages, [])
        self.assertEqual(self.chain.record_outcome(1, True, "")["ok"], False)  # the contract's rule, as the fake keeps it
        self.chain.setup_row["today"] += 5
        self.relay.pass_once()
        self.assertEqual(len(self.smtp.messages), 1)

    def test_a_repeat_sends_once(self):
        self.chain.add(1, "confirmation", self.seal(GUEST_EN))
        self.chain.lose_next_outcome = 1                                     # the chain's answer is lost after the send
        self.relay.pass_once()
        self.assertEqual(self.chain.rows[1]["state"], "due")
        self.relay.pass_once()
        self.relay.pass_once()
        self.assertEqual(len(self.smtp.messages), 1)
        self.assertEqual(self.chain.rows[1]["state"], "sent")
        self.assertEqual(self.chain.rows[1]["attempts"], 1)

    def test_a_send_cut_short_is_never_repeated(self):
        self.chain.add(1, "confirmation", self.seal(GUEST_EN))
        self.store.mark(CID, 1, "sending", 1)                                # the relay stopped mid-call
        self.relay.pass_once()
        self.assertEqual(self.smtp.messages, [])
        self.assertEqual(self.chain.rows[1]["state"], "sent")

    def test_failures_back_off_then_fail(self):
        self.chain.add(1, "confirmation", self.seal(GUEST_EN))
        self.smtp.rcpt_reply = (451, "try later")
        self.relay.pass_once()
        self.assertEqual((self.chain.rows[1]["attempts"], self.chain.rows[1]["failure"]), (1, "unavailable"))
        self.relay.pass_once()                                               # inside the back-off: not tried
        self.assertEqual(self.chain.rows[1]["attempts"], 1)
        self.clock.t += BACKOFF[1]
        self.relay.pass_once()
        self.assertEqual(self.chain.rows[1]["attempts"], 2)
        self.clock.t += BACKOFF[2] - 1
        self.relay.pass_once()
        self.assertEqual(self.chain.rows[1]["attempts"], 2)
        self.clock.t += 1
        self.relay.pass_once()
        self.assertEqual((self.chain.rows[1]["attempts"], self.chain.rows[1]["state"]), (3, "failed"))
        self.relay.pass_once()
        self.assertEqual(self.chain.rows[1]["attempts"], 3)

    def test_unreadable_address(self):
        self.chain.add(1, "confirmation", K.seal(GUEST_EN, K.Keys(MASTER, CID + 1).public()["mailKey"]))   # sealed to another hotel's key
        self.chain.add(2, "confirmation", self.seal("not an address\r\nBcc: x@y.example"))
        self.relay.pass_once()
        self.assertEqual(self.smtp.messages, [])
        self.assertEqual([self.chain.rows[i]["failure"] for i in (1, 2)], ["unreadable", "unreadable"])

    def test_off_unauthorised_and_not_mailer(self):
        self.chain.add(1, "confirmation", self.seal(GUEST_EN))
        self.chain.setup_row["on"] = False
        self.assertEqual(self.relay.pass_once()[0]["state"], "off")
        self.chain.setup_row["on"] = True
        self.chain.setup_row["authorised"] = "ab" * 32
        self.assertEqual(self.relay.pass_once()[0]["state"], "noCredential")
        self.chain.setup_row["authorised"] = self.digest
        self.chain.mailer = False
        self.assertEqual(self.relay.pass_once()[0]["state"], "notMailer")
        self.assertEqual(self.smtp.messages, [])

    def test_paging(self):
        for i in range(1, 121):
            self.chain.add(i, "confirmation", self.seal(GUEST_EN))
        self.relay.pass_once()
        self.assertEqual(len(self.smtp.messages), 120)
        self.assertTrue(all(r["state"] == "sent" for r in self.chain.rows.values()))

    def test_a_flood_never_pushes_out_the_authorised_credential(self):
        self.relay.pass_once()                                               # the relay learns the authorised digest
        self.relay.posts.n = 100
        for i in range(10):
            c = dict(self.credential, password=f"other-{i}")
            self.relay.accept_credential(CID, K.seal_credential(json.dumps(c).encode(), self.keys.public()["transportKey"]))
        self.assertIsNotNone(self.store.credential(CID, self.digest))

    def test_owner_test_email(self):
        with self.assertRaises(Refusal):
            self.relay.test(CID, "cd" * 32)                                  # not the authorised digest
        out = self.relay.test(CID, self.digest)
        self.assertEqual(out, {"ok": True, "recorded": True, "kind": ""})
        self.assertEqual(self.smtp.messages[0]["to"], ["owner@hotel.example"])
        self.assertEqual(self.chain.setup_row["tested"], self.digest)
        for _ in range(3):                                                   # the refused one above counted too: five in the hour
            self.relay.test(CID, self.digest)
        with self.assertRaises(Refusal) as r:
            self.relay.test(CID, self.digest)
        self.assertEqual(r.exception.status, 429)

    def test_a_bad_credential_is_refused(self):
        t = self.keys.public()["transportKey"]
        for bad in ({"provider": "carrier-pigeon"}, {"provider": "smtp", "from": "x@y.example"}, dict(self.credential, testTo="no"),
                    dict(self.credential, fromName="A\r\nBcc: x@y.example"), {"provider": "google", "from": "a@b.example", "testTo": "a@b.example"}):
            with self.assertRaises(Refusal):
                self.relay.accept_credential(CID, K.seal_credential(json.dumps(bad).encode(), t))
        with self.assertRaises(Refusal):
            self.relay.accept_credential(CID, K.seal_credential(json.dumps(self.credential).encode(), K.Keys(MASTER, CID + 1).public()["transportKey"]))


# ── the HTTP API ─────────────────────────────────────────────────────────────

class HttpApiTest(Base):
    def test_routes(self):
        from http.server import ThreadingHTTPServer
        chain = FakeChain()
        relay = Relay(MASTER, Store(":memory:", K.AtRest(MASTER)), self.net(), chain_for=lambda cid: chain)
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler_for(relay))
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{httpd.server_address[1]}"

        def call(method, path, body=None):
            req = urllib.request.Request(base + path, data=json.dumps(body).encode() if body is not None else None, method=method,
                                         headers={"Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req) as r:
                    return r.status, json.loads(r.read()), dict(r.headers)
            except urllib.error.HTTPError as e:
                return e.code, json.loads(e.read()), dict(e.headers)
        try:
            status, key, headers = call("GET", f"/v1/hotels/{CID}/key")
            self.assertEqual((status, key), (200, K.Keys(MASTER, CID).public()))
            self.assertEqual(headers["Access-Control-Allow-Origin"], "*")
            self.assertEqual(call("GET", "/v1/hotels/0/key")[0], 400)
            self.assertEqual(call("GET", "/v1/hotels/abc/key")[0], 400)
            cred = {"provider": "postmark", "from": "stay@hotel.example", "fromName": "", "apiKey": "pm-key-very-secret", "testTo": "owner@hotel.example"}
            env = K.seal_credential(json.dumps(cred).encode(), key["transportKey"])
            status, body, _ = call("POST", f"/v1/hotels/{CID}/credential", {"envelope": env})
            self.assertEqual((status, body["digest"]), (200, K.digest_hex(env)))
            self.assertNotIn("pm-key-very-secret", json.dumps(body))
            self.assertEqual(call("POST", f"/v1/hotels/{CID}/test", {"digest": body["digest"]})[0], 409)   # not yet authorised on the chain
            self.assertEqual(call("GET", f"/v1/hotels/{CID}/account")[1], {"digest": "", "onFile": False})
            chain.setup_row["authorised"] = "ab" * 32
            self.assertEqual(call("GET", f"/v1/hotels/{CID}/account")[1], {"digest": "ab" * 32, "onFile": False})   # named, never given here
            chain.setup_row["authorised"] = body["digest"]
            status, inuse, _ = call("GET", f"/v1/hotels/{CID}/account")
            self.assertEqual((status, inuse), (200, {"digest": body["digest"], "onFile": True, "provider": "postmark", "from": "stay@hotel.example"}))
            self.assertNotIn("pm-key-very-secret", json.dumps(inuse))
            self.assertNotIn("owner@hotel.example", json.dumps(inuse))
            self.http.answers["/email"] = (200, {"MessageID": "pm-t", "ErrorCode": 0}, {})
            status, out, _ = call("POST", f"/v1/hotels/{CID}/test", {"digest": body["digest"]})
            self.assertEqual((status, out["ok"], out["recorded"]), (200, True, True))
            status, provs, _ = call("GET", "/v1/providers")
            self.assertEqual(sorted(p["name"] for p in provs["providers"]), sorted(providers.ALL))
            self.assertEqual(call("POST", f"/v1/hotels/{CID}/credential", {"envelope": "x" * 20_000})[0], 413)
            self.assertEqual(call("GET", "/v1/nothing")[0], 404)
        finally:
            httpd.shutdown()
            httpd.server_close()


class ZLogsTest(Base):
    def test_no_secret_or_address_in_the_logs(self):
        text = LOGS.getvalue()
        self.assertTrue(text, "the relay logged nothing at all, so this check would prove nothing")
        for w in SECRET_WORDS:
            self.assertNotIn(w, text)


if __name__ == "__main__":
    unittest.main()
