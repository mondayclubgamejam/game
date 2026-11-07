extends RefCounted
## Cyberpunk set dressing for an ASCII level: ceiling and light panels,
## one teal floor trim, wall details (vents, pipes, panels), pillars and crates.
## Kept deliberately plain: one accent colour, no text. Neon is transparent, so
## it glows and skips the ink-outline pass.

const CONCRETE := Color("34323f")
const CONCRETE_LIGHT := Color("44414f")
const CEILING := Color("17161d")
const METAL := Color("5d6170")
const TEAL := Color("19ffc8")
const CRATE_COLOR := Color("3b3a44")

const DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]


# --- Materials ---------------------------------------------------------------

## Wet, slightly metallic floor: picks up neon in screen-space reflections.
static func wet(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.16
	m.metallic = 0.45
	return m


static func neon(color: Color, energy := 3.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(color, 0.99)
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	return m


static func solid_mat(color: Color, roughness := 0.85, metallic := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	return m


# --- Props -------------------------------------------------------------------

## A 1.2 m concrete column with glowing corner edges. Blocks bullets.
static func pillar(root: Node3D, p: Vector3, h: float) -> void:
	_box(root, p + Vector3(0, h / 2.0, 0), Vector3(1.2, h, 1.2), solid_mat(CONCRETE_LIGHT), true)
	var strip := neon(TEAL)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_box(root, p + Vector3(0.61 * sx, h / 2.0, 0.61 * sz),
				Vector3(0.05, h - 0.8, 0.05), strip)
	_box(root, p + Vector3(0, 0.12, 0), Vector3(1.32, 0.24, 1.32), solid_mat(METAL, 0.4, 0.7))


## Two stacked cargo crates with a hazard band. Blocks bullets.
static func crates(root: Node3D, p: Vector3, variant: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = variant
	var col := CRATE_COLOR
	_box(root, p + Vector3(0, 0.65, 0), Vector3(1.7, 1.3, 1.7), solid_mat(col, 0.7), true)
	var top := _box(root, p + Vector3(rng.randf_range(-0.15, 0.15), 1.8, rng.randf_range(-0.15, 0.15)),
		Vector3(1.3, 1.0, 1.3), solid_mat(col.lightened(0.08), 0.7), true)
	top.rotation.y = rng.randf_range(-0.4, 0.4)


# --- Room dressing -----------------------------------------------------------

static func dress(root: Node3D, map: Array, tile: float, h: float) -> void:
	var rows := map.size()
	var cols := 0
	for line in map:
		cols = maxi(cols, String(line).length())

	# Ceiling over the whole map: the room is enclosed.
	_box(root, Vector3((cols - 1) * tile / 2.0, h + 0.1, (rows - 1) * tile / 2.0),
		Vector3(cols * tile, 0.2, rows * tile), solid_mat(CEILING), true)

	var trim_low := neon(TEAL, 1.8)
	var dark := solid_mat(CEILING, 0.6, 0.3)
	var panel := solid_mat(CONCRETE_LIGHT)
	var pipe := solid_mat(METAL, 0.35, 0.8)
	var light_on := neon(Color("eaf4ff"), 4.0)

	for r in rows:
		var line: String = map[r]
		for c in line.length():
			var ch := line[c]
			var center := Vector3(c * tile, 0, r * tile)
			if ch != "#":
				# Ceiling light panels on a loose grid.
				if c % 3 == 1 and r % 2 == 1:
					_box(root, center + Vector3(0, h - 0.03, 0), Vector3(1.4, 0.05, 0.35), light_on)
					var light := OmniLight3D.new()
					light.light_color = Color("dde8f5")
					light.light_energy = 1.6
					light.omni_range = 7.0
					light.shadow_enabled = true
					root.add_child(light)
					light.position = center + Vector3(0, h - 0.5, 0)
				continue

			for d in DIRS:
				var nr: int = r + d.y
				var nc: int = c + d.x
				if nr < 0 or nr >= rows or nc < 0 or nc >= String(map[nr]).length():
					continue
				var nch := String(map[nr])[nc]
				if nch == "#" or nch == "D":
					continue
				var dir := Vector3(d.x, 0, d.y)
				var face := center + dir * (tile / 2.0)
				_face_box(root, face, dir, tile, 0.05, 0.18, 0.05, trim_low)
				match (r * 7 + c * 13) % 4:
					0:  # vent
						_face_box(root, face, dir, 1.2, 0.8, 2.3, 0.06, dark)
						for i in 4:
							_face_box(root, face, dir, 1.1, 0.06, 2.0 + i * 0.2, 0.1, pipe)
					1:  # raised wall panel
						_face_box(root, face, dir, 1.6, 2.4, 1.45, 0.05, panel)
					2:  # pipes
						for y in [3.05, 3.3]:
							_face_cylinder(root, face, dir, tile, 0.09, y, 0.18, pipe)


# --- Helpers -----------------------------------------------------------------

static func _face_box(root: Node3D, face: Vector3, dir: Vector3, width: float, height: float,
		y: float, depth: float, mat: Material) -> Node3D:
	var size := Vector3(depth, height, width) if absf(dir.x) > 0.5 else Vector3(width, height, depth)
	return _box(root, face + dir * (depth / 2.0) + Vector3(0, y, 0), size, mat)


static func _face_cylinder(root: Node3D, face: Vector3, dir: Vector3, length: float, radius: float,
		y: float, out: float, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = length
	mi.mesh = cyl
	mi.material_override = mat
	root.add_child(mi)
	mi.position = face + dir * out + Vector3(0, y, 0)
	# Cylinders stand along Y; lay them along the wall.
	if absf(dir.x) > 0.5:
		mi.rotation.x = PI / 2.0
	else:
		mi.rotation.z = PI / 2.0


static func _box(root: Node3D, center: Vector3, size: Vector3, mat: Material,
		solid := false) -> Node3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	if not solid:
		root.add_child(mi)
		mi.position = center
		return mi
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.add_child(mi)
	root.add_child(body)
	body.position = center
	return body
