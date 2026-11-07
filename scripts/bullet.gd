extends Node3D
## The one bullet. Every peer simulates it, but only the peer that launched it
## (the authority) decides where it stops and which enemies it killed. Other
## peers show the same flight and wait for that peer's result.
##
## Forward (A): straight line, through enemies, stops at the first wall.
## Recall (B): leaves the way it came in, curves into B's gun, through enemies,
##             and sticks in any wall in the way.

signal enemy_hit(enemy: Node3D, dir: Vector3)
signal player_hit(player: Node3D)
signal stopped(pos: Vector3, dir: Vector3, normal: Vector3)
signal arrived

const Palette := preload("res://scripts/palette.gd")
const Traj := preload("res://scripts/trajectory.gd")
const PulseShader := preload("res://shaders/pulse.gdshader")
const Clock := preload("res://scripts/clock.gd")

enum { IN_GUN, FORWARD, LODGED, RECALL, WAITING }

const SPEED := 55.0
const RECALL_SPEED := 42.0
const RANGE := 80.0
const MASK_WORLD := 1
const MASK_ENEMY := 2
const MASK_PLAYER := 4
const STEP := 1.0 / 60.0

var state := IN_GUN
var authority := false
var shooter: Node3D = null       ## the player who fired or is recalling
var lodge_pos := Vector3.ZERO
var lodge_dir := Vector3.FORWARD ## direction of travel when it stuck
var lodge_normal := Vector3.ZERO

var _pos := Vector3.ZERO
var _dir := Vector3.FORWARD
var _travelled := 0.0
var _p0 := Vector3.ZERO
var _p1 := Vector3.ZERO
var _t := 0.0
var _exclude: Array[RID] = []
var _query := PhysicsRayQueryParameters3D.new()

var _slug: MeshInstance3D
var _trail: MeshInstance3D
var _light: OmniLight3D
var _pulse: MeshInstance3D


func _ready() -> void:
	top_level = true
	_query.collision_mask = MASK_WORLD | MASK_ENEMY | MASK_PLAYER

	var slug_mesh := CapsuleMesh.new()
	slug_mesh.radius = 0.06
	slug_mesh.height = 0.36
	slug_mesh.radial_segments = 8
	slug_mesh.rings = 2
	_slug = MeshInstance3D.new()
	_slug.mesh = slug_mesh
	_slug.rotation.x = PI / 2.0
	_slug.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_slug)

	var trail_mesh := BoxMesh.new()
	trail_mesh.size = Vector3(0.05, 0.05, 2.4)
	_trail = MeshInstance3D.new()
	_trail.mesh = trail_mesh
	_trail.position.z = 1.3
	_trail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_trail)

	_light = OmniLight3D.new()
	_light.omni_range = 3.5
	_light.light_energy = 2.0
	add_child(_light)

	var quad := QuadMesh.new()
	quad.size = Vector2(1.2, 1.2)
	var pulse_mat := ShaderMaterial.new()
	pulse_mat.shader = PulseShader
	pulse_mat.set_shader_parameter("color", Palette.REVERSE)
	pulse_mat.set_shader_parameter("speed", -1.1)  # rings pull inward: "come back"
	_pulse = MeshInstance3D.new()
	_pulse.mesh = quad
	_pulse.material_override = pulse_mat
	_pulse.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_pulse)
	reset()


func reset() -> void:
	state = IN_GUN
	visible = false
	set_physics_process(false)


func fire(from: Vector3, dir: Vector3, by: Node3D, is_authority: bool, fast_forward: float) -> void:
	state = FORWARD
	authority = is_authority
	shooter = by
	_pos = from
	_dir = dir.normalized()
	_travelled = 0.0
	_exclude.clear()
	_exclude.append(by.get_rid())
	_show(Palette.FORWARD, false)
	_place(_pos, _dir)
	set_physics_process(true)
	_fast_forward(fast_forward * Clock.scale)


