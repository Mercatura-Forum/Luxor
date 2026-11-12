/**
 * The keys a guest's browser holds, with WebCrypto: a P-256 key per hold and a P-256 manage key per
 * booking. The contract stores only the compressed public half; the private half stays in this
 * browser (a hold key in session storage) or in the guest's manage link, after the '#', which a
 * browser never sends to any server. Signatures are raw r ‖ s over SHA-256, as the contract checks.
 *
 * The guest's email is sealed to the hotel's guest-data key (ECIES: an ephemeral P-256 key, ECDH,
 * HKDF-SHA-256, AES-GCM), so the contract stores ciphertext and never the address.
 */

const b64u = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
const unb64u = (s: string) => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4)), (c) => c.charCodeAt(0))
export const hex = (b: Uint8Array) => [...b].map((x) => x.toString(16).padStart(2, '0')).join('')
export const unhex = (h: string) => Uint8Array.from(h.match(/../g) ?? [], (x) => parseInt(x, 16))

export interface KeyPair { jwk: JsonWebKey; publicHex: string }

function compress(raw: Uint8Array): Uint8Array {
  // raw is 0x04 ‖ x(32) ‖ y(32); the compressed form is (0x02 | y parity) ‖ x
  const out = new Uint8Array(33)
  out[0] = 0x02 | (raw[64] & 1)
  out.set(raw.slice(1, 33), 1)
  return out
}

export async function newKey(): Promise<KeyPair> {
  const k = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])
  const raw = new Uint8Array(await crypto.subtle.exportKey('raw', k.publicKey))
  const jwk = await crypto.subtle.exportKey('jwk', k.privateKey)
  return { jwk, publicHex: hex(compress(raw)) }
}

export async function sign(jwk: JsonWebKey, message: string): Promise<string> {
  const key = await crypto.subtle.importKey('jwk', jwk, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign'])
  const sig = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(message)))
  return hex(sig)
}

/** A manage key as the link carries it: d.x.y, base64url. */
export function linkSecret(jwk: JsonWebKey): string { return `${jwk.d}.${jwk.x}.${jwk.y}` }

export function jwkFromSecret(secret: string): JsonWebKey | null {
  const [d, x, y] = secret.split('.')
  if (!d || !x || !y) return null
  return { kty: 'EC', crv: 'P-256', d, x, y, ext: true }
}

export function publicHexOf(jwk: JsonWebKey): string {
  const raw = new Uint8Array(65)
  raw[0] = 4
  raw.set(unb64u(jwk.x!), 1)
  raw.set(unb64u(jwk.y!), 33)
  return hex(compress(raw))
}

/** Seal text to the hotel's guest-data key: "lxe1." ‖ ephemeral public (raw) ‖ iv ‖ ciphertext, base64url.
 *  A guest's address for their emails is sealed the same way to the mail relay's mail key, which only the
 *  relay can open (never the hotel's guest-data key: the relay does not hold it). */
export async function seal(text: string, hotelKeyRawHex: string, info = 'LUXOR-GUEST-DATA-v1', prefix = 'lxe1.'): Promise<string> {
  const hotel = await crypto.subtle.importKey('raw', unhex(hotelKeyRawHex), { name: 'ECDH', namedCurve: 'P-256' }, false, [])
  const eph = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits'])
  const shared = await crypto.subtle.deriveBits({ name: 'ECDH', public: hotel }, eph.privateKey, 256)
  const ikm = await crypto.subtle.importKey('raw', shared, 'HKDF', false, ['deriveKey'])
  const aes = await crypto.subtle.deriveKey({ name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(0), info: new TextEncoder().encode(info) }, ikm, { name: 'AES-GCM', length: 256 }, false, ['encrypt'])
  const iv = crypto.getRandomValues(new Uint8Array(12))
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, aes, new TextEncoder().encode(text)))
  const ephRaw = new Uint8Array(await crypto.subtle.exportKey('raw', eph.publicKey))
  const body = new Uint8Array(ephRaw.length + iv.length + ct.length)
  body.set(ephRaw, 0); body.set(iv, ephRaw.length); body.set(ct, ephRaw.length + iv.length)
  return prefix + b64u(body)
}

