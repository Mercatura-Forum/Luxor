"""SendGrid: `POST /v3/mail/send` with the API key as a bearer token; 202 and an `X-Message-Id` when sent.

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
from .base import Outcome, by_status, headers_of, sender

NAME, LABEL = "sendgrid", "SendGrid"
FIELDS = ["from", "fromName", "apiKey"]
SPF = "sendgrid.net"
SPF_ROOT = False   # the provider's own return address carries SPF; DMARC passes through DKIM
DKIM = ["s1", "s2"]


def send(credential, message, net):
    addr, name = sender(credential)
    body = {"personalizations": [{"to": [{"email": message.to, **({"name": message.to_name} if message.to_name else {})}]}],
            "from": {"email": addr, "name": name}, "reply_to": {"email": addr, "name": name}, "subject": message.subject,
            "content": [{"type": "text/plain", "value": message.text}, {"type": "text/html", "value": message.html}],
            "headers": headers_of(message)}
    status, hdrs, _ = net.post_json(net.base(NAME, "https://api.sendgrid.com") + "/v3/mail/send", {"Authorization": "Bearer " + credential["apiKey"]}, body)
    code = by_status(status)
    return Outcome.failed(code) if code else Outcome.sent({k.lower(): v for k, v in hdrs.items()}.get("x-message-id", ""))
