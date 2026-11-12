"""Resend: `POST /emails` with the API key as a bearer token and an `Idempotency-Key` (the message's own id,
so a repeated request is one email at Resend too); 200 and an `id` when sent.

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import json
from .base import Outcome, by_status, headers_of, sender

NAME, LABEL = "resend", "Resend"
FIELDS = ["from", "fromName", "apiKey"]
SPF = "amazonses.com"   # Resend sends from a subdomain whose SPF names Amazon SES
SPF_ROOT = False   # the provider's own return address carries SPF; DMARC passes through DKIM
DKIM = ["resend"]


def send(credential, message, net):
    addr, name = sender(credential)
    sender_text = f"{name} <{addr}>" if name else addr
    body = {"from": sender_text, "to": [message.to], "reply_to": sender_text, "subject": message.subject, "text": message.text,
            "html": message.html, "headers": headers_of(message)}
    status, _, raw = net.post_json(net.base(NAME, "https://api.resend.com") + "/emails",
                                   {"Authorization": "Bearer " + credential["apiKey"], "Idempotency-Key": message.message_id.strip("<>")}, body)
    code = by_status(status)
    if code:
        return Outcome.failed(code)
    try:
        return Outcome.sent(json.loads(raw or b"{}").get("id", ""))
    except ValueError:
        return Outcome.sent("")
