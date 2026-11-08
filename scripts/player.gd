extends CharacterBody3D
## One player. The local player reads input and owns its own movement, so
## moving never waits on the network. The remote player is extrapolated from
## the latest network update and smoothed.
##
## Movement: walk, crouch (Ctrl/C: shorter and slower, so low crates hide
## you) and jump (Space).

const Palette := preload("res://scripts/palette.gd")
const Clock := preload("res://scripts/clock.gd")
const Mannequin := preload("res://scripts/mannequin.gd")

const SPEED := 6.5
const CARRY_SPEED := 3.2     ## the gun is heavy
const CROUCH_SPEED := 3.0
const ACCEL := 55.0
const AIR_ACCEL := 18.0
const GRAVITY := 22.0
const JUMP_VELOCITY := 7.2   ## about 1.2 m: enough to get onto a crate
const EYE := 1.6
const CROUCH_EYE := 1.0
const HEIGHT := 1.8
const CROUCH_HEIGHT := 1.15
const CROUCH_RATE := 9.0     ## how fast crouching eases in and out
const MOUSE_SENS := 0.0022
const LAYER_PLAYER := 4
const MASK_WORLD := 1
const MAX_EXTRAPOLATE := 0.12

## Bits of the flags sent with every network update.
const FLAG_CROUCH := 1
const FLAG_MOVING := 2

var peer_id := 0
var role := 0                ## 0 = forward (A), 1 = reverse (B)
var is_local := false
var alive := true
var carrying := false        ## set by the game when this player holds the gun
var input_enabled := true
var bot_move := Vector2.ZERO ## used by the test bot instead of the keyboard
var bot_crouch := false
var move_amount := 0.0       ## 0..1+, read by the hand overlay for bob
var player_name := "PLAYER"
var crouching := false

var head: Node3D
var camera: Camera3D
var hand_anchor: Node3D      ## where a remote player's gun is drawn

var _game_vel := Vector3.ZERO  ## velocity in game time (real velocity = this x the game clock)
var _wants_move := false       ## pressing a move key or in the air: counts as moving
var _shape: CollisionShape3D
var _capsule: CapsuleShape3D
var _crouch_t := 0.0         ## 0 standing .. 1 crouched, eased
var _body: Node3D            ## remote: the visible body, squashed when crouching
var _man: Mannequin = null   ## remote: the human figure (null on the fallback body)
var _last_pos := Vector3.ZERO
var _net_pos := Vector3.ZERO
var _net_vel := Vector3.ZERO
var _net_yaw := 0.0
var _net_pitch := 0.0
var _net_age := 0.0
var _net_moving := false
var _has_net := false


func setup(id: int, player_role: int, local: bool) -> void:
	peer_id = id
	role = player_role
	is_local = local
	name = "P%d" % id


func _ready() -> void:
	collision_layer = LAYER_PLAYER
	collision_mask = MASK_WORLD
	_capsule = CapsuleShape3D.new()
	_capsule.radius = 0.35
	_capsule.height = HEIGHT
	_shape = CollisionShape3D.new()
	_shape.shape = _capsule
	_shape.position.y = HEIGHT * 0.5
	add_child(_shape)

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


func _build_body() -> void:
	var color := Palette.role_color(role)
	_body = Node3D.new()
	add_child(_body)
	if DisplayServer.get_name() == "headless":
		return  # a server draws nothing
	var man := Mannequin.new()
	if man.setup(Palette.toon(color), Palette.toon(color.darkened(0.45))):
		_man = man
		_body.add_child(man)
		# The held gun sits in the figure's right hand, arm out along the aim.
		hand_anchor.position = Vector3(Mannequin.SHOULDER.x, Mannequin.SHOULDER.y - EYE, -Mannequin.REACH)
		return
	var body := CapsuleMesh.new()
	body.radius = 0.36
	body.height = 1.5
	_add_part(body, Vector3(0, 0.75, 0), Palette.toon(color), _body)
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
	_apply_crouch(delta)
	if _man != null:
		_pose_body(delta)


