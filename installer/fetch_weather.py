#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 itsAllexB
"""WeatherPad installer helper. Standard library only; run it with `python3 -I`.

Downloads only the parts of Apple's iPhone 5s (iPhone6,1) iOS 12.5.8 OTA update that hold
the Weather app and the WeatherUI animated-background resources, straight from Apple's
update server (HTTP range requests), and checks every file against the update's own
manifests; any mismatch stops the installer.

  fetch_weather.py fetch OUT_DIR [--no-backgrounds]   ->  OUT_DIR/Weather.app (as Apple ships it)
                                                         OUT_DIR/WeatherUI.framework
  fetch_weather.py patch-plist Weather.app/Info.plist  ->  adds the iPad keys
"""
import argparse, hashlib, lzma, os, plistlib, shutil, ssl, struct, subprocess, sys
import tempfile, time, urllib.error, urllib.request, zlib
from concurrent.futures import ThreadPoolExecutor

# ---- The one update we use ----------------------------------------------------------------
OTA_URL = ("https://updates.cdn-apple.com/2026WinterFCS/patches/047-28228/"
           "F1B6EC1E-0589-421A-A7A5-87BAB2301551/com_apple_MobileAsset_SoftwareUpdate/"
           "ea4b17b4dcce3b575a5fe732192256cf9adb81eb.zip")
OTA_SIZE = 2263797331
OTA_SHA1 = "27da4c2c30891deedaca7644ecbe57da8b3053df"  # Apple's "_Measurement" of the whole zip
CATALOG_URL = ("https://mesu.apple.com/assets/com_apple_MobileAsset_SoftwareUpdate/"
               "com_apple_MobileAsset_SoftwareUpdate.xml")
# SHA-256 of the zip members we read in full (Apple's own data, pinned so nothing else is used).
MEMBER_SHA256 = {
    "AssetData/post.bom": "e4969ae3a03e62d87c2cf0a4e86ba1031851a47e36777c0ce130b5d7c26c39de",
    "AssetData/payloadv2/app_patches/Weather.app": "a423d4d8b90e9fc4edbfc3f116baae77de6c97d50acb4ac3dd42a0d5924bce39",
}
WUI = "System/Library/PrivateFrameworks/WeatherUI.framework/"
# Where the WeatherUI files sit inside the payload chunks of this exact zip. Each run is
# (zip byte offset of its first pbzx block header, byte length, offset of the first entry in
# the run's decompressed data). Derived once by scanning the chunks; every file taken from
# them is checked against post.bom, so a stale table can only fail, never install bad files.
WUI_RUNS = [
    (891752358, 9319404, 5367887),  # payload.019, 2 pbzx blocks
    (810592697, 11615712, 3633948),  # payload.021, 2 pbzx blocks
    (1948679323, 8690036, 5024338),  # payload.022, 2 pbzx blocks
    (1519589184, 9301880, 7565000),  # payload.024, 2 pbzx blocks
    (1876094282, 4971700, 7433482),  # payload.025, 2 pbzx blocks
    (943148415, 2478960, 7698103),  # payload.026, 1 pbzx block
    (667266527, 2046712, 920807),  # payload.028, 1 pbzx block
    (2032727158, 1517244, 4205643),  # payload.031, 1 pbzx block
]
# SHA-256 over the sorted "sha1  path" lines of all 309 WeatherUI files.
WUI_TREE_SHA256 = "db9d6230f4c9a1f7c01aee3e4d7deb9da12e9243cc2b4a7f5f9b904642a24e5b"


def say(msg):
    print("  " + msg, flush=True)


def die(msg):
    sys.exit("error: " + msg)


def mb(n):
    return "%.1f MB" % (n / 1e6)


# ---- HTTP ---------------------------------------------------------------------------------
def _ssl_context():
    # python.org builds of Python ship without CA certificates; macOS has its own bundle.
    cafile = "/etc/ssl/cert.pem"
    return ssl.create_default_context(cafile=cafile if os.path.exists(cafile) else None)


