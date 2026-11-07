"""Builds the enemy mannequin and exports assets/models/enemy.glb.

Run with tools/blender/build.sh (Blender in the background, no window).
For preview renders:  blender -b --factory-startup --python tools/blender/enemy.py -- --preview DIR

The body is one continuous, smooth-shaded shape: a stick figure of joints
with a thickness at each (Blender's Skin modifier), subdivided, then trimmed
to a game-friendly polygon count. The head is a faceless skull shape joined on. A skeleton with named bones
is built over it and every vertex is weighted to its nearest bones, so the
game can bend hips, knees, shoulders and elbows.

Blender is Z-up; the glTF exporter turns Blender (x, y, z) into (x, z, -y),
so the model faces Blender +Y to end up facing Godot -Z. Right is +X in both.
Exports two skinned meshes: "body" (all of it) and "belt" (the accent ring).
No materials: the game applies its own.
"""

import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector
from mathutils.geometry import intersect_point_line

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "assets", "models", "enemy.glb")
TARGET_TRIS = 4200

# A ~1.85 m adult with realistic proportions (head about 1/8 of the height).
# Joints: name -> (position, skin radius x, skin radius y). Right side (+X);
# the left is mirrored. Front is +Y.
CENTRE = [
    ("pelvis", (0.0, -0.020, 0.96), 0.165, 0.124),
    ("waist", (0.0, 0.0, 1.10), 0.133, 0.094),
    ("ribs_low", (0.0, 0.012, 1.22), 0.150, 0.106),
    ("chest", (0.0, 0.028, 1.33), 0.170, 0.126),
    ("upper_chest", (0.0, 0.0, 1.43), 0.176, 0.104),
    ("neck_base", (0.0, -0.012, 1.53), 0.080, 0.072),
    ("neck_top", (0.0, 0.0, 1.655), 0.062, 0.060),
]
ARM = [  # a slight A-pose, so the arm never shares vertices with the torso
    ("shoulder", (0.200, 0.0, 1.455), 0.070, 0.070),
    ("deltoid", (0.220, 0.0, 1.400), 0.068, 0.066),
    ("bicep", (0.240, 0.004, 1.300), 0.056, 0.060),
    ("elbow", (0.258, -0.010, 1.190), 0.042, 0.043),
    ("forearm", (0.270, 0.002, 1.100), 0.050, 0.045),
    ("wrist", (0.284, 0.010, 0.960), 0.034, 0.026),
    ("palm", (0.290, 0.018, 0.900), 0.040, 0.020),
    ("fingertips", (0.294, 0.022, 0.820), 0.030, 0.013),
]
LEG = [
    ("hip", (0.095, 0.0, 0.92), 0.100, 0.102),
    ("thigh_mid", (0.102, 0.010, 0.74), 0.086, 0.088),
    ("knee", (0.106, 0.012, 0.52), 0.054, 0.056),
    ("calf", (0.108, -0.016, 0.40), 0.062, 0.068),
    ("shin_low", (0.110, -0.006, 0.20), 0.043, 0.045),
    ("ankle", (0.110, -0.010, 0.09), 0.036, 0.038),
    ("ball", (0.110, 0.100, 0.030), 0.042, 0.024),
    ("toe", (0.110, 0.160, 0.024), 0.034, 0.017),
]
HEEL = [("heel", (0.110, -0.040, 0.035), 0.034, 0.030)]  # branches off the ankle


def joint(chain, name):
    return next(p for n, p, _, _ in chain if n == name)


# Bones: name, head, tail, parent. Arms and legs are mirrored to _l.
BONES = [
    ("hips", (0, 0, 0.86), (0, 0, 1.05), None),
    ("spine", (0, 0, 1.05), (0, 0, 1.30), "hips"),
    ("chest", (0, 0, 1.30), (0, 0, 1.53), "spine"),
    ("neck", (0, 0, 1.53), (0, 0, 1.63), "chest"),
    ("head", (0, 0, 1.63), (0, 0, 1.87), "neck"),
]
LIMB_BONES = [
    ("upperarm", joint(ARM, "shoulder"), joint(ARM, "elbow"), "chest"),
    ("forearm", joint(ARM, "elbow"), joint(ARM, "wrist"), "upperarm"),
    ("hand", joint(ARM, "wrist"), joint(ARM, "fingertips"), "forearm"),
    ("thigh", joint(LEG, "hip"), joint(LEG, "knee"), "hips"),
    ("shin", joint(LEG, "knee"), joint(LEG, "ankle"), "thigh"),
    ("foot", joint(LEG, "ankle"), joint(LEG, "toe"), "shin"),
]
TORSO_BONES = ("hips", "spine", "chest", "neck", "head")
TORSO_HALF_WIDTH = 0.172  # vertices nearer the middle than this, above the hips, are torso


