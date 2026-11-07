#!/bin/sh
# One command for the server machine (Ubuntu 24.04, e.g. AWS EC2), run from
# a clone of this repository:
#
#   tools/server.sh
#
# Builds the game here (fetching Godot by itself the first time), installs or
# updates it as a service with sudo, and makes sure the repository's
# assets/server.crt matches this server's certificate. To update the server
# later: git pull && tools/server.sh
set -e
cd "$(dirname "$0")/.."

tools/build.sh -target linux

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"
$SUDO bash server/setup.sh build/linux/SuperTenet.x86_64 --from-server-sh

# Players' builds trust exactly the certificate in assets/server.crt.
CERT=/opt/onegun/tls/server.crt
if $SUDO test -f "$CERT"; then
	if $SUDO cmp -s "$CERT" assets/server.crt 2>/dev/null; then
		echo "assets/server.crt matches this server's certificate."
	else
		$SUDO cat "$CERT" > assets/server.crt
		echo
		echo "This server's certificate was copied into assets/server.crt."
		echo "Commit and push it so players' builds trust this server:"
		echo "    git add assets/server.crt && git commit -m 'Update server certificate' && git push"
	fi
fi
