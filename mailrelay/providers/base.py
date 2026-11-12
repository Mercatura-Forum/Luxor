"""The one interface every email provider sits behind, and the HTTP the API providers share.

A provider is one file: `send(credential, message, net)` returns an `Outcome` (sent with the provider's
message id, or failed with one of the outbox's codes), `FIELDS` names what the owner gives for it, and
`SPF` / `DKIM` say what the DNS check looks for. The credential is the hotel's, never Thebes's: the mail goes
from the hotel's own address through the hotel's own account.

Failures are codes, never the provider's words, because those can quote the guest's address:
  signIn       the account refused the relay's sign-in (a wrong or revoked key, password or grant)
  rejected     the provider refused this message (an address it will not send to, a sender not verified)
  unavailable  the provider could not be reached or asked to wait (network, 429, 5xx): tried again later

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import email.policy, email.utils, ipaddress, json, socket, ssl, urllib.error, urllib.parse, urllib.request
from dataclasses import dataclass
from email.headerregistry import Address
from email.message import EmailMessage


@dataclass
class Outcome:
    ok: bool
    provider_id: str = ""
    failure: str = ""

    @staticmethod
    def sent(pid=""):
        return Outcome(True, str(pid)[:200], "")

    @staticmethod
    def failed(code):
        assert code in ("signIn", "rejected", "unavailable", "unreadable")
        return Outcome(False, "", code)


def by_status(status):
    if 200 <= status < 300:
        return None
    if status in (401, 403):
        return "signIn"
    if status == 429 or status >= 500 or status == 408:
        return "unavailable"
    return "rejected"


def loopback(host):
    try:
        return ipaddress.ip_address(socket.gethostbyname(host)).is_loopback
    except OSError:
        return False


class Net:
    """The relay's outbound connections. `endpoints` overrides a provider's base URL (the tests' capture
    servers); `allow_private` lets SMTP reach a private address (the tests' capture server); `oauth` holds
    the relay's own application registrations with Google and Microsoft. Plain HTTP is
    refused except to a loopback address, so a credential never crosses a network in the clear."""

    def __init__(self, endpoints=None, allow_private=False, cafile=None, timeout=20, oauth=None, port_map=None):
        self.endpoints = dict(endpoints or {})
        self.port_map = dict(port_map or {})   # tests only: the port the owner typed -> the capture server's port
        self.oauth = dict(oauth or {})     # {"google": {"client_id", "client_secret"}, "microsoft": {...}}: the relay's own apps
        self.allow_private = allow_private
        self.cafile = cafile
        self.timeout = timeout

    def base(self, provider, default):
        return self.endpoints.get(provider, default).rstrip("/")

    def tls(self):
        ctx = ssl.create_default_context(cafile=self.cafile) if self.cafile else ssl.create_default_context()
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        return ctx

    def request(self, method, url, headers, body=b""):
        """(status, headers, body bytes); raises ConnectionError when nothing came back."""
        u = urllib.parse.urlparse(url)
        if u.scheme != "https" and not (u.scheme == "http" and loopback(u.hostname or "")):
            raise ValueError(f"refusing a plain-HTTP request to {u.hostname}")
        req = urllib.request.Request(url, data=body if method != "GET" else None, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout, context=self.tls() if u.scheme == "https" else None) as r:
                return r.status, dict(r.headers), r.read()
        except urllib.error.HTTPError as e:
            return e.code, dict(e.headers or {}), e.read()
        except (urllib.error.URLError, OSError) as e:
            raise ConnectionError(str(e)) from None

    def post_json(self, url, headers, payload):
        return self.request("POST", url, {**headers, "Content-Type": "application/json", "Accept": "application/json"}, json.dumps(payload).encode())

    def public_host(self, host):
        """Whether an SMTP host the owner typed resolves only to public addresses."""
        if self.allow_private:
            return True
        try:
            infos = socket.getaddrinfo(host, None)
        except OSError:
            return False
        for info in infos:
            ip = ipaddress.ip_address(info[4][0])
            if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved or ip.is_multicast or ip.is_unspecified:
                return False
        return bool(infos)


def sender(credential):
    """The hotel's own address and the name shown with it."""
    return credential["from"], credential.get("fromName", "")


def mime(credential, message):
    """The message as RFC 5322 bytes, for SMTP and the Gmail API: text and HTML alternatives, the
    hotel's address as From and Reply-To, and the message's stable Message-ID."""
    addr, name = sender(credential)
    m = EmailMessage(policy=email.policy.SMTP)
    local, _, domain = addr.partition("@")
    m["From"] = Address(display_name=name, username=local, domain=domain)
    tl, _, td = message.to.partition("@")
    m["To"] = Address(display_name=message.to_name, username=tl, domain=td)
    m["Reply-To"] = Address(display_name=name, username=local, domain=domain)
    m["Subject"] = message.subject
    m["Message-ID"] = message.message_id
    m["Date"] = email.utils.formatdate(localtime=False)
    m["Auto-Submitted"] = "auto-generated"
    m.set_content(message.text)
    m.add_alternative(message.html, subtype="html")
    m["Content-Language"] = message.lang       # after the content: set_content clears every Content-* header
    return m.as_bytes()


def headers_of(message):
    """The headers every API message carries: a stable id, and that a program sent it."""
    return {"X-Luxor-Message": message.message_id.strip("<>"), "Auto-Submitted": "auto-generated"}
