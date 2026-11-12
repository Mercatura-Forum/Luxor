"""Microsoft 365 (and Outlook.com): the owner signs in with Microsoft and grants one permission, to send
mail as them (`Mail.Send`); the relay keeps the refresh token and sends through Microsoft Graph
(`/me/sendMail`). Microsoft answers 202 with no id: the message's own Message-ID is the record. A sign-in
refused by the tenant's administrator shows as a sign-in failure, and the skill says what to ask them.

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
from .base import Outcome, by_status, headers_of, sender
from .. import oauth

NAME, LABEL = "microsoft", "Microsoft 365"
FIELDS = ["from", "fromName"]
SPF = "spf.protection.outlook.com"
SPF_ROOT = True   # the hotel's own domain is the return address: its SPF must name the provider
DKIM = ["selector1", "selector2"]


def send(credential, message, net):
    token = oauth.access_token(NAME, credential, net)
    if token is None:
        return Outcome.failed("signIn")
    addr, name = sender(credential)
    person = lambda a, n: {"emailAddress": {"address": a, **({"name": n} if n else {})}}
    body = {"message": {"subject": message.subject, "body": {"contentType": "HTML", "content": message.html},
                        "toRecipients": [person(message.to, message.to_name)], "replyTo": [person(addr, name)], "from": person(addr, name),
                        "internetMessageHeaders": [{"name": k, "value": v} for k, v in headers_of(message).items() if k.startswith("X-")]},
            "saveToSentItems": True}
    status, _, _ = net.post_json(net.base("microsoft.api", "https://graph.microsoft.com") + "/v1.0/me/sendMail", {"Authorization": "Bearer " + token}, body)
    code = by_status(status)
    if code:
        if code == "signIn":
            credential.pop("accessToken", None)
        return Outcome.failed(code)
    return Outcome.sent(message.message_id)
