extends Control
## First-person revolver. The gun is a 3D model (scripts/revolver.gd) in a
## gloved hand attached to the camera, pointing where you aim. This overlay
## animates it (raise, bob, recoil) and draws the 2D muzzle flash and recall
## rings at the muzzle's spot on screen. Fire kicks the gun up and back;
## recall plays that backwards: the gun is yanked forward as the bullet lands.

const Palette := preload("res://scripts/palette.gd")
const Revolver := preload("res://scripts/revolver.gd")

## Where the gun rests relative to the camera, and a slight turn inward so
## the barrel lines up with the crosshair.
const REST := Vector3(0.2, -0.19, -0.5)
const REST_YAW := 0.045
const SCALE := 0.8

var player: Node = null      ## the local player (its camera holds the gun)
var role := 0
var holding := false
var loaded := true

var raise := 0.0      ## 0 = lowered out of view, 1 = up
var kick := 0.0       ## +1 fire recoil, -1 recall yank
var flash := 0.0      ## muzzle starburst
var implode := 0.0    ## blue rings collapsing into the barrel
var _bob_t := 0.0
var _bob := 0.0

var _camera: Camera3D
var _rig: Node3D
var _drum: MeshInstance3D
var _muzzle: Node3D
var _shown_loaded := true


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	raise = move_toward(raise, 1.0 if holding else 0.0, delta * 5.0)
	var move := 0.0
	if player != null and is_instance_valid(player):
		move = clampf(player.move_amount, 0.0, 1.5)
	_bob = lerpf(_bob, move, delta * 8.0)
	_bob_t += delta * (5.0 + 5.0 * move)
	_ensure_rig()
	if _rig != null:
		_pose_rig()
	queue_redraw()


## Builds the hand and revolver on the local player's camera (again after
## every new round, since each round makes a new player).
func _ensure_rig() -> void:
	if player == null or not is_instance_valid(player):
		return
	var cam: Camera3D = player.camera
	if cam == null or cam == _camera and is_instance_valid(_rig):
		return
	_camera = cam
	_rig = Node3D.new()
	_rig.scale = Vector3.ONE * SCALE
	cam.add_child(_rig)
	var parts: Array = Revolver.build()
	var gun: Node3D = parts[0]
	_drum = parts[1]
	_rig.add_child(gun)
	_muzzle = Node3D.new()
	_muzzle.position = Vector3(0, 0.035, -0.34)
	gun.add_child(_muzzle)
	# Gloved hand round the grip, in this player's time colour, and a sleeve.
	var glove := MeshInstance3D.new()
	var fist := BoxMesh.new()
	fist.size = Vector3(0.075, 0.1, 0.1)
	glove.mesh = fist
	glove.position = Vector3(0, -0.1, 0.08)
	glove.rotation.x = -0.35
	glove.material_override = Palette.toon(Palette.role_color(role))
	_rig.add_child(glove)
	var sleeve := MeshInstance3D.new()
	var arm := CylinderMesh.new()
	arm.top_radius = 0.045
	arm.bottom_radius = 0.055
	arm.height = 0.3
	sleeve.mesh = arm
	sleeve.position = Vector3(0.02, -0.16, 0.24)
	sleeve.rotation.x = PI / 2.0 - 0.45
	sleeve.material_override = Palette.toon(Palette.INK.lightened(0.15))
	_rig.add_child(sleeve)
	for mi in [glove, sleeve]:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shown_loaded = not loaded  # force the drum colour to update


func _pose_rig() -> void:
	var bob := Vector3(sin(_bob_t) * 0.012, -absf(cos(_bob_t)) * 0.01, 0) * _bob
	var lowered := (1.0 - raise) * 0.35
	# Fire (kick > 0): up and back. Recall (kick < 0): yanked forward.
	_rig.position = REST + bob + Vector3(0, -lowered + kick * 0.025, kick * 0.07)
	_rig.rotation = Vector3(kick * 0.35, REST_YAW, -kick * 0.05)
	_rig.visible = raise > 0.01
	if loaded != _shown_loaded:
		_shown_loaded = loaded
		_drum.material_override = Palette.glow(Palette.FORWARD, 2.5) if loaded else Palette.toon(Palette.MUTED)


func play_fire() -> void:
	flash = 1.0
	var t := create_tween()
	t.tween_property(self, "kick", 1.0, 0.04)
	t.tween_property(self, "kick", 0.0, 0.32).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	create_tween().tween_property(self, "flash", 0.0, 0.12)


func play_recall_catch() -> void:
	implode = 1.0
	var t := create_tween()
	t.tween_property(self, "kick", -1.0, 0.05)
	t.tween_property(self, "kick", 0.0, 0.36).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	create_tween().tween_property(self, "implode", 0.0, 0.3)


func play_throw() -> void:
	var t := create_tween()
	t.tween_property(self, "kick", -0.8, 0.08)
	t.tween_property(self, "kick", 0.0, 0.2)


func play_catch() -> void:
	raise = 0.4
	kick = 0.5
	create_tween().tween_property(self, "kick", 0.0, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## Muzzle flash and recall rings, drawn where the muzzle is on screen.
func _draw() -> void:
	if (flash <= 0.0 and implode <= 0.0) or _muzzle == null or not is_instance_valid(_muzzle) \
			or _camera == null or not is_instance_valid(_camera):
		return
	var p := _camera.unproject_position(_muzzle.global_position)
	var s := size.y / 720.0
	if implode > 0.0:
		for i in 3:
			var col := Palette.REVERSE
			col.a = implode
			draw_arc(p, (12.0 + (implode + i * 0.35) * 70.0) * s, 0, TAU, 32, col, 6.0 * s)
	if flash > 0.0:
		_star(p, (20.0 + 60.0 * flash) * s, (9.0 + 18.0 * flash) * s, Palette.SIGNAL)
		_star(p, (10.0 + 28.0 * flash) * s, (5.0 + 9.0 * flash) * s, Color("fffbe6"))


func _star(c: Vector2, outer: float, inner: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 18:
		var a := TAU * i / 18.0 + flash * 0.6
		pts.append(c + Vector2(cos(a), sin(a)) * (outer if i % 2 == 0 else inner))
	draw_colored_polygon(pts, col)
	var closed := pts.duplicate()
	closed.append(pts[0])
	draw_polyline(closed, Palette.INK, 3.0, true)
