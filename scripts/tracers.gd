extends MultiMeshInstance3D
## Pooled enemy bullets, drawn in one MultiMesh. Every peer flies the same
## straight shots, but each peer only checks hits against its own player, so
## what you see is what kills you.

signal hit_local

const Palette := preload("res://scripts/palette.gd")

const MAX := 24
const SPEED := 85.0
const RANGE := 60.0
const LENGTH := 1.6
const MASK := 1 | 4            ## world + players
const STEP := 1.0 / 60.0

var local_body: CollisionObject3D = null
var ignore: Array[RID] = []    ## the remote player: their own machine decides their hits

var _pos := PackedVector3Array()
var _dir := PackedVector3Array()
var _left := PackedFloat32Array()
var _active := 0
var _query := PhysicsRayQueryParameters3D.new()
var _hidden := Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO)


func _ready() -> void:
	_pos.resize(MAX)
	_dir.resize(MAX)
	_left.resize(MAX)
	_query.collision_mask = MASK
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.05, 0.05, 1.0)
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = MAX
	material_override = Palette.glow(Palette.DANGER, 5.0)
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	custom_aabb = AABB(Vector3(-500, -50, -500), Vector3(1000, 200, 1000))
	clear()


func clear() -> void:
	_left.fill(0.0)
	_active = 0
	for i in MAX:
		multimesh.set_instance_transform(i, _hidden)
	set_physics_process(false)


func spawn(origin: Vector3, dir: Vector3, fast_forward: float) -> void:
	for i in MAX:
		if _left[i] <= 0.0:
			_pos[i] = origin
			_dir[i] = dir.normalized()
			_left[i] = RANGE
			_active += 1
			set_physics_process(true)
			var t := fast_forward
			while t >= STEP and _left[i] > 0.0:
				_advance(i, STEP)
				t -= STEP
			return


func _physics_process(delta: float) -> void:
	for i in MAX:
		if _left[i] > 0.0:
			_advance(i, delta)
	if _active <= 0:
		set_physics_process(false)


func _advance(i: int, delta: float) -> void:
	var from := _pos[i]
	var step := minf(SPEED * delta, _left[i])
	var to := from + _dir[i] * step
	_query.from = from
	_query.to = to
	_query.exclude = ignore
	var hit := get_world_3d().direct_space_state.intersect_ray(_query)
	if not hit.is_empty():
		if hit["collider"] == local_body:
			hit_local.emit()
		_kill(i)
		return
	_pos[i] = to
	_left[i] -= step
	if _left[i] <= 0.0:
		_kill(i)
		return
	var d := _dir[i]
	var up := Vector3.UP if absf(d.y) < 0.98 else Vector3.RIGHT
	var b := Basis.looking_at(d, up) * Basis.from_scale(Vector3(1, 1, LENGTH))
	multimesh.set_instance_transform(i, Transform3D(b, to - d * LENGTH * 0.5))


func _kill(i: int) -> void:
	_left[i] = 0.0
	_active -= 1
	multimesh.set_instance_transform(i, _hidden)
