extends Node3D
## Sky, light and the comic post-process quad. Also owns the screen-wide
## effects gameplay triggers (kill punch, slow-motion look).

const Palette := preload("res://scripts/palette.gd")
const ComicShader := preload("res://shaders/comic.gdshader")

var _post: ShaderMaterial
var _punch := 0.0
var _slowmo := 0.0


func _ready() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Palette.SKY_TOP
	sky_mat.sky_horizon_color = Palette.SKY_HORIZON
	sky_mat.ground_horizon_color = Palette.SKY_HORIZON
	sky_mat.ground_bottom_color = Palette.SKY_TOP
	sky_mat.sun_angle_max = 0.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.process_mode = Sky.PROCESS_MODE_QUALITY  # sky is static: render once

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("b9a6d9")
	env.ambient_light_energy = 0.45
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_hdr_threshold = 1.6
	if not Palette.COMIC:
		env.ssao_enabled = true  # soft contact shadows where there are no ink lines
		env.ssao_intensity = 1.6
		# Rooms are enclosed now: a bright, near-white fill so the shade isn't gloomy.
		env.ambient_light_color = Color("e9e4f2")
		env.ambient_light_energy = 0.32
		env.tonemap_mode = Environment.TONE_MAPPER_FILMIC  # bright sun patches roll off instead of clipping
		env.tonemap_exposure = 1.15
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	# Low and from +Z, so it comes in through the window wall (room_builder.gd)
	# and lays long bright shafts across the floor.
	sun.rotation_degrees = Vector3(-30, -25, 0)
	sun.light_energy = 0.85 if Palette.COMIC else 3.6
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_max_distance = 60.0
	if not Palette.COMIC:
		# The halftone used to hide shadow pixels; filter them instead.
		RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM)
		RenderingServer.directional_shadow_atlas_set_size(4096, true)
		sun.shadow_blur = 1.5
	add_child(sun)

	_post = ShaderMaterial.new()
	_post.shader = ComicShader
	_post.render_priority = Material.RENDER_PRIORITY_MIN
	_post.set_shader_parameter("comic", 1.0 if Palette.COMIC else 0.0)
	var quad_mesh := QuadMesh.new()
	quad_mesh.size = Vector2(2, 2)
	var quad := MeshInstance3D.new()
	quad.mesh = quad_mesh
	quad.material_override = _post
	quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	quad.extra_cull_margin = 16384.0  # never frustum-culled
	add_child(quad)
	set_process(false)


## 0 = normal time, 1 = full slow motion. Called every physics tick.
func set_slowmo(amount: float) -> void:
	if absf(amount - _slowmo) > 0.002:
		_slowmo = amount
		_post.set_shader_parameter("slowmo", amount)


func punch() -> void:
	_punch = 1.0
	set_process(true)


func _process(delta: float) -> void:
	_punch = move_toward(_punch, 0.0, delta * 8.0)
	_post.set_shader_parameter("punch", _punch)
	if _punch <= 0.0:
		set_process(false)
