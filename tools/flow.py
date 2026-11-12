#!/usr/bin/env python3
"""Walk the guest flow in a real browser and photograph every step: home, results, room, details,
payment (TEST card), confirmation, manage, cancel. Fails loudly on a console error or a step that
does not arrive. Also photographs the rates calendar.

  python3 tools/flow.py --base http://127.0.0.1:5174 --out shots/flow --width 1440 --lang en --mode light --tenant almar

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import argparse, os, sys
from playwright.sync_api import sync_playwright


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:5174")
    ap.add_argument("--out", default="shots/flow")
    ap.add_argument("--width", type=int, default=1440)
    ap.add_argument("--lang", default="en")
    ap.add_argument("--mode", default="light")
    ap.add_argument("--tenant", default="almar")
    ap.add_argument("--full", action="store_true")
    ap.add_argument("--arrival", help="search this arrival (YYYY-MM-DD, one night) instead of the home page's default dates")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    errors = []
    tag = f"{a.tenant}-{a.lang}-{a.mode}-{a.width}"
    with sync_playwright() as p:
        b = p.chromium.launch()
        ctx = b.new_context(viewport={"width": a.width, "height": 844 if a.width < 800 else 900}, device_scale_factor=2 if a.width < 800 else 1)
        ctx.add_init_script(f"try{{sessionStorage.setItem('luxor:tenant','{a.tenant}');localStorage.setItem('luxor:lang','{a.lang}');localStorage.setItem('luxor:mode','{a.mode}')}}catch(e){{}}")
        page = ctx.new_page()
        page.on("console", lambda m: m.type == "error" and errors.append(m.text))
        page.on("pageerror", lambda e: errors.append(str(e)))

        def shot(name):
            page.wait_for_timeout(900)
            page.screenshot(path=os.path.join(a.out, f"{tag}-{name}.png"), full_page=a.full)

        page.goto(f"{a.base}/#/"); shot("1-home")
        if a.arrival:
            page.goto(f"{a.base}/#/rooms?in={a.arrival}&n=1&a=2&c=0&r=1")
        else:
            page.locator("form button[type=submit]").first.click()
        page.wait_for_url("**#/rooms?**"); page.wait_for_selector("text=/\\d/", timeout=8000); shot("2-results")
        page.locator("li button:has-text('" + ("Choose" if a.lang == "en" else "اختر") + "')").first.click()
        page.wait_for_url("**#/rooms/**"); shot("3-room")
        page.locator("button:has-text('" + ("Reserve" if a.lang == "en" else "احجز") + "')").first.click()
        page.wait_for_url("**#/book/details", timeout=60000); shot("4-details")
        page.fill("#name", "Salma Farouk" if a.lang == "en" else "سلمى فاروق")
        page.fill("#email", "salma@example.com")
        page.locator("form button[type=submit]").click()
        page.wait_for_url("**#/book/payment", timeout=60000); shot("5-payment")
        page.fill("#card", "4242 4242 4242 4242"); page.fill("#exp", "12/29"); page.fill("#cvc", "123")
        page.locator("form button[type=submit]").click()
        page.wait_for_url("**#/book/done", timeout=120000); shot("6-confirmation")
        page.locator("a[href*='manage/']").first.click()
        page.wait_for_url("**#/manage/**"); shot("7-manage")
        page.locator("button:has-text('" + ("Cancel this booking" if a.lang == "en" else "ألغِ هذا الحجز") + "')").click()
        page.wait_for_timeout(300); shot("8-cancel-ask")
        page.locator("button:has-text('" + ("Yes, cancel it" if a.lang == "en" else "نعم، ألغِه") + "')").click()
        page.wait_for_timeout(900); shot("9-cancelled")
        page.goto(f"{a.base}/#/console/rates")
        # the console either shows the grid with a row for each room type or says plainly that it is for staff
        try:
            page.wait_for_function("() => document.querySelectorAll('table[role=grid] tbody tr').length > 0 || !!document.querySelector('[data-staff-only]')", timeout=30000)
        except Exception:
            errors.append("rates: neither grid rows nor the staff-only notice appeared")
        page.wait_for_timeout(400); shot("10-rates")
        b.close()
    if errors:
        print("console errors:", *errors[:8], sep="\n  ")
        sys.exit(1)
    print(f"flow {tag}: 10 steps, no console errors")


if __name__ == "__main__":
    main()
