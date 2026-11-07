# Game Jam Plan: One Gun, One Bullet

**Theme:** Time
**Target prizes:** Best Co-op Game, Most Innovative Use of Theme
**Engine:** Godot 4.7, 3D

## Pitch

A Tenet-inspired local co-op game in 3D. Two players share **one gun** and **one bullet**. Player A moves forward through time and can only **fire** the bullet. Player B is **inverted** and can only **recall** it, pulling the bullet out of whatever it hit and back into the gun. Neither player can do anything useful alone.

## 3D Approach

The game is 3D but plays on a mostly flat floor, so it stays readable and quick to build.

- **Camera:** one shared camera, angled top-down (about 50 to 60 degrees), that follows the midpoint of both players and zooms out as they separate. No split screen. Both players see every bullet line at once, which matters for planning shots together.
- **Aiming:** twin-stick style. Aim on the horizontal plane at gun height. Shots and recalls are straight lines parallel to the floor, which keeps lineups readable from above. Show a laser aim line for the gun holder.
- **Height:** used sparingly, for ledges, raised walkways and falling boxes. Bullets do not arc.
- **Input:** two gamepads, or one keyboard split (WASD + mouse for A, arrows + numpad or a second pad for B).
- **Art:** greybox first using CSG shapes and simple materials. Two clear player colours (A warm orange, B cold blue). Swap in low-poly assets only if time allows.

### Godot building blocks
- Players: `CharacterBody3D` with a capsule collider and a `Marker3D` hand point for the gun.
- Gun: a `RigidBody3D` when dropped or thrown, reparented to the hand when held.
- Bullet: a fast `Area3D`, or a raycast from the muzzle. On fire, the bullet stops at the first wall and records every hit along the way.
- Recall: raycast from the lodged bullet back to B's muzzle, apply damage to everything on that line, then animate the bullet along it.
- Levels: `CSGBox3D` and `CSGCombiner3D` greybox scenes, one scene per level.

## Characters

| | Player A (forward) | Player B (inverted) |
|---|---|---|
| Gun ability | Fires the bullet forward | Recalls a lodged bullet back into the gun |
| Without the gun | Push, break, knock over, throw, pull levers, hold doors | Un-break, un-fall objects, close what A opened, rebuild cover |
| Look and feel | Normal animations and effects | Reversed animations, dust rising, sparks flowing back into impacts, reversed sound effects |

## Core Loop

1. A holds the loaded gun and fires. The bullet lodges in the world.
2. A passes the gun to B.
3. B aims at the lodged bullet and recalls it. It flies back into the gun along a straight line.
4. B passes the gun back to A.

### Gun state

| Holder | Bullet in gun | Bullet lodged in world |
|---|---|---|
| A | Can fire | Gun does nothing |
| B | Gun does nothing | Can recall |

Two handoffs per shot means constant coordination and makes every shot valuable.

## Key Mechanics

### Recall (inverted shot)
- The bullet rips out of where it lodged and flies straight back into B's gun.
- Damage it caused on the way in is undone (glass un-shatters, holes close).
- **The return path damages things.** One bullet can hit twice: A shoots through one enemy into a wall, then B positions so the return line passes through more enemies. Lining up shots is the main puzzle and skill element.
- Recall needs line of sight from the bullet to B. If a wall blocks it, B must move. Show the recall line as a preview before B commits.

### Passing the gun
To decide early, ideally by playtesting:
- Walk up and hand over
- Short throw and catch (most fun, adds risk such as landing somewhere awkward)
- Drop and pick up

**MVP default:** drop and pick up (simplest to build). Add throwing once the loop works.

Stretch idea: B's throw is an "un-throw", so the gun flies out of A's hand towards B.

### Inverted controls
Try literally reversed controls for B in the first hour. If it is just frustrating, keep controls normal and show the inversion through animations and effects instead. Players should spend effort on talking to each other, not on fighting the inputs.

## Animation Strategy

Many of B's animations are A's animations played in reverse:
- A's fire reversed = B's recall
- A's walk reversed = B's backwards walk
- A's throw reversed = B's catch

In Godot, `AnimationPlayer.play_backwards()` covers most of this. This roughly halves animation work and makes B look properly inverted.

## MVP Goals

The MVP is the smallest version that shows off the idea and can be judged. Everything else is extra.

**The MVP is done when:**
- [ ] Two players move around one 3D greybox room on one screen with a shared follow camera
- [ ] There is one gun, and either player can pick it up or drop it
- [ ] A can fire; the bullet stops in the first wall and stays visible there
- [ ] B can recall; the bullet travels back to the gun in a straight line
- [ ] Both the shot and the recall damage enemies they pass through
- [ ] Enemies are static targets that die in one hit
- [ ] An aim line shows where the next shot or recall will go
- [ ] A door opens when all enemies in a room are dead
- [ ] Three short levels, played in order, with a restart button
- [ ] A clear on-screen cue for who holds the gun and whether it is loaded

