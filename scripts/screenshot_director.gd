extends Node
## Plays a scripted run of Level 1 and saves screenshots, then quits.
## Usage: godot --path . -- --shots=game-style/screenshots

var out_dir := ""
var player: Node3D


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)
	_run.call_deferred()


func _run() -> void:
	var enemies := get_tree().get_nodes_in_group("enemies")
	enemies.sort_custom(func(a, b): return a.global_position.z < b.global_position.z)
	var top: Node3D = enemies[0]
	var bottom: Node3D = enemies[1]

	await _wait(0.35)
	await _shot("01_level_intro")

	_face(top.global_position)
	await _wait(1.2)
	await _shot("02_aim_line")

	player._fire()
	await _wait(0.07)
	await _shot("03_fire_flash")
	await _wait(0.35)
	await _shot("04_kill_banner")
	await _wait(1.0)

	# Stand where the bullet's way home passes through the second enemy.
	var lodge: Vector3 = player.lodge_pos
	var through := bottom.global_position
	var away := Vector3(through.x - lodge.x, 0, through.z - lodge.z)
	var spot := Vector3(lodge.x, 0, lodge.z) + away * 1.6
	player.global_position = Vector3(spot.x, 0.1, spot.z)
	_face(lodge)
	await _wait(0.6)
	await _shot("05_recall_line")

	player._recall()
	await _wait(0.06)
	await _shot("06_recall_incoming")
	await _wait(0.2)
	await _shot("07_recall_yank")
	await _wait(1.2)
	await _shot("08_clear_door")

	await _overview()
	get_tree().quit()


func _overview() -> void:
	var cam := Camera3D.new()
	get_parent().add_child(cam)
	cam.global_position = Vector3(14, 26, 30)
	cam.look_at(Vector3(14, 0, 7), Vector3.UP)
	cam.fov = 55
	cam.current = true
	var ui := get_parent().get_node_or_null("UI") as CanvasLayer
	if ui:
		ui.visible = false
	await _wait(0.4)
	await _shot("09_level_overview")


func _face(target: Vector3) -> void:
	var d := target - player.global_position
	player.rotation.y = atan2(-d.x, -d.z)


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := out_dir.path_join(name + ".png")
	img.save_png(path)
	print("saved ", path)
