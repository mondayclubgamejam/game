extends Node3D
## An enemy's body, weapons and procedural animation, on every peer.
##
## Each frame builds a target pose (bone -> body-space euler) from layers:
## the stance for the enemy's weapon, walking, breathing, and the current
## attack phase. The shown pose eases toward it, fast for strikes and slower
## for wind-ups and recovery, so every move has anticipation and follow-through.
##
##   gunman: low ready -> raises the pistol two-handed and aims -> recoil and
##           muzzle flash -> brings the gun in to reload -> low ready
##   sword:  guard with the blade up -> lifts it high behind the head ->
##           a diagonal slash with a lunge and a white trail -> guard
##   knives: crouched, a knife in each hand -> draws both back -> double stab
##           lunge -> crouch
## Everything runs on game time (Clock.scale), so slow motion slows it too.

const Palette := preload("res://scripts/palette.gd")
const Mannequin := preload("res://scripts/mannequin.gd")
const Models := preload("res://scripts/models.gd")
const Clock := preload("res://scripts/clock.gd")

enum { GUNMAN, SWORD, KNIVES }
enum { IDLE, WINDUP, STRIKE, RECOVER, RELOAD }

const STRIKE_TIME := 0.11
const RECOVER_TIME := [0.25, 0.4, 0.35]
const RELOAD_TIME := 1.1
## How fast the shown pose catches up with the target pose, by phase.
const RATE := {IDLE: 9.0, WINDUP: 11.0, STRIKE: 45.0, RECOVER: 8.0, RELOAD: 9.0}
const LUNGE := [0.0, 0.45, 0.55]          ## how far the body springs forward on a strike (m)
const PISTOL_SCALE := 1.35
const PISTOL_MUZZLE := Vector3(0, 0.078, -0.17)
const SWORD_TIP := -1.01
const SWORD_BASE := -0.2
const KNIFE_SCALE := 1.3
const TRAIL_POINTS := 10
const FAR_SQ := 14.0 * 14.0       ## beyond this, idle poses update every other frame

static var _flash_mesh: Mesh
static var _flash_mat: Material
static var _trail_mat: Material
static var _skin_cache := {}

var kind := 0
var tint_parts: Array[MeshInstance3D] = []   ## flash white on wind-up, yellow when targeted
var man: Mannequin = null
var _base_mat: Material

var _state := IDLE
var _state_t := 0.0
var _state_len := 0.0
## The bones the animation drives, and their indices into the arrays below.
const BONES := ["thigh_l", "thigh_r", "shin_l", "shin_r", "foot_l", "foot_r", "spine", "chest", "neck",
	"head", "upperarm_l", "forearm_l", "hand_l", "upperarm_r", "forearm_r", "hand_r"]
enum { THIGH_L, THIGH_R, SHIN_L, SHIN_R, FOOT_L, FOOT_R, SPINE, CHEST, NECK, HEAD,
	UPPERARM_L, FOREARM_L, HAND_L, UPPERARM_R, FOREARM_R, HAND_R }

var _shown := PackedVector3Array()    ## euler per bone currently shown
var _target := PackedVector3Array()   ## euler per bone to move toward (reused every frame)
var _applied := PackedVector3Array()  ## euler last written to the skeleton
var _bone_ids := PackedInt32Array()
var _rest_a: Array[Quaternion] = []   ## per bone: rest * global_rest^-1
var _rest_b: Array[Quaternion] = []   ## per bone: global_rest
var _lunge := 0.0         ## shown forward offset of the whole body
var _drop := 0.0          ## shown crouch (hips down)
var _walk_phase := 0.0
var _walk_amt := 0.0
var _t := 0.0
var _seed := 0.0
var _aim_pitch := 0.0
var _aiming := false
var _skip := false

