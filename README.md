# Super Tenet

Monday Club game jam project, built with [Godot 4.7](https://godotengine.org/).

An online co-op shooter about time direction for **2 to 4 players**, who all share **one gun with one bullet**:

- The **normal** player can only **fire**. The bullet passes through every enemy in its path and sticks in the first wall.
- The **inverted** player can only **recall**. The bullet rips out of wherever it stuck and curves back into their gun, killing everything on the way. A recall can't pass through walls: it sticks in any wall in the way, and the inverted player has to find a clear angle.

The host picks who's normal and who's inverted in the match lobby.

So you must **throw the gun to each other** after every shot and every recall. Carrying the gun slows you down. Friendly fire is on, and enemies die in one hit and so do you. **A player who dies watches a teammate** (click for the next one); the attempt only ends when everyone is down, and then the room restarts. Clear every enemy to get a new procedurally generated room. **Bigger groups get bigger rooms and more enemies** (4 more per player beyond two).

Design spec: [`docs/superpowers/specs/2026-11-07-tenet-coop-mvp-design.md`](docs/superpowers/specs/2026-11-07-tenet-coop-mvp-design.md). Visual style: [`game-style/STYLE_BRIEF.md`](game-style/STYLE_BRIEF.md).

## Getting started

**To play, run one command.** Nothing needs installing first, not even Godot:

| On | Run |
|---|---|
| Linux | `tools/play.sh` |
| Windows | double-click `tools\play.bat` |

It builds the game the first time (about 30 seconds; it fetches Godot by itself), and after that only when the code has changed, for example after a `git pull`. Then it starts the game.

**To run the online server**, on the server: `tools/server.sh`. See [`server/README.md`](server/README.md).

**To work on the game** in the editor: install Godot 4.7, choose **Import** and select `project.godot`, then press **F5**.

### Controls

| Input | Action |
|---|---|
| WASD / arrows | Move |
| Space | Jump (high enough to get onto a crate) |
| Ctrl / C | Crouch: shorter and slower, so a crate hides you from gunmen |
| Mouse | Look and aim |
| Left click / F | Fire (normal) or recall (inverted) |
| Right click / Q | Throw the gun (aims itself at the teammate nearest the crosshair) |
| Walk into the gun | Catch it in the air or pick it up off the floor |
| R | Restart the room |
| Esc | Pause menu: resume, change roles, leave the match, quit |

The aim line shows where the shot or recall will go: orange for a shot, blue for a recall, **red** when it's blocked by a wall or would hit a teammate. Enemies on the path light up yellow.

### How it plays

- **Optional: time slows down while everyone stands still** (the host turns it on in the match lobby). Everything slows: players, enemies, bullets, enemy shots and thrown guns. A **TIME SLOWS** cut-in, a **TIME SLOWED** banner and a cool grey screen make it obvious. Pressing any movement key speeds time back up over a quarter of a second. Use it to plan a shot, line up a recall, or watch an enemy bullet coming.
- **Enemies come in three kinds**, told apart by silhouette and colour (weapon and belt): **gunmen** (red, pistol; shoot from range, then take a while to reload), **swordsmen** (steel, long sword) and **brawlers** (lime, big fists). An enemy flashes white while it winds up an attack.
- **Crates** are waist-high cover: crouch behind them, jump on them, and note that bullets stick in them like walls.
- The **ATTEMPT** counter under TARGETS counts your tries at the current room; it resets when you clear it.

### Playing online (eduroam, managed machines)

Put the server's **IP address** in **SERVER** and click **PLAY ONLINE**. Everyone does this and meets in the **match lobby**. Nobody needs firewall changes or admin rights: players only make outgoing connections to the server, over UDP when the network allows it and over HTTPS (port 443) when it doesn't. The HTTPS route checks the server against `assets/server.crt`, its certificate built into the game. Setting up the server on AWS EC2 is in [`server/README.md`](server/README.md).

### The match lobby

Up to **4 players** meet in the **match lobby**, which has two columns: **NORMAL · FIRE** and **INVERTED · RECALL**. Newcomers join the smaller column; anyone can switch with **JOIN NORMAL** / **JOIN INVERTED**, and **the host can click any player to move them**. The game can't start until there's **at least one player in each column** and everyone has clicked **READY UP** (click **CANCEL** to un-ready). The host is shown at the top right. On the left is the **map grid**, which only the host can change: **RANDOM** (a new procedural room every time) is the one to play for now; TUTORIAL and ENDLESS are coming, and six more slots are free for future maps. Only the host sees the **match options** (whether time slows while everyone stands still). On the LAN the host is whoever clicked HOST A GAME; online, it's whoever joined the server first. Nobody can join a game that's already running.

In game, **Esc → CHANGE ROLES** takes everyone back to the match lobby. You return to **the same room**, and the attempt count doesn't go up for the trip (a wipe that just happened still counts). **LEAVE MATCH** goes back to the title screen. If someone leaves mid-game, the rest carry on as long as both roles are still covered (the gun drops where they stood); otherwise everyone goes back to the match lobby. A LAN host whose players all leave goes back to waiting for new ones.

Everyone must run the same build. If they don't (for example, the server wasn't updated), the game refuses the connection and says which versions it saw.

