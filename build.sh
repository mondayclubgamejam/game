#!/usr/bin/env sh
# Build for this OS (pass --target windows|linux|all to choose). See tools/build.py.
cd "$(dirname "$0")" || exit 1
exec python3 tools/build.py "$@"
