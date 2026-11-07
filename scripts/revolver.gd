extends RefCounted
## The one gun, as a revolver built from simple shapes (toon-shaded and
## ink-outlined like everything else). Used for the first-person view, the
## partner's hand and the thrown gun. Points down -Z; about 0.4 m long.

const Palette := preload("res://scripts/palette.gd")
const Models := preload("res://scripts/models.gd")
const GRIP := Color("7a4a2c")

static var _meshes := {}


## Returns the revolver and its cylinder (whose material shows loaded/empty).
static func build() -> Array:
	# The Blender model (tools/blender/weapons.py) when it's been built.
	var model := Models.build("revolver", {
		"steel": Palette.toon(Palette.STEEL), "dark": Palette.toon(Palette.INK),
		"grip": Palette.toon(GRIP), "drum": Palette.toon(Palette.MUTED)}, false)
	if model != null:
		return [model, model.find_child("drum", true, false)]
	var root := Node3D.new()
	var steel := Palette.toon(Palette.STEEL)
	var dark := Palette.toon(Palette.INK)
	var wood := Palette.toon(Palette.CRATE_EDGE)
	_part(root, "frame", Vector3(0, 0.0, 0.0), Vector3.ZERO, steel)
	_part(root, "barrel", Vector3(0, 0.035, -0.2), Vector3(PI / 2.0, 0, 0), steel)
	_part(root, "rib", Vector3(0, 0.062, -0.19), Vector3.ZERO, dark)
	_part(root, "sight", Vector3(0, 0.075, -0.33), Vector3.ZERO, dark)
	var drum := _part(root, "drum", Vector3(0, 0.03, -0.035), Vector3(PI / 2.0, 0, 0), Palette.glow(Palette.FORWARD, 2.5))
	_part(root, "hammer", Vector3(0, 0.07, 0.07), Vector3(-0.5, 0, 0), dark)
	_part(root, "guard", Vector3(0, -0.055, -0.01), Vector3.ZERO, dark)
	_part(root, "grip", Vector3(0, -0.1, 0.085), Vector3(-0.35, 0, 0), wood)
	return [root, drum]


static func _part(parent: Node3D, key: String, pos: Vector3, rot: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = _mesh(key)
	mi.position = pos
	mi.rotation = rot
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


static func _mesh(key: String) -> Mesh:
	if _meshes.has(key):
		return _meshes[key]
	var m: Mesh
	match key:
		"frame":
			m = _box(Vector3(0.05, 0.09, 0.2))
		"rib":
			m = _box(Vector3(0.02, 0.012, 0.26))
		"sight":
			m = _box(Vector3(0.012, 0.02, 0.02))
		"hammer":
			m = _box(Vector3(0.02, 0.05, 0.03))
		"guard":
			m = _box(Vector3(0.012, 0.025, 0.08))
		"grip":
			m = _box(Vector3(0.046, 0.15, 0.06))
		"barrel":
			m = _cyl(0.018, 0.26, 12)
		"drum":
			m = _cyl(0.046, 0.085, 12)
	_meshes[key] = m
	return m


static func _box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


static func _cyl(radius: float, height: float, segments: int) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = radius
	c.bottom_radius = radius
	c.height = height
	c.radial_segments = segments
	c.rings = 1
	return c
