extends Control
## Comic HUD: slanted ink-bordered panels, crosshair, world markers for the
## partner / gun / bullet, and cut-in banners that slash across the screen.

const Palette := preload("res://scripts/palette.gd")

const HINT := "WASD MOVE   MOUSE AIM   LMB FIRE / RECALL   RMB THROW   R RESTART ROOM   ESC MOUSE"

var font: Font

# Set by the game every frame.
var role := 0
var status_text := ""
var status_caption := ""
var status_color := Palette.MUTED
var can_act := false
var targets := 0
var ping_ms := -1
var markers: Array = []          ## [Vector2 pos, Color, String label, bool on_screen]

var _banner_text := ""
var _banner_color := Palette.FORWARD
var _banner_x := 2.0
var _banner_queue: Array = []
var _banner_tween: Tween


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Anton", "Impact", "Arial Black", "Montserrat", "DejaVu Sans"])
	f.font_weight = 900
	font = f


func _process(_delta: float) -> void:
	queue_redraw()


func banner(text: String, color: Color) -> void:
	_banner_queue.append([text, color])
	if _banner_tween == null or not _banner_tween.is_running():
		_next_banner()


func clear_banners() -> void:
	_banner_queue.clear()
	if _banner_tween:
		_banner_tween.kill()
	_banner_x = 2.0


func _next_banner() -> void:
	if _banner_queue.is_empty():
		return
	var item: Array = _banner_queue.pop_front()
	_banner_text = item[0]
	_banner_color = item[1]
	_banner_x = -1.6
	_banner_tween = create_tween()
	_banner_tween.tween_property(self, "_banner_x", 0.0, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_banner_tween.tween_interval(0.55)
	_banner_tween.tween_property(self, "_banner_x", 1.6, 0.14).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_banner_tween.tween_callback(_next_banner)


func _draw() -> void:
	var w := size.x
	var h := size.y
	if h < 1.0:
		return
	var s := h / 720.0
	var role_col := Palette.role_color(role)

	for m in markers:
		_draw_marker(m[0], m[1], m[2], m[3], s)

	# Crosshair: role colour when the gun will do something, white otherwise.
	var c := Vector2(w, h) * 0.5
	var ch_col := role_col if can_act else Color.WHITE
	draw_arc(c, 9.0 * s, 0, TAU, 24, Palette.INK, 5.0 * s)
	draw_arc(c, 9.0 * s, 0, TAU, 24, ch_col, 2.0 * s)
	draw_circle(c, 2.2 * s, ch_col)

	# Targets, top left.
	_panel(Vector2(24, 24) * s, Vector2(250, 54) * s, Palette.ENEMY)
	_text("TARGETS  %d" % targets, Vector2(48, 66) * s, int(34 * s), Color.WHITE, int(8 * s))

	# Role tag, top right.
	var role_name := "FORWARD  ·  A" if role == 0 else "REVERSE  ·  B"
	var role_sub := "YOU CAN ONLY FIRE" if role == 0 else "YOU CAN ONLY RECALL"
	_panel(Vector2(w - 330 * s, 24 * s), Vector2(306, 70) * s, role_col)
	_text(role_name, Vector2(w - 300 * s, 62 * s), int(30 * s), Color.WHITE, int(8 * s))
	_text(role_sub, Vector2(w - 296 * s, 84 * s), int(15 * s), Palette.INK, 0)

	# Gun status, bottom left.
	_panel(Vector2(24, h / s - 120) * s, Vector2(360, 96) * s, status_color)
	_text(status_caption, Vector2(72, h / s - 92) * s, int(17 * s), Palette.INK, 0)
	_text(status_text, Vector2(58, h / s - 44) * s, int(46 * s), Color.WHITE, int(11 * s))

	var hint := HINT if ping_ms < 0 else "%s     PING %d MS" % [HINT, ping_ms]
	draw_string(font, Vector2(0, h - 10 * s), hint, HORIZONTAL_ALIGNMENT_RIGHT, w - 16 * s,
		int(13 * s), Color(1, 1, 1, 0.8))

	if _banner_x < 1.6:
		_draw_banner(w, h, s)


func _draw_marker(p: Vector2, col: Color, label: String, on_screen: bool, s: float) -> void:
	var r := 9.0 * s
	var pts := PackedVector2Array([p + Vector2(0, -r), p + Vector2(r, 0), p + Vector2(0, r), p + Vector2(-r, 0)])
	if not on_screen:
		pts = PackedVector2Array([p + Vector2(0, -r * 1.3), p + Vector2(r * 1.3, r), p + Vector2(-r * 1.3, r)])
	draw_colored_polygon(pts, col)
	var closed := pts.duplicate()
	closed.append(pts[0])
	draw_polyline(closed, Palette.INK, 3.0 * s)
	_text(label, p + Vector2(r + 4 * s, -r), int(15 * s), col, int(5 * s))


## Parallelogram with a thick ink border and flat fill.
func _panel(pos: Vector2, sz: Vector2, fill: Color) -> void:
	var slant := sz.y * 0.32
	var outer := PackedVector2Array([pos + Vector2(slant, 0), pos + Vector2(sz.x, 0),
		pos + Vector2(sz.x - slant, sz.y), pos + Vector2(0, sz.y)])
	draw_colored_polygon(outer, Palette.INK)
	var b := sz.y * 0.09
	var inner := PackedVector2Array([pos + Vector2(slant + b, b), pos + Vector2(sz.x - b * 1.4, b),
		pos + Vector2(sz.x - slant - b, sz.y - b), pos + Vector2(b * 1.4, sz.y - b)])
	draw_colored_polygon(inner, fill)


func _text(t: String, pos: Vector2, fs: int, col: Color, outline: int) -> void:
	if outline > 0:
		draw_string_outline(font, pos, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, outline, Palette.INK)
	draw_string(font, pos, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


func _draw_banner(w: float, h: float, s: float) -> void:
	# High and compact so it never covers the crosshair.
	draw_set_transform(Vector2(w * (0.5 + _banner_x), h * 0.3), -0.07, Vector2(s, s) * 0.5)
	var half := 1200.0
	draw_colored_polygon(PackedVector2Array([Vector2(-half, -104), Vector2(half, -124),
		Vector2(half, 104), Vector2(-half, 124)]), Palette.INK)
	draw_colored_polygon(PackedVector2Array([Vector2(-half, -86), Vector2(half, -104),
		Vector2(half, 84), Vector2(-half, 102)]), _banner_color)
	draw_colored_polygon(PackedVector2Array([Vector2(-half, 64), Vector2(half, 46),
		Vector2(half, 58), Vector2(-half, 76)]), Color(1, 1, 1, 0.9))
	var fs := 116
	while fs > 36 and font.get_string_size(_banner_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > 1000:
		fs -= 8
	var tw := font.get_string_size(_banner_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	_text(_banner_text, Vector2(-tw * 0.5, fs * 0.36), fs, Color.WHITE, 20)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
