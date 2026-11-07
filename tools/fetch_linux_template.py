#!/usr/bin/env python3
"""Install only Godot's Linux x86_64 release export template.

The official template bundle is a 1.3 GB zip covering every platform. This
reads the zip remotely with HTTP range requests and extracts just the files
the Linux export needs (about 70 MB), into Godot's standard template folder.

Usage: fetch_linux_template.py <godot version, e.g. 4.7.2>
"""
import io
import os
import sys
import urllib.request
import zipfile

WANTED = ("templates/linux_release.x86_64", "templates/version.txt")


class RangeFile(io.RawIOBase):
    """Seekable read-only view of a remote file, fetched in chunks on demand."""

    CHUNK = 4 * 1024 * 1024

    def __init__(self, url):
        req = urllib.request.Request(url, method="HEAD")
        with urllib.request.urlopen(req) as r:
            self.url = r.url  # follow GitHub's redirect once
            self.size = int(r.headers["Content-Length"])
        self.pos = 0
        self._buf_start = -1
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

    def _fill(self, start, want):
        end = min(self.size, start + max(want, self.CHUNK)) - 1
        req = urllib.request.Request(self.url, headers={"Range": f"bytes={start}-{end}"})
        with urllib.request.urlopen(req) as r:
            if r.status != 206:
                raise RuntimeError("server ignored the range request")
            self._buf = r.read()
        self._buf_start = start
        self.fetched += len(self._buf)

    def read(self, n=-1):
        if n is None or n < 0:
            n = self.size - self.pos
        n = min(n, self.size - self.pos)
        if n <= 0:
            return b""
        out = bytearray()
        while n > 0:
            off = self.pos - self._buf_start
            if self._buf_start < 0 or off < 0 or off >= len(self._buf):
                self._fill(self.pos, n)
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


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    version = sys.argv[1]
    data_home = os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share"))
    dest = os.path.join(data_home, "godot", "export_templates", f"{version}.stable")
    if all(os.path.exists(os.path.join(dest, os.path.basename(w))) for w in WANTED):
        print(f"Linux export template already installed in {dest}")
        return
    url = (f"https://github.com/godotengine/godot/releases/download/"
           f"{version}-stable/Godot_v{version}-stable_export_templates.tpz")
    print(f"Fetching the Linux template from {url}")
    remote = RangeFile(url)
    os.makedirs(dest, exist_ok=True)
    with zipfile.ZipFile(remote) as z:
        for name in WANTED:
            target = os.path.join(dest, os.path.basename(name))
            with z.open(name) as src, open(target + ".part", "wb") as out:
                while chunk := src.read(1 << 20):
                    out.write(chunk)
            os.replace(target + ".part", target)
            if name.endswith(".x86_64"):
                os.chmod(target, 0o755)
    print(f"Installed into {dest} (downloaded {remote.fetched / 1e6:.0f} MB "
          f"of {remote.size / 1e6:.0f} MB)")


if __name__ == "__main__":
    main()
