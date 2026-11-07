extends Control
## Title screen and pre-game lobby.
##   menu:  name, play online, host a game, join a game
##   join:  games found on the local network, or join by address
##   wait:  hosting / connecting
##   party: the match lobby: both players, their roles, ready

signal host_requested(port: int)
signal join_requested(address: String, port: int)
signal cancel_requested
signal online_requested(address: String)
signal join_page(opened: bool)        ## the network scan only runs while this page is open
signal role_chosen(role: int)        ## join a column
signal move_requested(id: int, role: int)  ## host: move someone to a column
signal map_chosen(id: String)              ## host: pick the map
signal ready_toggled(ready: bool)
signal slowmo_toggled(on: bool)

const Palette := preload("res://scripts/palette.gd")
const TitleFont := preload("res://assets/fonts/Anton-Regular.ttf")
const BgShader := preload("res://shaders/menu_bg.gdshader")
const TileShader := preload("res://shaders/map_tile.gdshader")
const MAP_PICTURES := "res://assets/maps/%s.png"   ## made by tools/map_previews.gd
const TILE_INSET := 6.0       ## the picture sits inside the tile's border
const DEFAULT_PORT := 7777
const PAPER := Color("f3e9d2")
const SETTINGS := "user://settings.cfg"
const READY_COLOR := Color("9bff3a")
const MAX_PLAYERS := 4
## The map grid in the match lobby, 3 x 3, read left to right, top to bottom.
## Only maps marked ready can be picked; the rest are still being made.
const MAPS := [
	{"id": "tutorial", "name": "TUTORIAL", "sub": "LEARN THE LOOP", "ready": false},
	{"id": "random", "name": "RANDOM", "sub": "A NEW ROOM EVERY TIME", "ready": true},
	{"id": "endless", "name": "ENDLESS", "sub": "HOW FAR CAN YOU GET?", "ready": true},
	# Hand-made maps (scripts/maps.gd), easiest first.
	{"id": "warmup", "name": "WARM UP", "sub": "SUPER EASY", "ready": true, "tier": 1},
	{"id": "yard", "name": "THE YARD", "sub": "EASY", "ready": true, "tier": 2},
	{"id": "crossfire", "name": "CROSSFIRE", "sub": "MEDIUM", "ready": true, "tier": 3},
	{"id": "maze", "name": "THE MAZE", "sub": "HARD", "ready": true, "tier": 4},
	{"id": "gauntlet", "name": "GAUNTLET", "sub": "VERY HARD", "ready": true, "tier": 5},
	{"id": "giggles", "name": "SHITS & GIGGLES", "sub": "GOOD LUCK", "ready": true, "tier": 6},
]
## Tile colours for the hand-made maps, by difficulty: green to purple.
const TIER_COLORS := [Color("3ecf6e"), Color("a5d93a"), Color("f2c230"), Color("ff8a2a"), Color("ff3d4a"), Color("b04bff")]
const DEFAULT_MAP := "random"
## The match lobby panel (1280 x 720 layout) and its slant. The map grid
## fills the same height and its right edge runs parallel to the panel's
## white left edge.
const PANEL_LEFT := 720.0
const PANEL_TOP := 36.0
const PANEL_BOTTOM := 628.0
const PANEL_SKEW := 0.08
const GRID_LEFT := 64.0      ## left edge of the middle row
const GRID_GAP := 12.0       ## between tiles
const GRID_MARGIN := 24.0    ## between the grid and the panel


static func map_available(id: String) -> bool:
	for m in MAPS:
		if m["id"] == id:
			return m["ready"]
	return false


## Best room reached in Endless with this many players, on this computer.
static func endless_best(players: int) -> int:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS) != OK:
		return 0
	return int(cfg.get_value("endless", "best_%d" % players, 0))


## Whether this computer's player has cleared hand-made map `id`.
static func is_cleared(id: String) -> bool:
	var cfg := ConfigFile.new()
	return cfg.load(SETTINGS) == OK and bool(cfg.get_value("cleared", id, false))


