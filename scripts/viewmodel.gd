extends Node3D
## First-person 3D hand and pistol, lit by the room. Child of the player camera.
## The gun is built from extruded side profiles (smooth, not boxes); the hand
## from jointed capsule fingers wrapped around the grip.
## Same API as the old 2D overlay: play_fire / play_recall / play_blocked.

const FIRE_COLOR := Color(1.0, 0.48, 0.1)
const RECALL_COLOR := Color(0.18, 0.66, 1.0)

const BASE_POS := Vector3(0.12, -0.115, -0.27)
const BASE_ROT := Vector3(0.0, 1.623, 0.0)  # ~93 deg: gun local +X -> forward, toed in

var player: Node  ## reads `move_amount` for walk bob
var muzzle: Node3D

var kick := 0.0          ## +1 fire recoil, -1 recall yank
var flash := 0.0
var recall_flash := 0.0
var slide_back := 0.0
var shake := 0.0

var _rig: Node3D
var _slide: Node3D
var _flash_node: Node3D
var _flash_light: OmniLight3D
var _ring: MeshInstance3D
var _ring_mat: StandardMaterial3D
var _bob_t := 0.0
var _bob := 0.0


func _ready() -> void:
	_rig = Node3D.new()
	add_child(_rig)
	_build_gun()
	_build_hand()
	_build_effects()

	# Soft fill so the hand reads in dark corners.
	var fill := OmniLight3D.new()
	fill.light_color = Color("bcd4ff")
	fill.light_energy = 0.5
	fill.omni_range = 1.0
	fill.position = Vector3(0.25, 0.15, 0.05)
	add_child(fill)


func _process(delta: float) -> void:
	var move := 0.0
	if player and "move_amount" in player:
		move = clampf(player.move_amount, 0.0, 1.8)
	_bob = lerpf(_bob, move, delta * 8.0)
	_bob_t += delta * (6.0 + 4.0 * move)
	var bob := Vector3(sin(_bob_t) * 0.006, -absf(cos(_bob_t)) * 0.005, 0.0) * _bob

	_rig.position = BASE_POS + bob + Vector3(shake * 0.008, kick * 0.012, kick * 0.045)
	_rig.rotation = BASE_ROT
	# Pitch the muzzle up on recoil (around the gun's local Z, which is camera X).
	_rig.rotate_object_local(Vector3(0, 0, 1), kick * 0.3)
	_slide.position.x = -0.03 * slide_back

	_flash_node.visible = flash > 0.01
	_flash_node.scale = Vector3.ONE * (0.4 + flash)
	_flash_light.light_energy = flash * 3.0
	_ring.visible = recall_flash > 0.01
	_ring.scale = Vector3.ONE * (0.4 + recall_flash * 2.5)
	_ring_mat.albedo_color.a = recall_flash


func play_fire() -> void:
	flash = 1.0
	_flash_light.light_color = FIRE_COLOR
	var tw := create_tween().set_parallel(true)
	tw.tween_property(self, "flash", 0.0, 0.08)
	tw.tween_property(self, "slide_back", 1.0, 0.04)
	var k := create_tween()
	k.tween_property(self, "kick", 1.0, 0.035).set_trans(Tween.TRANS_QUAD)
	k.tween_property(self, "kick", 0.0, 0.28).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## The fire animation played backwards: the gun is yanked forward as the bullet
## slams back into the barrel, and the slide snaps closed.
func play_recall() -> void:
	recall_flash = 1.0
	var tw := create_tween().set_parallel(true)
	tw.tween_property(self, "recall_flash", 0.0, 0.25)
	tw.tween_property(self, "slide_back", 0.0, 0.05)
	var k := create_tween()
	k.tween_property(self, "kick", -0.8, 0.05).set_trans(Tween.TRANS_QUAD)
	k.tween_property(self, "kick", 0.0, 0.32).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func play_blocked() -> void:
	var tw := create_tween()
	for i in 4:
		tw.tween_property(self, "shake", 1.0 if i % 2 == 0 else -1.0, 0.04)
	tw.tween_property(self, "shake", 0.0, 0.04)


# --- Gun ---------------------------------------------------------------------
# Gun local space: +X toward the muzzle, +Y up, Z across (extrusion width).