## Remote figure: legs walk at the speed it's moving; the right arm aims along
## the view while carrying the gun, otherwise both arms swing.
func _pose_body(delta: float) -> void:
	var moved := global_position - _last_pos
	_last_pos = global_position
	var speed := Vector2(moved.x, moved.z).length() / maxf(delta, 0.001)
	_man.walk(minf(speed, 8.0), delta)
	if carrying:
		_man.bend("upperarm_r", PI * 0.5 + head.rotation.x)
	else:
		_man.bend("upperarm_r", _man.swing * 0.7)
	_man.bend("upperarm_l", -_man.swing * 0.7)


func _local_move(delta: float) -> void:
	var input := Vector2.ZERO
	var wants_crouch := false
	var wants_jump := false
	if alive and input_enabled:
		input = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		if bot_move != Vector2.ZERO:
			input = bot_move
		wants_crouch = Input.is_action_pressed("crouch") or bot_crouch
		wants_jump = Input.is_action_just_pressed("jump")
	crouching = wants_crouch
	var speed := SPEED
	if carrying:
		speed = minf(speed, CARRY_SPEED)
	if crouching:
		speed = minf(speed, CROUCH_SPEED)

	# Movement runs on the game clock like everything else, so slow motion
	# slows players too. Whether you're "moving" comes from your keys, not
	# your speed: pressing a key is what speeds time back up.
	var on_floor := is_on_floor()
	_wants_move = input != Vector2.ZERO or wants_jump or not on_floor
	var t := Clock.scale
	var game_delta := delta * t
	var wish := (global_basis * Vector3(input.x, 0.0, input.y)) * speed
	var accel := ACCEL if on_floor else AIR_ACCEL
	var flat := Vector3(_game_vel.x, 0.0, _game_vel.z).move_toward(wish, accel * game_delta)
	_game_vel.x = flat.x
	_game_vel.z = flat.z
	if on_floor:
		_game_vel.y = JUMP_VELOCITY if wants_jump and not crouching else 0.0
	else:
		_game_vel.y -= GRAVITY * game_delta
	velocity = _game_vel * t
	move_and_slide()
	if t > 0.01:
		_game_vel = velocity / t  # keep what walls and floors did to us
	move_amount = Vector2(velocity.x, velocity.z).length() / SPEED


func _apply_crouch(delta: float) -> void:
	var target := 1.0 if crouching else 0.0
	if is_equal_approx(_crouch_t, target):
		return
	_crouch_t = move_toward(_crouch_t, target, delta * CROUCH_RATE)
	var h := lerpf(HEIGHT, CROUCH_HEIGHT, _crouch_t)
	_capsule.height = h
	_shape.position.y = h * 0.5
	head.position.y = lerpf(EYE, CROUCH_EYE, _crouch_t)
	if _body != null:
		_body.scale.y = h / HEIGHT


## True if this player counts as moving for the slow-motion rule.
func is_moving() -> bool:
	if not alive:
		return false
	if not is_local:
		return _net_moving
	return _wants_move


func net_flags() -> int:
	return (FLAG_CROUCH if crouching else 0) | (FLAG_MOVING if is_moving() else 0)


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
func apply_net_state(pos: Vector3, yaw: float, pitch_in: float, flags: int) -> void:
	if _has_net and _net_age > 0.0:
		var v := (pos - _net_pos) / maxf(_net_age, 1.0 / 120.0)
		_net_vel = _net_vel.lerp(v, 0.5)
	else:
		global_position = pos
		_net_vel = Vector3.ZERO
	_net_pos = pos
	_net_yaw = yaw
	_net_pitch = pitch_in
	_net_age = 0.0
	_has_net = true
	crouching = flags & FLAG_CROUCH != 0
	_net_moving = flags & FLAG_MOVING != 0


func place(pos: Vector3, yaw: float) -> void:
	global_position = pos
	_last_pos = pos
	rotation.y = yaw
	head.rotation.x = 0.0
	velocity = Vector3.ZERO
	_game_vel = Vector3.ZERO
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


## Where enemies aim: lower while crouched.
func chest_pos() -> Vector3:
	return global_position + Vector3(0, lerpf(1.2, 0.75, _crouch_t), 0)


func kill() -> void:
	if not alive:
		return
	alive = false
	collision_layer = 0  # the fallen no longer stop bullets or get hit
	var tw := create_tween()
	if is_local:
		tw.tween_property(head, "position:y", 0.35, 0.45).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
		tw.parallel().tween_property(head, "rotation:z", 0.6, 0.45)
	else:
		tw.tween_property(self, "rotation:x", -PI / 2.0, 0.4).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