var _muzzle: Node3D
var _flash: MeshInstance3D
var _flash_light: OmniLight3D
var _flash_t := 0.0
var _blade_base: Node3D
var _blade_tip: Node3D
var _trail: MeshInstance3D
var _trail_mesh: ImmediateMesh
var _trail_pts: Array = []    ## [base, tip, age] in world space
var _fallback_arm: Node3D     ## no model: a simple arm pivot instead


## False if the mannequin model is missing (then a plain body is built).
func setup(kind_in: int, skin: Color, accent: Color, seed_in: float) -> void:
	kind = kind_in
	_seed = seed_in
	_t = seed_in * 10.0
	if DisplayServer.get_name() == "headless":
		return  # a server draws nothing: no body, no animation
	var body_mat := _body_material(skin)
	_base_mat = body_mat
	var m := Mannequin.new()
	if not m.setup(body_mat, Palette.toon(accent)):
		_build_fallback(body_mat, accent)
		return
	man = m
	add_child(man)
	_cache_bones()
	tint_parts.append(man.body)
	# Only the body casts a shadow: belts and weapons are too small to matter
	# and each would add a draw to the shadow pass.
	for mi in man.find_children("*", "MeshInstance3D", true, false):
		if mi != man.body:
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_add_visor(accent)
	var mats := {"dark": Palette.toon(Palette.INK), "steel": Palette.toon(Palette.STEEL),
		"accent": Palette.toon(accent), "blade": Palette.toon(Palette.KNIFE_BLADE)}
	match kind:
		GUNMAN:
			var pistol := Models.build("pistol", mats, false)
			if pistol != null:
				_hold(pistol, "hand_r", 0.0, PISTOL_SCALE)
				_muzzle = Node3D.new()
				_muzzle.position = PISTOL_MUZZLE
				pistol.add_child(_muzzle)
				_build_flash()
		SWORD:
			var sword := Models.build("sword", mats, false)
			if sword != null:
				_hold(sword, "hand_r", PI * 0.5, 1.0)
				_blade_base = Node3D.new()
				_blade_base.position = Vector3(0, 0, SWORD_BASE)
				sword.add_child(_blade_base)
				_blade_tip = Node3D.new()
				_blade_tip.position = Vector3(0, 0, SWORD_TIP)
				sword.add_child(_blade_tip)
				_build_trail()
		KNIVES:
			for side in ["hand_r", "hand_l"]:
				var knife := Models.build("knife", mats, false)
				if knife != null:
					_hold(knife, side, PI * 0.5, KNIFE_SCALE)
	animate(0.0, 0.0, null)
	_snap()


## Enemies: matte magenta with a light rim, so they pop against pale walls.
## Shared per colour, like every other material.
func _body_material(skin: Color) -> StandardMaterial3D:
	var key := skin.to_html()
	if not _skin_cache.has(key):
		var m: StandardMaterial3D = Palette.toon(skin).duplicate()
		m.rim_enabled = true
		m.rim = 0.55
		m.rim_tint = 0.35
		_skin_cache[key] = m
	return _skin_cache[key]


## A glowing band across the face in the kind's colour: shows where it looks.
func _add_visor(accent: Color) -> void:
	var visor := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.17, 0.042, 0.06)
	visor.mesh = box
	visor.material_override = Palette.glow(accent, 2.2)
	visor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var head := man.rest_origin("head")
	man.attach("head", visor, Transform3D(Basis.IDENTITY, head + Vector3(0, 0.1, -0.085)))


## Puts a weapon in a hand. `tilt` turns it up from the line of the forearm
## (0: along the arm, like a pistol; PI/2: out of the fist, like a sword).
func _hold(model: Node3D, hand: String, tilt: float, scale_by: float) -> void:
	var grip := man.rest_origin(hand) + Vector3(0, -0.07, 0)
	var basis := Basis(Vector3.RIGHT, tilt - PI * 0.5).scaled(Vector3.ONE * scale_by)
	man.attach(hand, model, Transform3D(basis, grip))


