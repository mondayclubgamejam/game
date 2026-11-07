extends Node3D
## The shared human figure (assets/models/enemy.glb, built by
## tools/blender/enemy.py), used for enemies and the remote player. Owns the
## skeleton: walking swings the legs, and bend() turns any limb.
##
## Usage: var m := Mannequin.new(); if m.setup(body_mat, belt_mat): add_child(m)

const MODEL_PATH := "res://assets/models/enemy.glb"
const SHOULDER := Vector3(0.24, 1.455, 0.0)  ## right shoulder; the left one is mirrored
const REACH := 0.56                          ## shoulder to the grip in the hand
const WALK_SWING := 0.5                      ## leg swing at full stride (radians)

static var _scene: PackedScene = null
static var _checked := false

var body: MeshInstance3D
var skeleton: Skeleton3D
var swing := 0.0             ## current leg swing (radians), for arm counter-swing

var _bones := {}
var _phase := 0.0
var _amount := 0.0


static func available() -> bool:
	if not _checked:
		_checked = true
		if ResourceLoader.exists(MODEL_PATH):
			_scene = load(MODEL_PATH)
	return _scene != null


## Builds the figure. False if the model hasn't been built yet.
func setup(body_mat: Material, belt_mat: Material) -> bool:
	if not available():
		return false
	var model := _scene.instantiate()
	add_child(model)
	body = model.find_child("body", true, false)
	body.material_override = body_mat
	(model.find_child("belt", true, false) as MeshInstance3D).material_override = belt_mat
	skeleton = model.find_children("*", "Skeleton3D", true, false)[0]
	return true


## Legs swing opposite each other and the knees bend on the back swing,
## scaled by speed (m/s).
func walk(speed: float, delta: float) -> void:
	_amount = move_toward(_amount, clampf(speed / 3.0, 0.0, 1.0), delta * 6.0)
	_phase = fmod(_phase + speed * delta * 2.6, TAU)
	swing = sin(_phase) * WALK_SWING * _amount
	bend("thigh_l", swing)
	bend("thigh_r", -swing)
	bend("shin_l", -maxf(-swing, 0.0) * 1.6)
	bend("shin_r", -maxf(swing, 0.0) * 1.6)


## Turns a bone from its rest pose about the body's side-to-side axis.
## Positive swings a hanging limb forward; PI / 2 points an arm straight ahead.
func bend(bone_name: String, angle: float) -> void:
	if not _bones.has(bone_name):
		_bones[bone_name] = skeleton.find_bone(bone_name)
	var bone: int = _bones[bone_name]
	if bone < 0:
		return
	var rest := skeleton.get_bone_rest(bone).basis.get_rotation_quaternion()
	var g := skeleton.get_bone_global_rest(bone).basis.get_rotation_quaternion()
	skeleton.set_bone_pose_rotation(bone, rest * (g.inverse() * Quaternion(Vector3.RIGHT, angle) * g))
