#!/bin/sh
# Rebuild the 3D models from their Blender scripts (no Blender window opens):
#   tools/blender/build.sh
# Uses Blender from $BLENDER, from PATH, or from /Applications/Blender.app.
# The exported .glb files are committed, so only people changing models need Blender.
cd "$(dirname "$0")/../.." || exit 1
blender="${BLENDER:-}"
[ -z "$blender" ] && blender="$(command -v blender || true)"
[ -z "$blender" ] && [ -x /Applications/Blender.app/Contents/MacOS/Blender ] && blender=/Applications/Blender.app/Contents/MacOS/Blender
if [ -z "$blender" ]; then
	echo "Blender not found. Install it (macOS: brew install --cask blender, or https://www.blender.org/download/)" >&2
	echo "or set BLENDER=/path/to/blender." >&2
	exit 1
fi
set -e
for script in tools/blender/*.py; do
	echo "[blender] $script"
	"$blender" --background --factory-startup --python-exit-code 1 --python "$script"
done
