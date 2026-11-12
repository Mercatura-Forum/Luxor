#!/usr/bin/env python3
"""Render Luxor's screens with Playwright: every route, at 390 and 1440 px, in each language, mode and
property asked for. The browser console is recorded beside each shot, so an error on a screen is seen
with the screen rather than guessed at.

  python3 tools/shoot.py --base http://127.0.0.1:5174 --out shots --routes "/,/rooms" \
      --widths 390,1440 --langs en,ar --modes light,dark --tenants almar

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import argparse, json, os
from playwright.sync_api import sync_playwright


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:5174")
    ap.add_argument("--out", default="shots")
    ap.add_argument("--routes", default="/")
    ap.add_argument("--widths", default="390,1440")
    ap.add_argument("--langs", default="en")
    ap.add_argument("--modes", default="light")
    ap.add_argument("--tenants", default="almar")
    ap.add_argument("--full", action="store_true")
    ap.add_argument("--wait", type=int, default=1200)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    log = {}
    with sync_playwright() as p:
        b = p.chromium.launch()
        for tenant in a.tenants.split(","):
            for lang in a.langs.split(","):
                for mode in a.modes.split(","):
                    for w in [int(x) for x in a.widths.split(",")]:
                        ctx = b.new_context(viewport={"width": w, "height": 844 if w < 800 else 900}, device_scale_factor=2 if w < 800 else 1)
                        ctx.add_init_script(f"sessionStorage.setItem('luxor:tenant','{tenant}');localStorage.setItem('luxor:lang','{lang}');localStorage.setItem('luxor:mode','{mode}');")
                        page = ctx.new_page()
                        msgs = []
                        page.on("console", lambda m: msgs.append(f"{m.type}: {m.text}"))
                        page.on("pageerror", lambda e: msgs.append(f"pageerror: {e}"))
                        for route in a.routes.split(","):
                            page.goto(f"{a.base}/#{route}")
                            page.wait_for_timeout(a.wait)
                            name = f"{tenant}-{lang}-{mode}-{w}-{route.strip('/').replace('/', '_').replace('?', '_') or 'home'}"[:120]
                            page.screenshot(path=os.path.join(a.out, name + ".png"), full_page=a.full)
                            log[name] = [m for m in msgs if not m.startswith("debug")]
                            msgs.clear()
                        ctx.close()
        b.close()
    json.dump(log, open(os.path.join(a.out, "console.json"), "w"), indent=1)
    bad = {k: v for k, v in log.items() if any(("error" in m) for m in v)}
    print(f"{len(log)} shots; {len(bad)} with console errors")
    for k, v in bad.items():
        print(k, v[:3])


if __name__ == "__main__":
    main()
