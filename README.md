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

- One player clicks **HOST (A)**. The lobby lists that machine's IP addresses.
- The other player types the host's IP and clicks **JOIN (B)**.
- On the same network this just works. Over the internet, the host forwards UDP port **7777** (or a port you pick in the lobby).

Two windows on one machine work too: host in one, join `127.0.0.1` in the other.

### Controls

| Input | Action |
|---|---|
| WASD / arrows | Move |
| Mouse | Look and aim |
| Left click / F | Fire (A) or recall (B) |
| Right click / Q | Throw the gun (aims itself at your partner when they're near the crosshair) |
| Walk into the gun | Catch it in the air or pick it up off the floor |
| R | Restart the room |
| Esc | Free the mouse |

The aim line shows where the shot or recall will go: orange for a shot, blue for a recall, **red** when it's blocked by a wall or would hit your partner. Enemies on the path light up yellow.

## Command-line options

Pass these after `--`, for example `godot --path . -- --host`:

| Flag | Effect |
|---|---|
| `--host` / `--join=IP` / `--port=N` | Skip the lobby |
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
- `scripts/room_gen.gd`: deterministic procedural room (always fully connected, enemies kept away from the spawn).
- `scripts/bullet.gd`, `gun.gd`, `enemy.gd`, `player.gd`: gameplay objects.
- `scripts/hud.gd`, `hand.gd`, `lobby.gd`, `world_fx.gd`, `shaders/comic.gdshader`: the comic-print look (ink outlines, halftone, posterize, rewind tint).

## Layout

- `scenes/`: `.tscn` scenes (`main.tscn` is the entry point; everything else is built in code)
- `scripts/`: GDScript files
- `shaders/`: comic post-process, floor and pulse-ring shaders
- `tests/`: headless logic tests
- `game-style/`: style brief and reference screenshots (ignored by Godot)
- `assets/`: art, audio, fonts
