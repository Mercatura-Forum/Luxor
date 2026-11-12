// The page's own sealing code (frontend/src/api/keys.ts), run by Node: an address sealed to a mail key,
// a credential sealed to a transport key, and the digest the page computes over the credential envelope.
// test_relay.py opens both with the relay's keys. Attribution: Thebes Core Team. Licence: Apache 2.0.
import { seal, sealCredential, sha256Hex } from '../../frontend/src/api/keys.ts'

const [mailKey, transportKey, address, credential] = process.argv.slice(2)
const sealedAddress = await seal(address, mailKey)
const sealedCredential = await sealCredential(credential, transportKey)
console.log(JSON.stringify({ sealedAddress, sealedCredential, digest: await sha256Hex(sealedCredential) }))
