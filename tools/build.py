#!/usr/bin/env python3
"""Build One Gun One Bullet into a single self-contained executable.

    python3 tools/build.py                  # build for the OS you're on
    python3 tools/build.py --target windows # or: linux, all

Outputs:
    build/linux/OneGunOneBullet.x86_64
    build/windows/OneGunOneBullet.exe

Needs only Python 3. Godot comes from $GODOT, or from PATH if it's 4.7.x;
otherwise the official Godot 4.7.2 is downloaded once into a cache folder and
run in self-contained mode, so nothing is written outside that folder. Export
templates are pulled out of Godot's 1.3 GB template bundle with HTTP range
requests, so only the platforms you build for are downloaded.
"""
import argparse
import io
import os
import platform
import shutil
import stat
import subprocess
import sys
import urllib.request
import zipfile

GODOT_VERSION = "4.7.2"
SERIES = "4.7"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RELEASES = f"https://github.com/godotengine/godot/releases/download/{GODOT_VERSION}-stable"

TARGETS = {
    "linux": {
        "preset": "Linux",
        "template": "linux_release.x86_64",
        "out": os.path.join("build", "linux", "OneGunOneBullet.x86_64"),
    },
    "windows": {
        "preset": "Windows Desktop",
        "template": "windows_release_x86_64.exe",
        "out": os.path.join("build", "windows", "OneGunOneBullet.exe"),
    },
}

# Godot editor builds that can run the export on each host OS.
EDITORS = {
    ("Linux", "x86_64"): ("linux.x86_64.zip", "linux.x86_64"),
    ("Linux", "arm64"): ("linux.arm64.zip", "linux.arm64"),
    ("Windows", "x86_64"): ("win64.exe.zip", "win64_console.exe"),
    ("Windows", "arm64"): ("windows_arm64.exe.zip", "windows_arm64_console.exe"),
}


def log(msg):
    print(f"[build] {msg}", flush=True)


def host():
    system = platform.system()
    machine = platform.machine().lower()
    arch = "arm64" if machine in ("arm64", "aarch64") else "x86_64"
    return system, arch


def cache_dir():
    if platform.system() == "Windows":
        base = os.environ.get("LOCALAPPDATA", os.path.expanduser("~\\AppData\\Local"))
    else:
        base = os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache"))
    return os.path.join(base, "one-gun-one-bullet")


# --- Remote zip reading -----------------------------------------------------

class RangeFile(io.RawIOBase):
    """Seekable read-only view of a remote file, fetched in chunks on demand."""

    CHUNK = 4 * 1024 * 1024

    def __init__(self, url):
        with urllib.request.urlopen(urllib.request.Request(url, method="HEAD")) as r:
            self.url = r.url  # follow GitHub's redirect once
            self.size = int(r.headers["Content-Length"])
        self.pos = 0
        self._start = -1
        self._buf = b""
        self.fetched = 0

    def seekable(self):
        return True

    def readable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, offset, whence=io.SEEK_SET):
        base = {io.SEEK_SET: 0, io.SEEK_CUR: self.pos, io.SEEK_END: self.size}[whence]
        self.pos = max(0, min(self.size, base + offset))
        return self.pos

    def read(self, n=-1):
        if n is None or n < 0:
            n = self.size - self.pos
        n = min(n, self.size - self.pos)
        out = bytearray()
        while n > 0:
            off = self.pos - self._start
            if self._start < 0 or off < 0 or off >= len(self._buf):
                end = min(self.size, self.pos + max(n, self.CHUNK)) - 1
                req = urllib.request.Request(self.url, headers={"Range": f"bytes={self.pos}-{end}"})
                with urllib.request.urlopen(req) as r:
                    if r.status != 206:
                        raise RuntimeError("server ignored the range request")
                    self._buf = r.read()
                self._start = self.pos
                self.fetched += len(self._buf)
                off = 0
            piece = self._buf[off:off + n]
            out += piece
            self.pos += len(piece)
            n -= len(piece)
        return bytes(out)

    def readinto(self, b):
        data = self.read(len(b))
        b[:len(data)] = data
        return len(data)


def make_executable(path):
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


# --- Godot ------------------------------------------------------------------