func _build_fallback(body_mat: Material, accent: Color) -> void:
	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.4
	cap.height = 1.9
	body.mesh = cap
	body.position.y = 0.95
	body.material_override = body_mat
	add_child(body)
	tint_parts.append(body)
	_fallback_arm = Node3D.new()
	_fallback_arm.position = Vector3(0.42, 1.2, -0.2)
	add_child(_fallback_arm)
	var stick := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = Vector3(0.08, 0.08, 0.7 if kind == SWORD else 0.35)
	stick.mesh = b
	stick.position.z = -b.size.z * 0.5
	stick.material_override = Palette.toon(accent)
	_fallback_arm.add_child(stick)
	_muzzle = Node3D.new()
	_muzzle.position.z = -b.size.z
	_fallback_arm.add_child(_muzzle)


# --- Events --------------------------------------------------------------------

func windup(seconds: float) -> void:
	_set_state(WINDUP, seconds)


func strike() -> void:
	_set_state(STRIKE, STRIKE_TIME)
	if kind == GUNMAN and _flash != null:
		_flash_t = 0.07
	if _trail != null:
		_trail_pts.clear()


## null puts the normal skin back.
func set_tint(mat: Material) -> void:
	for mi in tint_parts:
		mi.material_override = mat if mat != null else _base_mat


func muzzle_pos() -> Vector3:
	if _muzzle != null:
		return _muzzle.global_position
	return global_position + Vector3(0, 1.4, 0) - global_basis.z * 0.6


func _set_state(s: int, length: float) -> void:
	_state = s
	_state_t = 0.0
	_state_len = maxf(length, 0.01)


# --- Animation -------------------------------------------------------------------

## `speed`: how fast the body moves (m/s). `aim_at`: a point a gunman points
## at (null: nobody in range, keep the gun low).
func animate(real_delta: float, speed: float, aim_at: Variant) -> void:
	if man == null and _fallback_arm == null:
		return  # headless: nothing to animate
	var delta := real_delta * Clock.scale
	_t += delta
	_advance(delta)
	_aiming = aim_at != null
	if _aiming:
		var shoulder := global_position + Vector3(0, 1.45, 0)
		var to: Vector3 = aim_at - shoulder
		var flat := Vector2(to.x, to.z).length()
		_aim_pitch = clampf(atan2(to.y, maxf(flat, 0.1)), -0.6, 0.6)
	_walk_amt = move_toward(_walk_amt, clampf(speed / 3.5, 0.0, 1.0), delta * 6.0)
	_walk_phase = fmod(_walk_phase + speed * delta * 2.4, TAU)
	if man == null:
		if _fallback_arm != null:
			_fallback_arm.rotation.x = _aim_pitch if _aiming else -0.6
		return
	# Far away and calm: pose every other frame (with twice the step).
	_skip = not _skip
	var cam := get_viewport().get_camera_3d() if real_delta > 0.0 else null
	if _state == IDLE and _skip and cam != null and cam.global_position.distance_squared_to(global_position) > FAR_SQ:
		return
	if _state == IDLE and cam != null and cam.global_position.distance_squared_to(global_position) > FAR_SQ:
		delta *= 2.0
	_target_pose()
	var k := 1.0 - exp(-RATE[_state] * delta) if real_delta > 0.0 else 1.0
	for b in BONES.size():
		var cur := _shown[b].lerp(_target[b], k)
		_shown[b] = cur
		_apply(b, cur)
	var lunge_goal := 0.0
	if _state == STRIKE or (_state == RECOVER and _state_t < _state_len * 0.4):
		lunge_goal = LUNGE[kind]
	_lunge = lerpf(_lunge, lunge_goal, k)
	var crouch := 0.12 if kind == KNIVES else 0.03
	if _state == WINDUP:
		crouch += 0.08
	var bob := -absf(sin(_walk_phase)) * 0.05 * _walk_amt
	_drop = lerpf(_drop, crouch, k)
	man.shift("hips", Vector3(0, bob - _drop, -_lunge))
	_update_fx(delta)