static func record_cleared(id: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	cfg.set_value("cleared", id, true)
	cfg.save(SETTINGS)


## Remembers `room` as the best Endless room for this many players if it is.
static func record_endless(players: int, room: int) -> int:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	var best := int(cfg.get_value("endless", "best_%d" % players, 0))
	if room > best:
		best = room
		cfg.set_value("endless", "best_%d" % players, best)
		cfg.save(SETTINGS)
	return best

var _pages: Array[Control] = []
var _menu: VBoxContainer
var _join: VBoxContainer
var _wait: VBoxContainer
var _party: VBoxContainer
var _name: LineEdit
var _server: LineEdit
var _address: LineEdit
var _lan_list: VBoxContainer
var _lan_empty: Label
var _lan_count: Label
var _wait_title: Label
var _wait_sub: Label
var _wait_sub_base := ""
var _wait_addresses: Label
var _wait_hint: Label
var _party_info: Label
var _columns: Array[VBoxContainer] = []   ## player cards per role
var _join_buttons: Array[Button] = []
var _party_status: Label
var _options_heading: Label
var _leader := 0
var _title_node: Control
var _maps_node: Control
var _map_tiles: Array[Button] = []
var _map_subs: Array[Label] = []
var _map_pics: Array[ShaderMaterial] = []   ## null where a map has no picture
var _host_label: Label
var _ready_button: Button
var _my_ready := false
var _slowmo_button: Button
var _slowmo_on := false
var _message: Label
var _message_strip: PanelContainer
var _t := 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var th := Theme.new()
	th.default_font = TitleFont
	th.default_font_size = 18
	theme = th

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg_mat := ShaderMaterial.new()
	bg_mat.shader = BgShader
	bg.material = bg_mat
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	_build_title()
	_build_maps()
	_build_panel()
	_build_message_strip()
	_load_settings()
	show_menu("", false)


# --- Public -------------------------------------------------------------------

func server_address() -> String:
	return _server.text.strip_edges()


func player_name() -> String:
	var n := _name.text.strip_edges().to_upper()
	return n if n != "" else "PLAYER"


func show_menu(message: String, is_error: bool) -> void:
	_show_page(_menu)
	_set_message(message, is_error)


func show_hosting(port: int, ips: Array, hint: String, answering: bool, note := "") -> void:
	_show_page(_wait)
	_wait_title.text = "HOSTING"
	_wait_title.add_theme_color_override("font_color", Palette.FORWARD)
	_wait_sub_base = "WAITING FOR YOUR PARTNER"
	var lines := []
	for ip in ips:
		lines.append("%s : %d" % [ip, port])
	_wait_addresses.text = "YOUR ADDRESS\n" + ("\n".join(lines) if not lines.is_empty() else "NO NETWORK FOUND")
	_wait_addresses.visible = true
	var extra := "" if answering else "\nAnother copy here is using port 7778, so LAN players may not see you; they can still join by address."
	_wait_hint.text = hint + extra
	_wait_hint.visible = true
	_set_message(note, false)


func show_busy(text: String, note := "") -> void:
	_show_page(_wait)
	_wait_title.text = "JOINING"
	_wait_title.add_theme_color_override("font_color", Palette.REVERSE)
	_wait_sub_base = text
	_wait_addresses.visible = false
	_wait_hint.visible = false
	_set_message(note, false)


## The match lobby. `members`: [{id, name, role (0 normal / 1 inverted), ready}].
## Players pick a column; the host (`leader`) can also move anyone, and is
## the only one who sees the match options.
func show_party(members: Array, my_id: int, leader: int, info: String, slowmo: bool, map_id: String,
		note := "") -> void:
	if not _party.visible:
		_show_page(_party)
	_leader = leader
	var is_host := my_id == leader
	_party_info.text = info
	_host_label.text = ""
	for m in members:
		if m["id"] == leader:
			_host_label.text = "HOST  ·  %s" % m["name"]
	_show_maps(map_id, is_host, members.size())
	var my_role := -1
	var counts := [0, 0]
	for m in members:
		counts[m["role"]] += 1
		if m["id"] == my_id:
			my_role = m["role"]
			_my_ready = m["ready"]
	for r in 2:
		for child in _columns[r].get_children():
			child.queue_free()
		for m in members:
			if m["role"] == r:
				_columns[r].add_child(_player_card(m, my_id, is_host))
		_join_buttons[r].visible = my_role != r
	if members.size() < 2:
		_party_status.text = "WAITING FOR MORE PLAYERS  ·  %d / %d" % [members.size(), MAX_PLAYERS]
		_party_status.add_theme_color_override("font_color", Palette.MUTED.lightened(0.5))
	elif counts[0] == 0 or counts[1] == 0:
		_party_status.text = "NEED AT LEAST ONE PLAYER ON EACH SIDE"
		_party_status.add_theme_color_override("font_color", Palette.DANGER)
	else:
		_party_status.text = "%d / %d PLAYERS%s" % [members.size(), MAX_PLAYERS,
			"  ·  CLICK A PLAYER TO MOVE THEM" if is_host else ""]
		_party_status.add_theme_color_override("font_color", Palette.MUTED.lightened(0.5))
	_slowmo_on = slowmo
	_slowmo_button.text = "TIME SLOWS WHEN EVERYONE STANDS STILL:  " + ("ON" if slowmo else "OFF")
	_slowmo_button.add_theme_stylebox_override("normal", _slanted(Palette.MUTED.lightened(0.25) if slowmo
		else Palette.MUTED.darkened(0.45), 6 if slowmo else 4, Color.WHITE if slowmo else Palette.INK))
	_options_heading.visible = is_host
	_slowmo_button.visible = is_host
	var can_start: bool = members.size() >= 2 and counts[0] > 0 and counts[1] > 0
	_ready_button.disabled = not can_start and not _my_ready
	_ready_button.text = "CANCEL" if _my_ready else "READY UP"
	_ready_button.add_theme_stylebox_override("normal", _slanted(Palette.MUTED if _my_ready else READY_COLOR))
	_ready_button.add_theme_stylebox_override("hover", _slanted((Palette.MUTED if _my_ready else READY_COLOR).lightened(0.15)))
	_set_message(note, false)


## A player in a column: "NAME (YOU)" with a tick (ready) or a cross (not
## ready) on the right. For the host, other players' cards are buttons that
## move them across.
func _player_card(m: Dictionary, my_id: int, is_host: bool) -> Button:
	var role: int = m["role"]
	var b := Button.new()
	b.custom_minimum_size.y = 50
	b.focus_mode = Control.FOCUS_NONE
	var style := _slanted(Palette.role_color(role), 4)
	for state in ["normal", "disabled", "pressed"]:
		b.add_theme_stylebox_override(state, style)
	b.add_theme_stylebox_override("hover", _slanted(Palette.role_color(role).lightened(0.2), 4))
	var name_label := _label(str(m["name"]) + ("  (YOU)" if m["id"] == my_id else ""), 20, Color.WHITE, 5, Vector2.ZERO)
	name_label.clip_text = true
	name_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	name_label.offset_left = 22
	name_label.offset_right = -50
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	b.add_child(name_label)
	var mark := ReadyMark.new()
	mark.is_ready = m["ready"]
	mark.anchor_left = 1.0
	mark.anchor_right = 1.0
	mark.anchor_top = 0.5
	mark.anchor_bottom = 0.5
	mark.offset_left = -50
	mark.offset_right = -14
	mark.offset_top = -18
	mark.offset_bottom = 18
	b.add_child(mark)
	var movable: bool = is_host and m["id"] != my_id
	b.disabled = not movable
	if movable:
		var id: int = m["id"]
		b.pressed.connect(func(): move_requested.emit(id, 1 - role))
	return b


## An ink badge with a green tick (ready) or a red cross (not ready).
class ReadyMark extends Control:
	const Pal := preload("res://scripts/palette.gd")
	const TICK := Color("9bff3a")
	var is_ready := false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5
		draw_circle(c, r, Pal.INK)
		var u := r / 18.0
		if is_ready:
			var pts := PackedVector2Array([c + Vector2(-9, 0) * u, c + Vector2(-3, 7) * u, c + Vector2(10, -8) * u])
			draw_polyline(pts, TICK, 5.5 * u, true)
		else:
			var col := Pal.DANGER.lightened(0.15)
			draw_line(c + Vector2(-7, -7) * u, c + Vector2(7, 7) * u, col, 5.5 * u, true)
			draw_line(c + Vector2(7, -7) * u, c + Vector2(-7, 7) * u, col, 5.5 * u, true)


func is_in_party() -> bool:
	return _party.visible


## One JOIN card per game found on the LAN.
func set_lan_hosts(hosts: Array) -> void:
	for child in _lan_list.get_children():
		child.queue_free()
	for h in hosts:
		var ip: String = h["ip"]
		var port: int = h["port"]
		var where := ip if port == DEFAULT_PORT else "%s : %d" % [ip, port]
		var card := _card("JOIN  %s" % str(h["name"]).to_upper(), where,
			Palette.REVERSE, func(): join_requested.emit(ip, port))
		_lan_list.add_child(card)
	_lan_empty.visible = hosts.is_empty()
	_lan_count.text = "" if hosts.is_empty() else "%d FOUND" % hosts.size()


# --- Layout -------------------------------------------------------------------

func _build_title() -> void:
	var title := Control.new()
	_title_node = title
	title.position = Vector2(70, 120)
	title.rotation = -0.1
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(title)
	title.add_child(_label("SUPER", 124, Color.WHITE, 16, Vector2(0, 0)))
	# TENET reads the same both ways: forward half, middle, reverse half.
	var word := HBoxContainer.new()
	word.position = Vector2(40, 140)
	word.add_theme_constant_override("separation", 0)
	word.add_child(_label("TE", 124, Palette.FORWARD, 16, Vector2.ZERO))
	word.add_child(_label("N", 124, Palette.SIGNAL, 16, Vector2.ZERO))
	word.add_child(_label("ET", 124, Palette.REVERSE, 16, Vector2.ZERO))
	title.add_child(word)
	title.add_child(_label("TWO PLAYERS.  ONE BULLET.  TIME RUNS BOTH WAYS.", 22, Color.WHITE, 6, Vector2(48, 300)))
	title.add_child(_label("NORMAL  ·  FIRE", 26, Palette.FORWARD, 7, Vector2(48, 344)))
	title.add_child(_label("INVERTED  ·  RECALL", 26, Palette.REVERSE, 7, Vector2(240, 344)))


## The 3 x 3 map grid on the left of the match lobby. It is as tall as the
## lobby panel; the tiles share the panel's slant and each row is shifted
## along it, so the grid's right edge runs parallel to the panel's white edge.
func _build_maps() -> void:
	_maps_node = Control.new()
	_maps_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_maps_node.visible = false
	add_child(_maps_node)
	var mid_y := (PANEL_TOP + PANEL_BOTTOM) * 0.5
	var right := PANEL_LEFT - GRID_MARGIN
	var tile := Vector2((right - GRID_LEFT - 2.0 * GRID_GAP) / 3.0,
		(PANEL_BOTTOM - PANEL_TOP - 2.0 * GRID_GAP) / 3.0)
	for i in MAPS.size():
		var m: Dictionary = MAPS[i]
		var row := i / 3
		var col := i % 3
		var y := PANEL_TOP + row * (tile.y + GRID_GAP)
		var shift := PANEL_SKEW * (mid_y - (y + tile.y * 0.5))
		var b := Button.new()
		b.position = Vector2(GRID_LEFT + col * (tile.x + GRID_GAP) + shift, y)
		b.size = tile
		b.focus_mode = Control.FOCUS_NONE
		# The map's picture fills the tile, cut to its slant; the name sits on top.
		var pic_mat: ShaderMaterial = null
		var path := MAP_PICTURES % m["id"]
		if m["id"] != "" and ResourceLoader.exists(path):
			var pic := TextureRect.new()
			pic.texture = load(path)
			pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			pic.stretch_mode = TextureRect.STRETCH_SCALE
			pic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			pic.offset_left = TILE_INSET
			pic.offset_top = TILE_INSET
			pic.offset_right = -TILE_INSET
			pic.offset_bottom = -TILE_INSET
			pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
			pic_mat = ShaderMaterial.new()
			pic_mat.shader = TileShader
			pic_mat.set_shader_parameter("slant", PANEL_SKEW * (tile.y - 2.0 * TILE_INSET) / (tile.x - 2.0 * TILE_INSET))
			pic.material = pic_mat
			b.add_child(pic)
			var mat := pic_mat
			b.mouse_entered.connect(func(): mat.set_shader_parameter("light", 0.0 if b.disabled else 1.0))
			b.mouse_exited.connect(func(): mat.set_shader_parameter("light", 0.0))
		_map_pics.append(pic_mat)
		var box := VBoxContainer.new()
		box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		box.offset_left = 24
		box.offset_right = -12
		box.offset_top = 10
		box.alignment = BoxContainer.ALIGNMENT_BEGIN
		box.add_theme_constant_override("separation", 0)
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var title := str(m["name"])
		box.add_child(_label(title, 30 if title.length() <= 10 else 22, Color.WHITE, 7, Vector2.ZERO))
		var sub := _label("", 14, PAPER, 4, Vector2.ZERO)
		sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(sub)
		_map_subs.append(sub)
		b.add_child(box)
		var id: String = m["id"]
		b.pressed.connect(func(): map_chosen.emit(id))
		_maps_node.add_child(b)
		_map_tiles.append(b)


## Highlights the chosen map; only the host can click ready maps. Endless
## shows this computer's best room for the current number of players.
func _show_maps(selected: String, is_host: bool, players: int) -> void:
	for i in MAPS.size():
		var m: Dictionary = MAPS[i]
		var b := _map_tiles[i]
		var sub := _map_subs[i]
		var picked: bool = m["id"] == selected and m["id"] != ""
		var fill: Color
		sub.text = m["sub"]
		if m["id"] == "endless":
			var best := endless_best(clampi(players, 2, MAX_PLAYERS))
			if best > 0:
				sub.text += "\nBEST  ·  ROOM %d" % best
		var tier: int = m.get("tier", 0)
		var base: Color = TIER_COLORS[tier - 1] if tier > 0 else Palette.SIGNAL
		if tier > 0 and is_cleared(m["id"]):
			sub.text += "  ·  CLEARED"
		if picked:
			fill = base
		elif m["ready"]:
			fill = base.darkened(0.45)
		elif m["id"] != "":
			fill = Palette.MUTED.darkened(0.3)
			sub.text = "COMING SOON"
		else:
			fill = Palette.INK.lightened(0.12)
			sub.text = ""
		var style := _slanted(fill, 6 if picked else 4, Color.WHITE if picked else Palette.INK, PANEL_SKEW)
		for state in ["normal", "disabled", "pressed"]:
			b.add_theme_stylebox_override(state, style)
		b.add_theme_stylebox_override("hover", _slanted(fill.lightened(0.15), 6 if picked else 4,
			Color.WHITE if picked else Palette.INK, PANEL_SKEW))
		b.disabled = not (is_host and m["ready"]) or picked
		var pic := _map_pics[i]
		if pic != null:
			pic.set_shader_parameter("fill", fill)
			pic.set_shader_parameter("dim", 0.0 if picked else (0.25 if m["ready"] else 0.7))


func _build_panel() -> void:
	var panel := PanelContainer.new()
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = PANEL_LEFT - 1280.0
	panel.offset_right = -40
	panel.offset_top = PANEL_TOP
	panel.offset_bottom = PANEL_BOTTOM - 720.0
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Palette.INK, 0.92)
	sb.border_color = Color.WHITE
	sb.border_width_left = 6
	sb.skew = Vector2(PANEL_SKEW, 0)
	sb.set_content_margin_all(26)
	sb.content_margin_left = 44
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)
	var stack := VBoxContainer.new()
	panel.add_child(stack)
	_menu = _page(stack)
	_join = _page(stack)
	_wait = _page(stack)
	_party = _page(stack)
	_build_menu()
	_build_join()
	_build_wait()
	_build_party()