class Remote:
    def __init__(self, url):
        self.url, self.ctx, self.fetched = url, _ssl_context(), 0

    def _open(self, headers=None, method="GET"):
        req = urllib.request.Request(self.url, headers=headers or {}, method=method)
        return urllib.request.urlopen(req, context=self.ctx, timeout=120)

    def size(self):
        with self._open(method="HEAD") as r:
            return int(r.headers.get("Content-Length", -1))

    def get(self, start, length):
        """Bytes [start, start+length) of the file, retried on network errors."""
        for attempt in range(5):
            try:
                with self._open({"Range": "bytes=%d-%d" % (start, start + length - 1)}) as r:
                    if r.status != 206:
                        raise IOError("server ignored the range request (HTTP %d)" % r.status)
                    data = r.read()
                if len(data) != length:
                    raise IOError("short read")
                self.fetched += length
                return data
            except (OSError, urllib.error.URLError) as e:
                if attempt == 4:
                    die("download failed: %s" % e)
                time.sleep(2 + 3 * attempt)


class RemoteZip:
    """Just enough of the zip format to read single members over HTTP."""

    def __init__(self, remote, size):
        self.r = remote
        tail = remote.get(size - 65536, 65536)
        eocd = tail.rfind(b"PK\x05\x06")
        if eocd < 0:
            die("not a zip file")
        cd_size, cd_off = struct.unpack_from("<II", tail, eocd + 12)
        cd = remote.get(cd_off, cd_size)
        self.members, p = {}, 0
        while cd[p:p + 4] == b"PK\x01\x02":
            method, _, _, crc, csize, usize, nlen, xlen, clen = struct.unpack_from("<HHHIIIHHH", cd, p + 10)
            (hdr_off,) = struct.unpack_from("<I", cd, p + 42)
            name = cd[p + 46:p + 46 + nlen].decode()
            self.members[name] = (method, crc, csize, usize, hdr_off)
            p += 46 + nlen + xlen + clen

    def data_offset(self, name):
        hdr_off = self.members[name][4]
        h = self.r.get(hdr_off, 30)
        nlen, xlen = struct.unpack_from("<HH", h, 26)
        return hdr_off + 30 + nlen + xlen

    def read(self, name):
        if name not in self.members:
            die("%s is missing from the update" % name)
        method, crc, csize, usize, _ = self.members[name]
        raw = self.r.get(self.data_offset(name), csize)
        data = raw if method == 0 else zlib.decompressobj(-15).decompress(raw)
        if len(data) != usize or zlib.crc32(data) != crc:
            die("%s failed its zip CRC check" % name)
        want = MEMBER_SHA256.get(name)
        if want and hashlib.sha256(data).hexdigest() != want:
            die("%s is not the expected file (SHA-256 mismatch)" % name)
        return data


def open_ota():
    """Find the update on Apple's server and make sure it is the one we expect."""
    url = OTA_URL
    try:
        size = Remote(url).size()
    except (OSError, urllib.error.URLError) as e:
        say("Apple's usual address did not answer (%s)." % e)
        size = -1
    if size != OTA_SIZE:
        say("Looking the update up in Apple's public update catalog ...")
        url = catalog_lookup()
        size = Remote(url).size()
        if size != OTA_SIZE:
            die("the update Apple lists has an unexpected size (%d bytes)" % size)
    z = RemoteZip(Remote(url), size)
    info = plistlib.loads(z.read("Info.plist")).get("MobileAssetProperties", {})
    if info.get("Build") != "16H88" or "iPhone6,1" not in info.get("SupportedDevices", []):
        die("this is not the iPhone 5s iOS 12.5.8 (16H88) update")
    return z


def catalog_lookup():
    """Search Apple's catalog for the same zip (same SHA-1), wherever Apple moved it."""
    remote = Remote(CATALOG_URL)
    with remote._open() as r:
        catalog = plistlib.loads(r.read())
    for a in catalog.get("Assets", []):
        m = a.get("_Measurement")
        m = m.hex() if isinstance(m, bytes) else str(m)
        if m == OTA_SHA1 and a.get("__BaseURL") and a.get("__RelativePath"):
            say("Found it in the catalog.")
            return a["__BaseURL"] + a["__RelativePath"]
    die("Apple no longer offers the iPhone 5s iOS 12.5.8 update (16H88), so the files "
        "can't be downloaded. Please open an issue on the WeatherPad repo.")


# ---- Formats ------------------------------------------------------------------------------
def pbzx_blocks(buf, p):
    """Decompress the pbzx blocks in buf[p:]: each is (u64 size, u64 stored size) + data."""
    while p < len(buf):
        usize, csize = struct.unpack_from(">QQ", buf, p)
        block = buf[p + 16:p + 16 + csize]
        p += 16 + csize
        if len(block) != csize:
            raise ValueError("truncated pbzx block")
        out = lzma.decompress(block) if block[:6] == b"\xfd7zXZ\x00" else bytes(block)
        if len(out) != usize:
            raise ValueError("pbzx block has the wrong size")
        yield out