func _advance(delta: float) -> void:
	if _state == IDLE:
		return
	_state_t += delta
	if _state_t < _state_len:
		return
	match _state:
		STRIKE:
			_set_state(RECOVER, RECOVER_TIME[kind])
		RECOVER:
			if kind == GUNMAN:
				_set_state(RELOAD, RELOAD_TIME)
			else:
				_set_state(IDLE, 0.0)
		RELOAD:
			_set_state(IDLE, 0.0)
		WINDUP:
			pass  # held until the strike arrives


func _snap() -> void:
	_target_pose()
	for b in BONES.size():
		_shown[b] = _target[b]
		_apply(b, _target[b])


## Sets bone `b` (an index into BONES) to `euler`, skipping it when the
## change is too small to see (most bones on a calm enemy).
func _apply(b: int, euler: Vector3) -> void:
	if _applied[b].distance_squared_to(euler) < 0.000004:
		return
	_applied[b] = euler
	man.skeleton.set_bone_pose_rotation(_bone_ids[b], _rest_a[b] * Quaternion.from_euler(euler) * _rest_b[b])


## Looks up each animated bone's index and rest rotations once.
func _cache_bones() -> void:
	_bone_ids.resize(BONES.size())
	_shown.resize(BONES.size())
	_target.resize(BONES.size())
	_applied.resize(BONES.size())
	for b in BONES.size():
		var id := man.skeleton.find_bone(BONES[b])
		_bone_ids[b] = id
		var g := man.skeleton.get_bone_global_rest(id).basis.get_rotation_quaternion()
		_rest_a.append(man.skeleton.get_bone_rest(id).basis.get_rotation_quaternion() * g.inverse())
		_rest_b.append(g)
		_applied[b] = Vector3(INF, 0, 0)


## The pose to move toward this frame, into _target.
func _target_pose() -> void:
	var p := _target
	var w := _walk_amt
	var s := sin(_walk_phase)
	var breath := sin(_t * 1.7 + _seed * 7.0) * 0.03
	# Legs: stride, knees bend on the back swing.
	var stride := s * 0.55 * w
	p[THIGH_L] = Vector3(stride, 0, 0)
	p[THIGH_R] = Vector3(-stride, 0, 0)
	p[SHIN_L] = Vector3(-maxf(-stride, 0.0) * 1.6, 0, 0)
	p[SHIN_R] = Vector3(-maxf(stride, 0.0) * 1.6, 0, 0)
	p[FOOT_L] = Vector3.ZERO
	p[FOOT_R] = Vector3.ZERO
	p[SPINE] = Vector3(0.06 * w, 0, 0)
	p[CHEST] = Vector3(breath + 0.08 * w, s * 0.08 * w, 0)
	p[NECK] = Vector3.ZERO
	# Glance around while idle.
	p[HEAD] = Vector3(-0.05, sin(_t * 0.37 + _seed * 3.0) * 0.25 * (1.0 - w), 0)
	# Free arms swing against the legs.
	var swing := -stride * 0.8
	p[UPPERARM_L] = Vector3(swing, 0, -0.08)
	p[FOREARM_L] = Vector3(0.25 + 0.2 * w, 0, 0)
	p[HAND_L] = Vector3.ZERO
	p[UPPERARM_R] = Vector3(-swing, 0, 0.08)
	p[FOREARM_R] = Vector3(0.25 + 0.2 * w, 0, 0)
	p[HAND_R] = Vector3.ZERO
	match kind:
		GUNMAN:
			_pose_gunman(p)
		SWORD:
			_pose_sword(p)
		KNIVES:
			_pose_knives(p)


func _phase() -> float:
	return clampf(_state_t / _state_len, 0.0, 1.0)


