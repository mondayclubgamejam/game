extends RefCounted
## Procedural room as pure data. The same seed gives the same room on every
## peer, so only the seed is sent over the network.
##
## Grid cells are TILE metres wide. Cell (x, y) maps to world (x, 0, y), so the
## grid's y axis is the world's z axis.

enum Kind { GUNMAN, KNIFE, FISTS }

## Room size grows with the number of players (index = players).
const SIZES := {2: Vector2i(18, 14), 3: Vector2i(21, 16), 4: Vector2i(24, 18)}
const MAX_PLAYERS := 4
const TILE := 2.0
const SPAWN_ROWS := 3          ## rows 1..3 stay free of cover
const MIN_ENEMY_DIST := 6.5    ## cells from the spawn point
const MIN_ENEMIES := 8
const MAX_ENEMIES := 12
const WALL := 1                ## full-height wall
const CRATE := 2               ## waist-high crate: hides a crouching player, can be jumped on
## Endless: each room deeper adds enemies, gunmen and pace, up to these caps.
const LEVEL_ENEMIES := 2       ## extra enemies per level
const MAX_EXTRA_ENEMIES := 14
const LEVEL_GUNMEN := 0.025    ## extra gunman share per level
const MAX_EXTRA_GUNMEN := 0.2
const LEVEL_PACE := 0.05       ## enemies move and attack this much faster per level
const MAX_PACE := 1.5

var seed_value := 0
var players := 2
var level := 0                  ## difficulty: 0 normally, Endless room - 1
var pace := 1.0                 ## enemy speed and attack-rate multiplier
var cols := 18
var rows := 14
var solid := PackedByteArray()  ## cols * rows: 0 floor, WALL or CRATE
var spawns: Array[Vector2i] = []  ## one per player, side by side on the spawn row
var enemy_cells: Array[Vector2i] = []
var enemy_kinds: PackedByteArray = PackedByteArray()
var boxes: Array[Rect2i] = []   ## merged wall rectangles, in cells
var crates: Array[Vector2i] = []


## `player_count` (2-4) makes the room bigger and adds enemies; `difficulty`
## (Endless: room number - 1) adds more, more gunmen and a faster pace.
static func generate(seed_in: int, player_count := 2, difficulty := 0) -> RefCounted:
	var room = new()
	room.level = maxi(difficulty, 0)
	room.pace = pace_for(room.level)
	room._build(seed_in, clampi(player_count, 2, MAX_PLAYERS))
	return room


## A hand-made room from text rows (see scripts/maps.gd for the symbols).
static func from_layout(lines: Array, player_count := 2, pace_in := 1.0) -> RefCounted:
	var room = new()
	room.pace = pace_in
	room._load(lines, clampi(player_count, 2, MAX_PLAYERS))
	return room


static func pace_for(lvl: int) -> float:
	return minf(1.0 + LEVEL_PACE * maxi(lvl, 0), MAX_PACE)


static func extra_enemies(lvl: int) -> int:
	return mini(LEVEL_ENEMIES * maxi(lvl, 0), MAX_EXTRA_ENEMIES)


static func gunman_share(player_count: int, lvl: int) -> float:
	return 0.4 + 0.05 * (player_count - 2) + minf(LEVEL_GUNMEN * maxi(lvl, 0), MAX_EXTRA_GUNMEN)


## Average of the spawn cells.
func spawn_center() -> Vector2:
	var sum := Vector2.ZERO
	for c in spawns:
		sum += Vector2(c)
	return sum / spawns.size()


## How much bigger than the two-player room this one is.
func _area_scale() -> float:
	return float(cols * rows) / float(SIZES[2].x * SIZES[2].y)


func is_solid(c: Vector2i) -> bool:
	if c.x < 0 or c.y < 0 or c.x >= cols or c.y >= rows:
		return true
	return solid[c.y * cols + c.x] != 0


func is_wall(c: Vector2i) -> bool:
	return solid[c.y * cols + c.x] == WALL


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
	seen.resize(cols * rows)
	var stack: Array[Vector2i] = [from]
	seen[from.y * cols + from.x] = 1
	var count := 0
	while not stack.is_empty():
		var c: Vector2i = stack.pop_back()
		count += 1
		for d: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var n := c + d
			if is_solid(n) or seen[n.y * cols + n.x] == 1:
				continue
			seen[n.y * cols + n.x] = 1
			stack.push_back(n)
	return count


func _build(seed_in: int, player_count: int) -> void:
	seed_value = seed_in
	players = player_count
	cols = SIZES[players].x
	rows = SIZES[players].y
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_in

	solid.resize(cols * rows)
	solid.fill(0)
	for x in cols:
		_mark(Vector2i(x, 0), 1)
		_mark(Vector2i(x, rows - 1), 1)
	for y in rows:
		_mark(Vector2i(0, y), 1)
		_mark(Vector2i(cols - 1, y), 1)

	var first := cols / 2 - (players - 1)
	for i in players:
		spawns.append(Vector2i(first + 2 * i, 1))

	_place_cover(rng)
	_place_crates(rng)
	_place_enemies(rng)
	_merge_boxes()


