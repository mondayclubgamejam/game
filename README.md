# One Gun, One Bullet

Monday Club game jam project, built with [Godot 4.7](https://godotengine.org/).

A two-player online co-op shooter about time direction. Two players share **one gun with one bullet**:

- **Player A (forward, the host)** can only **fire**. The bullet passes through every enemy in its path and sticks in the first wall.
- **Player B (reverse, the joiner)** can only **recall**. The bullet rips out of wherever it stuck and curves back into B's gun, killing everything on the way. A recall can't pass through walls: it sticks in any wall in the way, and B has to find a clear angle.

So you must **throw the gun to each other** after every shot and every recall. Carrying the gun slows you down. Friendly fire is on, enemies die in one hit and so do you, and if either player dies the room restarts. Clear every enemy to get a new procedurally generated room.

Design spec: [`docs/superpowers/specs/2026-11-07-tenet-coop-mvp-design.md`](docs/superpowers/specs/2026-11-07-tenet-coop-mvp-design.md). Visual style: [`game-style/STYLE_BRIEF.md`](game-style/STYLE_BRIEF.md).

## Getting started

1. Install Godot 4.7 (`brew install --cask godot` on macOS).
2. Open Godot, choose **Import**, and select `project.godot` in this folder.
3. Press **F5** to run.

### Playing together

- One player clicks **HOST (A)**.
- On the same network, the other player sees **JOIN <NAME>'S GAME** appear under *Games on your network* within a second and clicks it.
- Otherwise, type the host's IP (shown at the bottom of the host's lobby) and click **JOIN (B)**. Over the internet, the host forwards UDP port **7777**.

Two windows on one machine work too: they find each other the same way.

**Firewall:** the game uses UDP **7777** (game) and **7778** (finding games on the LAN). On Windows, allow the game when the firewall asks. On Linux with a firewall on (for example `ufw` on Ubuntu), allow the ports on both machines:

```sh
sudo ufw allow 7777:7778/udp
```

## Building an executable (Linux or Windows)

| On | Run |
|---|---|
| Linux | `./build.sh` |
| Windows | double-click `build.bat` (or run it from a terminal) |

The build works out which OS you're on and builds for it:

| Output | Runs on |
|---|---|
| `build/linux/OneGunOneBullet.x86_64` | 64-bit Linux |
| `build/windows/OneGunOneBullet.exe` | 64-bit Windows |

Each is a **single self-contained file** with the game packed inside (about 75 MB on Linux, 110 MB on Windows). **Running it needs nothing else, not even Godot**: copy it over and run it (on Linux, `chmod +x` it first if needed). To build for the other OS too, pass `--target windows`, `--target linux` or `--target all`. Godot can cross-build either one from either OS.

Building only needs **Python 3** ([python.org](https://www.python.org/downloads/) on Windows). The build uses Godot 4.7 from `$GODOT` or your PATH if you have it. Otherwise it downloads the official Godot 4.7.2 once into a cache folder (`~/.cache/one-gun-one-bullet`, or `%LOCALAPPDATA%\one-gun-one-bullet` on Windows) and keeps its settings there too. Export templates come out of Godot's 1.3 GB all-platform bundle via HTTP range requests, so only the ~35 MB you need is downloaded. A first build from a fresh clone takes about 30 seconds.

On Windows, the first time you host, Windows Defender Firewall asks whether to allow the game on the network. Allow it on **private networks**, or the other player can't find or join you.

## Command-line options

Pass these after `--`, for example `godot --path . -- --host`:

| Flag | Effect |
|---|---|
| `--host` / `--join=IP` / `--port=N` | Skip the lobby |
| `--join=lan` | Join the first game found on the LAN |
| `--bot` | An autopilot plays your role (for testing) and logs events |
| `--peaceful` | Host only: enemies chase but never attack |
| `--shots=DIR` | With `--bot`: save a screenshot every 0.5 s plus a room overview |
| `--log` | Print gameplay events |
| `--quit-after=SECONDS` | Exit after a while |

## Testing

Logic tests (room generation, recall curve, throw arcs):

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
- `scripts/lan_discovery.gd`: LAN discovery. Hosts broadcast a small UDP beacon on port 7778 once a second until a partner joins; the lobby listens and lists them.
- `scripts/room_gen.gd`: deterministic procedural room (always fully connected, enemies kept away from the spawn).
- `scripts/bullet.gd`, `gun.gd`, `enemy.gd`, `player.gd`: gameplay objects.
- `scripts/hud.gd`, `hand.gd`, `lobby.gd`, `world_fx.gd`, `shaders/comic.gdshader`: the comic-print look (ink outlines, halftone, posterize, rewind tint).

## Layout

- `scenes/`: `.tscn` scenes (`main.tscn` is the entry point; everything else is built in code)
- `scripts/`: GDScript files
- `shaders/`: comic post-process, floor and pulse-ring shaders
- `tests/`: headless logic tests
- `build.sh`, `build.bat`, `tools/build.py`: one-command builds for Linux and Windows
- `export_presets.cfg`: Linux and Windows export presets (single file, game embedded)
- `game-style/`: style brief and reference screenshots (ignored by Godot)
- `assets/`: art, audio, fonts