func _page(parent: Control) -> VBoxContainer:
	var p := VBoxContainer.new()
	p.add_theme_constant_override("separation", 10)
	p.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(p)
	_pages.append(p)
	return p


func _show_page(page: Control) -> void:
	var was_join := _join.visible
	for p in _pages:
		p.visible = p == page
	# In the match lobby the map grid takes the title's place.
	_title_node.visible = page != _party
	_maps_node.visible = page == _party
	if was_join != _join.visible:
		join_page.emit(_join.visible)


func _build_menu() -> void:
	var login := OS.get_environment("USERNAME") if OS.has_feature("windows") else OS.get_environment("USER")
	_name = _field(login.to_upper().left(16), "YOUR NAME")
	_name.max_length = 16
	_menu.add_child(_labelled_row("NAME", _name))

	_menu.add_child(_spacer(4))
	_menu.add_child(_card("PLAY ONLINE", "", Palette.SIGNAL, func():
		_save_settings()
		online_requested.emit(server_address())))
	_server = _field("", "SERVER IP, E.G. 3.120.45.67")
	_server.text_submitted.connect(func(_text: String):
		_save_settings()
		online_requested.emit(server_address()))
	_menu.add_child(_labelled_row("SERVER", _server))

	_menu.add_child(_spacer(14))
	_menu.add_child(_heading("ON THIS NETWORK", Palette.SIGNAL))
	_menu.add_child(_card("HOST A GAME", "", Palette.FORWARD, func():
		_save_settings()
		host_requested.emit(DEFAULT_PORT)))
	_menu.add_child(_card("JOIN A GAME", "", Palette.REVERSE, func():
		_save_settings()
		_show_page(_join)
		_set_message("", false)))

	# EXIT, bottom right.
	var fill := Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_menu.add_child(fill)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	_menu.add_child(row)
	row.add_child(_small_button("EXIT", Palette.DANGER, func():
		_save_settings()
		get_tree().quit()))


