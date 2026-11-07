extends Control
## In-game menu (Esc). The game is shared, so it keeps running behind this.

signal resume_requested
signal roles_requested   ## both players go back to the match lobby, same room
signal leave_requested
signal quit_requested

const Palette := preload("res://scripts/palette.gd")
const TitleFont := preload("res://assets/fonts/Anton-Regular.ttf")


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var th := Theme.new()
	th.default_font = TitleFont
	theme = th
	visible = false

	var dim := ColorRect.new()
	dim.color = Color(Palette.INK, 0.6)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	box.custom_minimum_size = Vector2(420, 0)
	box.position -= Vector2(210, 220)
	box.add_theme_constant_override("separation", 14)
	add_child(box)

	box.add_child(_label("PAUSE", 72, Palette.SIGNAL, 12))
	box.add_child(_label("THE GAME KEEPS RUNNING FOR YOUR PARTNER", 16, Color(1, 1, 1, 0.7), 0))
	box.add_child(_button("RESUME", Palette.FORWARD, func(): resume_requested.emit()))
	box.add_child(_button("CHANGE ROLES", Palette.REVERSE, func(): roles_requested.emit()))
	box.add_child(_button("LEAVE MATCH", Palette.MUTED, func(): leave_requested.emit()))
	box.add_child(_button("QUIT GAME", Palette.DANGER, func(): quit_requested.emit()))


func _label(text: String, size_px: int, color: Color, outline: int) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size_px)
	l.add_theme_color_override("font_color", color)
	if outline > 0:
		l.add_theme_color_override("font_outline_color", Palette.INK)
		l.add_theme_constant_override("outline_size", outline)
	return l


func _button(text: String, color: Color, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size.y = 58
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 30)
	for state in ["normal", "hover", "pressed"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = color.lightened(0.18) if state == "hover" else (color.darkened(0.2) if state == "pressed" else color)
		sb.border_color = Palette.INK
		sb.set_border_width_all(4)
		sb.skew = Vector2(0.22, 0)
		b.add_theme_stylebox_override(state, sb)
	b.add_theme_color_override("font_color", Color.WHITE)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_outline_color", Palette.INK)
	b.add_theme_constant_override("outline_size", 6)
	b.pressed.connect(on_press)
	return b
