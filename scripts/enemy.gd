extends CharacterBody3D
## An enemy. The host runs its brain; clients only smooth toward the packed
## positions the host streams. Attacks are events: the host announces a
## wind-up, then a strike, and each player's own machine decides if the
## strike hit them.

const RoomGen := preload("res://scripts/room_gen.gd")
const Palette := preload("res://scripts/palette.gd")
const Clock := preload("res://scripts/clock.gd")

const LAYER_ENEMY := 2
const MASK_WORLD := 1
const SIGHT := 26.0
const THINK_EVERY := 0.15
const REPATH_EVERY := 0.45
const MELEE_RANGE := 1.6
const GUN_RANGE := 18.0
const SPAWN_GRACE := 2.2       ## no attacks right after a (re)start
const REACTION := 0.45         ## pause after first spotting someone

const SPEEDS := [2.4, 4.0, 3.45]         ## by kind: gunman, sword, knives (m/s)
const WINDUPS := [0.7, 0.3, 0.4]
const COOLDOWNS := [3.8, 0.8, 0.7]       ## gunmen reload slowly
const COOLDOWN_JITTER := [1.4, 0.4, 0.4]
const EnemyRig := preload("res://scripts/enemy_rig.gd")

static var _meshes := {}

var id := 0
var kind := 0
var pace := 1.0                ## Endless: deeper rooms move and attack faster
var dummy := false             ## tutorial practice dummy: stands still, never attacks
var game: Node                 ## the main game node (host uses it to announce attacks)
var astar: AStarGrid2D
var alive := true

# Host brain.
var _alerted := false
var _target: Node3D = null
var _sees_target := false
var _think := 0.0
var _repath := 0.0
var _path: Array[Vector3] = []
var _windup := 0.0
var _cooldown := 0.0
var _query := PhysicsRayQueryParameters3D.new()

# Client smoothing.
var _net_pos := Vector3.ZERO
var _net_yaw := 0.0
var _net_vel := Vector3.ZERO
var _net_age := 0.0

# Visuals.
var _rig: EnemyRig
var _last_pos := Vector3.ZERO
var _aim_line: MeshInstance3D
var _aim_target: Node3D = null
var _flash := 0.0


func _ready() -> void:
	collision_layer = LAYER_ENEMY
	collision_mask = MASK_WORLD
	_query.collision_mask = MASK_WORLD
	_think = id * 0.037  # spread brain work across frames
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 2.2
	var shape := CollisionShape3D.new()
	shape.shape = capsule
	shape.position.y = 1.1
	add_child(shape)
	_build_visuals()
	_net_pos = global_position
	_last_pos = global_position
	set_process(false)
	_cooldown = SPAWN_GRACE + id * 0.12


## Body, weapons and animation live in the rig (scripts/enemy_rig.gd); the
## gunman's laser aim line lives here.
func _build_visuals() -> void:
	_rig = EnemyRig.new()
	add_child(_rig)
	_rig.setup(kind, _skin(), Palette.KIND_COLORS[kind], fmod(id * 0.618, 1.0))
	if kind == RoomGen.Kind.GUNMAN:
		_aim_line = MeshInstance3D.new()
		_aim_line.mesh = _get_mesh("unit")
		_aim_line.material_override = Palette.glow(Palette.DANGER, 3.0)
		_aim_line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_aim_line.top_level = true
		_aim_line.visible = false
		add_child(_aim_line)


## Where a gunman points: the player it's winding up on, else the nearest
## one in range (null: keep the gun low).
func _aim_point() -> Variant:
	if kind != RoomGen.Kind.GUNMAN or game == null:
		return null
	if _flash > 0.0 and _aim_target != null and is_instance_valid(_aim_target):
		return _aim_target.chest_pos()
	var best: Variant = null
	var best_d := GUN_RANGE
	for p in game.living_players():
		var d: float = global_position.distance_to(p.global_position)
		if d < best_d:
			best_d = d
			best = p.chest_pos()
	return best


