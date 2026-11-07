#!/bin/sh
# Start Super Tenet: builds it first if the code changed since the last build.
#   tools/play.sh               (extra arguments are passed to the game)
exec "$(dirname "$0")/build.sh" play "$@"
