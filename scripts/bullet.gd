extends Node3D
## The one shared bullet, and the rules for who can do what with it.
##
##   Player A (forward) fires it: it kills on the way out and lodges in a wall.
##   Player B (inverted) recalls it: it rips out of the wall, flies to B, and
##   relays straight on back into A's gun. Both recall legs kill.
##
## Forward (orange) enemies only die to the shot; inverted (blue) ones only to
## the recall. Aim lines show in both players' views.

signal state_changed(state: int)
signal fired
signal lodged
signal relayed        ## the bullet passed through B on its way back
signal returned       ## the bullet is back in A's gun
signal recall_blocked
signal shot_finished(kills: int, was_recall: bool)

enum { LOADED, FLYING_OUT, LODGED, FLYING_BACK }

const RANGE := 120.0
const BULLET_SPEED := 70.0
const MASK_WALL := 1
const MASK_ENEMY := 2
const LINE_GAP := 1.0  ## aim lines stop this far from a player's gun

const FIRE_COLOR := Color(1.0, 0.48, 0.1, 0.85)
const RECALL_COLOR := Color(0.18, 0.66, 1.0, 0.85)
const BLOCKED_COLOR := Color(1.0, 0.15, 0.2, 0.6)

var shooter: Node3D   ## player A
var recaller: Node3D  ## player B
var state := LOADED
var lodge_pos := Vector3.ZERO

var _slug: Node3D
var _mat: StandardMaterial3D
var _light: OmniLight3D
var _trail: MeshInstance3D
var _lines: Array = []  ## [{mesh, mat}]
var _targeted: Array = []


func _ready() -> void:
	_build_slug()
	for i in 2:
		_lines.append(_build_line())


func _physics_process(_delta: float) -> void:
	_update_preview()


## Player A pressed fire.
func try_fire() -> void:
	if state != LOADED:
		return
	var from: Vector3 = shooter.eye()
	var r := _trace(from, from + shooter.aim_dir() * RANGE, false)
	state = FLYING_OUT
	state_changed.emit(state)
	fired.emit()
	_fly([{"from": shooter.muzzle(), "to": r["end"], "hits": r["hits"], "immune": r["immune"]}],
		false)


## Player B pressed recall.
func try_recall() -> void:
	if state != LODGED:
		return
	var legs := _recall_legs()
	if legs["blocked"]:
		recall_blocked.emit()
		return
	state = FLYING_BACK
	state_changed.emit(state)
	_fly([
		{"from": lodge_pos, "to": recaller.muzzle(), "hits": legs["a"]["hits"],
			"immune": legs["a"]["immune"]},
		{"from": recaller.muzzle(), "to": shooter.muzzle(), "hits": legs["b"]["hits"],
			"immune": legs["b"]["immune"]},
	], true)


## Both recall legs: wall -> B, then B -> A.
func _recall_legs() -> Dictionary:
	var a := _trace(lodge_pos, recaller.eye(), true)
	var b := _trace(recaller.eye(), shooter.eye(), true)
	return {"a": a, "b": b, "blocked": a["blocked"] or b["blocked"]}


## Fly the bullet along one or more straight legs, killing as it passes.
func _fly(legs: Array, is_recall: bool) -> void:
	var color := RECALL_COLOR if is_recall else FIRE_COLOR
	_mat.emission = color
	_mat.albedo_color = Color(color, 1.0)
	_light.light_color = color
	_slug.visible = true
	_trail.visible = true
	_slug.global_position = legs[0]["from"]

	var tw := create_tween()
	var t0 := 0.0
	var kills := 0
	for i in legs.size():
		var leg: Dictionary = legs[i]
		var from: Vector3 = leg["from"]
		var to: Vector3 = leg["to"]
		var dir := (to - from).normalized()
		var duration := maxf(from.distance_to(to) / BULLET_SPEED, 0.05)
		tw.tween_callback(_orient.bind(_slug, to - from))
		tw.tween_property(_slug, "global_position", to, duration).from(from)
		for hit in leg["hits"]:
			_after(t0 + hit["dist"] / BULLET_SPEED, Callable(hit["enemy"], "die").bind(dir))
		# The wrong kind of shot passes straight through: the enemy just flashes.
		for hit in leg["immune"]:
			_after(t0 + hit["dist"] / BULLET_SPEED, Callable(hit["enemy"], "flash_immune"))
		kills += leg["hits"].size()
		t0 += duration
		if is_recall and i == 0:
			tw.tween_callback(func(): relayed.emit())
	tw.tween_callback(_on_arrived.bind(legs[-1]["to"], kills, is_recall))


func _after(seconds: float, callable: Callable) -> void:
	get_tree().create_timer(seconds).timeout.connect(callable)


func _on_arrived(end: Vector3, kills: int, is_recall: bool) -> void:
	_trail.visible = false
	if is_recall:
		_slug.visible = false
		state = LOADED
		returned.emit()
	else:
		lodge_pos = end
		state = LODGED
		lodged.emit()
	state_changed.emit(state)
	shot_finished.emit(kills, is_recall)


