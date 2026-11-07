extends Control
## Title screen: host a game, join one found on the LAN, or join by address.
## Also shows the "hosting, waiting for partner" and "connecting" screens.

signal host_requested(port: int)
signal join_requested(address: String, port: int)
signal cancel_requested
signal online_requested(address: String)

const Palette := preload("res://scripts/palette.gd")
const TitleFont := preload("res://assets/fonts/Anton-Regular.ttf")
const BgShader := preload("res://shaders/menu_bg.gdshader")
const DEFAULT_PORT := 7777
const PAPER := Color("f3e9d2")
const SETTINGS := "user://settings.cfg"

var _menu: VBoxContainer
var _wait: VBoxContainer
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
	_menu.visible = true
	_wait.visible = false
	_set_message(message, is_error)


func show_hosting(port: int, ips: Array, hint: String, answering: bool) -> void:
	_menu.visible = false
	_wait.visible = true
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
	_set_message("", false)


func show_busy(text: String, note := "") -> void:
	_menu.visible = false
	_wait.visible = true
	_wait_title.text = "JOINING"
	_wait_title.add_theme_color_override("font_color", Palette.REVERSE)
	_wait_sub_base = text
	_wait_addresses.visible = false
	_wait_hint.visible = false
	_set_message(note, false)


## One JOIN card per game found on the LAN.
func set_lan_hosts(hosts: Array) -> void:
	for child in _lan_list.get_children():
		child.queue_free()
	for h in hosts:
		var ip: String = h["ip"]
		var port: int = h["port"]
		var where := ip if port == DEFAULT_PORT else "%s : %d" % [ip, port]
		var card := _card("JOIN  %s" % str(h["name"]).to_upper(), "YOU PLAY REVERSE  ·  " + where,
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
	title.add_child(_label("ONE GUN", 124, Color.WHITE, 16, Vector2(0, 0)))
	title.add_child(_label("ONE BULLET", 124, Palette.SIGNAL, 16, Vector2(40, 140)))
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

	# Menu page.
	_menu = VBoxContainer.new()
	_menu.add_theme_constant_override("separation", 10)
	_menu.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stack.add_child(_menu)

	var login := OS.get_environment("USERNAME") if OS.has_feature("windows") else OS.get_environment("USER")
	_name = _field(login.to_upper().left(16), "YOUR NAME")
	_name.max_length = 16
	_menu.add_child(_labelled_row("NAME", _name))

	_menu.add_child(_spacer(2))
	_menu.add_child(_card("PLAY ONLINE", "THROUGH THE SERVER  ·  WORKS ON EDUROAM",
		Palette.SIGNAL, func():
			_save_settings()
			online_requested.emit(server_address())))
	_server = _field("", "SERVER IP, E.G. 3.120.45.67")
	_server.text_submitted.connect(func(_text: String):
		_save_settings()
		online_requested.emit(server_address()))
	_menu.add_child(_labelled_row("SERVER", _server))

	_menu.add_child(_spacer(6))
	var lan_head := HBoxContainer.new()
	lan_head.add_child(_heading("ON THIS NETWORK", Palette.SIGNAL))
	var fill := Control.new()
	fill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lan_head.add_child(fill)
	_lan_count = _heading("", Palette.REVERSE)
	lan_head.add_child(_lan_count)
	_menu.add_child(lan_head)

	_menu.add_child(_card("HOST A GAME", "YOU PLAY FORWARD  ·  YOU FIRE THE BULLET", Palette.FORWARD,
		func(): host_requested.emit(DEFAULT_PORT)))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_menu.add_child(scroll)
	var list_box := VBoxContainer.new()
	list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list_box)
	_lan_list = VBoxContainer.new()
	_lan_list.add_theme_constant_override("separation", 8)
	list_box.add_child(_lan_list)
	_lan_empty = _label("SCANNING YOUR NETWORK", 18, Palette.MUTED.lightened(0.45), 0, Vector2.ZERO)
	list_box.add_child(_lan_empty)

	_menu.add_child(_heading("OR JOIN BY ADDRESS", Palette.MUTED.lightened(0.5)))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_menu.add_child(row)
	_address = _field("", "192.168.0.12")
	_address.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_address.text_submitted.connect(func(_text: String): _join_typed())
	row.add_child(_address)
	row.add_child(_small_button("JOIN", Palette.REVERSE, _join_typed))

	# Waiting page (hosting / connecting).
	_wait = VBoxContainer.new()
	_wait.add_theme_constant_override("separation", 14)
	_wait.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stack.add_child(_wait)
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
	var fill2 := Control.new()
	fill2.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_wait.add_child(fill2)
	_wait.add_child(_small_button("CANCEL", Palette.DANGER, func(): cancel_requested.emit()))


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
	if _menu.visible and _lan_empty.visible:
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


func _slanted(fill: Color, border := 4) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = Palette.INK
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


## Big two-line slanted button.
func _card(title: String, subtitle: String, color: Color, on_press: Callable) -> Button:
	var b := Button.new()
	b.custom_minimum_size.y = 70
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_stylebox_override("normal", _slanted(color))
	b.add_theme_stylebox_override("hover", _slanted(color.lightened(0.18)))
	b.add_theme_stylebox_override("pressed", _slanted(color.darkened(0.2)))
	b.pressed.connect(on_press)
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 30
	box.offset_top = 2
	box.add_theme_constant_override("separation", -10)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_label(title, 32, Color.WHITE, 8, Vector2.ZERO))
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
	b.add_theme_color_override("font_color", Color.WHITE)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_outline_color", Palette.INK)
	b.add_theme_constant_override("outline_size", 6)
	b.pressed.connect(on_press)
	return b
