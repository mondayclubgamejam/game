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
signal role_chosen(role: int)
signal ready_toggled(ready: bool)

const Palette := preload("res://scripts/palette.gd")
const TitleFont := preload("res://assets/fonts/Anton-Regular.ttf")
const BgShader := preload("res://shaders/menu_bg.gdshader")
const DEFAULT_PORT := 7777
const PAPER := Color("f3e9d2")
const SETTINGS := "user://settings.cfg"
const READY_COLOR := Color("9bff3a")

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
var _slots: Array[PanelContainer] = []
var _role_buttons: Array[Button] = []
var _ready_button: Button
var _my_ready := false
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


## The match lobby. `members`: [{id, name, role (0 forward / 1 reverse), ready}].
## `info` says whether this is a new game or a return to the same room.
func show_party(members: Array, my_id: int, info: String, note := "") -> void:
	if not _party.visible:
		_show_page(_party)
	_party_info.text = info
	var mine: Dictionary = {}
	for m in members:
		if m["id"] == my_id:
			mine = m
	# My slot first, then my partner's (or an empty slot).
	var ordered: Array = [mine] if not mine.is_empty() else []
	for m in members:
		if m["id"] != my_id:
			ordered.append(m)
	for i in _slots.size():
		_fill_slot(_slots[i], ordered[i] if i < ordered.size() else {}, i == 0)
	var my_role: int = mine.get("role", 0)
	for r in 2:
		var picked := r == my_role
		_role_buttons[r].add_theme_stylebox_override("normal", _slanted(Palette.role_color(r) if picked
			else Palette.role_color(r).darkened(0.55), 6 if picked else 4, Color.WHITE if picked else Palette.INK))
	_my_ready = mine.get("ready", false)
	var full := members.size() >= 2
	_ready_button.disabled = not full
	_ready_button.text = "READY!" if _my_ready else ("I'M READY" if full else "WAITING FOR A PARTNER")
	_ready_button.add_theme_stylebox_override("normal", _slanted(READY_COLOR if _my_ready else Palette.MUTED))
	_set_message(note, false)


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
	title.add_child(_label("FORWARD  ·  FIRE", 26, Palette.FORWARD, 7, Vector2(48, 344)))
	title.add_child(_label("REVERSE  ·  RECALL", 26, Palette.REVERSE, 7, Vector2(260, 344)))


func _build_panel() -> void:
	var panel := PanelContainer.new()
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -560
	panel.offset_right = -40
	panel.offset_top = 36
	panel.offset_bottom = -92
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Palette.INK, 0.92)
	sb.border_color = Color.WHITE
	sb.border_width_left = 6
	sb.skew = Vector2(0.08, 0)
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
	_party.add_child(_label("MATCH LOBBY", 52, Palette.SIGNAL, 10, Vector2.ZERO))
	_party_info = _heading("", Palette.MUTED.lightened(0.5))
	_party.add_child(_party_info)
	for i in 2:
		var slot := PanelContainer.new()
		slot.custom_minimum_size.y = 64
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", -6)
		slot.add_child(box)
		box.add_child(_label("", 28, Color.WHITE, 7, Vector2.ZERO))
		box.add_child(_label("", 16, Palette.INK, 0, Vector2.ZERO))
		_party.add_child(slot)
		_slots.append(slot)

	_party.add_child(_heading("PICK YOUR ROLE", Palette.MUTED.lightened(0.5)))
	var roles := HBoxContainer.new()
	roles.add_theme_constant_override("separation", 12)
	_party.add_child(roles)
	for r in 2:
		var b := _small_button("FORWARD · FIRE" if r == 0 else "REVERSE · RECALL", Palette.role_color(r),
			func(): role_chosen.emit(r))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 20)
		roles.add_child(b)
		_role_buttons.append(b)

	var fill := Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_party.add_child(fill)
	_ready_button = _small_button("I'M READY", Palette.MUTED, func(): ready_toggled.emit(not _my_ready))
	_ready_button.custom_minimum_size.y = 56
	_ready_button.add_theme_font_size_override("font_size", 28)
	_party.add_child(_ready_button)
	_party.add_child(_small_button("LEAVE", Palette.DANGER, func(): cancel_requested.emit()))


## A player's slot: name, role and whether they're ready.
func _fill_slot(slot: PanelContainer, m: Dictionary, is_me: bool) -> void:
	var name_label: Label = slot.get_child(0).get_child(0)
	var info: Label = slot.get_child(0).get_child(1)
	if m.is_empty():
		slot.add_theme_stylebox_override("panel", _slanted(Palette.MUTED.darkened(0.3)))
		name_label.text = "WAITING FOR A PARTNER..."
		info.text = ""
		return
	var role: int = m["role"]
	slot.add_theme_stylebox_override("panel", _slanted(Palette.role_color(role), 4))
	name_label.text = str(m["name"]) + ("  (YOU)" if is_me else "")
	var role_text := "FORWARD · FIRES THE BULLET" if role == 0 else "REVERSE · RECALLS THE BULLET"
	info.text = role_text + ("    ·  READY" if m["ready"] else "    ·  NOT READY")


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


func _slanted(fill: Color, border := 4, border_color := Palette.INK) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = border_color
	sb.set_border_width_all(border)
	sb.skew = Vector2(0.22, 0)
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
