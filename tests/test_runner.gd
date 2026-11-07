extends SceneTree
## Headless logic tests. Run with:
##   godot --headless --path . --script res://tests/test_runner.gd

const RoomGen := preload("res://scripts/room_gen.gd")
const Traj := preload("res://scripts/trajectory.gd")
const Lan := preload("res://scripts/lan_discovery.gd")

var _failed := 0
var _passed := 0


func _initialize() -> void:
	test_room_is_deterministic()
	test_crates_are_placed_sensibly()
	test_rooms_scale_with_players()
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
