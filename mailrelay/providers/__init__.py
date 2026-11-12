"""Every provider a hotel can connect, by name.

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
from . import brevo, google, mailgun, microsoft, postmark, resend, sendgrid, ses, smtp

ALL = {p.NAME: p for p in (google, microsoft, smtp, sendgrid, postmark, resend, mailgun, brevo, ses)}
OAUTH = ("google", "microsoft")


def check(credential):
    """Whether a credential names a provider and carries every field that provider needs, all text, with a
    plain address as its sender. Returns the reason it does not, or "" when it does."""
    if not isinstance(credential, dict):
        return "not a credential"
    p = ALL.get(credential.get("provider"))
    if p is None:
        return "an unknown provider"
    if p.NAME in OAUTH:
        return "this provider connects by signing in, not by a key"
    for f in p.FIELDS:
        if f in ("fromName", "region", "domain", "security"):      # optional: a default, or the port decides
            continue
        if not str(credential.get(f, "")).strip():
            return f"{f} is missing"
    for k, v in credential.items():
        if not isinstance(v, (str, int)) or len(str(v)) > 4096:
            return f"{k} is not a short value"
    if not plain_address(credential["from"]) or not plain_address(credential.get("testTo", "")):
        return "an address is not a plain email address"
    if any(c in str(credential.get("fromName", "")) for c in "\r\n<>\""):
        return "the sender's name holds a character an email header cannot"
    return ""


def plain_address(a):
    a = str(a)
    if len(a) > 254 or a.count("@") != 1 or any(c.isspace() or c in "<>\",;()[]\\" for c in a):
        return False
    local, domain = a.split("@")
    return bool(local) and "." in domain and not domain.startswith(".") and not domain.endswith(".") and ".." not in domain
