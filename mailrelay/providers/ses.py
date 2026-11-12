"""Amazon SES (v2): `POST /v2/email/outbound-emails` on the region's endpoint, signed with AWS Signature
Version 4 from the IAM user's access key (which needs `ses:SendEmail` and nothing else); 200 and a
`MessageId` when sent.

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import datetime, hashlib, hmac, json, re, urllib.parse
from .base import Outcome, by_status, sender

NAME, LABEL = "ses", "Amazon SES"
FIELDS = ["from", "fromName", "accessKeyId", "secretAccessKey", "region"]
SPF = "amazonses.com"
SPF_ROOT = False   # the provider's own return address carries SPF; DMARC passes through DKIM
DKIM = []   # SES gives three CNAME tokens of its own: the owner reads them from the SES console


def _sign(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def signed_headers(method, url, body, access_key, secret, region, now=None, service="ses", content_type="application/json"):
    """AWS Signature Version 4: the canonical request, the string to sign and the Authorization header
    (checked in the tests against the worked example in AWS's own documentation)."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    amz_date, day = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
    u = urllib.parse.urlparse(url)
    host = u.netloc
    payload = hashlib.sha256(body).hexdigest()
    headers = {"content-type": content_type, "host": host, "x-amz-date": amz_date}
    names = ";".join(sorted(headers))
    canonical = "\n".join([method, u.path or "/", u.query, "".join(f"{k}:{headers[k]}\n" for k in sorted(headers)), names, payload])
    scope = f"{day}/{region}/{service}/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical.encode()).hexdigest()])
    k = _sign(_sign(_sign(_sign(("AWS4" + secret).encode(), day), region), service), "aws4_request")
    signature = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()
    return {"Content-Type": content_type, "X-Amz-Date": amz_date,
            "Authorization": f"AWS4-HMAC-SHA256 Credential={access_key}/{scope}, SignedHeaders={names}, Signature={signature}"}


def send(credential, message, net):
    region = credential.get("region", "")
    if not re.fullmatch(r"[a-z]{2}(-[a-z]+)+-\d", region):
        return Outcome.failed("signIn")
    addr, name = sender(credential)
    sender_text = f"{name} <{addr}>" if name else addr
    body = json.dumps({"FromEmailAddress": sender_text, "ReplyToAddresses": [addr], "Destination": {"ToAddresses": [message.to]},
                       "Content": {"Simple": {"Subject": {"Data": message.subject, "Charset": "UTF-8"},
                                              "Body": {"Text": {"Data": message.text, "Charset": "UTF-8"}, "Html": {"Data": message.html, "Charset": "UTF-8"}}}}}).encode()
    url = net.base(NAME, f"https://email.{region}.amazonaws.com") + "/v2/email/outbound-emails"
    status, _, raw = net.request("POST", url, signed_headers("POST", url, body, credential["accessKeyId"], credential["secretAccessKey"], region), body)
    code = by_status(status)
    if code:
        return Outcome.failed(code)
    try:
        return Outcome.sent(json.loads(raw or b"{}").get("MessageId", ""))
    except ValueError:
        return Outcome.sent("")
