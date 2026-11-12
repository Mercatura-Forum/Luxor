"""Google Workspace (and Gmail): the owner signs in with Google and grants one permission, to send mail
as them (`gmail.send`); the relay keeps the refresh token Google gives it and sends through the Gmail API
(`users/me/messages/send`) with a short-lived access token. The hotel's address must be the account's own
or one of its "send mail as" addresses: Gmail refuses any other, and the test email shows it.

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import base64, json
from .base import Outcome, by_status, mime
from .. import oauth

NAME, LABEL = "google", "Google Workspace"
FIELDS = ["from", "fromName"]          # the rest comes from Google's answer to the sign-in
SPF = "_spf.google.com"
SPF_ROOT = True   # the hotel's own domain is the return address: its SPF must name the provider
DKIM = ["google"]


def send(credential, message, net):
    token = oauth.access_token(NAME, credential, net)
    if token is None:
        return Outcome.failed("signIn")
    raw = base64.urlsafe_b64encode(mime(credential, message)).decode().rstrip("=")
    status, _, body = net.post_json(net.base("google.api", "https://gmail.googleapis.com") + "/gmail/v1/users/me/messages/send",
                                    {"Authorization": "Bearer " + token}, {"raw": raw})
    code = by_status(status)
    if code:
        if code == "signIn":
            credential.pop("accessToken", None)
        return Outcome.failed(code)
    try:
        return Outcome.sent(json.loads(body or b"{}").get("id", ""))
    except ValueError:
        return Outcome.sent("")
