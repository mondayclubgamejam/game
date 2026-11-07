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
var _rests := {}             ## bone -> [index, rest * global_rest^-1, global_rest] (pose() runs a lot)
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
	pose(bone_name, Vector3(angle, 0.0, 0.0))


## Turns a bone from its rest pose by `euler` (pitch, yaw, roll in radians),
## measured in the body's axes about the bone's own pivot and relative to its
## parent. x > 0 swings a hanging limb forward, y > 0 turns it toward the
## body's left, z > 0 swings it toward the body's right (+X).
func pose(bone_name: String, euler: Vector3) -> void:
	var r: Array = _rests.get(bone_name, [])
	if r.is_empty():
		var bone := _bone(bone_name)
		if bone < 0:
			return
		var g := skeleton.get_bone_global_rest(bone).basis.get_rotation_quaternion()
		r = [bone, skeleton.get_bone_rest(bone).basis.get_rotation_quaternion() * g.inverse(), g]
		_rests[bone_name] = r
	skeleton.set_bone_pose_rotation(r[0], r[1] * Quaternion.from_euler(euler) * r[2])


## Moves a bone from its rest position (the hips: the whole body).
func shift(bone_name: String, offset: Vector3) -> void:
	var bone := _bone(bone_name)
	if bone >= 0:
		skeleton.set_bone_pose_position(bone, skeleton.get_bone_rest(bone).origin + offset)


## Something that follows a bone (a weapon in the hand, a visor on the head).
## `body_xform` is where it sits, in the body's space, with the figure at rest.
func attach(bone_name: String, node: Node3D, body_xform: Transform3D) -> void:
	var bone := _bone(bone_name)
	var holder := BoneAttachment3D.new()
	holder.bone_name = bone_name
	skeleton.add_child(holder)
	node.transform = skeleton.get_bone_global_rest(bone).affine_inverse() * body_xform
	holder.add_child(node)


func rest_origin(bone_name: String) -> Vector3:
	return skeleton.get_bone_global_rest(_bone(bone_name)).origin


func _bone(bone_name: String) -> int:
	if not _bones.has(bone_name):
		_bones[bone_name] = skeleton.find_bone(bone_name)
	return _bones[bone_name]
