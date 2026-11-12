"""The relay's keys, and the two sealed envelopes it opens.

Every key the relay holds for a hotel is derived from one master secret and the hotel contract's id, so
the relay keeps no key per hotel and a request for a hotel's keys stores nothing:

  mailer     an Ed25519 key: the relay signs its calls to the hotel's contract with it, and the owner makes
             its principal the hotel's mailer (`setMailRelay`);
  mail       a P-256 key: guests' browsers seal their address to its public half, and only the relay can open
             one ("lxe1." envelopes, as the page's keys.ts seals them);
  transport  a P-256 key: the owner's browser seals the hotel's email credential to it ("lxc1." envelopes),
             so the credential travels only between the owner's browser and the relay.

The credentials the relay keeps are encrypted at rest under a key derived from the same master.

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import base64, hashlib, os
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, ed25519
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

P256_ORDER = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
ADDRESS_INFO = b"LUXOR-GUEST-DATA-v1"        # the page's seal(), with the mail key in place of the hotel's
CREDENTIAL_INFO = b"LUXOR-MAIL-CREDENTIAL-v1"
_ED25519_SPKI = bytes.fromhex("302a300506032b6570032100")


def _hkdf(master, info, length=32):
    return HKDF(algorithm=hashes.SHA256(), length=length, salt=b"luxor-mail-relay", info=info).derive(master)


def b64u(b):
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


def unb64u(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


class Keys:
    """The keys of one hotel contract, derived from the relay's master secret."""

    def __init__(self, master, contract):
        if len(master) != 32:
            raise ValueError("the relay's master secret is 32 bytes")
        cid = str(int(contract)).encode()
        self.contract = int(contract)
        self.mailer = ed25519.Ed25519PrivateKey.from_private_bytes(_hkdf(master, b"mailer/" + cid))
        self.mail = self._p256(master, b"mail/" + cid)
        self.transport = self._p256(master, b"transport/" + cid)

    @staticmethod
    def _p256(master, info):
        # 48 bytes reduced modulo the group order: the bias is below 2^-128
        scalar = int.from_bytes(_hkdf(master, info, 48), "big") % (P256_ORDER - 1) + 1
        return ec.derive_private_key(scalar, ec.SECP256R1())

    def mailer_seed_hex(self):
        return self.mailer.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption()).hex()

    def mailer_principal_hex(self):
        """The principal the contract sees for a call this key signs: SHA-224 of its DER key, then 0x02."""
        pub = self.mailer.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        return (hashlib.sha224(_ED25519_SPKI + pub).digest() + b"\x02").hex()

    @staticmethod
    def raw(key):
        return key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint).hex()

    def public(self):
        return {"contract": str(self.contract), "mailer": self.mailer_principal_hex(), "mailKey": self.raw(self.mail), "transportKey": self.raw(self.transport)}

    def open_address(self, envelope):
        return _open(self.mail, envelope, "lxe1.", ADDRESS_INFO).decode("utf-8")

    def open_credential(self, envelope):
        return _open(self.transport, envelope, "lxc1.", CREDENTIAL_INFO)


def seal(text_or_bytes, public_hex, prefix="lxe1.", info=ADDRESS_INFO):
    """Seal to a raw P-256 public key, as a browser does (used by the tests and the console's own code
    path in Python tools): ECDH with an ephemeral key, HKDF-SHA256, AES-256-GCM."""
    data = text_or_bytes.encode() if isinstance(text_or_bytes, str) else text_or_bytes
    pub = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), bytes.fromhex(public_hex))
    eph = ec.generate_private_key(ec.SECP256R1())
    key = HKDF(algorithm=hashes.SHA256(), length=32, salt=b"", info=info).derive(eph.exchange(ec.ECDH(), pub))
    iv = os.urandom(12)
    ephraw = eph.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    return prefix + b64u(ephraw + iv + AESGCM(key).encrypt(iv, data, None))


def seal_credential(data, transport_hex):
    return seal(data, transport_hex, "lxc1.", CREDENTIAL_INFO)


def _open(priv, envelope, prefix, info):
    if not envelope.startswith(prefix):
        raise ValueError("not a sealed value of this kind")
    body = unb64u(envelope[len(prefix):])
    if len(body) < 65 + 12 + 16:
        raise ValueError("a sealed value too short to hold anything")
    eph = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), body[:65])
    key = HKDF(algorithm=hashes.SHA256(), length=32, salt=b"", info=info).derive(priv.exchange(ec.ECDH(), eph))
    return AESGCM(key).decrypt(body[65:77], body[77:], None)


class AtRest:
    """The relay's store encryption: AES-256-GCM under a key derived from the master, the record's own
    name as associated data, so a ciphertext moved to another record does not open."""

    def __init__(self, master):
        self.key = _hkdf(master, b"at-rest")

    def seal(self, name, data):
        iv = os.urandom(12)
        return iv + AESGCM(self.key).encrypt(iv, data, name.encode())

    def open(self, name, blob):
        return AESGCM(self.key).decrypt(blob[:12], blob[12:], name.encode())


def digest_hex(envelope):
    """The digest the owner authorises on the chain: SHA-256 of the envelope's text, which the owner's
    browser computes over what it sent and the relay over what it received."""
    return hashlib.sha256(envelope.encode()).hexdigest()