func _build_join() -> void:
	var head := HBoxContainer.new()
	head.add_child(_heading("GAMES ON YOUR NETWORK", Palette.SIGNAL))
	var fill := Control.new()
	fill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(fill)
	_lan_count = _heading("", Palette.REVERSE)
	head.add_child(_lan_count)
	_join.add_child(head)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_join.add_child(scroll)
	var list_box := VBoxContainer.new()
	list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list_box)
	_lan_list = VBoxContainer.new()
	_lan_list.add_theme_constant_override("separation", 8)
	list_box.add_child(_lan_list)
	_lan_empty = _label("SCANNING YOUR NETWORK", 18, Palette.MUTED.lightened(0.45), 0, Vector2.ZERO)
	list_box.add_child(_lan_empty)

	_join.add_child(_heading("OR JOIN BY ADDRESS", Palette.MUTED.lightened(0.5)))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_join.add_child(row)
	_address = _field("", "192.168.0.12")
	_address.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_address.text_submitted.connect(func(_text: String): _join_typed())
	row.add_child(_address)
	row.add_child(_small_button("JOIN", Palette.REVERSE, _join_typed))
	_join.add_child(_spacer(6))
	_join.add_child(_small_button("BACK", Palette.MUTED, func(): show_menu("", false)))


func _build_wait() -> void:
	_wait.add_theme_constant_override("separation", 14)
	_wait_title = _label("HOSTING", 72, Palette.FORWARD, 12, Vector2.ZERO)
	_wait.add_child(_wait_title)
	_wait_sub = _label("", 26, Color.WHITE, 6, Vector2.ZERO)
	_wait.add_child(_wait_sub)
	_wait_addresses = _label("", 22, PAPER, 0, Vector2.ZERO)
	_wait.add_child(_wait_addresses)
	# The firewall command is shown in a plain font so it's easy to read and copy.
	_wait_hint = Label.new()
	_wait_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_wait_hint.add_theme_font_override("font", ThemeDB.fallback_font)
	_wait_hint.add_theme_font_size_override("font_size", 15)
	_wait_hint.add_theme_color_override("font_color", Palette.MUTED.lightened(0.55))
	_wait.add_child(_wait_hint)
	var fill := Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_wait.add_child(fill)
	_wait.add_child(_small_button("CANCEL", Palette.DANGER, func(): cancel_requested.emit()))


