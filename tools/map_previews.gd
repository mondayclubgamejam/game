extends SceneTree
## Renders the match lobby's map pictures into assets/maps/<id>.png: each map
## from above, in the game's comic style, with its enemies in place. Re-run it
## after changing a map (needs a GPU / display, not --headless):
##   godot --path . --resolution 640x600 --script res://tools/map_previews.gd
## Random and Endless show a sample room (Endless a few rooms in).

const Maps := preload("res://scripts/maps.gd")
const OUT := "res://assets/maps"
const SIZE := Vector2i(320, 300)   ## same shape as a grid tile
const TILT := 58.0                 ## degrees below the horizon
const SETTINGS := "user://settings.cfg"

func _initialize() -> void:
	# Rendering Endless records a "best room"; put the player's settings back after.
	var saved: PackedByteArray = FileAccess.get_file_as_bytes(SETTINGS) if FileAccess.file_exists(SETTINGS) else PackedByteArray()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	change_scene_to_file("res://scenes/main.tscn")
	await create_timer(1.0).timeout
	var main = current_scene
	# From above, the pale rooms and the low sun clip to white: darken for the pictures.
	for env in main.find_children("*", "WorldEnvironment", true, false):
		env.environment.tonemap_exposure = 0.5
	for sun in main.find_children("*", "DirectionalLight3D", true, false):
		sun.light_energy *= 0.45
		sun.rotation_degrees = Vector3(-62, -30, 0)
	var team := [[1, 0, "A"], [2, 1, "B"]]
	var jobs := [["random", 20240, 1, "random"], ["endless", 31337, 7, "endless"], ["tutorial", 1, 2, "tutorial_b"]]
	for id in Maps.ORDER:
		jobs.append([id, 1, 1, id])
	for job in jobs:
		main.start_round(job[1], job[2], 1, team, job[3])
		main.hud.visible = false
		main.hand.visible = false
		main.lobby.visible = false
		await create_timer(0.4).timeout
		# Look in from above: no ceiling.
		for n in ["Ceiling", "CeilingPanels"]:
			var c: Node = main.round_root.find_child(n, true, false)
			if c != null:
				c.visible = false
		var r = main.room
		var cam := Camera3D.new()
		main.add_child(cam)
		cam.fov = 34.0
		var w: float = r.cols * 2.0
		var d: float = r.rows * 2.0
		var a := deg_to_rad(TILT)
		var center := Vector3(w * 0.5, 0.0, d * 0.5)
		var dir := Vector3(0, sin(a), cos(a))
		cam.make_current()
		# Move in until a corner of the room (walls included) would leave the frame.
		var corners: Array[Vector3] = []
		for x in [0.0, w]:
			for z in [0.0, d]:
				for y in [0.0, 3.0]:
					corners.append(Vector3(x, y, z))
		var dist := 200.0
		while dist > 5.0:
			var next := dist * 0.98
			cam.position = center + dir * next
			cam.look_at(center)
			var fits := true
			var view := cam.get_viewport().get_visible_rect().size  # projection space
			var margin := view * 0.02
			for c in corners:
				var p := cam.unproject_position(c)
				if p.x < margin.x or p.y < margin.y or p.x > view.x - margin.x or p.y > view.y - margin.y:
					fits = false
			if not fits:
				break
			dist = next
		cam.position = center + dir * dist
		cam.look_at(center)
		cam.far = dist * 3.0
		await create_timer(0.3).timeout
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		img.resize(SIZE.x, SIZE.y, Image.INTERPOLATE_LANCZOS)
		img.save_png(ProjectSettings.globalize_path("%s/%s.png" % [OUT, job[0]]))
		print("saved ", job[0])
		cam.queue_free()
	if saved.is_empty():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS))
	else:
		var f := FileAccess.open(SETTINGS, FileAccess.WRITE)
		f.store_buffer(saved)
		f.close()
	quit()