## Two-handed aim: right arm straight at the target, left hand under it.
func _aimed(p: PackedVector3Array) -> void:
	var aim := _aim_pitch
	p[UPPERARM_R] = Vector3(PI * 0.5 + aim, 0.12, 0)
	p[FOREARM_R] = Vector3(0.05, 0, 0)
	p[HAND_R] = Vector3(-0.05, 0, 0)
	p[UPPERARM_L] = Vector3(PI * 0.5 + aim - 0.12, -0.55, 0)
	p[FOREARM_L] = Vector3(0.15, -0.35, 0)
	p[CHEST] = Vector3(p[CHEST].x, -0.22, 0)
	p[HEAD] = Vector3(-aim * 0.8, 0.18, 0)


func _pose_gunman(p: PackedVector3Array) -> void:
	match _state:
		WINDUP, RECOVER:
			_aimed(p)
		STRIKE:
			_aimed(p)
			p[UPPERARM_R] += Vector3(0.2, 0, 0)        # recoil kicks the gun up
			p[FOREARM_R] += Vector3(0.15, 0, 0)
			p[HAND_R] += Vector3(0.35, 0, 0)
			p[UPPERARM_L] += Vector3(0.15, 0, 0)
			p[CHEST] += Vector3(-0.12, 0, 0)
			p[HEAD] += Vector3(-0.1, 0, 0)
		RELOAD:
			# Gun pulled in to the chest; the left hand slaps a new magazine in.
			var slap := sin(_phase() * PI)
			p[UPPERARM_R] = Vector3(0.45, -0.35, 0)
			p[FOREARM_R] = Vector3(1.5, 0, 0)
			p[HAND_R] = Vector3(-0.3, 0, 0)
			p[UPPERARM_L] = Vector3(0.35 + 0.25 * slap, -0.45, 0)
			p[FOREARM_L] = Vector3(1.0 + 0.4 * slap, -0.2, 0)
			p[HEAD] = Vector3(0.35, 0.1, 0)
		_:
			if _aiming:
				_aimed(p)
			else:
				# Low ready.
				p[UPPERARM_R] = Vector3(0.55, 0.15, 0.05)
				p[FOREARM_R] = Vector3(0.45, 0, 0)
				p[HAND_R] = Vector3(-0.2, 0, 0)


func _pose_sword(p: PackedVector3Array) -> void:
	# Guard: blade angled up and forward.
	p[UPPERARM_R] = Vector3(0.5, 0.2, 0.1)
	p[FOREARM_R] = Vector3(0.35, 0.15, 0)
	p[HAND_R] = Vector3(-0.25, 0, 0)
	p[UPPERARM_L] = Vector3(0.3 + p[UPPERARM_L].x * 0.5, 0, -0.15)
	p[CHEST] = Vector3(p[CHEST].x, -0.12 + p[CHEST].y, 0)
	match _state:
		WINDUP:
			# Sword lifted high behind the head, body coiled to the right.
			p[UPPERARM_R] = Vector3(2.75, 0.2, 0.35)
			p[FOREARM_R] = Vector3(0.9, 0, 0)
			p[HAND_R] = Vector3(0.35, 0, 0)
			p[UPPERARM_L] = Vector3(0.7, 0, -0.35)
			p[CHEST] = Vector3(-0.15, -0.55, 0)
			p[SPINE] = Vector3(-0.05, -0.15, 0)
			p[HEAD] = Vector3(0.05, 0.45, 0)
			p[THIGH_R] = Vector3(-0.25, 0, 0)
			p[THIGH_L] = Vector3(0.2, 0, 0)
		STRIKE, RECOVER:
			if _state == RECOVER and _phase() > 0.45:
				return  # ease back to guard
			# Diagonal slash: down and across to the left, stepping in.
			p[UPPERARM_R] = Vector3(0.95, 0.85, 0.0)
			p[FOREARM_R] = Vector3(0.1, 0.2, 0)
			p[HAND_R] = Vector3(-1.5, 0, 0)
			p[UPPERARM_L] = Vector3(-0.4, 0, -0.45)
			p[CHEST] = Vector3(0.3, 0.55, 0)
			p[SPINE] = Vector3(0.1, 0.15, 0)
			p[HEAD] = Vector3(0.1, -0.35, 0)
			p[THIGH_R] = Vector3(0.6, 0, 0)
			p[SHIN_R] = Vector3(-0.3, 0, 0)
			p[THIGH_L] = Vector3(-0.35, 0, 0)


