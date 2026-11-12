"""The relay's tests, as the gate runs them: a count of tests run (zero is red: a run that found no
test says nothing), then RELAY GREEN.

Run from the repository root: python3 mailrelay/tests/run.py

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import io, os, sys, unittest, warnings

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, ROOT)
warnings.simplefilter("ignore")


def main():
    suite = unittest.defaultTestLoader.loadTestsFromName("mailrelay.tests.test_relay")
    stream = io.StringIO()
    result = unittest.TextTestRunner(stream=stream, verbosity=0).run(suite)
    print(f"count: relay tests run = {result.testsRun}")
    print(f"count: relay tests failed = {len(result.failures) + len(result.errors)}")
    for case, trace in result.failures + result.errors:
        print(f"RED {case.id()}\n{trace.strip().splitlines()[-1]}")
    if result.testsRun == 0 or not result.wasSuccessful():
        sys.exit(1)
    print("RELAY GREEN")


if __name__ == "__main__":
    main()
