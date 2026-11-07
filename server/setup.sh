#!/usr/bin/env bash
# Sets up (or updates) the One Gun One Bullet server on a fresh Ubuntu 24.04
# machine, such as an AWS EC2 instance. Safe to run again to update.
#
#   sudo bash setup.sh <domain> <path to OneGunOneBullet.x86_64> [duckdns token]
#
# Example:
#   sudo bash setup.sh onegun-uni.duckdns.org ./OneGunOneBullet.x86_64 a1b2c3d4-...
#
# What it does:
#   - installs Caddy, which gets a free HTTPS certificate for <domain> and
#     forwards WebSocket players (port 443) to the game server
#   - installs the game as a service that starts on boot and restarts if it
#     stops: UDP 7777 for players whose network allows UDP, and a WebSocket on
#     127.0.0.1:8080 behind Caddy for everyone else
#   - with a DuckDNS token, keeps <domain> pointing at this machine's IP
#     every 5 minutes (EC2 IPs change when an instance is stopped and started)
set -euo pipefail

DOMAIN="${1:-}"
BINARY="${2:-}"
DUCKDNS_TOKEN="${3:-}"

if [ -z "$DOMAIN" ] || [ -z "$BINARY" ]; then
	sed -n '2,9p' "$0"
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
echo "==> Installing Caddy"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq caddy curl >/dev/null

echo "==> Installing the game server into $APP"
id onegun >/dev/null 2>&1 || useradd --system --home-dir "$APP/home" --shell /usr/sbin/nologin onegun
mkdir -p "$APP/home"
install -m 0755 "$BINARY" "$APP/OneGunOneBullet.x86_64.new"
mv -f "$APP/OneGunOneBullet.x86_64.new" "$APP/OneGunOneBullet.x86_64"
chown -R onegun:onegun "$APP"

cat > /etc/systemd/system/onegun.service <<EOF
[Unit]
Description=One Gun One Bullet game server
After=network-online.target
Wants=network-online.target

[Service]
User=onegun
Environment=HOME=$APP/home
ExecStart=$APP/OneGunOneBullet.x86_64 --headless -- --server --port=7777 --ws-port=8080 --ws-bind=127.0.0.1
Restart=always
RestartSec=2
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$APP/home

[Install]
WantedBy=multi-user.target
EOF

echo "==> Configuring HTTPS for $DOMAIN"
cat > /etc/caddy/Caddyfile <<EOF
# HTTPS (port 443) for $DOMAIN, with a certificate Caddy gets and renews by
# itself. WebSocket players are passed to the game server.
$DOMAIN {
	reverse_proxy 127.0.0.1:8080
}
EOF
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null

if [ -n "$DUCKDNS_TOKEN" ]; then
	echo "==> Keeping $DOMAIN pointed at this machine (DuckDNS)"
	SUB="${DOMAIN%.duckdns.org}"
	cat > /etc/cron.d/onegun-duckdns <<EOF
*/5 * * * * root curl -fsS "https://www.duckdns.org/update?domains=$SUB&token=$DUCKDNS_TOKEN&ip=" >/dev/null 2>&1
@reboot root sleep 20 && curl -fsS "https://www.duckdns.org/update?domains=$SUB&token=$DUCKDNS_TOKEN&ip=" >/dev/null 2>&1
EOF
	chmod 600 /etc/cron.d/onegun-duckdns
	curl -fsS "https://www.duckdns.org/update?domains=$SUB&token=$DUCKDNS_TOKEN&ip=" && echo
fi

if command -v systemctl >/dev/null && [ -d /run/systemd/system ]; then
	systemctl daemon-reload
	systemctl enable --now onegun >/dev/null
	systemctl restart onegun
	systemctl reload-or-restart caddy
	sleep 2
	systemctl --no-pager --lines=3 status onegun | sed -n '1,3p'
fi

cat <<EOF

Done. Players enter this as the server in the game's lobby:

    $DOMAIN

Useful commands:
    journalctl -u onegun -f        # watch the game server log
    journalctl -u caddy -f         # watch HTTPS / certificate log
    sudo systemctl restart onegun  # restart the game server
EOF
