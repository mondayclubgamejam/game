#!/bin/sh
# Build the game for this OS:   ./build.sh
# Or choose:                    ./build.sh -target windows   (linux, windows, all)
# Runs a prebuilt, dependency-free builder from tools/bin (source: tools/builder).
cd "$(dirname "$0")" || exit 1
case "$(uname -m)" in
	x86_64 | amd64) arch=amd64 ;;
	aarch64 | arm64) arch=arm64 ;;
	*) arch="" ;;
esac
bin="tools/bin/onegun-build-linux-$arch"
if [ "$(uname -s)" = Linux ] && [ -n "$arch" ] && [ -f "$bin" ]; then
	[ -x "$bin" ] || chmod +x "$bin"
	exec "$bin" "$@"
fi
if command -v go >/dev/null 2>&1; then
	cd tools/builder && exec go run . "$@"
fi
echo "No prebuilt builder for $(uname -s) $(uname -m), and Go isn't installed (https://go.dev/dl/)." >&2
exit 1
