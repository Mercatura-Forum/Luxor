#!/usr/bin/env python3
"""Write NOTICE: the dependencies this tree is built with, the third-party material the built page ships,
and a credit for every photograph, read from frontend/public/media/credits.json.

  python3 tools/notice.py            writes NOTICE
  python3 tools/notice.py --check    exits 1 if NOTICE is not what this script writes

Attribution: Thebes Core Team. Licence: Apache 2.0."""
import json, os, sys
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
credits = json.load(open(os.path.join(HERE, "frontend/public/media/credits.json")))
kernel = open(os.path.join(HERE, "deps/KERNEL_PIN")).read().split()[0]
lib = open(os.path.join(HERE, "deps/THEBES_LIB_PIN")).read().split()
sdk = json.load(open(os.path.join(HERE, "frontend/package.json")))["dependencies"]["@thebes/sdk"]
lines = [
    "Luxor",
    "Copyright 2026 Thebes Core Team. Licensed under the Apache License, Version 2.0 (see LICENSE).",
    "",
    "Dependencies",
    "------------",
    f"The Thebes Domain Kernel, commit {kernel} (deps/KERNEL_PIN; see vendor/thebes-kernel/README.md).",
    f"src/vendor/MemphisAuth.mo: copied unchanged from thebes-lib commit {lib[1]}, {lib[2]}",
    "  (deps/THEBES_LIB_PIN), https://github.com/Mercatura-Forum/thebes-lib, Apache License 2.0.",
    f"The Thebes SDK (@thebes/sdk), {sdk} (frontend/package.json),",
    "  https://github.com/Mercatura-Forum/thebes-sdk, Apache License 2.0. Its runtime includes the",
    "  unmodified @noble/ed25519 3.1.0 (MIT License, (c) 2019 Paul Miller), which the page serves beside",
    "  the SDK's runtime for a browser without WebCrypto Ed25519.",
    "src/Sign.mo: the P-256 field and curve arithmetic after the kernel's sig/P256.mo; the nonce per",
    "  RFC 6979, HMAC per RFC 2104, checked against the RFC 6979 and RFC 4231 test vectors.",
    "src/Eta.mo: the credit note's shape and serialisation as the Egyptian Tax Authority's e-invoicing",
    "  SDK specification states them, after Mentat's EtaDocument.mo (https://github.com/Mercatura-Forum/Mentat).",
    "",
    "Fonts",
    "-----",
    "The page bundles Marcellus, Mulish, Reem Kufi and Cairo from the @fontsource packages, each under the",
    "SIL Open Font License 1.1 (https://openfontlicense.org).",
    "",
    "Photographs",
    "-----------",
    "The demo properties' photographs are from Unsplash, used under the Unsplash License",
    "(https://unsplash.com/license). They are served from this product's own assets and never",
    "hot-linked. Each is credited below by slot, photographer and source page.",
    "",
]
for c in credits:
    lines.append(f"  {c['slot']}-{c['index']}: {c['photographer']} (@{c['username']}), {c['link']}")
text = "\n".join(lines) + "\n"
path = os.path.join(HERE, "NOTICE")
if "--check" in sys.argv:
    same = os.path.exists(path) and open(path).read() == text
    print("NOTICE is current" if same else "NOTICE differs from what tools/notice.py writes")
    sys.exit(0 if same else 1)
open(path, "w").write(text)
print(f"NOTICE: {len(credits)} photographs credited")
