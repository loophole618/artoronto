"""Copy the newest photos off the iPhone, over Wi-Fi or USB, into field-tests/ (never pushed).

    phone_photos.py                   newest 5 photos and videos
    phone_photos.py --last 20
    phone_photos.py --since 2h        everything shot in the last 2 hours
    phone_photos.py --since "2026-11-28 09:30"
    phone_photos.py --list            names and times only, copies nothing

HEIC photos also get a .jpg beside them so anyone can open them. Read-only on the phone:
Apple's media file service (AFC) only reaches the camera roll and app imports.

Needs (Windows, once):
    py -m venv %USERPROFILE%\\.venvs\\pmd3
    %USERPROFILE%\\.venvs\\pmd3\\Scripts\\pip install pymobiledevice3 pillow pillow-heif
Run it with that venv's python. The phone must be paired with this PC (trusted over USB once)
and, for Wi-Fi, have Wi-Fi connections on (`pymobiledevice3 lockdown wifi-connections on`
over USB) and Private Wi-Fi Address OFF for the home network, so its Bonjour name carries the
MAC the pairing record expects. Bonjour is found with Apple's `dns-sd` (comes with Bonjour).
"""
import argparse
import asyncio
import datetime as dt
import glob
import os
import plistlib
import re
import subprocess
import sys
import time

from pymobiledevice3.lockdown import create_using_tcp, create_using_usbmux
from pymobiledevice3.services.afc import AfcService

async def aw(x):
    """pymobiledevice3 calls are async in some versions and plain in others."""
    return await x if asyncio.iscoroutine(x) or asyncio.isfuture(x) else x


REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCKDOWN = r"C:\ProgramData\Apple\Lockdown"
SKIP = {".AAE"}
VIDEO = {".MOV", ".MP4"}


