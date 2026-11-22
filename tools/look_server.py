"""Studio receiver for the LOOK button.

    py tools/look_server.py            (from the repo folder)

- Listens on the home network (port 8765) and announces itself over Bonjour
  as "_skyelook._tcp", so the apps find it without an address.
- POST /look with JSON {kind, app, note, info, time, jpeg(base64)}:
    kind "look": saved to field-tests/inbox/<time>-<app>.jpg + .json
    kind "live": frames kept in field-tests/inbox/live-<app>-<session>/, latest also as live-<app>.jpg
    kind "liveend": <time>-<app>-live.json naming the session folder
- GET /ping answers "ok".
Only addresses on the local network are accepted. Stdlib only.
"""
import base64, datetime, http.server, ipaddress, json, os, pathlib, shutil, subprocess, sys

PORT = 8765
ROOT = pathlib.Path(__file__).resolve().parent.parent
INBOX = ROOT / "field-tests" / "inbox"
INBOX.mkdir(parents=True, exist_ok=True)
MAX_BYTES = 20 * 1024 * 1024


def write(path, data):
    tmp = path.with_name(path.name + ".part")
    tmp.write_bytes(data)
    os.replace(tmp, path)


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
        kind = msg.get("kind") if msg.get("kind") in ("look", "live", "liveend") else "live"
        app = safe(msg.get("app"))
        jpeg = msg.pop("jpeg", None)
        msg["received"] = datetime.datetime.now().isoformat(timespec="seconds")
        now = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        if kind == "live":
            session = safe(msg.get("session") or "", 32)
            if jpeg:
                raw = base64.b64decode(jpeg)
                write(INBOX / f"live-{app}.jpg", raw)
                if session:
                    folder = INBOX / f"live-{app}-{session}"
                    folder.mkdir(exist_ok=True)
                    seq = int(msg.get("seq") or 0)
                    write(folder / f"{seq:05d}.jpg", raw)
                    with open(folder / "frames.jsonl", "a", encoding="utf-8") as f:
                        f.write(json.dumps({"seq": seq, "time": msg.get("time"), "info": msg.get("info")}) + "\n")
            write(INBOX / f"live-{app}.json", json.dumps(msg, indent=1).encode())
        elif kind == "liveend":
            session = safe(msg.get("session") or "", 32)
            msg["folder"] = str(INBOX / f"live-{app}-{session}")
            write(INBOX / f"{now}-{app}-live.json", json.dumps(msg, indent=1).encode())
            print(f"LIVE ended from {app}: {msg.get('frames')} frames -> {msg['folder']}", flush=True)
        else:
            stem = f"{now}-{app}"
            if jpeg:
                write(INBOX / (stem + ".jpg"), base64.b64decode(jpeg))
                msg["image"] = stem + ".jpg"
            write(INBOX / (stem + ".json"), json.dumps(msg, indent=1).encode())
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
