extends CharacterBody3D
## An enemy: a faceted low-poly humanoid (see enemy_figure.gd) that walks at the
## player and dies in one hit, but only from the right time direction:
##   forward  (orange)  only the shot kills it
##   inverted (blue)    only the recall kills it; walks toward you backwards
## The wrong kind of hit passes straight through and it flashes white.
## A shielded enemy blocks bullets that hit its front and stays put.

signal died
signal reached_player

const FORWARD_COLOR := Color("ff5a1f")
const INVERTED_COLOR := Color("2f8cff")
const SHIELD_COLOR := Color("c9d1e0")
const HIGHLIGHT_COLOR := Color("ffe14d")
const BASE_GLOW := 0.32

const WALK_SPEED := 1.4
const START_DELAY := 1.5   ## seconds before enemies start walking
const CATCH_RANGE := 0.9   ## metres: this close and the player is caught

const Figure := preload("res://scripts/enemy_figure.gd")

## Set true to freeze every enemy (screenshot director).
static var paused := false

var shielded := false
var inverted := false
var dead := false

var _mat: StandardMaterial3D
var _color := FORWARD_COLOR
var _body: Node3D
var _player: Node3D
var _wait := START_DELAY
var _walk_t := 0.0
var _flash := 0.0


func _ready() -> void:
	collision_layer = 2
	collision_mask = 1  # slide along walls, pillars and crates
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	add_to_group("enemies")
	_color = INVERTED_COLOR if inverted else FORWARD_COLOR
	_walk_t = randf() * TAU

	# Faceted figure with a faint glow so it reads in the dark.
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = _color
	_mat.roughness = 0.45
	_mat.metallic = 0.15
	_mat.emission_enabled = true
	_mat.emission = _color
	_mat.emission_energy_multiplier = BASE_GLOW
	var visor := StandardMaterial3D.new()
	visor.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	visor.albedo_color = Color("f2fbff")
	var gun := StandardMaterial3D.new()
	gun.albedo_color = Color("15151b")
	gun.roughness = 0.4
	gun.metallic = 0.6
	_body = Node3D.new()
	add_child(_body)
	Figure.build(_body, _mat, visor, gun, randi() % Figure.POSES.size())

	var body_shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.32
	capsule.height = 1.85
	body_shape.shape = capsule
	body_shape.position = Vector3(0, 0.95, 0)
	add_child(body_shape)

	if shielded:
		var shield := BoxMesh.new()
		shield.size = Vector3(0.9, 1.4, 0.08)
		_add_mesh(shield, Vector3(0, 1.0, -0.6), _toon(SHIELD_COLOR))


func _physics_process(delta: float) -> void:
	if _flash > 0.0:
		_flash = maxf(_flash - delta * 4.0, 0.0)
		if _flash == 0.0:
			set_targeted(false)
	if dead or paused or shielded:
		return
	if _wait > 0.0:
		_wait -= delta
		return
	_player = _nearest_player()
	if _player == null:
		return

	var to := _player.global_position - global_position
	to.y = 0.0
	if to.length() < CATCH_RANGE:
		reached_player.emit()
		return
	var dir := to.normalized()
	velocity = dir * WALK_SPEED
	move_and_slide()
	global_position.y = 0.0
	# Forward enemies face where they walk; inverted ones walk backwards.
	face(global_position + (-dir if inverted else dir))

	# Walk bob and sway on the posed figure.
	_walk_t += delta * 7.0
	_body.position.y = absf(sin(_walk_t)) * 0.05
	_body.rotation.z = sin(_walk_t) * 0.05


func _nearest_player() -> Node3D:
	var best: Node3D = null
	for p in get_tree().get_nodes_in_group("player"):
		var n := p as Node3D
		if best == null or n.global_position.distance_to(global_position) \
				< best.global_position.distance_to(global_position):
			best = n
	return best


## Turn so the enemy's face (local -Z) points at a world position.
func face(target: Vector3) -> void:
	var flat := Vector3(target.x, global_position.y, target.z)
	if flat.distance_to(global_position) > 0.01:
		look_at(flat, Vector3.UP)


## Forward enemies die to the shot, inverted ones to the recall.
func can_be_killed_by(is_recall: bool) -> bool:
	return is_recall == inverted


## True if a bullet travelling in `dir` would hit the shield.
func is_shield_blocking(dir: Vector3) -> bool:
	if not shielded:
		return false
	var facing := -global_basis.z
	return dir.dot(facing) < -0.15


func set_targeted(on: bool) -> void:
	if _mat and _flash == 0.0:
		_mat.emission = HIGHLIGHT_COLOR if on else _color
		_mat.emission_energy_multiplier = 0.9 if on else BASE_GLOW


## Wrong time direction: the bullet passes through and the body flashes white.
func flash_immune() -> void:
	if dead or _mat == null:
		return
	_flash = 1.0
	_mat.emission = Color.WHITE
	_mat.emission_energy_multiplier = 2.5


func die(dir: Vector3) -> void:
	if dead:
		return
	dead = true
	collision_layer = 0
	_spawn_debris(dir)
	died.emit()
	queue_free()


func _spawn_debris(dir: Vector3) -> void:
	var parent := get_parent()
	if parent == null:
		return
	var mat := _toon(_color)
	for i in 12:
		var rb := RigidBody3D.new()
		rb.collision_layer = 8
		rb.collision_mask = 1
		var size := randf_range(0.15, 0.32)
		var shape := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = Vector3.ONE * size
		shape.shape = box_shape
		rb.add_child(shape)
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3.ONE * size
		mi.mesh = box
		mi.material_override = mat
		rb.add_child(mi)
		parent.add_child(rb)
		rb.global_position = global_position + Vector3(
			randf_range(-0.3, 0.3), randf_range(0.3, 2.1), randf_range(-0.3, 0.3))
		rb.linear_velocity = dir * randf_range(4.0, 10.0) + Vector3(
			randf_range(-2.5, 2.5), randf_range(2.0, 5.5), randf_range(-2.5, 2.5))
		rb.angular_velocity = Vector3(
			randf_range(-12, 12), randf_range(-12, 12), randf_range(-12, 12))
		var tw := rb.create_tween()
		tw.tween_interval(randf_range(2.0, 3.0))
		tw.tween_property(mi, "scale", Vector3.ONE * 0.01, 0.4)
		tw.tween_callback(rb.queue_free)


func _add_mesh(mesh: Mesh, pos: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = mat
	add_child(mi)


static func _toon(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	m.roughness = 1.0
	return m
