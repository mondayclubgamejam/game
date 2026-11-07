"""Builds the weapon models and exports one .glb each into assets/models/.

Run with tools/blender/build.sh (Blender in the background, no window).
For preview renders:  blender -b --factory-startup --python tools/blender/weapons.py -- --preview DIR

Every weapon points along Blender +Y (Godot -Z after export) with its origin
where the hand holds it (the revolver: at the frame). Pieces are joined into
one object per material, named for the game to colour:
  dark    near-black metal
  steel   lighter metal
  accent  the enemy kind's colour (muzzle band, sword blade, knife guard)
  blade   the knife's steel blade
  grip    the revolver's grip
  drum    the revolver's cylinder (glows when loaded)
"""

import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT_DIR = os.path.join(ROOT, "assets", "models")


# --- Shapes --------------------------------------------------------------------

def box(bm, size, center, rot_x=0.0, bevel=0.0025):
    """A box with softly bevelled edges, optionally tipped about X."""
    m = Matrix.Translation(center) @ Matrix.Rotation(rot_x, 4, "X") @ Matrix.Diagonal((*size, 1.0))
    made = bmesh.ops.create_cube(bm, size=1.0, matrix=m)
    if bevel > 0.0:
        verts = set(made["verts"])
        edges = [e for e in bm.edges if e.verts[0] in verts and e.verts[1] in verts]
        bmesh.ops.bevel(bm, geom=edges, offset=bevel, segments=2, affect="EDGES", profile=0.5)


def cyl(bm, radius, length, center, axis="Y", segments=20, radius2=None):
    """A cylinder (or cone, with radius2) along an axis."""
    rot = {"X": Matrix.Rotation(math.pi / 2, 4, "Y"), "Y": Matrix.Rotation(math.pi / 2, 4, "X"),
        "Z": Matrix.Identity(4)}[axis]
    m = Matrix.Translation(center) @ rot
    bmesh.ops.create_cone(bm, cap_ends=True, segments=segments, radius1=radius,
        radius2=radius if radius2 is None else radius2, depth=length, matrix=m)


def ring(bm, major, minor, center, axis="X", segments=20, sides=8, arc=1.0, start=0.0):
    """A torus, or part of one (arc < 1), around an axis."""
    full = arc >= 0.999
    n = segments if full else segments + 1
    rings = []
    for i in range(n):
        a = start + (arc * math.tau) * i / segments
        u = Vector((0.0, math.cos(a), math.sin(a)))  # in the YZ plane, axis X
        ring_v = []
        for j in range(sides):
            b = math.tau * j / sides
            p = u * (major + minor * math.cos(b)) + Vector((minor * math.sin(b), 0.0, 0.0))
            ring_v.append(p)
        rings.append(ring_v)
    rot = {"X": Matrix.Identity(3), "Y": Matrix.Rotation(-math.pi / 2, 3, "Z"),
        "Z": Matrix.Rotation(math.pi / 2, 3, "Y")}[axis]
    verts = [[bm.verts.new(rot @ p + Vector(center)) for p in r] for r in rings]
    for i in range(segments if full else n - 1):
        a, b = verts[i], verts[(i + 1) % n]
        for j in range(sides):
            bm.faces.new((a[j], a[(j + 1) % sides], b[(j + 1) % sides], b[j]))


def blade(bm, start, length, width, thick, curve):
    """A tapered, slightly curved blade along +Y, edge down, spine up, with a point."""
    steps = 14
    sections = []
    for i in range(steps + 1):
        t = i / steps
        y = start + length * t
        z = curve * t * t
        w = width * (1.0 - 0.25 * t) if t < 0.86 else width * 0.75 * (1.0 - (t - 0.86) / 0.14)
        w = max(w, 0.0005)
        spine = z + w * 0.35
        edge = z - w * 0.65
        sections.append([bm.verts.new(v) for v in (
            (0.0, y, spine), (thick * 0.5, y, z + w * 0.15), (0.0, y, edge), (-thick * 0.5, y, z + w * 0.15))])
    for a, b in zip(sections, sections[1:]):
        for j in range(4):
            bm.faces.new((a[j], a[(j + 1) % 4], b[(j + 1) % 4], b[j]))
    bm.faces.new(list(reversed(sections[0])))
    bm.faces.new(sections[-1])


