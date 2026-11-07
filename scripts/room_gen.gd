extends RefCounted
## Procedural room as pure data. The same seed gives the same room on every
## peer, so only the seed is sent over the network.
##
## Grid cells are TILE metres wide. Cell (x, y) maps to world (x, 0, y), so the
## grid's y axis is the world's z axis.

enum Kind { GUNMAN, KNIFE, FISTS }

const W := 18
const H := 14
const TILE := 2.0
const SPAWN_ROWS := 3          ## rows 1..3 stay free of cover
const MIN_ENEMY_DIST := 6.5    ## cells from the spawn point
const MIN_ENEMIES := 8
const MAX_ENEMIES := 12
const WALL := 1                ## full-height wall
const CRATE := 2               ## waist-high crate: hides a crouching player, can be jumped on

var seed_value := 0
var solid := PackedByteArray()  ## W * H: 0 floor, WALL or CRATE
var spawn_a := Vector2i.ZERO
var spawn_b := Vector2i.ZERO
var enemy_cells: Array[Vector2i] = []
var enemy_kinds: PackedByteArray = PackedByteArray()
var boxes: Array[Rect2i] = []   ## merged wall rectangles, in cells
var crates: Array[Vector2i] = []


static func generate(seed_in: int) -> RefCounted:
	var room = new()
	room._build(seed_in)
	return room


func is_solid(c: Vector2i) -> bool:
	if c.x < 0 or c.y < 0 or c.x >= W or c.y >= H:
		return true
	return solid[c.y * W + c.x] != 0


func is_wall(c: Vector2i) -> bool:
	return solid[c.y * W + c.x] == WALL


static func cell_center(c: Vector2i) -> Vector3:
	return Vector3((c.x + 0.5) * TILE, 0.0, (c.y + 0.5) * TILE)


static func world_to_cell(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / TILE), floori(p.z / TILE))


func floor_count() -> int:
	return solid.count(0)


## Number of floor cells reachable from `from` (4-neighbour flood fill).
func reachable_count(from: Vector2i) -> int:
	if is_solid(from):
		return 0
	var seen := PackedByteArray()
	seen.resize(W * H)
	var stack: Array[Vector2i] = [from]
	seen[from.y * W + from.x] = 1
	var count := 0
	while not stack.is_empty():
		var c: Vector2i = stack.pop_back()
		count += 1
		for d: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var n := c + d
			if is_solid(n) or seen[n.y * W + n.x] == 1:
				continue
			seen[n.y * W + n.x] = 1
			stack.push_back(n)
	return count


func _build(seed_in: int) -> void:
	seed_value = seed_in
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_in

	solid.resize(W * H)
	solid.fill(0)
	for x in W:
		_mark(Vector2i(x, 0), 1)
		_mark(Vector2i(x, H - 1), 1)
	for y in H:
		_mark(Vector2i(0, y), 1)
		_mark(Vector2i(W - 1, y), 1)

	spawn_a = Vector2i(W / 2 - 2, 1)
	spawn_b = Vector2i(W / 2 + 1, 1)

	_place_cover(rng)
	_place_crates(rng)
	_place_enemies(rng)
	_merge_boxes()


func _mark(c: Vector2i, v: int) -> void:
	solid[c.y * W + c.x] = v


func _place_cover(rng: RandomNumberGenerator) -> void:
	var wanted := rng.randi_range(10, 15)
	var placed := 0
	var tries := 0
	var total_floor := floor_count()
	while placed < wanted and tries < 200:
		tries += 1
		var cells := _random_piece(rng)
		var ok := true
		for c in cells:
			if c.x < 1 or c.x > W - 2 or c.y <= SPAWN_ROWS or c.y > H - 2 or is_solid(c):
				ok = false
				break
		if not ok:
			continue
		for c in cells:
			_mark(c, 1)
		# Reject pieces that cut the room into separate parts.
		if reachable_count(spawn_a) != total_floor - cells.size():
			for c in cells:
				_mark(c, 0)
			continue
		total_floor -= cells.size()
		placed += 1


