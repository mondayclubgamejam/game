#!/usr/bin/env bash
# Builds a single self-contained Linux executable:
#   build/linux/OneGunOneBullet.x86_64
# Needs Godot 4.7.x on PATH (or GODOT=/path/to/godot) and python3.
set -euo pipefail
cd "$(dirname "$0")/.."

GODOT="${GODOT:-$(command -v godot || command -v godot4 || true)}"
if [ -z "$GODOT" ]; then
	echo "Godot not found. Put it on PATH or run: GODOT=/path/to/godot $0" >&2
	exit 1
fi

# "4.7.2.stable.official.ed1daf0bf" -> "4.7.2"
VERSION="$("$GODOT" --version | sed -E 's/^([0-9]+\.[0-9]+(\.[0-9]+)?)\..*/\1/')"
echo "Godot $VERSION"

python3 tools/fetch_linux_template.py "$VERSION"

mkdir -p build/linux
"$GODOT" --headless --path . --import >/dev/null 2>&1 || true
"$GODOT" --headless --path . --export-release "Linux" build/linux/OneGunOneBullet.x86_64
chmod +x build/linux/OneGunOneBullet.x86_64
echo "Built build/linux/OneGunOneBullet.x86_64 ($(du -h build/linux/OneGunOneBullet.x86_64 | cut -f1))"
