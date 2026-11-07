extends Node3D
## The one gun. Held, flying or on the floor. Flight is a fixed-step ballistic
## arc against static walls, so every peer simulates the same throw from just
## the start position and velocity.

const Palette := preload("res://scripts/palette.gd")
const Traj := preload("res://scripts/trajectory.gd")
const PulseShader := preload("res://shaders/pulse.gdshader")

enum { HELD, FLYING, GROUND }

const MASK := 1 | 16         ## world + the tall invisible rim that keeps it in the room
const STEP := 1.0 / 60.0

var state := HELD
var holder: Node3D = null
var thrower: Node3D = null
var loaded := true
var since_throw := 0.0
var since_land := 0.0

var _vel := Vector3.ZERO
var _model: Node3D
var _chamber: MeshInstance3D
var _pulse: MeshInstance3D
var _query := PhysicsRayQueryParameters3D.new()
var _spin := 0.0


func _ready() -> void:
	top_level = true
	_query.collision_mask = MASK
	_model = Node3D.new()
	add_child(_model)
	var frame := BoxMesh.new()
	frame.size = Vector3(0.09, 0.13, 0.42)
	_part(frame, Vector3(0, 0.03, -0.05), Palette.toon(Palette.STEEL))
	var grip := BoxMesh.new()
	grip.size = Vector3(0.08, 0.2, 0.1)
	_part(grip, Vector3(0, -0.11, 0.08), Palette.toon(Palette.INK))
	var chamber := BoxMesh.new()
	chamber.size = Vector3(0.1, 0.06, 0.12)
	_chamber = _part(chamber, Vector3(0, 0.1, -0.02), Palette.glow(Palette.FORWARD, 3.0))

	var quad := QuadMesh.new()
	quad.size = Vector2(1.4, 1.4)
	var pulse_mat := ShaderMaterial.new()
	pulse_mat.shader = PulseShader
	pulse_mat.set_shader_parameter("color", Palette.SIGNAL)
	_pulse = MeshInstance3D.new()
	_pulse.mesh = quad
	_pulse.material_override = pulse_mat
	_pulse.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_pulse.visible = false
	add_child(_pulse)
	_refresh_visual()


func _part(mesh: Mesh, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = mat
	_model.add_child(mi)
	return mi


func hold(p: Node3D) -> void:
	state = HELD
	holder = p
	_vel = Vector3.ZERO
	_refresh_visual()


func throw(from: Vector3, vel: Vector3, by: Node3D, fast_forward: float) -> void:
	state = FLYING
	holder = null
	thrower = by
	since_throw = 0.0
	global_position = from
	_vel = vel
	_refresh_visual()
	var t := fast_forward
	while t >= STEP and state == FLYING:
		_step(STEP)
		t -= STEP


func set_loaded(value: bool) -> void:
	loaded = value
	_refresh_visual()


func _refresh_visual() -> void:
	# The local holder sees the gun on the 2D hand overlay instead.
	visible = not (state == HELD and (holder == null or holder.is_local))
	_pulse.visible = state == GROUND
	_chamber.material_override = Palette.glow(Palette.FORWARD if loaded else Palette.MUTED, 3.0)


func _physics_process(delta: float) -> void:
	match state:
		FLYING:
			_step(delta)
		GROUND:
			since_land += delta
		HELD:
			if holder != null and not holder.is_local:
				global_transform = holder.hand_anchor.global_transform


func _step(delta: float) -> void:
	since_throw += delta
	_vel.y -= Traj.GUN_GRAVITY * delta
	var from := global_position
	var to := from + _vel * delta
	_query.from = from
	_query.to = to
	var hit := get_world_3d().direct_space_state.intersect_ray(_query)
	if hit.is_empty():
		global_position = to
	else:
		var n: Vector3 = hit["normal"]
		if n.y > 0.6:
			state = GROUND
			since_land = 0.0
			global_position = hit["position"] + Vector3.UP * 0.12
			rotation = Vector3(0, rotation.y, PI / 2.0)
			_refresh_visual()
			return
		global_position = hit["position"] + n * 0.05
		_vel = _vel.bounce(n) * 0.45
	_spin += delta * 14.0
	rotation = Vector3(_spin, _spin * 0.4, 0)