def dns_sd(args, seconds):
    """Run Apple's dns-sd for a few seconds (it never exits by itself) and return its output."""
    p = subprocess.Popen(["dns-sd", *args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    time.sleep(seconds)
    p.kill()
    out, _ = p.communicate()
    return out or ""


def pair_records():
    """{wifi mac: (udid, record)} from the pairing records Windows keeps."""
    found = {}
    for path in glob.glob(os.path.join(LOCKDOWN, "*.plist")):
        try:
            with open(path, "rb") as f:
                rec = plistlib.load(f)
        except Exception:
            continue
        mac = rec.get("WiFiMACAddress")
        if mac and "HostPrivateKey" in rec:
            found[mac.lower()] = (os.path.splitext(os.path.basename(path))[0], rec)
    return found


def find_on_wifi(udid=None):
    """Find a paired phone on the network: Bonjour name 'mac@...' -> pairing record -> IPv4."""
    records = pair_records()
    browse = dns_sd(["-B", "_apple-mobdev2._tcp", "local"], 4)
    for name in re.findall(r"_apple-mobdev2\._tcp\.\s+(\S+)", browse):
        mac = name.split("@")[0].lower()
        if mac not in records or (udid and records[mac][0] != udid):
            continue
        found = re.search(r"can be reached at (\S+?)\.?:\d+", dns_sd(["-L", name, "_apple-mobdev2._tcp", "local"], 3))
        if not found:
            continue
        host = found.group(1)
        v4 = re.search(r"\s(\d+\.\d+\.\d+\.\d+)\s", dns_sd(["-G", "v4", host], 3))
        if v4:
            return v4.group(1), records[mac][0], records[mac][1]
    return None


async def connect(args):
    if not args.host:
        try:
            ld = await create_using_usbmux(serial=args.udid, autopair=False)
            return ld, "USB"
        except Exception:
            pass
    if args.host:
        udid = args.udid
        rec = None
        if udid and os.path.exists(os.path.join(LOCKDOWN, udid + ".plist")):
            with open(os.path.join(LOCKDOWN, udid + ".plist"), "rb") as f:
                rec = plistlib.load(f)
        host = args.host
    else:
        hit = find_on_wifi(args.udid)
        if not hit:
            sys.exit("No phone found over USB or Wi-Fi. Is it awake on the home Wi-Fi? (If it was seen before, "
                     "turn its Wi-Fi off and on.)")
        host, udid, rec = hit
    ld = await create_using_tcp(hostname=host, identifier=udid, pair_record=rec, autopair=False)
    return ld, f"Wi-Fi {host}"


def mtime(st):
    t = st.get("st_mtime") or st.get("st_birthtime")
    if isinstance(t, dt.datetime):
        return t.astimezone() if t.tzinfo else t
    if isinstance(t, (int, float)):
        return dt.datetime.fromtimestamp(t / 1e9 if t > 1e12 else t).astimezone()
    return None


def number(name):
    m = re.search(r"(\d+)", name)
    return int(m.group(1)) if m else -1


def parse_since(text):
    m = re.fullmatch(r"(\d+(?:\.\d+)?)\s*([mhd])", text.strip())
    if m:
        unit = {"m": "minutes", "h": "hours", "d": "days"}[m.group(2)]
        return dt.datetime.now().astimezone() - dt.timedelta(**{unit: float(m.group(1))})
    return dt.datetime.fromisoformat(text).astimezone()


def to_jpg(path):
    try:
        import pillow_heif
        from PIL import Image
        pillow_heif.register_heif_opener()
        out = os.path.splitext(path)[0] + ".jpg"
        with Image.open(path) as im:
            exif = im.info.get("exif")
            im.convert("RGB").save(out, "JPEG", quality=90, **({"exif": exif} if exif else {}))
        return out
    except Exception as e:
        print(f"  (no jpg for {os.path.basename(path)}: {e})")
        return None


async def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--last", type=int, default=5, help="newest N files (default 5)")
    ap.add_argument("--since", help="'2h', '30m', '1d' or a date-time; overrides --last")
    ap.add_argument("--list", action="store_true", help="only list, copy nothing")
    ap.add_argument("--no-video", action="store_true", help="skip .MOV / .MP4")
    ap.add_argument("--out", help="folder (default field-tests/<today>)")
    ap.add_argument("--host", help="phone IP, to skip Bonjour")
    ap.add_argument("--udid", help="which phone, if several are paired")
    args = ap.parse_args()
    since = parse_since(args.since) if args.since else None

    ld, how = await connect(args)
    afc = AfcService(ld)
    info = await aw(ld.all_values() if callable(ld.all_values) else ld.all_values)
    print(f"connected: {info.get('DeviceName')} over {how}")

    picked = []
    folders = sorted((d for d in await aw(afc.listdir("/DCIM")) if re.fullmatch(r"\d+\w*", d)), key=number, reverse=True)
    done = False
    for folder in folders:
        names = [n for n in await aw(afc.listdir(f"/DCIM/{folder}")) if n not in (".", "..")]
        for name in sorted(names, key=lambda n: (number(n), n), reverse=True):
            ext = os.path.splitext(name)[1].upper()
            if ext in SKIP or (args.no_video and ext in VIDEO):
                continue
            path = f"/DCIM/{folder}/{name}"
            st = await aw(afc.stat(path))
            t = mtime(st)
            if since and t and t < since:
                done = True
                break
            picked.append((path, name, t, int(st.get("st_size", 0))))
            if not since and len(picked) >= args.last:
                done = True
                break
        if done:
            break

    picked.reverse()
    if args.list or not picked:
        for path, name, t, size in picked:
            print(f"  {name:16} {t:%Y-%m-%d %H:%M:%S}  {size / 1e6:6.1f} MB" if t else f"  {name}")
        if not picked:
            print("nothing matched")
        return

    out = args.out or os.path.join(REPO, "field-tests", dt.date.today().isoformat())
    os.makedirs(out, exist_ok=True)
    for path, name, t, size in picked:
        dest = os.path.join(out, name)
        if not (os.path.exists(dest) and os.path.getsize(dest) == size):
            with open(dest, "wb") as f:
                f.write(await aw(afc.get_file_contents(path)))
        view = dest
        if name.upper().endswith(".HEIC"):
            view = to_jpg(dest) or dest
        print(f"  {t:%H:%M:%S}  {view}" if t else f"  {view}")
    print(f"{len(picked)} file(s) in {out}")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except (TimeoutError, ConnectionError, OSError) as e:
        # The phone's Wi-Fi dozes; one more go picks up where it stopped (finished files are skipped).
        print(f"connection dropped ({type(e).__name__}), trying once more…")
        asyncio.run(main())