## Low crates, singly or in pairs, anywhere off the spawn rows that doesn't
## cut the room in two.
func _place_crates(rng: RandomNumberGenerator) -> void:
	var wanted := rng.randi_range(6, 10)
	var placed := 0
	var total_floor := floor_count()
	for attempt in 120:
		if placed >= wanted:
			break
		var c := Vector2i(rng.randi_range(1, W - 2), rng.randi_range(SPAWN_ROWS + 1, H - 2))
		var cells: Array[Vector2i] = [c]
		if rng.randf() < 0.35:
			cells.append(c + (Vector2i.RIGHT if rng.randf() < 0.5 else Vector2i.DOWN))
		var ok := true
		for cell in cells:
			if cell.x > W - 2 or cell.y > H - 2 or is_solid(cell):
				ok = false
		if not ok:
			continue
		for cell in cells:
			_mark(cell, CRATE)
		if reachable_count(spawn_a) != total_floor - cells.size():
			for cell in cells:
				_mark(cell, 0)
			continue
		total_floor -= cells.size()
		crates.append_array(cells)
		placed += 1


func _random_piece(rng: RandomNumberGenerator) -> Array[Vector2i]:
	var origin := Vector2i(rng.randi_range(1, W - 2), rng.randi_range(SPAWN_ROWS + 1, H - 2))
	var cells: Array[Vector2i] = []
	var roll := rng.randf()
	if roll < 0.6:
		# Wall segment, horizontal or vertical.
		var length := rng.randi_range(2, 5)
		var step := Vector2i.RIGHT if rng.randf() < 0.5 else Vector2i.DOWN
		for i in length:
			cells.append(origin + step * i)
	elif roll < 0.8:
		cells.append(origin)  # pillar
	else:
		for dy in 2:
			for dx in 2:
				cells.append(origin + Vector2i(dx, dy))  # block
	return cells


func _place_enemies(rng: RandomNumberGenerator) -> void:
	var wanted := rng.randi_range(MIN_ENEMIES, MAX_ENEMIES)
	var spawn_mid := Vector2(spawn_a + spawn_b) * 0.5
	var candidates: Array[Vector2i] = []
	for y in H:
		for x in W:
			var c := Vector2i(x, y)
			if not is_solid(c) and Vector2(c).distance_to(spawn_mid) >= MIN_ENEMY_DIST:
				candidates.append(c)
	# Deterministic shuffle (Array.shuffle uses the global RNG).
	for i in range(candidates.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t := candidates[i]
		candidates[i] = candidates[j]
		candidates[j] = t
	for c in candidates:
		if enemy_cells.size() >= wanted:
			break
		var crowded := false
		for e in enemy_cells:
			if absi(e.x - c.x) <= 1 and absi(e.y - c.y) <= 1:
				crowded = true
				break
		if crowded:
			continue
		enemy_cells.append(c)
		var roll := rng.randf()
		var kind := Kind.GUNMAN if roll < 0.4 else (Kind.KNIFE if roll < 0.7 else Kind.FISTS)
		enemy_kinds.append(kind)


## Greedy rectangle merge of wall cells so the room needs few boxes.
func _merge_boxes() -> void:
	var used := PackedByteArray()
	used.resize(W * H)
	for y in H:
		for x in W:
			if solid[y * W + x] != WALL or used[y * W + x] == 1:
				continue
			var w := 1
			while x + w < W and solid[y * W + x + w] == WALL and used[y * W + x + w] == 0:
				w += 1
			var h := 1
			var grow := true
			while grow and y + h < H:
				for i in w:
					var k := (y + h) * W + x + i
					if solid[k] != WALL or used[k] == 1:
						grow = false
						break
				if grow:
					h += 1
			for yy in h:
				for xx in w:
					used[(y + yy) * W + x + xx] = 1
			boxes.append(Rect2i(x, y, w, h))
