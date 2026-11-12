"""Mailgun: `POST /v3/<domain>/messages`, form-encoded, HTTP Basic as `api` with the API key; 200 and an
`id` when sent. An account in the EU region is on `api.eu.mailgun.net`.

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import base64, json, urllib.parse
from .base import Outcome, by_status, headers_of, sender

NAME, LABEL = "mailgun", "Mailgun"
FIELDS = ["from", "fromName", "apiKey", "domain", "region"]
SPF = "mailgun.org"
SPF_ROOT = False   # the provider's own return address carries SPF; DMARC passes through DKIM
DKIM = ["mx", "smtp", "k1", "pic"]


def send(credential, message, net):
    addr, name = sender(credential)
    sender_text = f"{name} <{addr}>" if name else addr
    form = [("from", sender_text), ("to", message.to), ("subject", message.subject), ("text", message.text), ("html", message.html),
            ("h:Reply-To", sender_text)] + [("h:" + k, v) for k, v in headers_of(message).items()]
    domain = credential.get("domain") or addr.partition("@")[2]
    if not domain.replace(".", "").replace("-", "").isalnum():
        return Outcome.failed("rejected")
    default = "https://api.eu.mailgun.net" if credential.get("region") == "eu" else "https://api.mailgun.net"
    auth = base64.b64encode(("api:" + credential["apiKey"]).encode()).decode()
    status, _, raw = net.request("POST", net.base(NAME, default) + f"/v3/{domain}/messages",
                                 {"Authorization": "Basic " + auth, "Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"},
                                 urllib.parse.urlencode(form).encode())
    code = by_status(status)
    if code:
        return Outcome.failed(code)
    try:
        return Outcome.sent(json.loads(raw or b"{}").get("id", ""))
    except ValueError:
        return Outcome.sent("")
