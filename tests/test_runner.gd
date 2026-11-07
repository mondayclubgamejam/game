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
	test_rooms_are_connected_and_populated()
	test_different_seeds_differ()
	test_merged_boxes_cover_exactly_the_walls()
	test_recall_curve_starts_backwards_and_ends_at_gun()
	test_throw_reaches_target()
	test_lan_beacon_round_trip()
	test_lan_beacon_rejects_foreign_packets()
	test_lan_broadcast_targets()
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
		check(r.reachable_count(r.spawn_a) == r.floor_count(), "seed %d fully connected" % s)
		check(not r.is_solid(r.spawn_a) and not r.is_solid(r.spawn_b), "seed %d spawns free" % s)
		check(r.enemy_cells.size() >= RoomGen.MIN_ENEMIES, "seed %d has >= %d enemies (got %d)"
			% [s, RoomGen.MIN_ENEMIES, r.enemy_cells.size()])
		check(r.enemy_cells.size() == r.enemy_kinds.size(), "seed %d kinds match cells" % s)
		var mid := Vector2(r.spawn_a + r.spawn_b) * 0.5
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
		cover.resize(RoomGen.W * RoomGen.H)
		var overlap := false
		for b: Rect2i in r.boxes:
			for y in range(b.position.y, b.end.y):
				for x in range(b.position.x, b.end.x):
					if cover[y * RoomGen.W + x] == 1:
						overlap = true
					cover[y * RoomGen.W + x] = 1
		check(cover == r.solid, "seed %d boxes cover walls exactly" % s)
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
	var info := Lan.decode(Lan.encode(7777, "NESTOR"))
	check(info.get("port") == 7777, "beacon keeps the port")
	check(info.get("name") == "NESTOR", "beacon keeps the name")
	check(Lan.decode(Lan.encode(7777, "N", 42)).get("id") == 42, "beacon keeps the session id")
	var long_name := Lan.decode(Lan.encode(7777, "X".repeat(100)))
	check(str(long_name.get("name")).length() == 32, "beacon names are capped")


func test_lan_beacon_rejects_foreign_packets() -> void:
	check(Lan.decode("hello".to_utf8_buffer()).is_empty(), "plain text ignored")
	check(Lan.decode(JSON.stringify({"g": "OTHER", "port": 7777}).to_utf8_buffer()).is_empty(), "other games ignored")
	check(Lan.decode(JSON.stringify({"g": Lan.MAGIC, "port": 0}).to_utf8_buffer()).is_empty(), "bad port ignored")
	check(Lan.decode(JSON.stringify({"g": Lan.MAGIC, "port": 70000}).to_utf8_buffer()).is_empty(), "port out of range ignored")
	var big := PackedByteArray()
	big.resize(4096)
	check(Lan.decode(big).is_empty(), "oversized packet ignored")


func test_lan_broadcast_targets() -> void:
	var targets := Lan.broadcast_targets()
	check(targets.has("255.255.255.255"), "always broadcasts to 255.255.255.255")
	check(targets.has("127.0.0.1"), "also beacons to this machine")
	for t in targets:
		if t != "127.0.0.1":
			check(t.ends_with(".255"), "broadcast target %s ends in .255" % t)
			check(not t.begins_with("127."), "no loopback broadcast")