## Walks a straight line, passing through enemies and stopping at the first wall
## or at a shield facing the bullet. Enemies this shot can kill go in `hits`;
## ones it can't (wrong time direction) go in `immune`.
func _trace(from: Vector3, to: Vector3, is_recall: bool) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var dir := (to - from).normalized()
	var exclude: Array[RID] = []
	var hits := []
	var immune := []
	for i in 32:
		var query := PhysicsRayQueryParameters3D.create(from, to, MASK_WALL | MASK_ENEMY, exclude)
		var r := space.intersect_ray(query)
		if r.is_empty():
			return {"hits": hits, "immune": immune, "end": to, "blocked": false}
		var collider: Object = r["collider"]
		var pos: Vector3 = r["position"]
		var normal: Vector3 = r["normal"]
		if collider.has_method("is_shield_blocking") and not collider.dead:
			if collider.is_shield_blocking(dir):
				return {"hits": hits, "immune": immune, "end": pos + normal * 0.06, "blocked": true}
			var hit := {"enemy": collider, "dist": from.distance_to(pos)}
			if collider.can_be_killed_by(is_recall):
				hits.append(hit)
			else:
				immune.append(hit)
			exclude.append(r["rid"])
			continue
		return {"hits": hits, "immune": immune, "end": pos + normal * 0.06, "blocked": true}
	return {"hits": hits, "immune": immune, "end": to, "blocked": false}


# --- Preview lines -----------------------------------------------------------

func _update_preview() -> void:
	if shooter == null or recaller == null:
		return
	var targets := []
	match state:
		LOADED:
			var from: Vector3 = shooter.eye()
			var r := _trace(from, from + shooter.aim_dir() * RANGE, false)
			_set_line(0, shooter.muzzle(), r["end"], FIRE_COLOR, true, false)
			_lines[1]["mesh"].visible = false
			targets = r["hits"]
		LODGED:
			var legs := _recall_legs()
			var a: Dictionary = legs["a"]
			var b: Dictionary = legs["b"]
			_set_line(0, lodge_pos, recaller.muzzle(),
				BLOCKED_COLOR if a["blocked"] else RECALL_COLOR, false, true)
			_set_line(1, recaller.muzzle(), shooter.muzzle(),
				BLOCKED_COLOR if b["blocked"] else RECALL_COLOR, true, true)
			if not legs["blocked"]:
				targets = a["hits"] + b["hits"]
		_:
			for l in _lines:
				l["mesh"].visible = false
	var enemies := targets.map(func(h): return h["enemy"])
	for e in _targeted:
		if is_instance_valid(e):
			e.set_targeted(false)
	for e in enemies:
		e.set_targeted(true)
	_targeted = enemies


## Draw line `i` from a to b. gap_a / gap_b leave a gap at a player's gun so
## the line doesn't fill that player's view as a wedge.
func _set_line(i: int, a: Vector3, b: Vector3, color: Color, gap_a: bool, gap_b: bool) -> void:
	var line: Dictionary = _lines[i]
	var mesh: MeshInstance3D = line["mesh"]
	var d := b - a
	var length := d.length()
	if length < LINE_GAP * 2.5 or absf(d.y / length) > 0.99:
		mesh.visible = false
		return
	var forward := d / length
	if gap_a:
		a += forward * LINE_GAP
	if gap_b:
		b -= forward * LINE_GAP
	length = a.distance_to(b)
	mesh.visible = true
	line["mat"].albedo_color = color
	var basis_scaled := Basis.looking_at(forward, Vector3.UP) * Basis.from_scale(
		Vector3(0.012, 0.012, length))
	mesh.global_transform = Transform3D(basis_scaled, (a + b) / 2.0)


# --- Visuals -----------------------------------------------------------------

func _build_slug() -> void:
	_slug = Node3D.new()
	_slug.visible = false
	add_child(_slug)

	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# Transparent so the outline post-process skips it and it draws on top.
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.albedo_color = Color(FIRE_COLOR, 1.0)
	_mat.emission_enabled = true
	_mat.emission = FIRE_COLOR
	_mat.emission_energy_multiplier = 6.0

	var slug := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.05
	cyl.bottom_radius = 0.05
	cyl.height = 0.35
	slug.mesh = cyl
	slug.material_override = _mat
	slug.rotation.x = PI / 2.0
	slug.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_slug.add_child(slug)

	_trail = MeshInstance3D.new()
	var trail_mesh := BoxMesh.new()
	trail_mesh.size = Vector3(0.05, 0.05, 2.0)
	_trail.mesh = trail_mesh
	_trail.material_override = _mat
	_trail.position = Vector3(0, 0, 1.0)
	_trail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_slug.add_child(_trail)

	_light = OmniLight3D.new()
	_light.light_color = FIRE_COLOR
	_light.light_energy = 2.0
	_light.omni_range = 3.0
	_slug.add_child(_light)


func _build_line() -> Dictionary:
	var mesh := MeshInstance3D.new()
	mesh.visible = false
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = FIRE_COLOR
	mesh.material_override = mat
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh)
	return {"mesh": mesh, "mat": mat}


static func _orient(node: Node3D, d: Vector3) -> void:
	if d.length() < 0.001:
		return
	var forward := d.normalized()
	if absf(forward.y) > 0.99:
		return
	node.global_basis = Basis.looking_at(forward, Vector3.UP)
