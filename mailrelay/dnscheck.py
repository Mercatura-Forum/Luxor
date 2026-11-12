"""The DNS check the console runs before a hotel's first message: do the records of the hotel's own
domain let its provider send as it, so guests' mail providers accept the messages rather than file them
as spam.

  SPF    for Google, Microsoft and the hotel's own SMTP server, whose messages leave with the hotel's own
         domain as their return address, the domain's one `v=spf1` TXT record names the provider (or, for
         SMTP, exists). The API providers send with their own return address (SendGrid, Postmark, Resend,
         Mailgun, Brevo, SES), which carries its own SPF, and DMARC passes through the DKIM signature
         aligned with the hotel's domain: for them the root record is reported, never required. Two SPF
         records are an error for every provider (RFC 7208 3.2).
  DKIM   a key is published at `<selector>._domainkey.<domain>` (TXT with `p=`, or a CNAME to the
         provider's key) for the provider's selectors or the one the owner names.
  DMARC  a `v=DMARC1` TXT record at `_dmarc.<domain>`, or at a parent domain's (RFC 7489 6.6.3, for a
         sending subdomain such as Mailgun's `mg.`); its policy is reported, `none` included, because a
         missing record is what large mailbox providers now refuse bulk senders for.

Each check answers pass, missing or wrong, with the record to add in words a hotel can give its domain's
administrator. Only public DNS is read.

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import re
import dns.exception, dns.resolver

from . import providers

DOMAIN = re.compile(r"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")


def resolver(nameserver=None, port=53, timeout=4.0):
    r = dns.resolver.Resolver(configure=nameserver is None)
    if nameserver:
        r.nameservers = [nameserver]
        r.port = port
    r.lifetime = timeout
    return r


def _txt(r, name):
    try:
        return ["".join(part.decode("utf-8", "replace") for part in rr.strings) for rr in r.resolve(name, "TXT")]
    except (dns.resolver.NXDOMAIN, dns.resolver.NoAnswer):
        return []


def _cname(r, name):
    try:
        return [str(rr.target).rstrip(".") for rr in r.resolve(name, "CNAME")]
    except (dns.resolver.NXDOMAIN, dns.resolver.NoAnswer):
        return []


def check(domain, provider, selector="", r=None):
    domain = str(domain).strip().lower().rstrip(".")
    if not DOMAIN.match(domain):
        return {"ok": False, "error": "not a domain name"}
    p = providers.ALL.get(provider)
    if p is None:
        return {"ok": False, "error": "an unknown provider"}
    if selector and not re.fullmatch(r"[a-z0-9]([a-z0-9._-]{0,62})", selector.lower()):
        return {"ok": False, "error": "not a DKIM selector"}
    r = r or resolver()
    try:
        out = {"domain": domain, "provider": provider, "spf": _spf(r, domain, p), "dkim": _dkim(r, domain, p, selector.lower()), "dmarc": _dmarc(r, domain)}
    except dns.exception.DNSException:
        return {"ok": False, "error": "the domain's DNS did not answer; try again in a minute"}
    out["ok"] = all(out[k]["state"] == "pass" for k in ("spf", "dkim", "dmarc"))
    return out


def _spf(r, domain, p):
    records = [t for t in _txt(r, domain) if t.lower().startswith("v=spf1")]
    want = f"include:{p.SPF}" if p.SPF else ""
    if not records and not p.SPF_ROOT:
        return {"state": "pass", "note": f"not needed for {p.LABEL}: it sends with its own return address, and DMARC passes through DKIM"}
    suggestion = f"v=spf1 {want} ~all" if want else "v=spf1 a mx ~all"
    if not records:
        return {"state": "missing", "add": {"type": "TXT", "name": domain, "value": suggestion}}
    if len(records) > 1:
        return {"state": "wrong", "found": records, "why": "two SPF records: merge them into one", "add": {"type": "TXT", "name": domain, "value": suggestion}}
    found = records[0]
    if not p.SPF_ROOT:
        return {"state": "pass", "found": [found], "note": f"not needed for {p.LABEL}: it sends with its own return address, and DMARC passes through DKIM"}
    if want and want.lower() not in found.lower().split():
        merged = found.rsplit(" ", 1)
        value = f"{merged[0]} {want} {merged[1]}" if len(merged) == 2 and merged[1].lstrip("~-?+") == "all" else f"{found} {want}"
        return {"state": "wrong", "found": [found], "why": f"the record does not name {p.LABEL}", "add": {"type": "TXT", "name": domain, "value": value}}
    return {"state": "pass", "found": [found]}


def _dkim(r, domain, p, selector):
    selectors = [selector] if selector else list(p.DKIM)
    if not selectors:
        return {"state": "missing", "why": f"{p.LABEL} gives each domain its own DKIM records: copy them from its console, then name the selector here"}
    for s in selectors:
        name = f"{s}._domainkey.{domain}"
        txt = [t for t in _txt(r, name) if re.search(r"(^|;)\s*p=[A-Za-z0-9+/=]{20,}", t)]
        if txt:
            return {"state": "pass", "selector": s, "found": [t[:80] for t in txt]}
        cname = _cname(r, name)
        if cname:
            return {"state": "pass", "selector": s, "found": cname}
    return {"state": "missing", "tried": selectors, "why": f"no DKIM key found: turn on DKIM signing in {p.LABEL} and add the record it gives you"}


def _dmarc(r, domain):
    suggestion = {"type": "TXT", "name": f"_dmarc.{domain}", "value": "v=DMARC1; p=none; adkim=r; aspf=r"}
    labels = domain.split(".")
    records, at = [], domain
    for i in range(len(labels) - 1):                 # the domain, then each parent with two labels or more
        at = ".".join(labels[i:])
        records = [t for t in _txt(r, f"_dmarc.{at}") if t.lower().startswith("v=dmarc1")]
        if records:
            break
    if not records:
        return {"state": "missing", "add": suggestion}
    if len(records) > 1:
        return {"state": "wrong", "found": records, "why": "two DMARC records: keep one", "add": suggestion}
    m = re.search(r"(^|;)\s*p\s*=\s*(none|quarantine|reject)", records[0], re.I)
    if not m:
        return {"state": "wrong", "found": records, "why": "the record has no policy", "add": suggestion}
    return {"state": "pass", "policy": m.group(2).lower(), "found": records, "at": f"_dmarc.{at}"}
