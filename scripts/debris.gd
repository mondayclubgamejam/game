extends MultiMeshInstance3D
## Pooled death bursts: tumbling cubes in one MultiMesh, simple CPU physics
## (gravity + floor bounce), no rigid bodies.

const Palette := preload("res://scripts/palette.gd")
const Clock := preload("res://scripts/clock.gd")

const MAX := 128
const PER_BURST := 10
const LIFE := 2.4

var _pos := PackedVector3Array()
var _vel := PackedVector3Array()
var _axis := PackedVector3Array()
var _angle := PackedFloat32Array()
var _size := PackedFloat32Array()
var _life := PackedFloat32Array()
var _next := 0
var _active := 0
var _hidden := Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO)


func _ready() -> void:
	_pos.resize(MAX)
	_vel.resize(MAX)
	_axis.resize(MAX)
	_angle.resize(MAX)
	_size.resize(MAX)
	_life.resize(MAX)
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = MAX
	material_override = Palette.toon(Palette.ENEMY)
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	custom_aabb = AABB(Vector3(-500, -50, -500), Vector3(1000, 200, 1000))
	clear()


func clear() -> void:
	_life.fill(0.0)
	_active = 0
	for i in MAX:
		multimesh.set_instance_transform(i, _hidden)
	set_process(false)


func burst(center: Vector3, dir: Vector3) -> void:
	for n in PER_BURST:
		var i := _next
		_next = (_next + 1) % MAX
		if _life[i] <= 0.0:
			_active += 1
		_pos[i] = center + Vector3(randf_range(-0.3, 0.3), randf_range(0.3, 1.9), randf_range(-0.3, 0.3))
		_vel[i] = dir * randf_range(3.0, 9.0) + Vector3(randf_range(-2.5, 2.5), randf_range(2.0, 6.0), randf_range(-2.5, 2.5))
		_axis[i] = Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5).normalized()
		_angle[i] = 0.0
		_size[i] = randf_range(0.14, 0.3)
		_life[i] = LIFE + randf() * 0.6
	set_process(true)


func _process(real_delta: float) -> void:
	var delta := real_delta * Clock.scale
	for i in MAX:
		if _life[i] <= 0.0:
			continue
		_life[i] -= delta
		if _life[i] <= 0.0:
			_active -= 1
			multimesh.set_instance_transform(i, _hidden)
			continue
		var v := _vel[i]
		v.y -= 20.0 * delta
		var p := _pos[i] + v * delta
		var half := _size[i] * 0.5
		if p.y < half:
			p.y = half
			v = Vector3(v.x * 0.6, -v.y * 0.35, v.z * 0.6)
		_pos[i] = p
		_vel[i] = v
		_angle[i] += delta * v.length() * 2.0
		var s := _size[i] * clampf(_life[i] / 0.4, 0.0, 1.0)
		multimesh.set_instance_transform(i, Transform3D(Basis(_axis[i], _angle[i]).scaled(Vector3.ONE * s), p))
	if _active <= 0:
		set_process(false)
