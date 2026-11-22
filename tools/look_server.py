"""Studio receiver for the LOOK button.

    py tools/look_server.py            (from the repo folder)

- Listens on the home network (port 8765) and announces itself over Bonjour
  as "_skyelook._tcp", so the apps find it without an address.
- POST /look with JSON {kind, app, note, info, time, jpeg(base64)}:
    kind "look": saved to field-tests/inbox/<time>-<app>.jpg + .json
    kind "live": overwrites field-tests/inbox/live-<app>.jpg + .json (just the latest frame)
- GET /ping answers "ok".
Only addresses on the local network are accepted. Stdlib only.
"""
import base64, datetime, http.server, ipaddress, json, os, pathlib, shutil, subprocess, sys

PORT = 8765
ROOT = pathlib.Path(__file__).resolve().parent.parent
INBOX = ROOT / "field-tests" / "inbox"
INBOX.mkdir(parents=True, exist_ok=True)
MAX_BYTES = 20 * 1024 * 1024


def safe(s, n=24):
    return "".join(c for c in str(s) if c.isalnum() or c in "-_")[:n] or "app"


class Handler(http.server.BaseHTTPRequestHandler):
    def _local(self):
        try:
            ip = ipaddress.ip_address(self.client_address[0])
            return ip.is_private or ip.is_loopback
        except ValueError:
            return False

    def _reply(self, code, text):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if not self._local():
            return self._reply(403, "local network only")
        self._reply(200, "ok")

    def do_POST(self):
        if not self._local() or self.path != "/look":
            return self._reply(403, "no")
        n = int(self.headers.get("Content-Length", 0))
        if n <= 0 or n > MAX_BYTES:
            return self._reply(413, "too big")
        try:
            msg = json.loads(self.rfile.read(n))
        except Exception:
            return self._reply(400, "bad json")
        kind = "look" if msg.get("kind") == "look" else "live"
        app = safe(msg.get("app"))
        jpeg = msg.pop("jpeg", None)
        msg["received"] = datetime.datetime.now().isoformat(timespec="seconds")
        if kind == "look":
            stem = datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + f"-{app}"
        else:
            stem = f"live-{app}"
        if jpeg:
            tmp = INBOX / (stem + ".jpg.part")
            tmp.write_bytes(base64.b64decode(jpeg))
            os.replace(tmp, INBOX / (stem + ".jpg"))
            msg["image"] = stem + ".jpg"
        tmp = INBOX / (stem + ".json.part")
        tmp.write_text(json.dumps(msg, indent=1), encoding="utf-8")
        os.replace(tmp, INBOX / (stem + ".json"))   # the .json lands last: the watcher keys on it
        if kind == "look":
            print(f"LOOK from {app}: {msg.get('note', '')!r} -> {stem}", flush=True)
        self._reply(200, "ok")

    def log_message(self, *a):
        pass


def main():
    bonjour = None
    dns_sd = shutil.which("dns-sd") or r"C:\Windows\System32\dns-sd.exe"
    if os.path.exists(dns_sd):
        bonjour = subprocess.Popen([dns_sd, "-R", "ARToronto studio", "_skyelook._tcp", "local", str(PORT)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"look server on :{PORT}, inbox {INBOX}, bonjour {'on' if bonjour else 'off'}", flush=True)
    try:
        http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
    finally:
        if bonjour:
            bonjour.terminate()


if __name__ == "__main__":
    sys.exit(main())