YAA_FIXED = {"1": 1, "2": 2, "4": 4, "8": 8, "S": 8, "T": 12, "F": 4, "G": 20, "H": 32, "I": 48, "J": 64}
YAA_BLOB = {"A": 2, "B": 4, "C": 8}


def yaa_entries(buf):
    """List the entries of an Apple Archive (YAA1): dicts of fields plus 'blobs' sizes."""
    p, entries = 0, []
    while p < len(buf):
        if buf[p:p + 4] != b"YAA1":
            raise ValueError("bad Apple Archive header at %d" % p)
        (hsize,) = struct.unpack_from("<H", buf, p + 4)
        q, end, e, blobs = p + 6, p + hsize, {}, 0
        while q < end:
            key, kind = buf[q:q + 3].decode(), chr(buf[q + 3])
            q += 4
            if kind in YAA_FIXED:
                n = YAA_FIXED[kind]
                v = buf[q:q + n]
                e[key] = int.from_bytes(v, "little") if kind in "1248" else bytes(v)
                q += n
            elif kind == "P":
                (n,) = struct.unpack_from("<H", buf, q)
                e[key] = buf[q + 2:q + 2 + n].decode()
                q += 2 + n
            elif kind in YAA_BLOB:
                n = YAA_BLOB[kind]
                size = int.from_bytes(buf[q:q + n], "little")
                e[key + "_size"], e[key + "_at"] = size, end + blobs
                blobs += size
                q += n
            else:
                raise ValueError("unknown Apple Archive field %s%s" % (key, kind))
        entries.append(e)
        p = end + blobs
    return entries


def payload_entries(buf, p):
    """Walk the OTA payload entries in buf from offset p: 30-byte header, name, data.
    Stops at the first entry that does not fit (the end of a partial download)."""
    while p + 30 <= len(buf):
        if buf[p] != 0x10:  # byte 1 is the entry type: 1 file, 3 symlink, ...
            raise ValueError("bad payload entry at %d" % p)
        size = int.from_bytes(buf[p + 2:p + 10], "big")
        nlen, _, _, mode = struct.unpack_from(">HHHH", buf, p + 22)
        start = p + 30 + nlen
        if start + size > len(buf):
            return
        yield buf[p + 30:start].decode(), mode, memoryview(buf)[start:start + size]
        p = start + size


# ---- Weather.app --------------------------------------------------------------------------
def fetch_app(z, out, tmp):
    name = "AssetData/payloadv2/app_patches/Weather.app"
    say("Downloading Weather.app (%s) ..." % mb(z.members[name][2]))
    data = z.read(name)
    # DIDIFF10 header: magic, u32, u64 length of a directory list, u64 length of the pbzx stream.
    if data[:8] != b"DIDIFF10":
        die("Weather.app has an unknown format")
    dlen, plen = struct.unpack_from("<QQ", data, 12)
    start = 28 + dlen
    if start + plen != len(data) or data[start:start + 4] != b"pbzx":
        die("Weather.app has an unknown layout")
    archive = b"".join(pbzx_blocks(data, start + 12))
    entries = yaa_entries(archive)
    aar = os.path.join(tmp, "Weather.aar")
    with open(aar, "wb") as f:
        f.write(archive)
    app = os.path.join(out, "Weather.app")
    os.makedirs(app)
    say("Unpacking with aa ...")
    subprocess.run(["aa", "extract", "-i", aar, "-d", app], check=True, stdout=subprocess.DEVNULL)
    os.remove(aar)
    # Check each file against the SHA-1 and size Apple stored in the archive.
    files = {e["PAT"]: e for e in entries if e.get("TYP") == ord("F")}
    found = set()
    for root, dirs, names in os.walk(app):
        for n in names:
            found.add(os.path.relpath(os.path.join(root, n), app))
    if found != set(files):
        die("Weather.app does not contain exactly the files listed in its archive")
    for path, e in files.items():
        with open(os.path.join(app, path), "rb") as f:
            blob = f.read()
        if len(blob) != e.get("DAT_size", 0) or hashlib.sha1(blob).digest() != e.get("SH1"):
            die("Weather.app/%s failed its SHA-1 check" % path)
    say("Weather.app: %d files, every SHA-1 and size matches Apple's archive." % len(files))