func _build_party() -> void:
	_party.add_theme_constant_override("separation", 8)
	var header := HBoxContainer.new()
	_party.add_child(header)
	header.add_child(_label("MATCH LOBBY", 44, Palette.SIGNAL, 9, Vector2.ZERO))
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(gap)
	_host_label = _label("", 18, Color.WHITE, 5, Vector2.ZERO)
	_host_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(_host_label)
	_party_info = _heading("", Palette.MUTED.lightened(0.5))
	_party.add_child(_party_info)

	# Two columns: NORMAL and INVERTED.
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 14)
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_party.add_child(cols)
	for r in 2:
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_theme_constant_override("separation", 6)
		cols.add_child(col)
		var head := _label("NORMAL · FIRE" if r == 0 else "INVERTED · RECALL", 22, Palette.role_color(r), 6, Vector2.ZERO)
		col.add_child(head)
		var list := VBoxContainer.new()
		list.add_theme_constant_override("separation", 6)
		col.add_child(list)
		_columns.append(list)
		var join := _small_button("JOIN NORMAL" if r == 0 else "JOIN INVERTED", Palette.role_color(r).darkened(0.35),
			func(): role_chosen.emit(r))
		join.custom_minimum_size.y = 38
		join.add_theme_font_size_override("font_size", 18)
		col.add_child(join)
		_join_buttons.append(join)

	_party_status = _heading("", Palette.MUTED.lightened(0.5))
	_party.add_child(_party_status)
	_options_heading = _heading("MATCH OPTIONS", Palette.MUTED.lightened(0.5))
	_party.add_child(_options_heading)
	_slowmo_button = _small_button("", Palette.MUTED, func(): slowmo_toggled.emit(not _slowmo_on))
	_slowmo_button.add_theme_font_size_override("font_size", 18)
	_slowmo_button.custom_minimum_size.y = 40
	_party.add_child(_slowmo_button)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 12)
	_party.add_child(bottom)
	_ready_button = _small_button("I'M READY", Palette.MUTED, func(): ready_toggled.emit(not _my_ready))
	_ready_button.custom_minimum_size.y = 56
	_ready_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ready_button.add_theme_font_size_override("font_size", 28)
	bottom.add_child(_ready_button)
	var leave := _small_button("LEAVE", Palette.DANGER, func(): cancel_requested.emit())
	leave.custom_minimum_size = Vector2(130, 56)
	bottom.add_child(leave)


