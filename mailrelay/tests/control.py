"""The relay tests' control: each fault the tests claim to catch, injected into a copy of the relay, and
caught by the test that names it. A fault caught by some other test is a miss (red for the wrong reason);
an injection that changes nothing is CONTROL BROKEN; the unchanged copy must be green first.

Run from the repository root: python3 mailrelay/tests/control.py

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import os, shutil, subprocess, sys, tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

# (file, text, replacement, what the fault is, the test that must catch it)
CASES = [
    ("relay.py", 'if rec["state"] in ("sent", "sending"):', 'if False:', "a message already sent is sent again", "test_a_repeat_sends_once"),
    ("relay.py", 'if rec["state"] in ("sent", "sending"):', 'if rec["state"] == "sent":', "a send cut short is sent again", "test_a_send_cut_short_is_never_repeated"),
    ("relay.py", 'self.clock() < rec["last"] + BACKOFF.get(attempts, 0)', 'False', "a failure retried at once", "test_failures_back_off_then_fail"),
    ("providers/smtp.py", '            if not s.has_extn("starttls"):\n', '            if False:\n', None, None),   # paired with the next: STARTTLS made optional
    ("providers/smtp.py", '            s.starttls(context=ctx)\n            s.ehlo()', '            if s.has_extn("starttls"):\n                s.starttls(context=ctx)\n                s.ehlo()',
     "a password sent where the server offers no TLS", "test_no_starttls_never_sends_the_password"),
    ("providers/smtp.py", "if not net.public_host(host):", "if False:", "an SMTP host on a private network", "test_private_host_and_odd_port_refused_before_connecting"),
    ("relay.py", 'if setup["authorised"] != digest:', 'if False:', "a test email for an account the owner did not authorise", "test_routes"),
    ("relay.py", "if not providers.plain_address(to):", "if False:", "an address carrying a header line", "test_unreadable_address"),
    ("providers/base.py", '        return "signIn"\n    if status == 429', '        return "rejected"\n    if status == 429', "a refused key read as a refused message", "test_sendgrid"),
    ("store.py", "AND digest != ? ORDER BY", "AND digest != 'x' || ? ORDER BY", "a flood pushes out the authorised account", "test_a_flood_never_pushes_out_the_authorised_credential"),
    ("dnscheck.py", "    if not p.SPF_ROOT:\n        return {\"state\": \"pass\", \"found\": [found]", "    if False:\n        return {\"state\": \"pass\", \"found\": [found]",
     "an API provider's correct domain marked wrong", "test_records"),
    ("messages.py", ' dir="rtl"', ' dir="ltr"', "an Arabic message laid out left to right", "test_en_and_ar_delivered"),
    ("relay.py", '"provider": credential["provider"], "from": credential["from"]}\n\n    def test(', '**credential}\n\n    def test(',
     "the console's account line handing out the credential", "test_routes"),
]


def run(tree):
    r = subprocess.run([sys.executable, "-W", "ignore", "-m", "unittest", "mailrelay.tests.test_relay"], cwd=tree, capture_output=True, text=True, timeout=600)
    failed = {l.split()[1] for l in r.stderr.splitlines() if l.startswith(("FAIL:", "ERROR:"))}
    return r.returncode, failed


def main():
    work = tempfile.mkdtemp(prefix="relay-control-")
    try:
        def fresh():
            tree = os.path.join(work, "t")
            shutil.rmtree(tree, ignore_errors=True)
            shutil.copytree(os.path.join(ROOT, "mailrelay"), os.path.join(tree, "mailrelay"), ignore=shutil.ignore_patterns("__pycache__"))
            shutil.copytree(os.path.join(ROOT, "tools"), os.path.join(tree, "tools"), ignore=shutil.ignore_patterns("__pycache__"))
            os.makedirs(os.path.join(tree, "frontend", "src", "api"))             # the page's sealing code, for the browser-seal test
            shutil.copy(os.path.join(ROOT, "frontend", "src", "api", "keys.ts"), os.path.join(tree, "frontend", "src", "api", "keys.ts"))
            return tree
        code, failed = run(fresh())
        if code != 0:
            print(f"CONTROL BROKEN: the unchanged relay is red ({', '.join(sorted(failed))})")
            sys.exit(1)
        missed = broken = caught = 0
        pending = []
        for f, old, new, label, test in CASES:
            pending.append((f, old, new))
            if label is None:
                continue
            tree = fresh()
            for pf, pold, pnew in pending:
                p = os.path.join(tree, "mailrelay", pf)
                s = open(p).read()
                if s.count(pold) != 1:
                    print(f"CONTROL BROKEN: {label}: the text to change is in {pf} {s.count(pold)} times, not once")
                    broken += 1
                    break
                open(p, "w").write(s.replace(pold, pnew))
            else:
                code, failed = run(tree)
                if code != 0 and test in failed:
                    caught += 1
                    print(f"caught: {label} ({test})")
                elif code != 0:
                    missed += 1
                    print(f"MISSED: {label}: red, but not in {test} ({', '.join(sorted(failed))})")
                else:
                    missed += 1
                    print(f"MISSED: {label}: every test stayed green")
            pending = []
        print(f"count: faults injected = {caught + missed + broken}")
        print(f"count: caught by their own test = {caught}")
        if missed or broken or caught == 0:
            sys.exit(1)
        print("RELAY CONTROL GREEN")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
