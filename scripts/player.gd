extends CharacterBody3D
## One player. The local player reads input and owns its own movement, so
## moving never waits on the network. The remote player is extrapolated from
## the latest network update and smoothed.

const Palette := preload("res://scripts/palette.gd")

const SPEED := 6.5
const CARRY_SPEED := 3.2     ## the gun is heavy
const ACCEL := 55.0
const GRAVITY := 22.0
const EYE := 1.6
const MOUSE_SENS := 0.0022
const LAYER_PLAYER := 4
const MASK_WORLD := 1
const MAX_EXTRAPOLATE := 0.12

var peer_id := 0
var role := 0                ## 0 = forward (A), 1 = reverse (B)
var is_local := false
var alive := true
var carrying := false        ## set by the game when this player holds the gun
var input_enabled := true
var bot_move := Vector2.ZERO ## used by the test bot instead of the keyboard
var move_amount := 0.0       ## 0..1, read by the hand overlay for bob

var head: Node3D
var camera: Camera3D
var hand_anchor: Node3D      ## where a remote player's gun is drawn

var _net_pos := Vector3.ZERO
var _net_vel := Vector3.ZERO
var _net_yaw := 0.0
var _net_pitch := 0.0
var _net_age := 0.0
var _has_net := false
var _body_parts: Array[MeshInstance3D] = []


func setup(id: int, player_role: int, local: bool) -> void:
	peer_id = id
	role = player_role
	is_local = local
	name = "P%d" % id


func _ready() -> void:
	collision_layer = LAYER_PLAYER
	collision_mask = MASK_WORLD
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = 1.8
	var shape := CollisionShape3D.new()
	shape.shape = capsule
	shape.position.y = 0.9
	add_child(shape)

	head = Node3D.new()
	head.position.y = EYE
	add_child(head)
	hand_anchor = Node3D.new()
	hand_anchor.position = Vector3(0.32, -0.4, -0.45)
	head.add_child(hand_anchor)

	if is_local:
		camera = Camera3D.new()
		camera.fov = 82.0
		camera.near = 0.05
		camera.far = 200.0
		head.add_child(camera)
		camera.make_current()
	else:
		_build_body()
		# Remote bodies only move by network updates.
		set_physics_process(true)


func _build_body() -> void:
	var color := Palette.role_color(role)
	var body := CapsuleMesh.new()
	body.radius = 0.36
	body.height = 1.5
	_add_part(body, Vector3(0, 0.75, 0), Palette.toon(color), self)
	var head_mesh := SphereMesh.new()
	head_mesh.radius = 0.27
	head_mesh.height = 0.54
	head_mesh.radial_segments = 16
	head_mesh.rings = 8
	_add_part(head_mesh, Vector3(0, 0, 0), Palette.toon(color), head)
	var visor := BoxMesh.new()
	visor.size = Vector3(0.44, 0.1, 0.12)
	_add_part(visor, Vector3(0, 0.02, -0.21), Palette.toon(Palette.INK), head)


func _add_part(mesh: Mesh, pos: Vector3, mat: Material, parent: Node3D) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = mat
	parent.add_child(mi)
	_body_parts.append(mi)


func _unhandled_input(event: InputEvent) -> void:
	if not is_local or not alive:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var rel: Vector2 = event.screen_relative
		rotation.y -= rel.x * MOUSE_SENS
		head.rotation.x = clampf(head.rotation.x - rel.y * MOUSE_SENS, -1.5, 1.5)


func _physics_process(delta: float) -> void:
	if is_local:
		_local_move(delta)
	else:
		_remote_follow(delta)


func _local_move(delta: float) -> void:
	var input := Vector2.ZERO
	if alive and input_enabled:
		input = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		if bot_move != Vector2.ZERO:
			input = bot_move
	var speed := CARRY_SPEED if carrying else SPEED
	var wish := (global_basis * Vector3(input.x, 0.0, input.y)) * speed
	var flat := Vector3(velocity.x, 0.0, velocity.z).move_toward(wish, ACCEL * delta)
	velocity.x = flat.x
	velocity.z = flat.z
	velocity.y = 0.0 if is_on_floor() else velocity.y - GRAVITY * delta
	move_and_slide()
	move_amount = flat.length() / SPEED


func _remote_follow(delta: float) -> void:
	if not _has_net:
		return
	_net_age += delta
	var predicted := _net_pos + _net_vel * minf(_net_age, MAX_EXTRAPOLATE)
	var k := 1.0 - exp(-delta * 18.0)
	if global_position.distance_squared_to(predicted) > 9.0:
		global_position = predicted  # teleport (respawn) instead of sliding
	else:
		global_position = global_position.lerp(predicted, k)
	rotation.y = lerp_angle(rotation.y, _net_yaw, k)
	head.rotation.x = lerpf(head.rotation.x, _net_pitch, k)


## Called when a network update for this (remote) player arrives.
func apply_net_state(pos: Vector3, yaw: float, pitch: float) -> void:
	if _has_net and _net_age > 0.0:
		var v := (pos - _net_pos) / maxf(_net_age, 1.0 / 120.0)
		_net_vel = _net_vel.lerp(v, 0.5)
	else:
		global_position = pos
		_net_vel = Vector3.ZERO
	_net_pos = pos
	_net_yaw = yaw
	_net_pitch = pitch
	_net_age = 0.0
	_has_net = true


func place(pos: Vector3, yaw: float) -> void:
	global_position = pos
	rotation.y = yaw
	head.rotation.x = 0.0
	velocity = Vector3.ZERO
	_net_pos = pos
	_net_vel = Vector3.ZERO
	_net_yaw = yaw
	_net_pitch = 0.0
	_has_net = false


func pitch() -> float:
	return head.rotation.x


func eye_pos() -> Vector3:
	return head.global_position


func aim_dir() -> Vector3:
	return -head.global_basis.z


func muzzle_pos() -> Vector3:
	return head.global_transform * Vector3(0.2, -0.2, -0.55)


func velocity_estimate() -> Vector3:
	return velocity if is_local else _net_vel


func chest_pos() -> Vector3:
	return global_position + Vector3(0, 1.2, 0)


func kill() -> void:
	if not alive:
		return
	alive = false
	var tw := create_tween()
	if is_local:
		tw.tween_property(head, "position:y", 0.35, 0.45).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
		tw.parallel().tween_property(head, "rotation:z", 0.6, 0.45)
	else:
		tw.tween_property(self, "rotation:x", -PI / 2.0, 0.4).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
