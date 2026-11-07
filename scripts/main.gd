extends Node3D
## Builds the whole MVP in code: input map, environment, comic post-process,
## level, player, 3D hand-and-gun viewmodel and HUD. Handles door, restart and next level.

const LevelBuilder := preload("res://scripts/level_builder.gd")
const Player := preload("res://scripts/player.gd")
const Viewmodel := preload("res://scripts/viewmodel.gd")
const Hud := preload("res://scripts/hud.gd")
const PostShader := preload("res://shaders/comic_post.gdshader")
const ScreenshotDirector := preload("res://scripts/screenshot_director.gd")

const LEVELS := [
	{
		"name": "FIRE AND RETURN",
		"facing": -90.0,
		"map": [
			"###############",
			"#....C........#",
			"#..A.G.....P..#",
			"#.........E...#",
			"#......P......#",
			"#CC.......E...#",
			"#C..........P.#",
			"#######D#######",
		],
	},
	{
		"name": "TWO FOR ONE",
		"facing": 0.0,
		"map": [
			"###############",
			"#.............#",
			"#..E.......E..#",
			"#.............#",
			"#.....###.....#",
			"#.A.G.###...B.#",
			"#.............#",
			"#..E.......E..#",
			"#######D#######",
		],
	},
	{
		"name": "AROUND THE SHIELD",
		"facing": -90.0,
		"map": [
			"###############",
			"#......#......#",
			"#..A...#..S...#",
			"#..G...#......#",
			"#......d......#",
			"#..B...#......#",
			"#......#......#",
			"#######D#######",
		],
	},
]

const KILL_WORDS := ["", "DOWN!", "DOUBLE!", "TRIPLE!", "QUAD!"]

## Survives scene reloads, so restart keeps the level and the exit advances it.
static var level_index := 0

var player: Player
var hand: Viewmodel
var hud: Hud
var _doors: Array = []
var _exit_z := 0.0
var _enemies_left := 0
var _cleared := false
var _leaving := false


func _ready() -> void:
	_setup_input()
	_build_environment()
	_build_post_process()

	var level: Dictionary = LEVELS[level_index]
	var built := LevelBuilder.build(self, level["map"])
	_doors = built["doors"]
	_exit_z = built["exit_z"]
	_enemies_left = built["enemies"].size()
	for e in built["enemies"]:
		e.died.connect(_on_enemy_died)

	player = Player.new()
	add_child(player)
	player.global_position = built["spawn"] + Vector3(0, 0.1, 0)
	player.rotation.y = deg_to_rad(level["facing"])

	var ui := CanvasLayer.new()
	ui.name = "UI"
	add_child(ui)
	hand = Viewmodel.new()
	hand.player = player
	player.camera.add_child(hand)
	player.muzzle_node = hand.muzzle
	hud = Hud.new()
	ui.add_child(hud)
	hud.targets = _enemies_left

	player.state_changed.connect(hud.set_state)
	player.fired.connect(hand.play_fire)
	player.recalled.connect(hand.play_recall)
	player.recall_blocked.connect(_on_recall_blocked)
	player.shot_finished.connect(_on_shot_finished)

	hud.cutin("%d  %s" % [level_index + 1, level["name"]], LevelBuilder.DOOR_COLOR)

	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shots="):
			var director := ScreenshotDirector.new()
			director.out_dir = ProjectSettings.globalize_path("res://").path_join(arg.trim_prefix("--shots="))
			director.player = player
			add_child(director)


func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("restart"):
		get_tree().reload_current_scene()
		return
	if _cleared and not _leaving and player.global_position.z > _exit_z:
		_leaving = true
		level_index = (level_index + 1) % LEVELS.size()
		get_tree().reload_current_scene()


func _on_enemy_died() -> void:
	_enemies_left -= 1
	hud.targets = _enemies_left
	if _enemies_left <= 0 and not _cleared:
		_cleared = true
		# Let the kill banner show first.
		get_tree().create_timer(0.3).timeout.connect(_open_doors)


func _open_doors() -> void:
	hud.cutin("CLEAR!", Hud.MAGENTA)
	for door in _doors:
		var tw := create_tween()
		tw.tween_property(door, "position:y", door.position.y + LevelBuilder.WALL_H + 0.1, 0.8) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)


func _on_shot_finished(kills: int, was_recall: bool) -> void:
	if kills <= 0:
		return
	var word: String = KILL_WORDS[mini(kills, KILL_WORDS.size() - 1)]
	hud.cutin(word, Hud.BLUE if was_recall else Hud.ORANGE)


func _on_recall_blocked() -> void:
	hand.play_blocked()
	hud.cutin("BLOCKED!", Hud.RED)


func _setup_input() -> void:
	_add_action("move_forward", [KEY_UP])
	_add_action("move_back", [KEY_DOWN])
	_add_action("turn_left", [KEY_LEFT])
	_add_action("turn_right", [KEY_RIGHT])
	_add_action("strafe_left", [KEY_A])
	_add_action("strafe_right", [KEY_D])
	_add_action("run", [KEY_SHIFT])
	_add_action("fire", [KEY_SPACE])
	_add_action("restart", [KEY_R])


func _add_action(action: String, keys: Array) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	for key in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = key
		InputMap.action_add_event(action, ev)


func _build_environment() -> void:
	# Enclosed room: no sky or sun. Light comes from ceiling panels and neon.
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("07060b")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("3a3560")
	env.ambient_light_energy = 0.5
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.9
	env.glow_bloom = 0.05
	env.glow_hdr_threshold = 0.9
	# Wet floor reflections and a light haze that catches the lights.
	env.ssr_enabled = true
	env.ssr_max_steps = 64
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.02
	env.volumetric_fog_albedo = Color("8f86c8")

	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)


func _build_post_process() -> void:
	var quad := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2(2, 2)
	quad.mesh = mesh
	var mat := ShaderMaterial.new()
	mat.shader = PostShader
	mat.render_priority = Material.RENDER_PRIORITY_MIN
	quad.material_override = mat
	# Lighter halftone for a dark scene: dots only in the deep shadows.
	mat.set_shader_parameter("halftone_start", 0.32)
	mat.set_shader_parameter("halftone_strength", 0.35)
	mat.set_shader_parameter("posterize_levels", 255.0)  # off: it bands light falloff
	quad.custom_aabb = AABB(Vector3(-10000, -10000, -10000), Vector3(20000, 20000, 20000))
	quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(quad)
