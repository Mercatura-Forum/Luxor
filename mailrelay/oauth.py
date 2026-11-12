"""Signing in with Google or Microsoft (OAuth 2.0 authorisation code with PKCE, RFC 7636), and the
short-lived access tokens the relay takes from the refresh token it keeps.

The relay is one registered application with each provider (its client id and secret are the relay's
own configuration, never a hotel's). The owner starts the sign-in from the console; the provider returns
to the relay's callback, which exchanges the code with the PKCE verifier only the relay holds, keeps the
refresh token encrypted, and sends the owner back to the console with the credential's digest, which the
owner then authorises on the chain. The token never reaches the browser.

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import base64, hashlib, json, secrets, time, urllib.parse

PROVIDERS = {
    "google": {"auth": "https://accounts.google.com/o/oauth2/v2/auth", "token": "https://oauth2.googleapis.com/token",
               "scope": "openid email https://www.googleapis.com/auth/gmail.send", "extra": {"access_type": "offline", "prompt": "consent"}},
    "microsoft": {"auth": "https://login.microsoftonline.com/common/oauth2/v2.0/authorize", "token": "https://login.microsoftonline.com/common/oauth2/v2.0/token",
                  "scope": "openid email offline_access https://graph.microsoft.com/Mail.Send", "extra": {"prompt": "select_account"}},
}


def _url(net, provider, which):
    return net.endpoints.get(f"{provider}.{which}", PROVIDERS[provider][which])


def pkce():
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(48)).decode().rstrip("=")
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    return verifier, challenge


def authorize_url(provider, net, redirect_uri, state, challenge, login_hint=""):
    client = net.oauth[provider]
    q = {"client_id": client["client_id"], "response_type": "code", "redirect_uri": redirect_uri, "scope": PROVIDERS[provider]["scope"], "state": state,
         "code_challenge": challenge, "code_challenge_method": "S256", **PROVIDERS[provider]["extra"]}
    if login_hint:
        q["login_hint"] = login_hint
    return _url(net, provider, "auth") + "?" + urllib.parse.urlencode(q)


def _token(provider, net, form):
    client = net.oauth[provider]
    body = urllib.parse.urlencode({**form, "client_id": client["client_id"], "client_secret": client["client_secret"]}).encode()
    status, _, raw = net.request("POST", _url(net, provider, "token"), {"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"}, body)
    try:
        answer = json.loads(raw or b"{}")
    except ValueError:
        answer = {}
    return status, answer


def _claims(id_token):
    """The id token's claims. It came straight from the provider's token endpoint over TLS, which OpenID
    Connect Core 3.1.3.7 accepts in place of checking its signature; only the account's address is read,
    for the console to show which account was connected."""
    try:
        return json.loads(base64.urlsafe_b64decode(id_token.split(".")[1] + "=="))
    except (IndexError, ValueError):
        return {}


def exchange(provider, net, code, verifier, redirect_uri):
    """The credential fields a finished sign-in gives, or None when the provider refused the code."""
    status, a = _token(provider, net, {"grant_type": "authorization_code", "code": code, "code_verifier": verifier, "redirect_uri": redirect_uri})
    if status != 200 or not a.get("access_token") or not a.get("refresh_token"):
        return None
    claims = _claims(a.get("id_token", ""))
    return {"refreshToken": a["refresh_token"], "accessToken": a["access_token"], "expires": time.time() + int(a.get("expires_in", 3600)) - 60,
            "account": str(claims.get("email") or claims.get("preferred_username") or "")}


def access_token(provider, credential, net):
    """A live access token for the credential, refreshed when it is near its end (the credential is
    updated in place, so the relay stores a rotated refresh token). None when the grant was revoked."""
    if credential.get("accessToken") and float(credential.get("expires", 0)) > time.time():
        return credential["accessToken"]
    status, a = _token(provider, net, {"grant_type": "refresh_token", "refresh_token": credential.get("refreshToken", ""), "scope": PROVIDERS[provider]["scope"]})
    if status in (400, 401) or (status == 200 and not a.get("access_token")):
        return None
    if status != 200:
        raise ConnectionError(f"{provider} token endpoint answered {status}")
    credential["accessToken"] = a["access_token"]
    credential["expires"] = time.time() + int(a.get("expires_in", 3600)) - 60
    if a.get("refresh_token"):
        credential["refreshToken"] = a["refresh_token"]
    return credential["accessToken"]