/** The hotel's email credential sealed to the relay's transport key ("lxc1."): it travels only from this
 *  browser to the relay, never to the chain. */
export function sealCredential(json: string, transportKeyHex: string): Promise<string> {
  return seal(json, transportKeyHex, 'LUXOR-MAIL-CREDENTIAL-v1', 'lxc1.')
}

/** SHA-256 of a text, hex: the digest of a sealed value, as the contract and the relay compute it. */
export async function sha256Hex(text: string): Promise<string> {
  return hex(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))))
}

/** Open a sealed text with the hotel's private guest-data key (on a staff device). */
export async function open(envelope: string, hotelPrivate: JsonWebKey): Promise<string> {
  if (!envelope.startsWith('lxe1.')) throw new Error('not a sealed value')
  const body = unb64u(envelope.slice(5))
  const eph = await crypto.subtle.importKey('raw', body.slice(0, 65), { name: 'ECDH', namedCurve: 'P-256' }, false, [])
  const priv = await crypto.subtle.importKey('jwk', hotelPrivate, { name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits'])
  const shared = await crypto.subtle.deriveBits({ name: 'ECDH', public: eph }, priv, 256)
  const ikm = await crypto.subtle.importKey('raw', shared, 'HKDF', false, ['deriveKey'])
  const aes = await crypto.subtle.deriveKey({ name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(0), info: new TextEncoder().encode('LUXOR-GUEST-DATA-v1') }, ikm, { name: 'AES-GCM', length: 256 }, false, ['decrypt'])
  const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: body.slice(65, 77) }, aes, body.slice(77))
  return new TextDecoder().decode(pt)
}

/**
 * Encrypt a file for the hotel: a fresh AES-GCM key per file, the ciphertext kept by the contract,
 * and the key itself sealed to the hotel's guest-data key. Destroying the sealed key erases the file.
 */
export async function sealFile(plain: Uint8Array, hotelKeyRawHex: string): Promise<{ ciphertext: Uint8Array; fileKey: string; plainHash: string }> {
  const key = crypto.getRandomValues(new Uint8Array(32))
  const iv = crypto.getRandomValues(new Uint8Array(12))
  const aes = await crypto.subtle.importKey('raw', key, 'AES-GCM', false, ['encrypt'])
  const ciphertext = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, aes, plain))
  const plainHash = hex(new Uint8Array(await crypto.subtle.digest('SHA-256', plain)))
  return { ciphertext, fileKey: await seal(`${hex(key)}.${hex(iv)}`, hotelKeyRawHex), plainHash }
}

export async function openFile(ciphertext: Uint8Array, fileKey: string, hotelPrivate: JsonWebKey): Promise<Uint8Array> {
  const [k, iv] = (await open(fileKey, hotelPrivate)).split('.')
  const aes = await crypto.subtle.importKey('raw', unhex(k), 'AES-GCM', false, ['decrypt'])
  return new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: unhex(iv) }, aes, ciphertext))
}

/** The kernel's chunk fingerprint: SHA-256 of (len16 ‖ domain ‖ bytes), hex. */
export async function chunkHash(bytes: Uint8Array): Promise<string> {
  const domain = new TextEncoder().encode('THEBES-EVIDENCE-CHUNK-v1')
  const buf = new Uint8Array(2 + domain.length + bytes.length)
  buf[0] = domain.length >> 8; buf[1] = domain.length & 0xff
  buf.set(domain, 2); buf.set(bytes, 2 + domain.length)
  return hex(new Uint8Array(await crypto.subtle.digest('SHA-256', buf)))
}
