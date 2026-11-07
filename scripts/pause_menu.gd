extends Control
## In-game menu (Esc). The game is shared, so it keeps running behind this:
## blurred, with the menu on a slanted panel and the controls beside it.

signal resume_requested
signal roles_requested   ## everyone goes back to the match lobby, same room
signal leave_requested
signal quit_requested

const Palette := preload("res://scripts/palette.gd")
const TitleFont := preload("res://assets/fonts/Anton-Regular.ttf")
const BlurShader := preload("res://shaders/blur.gdshader")

const CONTROLS := [
	["WASD", "MOVE"], ["MOUSE", "LOOK AND AIM"], ["LMB / F", "FIRE (NORMAL) · RECALL (INVERTED)"],
	["RMB / Q", "THROW THE GUN"], ["SPACE", "JUMP"], ["CTRL / C", "CROUCH BEHIND CRATES"],
	["R", "RESTART THE ROOM"], ["ESC", "THIS MENU"],
]

var _panel: Control
var _controls: Control
var _buttons: Array[Button] = []


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var th := Theme.new()
	th.default_font = TitleFont
	theme = th
	visible = false

	var blur := ColorRect.new()
	blur.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var mat := ShaderMaterial.new()
	mat.shader = BlurShader
	blur.material = mat
	add_child(blur)

	_panel = PanelContainer.new()
	_panel.position = Vector2(90, 70)
	_panel.custom_minimum_size = Vector2(470, 580)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Palette.INK, 0.94)
	sb.border_color = Color.WHITE
	sb.border_width_right = 6
	sb.skew = Vector2(0.08, 0)
	sb.set_content_margin_all(34)
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	_panel.add_child(box)
	box.add_child(_label("PAUSED", 78, Palette.SIGNAL, 12))
	box.add_child(_label("THE GAME KEEPS RUNNING FOR YOUR TEAM", 17, Color(1, 1, 1, 0.7), 0))
	var gap := Control.new()
	gap.custom_minimum_size.y = 10
	box.add_child(gap)
	box.add_child(_button("RESUME", Palette.FORWARD, func(): resume_requested.emit()))
	box.add_child(_button("CHANGE ROLES", Palette.REVERSE, func(): roles_requested.emit()))
	box.add_child(_button("LEAVE MATCH", Palette.MUTED, func(): leave_requested.emit()))
	box.add_child(_button("QUIT GAME", Palette.DANGER, func(): quit_requested.emit()))

	_controls = _build_controls()
	add_child(_controls)
	visibility_changed.connect(_on_shown)


func _build_controls() -> Control:
	var card := PanelContainer.new()
	card.position = Vector2(650, 150)
	card.custom_minimum_size = Vector2(540, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Palette.INK, 0.8)
	sb.border_color = Palette.SIGNAL
	sb.border_width_left = 4
	sb.skew = Vector2(0.08, 0)
	sb.set_content_margin_all(26)
	card.add_theme_stylebox_override("panel", sb)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 9)
	card.add_child(box)
	var head := _label("CONTROLS", 30, Color.WHITE, 6)
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	box.add_child(head)
	for c in CONTROLS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 14)
		var key := Label.new()
		key.text = c[0]
		key.custom_minimum_size.x = 120
		key.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		key.add_theme_font_size_override("font_size", 17)
		key.add_theme_color_override("font_color", Palette.INK)
		var cap := StyleBoxFlat.new()
		cap.bg_color = Color(1, 1, 1, 0.92)
		cap.border_color = Palette.INK
		cap.set_border_width_all(2)
		cap.border_width_bottom = 5
		cap.set_corner_radius_all(4)
		cap.content_margin_top = 2
		cap.content_margin_bottom = 2
		key.add_theme_stylebox_override("normal", cap)
		row.add_child(key)
		var what := Label.new()
		what.text = c[1]
		what.add_theme_font_size_override("font_size", 18)
		what.add_theme_color_override("font_color", Color.WHITE)
		row.add_child(what)
		box.add_child(row)
	return card


## Slide the panel in from the left and the controls from the right.
func _on_shown() -> void:
	if not visible:
		return
	_panel.position.x = 20
	_panel.modulate.a = 0.0
	_controls.position.x = 720
	_controls.modulate.a = 0.0
	var tw := create_tween().set_parallel()
	tw.tween_property(_panel, "position:x", 90.0, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_panel, "modulate:a", 1.0, 0.15)
	tw.tween_property(_controls, "position:x", 650.0, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT).set_delay(0.05)
	tw.tween_property(_controls, "modulate:a", 1.0, 0.2).set_delay(0.05)


func _label(text: String, size_px: int, color: Color, outline: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size_px)
	l.add_theme_color_override("font_color", color)
	if outline > 0:
		l.add_theme_color_override("font_outline_color", Palette.INK)
		l.add_theme_constant_override("outline_size", outline)
	return l


func _button(text: String, color: Color, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size.y = 62
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.add_theme_font_size_override("font_size", 32)
	for state in ["normal", "hover", "pressed"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = color.lightened(0.18) if state == "hover" else (color.darkened(0.2) if state == "pressed" else color)
		sb.border_color = Color.WHITE if state == "hover" else Palette.INK
		sb.set_border_width_all(4)
		sb.skew = Vector2(0.22, 0)
		sb.content_margin_left = 30
		b.add_theme_stylebox_override(state, sb)
	b.add_theme_color_override("font_color", Color.WHITE)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_outline_color", Palette.INK)
	b.add_theme_constant_override("outline_size", 6)
	b.pressed.connect(on_press)
	b.resized.connect(func(): b.pivot_offset = b.size * 0.5)
	b.mouse_entered.connect(func(): _scale(b, 1.04))
	b.mouse_exited.connect(func(): _scale(b, 1.0))
	_buttons.append(b)
	return b


func _scale(c: Control, to: float) -> void:
	c.create_tween().tween_property(c, "scale", Vector2.ONE * to, 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