## Meshes are shared by every enemy.
static func _get_mesh(key: String) -> Mesh:
	if _meshes.has(key):
		return _meshes[key]
	var m: Mesh
	match key:
		"body":
			var c := CapsuleMesh.new()
			c.radius = 0.4
			c.height = 1.6
			c.radial_segments = 16
			c.rings = 4
			m = c
		"head":
			var s := SphereMesh.new()
			s.radius = 0.28
			s.height = 0.56
			s.radial_segments = 16
			s.rings = 8
			m = s
		"visor":
			var b := BoxMesh.new()
			b.size = Vector3(0.46, 0.11, 0.12)
			m = b
		"pistol":
			var b := BoxMesh.new()
			b.size = Vector3(0.13, 0.22, 0.56)
			m = b
		"muzzle":
			var b := BoxMesh.new()
			b.size = Vector3(0.15, 0.15, 0.08)
			m = b
		"belt":
			var c := CylinderMesh.new()
			c.top_radius = 0.43
			c.bottom_radius = 0.43
			c.height = 0.16
			c.radial_segments = 16
			m = c
		"grip":
			var b := BoxMesh.new()
			b.size = Vector3(0.07, 0.07, 0.24)
			m = b
		"guard":
			var b := BoxMesh.new()
			b.size = Vector3(0.38, 0.07, 0.07)
			m = b
		"blade":
			var b := BoxMesh.new()
			b.size = Vector3(0.06, 0.15, 1.1)
			m = b
		"fist":
			var s := SphereMesh.new()
			s.radius = 0.21
			s.height = 0.42
			s.radial_segments = 12
			s.rings = 6
			m = s
		_:
			var b := BoxMesh.new()
			b.size = Vector3.ONE
			m = b
	_meshes[key] = m
	return m


func set_targeted(on: bool) -> void:
	if alive:
		_rig.set_tint(Palette.toon(Palette.TARGET) if on else null)


## Dummies look like wooden practice targets.
func _skin() -> Color:
	return Palette.CRATE_EDGE if dummy else Palette.ENEMY


## Tutorial: an enemy waits hidden (not hittable, not thinking) until its step.
func set_active(on: bool) -> void:
	alive = on
	visible = on
	collision_layer = LAYER_ENEMY if on else 0
	set_physics_process(on)
	if on:
		_cooldown = maxf(_cooldown, SPAWN_GRACE)


func die() -> void:
	if not alive:
		return
	alive = false
	collision_layer = 0
	visible = false
	set_physics_process(false)
	set_process(false)


func alert() -> void:
	_alerted = true


func muzzle_pos() -> Vector3:
	return _rig.muzzle_pos()


# --- Network smoothing (clients) ----------------------------------------------

func apply_net_state(x: float, z: float, yaw: float) -> void:
	var p := Vector3(x, global_position.y, z)
	if _net_age > 0.0:
		_net_vel = _net_vel.lerp((p - _net_pos) / maxf(_net_age, 0.01), 0.5)
	_net_pos = p
	_net_yaw = yaw
	_net_age = 0.0


func _process(delta: float) -> void:
	# Telegraph visuals run on every peer.
	if _flash > 0.0:
		_flash = maxf(_flash - delta * Clock.scale, 0.0)
	if _aim_line != null and _aim_line.visible:
		if _aim_target == null or not is_instance_valid(_aim_target) or _flash <= 0.0:
			_aim_line.visible = false
		else:
			_draw_line(muzzle_pos(), _aim_target.chest_pos())
	if _flash <= 0.0 and (_aim_line == null or not _aim_line.visible):
		set_process(false)


## Wind-up telegraph. `target` may be null.
func show_windup(target: Node3D, seconds: float) -> void:
	_flash = seconds
	_rig.set_tint(Palette.toon(Color.WHITE))
	_rig.windup(seconds)
	if _aim_line != null and target != null:
		_aim_target = target
		_aim_line.visible = true
	set_process(true)


func show_strike() -> void:
	_flash = 0.0
	_rig.strike()
	if _aim_line:
		_aim_line.visible = false
	set_targeted(false)


func _draw_line(a: Vector3, b: Vector3) -> void:
	var d := b - a
	var length := d.length()
	if length < 0.05:
		return
	var up := Vector3.UP if absf(d.y / length) < 0.98 else Vector3.RIGHT
	_aim_line.global_transform = Transform3D(
		Basis.looking_at(d, up) * Basis.from_scale(Vector3(0.025, 0.025, length)), (a + b) * 0.5)


# --- Brain (host) ---------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not alive:
		return
	var moved := global_position - _last_pos
	_last_pos = global_position
	_rig.animate(delta, Vector2(moved.x, moved.z).length() / maxf(delta, 0.001), _aim_point())
	if not multiplayer.is_server():
		_net_age += delta
		var predicted := _net_pos + _net_vel * minf(_net_age, 0.15)
		var k := 1.0 - exp(-delta * 14.0)
		global_position = global_position.lerp(predicted, k)
		rotation.y = lerp_angle(rotation.y, _net_yaw, k)
		return
	_brain(delta)


