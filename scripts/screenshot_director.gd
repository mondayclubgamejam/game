extends Node
## Plays a scripted two-player run of Level 1 and saves screenshots, then quits.
## Usage: godot --path . -- --shots=game-style/screenshots

const Enemy := preload("res://scripts/enemy.gd")

var out_dir := ""
var players: Array = []  ## [A, B]
var bullet: Node


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)
	_run.call_deferred()


func _run() -> void:
	var a: Node3D = players[0]
	var b: Node3D = players[1]
	var enemies := get_tree().get_nodes_in_group("enemies")
	enemies.sort_custom(func(x, y): return x.global_position.z < y.global_position.z)
	var top: Node3D = enemies[0]     # forward (orange): the shot kills it
	var bottom: Node3D = enemies[1]  # inverted (blue): the recall kills it

	# Freeze enemies so the scripted shots line up.
	Enemy.paused = true
	await _wait(0.35)
	await _shot("01_level_intro")

	# Close-up of both enemy types from A's view, aimed past them.
	var a_pos := a.global_position
	var a_rot := a.rotation
	var close := top.global_position + Vector3(-3.6, 0, 0.9)
	a.global_position = Vector3(close.x, 0.1, close.z)
	_face(a, top.global_position + Vector3(0, 0, 1.1))
	await _wait(1.3)
	await _shot("00_enemy_closeup")
	a.global_position = a_pos
	a.rotation = a_rot

	# A aims through the forward enemy and fires.
	_face(a, top.global_position)
	await _wait(0.8)
	await _shot("02_aim_line")
	bullet.try_fire()
	await _wait(0.07)
	await _shot("03_fire_flash")
	await _wait(0.4)
	await _shot("04_kill_banner")
	await _wait(0.8)

	# B stands where the wall -> B leg passes through the inverted enemy.
	var lodge: Vector3 = bullet.lodge_pos
	var through := bottom.global_position
	var away := Vector3(through.x - lodge.x, 0, through.z - lodge.z)
	var spot := Vector3(lodge.x, 0, lodge.z) + away * 1.6
	b.global_position = Vector3(spot.x, 0.1, spot.z)
	_face(b, lodge)
	_face(a, b.global_position)
	await _wait(0.6)
	await _shot("05_recall_lines")

	bullet.try_recall()
	await _wait(0.08)
	await _shot("06_recall_incoming")
	while bullet.state != 0:  # wait until it is back in A's gun
		await get_tree().physics_frame
	await _wait(0.05)
	await _shot("07_returned")
	await _wait(1.2)
	await _shot("08_clear_door")
	get_tree().quit()


func _face(p: Node3D, target: Vector3) -> void:
	var d := target - p.global_position
	p.rotation.y = atan2(-d.x, -d.z)


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := out_dir.path_join(name + ".png")
	img.save_png(path)
	print("saved ", path)
