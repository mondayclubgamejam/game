extends CharacterBody3D
## One of the two first-person players. Movement, camera and input only; the
## shared bullet (bullet.gd) owns the gun rules.
##   role "A": forward, can only fire     role "B": inverted, can only recall

const Figure := preload("res://scripts/enemy_figure.gd")

const WALK_SPEED := 5.0
const TURN_SPEED := 2.4
const GRAVITY := 20.0
const EYE_HEIGHT := 1.6

var role := "A"
var actions := "p1_"    ## input action prefix: p1_forward, p1_back, p1_left, p1_right, p1_act
var gun: Node           ## the shared bullet
var camera: Camera3D    ## lives in this player's SubViewport; we drive its transform
var muzzle_node: Node3D ## set from the viewmodel
var body_layer := 2     ## render layer for this player's body (hidden from own camera)
var accent := Color.WHITE
var move_amount := 0.0  ## 0..1, read by the viewmodel for bobbing

var _shake := 0.0


func _ready() -> void:
	collision_layer = 4
	collision_mask = 1 | 2 | 4  # walls, enemies, the other player
	add_to_group("player")

	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = 1.8
	shape.shape = capsule
	shape.position = Vector3(0, 0.9, 0)
	add_child(shape)

	_build_body()


func _physics_process(delta: float) -> void:
	var turn := Input.get_axis(actions + "right", actions + "left")
	rotate_y(turn * TURN_SPEED * delta)
	var forward_in := Input.get_axis(actions + "back", actions + "forward")
	var dir := -global_basis.z * forward_in
	dir.y = 0.0
	velocity.x = dir.x * WALK_SPEED
	velocity.z = dir.z * WALK_SPEED
	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= GRAVITY * delta
	move_and_slide()
	move_amount = Vector2(velocity.x, velocity.z).length() / WALK_SPEED

	if gun and Input.is_action_just_pressed(actions + "act"):
		if role == "A":
			gun.try_fire()
		else:
			gun.try_recall()


func _process(delta: float) -> void:
	if camera == null:
		return
	_shake = move_toward(_shake, 0.0, delta * 5.0)
	camera.global_transform = global_transform.translated_local(Vector3(0, EYE_HEIGHT, 0))
	camera.h_offset = randf_range(-1.0, 1.0) * _shake * 0.06
	camera.v_offset = randf_range(-1.0, 1.0) * _shake * 0.06


func shake(amount: float) -> void:
	_shake = maxf(_shake, amount)


func eye() -> Vector3:
	return global_position + Vector3(0, EYE_HEIGHT, 0)


func aim_dir() -> Vector3:
	var v := -global_basis.z
	v.y = 0.0
	return v.normalized()


func muzzle() -> Vector3:
	if muzzle_node:
		return muzzle_node.global_position
	return eye() + aim_dir() * 0.45


## A light grey figure with a glowing visor in this player's colour, so the
## other player can see where you are (and it doesn't read as an enemy).
## Hidden from your own camera.
func _build_body() -> void:
	var suit := StandardMaterial3D.new()
	suit.albedo_color = Color("c8cad4")
	suit.roughness = 0.55
	suit.metallic = 0.1
	var visor := StandardMaterial3D.new()
	visor.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	visor.albedo_color = accent
	var gun_mat := StandardMaterial3D.new()
	gun_mat.albedo_color = Color("15151b")
	var body := Node3D.new()
	add_child(body)
	Figure.build(body, suit, visor, gun_mat, 0)
	for child in body.get_children():
		if child is VisualInstance3D:
			child.layers = body_layer