def godot_version(exe):
    try:
        out = subprocess.run([exe, "--version"], capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""
    line = out.strip().splitlines()[-1] if out.strip() else ""
    parts = line.split(".")
    nums = [p for p in parts[:3] if p.isdigit()]
    return ".".join(nums)


def find_godot():
    """Returns (path, version, self_contained)."""
    explicit = os.environ.get("GODOT")
    candidates = [explicit] if explicit else [shutil.which(n) for n in ("godot", "godot4")]
    for exe in filter(None, candidates):
        v = godot_version(exe)
        if v.startswith(SERIES):
            return exe, v, is_self_contained(exe)
        log(f"Ignoring {exe} (version '{v}', this project needs {SERIES}.x)")
        if explicit:
            sys.exit(f"GODOT={explicit} is not Godot {SERIES}.x")
    return download_godot()


def is_self_contained(exe):
    d = os.path.dirname(os.path.realpath(exe))
    return os.path.exists(os.path.join(d, "._sc_")) or os.path.exists(os.path.join(d, "_sc_"))


def download_godot():
    key = host()
    if key not in EDITORS:
        sys.exit(f"Can't build on {key[0]} {key[1]} automatically. Install Godot {GODOT_VERSION} "
                 f"and set GODOT=/path/to/godot.")
    zip_name, exe_suffix = EDITORS[key]
    folder = os.path.join(cache_dir(), f"godot-{GODOT_VERSION}")
    exe = os.path.join(folder, f"Godot_v{GODOT_VERSION}-stable_{exe_suffix}")
    if not os.path.exists(exe):
        url = f"{RELEASES}/Godot_v{GODOT_VERSION}-stable_{zip_name}"
        log(f"Downloading Godot {GODOT_VERSION} for {key[0]} (about 80 MB) into {folder}")
        os.makedirs(folder, exist_ok=True)
        with urllib.request.urlopen(url) as r:
            data = r.read()
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            z.extractall(folder)
        for name in os.listdir(folder):
            if name.startswith("Godot_v"):
                make_executable(os.path.join(folder, name))
        # Self-contained mode: Godot keeps its settings and export templates
        # in editor_data/ next to itself instead of in your user folders.
        open(os.path.join(folder, "._sc_"), "w").close()
    return exe, GODOT_VERSION, True


def template_dir(godot_exe, version, self_contained):
    if self_contained:
        base = os.path.join(os.path.dirname(os.path.realpath(godot_exe)), "editor_data")
    elif platform.system() == "Windows":
        base = os.path.join(os.environ["APPDATA"], "Godot")
    elif platform.system() == "Darwin":
        base = os.path.expanduser("~/Library/Application Support/Godot")
    else:
        base = os.path.join(os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")), "godot")
    return os.path.join(base, "export_templates", f"{version}.stable")


def ensure_templates(dest, version, names):
    wanted = [n for n in names + ["version.txt"] if not os.path.exists(os.path.join(dest, n))]
    if not wanted:
        return
    url = f"https://github.com/godotengine/godot/releases/download/{version}-stable/" \
          f"Godot_v{version}-stable_export_templates.tpz"
    log(f"Fetching export templates {', '.join(wanted)}")
    remote = RangeFile(url)
    os.makedirs(dest, exist_ok=True)
    with zipfile.ZipFile(remote) as z:
        for name in wanted:
            target = os.path.join(dest, name)
            with z.open(f"templates/{name}") as src, open(target + ".part", "wb") as out:
                shutil.copyfileobj(src, out, 1 << 20)
            os.replace(target + ".part", target)
            if not name.endswith(".txt"):
                make_executable(target)
    log(f"Templates ready in {dest} (downloaded {remote.fetched / 1e6:.0f} MB of {remote.size / 1e6:.0f} MB)")


# --- Build ------------------------------------------------------------------

def default_target():
    system = platform.system()
    if system == "Windows":
        return "windows"
    if system == "Linux":
        return "linux"
    sys.exit(f"There's no {system} build yet. Use --target linux or --target windows to cross-build.")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--target", choices=["auto", "linux", "windows", "all"], default="auto")
    args = parser.parse_args()
    targets = list(TARGETS) if args.target == "all" else [default_target() if args.target == "auto" else args.target]

    godot, version, self_contained = find_godot()
    log(f"Using Godot {version} at {godot}")
    ensure_templates(template_dir(godot, version, self_contained), version,
                     [TARGETS[t]["template"] for t in targets])

    # Keep Godot from scanning build output as project files.
    os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)
    open(os.path.join(ROOT, "build", ".gdignore"), "a").close()

    subprocess.run([godot, "--headless", "--path", ROOT, "--import"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for t in targets:
        spec = TARGETS[t]
        out = os.path.join(ROOT, spec["out"])
        os.makedirs(os.path.dirname(out), exist_ok=True)
        if os.path.exists(out):
            os.remove(out)
        log(f"Exporting {t} ...")
        result = subprocess.run([godot, "--headless", "--path", ROOT, "--export-release", spec["preset"], out],
                                capture_output=True, text=True)
        if result.returncode != 0 or not os.path.exists(out):
            print(result.stdout[-3000:], result.stderr[-3000:], sep="\n")
            sys.exit(f"Export for {t} failed.")
        if t == "linux":
            make_executable(out)
        log(f"Built {spec['out']} ({os.path.getsize(out) / 1e6:.0f} MB)")


if __name__ == "__main__":
    main()
