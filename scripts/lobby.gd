extends Control
## Host / join screen.

signal host_requested(port: int)
signal join_requested(address: String, port: int)

const Palette := preload("res://scripts/palette.gd")
const DEFAULT_PORT := 7777

var _address: LineEdit
var _port: LineEdit
var _status: Label
var _buttons: Array[Button] = []


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Palette.SKY_TOP
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	box.custom_minimum_size = Vector2(460, 0)
	box.position -= Vector2(230, 220)
	box.add_theme_constant_override("separation", 14)
	add_child(box)

	box.add_child(_label("ONE GUN  ·  ONE BULLET", 46, Palette.SIGNAL))
	box.add_child(_label("HOST PLAYS FORWARD (FIRE)  ·  JOINER PLAYS REVERSE (RECALL)", 14, Color.WHITE))

	_address = _field("127.0.0.1", "Host address")
	box.add_child(_address)
	_port = _field(str(DEFAULT_PORT), "Port")
	box.add_child(_port)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	box.add_child(row)
	row.add_child(_button("HOST  (A)", Palette.FORWARD, func(): host_requested.emit(_port_value())))
	row.add_child(_button("JOIN  (B)", Palette.REVERSE,
		func(): join_requested.emit(_address.text.strip_edges(), _port_value())))

	_status = _label("", 16, Color.WHITE)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)

	var ips: Array[String] = []
	for ip in IP.get_local_addresses():
		if ip.count(".") == 3 and not ip.begins_with("127."):
			ips.append(ip)
	box.add_child(_label("THIS MACHINE:  " + ", ".join(ips), 13, Palette.MUTED.lightened(0.4)))


func set_status(text: String, busy: bool) -> void:
	_status.text = text
	for b in _buttons:
		b.disabled = busy


func _port_value() -> int:
	var p := _port.text.to_int()
	return p if p > 0 and p < 65536 else DEFAULT_PORT


func _label(text: String, size_px: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size_px)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Palette.INK)
	l.add_theme_constant_override("outline_size", maxi(size_px / 6, 2))
	return l


func _field(text: String, placeholder: String) -> LineEdit:
	var e := LineEdit.new()
	e.text = text
	e.placeholder_text = placeholder
	e.custom_minimum_size.y = 42
	e.add_theme_font_size_override("font_size", 20)
	e.add_theme_stylebox_override("normal", _slanted(Color("f3e9d2")))
	e.add_theme_stylebox_override("focus", _slanted(Color("fff6dc")))
	e.add_theme_color_override("font_color", Palette.INK)
	return e


func _button(text: String, color: Color, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size.y = 58
	b.add_theme_font_size_override("font_size", 24)
	b.add_theme_stylebox_override("normal", _slanted(color))
	b.add_theme_stylebox_override("hover", _slanted(color.lightened(0.2)))
	b.add_theme_stylebox_override("pressed", _slanted(color.darkened(0.2)))
	b.add_theme_stylebox_override("disabled", _slanted(Palette.MUTED))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_color_override("font_color", Color.WHITE)
	b.add_theme_color_override("font_outline_color", Palette.INK)
	b.add_theme_constant_override("outline_size", 6)
	b.pressed.connect(on_press)
	_buttons.append(b)
	return b


func _slanted(fill: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = Palette.INK
	sb.set_border_width_all(4)
	sb.skew = Vector2(0.25, 0)
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	return sb