func _brain(real_delta: float) -> void:
	if dummy:
		return
	var delta := real_delta * Clock.scale  # slow motion slows the brain too
	_cooldown = maxf(_cooldown - delta, 0.0)
	_think -= delta
	if _think <= 0.0:
		_think = THINK_EVERY
		_perceive()

	var wish := Vector3.ZERO
	if _windup > 0.0:
		_windup -= delta
		_face(_target.global_position if _target else global_position - global_basis.z)
		if _windup <= 0.0:
			_strike()
	elif _target != null and _alerted:
		var to_target := _target.global_position - global_position
		to_target.y = 0.0
		var dist := to_target.length()
		var wants_attack := false
		if kind == RoomGen.Kind.GUNMAN:
			wants_attack = _sees_target and dist < GUN_RANGE
		else:
			wants_attack = _sees_target and dist < MELEE_RANGE
		if wants_attack and _cooldown <= 0.0:
			_windup = WINDUPS[kind] / pace
			game.announce_windup(self, _target, _windup)
		elif kind == RoomGen.Kind.GUNMAN and _sees_target and dist < GUN_RANGE * 0.6:
			_face(_target.global_position)  # good spot: hold and keep aiming
		else:
			wish = _steer(delta, dist)
	wish += _separation()
	wish *= Clock.scale
	velocity.x = wish.x
	velocity.z = wish.z
	velocity.y = 0.0
	move_and_slide()


func _perceive() -> void:
	var best: Node3D = null
	var best_d := INF
	var best_seen := false
	for p in game.living_players():
		var d: float = global_position.distance_to(p.global_position)
		var seen := d < SIGHT and _line_of_sight(p.chest_pos())
		if seen:
			_alerted = true
		# Prefer players we can see, then the closest.
		if (seen and not best_seen) or (seen == best_seen and d < best_d):
			best = p
			best_d = d
			best_seen = seen
	if best_seen and not _sees_target:
		_cooldown = maxf(_cooldown, REACTION)
	_target = best
	_sees_target = best_seen


func _line_of_sight(to: Vector3) -> bool:
	_query.from = global_position + Vector3(0, 1.7, 0)
	_query.to = to
	return get_world_3d().direct_space_state.intersect_ray(_query).is_empty()


func _steer(delta: float, dist: float) -> Vector3:
	var speed: float = SPEEDS[kind] * pace
	var goal: Vector3 = _target.global_position
	if not _sees_target:
		_repath -= delta
		if _repath <= 0.0 or _path.is_empty():
			_repath = REPATH_EVERY
			_rebuild_path()
		while not _path.is_empty() and Vector2(_path[0].x - global_position.x, _path[0].z - global_position.z).length() < 0.5:
			_path.pop_front()
		if not _path.is_empty():
			goal = _path[0]
	var d := goal - global_position
	d.y = 0.0
	if d.length() < 0.05 or dist < MELEE_RANGE * 0.7:
		return Vector3.ZERO
	_face(global_position + d)
	return d.normalized() * speed


func _rebuild_path() -> void:
	_path.clear()
	var from := RoomGen.world_to_cell(global_position)
	var to := RoomGen.world_to_cell(_target.global_position)
	if not astar.is_in_boundsv(from) or not astar.is_in_boundsv(to):
		return
	var cells := astar.get_id_path(from, to, true)
	for i in range(1, cells.size()):
		_path.append(RoomGen.cell_center(cells[i]))


func _separation() -> Vector3:
	var push := Vector3.ZERO
	for e in game.enemies:
		if e == self or not e.alive:
			continue
		var d: Vector3 = global_position - e.global_position
		d.y = 0.0
		var l := d.length()
		if l < 1.0 and l > 0.001:
			push += d / l * (1.0 - l) * 4.0
	return push


func _face(point: Vector3) -> void:
	var d := point - global_position
	if Vector2(d.x, d.z).length() > 0.01:
		rotation.y = atan2(-d.x, -d.z)


func _strike() -> void:
	_cooldown = (COOLDOWNS[kind] + randf() * COOLDOWN_JITTER[kind]) / pace
	if _target == null:
		return
	if kind == RoomGen.Kind.GUNMAN:
		var origin := muzzle_pos()
		var aim: Vector3 = (_target.chest_pos() - origin).normalized()
		aim = (aim + Vector3(randf_range(-1, 1), randf_range(-0.5, 0.5), randf_range(-1, 1)) * 0.025).normalized()
		game.announce_strike(self, origin, aim)
	else:
		game.announce_strike(self, Vector3.ZERO, Vector3.ZERO)
