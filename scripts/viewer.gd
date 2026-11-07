extends Node3D
## Look-only mode: a generated room with frozen enemies, a partner and the gun
## on the floor, plus every UI screen filled with sample data. No networking,
## no AI, no physics gameplay. Fly around to look at the space.
##
##   Mouse        look (click to grab the mouse, Esc to let go)
##   WASD         fly          Space / E  up      Ctrl / Q  down     Shift  fast
##   G            walk height (snap to eye level at the spawn)
##   N / P        next / previous room seed
##   1 2 3 0      UI: HUD / title + lobby / pause / none
##   L            next lobby page (menu, join, hosting, match lobby)
##   R            swap role (HUD colours)
##   B            play a banner           T  toggle the slow-motion look
##   K            enemies walk on the spot (animation only)
##   J            line up one enemy of each kind in front of you
##   --shot=FILE  (command line) line up, take a screenshot, quit
##   --cam=x,y,z,yaw,pitch   (command line) camera position for the shot, no lineup
##   --lineup     (command line) line up in front of the spawn even with --cam

const Palette := preload("res://scripts/palette.gd")
const RoomGen := preload("res://scripts/room_gen.gd")
const RoomBuilder := preload("res://scripts/room_builder.gd")
const WorldFx := preload("res://scripts/world_fx.gd")
const Player := preload("res://scripts/player.gd")
const Enemy := preload("res://scripts/enemy.gd")
const Gun := preload("res://scripts/gun.gd")
const Hud := preload("res://scripts/hud.gd")
const Lobby := preload("res://scripts/lobby.gd")
const PauseMenu := preload("res://scripts/pause_menu.gd")

const FLY_SPEED := 8.0
const MOUSE_SENS := 0.0022
const EYE := 1.6
const BANNERS := [["ROOM 1", Palette.SIGNAL], ["KILL!", Palette.FORWARD], ["DOUBLE!", Palette.REVERSE],
	["CLEAR!", Palette.ENEMY], ["BLOCKED!", Palette.DANGER], ["YOU DIED", Palette.DANGER]]

var fx: WorldFx
var hud: Hud
var lobby: Lobby
var pause: PauseMenu
var cam: Camera3D
var room_seed := 1
var room: RefCounted
var round_root: Node3D
var partner: Player
var gun: Gun
var role := 0
var slowmo := false
var lobby_page := 0
var banner_i := 0
var ui_mode := 1
var walking := false
var enemies: Array = []
var _yaw := PI
var _pitch := 0.0
var _info: Label


func _ready() -> void:
	fx = WorldFx.new()
	add_child(fx)
	cam = Camera3D.new()
	cam.fov = 82.0
	cam.near = 0.05
	cam.far = 200.0
	add_child(cam)
	cam.make_current()

	var ui := CanvasLayer.new()
	add_child(ui)
	hud = Hud.new()
	ui.add_child(hud)
	lobby = Lobby.new()
	ui.add_child(lobby)
	pause = PauseMenu.new()
	ui.add_child(pause)
	_info = Label.new()
	_info.position = Vector2(16, 140)
	_info.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	_info.add_theme_color_override("font_outline_color", Palette.INK)
	_info.add_theme_constant_override("outline_size", 4)
	ui.add_child(_info)

	_build_room()
	_go_to_spawn()
	_set_ui(1)
	var lineup := true
	if OS.get_cmdline_user_args().has("--lineup"):
		_lineup()  # in front of the spawn, before --cam moves the camera
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--cam="):
			# --cam=x,y,z,yaw_deg,pitch_deg puts the camera somewhere for a screenshot.
			var v := arg.trim_prefix("--cam=").split_floats(",")
			cam.position = Vector3(v[0], v[1], v[2])
			_yaw = deg_to_rad(v[3])
			_pitch = deg_to_rad(v[4])
			cam.rotation = Vector3(_pitch, _yaw, 0)
			lineup = false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--quit-after="):  # for smoke tests
			get_tree().create_timer(arg.trim_prefix("--quit-after=").to_float()).timeout.connect(get_tree().quit)
		elif arg == "--walk":
			walking = true
		elif arg.begins_with("--shot="):
			if lineup:
				_lineup()
			_take_shot(arg.trim_prefix("--shot="))


func _take_shot(path: String) -> void:
	await get_tree().create_timer(1.0).timeout
	get_viewport().get_texture().get_image().save_png(path)
	print("saved ", path)
	get_tree().quit()


## One enemy of each kind, 3.5 m in front of the camera, facing it.
func _lineup() -> void:
	var fwd := -cam.global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var side := fwd.cross(Vector3.UP)
	var shown := {}
	for e in enemies:
		if shown.has(e.kind):
			continue
		var p: Vector3 = cam.global_position + fwd * 3.5 + side * (float(shown.size()) - 1.0) * 1.3
		e.global_position = Vector3(p.x, 0.0, p.z)
		e.look_at(Vector3(cam.global_position.x, 0.0, cam.global_position.z), Vector3.UP)
		shown[e.kind] = true


