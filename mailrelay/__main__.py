"""python3 -m mailrelay <command> --config relay.json

  init               make the master secret (once; 32 random bytes, readable by its owner only)
  key --contract N   a hotel's public keys: what its owner gives setMailRelay (the console fetches the same)
  pass               one pass over every hotel, printed
  serve              the HTTP API and the pull, until stopped

The configuration (JSON):
  chain_base       the gateway the relay calls, e.g. https://<gateway>
  master_file      the master secret's path
  db               the SQLite file
  listen           host:port of the HTTP API (put it behind TLS)
  public_url       the API's public https address (the OAuth callback is public_url + /v1/oauth/callback)
  return_origins   the console origins a sign-in may return to
  oauth            {"google": {"client_id", "client_secret"}, "microsoft": {...}}; a provider left out has no sign-in
  poll_seconds     the pause between passes (default 60)
  trust_proxy      true behind a reverse proxy that sets X-Forwarded-For

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import argparse, json, logging, os, secrets, sys

from .keys import AtRest, Keys
from .providers.base import Net
from .relay import Relay, serve
from .store import Store


def master(path):
    with open(path, "rb") as f:
        m = f.read()
    if len(m) != 32:
        sys.exit(f"{path} is not a 32-byte master secret")
    return m


def build(cfg):
    m = master(cfg["master_file"])
    return Relay(m, Store(cfg["db"], AtRest(m)), Net(oauth=cfg.get("oauth", {})), chain_base=cfg["chain_base"], public_url=cfg.get("public_url", ""),
                 return_origins=cfg.get("return_origins", []))


def main(argv=None):
    ap = argparse.ArgumentParser(prog="mailrelay")
    ap.add_argument("command", choices=["init", "key", "pass", "serve"])
    ap.add_argument("--config", required=True)
    ap.add_argument("--contract", type=int)
    a = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    with open(a.config) as f:
        cfg = json.load(f)
    if a.command == "init":
        if os.path.exists(cfg["master_file"]):
            sys.exit(f"{cfg['master_file']} exists: a new master would change every hotel's keys")
        fd = os.open(cfg["master_file"], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(secrets.token_bytes(32))
        print("master secret written; keep a copy offline: without it no hotel's mail key opens")
        return
    if a.command == "key":
        if not a.contract:
            sys.exit("--contract is needed")
        print(json.dumps(Keys(master(cfg["master_file"]), a.contract).public(), indent=2))
        return
    relay = build(cfg)
    if a.command == "pass":
        print(json.dumps(relay.pass_once(), indent=2))
        return
    host, _, port = cfg.get("listen", "127.0.0.1:8740").rpartition(":")
    serve(relay, host, int(port), int(cfg.get("poll_seconds", 60)), bool(cfg.get("trust_proxy")))


if __name__ == "__main__":
    main()