func _build_message_strip() -> void:
	_message_strip = PanelContainer.new()
	_message_strip.anchor_top = 1.0
	_message_strip.anchor_bottom = 1.0
	_message_strip.anchor_right = 1.0
	_message_strip.offset_left = 40
	_message_strip.offset_right = -40
	_message_strip.offset_top = -78
	_message_strip.offset_bottom = -24
	add_child(_message_strip)
	_message = Label.new()
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_message.add_theme_font_size_override("font_size", 20)
	_message.add_theme_color_override("font_color", Color.WHITE)
	_message_strip.add_child(_message)


func _set_message(text: String, is_error: bool) -> void:
	_message.text = text.to_upper()
	_message_strip.visible = text != ""
	var sb := StyleBoxFlat.new()
	sb.bg_color = Palette.DANGER if is_error else Palette.INK
	sb.skew = Vector2(0.3, 0)
	sb.content_margin_left = 30
	sb.content_margin_right = 30
	_message_strip.add_theme_stylebox_override("panel", sb)


func _process(delta: float) -> void:
	_t += delta
	var dots := ".".repeat(int(_t * 3.0) % 4)
	if _join.visible and _lan_empty.visible:
		_lan_empty.text = "SCANNING YOUR NETWORK" + dots
	if _wait.visible:
		_wait_sub.text = _wait_sub_base + dots


