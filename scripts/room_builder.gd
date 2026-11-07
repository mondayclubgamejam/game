extends RefCounted
## Turns RoomGen data into nodes: one floor plane, one wall MultiMesh, one
## static body holding every collision box, and an A* grid for enemies.

const RoomGen := preload("res://scripts/room_gen.gd")
const Palette := preload("res://scripts/palette.gd")
const FloorShader := preload("res://shaders/floor.gdshader")

const WALL_H := 3.2
const CRATE_H := 0.95
const CRATE_SIZE := 1.7   ## a bit under a tile, so crates read as objects
const LAYER_WORLD := 1
const LAYER_GUN_RIM := 16
const CEILING_T := 0.5      ## ceiling slab thickness (thick, so the sun can't leak under it)
const SILL_H := 0.85        ## window wall: solid up to here ...
const LINTEL_H := 2.55      ## ... open up to here, solid above
const WINDOW_PITCH := 4.0   ## a pillar every this many metres along the window wall
const PILLAR_W := 0.7
const PANEL_STEP := 6.0     ## ceiling light panels, every this many metres
const LAMP_STEP := 9.0      ## real lights (fewer than panels; they're costly)

static var _floor_mat: ShaderMaterial
static var _unit_box: BoxMesh


static func build(room: RefCounted) -> Node3D:
	var root := Node3D.new()
	root.name = "Room"
	var tile := RoomGen.TILE
	var extent := Vector2(room.cols * tile, room.rows * tile)

	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = extent
	var floor_mi := MeshInstance3D.new()
	floor_mi.mesh = floor_mesh
	floor_mi.position = Vector3(extent.x * 0.5, 0.0, extent.y * 0.5)
	floor_mi.material_override = _get_floor_mat()
	root.add_child(floor_mi)

	var body := StaticBody3D.new()
	body.name = "Walls"
	body.collision_layer = LAYER_WORLD
	body.collision_mask = 0
	var ground := CollisionShape3D.new()
	ground.shape = WorldBoundaryShape3D.new()
	body.add_child(ground)

	# Collision keeps every wall box solid, windows included, so bullets and
	# the thrown gun never leave the room. Only the visuals open up the windows.
	var boxes: Array[Rect2i] = room.boxes
	var visual: Array = []  # [size, centre] of each wall piece to draw
	for b in boxes:
		var size := Vector3(b.size.x * tile, WALL_H, b.size.y * tile)
		var center := Vector3((b.position.x + b.size.x * 0.5) * tile, WALL_H * 0.5,
			(b.position.y + b.size.y * 0.5) * tile)
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = size
		shape.shape = box
		shape.position = center
		body.add_child(shape)
		# The window wall is the back row (z = H - 1), between the corners:
		# leave that row out of the drawn box and build it with openings below.
		var draw := b
		if b.end.y == room.rows and b.position.x >= 1 and b.end.x <= room.cols - 1:
			draw.size.y -= 1
		if draw.size.y > 0:
			visual.append([Vector3(draw.size.x * tile, WALL_H, draw.size.y * tile),
				Vector3((draw.position.x + draw.size.x * 0.5) * tile, WALL_H * 0.5,
					(draw.position.y + draw.size.y * 0.5) * tile)])
	visual.append_array(_window_wall(extent, tile))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _get_unit_box()
	mm.instance_count = visual.size()
	for i in visual.size():
		mm.set_instance_transform(i, Transform3D(Basis.from_scale(visual[i][0]), visual[i][1]))
	var walls := MultiMeshInstance3D.new()
	walls.multimesh = mm
	walls.material_override = Palette.toon(Palette.WALL)
	root.add_child(walls)

	_build_ceiling(root, body, extent)

	# Crates: one MultiMesh for the boxes and one for their darker lids, so
	# the top edge reads even in flat toon light.
	var crate_cells: Array[Vector2i] = room.crates
	if not crate_cells.is_empty():
		var boxes_mm := MultiMesh.new()
		boxes_mm.transform_format = MultiMesh.TRANSFORM_3D
		boxes_mm.mesh = _get_unit_box()
		boxes_mm.instance_count = crate_cells.size()
		var lids_mm := MultiMesh.new()
		lids_mm.transform_format = MultiMesh.TRANSFORM_3D
		lids_mm.mesh = _get_unit_box()
		lids_mm.instance_count = crate_cells.size()
		var size := Vector3(CRATE_SIZE, CRATE_H, CRATE_SIZE)
		for i in crate_cells.size():
			var center := RoomGen.cell_center(crate_cells[i]) + Vector3(0, CRATE_H * 0.5, 0)
			boxes_mm.set_instance_transform(i, Transform3D(Basis.from_scale(size), center))
			lids_mm.set_instance_transform(i, Transform3D(
				Basis.from_scale(Vector3(CRATE_SIZE + 0.08, 0.1, CRATE_SIZE + 0.08)),
				center + Vector3(0, CRATE_H * 0.5, 0)))
			var shape := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = size
			shape.shape = box
			shape.position = center
			body.add_child(shape)
		var crates_mi := MultiMeshInstance3D.new()
		crates_mi.multimesh = boxes_mm
		crates_mi.material_override = Palette.toon(Palette.CRATE)
		root.add_child(crates_mi)
		var lids_mi := MultiMeshInstance3D.new()
		lids_mi.multimesh = lids_mm
		lids_mi.material_override = Palette.toon(Palette.CRATE_EDGE)
		root.add_child(lids_mi)
	root.add_child(body)

	# Tall invisible rim on top of the outer walls. Only the thrown gun
	# collides with it, so the gun can never leave the room.
	var rim := StaticBody3D.new()
	rim.name = "GunRim"
	rim.collision_layer = LAYER_GUN_RIM
	rim.collision_mask = 0
	var rim_h := 40.0
	var y := WALL_H + rim_h * 0.5
	for side in [
		[Vector3(extent.x * 0.5, y, tile * 0.5), Vector3(extent.x, rim_h, tile)],
		[Vector3(extent.x * 0.5, y, extent.y - tile * 0.5), Vector3(extent.x, rim_h, tile)],
		[Vector3(tile * 0.5, y, extent.y * 0.5), Vector3(tile, rim_h, extent.y)],
		[Vector3(extent.x - tile * 0.5, y, extent.y * 0.5), Vector3(tile, rim_h, extent.y)],
	]:
		var rim_shape := CollisionShape3D.new()
		var rim_box := BoxShape3D.new()
		rim_box.size = side[1]
		rim_shape.shape = rim_box
		rim_shape.position = side[0]
		rim.add_child(rim_shape)
	root.add_child(rim)
	return root


