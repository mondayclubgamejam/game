extends RefCounted
## Builds a greybox level from an ASCII map (legend from PLAN.md).
##   #  wall          .  floor        A  player start
##   E  enemy         S  shielded enemy (faces the nearest `d`)
##   D  exit door     d  open doorway   G / B  treated as floor for now

const Enemy := preload("res://scripts/enemy.gd")

const TILE := 2.0
const WALL_H := 3.2

const WALL_COLOR := Color("5a3c8c")
const FLOOR_A := Color("f3e9d2")
const FLOOR_B := Color("e3d3b0")
const DOOR_COLOR := Color("ffcc1a")


static func toon(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	m.roughness = 1.0
	return m


## Returns { spawn: Vector3, enemies: Array, doors: Array, exit_z: float }.
static func build(root: Node3D, map: Array) -> Dictionary:
	var wall_mat := toon(WALL_COLOR)
	var floor_mats := [toon(FLOOR_A), toon(FLOOR_B)]
	var door_mat := toon(DOOR_COLOR)

	var rows := map.size()
	var cols := 0
	for line in map:
		cols = maxi(cols, String(line).length())

	var spawn := Vector3.ZERO
	var enemy_specs := []
	var doorways := []
	var doors := []
	var door_cols := []

	for r in rows:
		var line: String = map[r]
		for c in line.length():
			var ch := line[c]
			var p := Vector3(c * TILE, 0, r * TILE)
			if ch == "#":
				_add_box(root, p + Vector3(0, WALL_H / 2.0, 0),
					Vector3(TILE, WALL_H, TILE), wall_mat, true)
				continue
			_add_floor_tile(root, p, floor_mats[(r + c) % 2])
			match ch:
				"A":
					spawn = p
				"E", "S":
					enemy_specs.append({"pos": p, "shielded": ch == "S"})
				"d":
					doorways.append(p)
				"D":
					doors.append(_add_box(root, p + Vector3(0, WALL_H / 2.0, 0),
						Vector3(TILE, WALL_H, TILE * 0.5), door_mat, true))
					door_cols.append(c)

	# A little floor outside each exit door so the player can walk out.
	for c in door_cols:
		for r in range(rows, rows + 3):
			for dc in [-1, 0, 1]:
				_add_floor_tile(root, Vector3((c + dc) * TILE, 0, r * TILE),
					floor_mats[(r + c + dc) % 2])

	# One big collision slab for the floor.
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1
	floor_body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3((cols + 2) * TILE, 0.2, (rows + 5) * TILE)
	shape.shape = box
	floor_body.add_child(shape)
	floor_body.position = Vector3((cols - 1) * TILE / 2.0, -0.1, (rows + 2) * TILE / 2.0)
	root.add_child(floor_body)

	var enemies := []
	for spec in enemy_specs:
		var e := Enemy.new()
		e.shielded = spec["shielded"]
		root.add_child(e)
		e.global_position = spec["pos"]
		var look_target: Vector3 = spawn
		if e.shielded and not doorways.is_empty():
			look_target = _nearest(spec["pos"], doorways)
		e.face(look_target)
		enemies.append(e)

	return {
		"spawn": spawn,
		"enemies": enemies,
		"doors": doors,
		"exit_z": (rows - 1) * TILE + TILE * 0.6,
	}


static func _nearest(from: Vector3, points: Array) -> Vector3:
	var best: Vector3 = points[0]
	for p in points:
		if from.distance_to(p) < from.distance_to(best):
			best = p
	return best


static func _add_floor_tile(root: Node3D, p: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(TILE, 0.1, TILE)
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = p + Vector3(0, -0.05, 0)
	root.add_child(mi)


static func _add_box(root: Node3D, center: Vector3, size: Vector3, mat: Material,
		solid: bool) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1 if solid else 0
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	body.add_child(mi)
	body.position = center
	root.add_child(body)
	return body