**Not in the MVP:** throwing the gun, glass, ropes, falling boxes, moving enemies, un-breaking, reversed sound, menus beyond a title card.

## Level Design

Levels are single rooms, roughly 20 by 15 metres, built from CSG boxes. Each one teaches one idea and should take under two minutes. Goal in every level: kill all targets, then walk both players through the exit door.

Legend for the layouts below: `#` wall, `A` / `B` player start, `G` gun, `E` enemy, `D` exit door, `S` shielded enemy, `|` glass, `.` floor.

### Level 1: Fire and Return (MVP)
Teaches the basic loop. One enemy in the way of the shot, one in the way of the return.

```
###############
#.............#
#..A.G........#
#.........E...#
#.............#
#..B......E...#
#.............#
#######D#######
```

- A picks up the gun and fires right through the top enemy into the wall.
- A drops the gun, B picks it up, walks to line up with the lodged bullet and the second enemy, and recalls through it.
- Lesson: the return trip is a second shot.

### Level 2: Two for One (MVP)
Teaches lining up a recall from a deliberate angle.

```
###############
#.............#
#..E.......E..#
#.............#
#.....###.....#
#.A.G.###...B.#
#.............#
#..E.......E..#
#######D#######
```

- Four enemies, a central pillar, one bullet. Players need two full cycles.
- The pillar blocks easy lines, so A must shoot at an angle that leaves B a clean return through a second enemy.
- Lesson: A should aim with B's position in mind.

### Level 3: Around the Shield (MVP)
Teaches using the return path to hit something from behind.

```
###############
#......#......#
#..A...#..S...#
#..G...#......#
#......d......#
#..B...#......#
#......#......#
#######D#######
```

- A shielded enemy `S` faces the doorway `d` and blocks shots from the front. `d` is an open doorway between the two halves.
- A fires past it into the back wall. B stands where the return line passes through the enemy's back and recalls.
- Lesson: recall direction matters, not just the shot.

### Level 4: Glass (post-MVP)
- A shoots through a glass wall to open a path. Both players go through.
- An enemy starts chasing. B recalls the bullet, the glass un-shatters behind them and blocks it.
- Lesson: recall undoes what the shot did.

### Level 5: The Bridge (post-MVP)
- A shoots a rope to drop a bridge over a gap. Both cross.
- Later, B recalls to raise the bridge again and cut off enemies on the far side, or to reach a ledge.
- Lesson: using undo as a tool, not just a side effect.

### Level design rules
- Keep the camera able to see the whole room at once.
- Every level must give the player without the gun something to do (positioning, a lever, a box).
- Place enemies so the "obvious" shot leaves a bad recall angle, which forces the players to talk.
- Use colour to show what can be shot, what blocks bullets and what can be undone.

## Build Order

### Phase 1: Core loop (must work by end of day one)
- [ ] Greybox test room with a shared follow camera
- [ ] Two `CharacterBody3D` players on separate inputs
- [ ] One gun that can be picked up and dropped
- [ ] A fires; the bullet lodges in walls
- [ ] B recalls; the bullet returns along a straight line
- [ ] Both directions damage enemies
- [ ] Aim line for the gun holder

If the loop is not fun by the end of day one, rethink before building more.

### Phase 2: MVP levels
- [ ] Levels 1 to 3 built and playable in sequence
- [ ] Exit door that opens when all enemies are dead
- [ ] Restart level button
- [ ] HUD cue for gun holder and loaded state

### Phase 3: Roles and twists
- [ ] Gun throwing, if playtests favour it
- [ ] Non-gun actions for A (push, break, levers)
- [ ] Non-gun actions for B (un-break, un-fall)
- [ ] Undo damage on recall (glass, holes)
- [ ] Levels 4 and 5

### Phase 4: Polish
- [ ] Reversed animations for B
- [ ] Reversed effects and sound for B
- [ ] Bullet trail and impact effects that read clearly from the top-down camera
- [ ] Title screen and a short intro explaining the roles

## Risks

- **Scope:** 3D costs more than 2D. Stay greybox until the MVP is done. Polish beats quantity.
- **Readability:** judges need to understand the inversion in seconds, so make reversed effects and aim lines obvious from the camera angle.
- **Aiming in 3D:** keep shots on a flat plane. Add aim assist or snap-to-bullet for B's recall if aiming feels fiddly.
- **Camera:** a shared camera can lose players at the edges. Keep rooms small and clamp how far apart players can move.
- **Idle player:** whoever lacks the gun must always have something to do.
- **Networking:** avoid it. Local co-op only.

## Open Questions

- How long is the jam?
- Handoff method: hand over, throw, or drop? (MVP uses drop)
- Real inverted controls or presentation only?
- Shared camera only, or split screen if players need to separate?
