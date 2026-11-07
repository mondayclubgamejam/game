extends StaticBody3D
## A static target "person". Dies in one hit and bursts into pieces.
## A shielded enemy blocks bullets that hit its front.

signal died

const BODY_COLOR := Color("ff2e88")
const VISOR_COLOR := Color("1a1026")
const SHIELD_COLOR := Color("c9d1e0")
const HIGHLIGHT_COLOR := Color("ffe14d")

var shielded := false
var dead := false

var _mat: StandardMaterial3D


func _ready() -> void:
	collision_layer = 2
	collision_mask = 0
	add_to_group("enemies")

	_mat = _toon(BODY_COLOR)
	_mat.emission_enabled = true
	_mat.emission = HIGHLIGHT_COLOR
	_mat.emission_energy_multiplier = 0.0

	var body_mesh := CapsuleMesh.new()
	body_mesh.radius = 0.4
	body_mesh.height = 1.8
	_add_mesh(body_mesh, Vector3(0, 0.9, 0), _mat)

	var head_mesh := SphereMesh.new()
	head_mesh.radius = 0.28
	head_mesh.height = 0.56
	_add_mesh(head_mesh, Vector3(0, 2.0, 0), _mat)

	var visor := BoxMesh.new()
	visor.size = Vector3(0.46, 0.11, 0.12)
	_add_mesh(visor, Vector3(0, 2.03, -0.22), _toon(VISOR_COLOR))

	var body_shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	body_shape.shape = capsule
	body_shape.position = Vector3(0, 0.9, 0)
	add_child(body_shape)

	var head_shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.28
	head_shape.shape = sphere
	head_shape.position = Vector3(0, 2.0, 0)
	add_child(head_shape)

	if shielded:
		var shield := BoxMesh.new()
		shield.size = Vector3(1.15, 1.6, 0.12)
		_add_mesh(shield, Vector3(0, 1.0, -0.62), _toon(SHIELD_COLOR))


## Turn so the enemy's face (local -Z) points at a world position.
func face(target: Vector3) -> void:
	var flat := Vector3(target.x, global_position.y, target.z)
	if flat.distance_to(global_position) > 0.01:
		look_at(flat, Vector3.UP)


## True if a bullet travelling in `dir` would hit the shield.
func is_shield_blocking(dir: Vector3) -> bool:
	if not shielded:
		return false
	var facing := -global_basis.z
	return dir.dot(facing) < -0.15


func set_targeted(on: bool) -> void:
	if _mat:
		_mat.emission_energy_multiplier = 0.9 if on else 0.0


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
	var mat := _toon(BODY_COLOR)
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
