"""Wait for the next LOOK from the phone, print it, and exit.

    py tools/look_wait.py

Ignores "live-" frames; only a new <time>-<app>.json counts.
"""
import json, pathlib, sys, time

INBOX = pathlib.Path(__file__).resolve().parent.parent / "field-tests" / "inbox"
INBOX.mkdir(parents=True, exist_ok=True)
seen = {p.name for p in INBOX.glob("*.json")}
while True:
    new = sorted(p for p in INBOX.glob("*.json") if p.name not in seen and not p.name.startswith("live-"))
    if new:
        for p in new:
            msg = json.loads(p.read_text(encoding="utf-8"))
            print(json.dumps({"file": str(p), "image": str(INBOX / msg.get("image", "")) if msg.get("image") else None,
                              "note": msg.get("note"), "app": msg.get("app"), "kind": msg.get("kind"),
                              "folder": msg.get("folder"), "frames": msg.get("frames"), "info": msg.get("info")}, indent=1))
        sys.exit(0)
    time.sleep(1)
