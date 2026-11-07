#!/bin/sh
# Look at the world and UI with no game running: a generated room, frozen
# enemies, every UI screen with sample data, and a free-fly camera.
#   tools/view.sh
# Uses Godot from $GODOT, from PATH, or from /Applications/Godot.app (macOS).
# Without a local Godot it falls back to the exported build (Linux/Windows).
cd "$(dirname "$0")/.." || exit 1
godot="${GODOT:-}"
[ -z "$godot" ] && godot="$(command -v godot || command -v godot4 || true)"
[ -z "$godot" ] && [ -x /Applications/Godot.app/Contents/MacOS/Godot ] && godot=/Applications/Godot.app/Contents/MacOS/Godot
if [ -n "$godot" ]; then
	# Assets (the font, shaders) must be imported once before running from source.
	if [ ! -d .godot/imported ] || [ -z "$(ls .godot/imported 2>/dev/null)" ]; then
		echo "Importing assets (first run only)..."
		"$godot" --headless --path . --import >/dev/null 2>&1
	fi
	exec "$godot" --path . -- --view "$@"
fi
# The first -- ends the builder's own flags; the second starts the game's.
exec tools/play.sh -- -- --view "$@"