### Playing together on the same network


- One player clicks **HOST A GAME**. The hosting screen shows their address and, if needed, the exact firewall command for their machine.
- The other clicks **JOIN A GAME**: the host appears under *Games on your network* within a second or two (the network is only scanned while this page is open). Or type the host's address under *Or join by address* (`192.168.0.12`, or `192.168.0.12:7777`). Over the internet, the host forwards UDP port **7777**.

Two windows on one machine work too.

**Firewall: only the host needs to do anything.** The game uses UDP **7777** (the game) and **7778** (finding games on the LAN). Joining players need no firewall changes: the lobby asks every machine on the local network directly, and the answers come back as replies, which firewalls let through. The **host** has to let both ports in:

| Host OS | Command |
|---|---|
| Rocky / RHEL / Fedora (firewalld) | `sudo firewall-cmd --add-port=7777/udp --add-port=7778/udp` (add `--permanent` and reload to keep it after a reboot) |
| Ubuntu / Debian (ufw) | `sudo ufw allow 7777/udp && sudo ufw allow 7778/udp` |
| Windows | Click **Allow** (private networks) when Windows Defender Firewall asks the first time you host |

If you can't change the host's firewall (for example on a locked-down managed machine), let the other player host instead.

### If something goes wrong

| Problem | Fix |
|---|---|
| Mouse stuck in the window | Press **Esc** to free it |
| The game won't close | `pkill -f SuperTenet` (or `pkill -9 -f SuperTenet`); on Windows, end it in Task Manager |
| Frozen or very slow window | The game restarts itself on the lighter OpenGL renderer when it detects software (CPU) rendering. To force it: `./SuperTenet.x86_64 --rendering-method gl_compatibility`. The OpenGL look is plainer (no ink outlines) |
| Audio errors | The game has no sound yet and uses Godot's silent audio driver, so it never opens your sound device. If you still see audio errors, you're running an older build |

## Building an executable (Linux or Windows)

| On | Run |
|---|---|
| Linux | `tools/build.sh` |
| Windows | double-click `tools\build.bat` (or run it from a terminal) |

The build works out which OS you're on and builds for it:

| Output | Runs on |
|---|---|
| `build/linux/SuperTenet.x86_64` | 64-bit Linux |
| `build/windows/SuperTenet.exe` | 64-bit Windows |

Each is a **single self-contained file** with the game packed inside (about 75 MB on Linux, 110 MB on Windows). **Running it needs nothing else, not even Godot**: copy it over and run it (on Linux, `chmod +x` it first if needed). To build for the other OS too, pass `-target windows`, `-target linux` or `-target all`; either OS can build both.

**Building needs nothing installed either.** `tools/build.sh` and `tools/build.bat` run a small prebuilt builder from `tools/bin/` (a static Go program, source in `tools/builder/`): no Python, unzip or curl. It uses Godot 4.7 from `$GODOT` or your PATH if you have it. Otherwise it downloads the official Godot 4.7.2 once into your cache folder (`~/.cache/one-gun-one-bullet`, or `%LOCALAPPDATA%\one-gun-one-bullet` on Windows) and keeps Godot's settings there too. Export templates are read straight out of Godot's 1.3 GB all-platform bundle with HTTP range requests, so only the ~35-40 MB per platform you build for is downloaded. A first build takes about 30 seconds (tested on a bare Rocky Linux 8).

To change the builder, edit `tools/builder/main.go` and rebuild the binaries with Go 1.21 or newer:

```sh
cd tools/builder
for t in linux/amd64 linux/arm64 windows/amd64; do
  os=${t%/*}; arch=${t#*/}; ext=; [ $os = windows ] && ext=.exe
  CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -trimpath -ldflags="-s -w" -o ../bin/onegun-build-$os-$arch$ext .
done
```

## Command-line options

Pass these after `--`, for example `godot --path . -- --host`:

