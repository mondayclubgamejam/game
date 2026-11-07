extends CharacterBody3D
## First-person player with classic keyboard controls and the one-bullet gun.
## Space fires the bullet (it lodges in the first wall), Space again recalls it.
## Both the shot and the return trip kill every enemy on their line.

signal state_changed(state: int)
signal fired
signal recalled
signal recall_blocked
signal shot_finished(kills: int, was_recall: bool)

enum { LOADED, FLYING_OUT, LODGED, FLYING_BACK }

const WALK_SPEED := 5.0
const RUN_SPEED := 8.5
const TURN_SPEED := 2.4
const GRAVITY := 20.0
const EYE_HEIGHT := 1.6
const RANGE := 120.0
const BULLET_SPEED := 70.0

const MASK_WALL := 1
const MASK_ENEMY := 2

const FIRE_COLOR := Color(1.0, 0.48, 0.1, 0.85)
const RECALL_COLOR := Color(0.18, 0.66, 1.0, 0.85)
const BLOCKED_COLOR := Color(1.0, 0.15, 0.2, 0.6)

var state := LOADED
var lodge_pos := Vector3.ZERO
var move_amount := 0.0  ## 0..1+, read by the hand overlay for bobbing

var camera: Camera3D
var _bullet: Node3D
var _bullet_mat: StandardMaterial3D
var _bullet_light: OmniLight3D
var _trail: MeshInstance3D
var _laser: MeshInstance3D
var _laser_mat: StandardMaterial3D
var _targeted: Array = []
var _shake := 0.0


func _ready() -> void:
	collision_layer = 4
	collision_mask = MASK_WALL | MASK_ENEMY

	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = 1.8
	shape.shape = capsule
	shape.position = Vector3(0, 0.9, 0)
	add_child(shape)

	camera = Camera3D.new()
	camera.position = Vector3(0, EYE_HEIGHT, 0)
	camera.fov = 80.0
	camera.near = 0.05
	add_child(camera)
	camera.current = true

	_build_bullet()
	_build_laser()


func _physics_process(delta: float) -> void:
	var turn := Input.get_axis("turn_right", "turn_left")
	rotate_y(turn * TURN_SPEED * delta)

	var forward_in := Input.get_axis("move_back", "move_forward")
	var strafe_in := Input.get_axis("strafe_left", "strafe_right")
	var speed := RUN_SPEED if Input.is_action_pressed("run") else WALK_SPEED
	var dir := -global_basis.z * forward_in + global_basis.x * strafe_in
	dir.y = 0.0
	if dir.length() > 1.0:
		dir = dir.normalized()
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= GRAVITY * delta
	move_and_slide()
	move_amount = Vector2(velocity.x, velocity.z).length() / WALK_SPEED

	if Input.is_action_just_pressed("fire"):
		if state == LOADED:
			_fire()
		elif state == LODGED:
			_recall()

	_update_preview()

	_shake = move_toward(_shake, 0.0, delta * 5.0)
	camera.h_offset = randf_range(-1.0, 1.0) * _shake * 0.06
	camera.v_offset = randf_range(-1.0, 1.0) * _shake * 0.06


# --- Gun ---------------------------------------------------------------------

func _fire() -> void:
	var from := camera.global_position
	var result := _trace(from, from + _aim_dir() * RANGE)
	state = FLYING_OUT
	state_changed.emit(state)
	fired.emit()
	_shake = 1.0
	_launch(_muzzle(), result["end"], result["hits"], false)


func _recall() -> void:
	var result := _trace(lodge_pos, camera.global_position)
	if result["blocked"]:
		recall_blocked.emit()
		_shake = 0.4
		return
	state = FLYING_BACK
	state_changed.emit(state)
	_launch(lodge_pos, _muzzle(), result["hits"], true)


func _launch(start: Vector3, end: Vector3, hits: Array, is_recall: bool) -> void:
	var color := RECALL_COLOR if is_recall else FIRE_COLOR
	_bullet_mat.emission = color
	_bullet_mat.albedo_color = Color(color, 1.0)
	_bullet_light.light_color = color
	_bullet.visible = true
	_trail.visible = true
	_bullet.global_position = start
	_orient(_bullet, end - start)

	var dir := (end - start).normalized()
	var duration := maxf(start.distance_to(end) / BULLET_SPEED, 0.05)
	var tw := create_tween()
	tw.tween_property(_bullet, "global_position", end, duration)
	for hit in hits:
		var enemy: Object = hit["enemy"]
		get_tree().create_timer(hit["dist"] / BULLET_SPEED).timeout.connect(
			Callable(enemy, "die").bind(dir))
	tw.tween_callback(_on_bullet_arrived.bind(end, hits.size(), is_recall))


func _on_bullet_arrived(end: Vector3, kills: int, is_recall: bool) -> void:
	_trail.visible = false
	if is_recall:
		_bullet.visible = false
		state = LOADED
		recalled.emit()
		_shake = 0.7
	else:
		lodge_pos = end
		state = LODGED
	state_changed.emit(state)
	shot_finished.emit(kills, is_recall)


