extends RefCounted
## Turns RoomGen data into nodes: one floor plane, one wall MultiMesh, one
## static body holding every collision box, and an A* grid for enemies.

const RoomGen := preload("res://scripts/room_gen.gd")
const Palette := preload("res://scripts/palette.gd")
const FloorShader := preload("res://shaders/floor.gdshader")

const WALL_H := 3.2
const LAYER_WORLD := 1
const LAYER_GUN_RIM := 16

static var _floor_mat: ShaderMaterial
static var _unit_box: BoxMesh


static func build(room: RefCounted) -> Node3D:
	var root := Node3D.new()
	root.name = "Room"
	var tile := RoomGen.TILE
	var extent := Vector2(RoomGen.W * tile, RoomGen.H * tile)

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

	var boxes: Array[Rect2i] = room.boxes
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _get_unit_box()
	mm.instance_count = boxes.size()
	for i in boxes.size():
		var b := boxes[i]
		var size := Vector3(b.size.x * tile, WALL_H, b.size.y * tile)
		var center := Vector3((b.position.x + b.size.x * 0.5) * tile, WALL_H * 0.5,
			(b.position.y + b.size.y * 0.5) * tile)
		mm.set_instance_transform(i, Transform3D(Basis.from_scale(size), center))
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = size
		shape.shape = box
		shape.position = center
		body.add_child(shape)
	var walls := MultiMeshInstance3D.new()
	walls.multimesh = mm
	walls.material_override = Palette.toon(Palette.WALL)
	root.add_child(walls)
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


static func build_astar(room: RefCounted) -> AStarGrid2D:
	var grid := AStarGrid2D.new()
	grid.region = Rect2i(0, 0, RoomGen.W, RoomGen.H)
	grid.cell_size = Vector2(RoomGen.TILE, RoomGen.TILE)
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	grid.update()
	for y in RoomGen.H:
		for x in RoomGen.W:
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
