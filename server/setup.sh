#!/usr/bin/env bash
# Sets up (or updates) the One Gun One Bullet server on a fresh Ubuntu 24.04
# machine, such as an AWS EC2 instance. Safe to run again to update the game.
#
#   sudo bash setup.sh <path to OneGunOneBullet.x86_64>
#
# Players connect by this machine's public IP address:
#   - UDP 7777 for players whose network allows UDP (lowest latency)
#   - HTTPS (an encrypted WebSocket) on TCP 443 for everyone else
#
# The server makes its own key and certificate on first start, in
# /opt/onegun/tls. The key never leaves this machine. The certificate is
# public: copy it into the game as assets/server.crt before building the
# copies players use, so they can check they've reached this server.
set -euo pipefail

BINARY="${1:-}"
if [ -z "$BINARY" ]; then
	sed -n '2,14p' "$0"
	exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
	echo "Run with sudo." >&2
	exit 1
fi
if [ ! -f "$BINARY" ]; then
	echo "Can't find $BINARY. Build it with tools/build.sh and copy it here." >&2
	exit 1
fi

APP=/opt/onegun
echo "==> Installing the game server into $APP"
id onegun >/dev/null 2>&1 || useradd --system --home-dir "$APP/home" --shell /usr/sbin/nologin onegun
mkdir -p "$APP/home" "$APP/tls"
install -m 0755 "$BINARY" "$APP/OneGunOneBullet.x86_64.new"
mv -f "$APP/OneGunOneBullet.x86_64.new" "$APP/OneGunOneBullet.x86_64"
chown -R onegun:onegun "$APP"
chmod 700 "$APP/tls"

# The game binds port 443 itself; the capability below allows that without
# running as root.
cat > /etc/systemd/system/onegun.service <<EOF
[Unit]
Description=One Gun One Bullet game server
After=network-online.target
Wants=network-online.target

[Service]
User=onegun
Environment=HOME=$APP/home
ExecStart=$APP/OneGunOneBullet.x86_64 --headless -- --server --port=7777 --ws-port=443 --tls-dir=$APP/tls
Restart=always
RestartSec=2
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$APP/home $APP/tls

[Install]
WantedBy=multi-user.target
EOF

STATUS="installed (start it with: sudo systemctl start onegun)"
if command -v systemctl >/dev/null && [ -d /run/systemd/system ]; then
	STATUS="running"
	systemctl daemon-reload
	systemctl enable onegun >/dev/null
	systemctl restart onegun
	# Wait for the first start to make the certificate.
	for _ in $(seq 1 30); do
		[ -f "$APP/tls/server.crt" ] && break
		sleep 1
	done
	systemctl --no-pager --lines=3 status onegun | sed -n '1,3p'
fi

IP="$(curl -fsS --max-time 5 https://checkip.amazonaws.com 2>/dev/null || hostname -I | awk '{print $1}')"
cat <<EOF

Done. The server is $STATUS. Players enter this IP in the game's SERVER box:

    $IP

Before building the copies players use, put this server's certificate into
the game (it's public, so it's fine to commit). On your own machine, in the
game folder:

    scp -i YOUR-KEY.pem ubuntu@$IP:$APP/tls/server.crt assets/server.crt

Then build with tools/build.sh. Do this once; it stays valid for 20 years
unless you delete $APP/tls on the server.

Useful commands here:
    journalctl -u onegun -f        # watch the server: connections and matches
    sudo systemctl restart onegun  # restart it
EOF