## The back wall's pieces: a sill, a lintel and pillars, leaving wide openings
## the sun shines through. Returns [size, centre] pairs.
static func _window_wall(extent: Vector2, tile: float) -> Array:
	var z := extent.y - tile * 0.5
	var x0 := tile
	var x1 := extent.x - tile
	var length := x1 - x0
	var pieces := [
		[Vector3(length, SILL_H, tile), Vector3((x0 + x1) * 0.5, SILL_H * 0.5, z)],
		[Vector3(length, WALL_H - LINTEL_H, tile), Vector3((x0 + x1) * 0.5, (LINTEL_H + WALL_H) * 0.5, z)],
	]
	var x := x0
	while x <= x1 + 0.01:
		pieces.append([Vector3(PILLAR_W, LINTEL_H - SILL_H, tile),
			Vector3(clampf(x, x0 + PILLAR_W * 0.5, x1 - PILLAR_W * 0.5), (SILL_H + LINTEL_H) * 0.5, z)])
		x += WINDOW_PITCH
	return pieces


## A solid ceiling with glowing light panels and a few real lamps under it.
static func _build_ceiling(root: Node3D, body: StaticBody3D, extent: Vector2) -> void:
	var size := Vector3(extent.x, CEILING_T, extent.y)
	var center := Vector3(extent.x * 0.5, WALL_H + CEILING_T * 0.5, extent.y * 0.5)
	var slab := MeshInstance3D.new()
	slab.mesh = _get_unit_box()
	slab.scale = size
	slab.position = center
	slab.name = "Ceiling"  # tools/map_previews.gd hides it to look in from above
	slab.material_override = Palette.toon(Palette.CEILING)
	root.add_child(slab)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position = center
	body.add_child(shape)

	var panel_mat := StandardMaterial3D.new()
	panel_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	panel_mat.albedo_color = Color("fffdf8")
	panel_mat.emission_enabled = true
	panel_mat.emission = Color("fffaf0")
	panel_mat.emission_energy_multiplier = 1.3
	var panels := MultiMesh.new()
	panels.transform_format = MultiMesh.TRANSFORM_3D
	panels.mesh = _get_unit_box()
	var spots: Array[Vector3] = []
	var px := PANEL_STEP * 0.5 + 1.0
	while px < extent.x - 1.0:
		var pz := PANEL_STEP * 0.5 + 1.0
		while pz < extent.y - 1.0:
			spots.append(Vector3(px, WALL_H - 0.02, pz))
			pz += PANEL_STEP
		px += PANEL_STEP
	panels.instance_count = spots.size()
	for i in spots.size():
		panels.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3(1.4, 0.04, 0.5)), spots[i]))
	var panels_mi := MultiMeshInstance3D.new()
	panels_mi.multimesh = panels
	panels_mi.name = "CeilingPanels"
	panels_mi.material_override = panel_mat
	panels_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(panels_mi)

	var lx := LAMP_STEP * 0.5
	while lx < extent.x:
		var lz := LAMP_STEP * 0.5
		while lz < extent.y:
			var lamp := OmniLight3D.new()
			lamp.position = Vector3(lx, WALL_H - 0.4, lz)
			lamp.omni_range = LAMP_STEP * 1.2
			lamp.light_energy = 0.3
			lamp.light_color = Color("fff6ea")
			lamp.shadow_enabled = false
			root.add_child(lamp)
			lz += LAMP_STEP
		lx += LAMP_STEP


static func build_astar(room: RefCounted) -> AStarGrid2D:
	var grid := AStarGrid2D.new()
	grid.region = Rect2i(0, 0, room.cols, room.rows)
	grid.cell_size = Vector2(RoomGen.TILE, RoomGen.TILE)
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	grid.update()
	for y in room.rows:
		for x in room.cols:
			if room.is_solid(Vector2i(x, y)):
				grid.set_point_solid(Vector2i(x, y), true)
	return grid


static func _get_floor_mat() -> ShaderMaterial:
	if _floor_mat == null:
		_floor_mat = ShaderMaterial.new()
		_floor_mat.shader = FloorShader
		_floor_mat.set_shader_parameter("color_a", Palette.FLOOR_A)
		_floor_mat.set_shader_parameter("color_b", Palette.FLOOR_B)
		_floor_mat.set_shader_parameter("tile", RoomGen.TILE)
	return _floor_mat


static func _get_unit_box() -> BoxMesh:
	if _unit_box == null:
		_unit_box = BoxMesh.new()
		_unit_box.size = Vector3.ONE
	return _unit_box
