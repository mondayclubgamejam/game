# Running the online server (AWS EC2)

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

## 2. Install the server

On your own machine, build the Linux executable and copy it and the setup
script to the instance (`IP` is the instance's public or Elastic IP):

```sh
tools/build.sh -target linux
scp -i my-key.pem build/linux/OneGunOneBullet.x86_64 server/setup.sh ubuntu@IP:
ssh -i my-key.pem ubuntu@IP
```

Then, on the instance:

```sh
sudo bash setup.sh ./OneGunOneBullet.x86_64
```

That installs the game as a service that starts on boot and restarts if it
stops, makes the server's key and certificate, and prints what to do next.

## 3. Put the server's certificate into the game

Back on your own machine, in the game folder:

```sh
scp -i my-key.pem ubuntu@IP:/opt/onegun/tls/server.crt assets/server.crt
git add assets/server.crt && git commit -m "Add online server certificate"
```

Builds made after this can use the HTTPS route. (Builds without it still
work over UDP, but can't fall back to HTTPS.) This is a one-time step: the
certificate is valid for 20 years unless you delete `/opt/onegun/tls` on the
server.

## 4. Play

In the game's lobby, put the server's IP in **SERVER** and click **PLAY
ONLINE**. The second player does the same; the match starts when both are in.

To ship builds with the IP already filled in, set it in `project.godot`:

```ini
[game]

online_server="3.120.45.67"
```

## Updating

Copy the new executable over and run the setup script again; it replaces the
game and restarts it. The key and certificate are kept.

## Checking on it

```sh
journalctl -u onegun -f       # who connected, over UDP or WebSocket, and the match
sudo systemctl restart onegun
```

If players can't connect: check the security group rules above, that they're
using the server's current IP, and that their build contains this server's
`assets/server.crt` (a mismatched certificate fails the HTTPS route on
purpose).
