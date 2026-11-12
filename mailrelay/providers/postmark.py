"""Postmark: `POST /email` with the server token in `X-Postmark-Server-Token`; 200 and a `MessageID`
when sent. Postmark answers a refusal with 422 and its own `ErrorCode`: 10 is a bad token.

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import json
from .base import Outcome, by_status, headers_of, sender

NAME, LABEL = "postmark", "Postmark"
FIELDS = ["from", "fromName", "apiKey"]
SPF = "spf.mtasv.net"
SPF_ROOT = False   # the provider's own return address carries SPF; DMARC passes through DKIM
DKIM = []   # Postmark names its selector by date (e.g. 20240101pm): the owner reads it from Postmark


def send(credential, message, net):
    addr, name = sender(credential)
    sender_text = f"{name} <{addr}>" if name else addr
    body = {"From": sender_text, "To": message.to, "ReplyTo": sender_text, "Subject": message.subject, "TextBody": message.text,
            "HtmlBody": message.html, "MessageStream": "outbound", "Headers": [{"Name": k, "Value": v} for k, v in headers_of(message).items()]}
    status, _, raw = net.post_json(net.base(NAME, "https://api.postmarkapp.com") + "/email", {"X-Postmark-Server-Token": credential["apiKey"]}, body)
    try:
        answer = json.loads(raw or b"{}")
    except ValueError:
        answer = {}
    if status == 422 and answer.get("ErrorCode") == 10:
        return Outcome.failed("signIn")
    code = by_status(status)
    return Outcome.failed(code) if code else Outcome.sent(answer.get("MessageID", ""))
