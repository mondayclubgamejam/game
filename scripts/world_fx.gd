extends Node3D
## Sky, light and the screen effects gameplay triggers (kill punch,
## slow-motion look). With the comic look on, a full-screen post-process quad
## draws them; with it off, slow motion drains colour through the
## environment's saturation and a 2D overlay draws the vignette and flash, so
## no full-screen pass reads the screen.

const Palette := preload("res://scripts/palette.gd")
const ComicShader := preload("res://shaders/comic.gdshader")
const ScreenFxShader := preload("res://shaders/screen_fx.gdshader")

var _post: ShaderMaterial      ## the comic quad's, or the overlay's
var _env: Environment
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
	sky.radiance_size = Sky.RADIANCE_SIZE_32  # matte surfaces: tiny reflections save ~36 MB of video memory
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
		RenderingServer.directional_shadow_atlas_set_size(2048, true)  # 4096 cost 24 MB more for little gain
		sun.shadow_blur = 1.5
	add_child(sun)

	_env = env
	_post = ShaderMaterial.new()
	if not Palette.COMIC:
		_post.shader = ScreenFxShader
		var layer := CanvasLayer.new()
		layer.layer = 0  # under the HUD and menus
		add_child(layer)
		var overlay := ColorRect.new()
		overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		overlay.material = _post
		layer.add_child(overlay)
		set_process(false)
		return
	_post.shader = ComicShader
	_post.render_priority = Material.RENDER_PRIORITY_MIN
	_post.set_shader_parameter("comic", 1.0)
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
		if not Palette.COMIC:
			_env.adjustment_enabled = amount > 0.001
			_env.adjustment_saturation = 1.0 - 0.6 * amount


func punch() -> void:
	_punch = 1.0
	set_process(true)


func _process(delta: float) -> void:
	_punch = move_toward(_punch, 0.0, delta * 8.0)
	_post.set_shader_parameter("punch", _punch)
	if _punch <= 0.0:
		set_process(false)