## Remembers the name and server between runs. The server defaults to the
## project setting game/online_server, so a build can ship with it filled in.
func _load_settings() -> void:
	_server.text = str(ProjectSettings.get_setting("game/online_server", ""))
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS) == OK:
		_server.text = str(cfg.get_value("online", "server", _server.text))
		var saved := str(cfg.get_value("player", "name", ""))
		if saved != "":
			_name.text = saved


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	cfg.set_value("online", "server", server_address())
	cfg.set_value("player", "name", _name.text.strip_edges())
	cfg.save(SETTINGS)


func _join_typed() -> void:
	var text := _address.text.strip_edges()
	if text == "":
		_set_message("Type the host's address first, e.g. 192.168.0.12", true)
		return
	var port := DEFAULT_PORT
	var host := text
	if text.count(":") == 1:
		host = text.get_slice(":", 0)
		port = text.get_slice(":", 1).to_int()
		if port <= 0 or port > 65535:
			port = DEFAULT_PORT
	join_requested.emit(host, port)


# --- Widgets ------------------------------------------------------------------

func _label(text: String, size_px: int, color: Color, outline: int, pos: Vector2) -> Label:
	var l := Label.new()
	l.text = text
	l.position = pos
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", size_px)
	l.add_theme_color_override("font_color", color)
	if outline > 0:
		l.add_theme_color_override("font_outline_color", Palette.INK)
		l.add_theme_constant_override("outline_size", outline)
	return l


