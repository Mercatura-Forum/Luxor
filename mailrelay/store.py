"""The relay's own records, in one SQLite file:

  credentials  each hotel's email credential as the owner's browser (or the provider's OAuth answer) gave
               it, encrypted at rest, under the digest the owner authorises on the chain. One hotel may have
               a few on file while its owner changes accounts; only the one whose digest the chain names is
               ever used, and older ones are dropped past the last five.
  sends        one row per (contract, outbox id): the idempotency record. A message is marked `sending`
               before the provider is called and `sent` once it answers, so a repeated pass, a restart or a
               lost reply from the chain never sends it twice.
  hotels       the digest each hotel's chain last named, so a flood of credentials posted for a hotel can
               never push out the one its owner authorised.
  oauth        the state of a sign-in with Google or Microsoft in progress (PKCE verifier, where to return).

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import json, sqlite3, threading, time

KEEP_CREDENTIALS = 5
OAUTH_TTL = 900   # a sign-in not finished in fifteen minutes is forgotten


class Store:
    def __init__(self, path, at_rest):
        self.db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.lock = threading.Lock()
        self.at_rest = at_rest
        self.db.executescript("""
          CREATE TABLE IF NOT EXISTS credentials (contract INTEGER, digest TEXT, sealed BLOB, created REAL, PRIMARY KEY (contract, digest));
          CREATE TABLE IF NOT EXISTS sends (contract INTEGER, outbox INTEGER, state TEXT, attempts INTEGER, last REAL, provider_id TEXT,
                                            failure TEXT, recorded INTEGER, PRIMARY KEY (contract, outbox));
          CREATE TABLE IF NOT EXISTS oauth (state TEXT PRIMARY KEY, record BLOB, created REAL);
          CREATE TABLE IF NOT EXISTS hotels (contract INTEGER PRIMARY KEY, authorised TEXT);
        """)

    # ── credentials ──
    def put_credential(self, contract, digest, credential):
        """`credential` is the decoded dict; it is stored encrypted under its record name."""
        blob = self.at_rest.seal(f"credential/{contract}/{digest}", json.dumps(credential, sort_keys=True).encode())
        with self.lock:
            self.db.execute("INSERT OR REPLACE INTO credentials VALUES (?, ?, ?, ?)", (int(contract), digest, blob, time.time()))
            # the one the chain names is never dropped, however many are posted after it
            old = self.db.execute("SELECT digest FROM credentials WHERE contract = ? AND digest != ? ORDER BY created DESC LIMIT -1 OFFSET ?",
                                  (int(contract), self.authorised(contract), KEEP_CREDENTIALS)).fetchall()
            for (d,) in old:
                self.db.execute("DELETE FROM credentials WHERE contract = ? AND digest = ?", (int(contract), d))

    def credential(self, contract, digest):
        row = self.db.execute("SELECT sealed FROM credentials WHERE contract = ? AND digest = ?", (int(contract), digest)).fetchone()
        if row is None:
            return None
        return json.loads(self.at_rest.open(f"credential/{contract}/{digest}", row[0]))

    def update_credential(self, contract, digest, credential):
        """A credential's own fields refreshed in place (an OAuth access token), under the same digest."""
        blob = self.at_rest.seal(f"credential/{contract}/{digest}", json.dumps(credential, sort_keys=True).encode())
        with self.lock:
            self.db.execute("UPDATE credentials SET sealed = ? WHERE contract = ? AND digest = ?", (blob, int(contract), digest))

    def authorised(self, contract):
        r = self.db.execute("SELECT authorised FROM hotels WHERE contract = ?", (int(contract),)).fetchone()
        return r[0] if r else ""

    def set_authorised(self, contract, digest):
        """The digest the chain names for this hotel, as last read: its credential is kept."""
        with self.lock:
            self.db.execute("INSERT OR REPLACE INTO hotels VALUES (?, ?)", (int(contract), digest))

    def contracts(self):
        return [c for (c,) in self.db.execute("SELECT DISTINCT contract FROM credentials ORDER BY contract")]

    # ── sends ──
    def send_of(self, contract, outbox):
        r = self.db.execute("SELECT state, attempts, last, provider_id, failure, recorded FROM sends WHERE contract = ? AND outbox = ?", (int(contract), int(outbox))).fetchone()
        return None if r is None else dict(zip(("state", "attempts", "last", "provider_id", "failure", "recorded"), r))

    def mark(self, contract, outbox, state, attempts, provider_id="", failure="", recorded=0, now=None):
        with self.lock:
            self.db.execute("INSERT OR REPLACE INTO sends VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                            (int(contract), int(outbox), state, int(attempts), time.time() if now is None else now, provider_id, failure, int(recorded)))

    def mark_recorded(self, contract, outbox):
        with self.lock:
            self.db.execute("UPDATE sends SET recorded = 1 WHERE contract = ? AND outbox = ?", (int(contract), int(outbox)))

    # ── OAuth sign-ins in progress ──
    def put_oauth(self, state, record):
        with self.lock:
            self.db.execute("DELETE FROM oauth WHERE created < ?", (time.time() - OAUTH_TTL,))
            self.db.execute("INSERT INTO oauth VALUES (?, ?, ?)", (state, self.at_rest.seal(f"oauth/{state}", json.dumps(record).encode()), time.time()))

    def take_oauth(self, state):
        """The sign-in's record, once: a state is used at most once and never after it expires."""
        with self.lock:
            row = self.db.execute("SELECT record, created FROM oauth WHERE state = ?", (state,)).fetchone()
            self.db.execute("DELETE FROM oauth WHERE state = ?", (state,))
        if row is None or row[1] < time.time() - OAUTH_TTL:
            return None
        return json.loads(self.at_rest.open(f"oauth/{state}", row[0]))
