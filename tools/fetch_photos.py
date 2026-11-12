#!/usr/bin/env python3
"""Fetch the demo properties' photographs from Unsplash, under the Unsplash License only.

Unsplash+ images are a different, paid licence, so every result marked `premium` or `plus` is
skipped. Each photograph is saved at 480, 960 and 1600 px wide as WebP (and a 1600 px JPEG, which is
also the master the smaller files are made from); a property's hero is saved as AVIF too, the one place
the page offers it (see frontend/src/components/Img.tsx, avif). Its photographer is recorded in
`frontend/public/media/credits.json`,
from which tools/notice.py writes NOTICE. Photographs of people are skipped: the rooms should read as rooms.

Run: python3 tools/fetch_photos.py            (idempotent: an existing slot is kept)
     python3 tools/fetch_photos.py --avif     (writes the heroes' AVIF files from their masters, removes any other AVIF)

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import io, json, os, sys, time, urllib.parse, urllib.request
from PIL import Image

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(HERE, "frontend", "public", "media")
CREDITS = os.path.join(OUT, "credits.json")
WIDTHS = (480, 960, 1600)
PEOPLE = ("woman", "man ", "men ", "person", "people", "couple", "girl", "boy", "guest", "child", "massage")

# slot -> (query, how many)
SLOTS = {
    "almar/hero": ("mediterranean cove pine trees turquoise water", 1),
    "almar/bay": ("quiet bay clear water rocks mediterranean", 1),
    "almar/terrace": ("restaurant terrace tables sea view", 1),
    "almar/pool": ("infinity pool above the sea", 1),
    "almar/garden-room": ("minimal hotel bedroom linen natural light interior", 3),
    "almar/sea-room": ("hotel bedroom window sea view interior white linen", 3),
    "almar/junior-suite": ("hotel suite sitting area sea view", 3),
    "almar/pool-suite": ("private pool villa terrace sun loungers", 3),
    "almar/terrace-suite": ("hotel suite terrace sunset sea loungers", 3),
    "almar/bay-villa": ("villa living room sea view interior", 3),
    "karnak/hero": ("luxor nile sunset felucca", 1),
    "karnak/courtyard": ("egyptian courtyard arches limestone", 1),
    "karnak/nile-room": ("hotel room arched window warm wood interior", 3),
    "karnak/courtyard-room": ("boutique hotel room arches warm light", 3),
    "karnak/river-suite": ("luxury hotel suite bedroom warm lighting interior", 3),
}

UA = {"User-Agent": "curl/8.5.0", "Accept": "application/json"}


def get(url, accept_json=True):
    """GET with a patient backoff: Unsplash answers 429 when asked too quickly."""
    import urllib.error
    for attempt in range(6):
        req = urllib.request.Request(url, headers=UA if accept_json else {"User-Agent": UA["User-Agent"]})
        try:
            with urllib.request.urlopen(req, timeout=40) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code != 429 or attempt == 5:
                raise
            time.sleep(20 * (attempt + 1))


def search(query, page=1):
    q = urllib.parse.quote(query)
    return json.loads(get(f"https://unsplash.com/napi/search/photos?query={q}&per_page=30&page={page}&orientation=landscape"))["results"]


def usable(r, taken):
    if r.get("premium") or r.get("plus"):
        return False
    if r["id"] in taken or r["width"] < r["height"] or r["width"] < 2400:
        return False
    alt = ((r.get("alt_description") or "") + " " + (r.get("description") or "")).lower()
    return not any(w in alt for w in PEOPLE)


from seed import tenants   # the properties' data, read from the frontend's own tenants.ts

AVIF_QUALITY = 50   # matched by eye against the WebP at 78 on the most detailed photograph (almar/bay-1): as sharp, a third smaller


def hero_slots():
    """The slot-and-index of each property's hero photograph, e.g. almar/bay-1."""
    return {t["hero"]["slot"] for t in tenants().values()}


def variants(img, name, formats=("webp",)):
    """The page's files for one photograph, at each width."""
    for w in WIDTHS:
        small = img.resize((w, round(img.height * w / img.width)), Image.LANCZOS)
        if "webp" in formats:
            small.save(f"{name}-{w}.webp", "WEBP", quality=78, method=6)
        if "avif" in formats:
            small.save(f"{name}-{w}.avif", "AVIF", quality=AVIF_QUALITY, speed=4)


