extends SceneTree
## Headless logic tests. Run with:
##   godot --headless --path . --script res://tests/test_runner.gd

const RoomGen := preload("res://scripts/room_gen.gd")
const Traj := preload("res://scripts/trajectory.gd")
const Lan := preload("res://scripts/lan_discovery.gd")
const Maps := preload("res://scripts/maps.gd")

var _failed := 0
var _passed := 0


func _initialize() -> void:
	test_room_is_deterministic()
	test_crates_are_placed_sensibly()
	test_rooms_scale_with_players()
	test_endless_ramps_up_with_caps()
	test_hand_made_maps()
	test_rooms_are_connected_and_populated()
	test_different_seeds_differ()
	test_merged_boxes_cover_exactly_the_walls()
	test_recall_curve_starts_backwards_and_ends_at_gun()
	test_throw_reaches_target()
	test_lan_beacon_round_trip()
	test_lan_beacon_rejects_foreign_packets()
	test_lan_broadcast_targets()
	test_lan_private_ranges_and_sweep()
	print("\n%d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


func check(cond: bool, msg: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("FAIL: ", msg)


func test_room_is_deterministic() -> void:
	var a = RoomGen.generate(12345)
	var b = RoomGen.generate(12345)
	check(a.solid == b.solid, "same seed gives same walls")
	check(a.enemy_cells == b.enemy_cells, "same seed gives same enemy cells")
	check(a.enemy_kinds == b.enemy_kinds, "same seed gives same enemy kinds")


func test_rooms_are_connected_and_populated() -> void:
	for s in 300:
		var r = RoomGen.generate(s * 7919 + 3)
		check(r.reachable_count(r.spawns[0]) == r.floor_count(), "seed %d fully connected" % s)
		for sp in r.spawns:
			check(not r.is_solid(sp), "seed %d spawns free" % s)
		check(r.enemy_cells.size() >= RoomGen.MIN_ENEMIES, "seed %d has >= %d enemies (got %d)"
			% [s, RoomGen.MIN_ENEMIES, r.enemy_cells.size()])
		check(r.enemy_cells.size() == r.enemy_kinds.size(), "seed %d kinds match cells" % s)
		var mid: Vector2 = r.spawn_center()
		for c in r.enemy_cells:
			check(not r.is_solid(c), "seed %d enemy on floor" % s)
			check(Vector2(c).distance_to(mid) >= RoomGen.MIN_ENEMY_DIST, "seed %d enemy far from spawn" % s)
		if _failed > 0:
			return


func test_different_seeds_differ() -> void:
	var a = RoomGen.generate(1)
	var b = RoomGen.generate(2)
	check(a.solid != b.solid or a.enemy_cells != b.enemy_cells, "different seeds give different rooms")


func test_merged_boxes_cover_exactly_the_walls() -> void:
	for s in 50:
		var r = RoomGen.generate(s)
		var cover := PackedByteArray()
		cover.resize(r.cols * r.rows)
		var overlap := false
		for b: Rect2i in r.boxes:
			for y in range(b.position.y, b.end.y):
				for x in range(b.position.x, b.end.x):
					if cover[y * r.cols + x] == 1:
						overlap = true
					cover[y * r.cols + x] = 1
		var walls := PackedByteArray()
		walls.resize(r.cols * r.rows)
		for i in walls.size():
			walls[i] = 1 if r.solid[i] == RoomGen.WALL else 0
		check(cover == walls, "seed %d boxes cover walls exactly" % s)
		check(not overlap, "seed %d boxes do not overlap" % s)
		check(r.boxes.size() < 40, "seed %d merged into few boxes (%d)" % [s, r.boxes.size()])


func test_recall_curve_starts_backwards_and_ends_at_gun() -> void:
	var lodge := Vector3(10, 1.5, 10)
	var dir_in := Vector3(1, 0, 0)  # bullet was travelling +x when it stuck
	var gun := Vector3(0, 1.4, 20)
	var p1 := Traj.recall_control(lodge, dir_in, gun)
	check(Traj.bezier(lodge, p1, gun, 0.0).is_equal_approx(lodge), "curve starts at lodge point")
	check(Traj.bezier(lodge, p1, gun, 1.0).is_equal_approx(gun), "curve ends at the gun")
	var early := Traj.bezier(lodge, p1, gun, 0.02) - lodge
	check(early.normalized().dot(-dir_in) > 0.9, "curve leaves the way the bullet came in")
	var length := Traj.bezier_length(lodge, p1, gun)
	check(length >= lodge.distance_to(gun) - 0.001, "length estimate is at least the chord")


func test_throw_reaches_target() -> void:
	var from := Vector3(0, 1.4, 0)
	for to in [Vector3(8, 1.2, 3), Vector3(-15, 1.2, 20), Vector3(2, 1.2, 0)]:
		var v := Traj.throw_velocity(from, to)
		# Simulate the same integration the gun uses.
		var p := from
		var vel := v
		var best := INF
		var dt := 1.0 / 120.0
		for i in 240:
			vel.y -= Traj.GUN_GRAVITY * dt
			p += vel * dt
			best = minf(best, p.distance_to(to))
		check(best < 0.35, "throw passes within 0.35 m of %s (closest %.2f)" % [to, best])


func test_lan_beacon_round_trip() -> void:
	var info := Lan.decode(Lan.encode_host(7777, "NESTOR", 42))
	check(info.get("t") == "h", "host packet decodes as a host")
	check(info.get("port") == 7777, "beacon keeps the port")
	check(info.get("name") == "NESTOR", "beacon keeps the name")
	check(info.get("id") == 42, "beacon keeps the session id")
	check(Lan.decode(Lan.encode_query()).get("t") == "q", "query decodes as a query")
	var long_name := Lan.decode(Lan.encode_host(7777, "X".repeat(100), 1))
	check(str(long_name.get("name")).length() == 32, "beacon names are capped")


func test_lan_beacon_rejects_foreign_packets() -> void:
	check(Lan.decode("hello".to_utf8_buffer()).is_empty(), "plain text ignored")
	check(Lan.decode(PackedByteArray()).is_empty(), "empty packet ignored")
	check(Lan.decode(JSON.stringify({"g": "OTHER", "t": "q"}).to_utf8_buffer()).is_empty(), "other games ignored")
	check(Lan.decode(JSON.stringify({"g": "OGOB1", "port": 7777}).to_utf8_buffer()).is_empty(), "old protocol ignored")
	check(Lan.decode(JSON.stringify({"g": Lan.MAGIC, "t": "h", "port": 0}).to_utf8_buffer()).is_empty(), "bad port ignored")
	check(Lan.decode(JSON.stringify({"g": Lan.MAGIC, "t": "h", "port": 70000}).to_utf8_buffer()).is_empty(), "port out of range ignored")
	check(Lan.decode(JSON.stringify({"g": Lan.MAGIC, "t": "x"}).to_utf8_buffer()).is_empty(), "unknown type ignored")
	check(Lan.decode(JSON.stringify([1, 2]).to_utf8_buffer()).is_empty(), "non-object JSON ignored")
	var big := PackedByteArray()
	big.resize(4096)
	check(Lan.decode(big).is_empty(), "oversized packet ignored")


func test_lan_broadcast_targets() -> void:
	var targets := Lan.broadcast_targets()
	check(targets.has("255.255.255.255"), "always broadcasts to 255.255.255.255")
	check(targets.has("127.0.0.1"), "also asks this machine")
	for t in targets:
		if t != "127.0.0.1":
			check(t.ends_with(".255"), "broadcast target %s ends in .255" % t)


func test_lan_private_ranges_and_sweep() -> void:
	for ip in ["10.0.0.5", "192.168.1.20", "172.16.0.1", "172.31.255.1"]:
		check(Lan.is_private_ipv4(ip), "%s is private" % ip)
	for ip in ["8.8.8.8", "172.32.0.1", "100.106.214.117", "fe80::1", "127.0.0.1"]:
		check(not Lan.is_private_ipv4(ip), "%s is not swept" % ip)
	var sweep := Lan.sweep_targets()
	var mine := Lan.local_ipv4()
	check(sweep.size() <= 254 * Lan.MAX_SWEEP_NETWORKS, "sweep is bounded")
	for ip in sweep:
		check(Lan.is_private_ipv4(ip), "sweep only hits private addresses (%s)" % ip)
		check(not mine.has(ip), "sweep skips this machine's own address")
		if _failed > 0:
			return


func test_crates_are_placed_sensibly() -> void:
	var total := 0
	for s in 200:
		var r = RoomGen.generate(s * 31 + 7)
		total += r.crates.size()
		for c: Vector2i in r.crates:
			check(r.solid[c.y * r.cols + c.x] == RoomGen.CRATE, "seed %d crate cell marked as crate" % s)
			check(c.y > RoomGen.SPAWN_ROWS, "seed %d crate off the spawn rows" % s)
			check(not r.enemy_cells.has(c), "seed %d no enemy inside a crate" % s)
		check(r.reachable_count(r.spawns[0]) == r.floor_count(), "seed %d still connected with crates" % s)
		if _failed > 0:
			return
	check(total > 200 * 4, "rooms get a fair number of crates (%d over 200 rooms)" % total)


## Endless: room 1 is easy, then enemies, gunmen and pace grow
## exponentially up to their caps, and rooms stay playable (connected,
## enemies spaced out and away from the spawn).
func test_endless_ramps_up_with_caps() -> void:
	check(RoomGen.endless_enemies(2, 0) <= 4, "room 1 has only a few enemies")
	check(RoomGen.endless_pace(0) < 0.8, "room 1 enemies are slow")
	check(RoomGen.endless_gunmen(0) <= 0.1, "room 1 has hardly any gunmen")
	check(RoomGen.endless_pace(99) == RoomGen.ENDLESS_MAX_PACE, "pace is capped")
	check(RoomGen.endless_gunmen(99) == RoomGen.ENDLESS_MAX_GUNMEN, "gunman share is capped")
	check(RoomGen.endless_enemies(4, 99) == RoomGen.ENDLESS_MAX_ENEMIES, "enemy count is capped")
	# Exponential: each room's increase is at least as big as the one before.
	for n in [2, 3, 4]:
		var step := 0.0
		for lvl in range(1, 7):
			var grow := RoomGen.endless_enemies(n, lvl) - RoomGen.endless_enemies(n, lvl - 1)
			check(grow >= step - 1.0 and grow >= 0, "%dp: enemies grow faster each room (level %d: +%d)" % [n, lvl, grow])
			step = grow
		var pace_step := 0.0
		for lvl in range(1, 9):
			var d := RoomGen.endless_pace(lvl) - RoomGen.endless_pace(lvl - 1)
			check(d > pace_step - 0.0001, "pace grows faster each room (level %d)" % lvl)
			pace_step = d
	# A normal (Random) room is untouched by the Endless curve.
	var plain = RoomGen.generate(4242, 2)
	check(plain.level == -1 and plain.pace == 1.0 and plain.enemy_cells.size() >= RoomGen.MIN_ENEMIES, "normal rooms unchanged")
	for n in [2, 3, 4]:
		var prev := 0.0
		for lvl in [0, 2, 4, 6, 8, 10, 14]:
			var total := 0
			var gunmen := 0
			for seed in 30:
				var r = RoomGen.generate(seed * 17 + lvl, n, lvl)
				total += r.enemy_cells.size()
				for k in r.enemy_kinds:
					gunmen += 1 if k == RoomGen.Kind.GUNMAN else 0
				check(r.reachable_count(r.spawns[0]) == r.floor_count(), "%dp level %d connected" % [n, lvl])
				check(r.pace == RoomGen.endless_pace(lvl), "%dp level %d pace set" % [n, lvl])
				for i in r.enemy_cells.size():
					var c: Vector2i = r.enemy_cells[i]
					check(Vector2(c).distance_to(r.spawn_center()) >= RoomGen.MIN_ENEMY_DIST, "%dp level %d enemy away from spawn" % [n, lvl])
					for j in range(i + 1, r.enemy_cells.size()):
						var d: Vector2i = r.enemy_cells[j] - c
						check(absi(d.x) > 1 or absi(d.y) > 1, "%dp level %d enemies not packed" % [n, lvl])
				if _failed > 0:
					return
			var avg := float(total) / 30.0
			print("  endless %dp room %2d: %4.1f enemies, %2.0f%% gunmen, pace %.2f" % [n, lvl + 1, avg,
				100.0 * gunmen / maxf(total, 1), RoomGen.endless_pace(lvl)])
			check(avg >= prev - 0.5, "%dp room %d: not fewer enemies than before (%.1f)" % [n, lvl + 1, avg])
			prev = avg


## The six hand-made maps: well formed, connected, fair at the start, and
## harder one after another.
func test_hand_made_maps() -> void:
	var prev_count := {2: 0, 3: 0, 4: 0}
	var prev_pace := 0.0
	var prev_gunmen := {2: -1, 3: -1, 4: -1}
	for id in Maps.ORDER:
		var m: Dictionary = Maps.ALL[id]
		var lines: Array = m["rows"]
		var w := str(lines[0]).length()
		for y in lines.size():
			var line := str(lines[y])
			check(line.length() == w, "%s row %d is %d wide, not %d" % [id, y, line.length(), w])
			check(line[0] == "#" and line[w - 1] == "#", "%s row %d has side walls" % [id, y])
			if y == 0 or y == lines.size() - 1:
				check(line == "#".repeat(w), "%s top/bottom row is all wall" % id)
		for d in ["1", "2", "3", "4"]:
			check("".join(lines).count(d) == 1, "%s has exactly one spawn %s" % [id, d])
		check(m["pace"] > prev_pace, "%s is faster than the map before" % id)
		prev_pace = m["pace"]
		for n in [2, 3, 4]:
			var r = Maps.build(id, n)
			check(r.spawns.size() == n, "%s %dp: one spawn each" % [id, n])
			check(r.reachable_count(r.spawns[0]) == r.floor_count(), "%s %dp: every floor cell reachable" % [id, n])
			var gunmen := 0
			for i in r.enemy_cells.size():
				var c: Vector2i = r.enemy_cells[i]
				check(not r.is_solid(c), "%s %dp: enemy %s on the floor" % [id, n, c])
				check(Vector2(c).distance_to(r.spawn_center()) >= 5.0, "%s %dp: enemy %s away from the spawn" % [id, n, c])
				if r.enemy_kinds[i] == RoomGen.Kind.GUNMAN:
					gunmen += 1
					# The easy maps never put a gunman in view of the spawn.
					if Maps.ORDER.find(id) < 3:
						for sp in r.spawns:
							check(not _wall_sight(r, c, sp), "%s %dp: gunman %s can't see spawn %s" % [id, n, c, sp])
			for sp in r.spawns:
				check(not r.is_solid(sp), "%s %dp: spawn %s is free" % [id, n, sp])
			check(r.enemy_cells.size() > prev_count[n], "%s %dp: more enemies (%d) than the map before" % [id, n, r.enemy_cells.size()])
			check(gunmen >= prev_gunmen[n], "%s %dp: at least as many gunmen (%d)" % [id, n, gunmen])
			if n == 2 or n == 4:
				print("  map %-10s %dp: %2d enemies (%2d gunmen), pace %.2f, %dx%d" % [id, n, r.enemy_cells.size(), gunmen, r.pace, r.cols, r.rows])
			prev_count[n] = r.enemy_cells.size()
			prev_gunmen[n] = gunmen


## True if a straight line between two cells crosses no full wall (crates are
## low, so they don't block a standing player).
func _wall_sight(r, a: Vector2i, b: Vector2i) -> bool:
	var from := Vector2(a) + Vector2(0.5, 0.5)
	var to := Vector2(b) + Vector2(0.5, 0.5)
	var steps := int(from.distance_to(to) * 8.0)
	for i in steps:
		var p := from.lerp(to, float(i) / steps)
		var c := Vector2i(floori(p.x), floori(p.y))
		if c != a and c != b and r.is_wall(c):
			return false
	return true


func test_rooms_scale_with_players() -> void:
	var prev_area := 0
	var prev_enemies := 0.0
	for n in [2, 3, 4]:
		var total_enemies := 0
		var area := 0
		for seed in 60:
			var r = RoomGen.generate(seed * 13 + n, n)
			area = r.cols * r.rows
			total_enemies += r.enemy_cells.size()
			check(r.spawns.size() == n, "%d players: one spawn each" % n)
			var seen := {}
			for sp in r.spawns:
				check(not r.is_solid(sp), "%d players: spawn %s is free" % [n, sp])
				check(not seen.has(sp), "%d players: spawns are distinct" % n)
				seen[sp] = true
			check(r.reachable_count(r.spawns[0]) == r.floor_count(), "%d players seed %d connected" % [n, seed])
			check(r.solid.size() == r.cols * r.rows, "%d players: grid matches size" % n)
			if _failed > 0:
				return
		var avg := float(total_enemies) / 60.0
		check(area > prev_area, "%d players: bigger room (%d cells)" % [n, area])
		check(avg > prev_enemies + 2.5, "%d players: more enemies (%.1f on average)" % [n, avg])
		prev_area = area
		prev_enemies = avg
	var a = RoomGen.generate(99, 4)
	var b = RoomGen.generate(99, 4)
	check(a.solid == b.solid and a.enemy_cells == b.enemy_cells, "4-player rooms are deterministic too")
