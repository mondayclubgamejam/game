extends Node3D
## The live scene behind the title screen and match lobby: a room with a
## handful of enemies idling, now and then rehearsing an attack, while the
## camera drifts gently. Shown only while no round is running.

const Maps := preload("res://scripts/maps.gd")
const RoomBuilder := preload("res://scripts/room_builder.gd")
const Enemy := preload("res://scripts/enemy.gd")

## Where each figure's feet land on screen (1280 x 720 layout: low on the
## left, under the title and clear of the menu panel) and its kind.
const CAST := [
	[Vector2(120, 690), 1], [Vector2(300, 655), 0], [Vector2(470, 700), 2],
	[Vector2(215, 600), 2], [Vector2(420, 590), 1], [Vector2(560, 610), 0],
]
const CAM_POS := Vector3(16.0, 1.8, 3.5)
const CAM_LOOK := Vector3(22.0, 6.8, 20.0)   ## tilted up so eye level (and the heads) sits low on screen

var game: Node                 ## main: the stage shows only while game.round_root is null
var _camera: Camera3D
var _rigs: Array = []          ## the enemies on show (their brains stay off)
var _t := 0.0
var _next_attack := 2.0
var _placed := false
var _set: Node3D = null       ## the room and cast while shown


func _ready() -> void:
	_camera = Camera3D.new()
	_camera.fov = 62.0
	add_child(_camera)
	_camera.position = CAM_POS
	_camera.look_at(CAM_LOOK)


## The room and cast exist only while the stage is shown: freed during play,
## rebuilt on the way back to the menus.
func _build() -> void:
	_set = Node3D.new()
	add_child(_set)
	_set.add_child(RoomBuilder.build(Maps.build("warmup", 2)))
	for i in CAST.size():
		var e := Enemy.new()
		e.id = 100 + i
		e.kind = CAST[i][1]
		e.game = game
		_set.add_child(e)
		e.set_physics_process(false)  # just for show: no brain, no moving
		e.set_meta("phase", randf() * TAU)
		_rigs.append(e)
	_placed = false


func _teardown() -> void:
	_rigs.clear()
	_set.queue_free()
	_set = null


## Stands each figure where its feet should appear, facing the camera.
func _place_cast() -> void:
	var view := get_viewport().get_visible_rect().size
	for i in CAST.size():
		var screen: Vector2 = CAST[i][0] / Vector2(1280, 720) * view
		var from := _camera.project_ray_origin(screen)
		var dir := _camera.project_ray_normal(screen)
		if dir.y >= -0.001:
			continue
		var feet := from + dir * (-from.y / dir.y)
		var rig: Node3D = _rigs[i]
		rig.position = feet
		var to := CAM_POS - feet
		rig.rotation.y = atan2(-to.x, -to.z) + randf_range(-0.35, 0.35)
		rig.set_meta("yaw", rig.rotation.y)
	_placed = true


func _process(delta: float) -> void:
	var on: bool = game != null and game.round_root == null
	visible = on
	if not on:
		if _set != null:
			_teardown()
		return
	if _set == null:
		_build()
	if not _camera.current:
		_camera.make_current()
	if not _placed:
		_place_cast()
	_t += delta
	var sway := sin(_t * 0.09)
	_camera.position = CAM_POS + Vector3(sway * 0.6, sin(_t * 0.13) * 0.12, 0)
	_camera.look_at(CAM_LOOK + Vector3(sway * 0.4, 0, 0))
	# A gentle sway so nobody stands frozen.
	for rig in _rigs:
		var ph: float = rig.get_meta("phase")
		rig.rotation.y = rig.get_meta("yaw", 0.0) + sin(_t * 0.6 + ph) * 0.12
	_next_attack -= delta
	if _next_attack <= 0.0:
		_next_attack = randf_range(1.2, 2.6)
		var rig: Node = _rigs[randi() % _rigs.size()]
		rig.show_windup(null, 0.6)
		get_tree().create_timer(0.6).timeout.connect(func():
			if is_instance_valid(rig):
				rig.show_strike())
