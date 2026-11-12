"""Brevo: `POST /v3/smtp/email` with the API key in `api-key`; 201 and a `messageId` when sent.

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import json
from .base import Outcome, by_status, headers_of, sender

NAME, LABEL = "brevo", "Brevo"
FIELDS = ["from", "fromName", "apiKey"]
SPF = "spf.brevo.com"
SPF_ROOT = False   # the provider's own return address carries SPF; DMARC passes through DKIM
DKIM = ["brevo1", "brevo2", "mail"]


def send(credential, message, net):
    addr, name = sender(credential)
    body = {"sender": {"email": addr, **({"name": name} if name else {})}, "to": [{"email": message.to, **({"name": message.to_name} if message.to_name else {})}],
            "replyTo": {"email": addr}, "subject": message.subject, "textContent": message.text, "htmlContent": message.html, "headers": headers_of(message)}
    status, _, raw = net.post_json(net.base(NAME, "https://api.brevo.com") + "/v3/smtp/email", {"api-key": credential["apiKey"]}, body)
    code = by_status(status)
    if code:
        return Outcome.failed(code)
    try:
        return Outcome.sent(json.loads(raw or b"{}").get("messageId", ""))
    except ValueError:
        return Outcome.sent("")