# --- Weapons -------------------------------------------------------------------

def pistol():
    """A compact semi-automatic, origin in the middle of the grip."""
    dark, accent = bmesh.new(), bmesh.new()
    box(dark, (0.030, 0.205, 0.036), (0.0, 0.060, 0.074))             # slide
    box(dark, (0.026, 0.150, 0.024), (0.0, 0.040, 0.048))             # frame under the slide
    box(dark, (0.030, 0.050, 0.118), (0.0, -0.010, -0.004), rot_x=0.26)  # grip, raked back
    box(dark, (0.034, 0.054, 0.012), (0.0, -0.026, -0.060), rot_x=0.26)  # magazine base
    ring(dark, 0.022, 0.0035, (0.0, 0.040, 0.028), axis="X", arc=0.55, start=math.pi * 0.95)  # trigger guard
    box(dark, (0.006, 0.008, 0.022), (0.0, 0.034, 0.030), rot_x=-0.2)  # trigger
    for i in range(5):                                                 # slide serrations
        box(dark, (0.032, 0.004, 0.026), (0.0, -0.030 + i * 0.008, 0.076), bevel=0.0)
    box(accent, (0.033, 0.010, 0.040), (0.0, 0.160, 0.074), bevel=0.002)  # muzzle band
    box(accent, (0.006, 0.010, 0.010), (0.0, 0.150, 0.096), bevel=0.0)    # front sight
    return {"dark": dark, "accent": accent}


def sword():
    """A long, slightly curved single-edged sword, origin at the hand on the grip."""
    dark, steel, accent = bmesh.new(), bmesh.new(), bmesh.new()
    cyl(dark, 0.016, 0.26, (0.0, 0.02, 0.0), axis="Y", segments=10)       # wrapped grip
    for i in range(6):                                                    # wrap ridges
        ring(dark, 0.0165, 0.003, (0.0, -0.08 + i * 0.04, 0.0), axis="Y", segments=12, sides=5)
    cyl(steel, 0.020, 0.024, (0.0, -0.12, 0.0), axis="Y", segments=10)    # pommel
    m = Matrix.Translation((0.0, 0.158, 0.0)) @ Matrix.Rotation(math.pi / 2, 4, "X") @ Matrix.Diagonal((1.0, 0.75, 1.0, 1.0))
    bmesh.ops.create_cone(steel, cap_ends=True, segments=16, radius1=0.048, radius2=0.048, depth=0.012, matrix=m)  # guard
    cyl(steel, 0.018, 0.03, (0.0, 0.178, 0.004), axis="Y", segments=10)   # collar
    blade(accent, 0.19, 0.82, 0.036, 0.008, 0.035)
    return {"dark": dark, "steel": steel, "accent": accent}


def knife():
    """A fighting knife, origin at the hand on the grip."""
    dark, accent, blade_bm = bmesh.new(), bmesh.new(), bmesh.new()
    box(dark, (0.024, 0.115, 0.028), (0.0, 0.0, 0.0), bevel=0.006)        # grip
    for i in range(3):                                                    # finger grooves
        box(dark, (0.026, 0.008, 0.006), (0.0, -0.03 + i * 0.03, -0.015), bevel=0.0)
    box(accent, (0.028, 0.012, 0.062), (0.0, 0.062, 0.004), bevel=0.003)  # guard
    box(accent, (0.028, 0.016, 0.032), (0.0, -0.064, 0.0), bevel=0.004)   # pommel
    blade(blade_bm, 0.068, 0.20, 0.034, 0.006, 0.004)
    return {"dark": dark, "accent": accent, "blade": blade_bm}