func _pose_knives(p: PackedVector3Array) -> void:
	# Low fighting crouch, a knife forward in each hand.
	p[THIGH_L] = Vector3(0.45 + p[THIGH_L].x, 0, -0.08)
	p[THIGH_R] = Vector3(0.45 + p[THIGH_R].x, 0, 0.08)
	p[SHIN_L] = Vector3(-0.8 + p[SHIN_L].x, 0, 0)
	p[SHIN_R] = Vector3(-0.8 + p[SHIN_R].x, 0, 0)
	p[FOOT_L] = Vector3(0.35, 0, 0)
	p[FOOT_R] = Vector3(0.35, 0, 0)
	p[SPINE] = Vector3(0.2, 0, 0)
	p[CHEST] = Vector3(0.15 + p[CHEST].x, p[CHEST].y, 0)
	p[HEAD] = Vector3(-0.3, p[HEAD].y * 0.5, 0)
	p[UPPERARM_R] = Vector3(0.15, 0.1, 0.15)
	p[FOREARM_R] = Vector3(0.95, 0, 0)
	p[HAND_R] = Vector3(-0.7, 0, 0)
	p[UPPERARM_L] = Vector3(0.35, -0.1, -0.15)
	p[FOREARM_L] = Vector3(0.85, 0, 0)
	p[HAND_L] = Vector3(-0.75, 0, 0)
	match _state:
		WINDUP:
			# Both knives drawn back, coiled low.
			p[UPPERARM_R] = Vector3(-0.6, 0.0, 0.3)
			p[FOREARM_R] = Vector3(1.35, 0, 0)
			p[UPPERARM_L] = Vector3(-0.6, 0.0, -0.3)
			p[FOREARM_L] = Vector3(1.35, 0, 0)
			p[CHEST] = Vector3(0.05, 0, 0)
			p[SPINE] = Vector3(0.3, 0, 0)
		STRIKE, RECOVER:
			if _state == RECOVER and _phase() > 0.4:
				return
			# Lunge: both knives thrust forward, the left a beat behind.
			var lag := 0.0 if _state == RECOVER else 1.0 - _phase()
			p[UPPERARM_R] = Vector3(1.2, 0.12, 0)
			p[FOREARM_R] = Vector3(0.05, 0, 0)
			p[HAND_R] = Vector3(-1.05, 0, 0)
			p[UPPERARM_L] = Vector3(1.05 - 0.6 * lag, -0.12, 0)
			p[FOREARM_L] = Vector3(0.1 + 0.6 * lag, 0, 0)
			p[HAND_L] = Vector3(-1.0, 0, 0)
			p[CHEST] = Vector3(0.35, 0.1, 0)
			p[THIGH_R] = Vector3(0.9, 0, 0.08)
			p[SHIN_R] = Vector3(-0.9, 0, 0)
			p[THIGH_L] = Vector3(-0.2, 0, -0.08)
			p[SHIN_L] = Vector3(-0.3, 0, 0)