func _build_room() -> void:
	if round_root:
		round_root.queue_free()
	room = RoomGen.generate(room_seed)
	round_root = Node3D.new()
	add_child(round_root)
	round_root.add_child(RoomBuilder.build(room))
	enemies.clear()

	partner = Player.new()
	partner.setup(2, 1 - role, false)
	round_root.add_child(partner)
	partner.place(RoomGen.cell_center(room.spawns[1]) + Vector3(0, 0.05, 0), PI)
	partner.process_mode = Node.PROCESS_MODE_DISABLED

	for i in room.enemy_cells.size():
		var e := Enemy.new()
		e.id = i
		e.kind = room.enemy_kinds[i]
		e.position = RoomGen.cell_center(room.enemy_cells[i])
		e.rotation.y = randf() * TAU
		round_root.add_child(e)
		e.process_mode = Node.PROCESS_MODE_DISABLED
		enemies.append(e)

	gun = Gun.new()
	round_root.add_child(gun)
	gun.global_position = RoomGen.cell_center(room.spawns[0]) + Vector3(0, 0.15, -2.0)
	gun.state = Gun.GROUND
	gun._refresh_visual()
	gun.process_mode = Node.PROCESS_MODE_DISABLED


func _go_to_spawn() -> void:
	cam.position = RoomGen.cell_center(room.spawns[0]) + Vector3(0, EYE, 0)
	_yaw = PI
	_pitch = 0.0
	cam.rotation = Vector3(_pitch, _yaw, 0)


func _set_ui(mode: int) -> void:
	ui_mode = mode
	hud.visible = mode == 1
	lobby.visible = mode == 2
	pause.visible = mode == 3
	if mode == 2:
		_show_lobby_page()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if mode in [0, 1] else Input.MOUSE_MODE_VISIBLE


func _show_lobby_page() -> void:
	match lobby_page:
		0:
			lobby.show_menu("", false)
		1:
			lobby.show_menu("", false)
			lobby._show_page(lobby._join)
			lobby.set_lan_hosts([{"ip": "192.168.0.12", "port": 7777, "name": "Alex"},
				{"ip": "192.168.0.31", "port": 7778, "name": "Sam"}])
		2:
			lobby.show_hosting(7777, ["192.168.0.12"], "Sample firewall hint goes here.", true)
		3:
			lobby.show_party([{"id": 1, "name": "YOU", "role": role, "ready": true},
				{"id": 2, "name": "PARTNER", "role": 1 - role, "ready": false}],
				1, 1, "NEW GAME", slowmo, "Sample note in the message strip")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * MOUSE_SENS
		_pitch = clampf(_pitch - event.relative.y * MOUSE_SENS, -1.5, 1.5)
	elif event is InputEventMouseButton and event.pressed and ui_mode in [0, 1]:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			KEY_1:
				_set_ui(1)
			KEY_2:
				_set_ui(2)
			KEY_3:
				_set_ui(3)
			KEY_0:
				_set_ui(0)
			KEY_L:
				lobby_page = (lobby_page + 1) % 4
				_set_ui(2)
			KEY_N:
				room_seed += 1
				_build_room()
			KEY_P:
				room_seed = maxi(1, room_seed - 1)
				_build_room()
			KEY_G:
				_go_to_spawn()
			KEY_R:
				role = 1 - role
				_build_room()
				if ui_mode == 2:
					_show_lobby_page()
			KEY_B:
				var b: Array = BANNERS[banner_i % BANNERS.size()]
				hud.banner(b[0], b[1])
				banner_i += 1
			KEY_T:
				slowmo = not slowmo
			KEY_K:
				walking = not walking
			KEY_J:
				_lineup()


func _process(delta: float) -> void:
	cam.rotation = Vector3(_pitch, _yaw, 0)
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var dir := Vector3.ZERO
		if Input.is_key_pressed(KEY_W): dir.z -= 1
		if Input.is_key_pressed(KEY_S): dir.z += 1
		if Input.is_key_pressed(KEY_A): dir.x -= 1
		if Input.is_key_pressed(KEY_D): dir.x += 1
		var up := 0.0
		if Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_E): up += 1
		if Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_Q): up -= 1
		var speed := FLY_SPEED * (3.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
		cam.position += (cam.global_basis * dir.normalized() + Vector3.UP * up) * speed * delta

	for e in enemies:
		e._rig.animate(delta, 2.5 if walking else 0.0, null)

	var s := move_toward(hud.slowmo, 1.0 if slowmo else 0.0, delta * 3.0)
	hud.slowmo = s
	fx.set_slowmo(s)

	# Sample HUD state.
	hud.role = role
	hud.can_act = true
	hud.targets = room.enemy_cells.size()
	hud.attempt = 1
	hud.ping_ms = 42
	hud.markers.clear()
	_add_marker(partner.global_position + Vector3(0, 2.4, 0), Palette.role_color(partner.role),
		"NORMAL" if partner.role == 0 else "INVERTED")
	_add_marker(gun.global_position + Vector3(0, 0.5, 0), Palette.SIGNAL, "GUN")

	_info.visible = ui_mode != 2 and ui_mode != 3
	_info.text = "VIEW MODE  ·  seed %d\n1 HUD  2 LOBBY (L next page)  3 PAUSE  0 NONE\nN/P room  G spawn  R role  B banner  T slow-mo  K walk  J lineup\nWASD fly  SPACE/E up  CTRL/Q down  SHIFT fast" % room_seed


func _add_marker(world: Vector3, col: Color, label: String) -> void:
	var view := hud.size
	var behind := cam.is_position_behind(world)
	var p := cam.unproject_position(world)
	var margin := 36.0
	var on_screen := not behind and Rect2(Vector2.ONE * margin, view - Vector2.ONE * margin * 2.0).has_point(p)
	if not on_screen:
		if behind:
			p = view - p
		p = p.clamp(Vector2.ONE * margin, view - Vector2.ONE * margin)
	hud.markers.append([p, col, label, on_screen])