| Flag | Effect |
|---|---|
| `--host` / `--join=IP` / `--port=N` | Skip the lobby |
| `--join=lan` | Join the first game found on the LAN |
| `--online=ADDRESS` | Join through a server (an IP, `ip:udp_port`, or a `wss://` / `ws://` URL) |
| `--server` | Run as the dedicated online server (use with `--headless`). `--tls-dir=DIR` holds its key and certificate (made on first run; without it the WebSocket is unencrypted, for testing), `--ws-port=N` (default 443), `--ws-bind=ADDR` (default all) |
| `--bot` | An autopilot plays your role (for testing) and logs events |
| `--peaceful` | Host or server only: enemies chase but never attack |
| `--slowmo` | Host or server only: start with slow motion turned on (it's normally chosen in the match lobby) |
| `--shots=DIR` | With `--bot`: save a screenshot every 0.5 s plus a room overview |
| `--log` | Print gameplay events |
| `--no-gl-fallback` | Don't switch to OpenGL on software rendering |
| `--quit-after=SECONDS` | Exit after a while |
| `--wait-players=N` | With `--bot`: ready up once N players are in the match lobby (default 2) |
| `--swap-after=SECONDS` | With `--bot`: ask to change roles after a while, then take the other role (testing) |

## Testing

Logic tests (room generation, recall curve, throw arcs, LAN discovery packets):

```sh
godot --headless --path . --script res://tests/test_runner.gd
```

Full networked loop, headless, two bots on one machine:

```sh
godot --headless --path . -- --host --bot --peaceful --quit-after=40 &
godot --headless --path . -- --join=127.0.0.1 --bot --peaceful --quit-after=38
```

Both processes print the same event timeline (fire, kill, throw, catch, recall, back in gun, ...).

## How it's built

- `scripts/main.gd`: entry point and the **only network router**. Every RPC lives here, so node paths always match on both machines, and moving to a central server later means changing who runs the host branches in this one file.
- Latency: each player owns **their own movement** and **the bullet they launch**, and decides **hits on themselves**, so nothing you do waits on the network. Only small events cross the wire. The room is rebuilt from a seed, and straight shots and gun throws are re-simulated locally and fast-forwarded by half the measured ping. State streams use unreliable channels separate from reliable events, and the network is polled right after each physics tick.
- Memory and compute: the walls are one MultiMesh plus one static body, the floor is one shader-tiled plane, enemy bullets, debris and aim lines are pooled MultiMeshes, meshes and materials are shared, and idle systems switch off their per-frame processing.
- Online play: `scripts/dual_server_peer.gd` lets the dedicated server accept UDP (ENet) and WebSocket players at the same time, and Godot's server relay passes messages between them. Clients try UDP for 2.5 s, then fall back to `wss://<server ip>:443`, trusting only the certificate in `assets/server.crt`. `server/` holds the EC2 setup script and guide.
- `scripts/lan_discovery.gd`: LAN discovery. The host answers on UDP 7778 and broadcasts a beacon once a second while its match lobby has room. The lobby sends small queries to the broadcast addresses and directly to every address in its local /24 networks (about 200 a second); the answers are replies to its own packets, so they get through the joiner's firewall.
- `scripts/room_gen.gd`: deterministic procedural room: walls, waist-high crates, enemies kept away from the spawn, always fully connected.
- Slow motion: `scripts/clock.gd` holds the world's speed. The host decides it (both players still = slow) and sends it with every enemy update; each player also speeds time up the instant they move. Enemies, bullets, enemy shots, thrown guns and debris scale their time by it; players, aiming and networking never do.
- `scripts/bullet.gd`, `gun.gd`, `enemy.gd`, `player.gd`: gameplay objects.
- `scripts/hud.gd`, `hand.gd`, `lobby.gd`, `world_fx.gd`, `shaders/comic.gdshader`: the comic-print look (ink outlines, halftone, posterize, rewind tint).

## Layout

- `scenes/`: `.tscn` scenes (`main.tscn` is the entry point; everything else is built in code)
- `scripts/`: GDScript files
- `shaders/`: comic post-process, floor and pulse-ring shaders
- `tests/`: headless logic tests
- `tools/build.sh`, `tools/build.bat`: one-command builds for Linux and Windows
- `tools/builder/`, `tools/bin/`: the Go build tool and its prebuilt static binaries
- `assets/fonts/`: Anton (SIL Open Font License, see `OFL-Anton.txt`), bundled so no system fonts are needed
- `export_presets.cfg`: Linux and Windows export presets (single file, game embedded)
- `game-style/`: style brief and reference screenshots (ignored by Godot)
- `assets/`: art, audio, fonts