def revolver():
    """The players' one gun: a heavy revolver, origin at the frame."""
    steel, dark, grip, drum = bmesh.new(), bmesh.new(), bmesh.new(), bmesh.new()
    box(steel, (0.034, 0.118, 0.066), (0.0, 0.004, 0.012))               # frame
    box(steel, (0.030, 0.100, 0.012), (0.0, 0.004, 0.052))               # top strap
    cyl(steel, 0.0165, 0.24, (0.0, 0.180, 0.036), axis="Y", segments=16)  # barrel
    box(steel, (0.020, 0.200, 0.020), (0.0, 0.170, 0.016))               # under-lug
    box(dark, (0.012, 0.230, 0.010), (0.0, 0.180, 0.056), bevel=0.002)   # rib
    box(dark, (0.006, 0.012, 0.018), (0.0, 0.288, 0.064), bevel=0.0)     # front sight
    cyl(dark, 0.0085, 0.012, (0.0, 0.302, 0.036), axis="Y", segments=12)  # muzzle bore
    box(dark, (0.014, 0.030, 0.036), (0.0, -0.066, 0.056), rot_x=-0.5)   # hammer
    ring(dark, 0.026, 0.0035, (0.0, 0.012, -0.030), axis="X", arc=0.55, start=math.pi * 0.95)  # trigger guard
    box(dark, (0.006, 0.008, 0.026), (0.0, 0.006, -0.032), rot_x=-0.25)  # trigger
    box(grip, (0.034, 0.052, 0.122), (0.0, -0.074, -0.062), rot_x=-0.38, bevel=0.008)  # grip
    box(steel, (0.036, 0.040, 0.012), (0.0, -0.096, -0.118), rot_x=-0.38)  # butt cap
    cyl(drum, 0.040, 0.074, (0.0, 0.004, 0.022), axis="Y", segments=18)  # cylinder
    for i in range(6):                                                    # flutes between chambers
        a = math.tau * i / 6
        box(dark, (0.010, 0.056, 0.010), (math.cos(a) * 0.038, 0.004, 0.022 + math.sin(a) * 0.038), bevel=0.0)
    for i in range(6):                                                    # chamber mouths on the front
        a = math.tau * i / 6 + math.pi / 6
        cyl(dark, 0.007, 0.004, (math.cos(a) * 0.024, 0.042, 0.022 + math.sin(a) * 0.024), axis="Y", segments=8)
    return {"steel": steel, "dark": dark, "grip": grip, "drum": drum}


WEAPONS = {"pistol": pistol, "sword": sword, "knife": knife, "revolver": revolver}


def export(name, parts):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    for part, bm in parts.items():
        mesh = bpy.data.meshes.new(part)
        bm.to_mesh(mesh)
        bm.free()
        for poly in mesh.polygons:
            poly.use_smooth = False
        obj = bpy.data.objects.new(part, mesh)
        bpy.context.collection.objects.link(obj)
    path = os.path.join(OUT_DIR, name + ".glb")
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", export_yup=True,
        export_materials="NONE", export_animations=False)
    tris = sum(len(p.vertices) - 2 for o in bpy.data.objects for p in o.data.polygons)
    print("[blender] wrote %s (%d triangles)" % (path, tris))


COLOURS = {"dark": (0.06, 0.05, 0.08), "steel": (0.35, 0.33, 0.42), "accent": (1.0, 0.2, 0.25),
    "grip": (0.45, 0.25, 0.14), "drum": (1.0, 0.48, 0.1), "blade": (0.55, 0.58, 0.68)}


def preview(name, out_dir):
    """A quick flat render of the weapon in the current scene, from the side."""
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.light = "STUDIO"
    scene.display.shading.color_type = "OBJECT"
    for obj in bpy.data.objects:
        obj.color = (*COLOURS[obj.name], 1.0)
    scene.render.resolution_x = 900
    scene.render.resolution_y = 500
    scene.world = bpy.data.worlds.new("w")
    cam_data = bpy.data.cameras.new("cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = 1.15 if name == "sword" else (0.36 if name == "knife" else 0.42)
    cam = bpy.data.objects.new("cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    mid = 0.4 if name == "sword" else 0.08
    cam.location = (2.0, mid - 0.9, 0.55)
    cam.rotation_euler = (math.radians(75), 0.0, math.radians(65))
    scene.render.filepath = os.path.join(out_dir, "weapon_" + name + ".png")
    bpy.ops.render.render(write_still=True)


def main():
    args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    out = args[args.index("--preview") + 1] if "--preview" in args else None
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, build in WEAPONS.items():
        export(name, build())
        if out:
            os.makedirs(out, exist_ok=True)
            preview(name, out)


main()
