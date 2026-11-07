# Style Brief: Comic Pop Shooter

A bold, graphic, high-energy look: flat colour, heavy ink, halftone print, and
UI that slashes across the screen. It's inspired by stylish comic and pop-art
game UIs in general, but the palette, shapes and type are our own. **Don't copy
any one game's logos, fonts, UI layouts or colour scheme.**

Screenshots are in [`screenshots/`](screenshots/). They're captured from the
current build with `godot --path . -- --shots=game-style/screenshots`.

## Pillars

1. **Readable in one glance.** Judges need to understand "fire forward, recall
   back" in seconds. Every gameplay state has a colour and a shape.
2. **Printed comic page, not realism.** Flat fills, ink lines, halftone dots,
   few colour steps. No textures, no realistic lighting.
3. **Time has a direction you can see.** Going forward is warm, punchy and
   outward. Going backward (the recall) is cold, inward and plays in reverse.

## Palette

| Role | Colour | Hex |
|---|---|---|
| Forward time, the shot, player A | Hot orange | `#ff7a1a` |
| Inverted time, the recall, player B | Cold blue | `#2fa8ff` |
| Enemies, targets panel, CLEAR | Hot magenta | `#ff2e88` |
| Doors, exits, level titles | Signal yellow | `#ffcc1a` |
| Targeted enemy glow | Pale yellow | `#ffe14d` |
| Blocked / danger | Red | `#ff3344` |
| Ink (outlines, panel borders) | Purple-black | `#1a1026` |
| Walls / ceiling | Pale violet-white | `#ebe7ef` / `#f4f2f6` |
| Floor checker | Warm off-white | `#f1eee9` / `#e6e1da` |
| Sky | Violet to pink gradient | `#2a1446` / `#ff6fa8` |

Rule of thumb: **orange and blue mean time direction**, and nothing else uses
them. Magenta means "shoot this". Yellow means "go here".

## Environment

Enclosed, pale rooms: a ceiling with glowing light panels, and a window wall
along the back (+Z) whose openings let a low sun lay bright shafts across the
floor. The sky shows through the windows. Walls, floor and crates stay near
white so the role colours, magenta enemies and yellow gun are the only colour.

## Rendering (see `shaders/comic.gdshader`)

**The comic look is currently off** (`COMIC` in `scripts/palette.gd`): plain
smooth shading with soft shadows and ambient occlusion. With it on:

- **Toon lighting:** `DIFFUSE_TOON`, no specular, so every surface has two or three flat bands.
- **Ink outlines:** a full-screen pass finds depth and normal edges and draws
  them in purple-black, about 1.6 px. Outlines are what make it read as a comic.
- **Halftone:** 45° dot screen in the shadows. Dots grow as the tone darkens.
- **Posterize:** about 6 steps per channel, in sRGB space.
- **Effects skip the ink:** bullets, aim lines and flashes are transparent and
  emissive, so they draw over the ink pass, glow, and never get outlined.

## Animation

**Core rule: the recall is the shot played backwards.** Most recall animation
is the fire animation reversed, which halves the work and makes inversion
obvious at once.

| Moment | Forward (fire) | Inverted (recall) |
|---|---|---|
| Hand | Fast kick up and back (0.04 s), elastic settle (0.3 s) | Yanked *forward* toward the target, elastic settle |
| Gun slide | Locks back, the empty chamber glows orange | Snaps forward, closed |
| Flash | Yellow and white starburst at the muzzle | Blue rings collapsing *into* the barrel |
| Bullet | Orange slug plus trail, flies outward at 70 m/s | Blue slug plus trail, flies back to the gun |
| Camera | Strong shake | Medium shake on arrival |

- **Timing:** snappy attacks (under 0.06 s) with soft, overshooting recovery
  (`TRANS_BACK`). Nothing floats.
- **Walk bob:** a figure-eight sway that grows with speed.
- **Enemies:** faceless, faceted low-poly mannequins in magenta, with a belt and weapon coloured by kind. Rigid parts: the legs swing to walk and the weapon arm winds up. Model: `tools/blender/enemy.py`.
- **Weapons:** near-black metal with one accent in the kind colour: a pistol with a red muzzle band, a curved sword with a blue-steel blade, a lime-guarded knife in each hand for the knife fighters. The players' revolver has a cylinder that glows orange when loaded. Models: `tools/blender/weapons.py`.
- **Enemy death:** bursts into 12 tumbling cubes that shrink away after 2 to 3 s.
  Later, the recall could reassemble them in reverse.
- **Doors:** wind up, then rise fast (`TRANS_BACK`, ease in).

## UI and cut-ins (see `scripts/hud.gd`)

- **Slanted panels everywhere.** Parallelograms with a thick ink border and a
  flat colour fill. No rounded corners and no flat rectangles.
- **Type:** heavy sans, white with a thick ink outline, always upper case.
- **Cut-in banners** slash across the screen at -6° for big moments:
  - `DOWN!` / `DOUBLE!` / `TRIPLE!` in orange when the shot does it, blue when the recall does
  - `CLEAR!` in magenta, `BLOCKED!` in red, the level title in yellow
  - motion: overshoot in (0.2 s), hold (0.6 s), whip out (0.16 s)
- **HUD:** bullet state at the bottom left (LOADED / FIRING / EMPTY / RETURN), target count at the top left, a crosshair, and a small control hint.

## In progress: time effects

Another work stream is adding time effects to the post shader. These follow
the same pillars:
- **Rewind look:** cold duotone, white ink, halftone moving into the highlights and drifting backwards
- **Misregistration:** the orange and blue colour layers slip apart, like a badly aligned print
- **Speed lines:** streaming outward going forward, sucked inward when rewinding
- **Impact flash:** the frame drops to paper, accent and ink for a beat

## Not doing

- Realistic textures, PBR shine, bloom haze over everything
- Copying any existing game's logos, fonts, menus or signature colour scheme
- Gradients in the UI (flat fills only)
