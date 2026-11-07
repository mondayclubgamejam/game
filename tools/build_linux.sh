#!/usr/bin/env bash
# Builds a single self-contained Linux executable:
#   build/linux/OneGunOneBullet.x86_64
# Only needs python3. Uses Godot from $GODOT or PATH if it's 4.7.x; otherwise
# downloads the official Godot 4.7.2 into ~/.cache/one-gun-one-bullet once.
set -euo pipefail
cd "$(dirname "$0")/.."

GODOT_VERSION="4.7.2"
WANT_SERIES="4.7"

version_of() { "$1" --version 2>/dev/null | head -n1 | sed -E 's/^([0-9]+\.[0-9]+(\.[0-9]+)?)\..*/\1/'; }

GODOT="${GODOT:-$(command -v godot || command -v godot4 || true)}"
if [ -n "$GODOT" ] && [[ "$(version_of "$GODOT")" != "$WANT_SERIES"* ]]; then
	echo "Ignoring $GODOT (version $(version_of "$GODOT"), this project needs $WANT_SERIES)"
	GODOT=""
fi
if [ -z "$GODOT" ]; then
	CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/one-gun-one-bullet"
	GODOT="$CACHE/Godot_v${GODOT_VERSION}-stable_linux.x86_64"
	if [ ! -x "$GODOT" ]; then
		URL="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip"
		echo "Downloading Godot $GODOT_VERSION (about 75 MB) into $CACHE"
		mkdir -p "$CACHE"
		python3 - "$URL" "$CACHE" <<'PY'
import io, os, sys, urllib.request, zipfile
url, dest = sys.argv[1], sys.argv[2]
with urllib.request.urlopen(url) as r:
    data = r.read()
with zipfile.ZipFile(io.BytesIO(data)) as z:
    for name in z.namelist():
        z.extract(name, dest)
        os.chmod(os.path.join(dest, name), 0o755)
PY
	fi
fi

VERSION="$(version_of "$GODOT")"
echo "Using Godot $VERSION ($GODOT)"

python3 tools/fetch_linux_template.py "$VERSION"

mkdir -p build/linux
"$GODOT" --headless --path . --import >/dev/null 2>&1 || true
"$GODOT" --headless --path . --export-release "Linux" build/linux/OneGunOneBullet.x86_64
chmod +x build/linux/OneGunOneBullet.x86_64
echo "Built build/linux/OneGunOneBullet.x86_64 ($(du -h build/linux/OneGunOneBullet.x86_64 | cut -f1))"