## Walks a straight line, passing through enemies and stopping at the first wall
## or at a shield facing the bullet.
## Returns { hits: [{enemy, dist}], end: Vector3, blocked: bool }.
func _trace(from: Vector3, to: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var dir := (to - from).normalized()
	var exclude: Array[RID] = [get_rid()]
	var hits := []
	for i in 32:
		var query := PhysicsRayQueryParameters3D.create(
			from, to, MASK_WALL | MASK_ENEMY, exclude)
		var r := space.intersect_ray(query)
		if r.is_empty():
			return {"hits": hits, "end": to, "blocked": false}
		var collider: Object = r["collider"]
		var pos: Vector3 = r["position"]
		var normal: Vector3 = r["normal"]
		if collider.has_method("is_shield_blocking") and not collider.dead:
			if collider.is_shield_blocking(dir):
				return {"hits": hits, "end": pos + normal * 0.06, "blocked": true}
			hits.append({"enemy": collider, "dist": from.distance_to(pos)})
			exclude.append(r["rid"])
			continue
		return {"hits": hits, "end": pos + normal * 0.06, "blocked": true}
	return {"hits": hits, "end": to, "blocked": false}


func _update_preview() -> void:
	var targets := []
	match state:
		LOADED:
			var from := camera.global_position
			var r := _trace(from, from + _aim_dir() * RANGE)
			_set_line(_laser_start(), r["end"], FIRE_COLOR)
			targets = r["hits"].map(func(h): return h["enemy"])
		LODGED:
			var r := _trace(lodge_pos, camera.global_position)
			if r["blocked"]:
				_set_line(lodge_pos, _laser_start(), BLOCKED_COLOR)
			else:
				_set_line(lodge_pos, _laser_start(), RECALL_COLOR)
				targets = r["hits"].map(func(h): return h["enemy"])
		_:
			_laser.visible = false
	for e in _targeted:
		if is_instance_valid(e):
			e.set_targeted(false)
	for e in targets:
		e.set_targeted(true)
	_targeted = targets


func _aim_dir() -> Vector3:
	var v := -global_basis.z
	v.y = 0.0
	return v.normalized()


func _muzzle() -> Vector3:
	return camera.global_transform * Vector3(0.16, -0.17, -0.45)


# --- Visuals -----------------------------------------------------------------

func _build_bullet() -> void:
	_bullet = Node3D.new()
	_bullet.top_level = true
	_bullet.visible = false
	add_child(_bullet)

	_bullet_mat = StandardMaterial3D.new()
	_bullet_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# Transparent so the outline post-process skips it and it draws on top.
	_bullet_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_bullet_mat.albedo_color = Color(FIRE_COLOR, 1.0)
	_bullet_mat.emission_enabled = true
	_bullet_mat.emission = FIRE_COLOR
	_bullet_mat.emission_energy_multiplier = 6.0

	var slug := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.05
	cyl.bottom_radius = 0.05
	cyl.height = 0.35
	slug.mesh = cyl
	slug.material_override = _bullet_mat
	slug.rotation.x = PI / 2.0
	slug.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_bullet.add_child(slug)

	_trail = MeshInstance3D.new()
	var trail_mesh := BoxMesh.new()
	trail_mesh.size = Vector3(0.05, 0.05, 2.0)
	_trail.mesh = trail_mesh
	_trail.material_override = _bullet_mat
	_trail.position = Vector3(0, 0, 1.0)
	_trail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_bullet.add_child(_trail)

	_bullet_light = OmniLight3D.new()
	_bullet_light.light_color = FIRE_COLOR
	_bullet_light.light_energy = 2.0
	_bullet_light.omni_range = 3.0
	_bullet.add_child(_bullet_light)


func _build_laser() -> void:
	_laser = MeshInstance3D.new()
	_laser.top_level = true
	_laser.visible = false
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE
	_laser.mesh = mesh
	_laser_mat = StandardMaterial3D.new()
	_laser_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_laser_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_laser_mat.albedo_color = FIRE_COLOR
	_laser.material_override = _laser_mat
	_laser.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_laser)


func _set_line(a: Vector3, b: Vector3, color: Color) -> void:
	var d := b - a
	var length := d.length()
	if length < 0.05:
		_laser.visible = false
		return
	var forward := d / length
	if absf(forward.y) > 0.99:
		_laser.visible = false
		return
	_laser.visible = true
	_laser_mat.albedo_color = color
	var line_basis := Basis.looking_at(forward, Vector3.UP) * Basis.from_scale(
		Vector3(0.012, 0.012, length))
	_laser.global_transform = Transform3D(line_basis, (a + b) / 2.0)


func _orient(node: Node3D, d: Vector3) -> void:
	if d.length() < 0.001:
		return
	var forward := d.normalized()
	if absf(forward.y) > 0.99:
		return
	node.global_basis = Basis.looking_at(forward, Vector3.UP)


## Aim lines start a little ahead of the gun so they read as a thin beam
## instead of a wedge filling the bottom of the screen.
func _laser_start() -> Vector3:
	return _muzzle() + _aim_dir() * 1.2
