# One Gun, One Bullet: Networked Co-op MVP

Branch: `nestor/mvp`. Engine: Godot 4.7, 3D, first person.
Visual reference: `game-style/STYLE_BRIEF.md` and `game-style/screenshots/` (comic-pop look). All code is new; nothing is reused from the `persona-style-graphics` branch.

## Intent

A two-player co-op shooter where time direction is split between the players. The players share **one gun with one bullet**:

- **Player A (forward)** can only fire.
- **Player B (reverse)** can only recall. Recalling rips the lodged bullet back into the gun.

So neither player can shoot twice in a row. They must **throw the gun to each other** between every shot and every recall. The fun is positioning: A picks what the bullet passes through on the way out, B picks what it passes through on the way back, and the throws are the risky moments in between.

Time runs normally (it is **not** a "time moves when you move" game). Enemies and players die in one hit.

## Rules (decided with the user)

### Players
- Two players on two devices. Peer to peer for now, with the host as the authority for the room, enemies and gun ownership. A central server may come later, so all game logic must route through one place that can move to a server.
- First-person camera for both players.
- **Carrying the gun slows you down** (it is heavy). With no gun, or while the gun is in the air, you move at full speed.
- *(Our call)* The host plays A (forward) and the joiner plays B (reverse).

### The bullet
- **A fires:** the bullet travels in a straight line, **passes through every enemy** on its path, and only stops at a wall, where it sticks. A miss still sticks wherever it lands, so a miss can be recalled.
- **B recalls:** the bullet leaves the way it went in, then curves toward B's gun (curved trajectory), killing every enemy on the way.
- **A recall cannot pass through walls.** If a wall is between the bullet and B, the bullet flies toward the gun, hits the wall and sticks there. B must move to a spot with a clear path and recall again.
- **Friendly fire is on in both directions.** A bullet kills your partner if they are on its path.
- The bullet is never lost: it is either in the gun, in flight, or stuck somewhere.

### The gun
- Exactly one gun. It is either held by a player, flying, or on the floor.
- **Throw:** aim and throw; the gun flies in an arc. If it passes close to the partner, they catch it automatically. If it lands, either player can walk over it to pick it up. *(Our call)* A gentle aim assist steers the throw toward the partner when they are roughly in the crosshair.
- **Enemies ignore the gun.**
- Gun state table:

| Holder | Bullet in gun | Bullet stuck in world |
|---|---|---|
| A | Can fire | Nothing to do: throw it |
| B | Nothing to do: throw it | Can recall |

### Enemies
- Three kinds: **gunmen** (shoot from range), **knife** and **fist** enemies (rush and hit up close).
- Enemy bullets travel at normal (fast) speed. *(Our call)* Gunmen show a short aim telegraph before firing so cover and timing matter.
- *(Our call)* Enemies stay idle until they see a player or hear the gun fire, so the players aren't rushed at spawn.
- One hit kills anyone, anywhere.

### Rounds
- If either player dies, the room restarts for both players with the same layout.
- *(Our call)* Clearing every enemy shows CLEAR and generates a new room from a new seed.

## MVP scope

Done when two people on two machines can connect, spawn in one procedurally generated room and play the full shoot, throw, recall loop against a room of enemies.

- **Connect:** host / join by IP (LAN, or internet with port forwarding). Command-line flags `--host` and `--join=IP` for quick testing.
- **Procedural room:** generated from a seed, so only the seed crosses the network. *(Our call)* A rectangular arena with random wall segments, pillars and blocks for cover, always fully connected, with 8 to 12 enemies placed away from the player spawn.
- **Look:** the comic-pop style from the brief: toon lighting, ink outlines, halftone shadows, posterize, orange = forward / A, blue = reverse / B, magenta = enemies, slanted HUD panels and cut-in banners.
- **Not in the MVP:** central server, menus beyond host/join, sound, more than one room type, difficulty curve, role swapping.

## Performance and latency requirements (from the user)

Optimise for memory, compute and **latency**:
- Each player is authoritative over their **own movement** (zero input latency) and over **the bullet they launch** (zero fire / recall latency; it is co-op, so trusting clients is fine).
- Each player decides hits on **themselves** (enemy bullets, melee, friendly fire), so what you see is what kills you.
- Remote peers simulate deterministic things locally (the room from a seed, straight bullet lines, thrown-gun arcs) and fast-forward by half the measured round trip, so only small events cross the wire.
- State streams (player transforms, packed enemy positions) use unreliable ordered channels separate from the reliable event channel, so a lost packet never stalls events.
- Rendering: walls drawn as one MultiMesh, floor as one shader-tiled plane, debris and enemy tracers pooled in MultiMeshes, shared materials, no per-frame allocations in hot paths.

## Left to the builder
Exact speeds, timings, colours within the brief's palette, HUD layout, controls (default: WASD + mouse look, left click fire/recall, right click throw).