## A small label to the left of a compact field.
func _labelled_row(text: String, field: LineEdit) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var l := _heading(text, Palette.MUTED.lightened(0.5))
	l.custom_minimum_size.x = 64
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(l)
	field.custom_minimum_size.y = 38
	field.add_theme_font_size_override("font_size", 18)
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(field)
	return row


func _heading(text: String, color: Color) -> Label:
	return _label(text, 18, color, 0, Vector2.ZERO)


func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size.y = h
	return c


func _slanted(fill: Color, border := 4, border_color := Palette.INK, skew := 0.22) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = border_color
	sb.set_border_width_all(border)
	sb.skew = Vector2(skew, 0)
	sb.content_margin_left = 26
	sb.content_margin_right = 20
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	return sb


func _field(text: String, placeholder: String) -> LineEdit:
	var e := LineEdit.new()
	e.text = text
	e.placeholder_text = placeholder
	e.custom_minimum_size.y = 46
	e.add_theme_font_size_override("font_size", 22)
	e.add_theme_stylebox_override("normal", _slanted(PAPER))
	e.add_theme_stylebox_override("focus", _slanted(Color("fffaf0")))
	e.add_theme_color_override("font_color", Palette.INK)
	e.add_theme_color_override("font_placeholder_color", Palette.MUTED)
	e.add_theme_color_override("caret_color", Palette.INK)
	return e


## Big slanted button; with a subtitle it shows a second, smaller line.
func _card(title: String, subtitle: String, color: Color, on_press: Callable) -> Button:
	var b := Button.new()
	b.custom_minimum_size.y = 70 if subtitle != "" else 60
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_stylebox_override("normal", _slanted(color))
	b.add_theme_stylebox_override("hover", _slanted(color.lightened(0.18)))
	b.add_theme_stylebox_override("pressed", _slanted(color.darkened(0.2)))
	b.pressed.connect(on_press)
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 30
	box.offset_top = 2
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", -10)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_label(title, 32, Color.WHITE, 8, Vector2.ZERO))
	if subtitle != "":
		box.add_child(_label(subtitle, 15, Palette.INK, 0, Vector2.ZERO))
	b.add_child(box)
	return b


func _small_button(text: String, color: Color, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(140, 46)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 24)
	b.add_theme_stylebox_override("normal", _slanted(color))
	b.add_theme_stylebox_override("hover", _slanted(color.lightened(0.18)))
	b.add_theme_stylebox_override("pressed", _slanted(color.darkened(0.2)))
	b.add_theme_stylebox_override("disabled", _slanted(Palette.MUTED.darkened(0.3)))
	b.add_theme_color_override("font_color", Color.WHITE)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_disabled_color", Color(1, 1, 1, 0.6))
	b.add_theme_color_override("font_outline_color", Palette.INK)
	b.add_theme_constant_override("outline_size", 6)
	b.pressed.connect(on_press)
	return b