## Death: a white flash, knocked back and toppling away from the shot, then
## shrinking out of sight; the enemy is hidden at the end.
func fall(hit_dir: Vector3) -> void:
	if man == null and _fallback_arm == null:
		get_parent().visible = false
		return
	var flat := Vector3(hit_dir.x, 0, hit_dir.z)
	if flat.length() < 0.01:
		flat = global_basis.z
	flat = flat.normalized()
	set_tint(Palette.toon(Color.WHITE))
	_flash_t = 0.0
	if _trail != null:
		_trail.visible = false
	var owner_enemy := get_parent()
	# Tip over around the feet, about the axis across the shot.
	var axis := Vector3.UP.cross(flat).normalized()
	var start := global_transform
	var tw := create_tween()
	tw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	tw.tween_method(func(t: float):
		var tip := Basis(axis, t * PI * 0.48)
		global_transform = Transform3D(tip * start.basis, start.origin + flat * t * 0.9 + Vector3.UP * sin(t * PI) * 0.25)
		, 0.0, 1.0, 0.32).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(func(): set_tint(null))
	tw.tween_property(self, "scale", Vector3.ONE * 0.01, 0.35).set_delay(0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tw.tween_callback(func():
		if is_instance_valid(owner_enemy):
			owner_enemy.visible = false
		visible = false)


# --- Effects ------------------------------------------------------------------------

func _build_flash() -> void:
	if _flash_mesh == null:
		var q := QuadMesh.new()
		q.size = Vector2(0.55, 0.55)
		_flash_mesh = q
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		m.albedo_texture = _star_texture()
		m.albedo_color = Color(1.0, 0.85, 0.5) * 3.0
		_flash_mat = m
	_flash = MeshInstance3D.new()
	_flash.mesh = _flash_mesh
	_flash.material_override = _flash_mat
	_flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_flash.visible = false
	_muzzle.add_child(_flash)
	_flash_light = OmniLight3D.new()
	_flash_light.light_color = Color("ffc070")
	_flash_light.omni_range = 4.0
	_flash_light.light_energy = 0.0
	_flash_light.visible = false
	_muzzle.add_child(_flash_light)


## A soft eight-pointed star, drawn once and shared.
static func _star_texture() -> ImageTexture:
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var d := (Vector2(x, y) - Vector2(n, n) * 0.5) / (n * 0.5)
			var a := d.angle()
			var r := d.length()
			var spikes := 0.35 + 0.65 * pow(absf(cos(a * 4.0)), 6.0)
			var v := clampf(1.0 - r / spikes, 0.0, 1.0)
			v = v * v
			img.set_pixel(x, y, Color(1, 1, 1, v))
	return ImageTexture.create_from_image(img)


func _build_trail() -> void:
	if _trail_mat == null:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.vertex_color_use_as_albedo = true
		_trail_mat = m
	_trail_mesh = ImmediateMesh.new()
	_trail = MeshInstance3D.new()
	_trail.mesh = _trail_mesh
	_trail.material_override = _trail_mat
	_trail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_trail.top_level = true
	add_child(_trail)


func _update_fx(delta: float) -> void:
	if _flash != null:
		_flash_t = maxf(_flash_t - delta, 0.0)
		var on := _flash_t > 0.0
		_flash.visible = on
		_flash_light.visible = on
		if on:
			var k := _flash_t / 0.07
			_flash.scale = Vector3.ONE * (0.6 + 0.8 * k)
			_flash.rotation.z = randf() * TAU
			_flash_light.light_energy = 6.0 * k
	if _trail != null:
		_update_trail(delta)


## A white ribbon behind the blade during a slash, fading over a moment.
func _update_trail(delta: float) -> void:
	var slashing := _state == STRIKE or (_state == RECOVER and _state_t < 0.12)
	for pt in _trail_pts:
		pt[2] += delta
	while not _trail_pts.is_empty() and _trail_pts[0][2] > 0.18:
		_trail_pts.pop_front()
	if slashing:
		_trail_pts.append([_blade_base.global_position, _blade_tip.global_position, 0.0])
		if _trail_pts.size() > TRAIL_POINTS:
			_trail_pts.pop_front()
	_trail_mesh.clear_surfaces()
	if _trail_pts.size() < 2:
		return
	_trail_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for pt in _trail_pts:
		var a := clampf(1.0 - pt[2] / 0.18, 0.0, 1.0) * 0.85
		_trail_mesh.surface_set_color(Color(0.85, 0.92, 1.0, a * 0.2))
		_trail_mesh.surface_add_vertex(pt[0])
		_trail_mesh.surface_set_color(Color(1, 1, 1, a))
		_trail_mesh.surface_add_vertex(pt[1])
	_trail_mesh.surface_end()
