extends Node3D
## Builds the whole MVP in code: input map, environment, comic post-process,
## level, two split-screen players with 3D hand-and-gun viewmodels and HUDs,
## and the one shared bullet. Handles door, restart and next level.

const LevelBuilder := preload("res://scripts/level_builder.gd")
const Player := preload("res://scripts/player.gd")
const Enemy := preload("res://scripts/enemy.gd")
const Viewmodel := preload("res://scripts/viewmodel.gd")
const Bullet := preload("res://scripts/bullet.gd")
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
			"#CC.B.....I...#",
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
			"#..E.......I..#",
			"#.............#",
			"#.....###.....#",
			"#.A.G.###...B.#",
			"#.............#",
			"#..I.......E..#",
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

const A_ACCENT := Color(1.0, 0.48, 0.1)
const B_ACCENT := Color(0.18, 0.66, 1.0)
const ALL_LAYERS := 0xFFFFF
# Render layers (bit values): own body hidden from own camera, own hand only
# visible to own camera.
const A_BODY := 2
const B_BODY := 4
const A_HAND := 8
const B_HAND := 16

var players: Array = []  ## [A, B]
var hands: Array = []
var huds: Array = []
var bullet: Bullet
var _doors: Array = []
var _exit_z := 0.0
var _enemies_left := 0
var _cleared := false
var _leaving := false
var _caught := false


func _ready() -> void:
	_setup_input()
	_build_environment()
	_build_post_process()

	var level: Dictionary = LEVELS[level_index]
	var built := LevelBuilder.build(self, level["map"])
	_doors = built["doors"]
	_exit_z = built["exit_z"]
	_enemies_left = built["enemies"].size()
	Enemy.paused = false
	for e in built["enemies"]:
		e.died.connect(_on_enemy_died)
		e.reached_player.connect(_on_caught)

	bullet = Bullet.new()
	add_child(bullet)

	# Split screen: A on the left, B on the right, both looking into one world.
	var screens := HBoxContainer.new()
	screens.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screens.add_theme_constant_override("separation", 4)
	var screen_layer := CanvasLayer.new()
	add_child(screen_layer)
	screen_layer.add_child(screens)

	for i in 2:
		var is_a := i == 0
		var container := SubViewportContainer.new()
		container.stretch = true
		container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		container.size_flags_vertical = Control.SIZE_EXPAND_FILL
		screens.add_child(container)
		var vp := SubViewport.new()
		container.add_child(vp)
		var cam := Camera3D.new()
		cam.fov = 75.0
		cam.near = 0.05
		cam.cull_mask = ALL_LAYERS & ~((A_BODY | B_HAND) if is_a else (B_BODY | A_HAND))
		vp.add_child(cam)
		cam.current = true

		var p := Player.new()
		p.role = "A" if is_a else "B"
		p.actions = "p1_" if is_a else "p2_"
		p.gun = bullet
		p.camera = cam
		p.body_layer = A_BODY if is_a else B_BODY
		p.accent = A_ACCENT if is_a else B_ACCENT
		add_child(p)
		var spawn: Vector3 = built["spawn"] if is_a else built["spawn_b"]
		p.global_position = spawn + Vector3(0, 0.1, 0)
		p.rotation.y = deg_to_rad(level["facing"])

		var vm := Viewmodel.new()
		vm.player = p
		vm.accent = p.accent
		vm.layer_mask = A_HAND if is_a else B_HAND
		cam.add_child(vm)
		p.muzzle_node = vm.muzzle

		var ui := CanvasLayer.new()
		vp.add_child(ui)
		var hud := Hud.new()
		hud.role = p.role
		hud.role_color = p.accent
		hud.role_text = "A  FORWARD" if is_a else "B  INVERTED"
		hud.hint = "W S move   A D turn   SPACE fire   R restart" if is_a \
			else "UP DOWN move   LEFT RIGHT turn   ENTER recall"
		ui.add_child(hud)
		hud.targets = _enemies_left
		hud.set_state(Bullet.LOADED)

		players.append(p)
		hands.append(vm)
		huds.append(hud)

	bullet.shooter = players[0]
	bullet.recaller = players[1]
	for hud in huds:
		bullet.state_changed.connect(hud.set_state)
	bullet.fired.connect(func():
		hands[0].play_fire()
		players[0].shake(1.0))
	bullet.relayed.connect(func():
		hands[1].play_recall()
		players[1].shake(0.6))
	bullet.returned.connect(func():
		hands[0].play_recall()
		players[0].shake(0.7))
	bullet.recall_blocked.connect(_on_recall_blocked)
	bullet.shot_finished.connect(_on_shot_finished)

	_cutin_all("%d  %s" % [level_index + 1, level["name"]], LevelBuilder.DOOR_COLOR)

	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shots="):
			var director := ScreenshotDirector.new()
			director.out_dir = ProjectSettings.globalize_path("res://").path_join(arg.trim_prefix("--shots="))
			director.players = players
			director.bullet = bullet
			add_child(director)


func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("restart"):
		get_tree().reload_current_scene()
		return
	# Both players have to walk out through the open door.
	if _cleared and not _leaving and players.all(func(p): return p.global_position.z > _exit_z):
		_leaving = true
		level_index = (level_index + 1) % LEVELS.size()
		get_tree().reload_current_scene()


func _cutin_all(text: String, color: Color) -> void:
	for hud in huds:
		hud.cutin(text, color)


func _on_enemy_died() -> void:
	_enemies_left -= 1
	for hud in huds:
		hud.targets = _enemies_left
	if _enemies_left <= 0 and not _cleared:
		_cleared = true
		# Let the kill banner show first.
		get_tree().create_timer(0.3).timeout.connect(_open_doors)


func _open_doors() -> void:
	_cutin_all("CLEAR!", Hud.MAGENTA)
	for door in _doors:
		var tw := create_tween()
		tw.tween_property(door, "position:y", door.position.y + LevelBuilder.WALL_H + 0.1, 0.8) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)


func _on_shot_finished(kills: int, was_recall: bool) -> void:
	if kills <= 0:
		return
	var word: String = KILL_WORDS[mini(kills, KILL_WORDS.size() - 1)]
	_cutin_all(word, Hud.BLUE if was_recall else Hud.ORANGE)


func _on_caught() -> void:
	if _caught or _cleared:
		return
	_caught = true
	Enemy.paused = true
	_cutin_all("CAUGHT!", Hud.RED)
	get_tree().create_timer(1.2).timeout.connect(get_tree().reload_current_scene)


func _on_recall_blocked() -> void:
	hands[1].play_blocked()
	_cutin_all("BLOCKED!", Hud.RED)


func _setup_input() -> void:
	# Player A: WASD + Space. Player B: arrows + Enter.
	_add_action("p1_forward", [KEY_W])
	_add_action("p1_back", [KEY_S])
	_add_action("p1_left", [KEY_A])
	_add_action("p1_right", [KEY_D])
	_add_action("p1_act", [KEY_SPACE])
	_add_action("p2_forward", [KEY_UP])
	_add_action("p2_back", [KEY_DOWN])
	_add_action("p2_left", [KEY_LEFT])
	_add_action("p2_right", [KEY_RIGHT])
	_add_action("p2_act", [KEY_ENTER, KEY_KP_ENTER])
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