def save(r, slot, index):
    base = os.path.join(OUT, slot)
    os.makedirs(os.path.dirname(base), exist_ok=True)
    name = f"{base}-{index}"
    raw = r["urls"]["raw"]
    data = get(raw + ("&" if "?" in raw else "?") + "w=1600&q=82&fm=jpg&fit=max", accept_json=False)
    img = Image.open(io.BytesIO(data)).convert("RGB")
    img.save(name + "-1600.jpg", "JPEG", quality=82, optimize=True, progressive=True)
    variants(img, name, ("webp", "avif") if f"{slot}-{index}" in hero_slots() else ("webp",))
    # a tiny blurred preview, inlined by the page while the real bytes arrive
    tiny = img.resize((16, max(1, round(img.height * 16 / img.width))), Image.LANCZOS)
    buf = io.BytesIO(); tiny.save(buf, "WEBP", quality=40)
    import base64
    return {
        "slot": slot, "index": index, "id": r["id"], "width": 1600, "height": round(img.height * 1600 / img.width),
        "alt": r.get("alt_description") or "", "photographer": r["user"]["name"], "username": r["user"]["username"],
        "link": f"https://unsplash.com/photos/{r['id']}", "lqip": "data:image/webp;base64," + base64.b64encode(buf.getvalue()).decode(),
        "licence": "Unsplash License",
    }


REJECTED = os.path.join(OUT, "rejected.json")


def avif_from_masters():
    """The heroes' AVIF files, from each one's 1600 px master; AVIF of any other photograph is removed,
    because the page never asks for it."""
    heroes, written, removed = hero_slots(), 0, 0
    for c in json.load(open(CREDITS)):
        key = f"{c['slot']}-{c['index']}"
        name = os.path.join(OUT, key)
        if key in heroes:
            variants(Image.open(name + "-1600.jpg").convert("RGB"), name, formats=("avif",))
            written += 1
        else:
            for w in WIDTHS:
                if os.path.exists(f"{name}-{w}.avif"):
                    os.remove(f"{name}-{w}.avif"); removed += 1
    print(f"AVIF written for {written} heroes ({', '.join(sorted(heroes))}); {removed} other AVIF files removed")


def main():
    """`--redo slot,slot` drops those slots and records their photographs as rejected, so a new
    search cannot pick them again; the art direction is a person's eye, and this is how it is kept."""
    os.makedirs(OUT, exist_ok=True)
    if "--avif" in sys.argv:
        return avif_from_masters()
    credits = json.load(open(CREDITS)) if os.path.exists(CREDITS) else []
    rejected = set(json.load(open(REJECTED))) if os.path.exists(REJECTED) else set()
    if len(sys.argv) > 2 and sys.argv[1] == "--redo":
        redo = set(sys.argv[2].split(","))
        for c in credits:
            if c["slot"] in redo or f"{c['slot']}-{c['index']}" in redo:
                rejected.add(c["id"])
                for f in os.listdir(os.path.join(OUT, os.path.dirname(c["slot"]))):
                    if f.startswith(os.path.basename(c["slot"]) + f"-{c['index']}-"):
                        os.remove(os.path.join(OUT, os.path.dirname(c["slot"]), f))
        credits = [c for c in credits if c["id"] not in rejected]
        json.dump(sorted(rejected), open(REJECTED, "w"), indent=1)
    have = {(c["slot"], c["index"]) for c in credits}
    taken = {c["id"] for c in credits} | rejected
    for slot, (query, n) in SLOTS.items():
        want = [i for i in range(1, n + 1) if (slot, i) not in have]
        if not want:
            continue
        page = 1
        while want and page <= 3:
            for r in search(query, page):
                if not want:
                    break
                if usable(r, taken):
                    i = want.pop(0)
                    try:
                        credits.append(save(r, slot, i)); taken.add(r["id"])
                        json.dump(credits, open(CREDITS, "w"), indent=1, ensure_ascii=False)
                        print(f"{slot}-{i}: {r['id']} by {r['user']['name']}")
                    except Exception as e:  # a failed download leaves the slot for the next run
                        print(f"{slot}-{i}: {r['id']} failed ({e})", file=sys.stderr); want.insert(0, i)
                    time.sleep(1.5)
            page += 1
        if want:
            print(f"{slot}: {len(want)} slot(s) still empty", file=sys.stderr)
    credits.sort(key=lambda c: (c["slot"], c["index"]))
    json.dump(credits, open(CREDITS, "w"), indent=1, ensure_ascii=False)
    print(f"{len(credits)} photographs recorded in {CREDITS}")


if __name__ == "__main__":
    main()