def mirror(p, side):
    return (p[0] * side, p[1], p[2])


def all_bones():
    bones = list(BONES)
    for side, suffix in ((1, "_r"), (-1, "_l")):
        for name, head, tail, parent in LIMB_BONES:
            par = parent if parent in ("chest", "hips") else parent + suffix
            bones.append((name + suffix, mirror(head, side), mirror(tail, side), par))
    return bones


def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def skin_body():
    """The stick figure with a Skin modifier, smoothed and decimated."""
    verts, radii, edges = [], [], []

    def add(p, rx, ry):
        verts.append(p)
        radii.append((rx, ry))
        return len(verts) - 1

    def chain(start, joints, side):
        """Adds a run of joints from `start`; returns name -> vertex index."""
        made, prev = {}, start
        for name, p, rx, ry in joints:
            i = add(mirror(p, side), rx, ry)
            edges.append((prev, i))
            made[name] = prev = i
        return made

    centre = [add(p, rx, ry) for _, p, rx, ry in CENTRE]
    edges += [(centre[i], centre[i + 1]) for i in range(len(centre) - 1)]
    upper_chest = centre[[n for n, _, _, _ in CENTRE].index("upper_chest")]
    for side in (1, -1):
        arm = chain(upper_chest, ARM, side)
        leg = chain(centre[0], LEG, side)
        chain(leg["ankle"], HEEL, side)

    mesh = bpy.data.meshes.new("skeleton_lines")
    mesh.from_pydata(verts, edges, [])
    obj = bpy.data.objects.new("skin_src", mesh)
    bpy.context.collection.objects.link(obj)
    skin = obj.modifiers.new("skin", "SKIN")
    skin.branch_smoothing = 0.6
    for i, r in enumerate(radii):
        sv = mesh.skin_vertices[0].data[i]
        sv.radius = r
        sv.use_root = i == centre[0]
    sub = obj.modifiers.new("smooth", "SUBSURF")
    sub.levels = 2
    sub.render_levels = 2
    return obj


def head_mesh(bm):
    """A skull with a narrower jaw and chin, a rounder back, and no face."""
    made = bmesh.ops.create_icosphere(bm, subdivisions=3, radius=1.0)
    for v in made["verts"]:
        x, y, z = v.co
        x, y, z = x * 0.088, y * 0.106, z * 0.118
        if z < 0.0:  # jaw: narrows and comes forward toward the chin
            t = -z / 0.118
            x *= 1.0 - 0.42 * t
            y = y * (1.0 - 0.25 * t) + 0.016 * t
        elif y < 0.0:  # back of the skull bulges out a little
            y *= 1.0 + 0.10 * (z / 0.118)
        v.co = Vector((x, y + 0.012, z + 1.725))


def belt_mesh(bm):
    m = Matrix.Translation((0.0, 0.0, 1.02)) @ Matrix.Diagonal((1.0, 0.76, 1.0, 1.0))
    bmesh.ops.create_cone(bm, cap_ends=True, segments=10, radius1=0.150, radius2=0.142, depth=0.055, matrix=m)


def bake(obj):
    """Applies an object's modifiers into a new plain mesh."""
    deps = bpy.context.evaluated_depsgraph_get()
    return bpy.data.meshes.new_from_object(obj.evaluated_get(deps))


def build_body_mesh():
    src = skin_body()
    body = bake(src)
    bpy.data.objects.remove(src)
    bm = bmesh.new()
    bm.from_mesh(body)
    head_mesh(bm)
    bm.to_mesh(body)
    bm.free()

    obj = bpy.data.objects.new("body", body)
    bpy.context.collection.objects.link(obj)
    # Trim the polygon count for the game; smooth shading hides the cuts.
    tris = sum(len(p.vertices) - 2 for p in body.polygons)
    dec = obj.modifiers.new("facets", "DECIMATE")
    dec.ratio = min(1.0, TARGET_TRIS / max(tris, 1))
    faceted = bake(obj)
    obj.modifiers.clear()
    obj.data = faceted
    bpy.data.meshes.remove(body)
    for poly in obj.data.polygons:
        poly.use_smooth = True
    return obj