# ---- WeatherUI.framework ------------------------------------------------------------------
def bom_files(z, tmp, prefix):
    """{relative path: (size, cksum CRC)} for files under prefix, from the update's post.bom."""
    say("Downloading the update's file list (post.bom, %s) ..." % mb(z.members["AssetData/post.bom"][2]))
    bom = os.path.join(tmp, "post.bom")
    with open(bom, "wb") as f:
        f.write(z.read("AssetData/post.bom"))
    out = subprocess.run(["lsbom", "-f", "-p", "fsc", bom], check=True, capture_output=True, text=True).stdout
    os.remove(bom)
    want = {}
    for line in out.splitlines():
        path, size, crc = line.split("\t")
        path = path[2:] if path.startswith("./") else path
        if path.startswith(prefix):
            want[path[len(prefix):]] = (int(size), int(crc))
    return want


def fetch_backgrounds(z, out, tmp):
    want = bom_files(z, tmp, WUI)
    total = sum(n for _, n, _ in WUI_RUNS)
    say("Downloading the WeatherUI background files (%s in %d pieces) ..." % (mb(total), len(WUI_RUNS)))
    fw = os.path.join(out, "WeatherUI.framework")
    got, done = {}, [0]

    def work(run):
        off, length, first = run
        raw = z.r.get(off, length)
        data = b"".join(pbzx_blocks(raw, 0))
        res = {}
        for name, mode, blob in payload_entries(data, first):
            if name.startswith(WUI) and name[len(WUI):] in want:
                res[name[len(WUI):]] = bytes(blob)
        done[0] += length
        say("  %3d%%  %s of %s" % (100 * done[0] // total, mb(done[0]), mb(total)))
        return res

    with ThreadPoolExecutor(3) as ex:
        for res in ex.map(work, WUI_RUNS):
            for rel, blob in res.items():
                path = os.path.join(fw, rel)
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "wb") as f:
                    f.write(blob)
                got[rel] = hashlib.sha1(blob).hexdigest()
    missing = sorted(set(want) - set(got))
    if missing:
        die("%d WeatherUI files were not found, e.g. %s" % (len(missing), missing[0]))
    # Check sizes and CRCs against post.bom with macOS's own cksum (same algorithm as BOM).
    rels = sorted(want)
    ck = subprocess.run(["cksum"] + rels, cwd=fw, check=True, capture_output=True, text=True).stdout
    for line in ck.splitlines():
        crc, size, rel = line.split(" ", 2)
        if (int(size), int(crc)) != want[rel]:
            die("WeatherUI.framework/%s failed its checksum check" % rel)
    tree = "".join("%s  %s\n" % (got[r], r) for r in rels).encode()
    if hashlib.sha256(tree).hexdigest() != WUI_TREE_SHA256:
        die("the WeatherUI files differ from the expected set")
    for root, dirs, names in os.walk(fw):
        os.chmod(root, 0o755)
        for n in names:
            os.chmod(os.path.join(root, n), 0o644)
    say("WeatherUI.framework: %d files, every size and checksum matches the update's manifest." % len(got))


# ---- Info.plist ---------------------------------------------------------------------------
def patch_plist(path):
    with open(path, "rb") as f:
        p = plistlib.load(f)
    p["UIDeviceFamily"] = [1, 2]
    p["UISupportedInterfaceOrientations~ipad"] = [
        "UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
        "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]
    p["UILaunchStoryboardName"] = "WeatherLaunch"
    with open(path, "wb") as f:
        plistlib.dump(p, f)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fetch")
    f.add_argument("out")
    f.add_argument("--no-backgrounds", action="store_true")
    sub.add_parser("patch-plist").add_argument("plist")
    a = ap.parse_args()
    if a.cmd == "patch-plist":
        return patch_plist(a.plist)
    os.makedirs(a.out)
    say("Checking the iPhone 5s iOS 12.5.8 update on Apple's server ...")
    z = open_ota()
    tmp = tempfile.mkdtemp(prefix="weatherpad.")
    try:
        fetch_app(z, a.out, tmp)
        if not a.no_backgrounds:
            fetch_backgrounds(z, a.out, tmp)
    except subprocess.CalledProcessError as e:
        die("%s failed (exit code %d)" % (e.cmd[0], e.returncode))
    except ValueError as e:
        die("unexpected data in the update: %s" % e)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    say("Downloaded %s from Apple in total." % mb(z.r.fetched))


if __name__ == "__main__":
    main()