func _load(lines: Array, player_count: int) -> void:
	players = player_count
	rows = lines.size()
	cols = str(lines[0]).length()
	solid.resize(cols * rows)
	solid.fill(0)
	var spawn_at := {}
	var kinds := {"g": Kind.GUNMAN, "k": Kind.KNIFE, "f": Kind.FISTS}
	for y in rows:
		var line := str(lines[y])
		for x in mini(cols, line.length()):
			var ch := line[x]
			var c := Vector2i(x, y)
			if ch == "#":
				_mark(c, WALL)
			elif ch == "c":
				_mark(c, CRATE)
				crates.append(c)
			elif ch in ["1", "2", "3", "4"]:
				spawn_at[ch.to_int()] = c
			elif kinds.has(ch.to_lower()) and (ch == ch.to_lower() or players >= 3):
				enemy_cells.append(c)
				enemy_kinds.append(kinds[ch.to_lower()])
	for i in players:
		spawns.append(spawn_at.get(i + 1, Vector2i(1 + i, 1)))
	_merge_boxes()


func _mark(c: Vector2i, v: int) -> void:
	solid[c.y * cols + c.x] = v


func _place_cover(rng: RandomNumberGenerator) -> void:
	var wanted := roundi(rng.randi_range(10, 15) * _area_scale())
	var placed := 0
	var tries := 0
	var total_floor := floor_count()
	while placed < wanted and tries < roundi(200 * _area_scale()):
		tries += 1
		var cells := _random_piece(rng)
		var ok := true
		for c in cells:
			if c.x < 1 or c.x > cols - 2 or c.y <= SPAWN_ROWS or c.y > rows - 2 or is_solid(c):
				ok = false
				break
		if not ok:
			continue
		for c in cells:
			_mark(c, 1)
		# Reject pieces that cut the room into separate parts.
		if reachable_count(spawns[0]) != total_floor - cells.size():
			for c in cells:
				_mark(c, 0)
			continue
		total_floor -= cells.size()
		placed += 1


## Low crates, singly or in pairs, anywhere off the spawn rows that doesn't
## cut the room in two.
func _place_crates(rng: RandomNumberGenerator) -> void:
	var wanted := roundi(rng.randi_range(6, 10) * _area_scale())
	var placed := 0
	var total_floor := floor_count()
	for attempt in roundi(120 * _area_scale()):
		if placed >= wanted:
			break
		var c := Vector2i(rng.randi_range(1, cols - 2), rng.randi_range(SPAWN_ROWS + 1, rows - 2))
		var cells: Array[Vector2i] = [c]
		if rng.randf() < 0.35:
			cells.append(c + (Vector2i.RIGHT if rng.randf() < 0.5 else Vector2i.DOWN))
		var ok := true
		for cell in cells:
			if cell.x > cols - 2 or cell.y > rows - 2 or is_solid(cell):
				ok = false
		if not ok:
			continue
		for cell in cells:
			_mark(cell, CRATE)
		if reachable_count(spawns[0]) != total_floor - cells.size():
			for cell in cells:
				_mark(cell, 0)
			continue
		total_floor -= cells.size()
		crates.append_array(cells)
		placed += 1


func _random_piece(rng: RandomNumberGenerator) -> Array[Vector2i]:
	var origin := Vector2i(rng.randi_range(1, cols - 2), rng.randi_range(SPAWN_ROWS + 1, rows - 2))
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
	# Four more enemies per player beyond two, with a few more gunmen; more
	# still the deeper an Endless run goes. Spacing below keeps it from jamming.
	var wanted := rng.randi_range(MIN_ENEMIES, MAX_ENEMIES) + 4 * (players - 2) + extra_enemies(level)
	var share := gunman_share(players, level)
	var spawn_mid := spawn_center()
	var candidates: Array[Vector2i] = []
	for y in rows:
		for x in cols:
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
		var kind := Kind.GUNMAN if roll < share else (Kind.KNIFE if roll < share + 0.3 else Kind.FISTS)
		enemy_kinds.append(kind)


## Greedy rectangle merge of wall cells so the room needs few boxes.
func _merge_boxes() -> void:
	var used := PackedByteArray()
	used.resize(cols * rows)
	for y in rows:
		for x in cols:
			if solid[y * cols + x] != WALL or used[y * cols + x] == 1:
				continue
			var w := 1
			while x + w < cols and solid[y * cols + x + w] == WALL and used[y * cols + x + w] == 0:
				w += 1
			var h := 1
			var grow := true
			while grow and y + h < rows:
				for i in w:
					var k := (y + h) * cols + x + i
					if solid[k] != WALL or used[k] == 1:
						grow = false
						break
				if grow:
					h += 1
			for yy in h:
				for xx in w:
					used[(y + yy) * cols + x + xx] = 1
			boxes.append(Rect2i(x, y, w, h))
