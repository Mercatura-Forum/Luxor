#!/usr/bin/env python3
"""Compare two builds of the frontend page by page: the same pages and the same interactions, in English
and Arabic, at 1440 and 390 px, on the demo property (whose data is fixed for a day). For each state it
compares the page's text exactly and its pixels closely. A page that says something different, or
looks different beyond anti-aliasing, is reported with where it differs.

  python3 tools/compare_builds.py --a http://127.0.0.1:5181 --b http://127.0.0.1:5182 --out <dir>

A state matches when its visible text is identical and at most --tolerance of its pixels differ by more
than a small threshold. Motion is reduced in both, so a transition caught mid-way cannot pass for a
difference.

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import argparse, os, sys
from PIL import Image, ImageChops
from playwright.sync_api import sync_playwright

ap = argparse.ArgumentParser()
ap.add_argument("--a", required=True, help="the reference build's address")
ap.add_argument("--b", required=True, help="the build under test")
ap.add_argument("--out", required=True)
ap.add_argument("--tenant", default="karnak")
ap.add_argument("--tolerance", type=float, default=0.002, help="the share of pixels that may differ")
ap.add_argument("--only", default="", help="compare only the states whose names start with this")
ap.add_argument("--repeat", type=int, default=1, help="compare each state this many times")
a = ap.parse_args()
os.makedirs(a.out, exist_ok=True)

def open_picker(pg):
    pg.locator("form button").first.click(); pg.wait_for_timeout(600)

def type_in_rates(pg):
    pg.wait_for_selector("table[role=grid] tbody tr")
    pg.locator('[data-cell$="-2-rooms"]').first.focus(); pg.keyboard.press("5"); pg.wait_for_selector("[data-quick-bar] input"); pg.wait_for_timeout(500)

def open_booking(pg):
    pg.wait_for_selector("tbody tr td button")
    pg.locator("tbody tr td button").first.click(); pg.wait_for_selector("[role=dialog] table"); pg.wait_for_timeout(500)

# each state with what it looks like when it is ready: a page is captured once that is on screen
STATES = [
    ("home", "#/", None, "main h1"), ("home-picker", "#/", open_picker, "[role=dialog]"), ("results", "#/rooms", None, "main h2"),
    ("room", "#/rooms/1", None, "main h1"), ("rates", "#/console/rates", None, "td[data-cell]"), ("rates-typed", "#/console/rates", type_in_rates, "[data-quick-bar] input"),
    ("bookings", "#/console/bookings", None, "tbody tr td button"), ("booking-detail", "#/console/bookings", open_booking, "[role=dialog] table"),
    ("today", "#/console", None, "main h1"), ("audit", "#/console/audit", None, "main h1"), ("approvals", "#/console/approvals", None, "main h1"),
    ("stays", "#/stays", None, "main h1"), ("not-found", "#/no-such-page", None, "main h1"),
]

def settle(pg, timeout_ms=20000):
    """Wait until the page has finished arriving: the app has drawn its main area, no loading skeleton is
    left, and the page's height, text and skeleton count hold still across four readings. A fixed pause
    passes or fails with the machine's load, not the page; so does a check made before the app has
    drawn anything, when there is no skeleton yet either."""
    pg.wait_for_selector("#main", timeout=timeout_ms)
    last, still = None, 0
    for _ in range(timeout_ms // 250):
        now = pg.evaluate("() => [document.documentElement.scrollHeight, document.body.innerText.length, document.querySelectorAll('.skeleton').length].join('/')")
        still = still + 1 if now == last else 0
        if still >= 4 and now.endswith("/0"):
            return
        last = now
        pg.wait_for_timeout(250)
    raise TimeoutError("the page did not settle")


def capture(p, base, name, route, act, ready, lang, width, path):
    b = p.chromium.launch()
    ctx = b.new_context(viewport={"width": width, "height": 900}, reduced_motion="reduce", device_scale_factor=1)
    ctx.add_init_script(f"try{{sessionStorage.setItem('luxor:tenant','{a.tenant}');localStorage.setItem('luxor:lang','{lang}');localStorage.setItem('luxor:mode','light')}}catch(e){{}}")
    # a record, from the page's first moment, of every time loading skeletons appear after content did
    ctx.add_init_script("""window.__trace = []; (() => { let content = false, t0 = performance.now();
      const tick = () => { const sk = document.querySelectorAll('.skeleton').length; const main = document.querySelector('#main');
        if (sk === 0 && main && main.innerText.length > 200) content = true;
        if (content && sk > 0) { window.__trace.push(Math.round(performance.now() - t0) + 'ms: ' + sk + ' skeletons after content'); content = false }
        requestAnimationFrame(tick) }; requestAnimationFrame(tick) })()""")
    pg = ctx.new_page()
    errors = []
    pg.on("pageerror", lambda e: errors.append(str(e)))
    pg.on("console", lambda m: m.type == "error" and errors.append(m.text))
    pg.goto(base + "/" + route, wait_until="networkidle")
    settle(pg)
    if act:
        act(pg)
    pg.wait_for_selector(ready, timeout=20000)
    # an interaction starts its own loading (a panel's placeholders while its data arrives); what must
    # not happen is content going back to loading once the state has arrived, so the trace starts here
    if act:
        pg.evaluate("() => { window.__trace = [] }")
    settle(pg)
    text = pg.evaluate("() => document.body.innerText")
    trace = pg.evaluate("() => window.__trace")
    if trace:
        errors.append("content went back to loading: " + "; ".join(trace))
    # what a person sees: the whole page, or with a dialog open the viewport it covers. A dialog locks the
    # page's scrolling, and a full-page capture taken then photographs an empty page nobody sees.
    pg.screenshot(path=path, full_page=pg.locator("[role=dialog]").count() == 0)
    b.close()
    return text, errors

def diff(p1, p2, out):
    i1, i2 = Image.open(p1).convert("RGB"), Image.open(p2).convert("RGB")
    if i1.size != i2.size:
        return 1.0, f"sizes differ: {i1.size} and {i2.size}"
    d = ImageChops.difference(i1, i2).convert("L").point(lambda v: 255 if v > 24 else 0)
    n = d.histogram()[255]
    share = n / (i1.size[0] * i1.size[1])
    if n:
        box = d.getbbox()
        d.save(out)
        return share, f"{n} pixels differ, within {box}"
    return 0.0, ""

failed = 0
total = 0
with sync_playwright() as p:
    for name, route, act, ready in [x for x in STATES if x[0].startswith(a.only)] * a.repeat:
        for lang in ("en", "ar"):
            for width in (1440, 390):
                total += 1
                tag = f"{name}-{lang}-{width}"
                pa, pb = os.path.join(a.out, f"{tag}-a.png"), os.path.join(a.out, f"{tag}-b.png")
                try:
                    ta, ea = capture(p, a.a, name, route, act, ready, lang, width, pa)
                    tb, eb = capture(p, a.b, name, route, act, ready, lang, width, pb)
                except Exception as e:
                    failed += 1; print(f"FAIL {tag}: could not drive the page: {str(e)[:160]}"); continue
                share, where = diff(pa, pb, os.path.join(a.out, f"{tag}-diff.png"))
                problems = []
                if ta != tb:
                    la, lb = ta.splitlines(), tb.splitlines()
                    first = next((i for i in range(max(len(la), len(lb))) if i >= len(la) or i >= len(lb) or la[i] != lb[i]), None)
                    problems.append(f"text differs at line {first}: {la[first] if first is not None and first < len(la) else '∅'!r} / {lb[first] if first is not None and first < len(lb) else '∅'!r}")
                if share > a.tolerance:
                    problems.append(f"{share:.4%} of pixels differ ({where})")
                if eb and not ea:
                    problems.append(f"errors only in the build under test: {eb[:2]}")
                if ea and not eb:
                    problems.append(f"errors only in the reference: {ea[:2]}")
                if problems:
                    failed += 1; print(f"FAIL {tag}: " + "; ".join(problems))
                else:
                    print(f"ok   {tag}" + (f" ({share:.4%} of pixels, anti-aliasing)" if share else ""))
print(f"\n{total - failed} of {total} states match")
sys.exit(1 if failed else 0)