func recall(by: Node3D, is_authority: bool, fast_forward: float) -> void:
	state = RECALL
	authority = is_authority
	shooter = by
	_p0 = lodge_pos
	_p1 = Traj.recall_control(lodge_pos, lodge_dir, by.muzzle_pos())
	_t = 0.0
	_pos = lodge_pos
	_exclude.clear()
	_exclude.append(by.get_rid())
	_show(Palette.REVERSE, false)
	set_physics_process(true)
	_fast_forward(fast_forward * Clock.scale)


## Authoritative result: the bullet is stuck here.
func set_lodged(pos: Vector3, dir: Vector3, normal: Vector3) -> void:
	state = LODGED
	lodge_pos = pos
	lodge_dir = dir.normalized()
	lodge_normal = normal
	_pos = pos
	_place(pos, lodge_dir)
	_show(Palette.REVERSE, true)
	set_physics_process(false)


func _fast_forward(seconds: float) -> void:
	var t := seconds
	while t >= STEP and (state == FORWARD or state == RECALL):
		_step(STEP)
		t -= STEP


func _physics_process(delta: float) -> void:
	_step(delta * Clock.scale)


func _step(delta: float) -> void:
	match state:
		FORWARD:
			var dist := minf(SPEED * delta, RANGE - _travelled)
			var to := _pos + _dir * dist
			if _sweep(_pos, to, _dir):
				return
			_travelled += dist
			_pos = to
			_place(_pos, _dir)
			if _travelled >= RANGE:
				_stop(_pos, _dir, Vector3.ZERO)
		RECALL:
			var target: Vector3 = shooter.muzzle_pos()
			var length := maxf(Traj.bezier_length(_p0, _p1, target), 0.01)
			_t = minf(_t + RECALL_SPEED * delta / length, 1.0)
			var to := Traj.bezier(_p0, _p1, target, _t)
			var d := to - _pos
			var dir := d.normalized() if d.length_squared() > 1e-8 else _dir
			if _sweep(_pos, to, dir):
				return
			_pos = to
			_dir = dir
			_place(_pos, -_dir)  # trail streams ahead: it's moving backwards in time
			if _t >= 1.0:
				_finish_recall()


## Moves the bullet along one segment. Returns true if a wall stopped it.
func _sweep(from: Vector3, to: Vector3, dir: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	_query.from = from
	_query.to = to
	for i in 8:
		_query.exclude = _exclude
		var hit := space.intersect_ray(_query)
		if hit.is_empty():
			return false
		var body: CollisionObject3D = hit["collider"]
		if body.collision_layer & MASK_WORLD:
			_stop(hit["position"] + hit["normal"] * 0.04, dir, hit["normal"])
			return true
		_exclude.append(hit["rid"])
		if body.collision_layer & MASK_ENEMY:
			enemy_hit.emit(body, dir)
		elif body.collision_layer & MASK_PLAYER:
			player_hit.emit(body)
	return false


func _stop(pos: Vector3, dir: Vector3, normal: Vector3) -> void:
	_place(pos, dir)
	set_physics_process(false)
	if authority:
		set_lodged(pos, dir, normal)
		stopped.emit(pos, dir, normal)
	else:
		state = WAITING  # hold here until the authority says where it stopped


func _finish_recall() -> void:
	set_physics_process(false)
	visible = false
	if authority:
		state = IN_GUN
		arrived.emit()
	else:
		state = WAITING


func _show(color: Color, lodged: bool) -> void:
	visible = true
	var mat := Palette.glow(color, 6.0)
	_slug.material_override = mat
	_trail.material_override = mat
	_trail.visible = not lodged
	_light.visible = not lodged
	_light.light_color = color
	_pulse.visible = lodged


func _place(pos: Vector3, forward: Vector3) -> void:
	global_position = pos
	if forward.length_squared() < 1e-6:
		return
	var up := Vector3.UP if absf(forward.normalized().y) < 0.98 else Vector3.RIGHT
	global_basis = Basis.looking_at(forward, up)