func _build_gun() -> void:
	var steel := _mat(Color("2b2e36"), 0.3, 0.85)
	var polymer := _mat(Color("1c1d22"), 0.65, 0.0)
	var dark := _mat(Color("0c0c10"), 0.5, 0.2)

	_slide = Node3D.new()
	_rig.add_child(_slide)
	_profile(_slide, [
		Vector2(-0.010, 0.000), Vector2(0.180, 0.000), Vector2(0.181, 0.022),
		Vector2(0.178, 0.029), Vector2(0.172, 0.033), Vector2(0.004, 0.033),
		Vector2(-0.004, 0.031), Vector2(-0.009, 0.026),
	], 0.026, steel)
	# Rear grip grooves on both sides.
	for i in 6:
		for side in [-1.0, 1.0]:
			_box(_slide, Vector3(0.006 + i * 0.006, 0.017, side * 0.0132),
				Vector3(0.0022, 0.024, 0.001), dark)
	# Sights with glowing dots.
	_box(_slide, Vector3(0.168, 0.0365, 0), Vector3(0.008, 0.007, 0.005), dark)
	_box(_slide, Vector3(0.004, 0.0365, 0), Vector3(0.008, 0.007, 0.018), dark)
	_box(_slide, Vector3(0.168, 0.037, 0), Vector3(0.0025, 0.0025, 0.0055), _glow(FIRE_COLOR))
	# Neon accent line on the visible (right) side.
	_box(_slide, Vector3(0.10, 0.011, 0.0132), Vector3(0.11, 0.0025, 0.001), _glow(FIRE_COLOR))
	# Barrel crown and muzzle.
	_cylinder_x(_slide, Vector3(0.183, 0.017, 0), 0.0068, 0.008, steel)
	_cylinder_x(_slide, Vector3(0.1875, 0.017, 0), 0.0042, 0.002, dark)

	# Frame with an angled grip.
	_profile(_rig, [
		Vector2(0.170, 0.000), Vector2(0.170, -0.012), Vector2(0.120, -0.016),
		Vector2(0.088, -0.020), Vector2(0.042, -0.020), Vector2(0.036, -0.030),
		Vector2(0.031, -0.060), Vector2(0.026, -0.090), Vector2(0.021, -0.114),
		Vector2(0.015, -0.122), Vector2(-0.030, -0.128), Vector2(-0.037, -0.121),
		Vector2(-0.031, -0.090), Vector2(-0.023, -0.050), Vector2(-0.019, -0.020),
		Vector2(-0.023, -0.009), Vector2(-0.032, -0.004), Vector2(-0.025, 0.000),
	], 0.024, polymer)
	# Trigger guard (U band) and trigger.
	_profile(_rig, [
		Vector2(0.090, -0.020), Vector2(0.093, -0.033), Vector2(0.087, -0.042),
		Vector2(0.046, -0.042), Vector2(0.040, -0.036), Vector2(0.046, -0.036),
		Vector2(0.050, -0.037), Vector2(0.083, -0.037), Vector2(0.087, -0.032),
		Vector2(0.085, -0.020),
	], 0.017, polymer)
	_profile(_rig, [
		Vector2(0.063, -0.020), Vector2(0.065, -0.029), Vector2(0.061, -0.035),
		Vector2(0.058, -0.033), Vector2(0.059, -0.020),
	], 0.006, steel)
	# Magazine base plate.
	_box(_rig, Vector3(-0.008, -0.130, 0), Vector3(0.050, 0.006, 0.026), steel)

	muzzle = Node3D.new()
	muzzle.position = Vector3(0.19, 0.017, 0)
	_slide.add_child(muzzle)


# --- Hand --------------------------------------------------------------------
# Right hand: palm on the right (+Z) side, fingers wrap the front of the grip,
# thumb along the left side.