def build_armature():
    data = bpy.data.armatures.new("rig")
    rig = bpy.data.objects.new("rig", data)
    bpy.context.collection.objects.link(rig)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.mode_set(mode="EDIT")
    made = {}
    for name, head, tail, parent in all_bones():
        eb = data.edit_bones.new(name)
        eb.head, eb.tail = head, tail
        eb.roll = 0.0
        if parent:
            eb.parent = made[parent]
        made[name] = eb
    bpy.ops.object.mode_set(mode="OBJECT")
    return rig


def weight(obj, rig, only=None):
    """Each vertex follows its two nearest bones, blended by distance."""
    bones = [(n, Vector(h), Vector(t)) for n, h, t, _ in all_bones()]
    groups = {n: obj.vertex_groups.new(name=n) for n, _, _ in bones}
    for v in obj.data.vertices:
        if only:
            groups[only].add([v.index], 1.0, "REPLACE")
            continue
        # The torso only follows torso bones, so a moving arm or leg can't drag the chest.
        torso = abs(v.co.x) < TORSO_HALF_WIDTH and 0.98 < v.co.z < 1.36  # shoulders blend
        dists = []
        for n, h, t in bones:
            if torso and n not in TORSO_BONES:
                continue
            closest, f = intersect_point_line(v.co, h, t)
            if f < 0.0:
                closest = h
            elif f > 1.0:
                closest = t
            dists.append(((v.co - closest).length, n))
        dists.sort()
        (d0, n0), (d1, n1) = dists[0], dists[1]
        w0 = 1.0 / (d0 ** 4 + 1e-6)
        w1 = 1.0 / (d1 ** 4 + 1e-6)
        groups[n0].add([v.index], w0 / (w0 + w1), "REPLACE")
        groups[n1].add([v.index], w1 / (w0 + w1), "REPLACE")
    mod = obj.modifiers.new("rig", "ARMATURE")
    mod.object = rig
    obj.parent = rig


def preview(out_dir, rig):
    """Front, side and a walking pose, rendered flat for a quick look."""
    os.makedirs(out_dir, exist_ok=True)
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.light = "STUDIO"
    scene.display.shading.color_type = "SINGLE"
    scene.display.shading.single_color = (1.0, 0.18, 0.53)
    scene.display.shading.show_cavity = True
    scene.render.resolution_x = 520
    scene.render.resolution_y = 760
    world = bpy.data.worlds.new("w")
    scene.world = world
    cam_data = bpy.data.cameras.new("cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = 2.2
    cam = bpy.data.objects.new("cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam

    def shot(name, angle):
        r = 6.0
        cam.location = (math.sin(angle) * r, math.cos(angle) * r, 1.0)
        cam.rotation_euler = (math.pi / 2, 0.0, math.pi - angle)
        scene.render.filepath = os.path.join(out_dir, name + ".png")
        bpy.ops.render.render(write_still=True)

    shot("front", 0.0)
    shot("side", math.pi / 2)
    shot("three_quarter", math.pi / 4)
    pb = rig.pose.bones
    pb["thigh_r"].rotation_mode = pb["thigh_l"].rotation_mode = "XYZ"
    pb["shin_l"].rotation_mode = pb["upperarm_r"].rotation_mode = "XYZ"
    pb["thigh_r"].rotation_euler = (0.55, 0, 0)
    pb["thigh_l"].rotation_euler = (-0.55, 0, 0)
    pb["shin_l"].rotation_euler = (-0.6, 0, 0)
    pb["upperarm_r"].rotation_euler = (-1.5, 0, 0)
    shot("posed", math.pi / 3)


def main():
    clear_scene()
    body = build_body_mesh()
    belt_data = bpy.data.meshes.new("belt")
    bm = bmesh.new()
    belt_mesh(bm)
    bm.to_mesh(belt_data)
    bm.free()
    belt = bpy.data.objects.new("belt", belt_data)
    bpy.context.collection.objects.link(belt)
    for poly in belt_data.polygons:
        poly.use_smooth = False

    rig = build_armature()
    weight(body, rig)
    weight(belt, rig, only="hips")

    tris = sum(len(p.vertices) - 2 for p in body.data.polygons)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=OUT, export_format="GLB", export_yup=True,
        export_apply=False, export_materials="NONE", export_skins=True,
        export_animations=False)
    print("[blender] wrote %s (body: %d triangles)" % (OUT, tris))

    args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if "--preview" in args:
        preview(args[args.index("--preview") + 1], rig)


main()
