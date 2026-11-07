# Running the online server (AWS EC2)

The online server lets two players meet through the internet instead of the
local network. Both players only make **outgoing** connections, so it works
on eduroam, on locked-down managed machines, and anywhere else that blocks
devices from reaching each other. Each player connects over:

- **UDP 7777** when their network allows it (lowest latency), or
- **HTTPS on port 443** (a WebSocket) when it doesn't. The game switches by
  itself after ~2.5 s.

The server is the same game executable started with `--server`. It needs no
graphics and very little CPU or memory, so the smallest instance is plenty.
One server runs **one match at a time**: the first two players to connect are
paired (first = Forward, second = Reverse); anyone else is told it's busy.

## 1. Launch the instance

In the AWS console, **EC2 → Launch instance**:

| Setting | Value |
|---|---|
| Region | the one closest to your campus (top right of the console) |
| Image | **Ubuntu Server 24.04 LTS**, 64-bit **(x86)** |
| Instance type | **t3.micro** (or t2.micro) |
| Key pair | create one and keep the `.pem` file; you need it to log in |
| Network settings → security group | add the rules below |

| Type | Port | Source | Why |
|---|---|---|---|
| SSH (TCP) | 22 | **My IP** | logging in to set it up |
| HTTP (TCP) | 80 | Anywhere | getting the HTTPS certificate |
| HTTPS (TCP) | 443 | Anywhere | players on networks that block UDP |
| Custom UDP | 7777 | Anywhere | players on networks that allow UDP |

**Cost:** new AWS accounts (since July 2025) get credits and a 6-month free
plan, and EC2 usage draws down the credits; older accounts have 750 free
t2/t3.micro hours a month for 12 months. Every public IPv4 address costs about
$3.60/month either way. Set up a **billing budget alert** (Billing → Budgets)
and check the free-tier usage page after launching.

## 2. Give it a name (free, DuckDNS)

HTTPS needs a domain name. At [duckdns.org](https://www.duckdns.org), sign
in, create a subdomain (say `onegun-uni`), and paste the instance's **public
IPv4 address** into it. Copy your DuckDNS **token** from the same page.

## 3. Install the server

On your own machine, build the Linux executable and copy it and the setup
script to the instance:

```sh
tools/build.sh -target linux
scp -i my-key.pem build/linux/OneGunOneBullet.x86_64 server/setup.sh ubuntu@onegun-uni.duckdns.org:
ssh -i my-key.pem ubuntu@onegun-uni.duckdns.org
```

Then, on the instance:

```sh
sudo bash setup.sh onegun-uni.duckdns.org ./OneGunOneBullet.x86_64 YOUR-DUCKDNS-TOKEN
```

That installs Caddy (HTTPS certificates, renewed automatically), installs the
game as a service that starts on boot and restarts if it stops, and keeps the
DuckDNS name pointed at the instance (its IP changes if you stop and start
it). The token is optional if you'd rather update DuckDNS by hand.

## 4. Play

In the game's lobby, put `onegun-uni.duckdns.org` in **SERVER** and click
**PLAY ONLINE**. The second player does the same; the match starts when both
are in.

To ship builds with the server already filled in, set it in `project.godot`:

```ini
[game]

online_server="onegun-uni.duckdns.org"
```

## Updating

Copy the new executable over and run the setup script again; it replaces the
game and restarts it.

## Checking on it

```sh
journalctl -u onegun -f   # who connected, over UDP or WebSocket, and the match
journalctl -u caddy -f    # HTTPS certificate problems show up here
sudo systemctl restart onegun
```

If players can't connect: check the security group rules above, that the
DuckDNS name shows the instance's current IP, and `journalctl -u caddy` for
certificate errors (port 80 must be open for Caddy to get the certificate).

## Testing a server without a domain

`--online=1.2.3.4` connects to a bare IP: UDP on 7777, falling back to a
plain (unencrypted) WebSocket on port 8080. For that, start the server with
`--ws-bind=*` instead of `127.0.0.1` and open TCP 8080 in the security group.
Use the domain + HTTPS setup for real play: some networks block or interfere
with unencrypted WebSockets.