func _build_hand() -> void:
	var skin := _mat(Color("c58b6a"), 0.55, 0.0)
	skin.subsurf_scatter_enabled = true
	skin.subsurf_scatter_strength = 0.3
	var glove := _mat(Color("22232a"), 0.75, 0.0)
	var sleeve := _mat(Color("16171d"), 0.85, 0.0)

	var hand := Node3D.new()
	_rig.add_child(hand)

	# Palm and back of the hand over the grip's right side and back strap.
	_capsule(hand, Vector3(-0.008, -0.030, 0.024), Vector3(0.012, -0.104, 0.024), 0.026, glove,
		Vector3(1.0, 1.0, 0.7))
	_capsule(hand, Vector3(-0.034, -0.012, 0.006), Vector3(-0.030, -0.090, 0.018), 0.022, glove)

	# Fingers: proximal (glove), middle, tip (skin). Index sits on the trigger.
	var rows := [
		{"y": -0.048, "r": 0.0105},
		{"y": -0.070, "r": 0.0102},
		{"y": -0.092, "r": 0.0095},
	]
	for f in rows:
		var y: float = f["y"]
		var r: float = f["r"]
		var k := Vector3(0.026, y, 0.022)
		var j1 := Vector3(0.042 - (y + 0.05) * 0.2, y - 0.003, 0.004)
		var j2 := Vector3(0.036 - (y + 0.05) * 0.2, y - 0.005, -0.018)
		var tip := Vector3(0.028, y - 0.006, -0.021)  # tips end at the grip front-left
		_capsule(hand, k, j1, r, glove)
		_capsule(hand, j1, j2, r * 0.93, skin)
		_capsule(hand, j2, tip, r * 0.86, skin)
	# Index finger along the frame onto the trigger.
	var ik := Vector3(0.030, -0.026, 0.020)
	var ij1 := Vector3(0.056, -0.026, 0.013)
	var ij2 := Vector3(0.064, -0.031, 0.004)
	_capsule(hand, ik, ij1, 0.0105, glove)
	_capsule(hand, ij1, ij2, 0.0095, skin)
	_capsule(hand, ij2, Vector3(0.061, -0.036, -0.004), 0.0088, skin)
	# Thumb along the left side of the frame.
	var t0 := Vector3(-0.024, -0.018, 0.004)
	var t1 := Vector3(0.010, -0.020, -0.020)
	var t2 := Vector3(0.042, -0.016, -0.022)
	_capsule(hand, t0, t1, 0.0125, glove)
	_capsule(hand, t1, t2, 0.0112, skin)

	# Wrist, forearm and sleeve running back toward the camera.
	var wrist := Vector3(-0.045, -0.095, 0.022)
	var elbow := Vector3(-0.16, -0.32, 0.07)  # down and back, out of frame
	_capsule(hand, Vector3(-0.022, -0.075, 0.022), wrist, 0.028, glove)
	_capsule(hand, wrist, elbow, 0.031, skin)
	var cuff := wrist.lerp(elbow, 0.22)
	_capsule(hand, cuff, elbow + (elbow - wrist) * 0.3, 0.043, sleeve)
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.041
	torus.outer_radius = 0.047
	ring.mesh = torus
	ring.material_override = _glow(Color("19ffc8"))
	hand.add_child(ring)
	ring.position = cuff
	ring.quaternion = Quaternion(Vector3.UP, (elbow - wrist).normalized())


# --- Effects -----------------------------------------------------------------

func _build_effects() -> void:
	_flash_node = Node3D.new()
	muzzle.add_child(_flash_node)
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 0.9, 1))
	grad.set_color(1, Color(1, 0.6, 0.1, 0))
	grad.add_point(0.35, Color(1, 0.8, 0.3, 0.9))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	var fm := StandardMaterial3D.new()
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	fm.cull_mode = BaseMaterial3D.CULL_DISABLED
	fm.albedo_texture = tex
	for i in 3:
		var q := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(0.09, 0.09)
		q.mesh = qm
		q.material_override = fm
		_flash_node.add_child(q)
		q.position = Vector3(0.03, 0, 0)
		q.rotation = Vector3(i * PI / 3.0, 0, 0)  # planes along the barrel
	var face := MeshInstance3D.new()
	var fq := QuadMesh.new()
	fq.size = Vector2(0.06, 0.06)
	face.mesh = fq
	face.material_override = fm
	face.rotation.y = PI / 2.0
	_flash_node.add_child(face)
	_flash_light = OmniLight3D.new()
	_flash_light.omni_range = 4.0
	_flash_light.light_energy = 0.0
	muzzle.add_child(_flash_light)

	_ring = MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.016
	torus.outer_radius = 0.02
	_ring.mesh = torus
	_ring_mat = _glow(RECALL_COLOR)
	_ring.material_override = _ring_mat
	_ring.rotation.z = PI / 2.0  # ring faces along the barrel
	_ring.visible = false
	muzzle.add_child(_ring)


# --- Helpers -----------------------------------------------------------------

func _profile(parent: Node3D, points: Array, width: float, mat: Material) -> void:
	var poly := CSGPolygon3D.new()
	poly.polygon = PackedVector2Array(points)
	poly.depth = width
	poly.smooth_faces = true
	poly.material = mat
	parent.add_child(poly)
	poly.position.z = width / 2.0  # extrusion runs toward -Z; centre it


func _capsule(parent: Node3D, a: Vector3, b: Vector3, radius: float, mat: Material,
		squash := Vector3.ONE) -> void:
	var mi := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = radius
	cap.height = a.distance_to(b) + radius * 2.0
	cap.radial_segments = 16
	cap.rings = 6
	mi.mesh = cap
	mi.material_override = mat
	parent.add_child(mi)
	mi.position = (a + b) / 2.0
	var d := b - a
	if d.length() > 0.0001:
		mi.quaternion = Quaternion(Vector3.UP, d.normalized())
	mi.scale = squash


func _box(parent: Node3D, pos: Vector3, size: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)


func _cylinder_x(parent: Node3D, pos: Vector3, radius: float, length: float, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = length
	mi.mesh = cyl
	mi.material_override = mat
	mi.position = pos
	mi.rotation.z = PI / 2.0
	parent.add_child(mi)


static func _mat(color: Color, roughness: float, metallic: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	return m


static func _glow(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(color, 0.99)
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = 3.0
	return m
