"""SMTP: the hotel's own mail server or any provider's SMTP service, by host, port, user name and password.

TLS is required in both forms: implicit TLS (port 465) or STARTTLS (587, 25, 2525). A server that does not
offer STARTTLS is never sent the password; the certificate is checked against the host name the owner typed.
The host is resolved once, checked to be a public address (so the relay cannot be pointed at its own
network), and the connection is made to that same address.

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import smtplib, socket
from .base import Outcome, mime, sender

NAME, LABEL = "smtp", "SMTP"
FIELDS = ["from", "fromName", "host", "port", "security", "username", "password"]
SPF = ""        # the owner's own server: the check reads the SPF record as it is and asks the owner to confirm it
SPF_ROOT = True   # the hotel's own domain is the return address: its SPF must name the provider
DKIM = ["default", "mail", "dkim", "selector1", "selector2"]
PORTS = {465: "tls", 587: "starttls", 25: "starttls", 2525: "starttls"}


class _Pinned:
    """Connect to the address that was checked, while TLS verifies the name the owner typed."""

    def _get_socket(self, host, port, timeout):
        sock = socket.create_connection((self.pinned, self.port_map.get(port, port)), timeout)
        if isinstance(self, smtplib.SMTP_SSL):
            return self.context.wrap_socket(sock, server_hostname=self._host)
        return sock


class _SMTP(_Pinned, smtplib.SMTP):
    pass


class _SMTPS(_Pinned, smtplib.SMTP_SSL):
    pass


def _address(host, net):
    """The one address the relay will connect to, or None when the host is not public."""
    if not net.public_host(host):
        return None
    try:
        infos = socket.getaddrinfo(host, None, type=socket.SOCK_STREAM)
        return sorted(infos, key=lambda i: i[0] != socket.AF_INET)[0][4][0]
    except OSError:
        return None


def send(credential, message, net):
    host, port = str(credential.get("host", "")).strip().lower(), int(credential.get("port", 0) or 0)
    security = credential.get("security") or PORTS.get(port, "")
    if not host or port not in PORTS or security not in ("tls", "starttls"):
        return Outcome.failed("signIn")
    pinned = _address(host, net)
    if pinned is None:
        return Outcome.failed("signIn")
    addr, _ = sender(credential)
    ctx = net.tls()
    try:
        if security == "tls":
            s = _SMTPS(context=ctx, timeout=net.timeout)
            s.pinned, s.port_map = pinned, net.port_map
            s._host = host
            s.connect(host, port)
        else:
            s = _SMTP(timeout=net.timeout)
            s.pinned, s.port_map = pinned, net.port_map
            s._host = host          # STARTTLS verifies the certificate against this name
            s.connect(host, port)
            s.ehlo()
            if not s.has_extn("starttls"):
                # Never a password over a plain connection. smtplib's starttls() would refuse here too (it
                # raises when the server does not offer it); this says so first, as the reason, and closes.
                s.close()
                return Outcome.failed("signIn")
            s.starttls(context=ctx)
            s.ehlo()
        try:
            s.login(credential["username"], credential["password"])
            refused = s.sendmail(addr, [message.to], mime(credential, message))
        finally:
            try:
                s.quit()
            except (smtplib.SMTPException, OSError):
                s.close()
        return Outcome.failed("rejected") if refused else Outcome.sent(message.message_id)
    except smtplib.SMTPAuthenticationError:
        return Outcome.failed("signIn")
    except smtplib.SMTPNotSupportedError:
        return Outcome.failed("signIn")
    except (smtplib.SMTPRecipientsRefused, smtplib.SMTPSenderRefused, smtplib.SMTPDataError) as e:
        code = getattr(e, "smtp_code", 0) or 550
        if isinstance(e, smtplib.SMTPRecipientsRefused):
            code = min((c for c, _ in e.recipients.values()), default=550)
        return Outcome.failed("unavailable" if 400 <= code < 500 else "rejected")
    except smtplib.SMTPResponseException as e:
        return Outcome.failed("unavailable" if 400 <= e.smtp_code < 500 else "rejected")
    except (smtplib.SMTPException, OSError):
        return Outcome.failed("unavailable")
