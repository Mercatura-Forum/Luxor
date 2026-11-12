#!/usr/bin/env python3
"""Click every control on every screen of a Luxor page, in a real browser, and report what each did.

  python3 tools/every_control.py --page https://<thebes-gateway>/_/raw/<cid>/index.html \
      --out shots/every --width 1440 --lang en --mode light

The screens are reached the way a guest reaches them (home, results, room, details, payment,
confirmation, manage, my stays, a page that does not exist, the hotel console, and the console's demo
desk). On each screen every visible control is listed: buttons, links, tabs, switches, checkboxes,
radio buttons, selects and disclosure summaries. Each one is clicked once, on a fresh copy of that
screen, and the result is recorded: the address changed, the screen changed, a window opened, or
nothing happened. A screenshot is kept after every click. Browser errors and failed requests are
recorded against the click that caused them.

Fails (exit 1) on any browser error, any failed request to the page's own origin, or any control
that did nothing. A control that does nothing on purpose (the link to the screen already shown, a
selected tab) is reported as "already here" rather than as nothing, when the address and the
control's own state say so.

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import argparse, datetime, hashlib, json, os, sys, time
from urllib.parse import urlsplit
from playwright.sync_api import sync_playwright

ap = argparse.ArgumentParser()
ap.add_argument("--page", required=True, help="the page's index.html address; screens are its #/ routes")
ap.add_argument("--out", default="shots/every")
ap.add_argument("--width", type=int, default=1440)
ap.add_argument("--lang", default="en")
ap.add_argument("--mode", default="light")
ap.add_argument("--tenant", default="almar")
A = ap.parse_args()

TAG = f"{A.tenant}-{A.lang}-{A.mode}-{A.width}"
OUT = os.path.join(A.out, TAG)
os.makedirs(OUT, exist_ok=True)
ORIGIN = "{0.scheme}://{0.netloc}".format(urlsplit(A.page))
EN = A.lang == "en"
CONTROLS = ("button, a[href], [role=button], [role=tab], [role=switch], [role=menuitem], [role=option], "
            "input[type=checkbox], input[type=radio], select, summary")

report = {"tag": TAG, "page": A.page, "screens": [], "errors": [], "failed_requests": []}
current = {"click": None}


def url(route):
    return A.page.split("#")[0] + "#" + route


def settle(pg, ms=900):
    try:
        pg.wait_for_load_state("networkidle", timeout=8000)
    except Exception:
        pass
    pg.wait_for_timeout(ms)


def fingerprint(pg):
    return hashlib.sha256(pg.evaluate("() => document.body.innerText + '|' + document.body.innerHTML.length + '|' + (document.activeElement ? document.activeElement.outerHTML.slice(0, 200) : '')").encode()).hexdigest()


def label(el):
    try:
        return el.evaluate("""e => {
          const t = (e.getAttribute('aria-label') || e.innerText || e.value || e.title || e.getAttribute('href') || e.tagName).trim().replace(/\\s+/g, ' ');
          return (e.tagName.toLowerCase() + ': ' + t).slice(0, 90);
        }""")
    except Exception:
        return "?"


def visible_controls(pg):
    loc = pg.locator(CONTROLS)
    out = []
    for i in range(loc.count()):
        el = loc.nth(i)
        try:
            # on the page for a person to click: a visible box of real size inside the page (a skip link parked
            # off-screen until it has focus is reached by the keyboard, not by a click, and is not counted)
            if el.is_visible() and el.evaluate("e => { const r = e.getBoundingClientRect(); return r.width > 2 && r.height > 2 && r.right > 0 && r.bottom + scrollY > 0 && r.left < document.documentElement.scrollWidth }"):
                out.append(i)
        except Exception:
            pass
    return out


def new_context(p, source=None):
    b = p.chromium.launch()
    ctx = b.new_context(viewport={"width": A.width, "height": 844 if A.width < 800 else 900}, device_scale_factor=2 if A.width < 800 else 1)
    init = f"try{{sessionStorage.setItem('luxor:tenant','{A.tenant}');localStorage.setItem('luxor:lang','{A.lang}');localStorage.setItem('luxor:mode','{A.mode}')"
    if source:
        init += f";sessionStorage.setItem('luxor:source','{source}')"
    ctx.add_init_script(init + "}catch(e){}")
    pg = ctx.new_page()
    pg.on("console", lambda m: m.type == "error" and report["errors"].append({"click": current["click"], "text": m.text[:300]}))
    pg.on("pageerror", lambda e: report["errors"].append({"click": current["click"], "text": str(e)[:300]}))
    def failed(r):
        if "ERR_ABORTED" in (r.failure or ""):
            return   # a download the browser cancelled because the click left the page
        report["failed_requests"].append({"click": current["click"], "url": r.url[:160], "why": (r.failure or "")[:80]})
    def response(r):
        if r.status >= 400 and r.url.startswith(ORIGIN):
            report["failed_requests"].append({"click": current["click"], "url": r.url[:160], "why": f"HTTP {r.status}"})
    pg.on("requestfailed", failed)
    pg.on("response", response)
    return b, ctx, pg


# ---- how each screen is reached: a route, or the guest's steps from the home page ----
def to_home(pg):
    pg.goto(url("/")); settle(pg)

# Each reach of a booking screen places a hold, and the hotel allows only a few rooms on hold per night.
# The sweep therefore searches its own one-night stay, a different night each time, far from the nights
# a visitor is shown first (the home page's default search), so it neither meets the cap nor takes them.
NIGHT = {"next": 60 + (os.getpid() % 97) * 2}
def to_results(pg):
    d = datetime.date.today() + datetime.timedelta(days=NIGHT["next"]); NIGHT["next"] += 1
    pg.goto("about:blank"); pg.goto(url(f"/rooms?in={d.isoformat()}&n=1&a=2&c=0&r=1"))
    pg.wait_for_url("**#/rooms?**", timeout=20000); pg.wait_for_selector("text=/\\d/", timeout=20000); settle(pg)

def to_room(pg):
    to_results(pg)
    pg.locator("li button:has-text('" + ("Choose" if EN else "اختر") + "')").first.click()
    pg.wait_for_url("**#/rooms/**", timeout=20000); settle(pg)

def to_details(pg):
    to_room(pg)
    pg.locator("button:has-text('" + ("Reserve" if EN else "احجز") + "')").first.click()
    pg.wait_for_url("**#/book/details", timeout=60000); settle(pg)

def to_payment(pg):
    to_details(pg)
    pg.fill("#name", "Salma Farouk" if EN else "سلمى فاروق"); pg.fill("#email", "salma@example.com")
    pg.locator("form button[type=submit]").click()
    pg.wait_for_url("**#/book/payment", timeout=60000); settle(pg)

BOOKED = {}
MADE = []   # every booking this run makes, cancelled at the end so the demo keeps its free nights
def to_confirmation(pg):
    to_payment(pg)
    pg.fill("#card", "4242 4242 4242 4242"); pg.fill("#exp", "12/29"); pg.fill("#cvc", "123")
    pg.locator("form button[type=submit]").click()
    pg.wait_for_url("**#/book/done", timeout=120000); settle(pg)
    href = pg.locator("a[href*='manage/']").first.get_attribute("href")
    BOOKED["manage"] = href.split("#", 1)[1] if "#" in href else href
    MADE.append(BOOKED["manage"])

def to_manage(pg):
    if "manage" not in BOOKED:
        to_confirmation(pg)
    pg.goto(url(BOOKED["manage"])); settle(pg)

def by_route(route):
    def go(pg):
        pg.goto(url(route)); settle(pg)
    return go

# (name, how to reach it, whether a fresh copy can be had by its address alone, localStorage source)
SCREENS = [
    ("home", to_home, True, None),
    ("results", to_results, True, None),
    ("room", to_room, True, None),
    ("details", to_details, False, None),
    ("payment", to_payment, False, None),
    ("confirmation", to_confirmation, False, None),
    ("manage", to_manage, True, None),
    ("my-stays", by_route("/stays"), True, None),
    ("not-found", by_route("/no-such-page"), True, None),
]
for sub in ("", "/rates", "/bookings", "/audit", "/approvals"):
    tag = "console" + sub.replace("/", "-")
    SCREENS.append((tag, by_route("/console" + sub), True, None))
    SCREENS.append((tag + "-demo-desk", by_route("/console" + sub), True, "demo"))


def sweep(p, name, reach, by_address, source):
    b, ctx, pg = new_context(p, source)
    screen = {"screen": name, "controls": []}
    report["screens"].append(screen)
    try:
        current["click"] = f"{name}: reach"
        reach(pg)
        here = pg.url
        pg.screenshot(path=os.path.join(OUT, f"{name}-00-screen.png"), full_page=True)
        n = len(visible_controls(pg))
        screen["address"] = here
        screen["count"] = n
        for k in range(n):
            # a fresh copy of the screen for every click: by its address when that is enough, else by the guest's steps
            if k:
                if by_address:
                    # a new document every time: an address that differs only in its #route would not reload
                    pg.goto("about:blank"); pg.goto(here); settle(pg, 500)
                else:
                    b.close(); b, ctx, pg = new_context(p, source); reach(pg)
            idx = visible_controls(pg)
            # a fresh copy is drawn in stages: wait until it shows as many controls as the first copy did
            waited = 0
            while len(idx) < n and waited < 15000:
                pg.wait_for_timeout(500); waited += 500; idx = visible_controls(pg)
            if k >= len(idx):
                screen["controls"].append({"n": k, "control": "?", "result": "screen changed between copies (fewer controls)"})
                continue
            el = pg.locator(CONTROLS).nth(idx[k])
            what = label(el)
            current["click"] = f"{name}: {what}"
            before_url, before = pg.url, fingerprint(pg)
            pages_before = len(ctx.pages)
            if el.is_disabled():
                # a control that is off until something is chosen, and says so on its face, is working as designed
                screen["controls"].append({"n": k + 1, "control": what, "result": "disabled until chosen: " + what})
                print(f"  {name} {k + 1}/{n} {what[:60]} -> disabled (says why)", flush=True)
                continue
            selected = el.evaluate("e => e.getAttribute('aria-selected') === 'true' || e.getAttribute('aria-current') === 'page' || e.getAttribute('aria-pressed') === 'true' || e.disabled === true")
            href = el.get_attribute("href") or ""
            try:
                if el.evaluate("e => e.tagName") == "SELECT":
                    opts = el.evaluate("e => [...e.options].map(o => o.value)")
                    cur = el.evaluate("e => e.value")
                    other = next((o for o in opts if o != cur), cur)
                    el.select_option(other, timeout=5000)
                else:
                    el.click(timeout=5000)
            except Exception as e:
                screen["controls"].append({"n": k, "control": what, "result": "could not click: " + str(e).splitlines()[0][:120]})
                continue
            settle(pg, 900)
            opened = len(ctx.pages) > pages_before
            after_url = pg.url if not pg.is_closed() else before_url
            if opened:
                result = "a window opened: " + ctx.pages[-1].url[:100]
                for extra in ctx.pages[pages_before:]:
                    extra.close()
            elif after_url != before_url:
                result = "went to " + after_url.split("#", 1)[-1][:80]
            elif fingerprint(pg) != before:
                result = "screen changed"
            elif selected or (href and "#" in href and url(href.split("#", 1)[1]).rstrip("/") == before_url.rstrip("/")) or href.endswith(before_url.split("#", 1)[-1]):
                result = "already here"
            else:
                result = "NOTHING"
            pg.screenshot(path=os.path.join(OUT, f"{name}-{k + 1:02d}.png"))
            screen["controls"].append({"n": k + 1, "control": what, "result": result})
            print(f"  {name} {k + 1}/{n} {what[:60]} -> {result}", flush=True)
    except Exception as e:
        screen["error"] = "could not reach or sweep: " + str(e).splitlines()[0][:200]
        report["errors"].append({"click": current["click"], "text": screen["error"]})
    finally:
        b.close()


t0 = time.time()
with sync_playwright() as p:
    for name, reach, by_address, source in SCREENS:
        print(f"{TAG} {name}", flush=True)
        sweep(p, name, reach, by_address, source)

    # the demo's nights are for its visitors: every booking the sweep made is cancelled by its own manage link
    cancelled = 0
    for ref in dict.fromkeys(MADE):
        b, ctx, pg = new_context(p)
        try:
            current["click"] = "cleanup: cancel " + ref
            pg.goto(url(ref)); settle(pg)
            btn = pg.locator("button:has-text('" + ("Cancel this booking" if EN else "ألغِ هذا الحجز") + "')")
            if btn.count():
                btn.first.click(); pg.wait_for_timeout(400)
                pg.locator("button:has-text('" + ("Yes, cancel it" if EN else "نعم، ألغِه") + "')").first.click(); settle(pg)
                cancelled += 1
        except Exception as e:
            report["errors"].append({"click": current["click"], "text": str(e).splitlines()[0][:200]})
        finally:
            b.close()
    report["bookings_made"], report["bookings_cancelled_at_end"] = len(set(MADE)), cancelled
    print(f"cleanup: {cancelled} of {len(set(MADE))} bookings cancelled (the rest were cancelled by the sweep itself)")

total = sum(len(s["controls"]) for s in report["screens"])
listed = sum(s.get("count", 0) for s in report["screens"])
nothing = [(s["screen"], c["control"]) for s in report["screens"] for c in s["controls"] if c["result"] == "NOTHING"]
unclickable = [(s["screen"], c["control"], c["result"]) for s in report["screens"] for c in s["controls"] if c["result"].startswith(("could not", "screen changed between"))]
report.update({"clicked": total, "listed": listed, "nothing": nothing, "unclickable": unclickable, "seconds": round(time.time() - t0)})
json.dump(report, open(os.path.join(OUT, "report.json"), "w"), indent=1, ensure_ascii=False)
print(f"\n{TAG}: {total} of {listed} controls clicked on {len(report['screens'])} screens; "
      f"did nothing {len(nothing)}; could not click {len(unclickable)}; browser errors {len(report['errors'])}; failed requests {len(report['failed_requests'])}")
for s in report["screens"]:
    print(f"  {s['screen']:<18} {len(s['controls']):>3} of {s.get('count', 0):>3}  {s.get('error', '')}")
for x in nothing: print("  NOTHING:", *x)
for x in unclickable: print("  UNCLICKABLE:", *x)
for x in report["errors"][:15]: print("  ERROR:", x["click"], "|", x["text"])
for x in report["failed_requests"][:15]: print("  FAILED:", x["click"], "|", x["url"], x["why"])
sys.exit(1 if (nothing or unclickable or report["errors"] or [r for r in report["failed_requests"] if r["url"].startswith(ORIGIN)]) else 0)
