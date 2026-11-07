# Running the Super Tenet online server (AWS EC2)

The online server lets two players meet through the internet instead of the
local network. Both players only make **outgoing** connections, so it works
on eduroam, on locked-down managed machines, and anywhere else that blocks
devices from reaching each other. Players connect by the server's **IP
address**, over:

- **UDP 7777** when their network allows it (lowest latency), or
- **HTTPS on port 443** (an encrypted WebSocket) when it doesn't. The game
  switches by itself after ~2.5 s.

The server is the same game executable started with `--server`. It needs no
graphics and very little CPU or memory, so the smallest instance is plenty.
One server runs **one match at a time**: the first two players to connect are
paired (first = Forward, second = Reverse); anyone else is told it's busy.

**About the certificate.** HTTPS certificates normally vouch for a domain
name, and this server only has an IP. So the server makes its own key and
certificate, and the game carries a copy of that certificate
(`assets/server.crt`) and trusts exactly it. Players are fully checked
against it: nobody else can pose as your server. The certificate is public
and safe to commit; the key stays on the server.

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
| HTTPS (TCP) | 443 | Anywhere | players on networks that block UDP |
| Custom UDP | 7777 | Anywhere | players on networks that allow UDP |

**Keep the IP fixed:** an instance's public IP changes when it's stopped and
started. To avoid re-typing it, allocate an **Elastic IP** (EC2 → Elastic IPs
→ Allocate, then Associate with the instance) and use that.

**Cost:** new AWS accounts (since July 2025) get credits and a 6-month free
plan, and EC2 usage draws down the credits; older accounts have 750 free
t2/t3.micro hours a month for 12 months. Every public IPv4 address (Elastic
or not) costs about $3.60/month. Set up a **billing budget alert** (Billing →
Budgets) and check the free-tier usage page after launching.

## 2. Install the server: one command

Log in to the instance (`IP` is its public or Elastic IP), get the game's
repository onto it, and run one script:

```sh
ssh -i my-key.pem ubuntu@IP
git clone <your repository URL> game && cd game
tools/server.sh
```

`tools/server.sh` does everything:

- builds the Linux version of the game right there (it fetches Godot by
  itself the first time; about 30 seconds),
- installs it as a service that starts on boot and restarts if it stops
  (it asks for `sudo`),
- makes the server's key and certificate on first start, and
- checks the repository's `assets/server.crt` against the server's
  certificate. If they differ (a new server), it copies the right one in and
  tells you to commit and push it, so players' builds trust this server.

**Updating** the server later is the same command:

```sh
cd game && git pull && tools/server.sh
```

The key and certificate are kept across updates.

(`server/setup.sh` is the install step on its own, if you'd rather build
elsewhere and copy the executable over: `sudo bash setup.sh ./SuperTenet.x86_64`.)

## 3. Players

Players run `tools/play.sh` (Linux) or `tools\play.bat` (Windows) from a
copy of the repository that includes this server's `assets/server.crt`.
Their game builds itself when needed and starts.

## 4. Play

In the game's lobby, put the server's IP in **SERVER** and click **PLAY
ONLINE**. The second player does the same; the match starts when both are in.

To ship builds with the IP already filled in, set it in `project.godot`:

```ini
[game]

online_server="3.120.45.67"
```

## Updating

On the server: `cd game && git pull && tools/server.sh`. Players: `git pull`,
then `tools/play.sh` / `tools\play.bat` rebuilds by itself.

## Checking on it

```sh
journalctl -u onegun -f       # who connected, over UDP or WebSocket, and the match
sudo systemctl restart onegun
```

If players can't connect: check the security group rules above, that they're
using the server's current IP, and that their build contains this server's
`assets/server.crt` (a mismatched certificate fails the HTTPS route on
purpose).
