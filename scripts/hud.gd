extends Control
## Comic-style HUD: slanted status panels, a crosshair, and cut-in banners
## that swipe across the screen for big moments.

const OUTLINE := Color("1a1026")
const ORANGE := Color("ff7a1a")
const BLUE := Color("2fa8ff")
const MAGENTA := Color("ff2e88")
const YELLOW := Color("ffcc1a")
const RED := Color("ff3344")
const GREY := Color("6d5f8f")

const HINT := "ARROWS move / turn    A D strafe    SHIFT run    SPACE fire / recall    R restart"

var font: Font
var state_text := "LOADED"
var state_color := ORANGE
var targets := 0

var banner_x := -1.5
var _banner_text := ""
var _banner_color := ORANGE
var _queue: Array = []
var _busy := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	font = ThemeDB.fallback_font


func _process(_delta: float) -> void:
	queue_redraw()


func set_state(state: int) -> void:
	# Matches the enum order in player.gd: LOADED, FLYING_OUT, LODGED, FLYING_BACK
	match state:
		0:
			state_text = "LOADED"
			state_color = ORANGE
		1:
			state_text = "FIRING"
			state_color = ORANGE
		2:
			state_text = "EMPTY"
			state_color = GREY
		3:
			state_text = "RETURN"
			state_color = BLUE


func cutin(text: String, color: Color) -> void:
	_queue.append([text, color])
	if not _busy:
		_next_banner()


func _next_banner() -> void:
	if _queue.is_empty():
		_busy = false
		return
	_busy = true
	var item: Array = _queue.pop_front()
	_banner_text = item[0]
	_banner_color = item[1]
	banner_x = -1.5
	var tw := create_tween()
	tw.tween_property(self, "banner_x", 0.0, 0.2) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(0.6)
	tw.tween_property(self, "banner_x", 1.5, 0.16) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(_next_banner)


func _draw() -> void:
	if size.y < 1.0:
		return
	var w := size.x
	var h := size.y
	var s := h / 720.0

	_draw_crosshair(Vector2(w, h) / 2.0, s)

	# Bullet status, bottom left.
	draw_set_transform(Vector2(28 * s, h - 28 * s), 0.0, Vector2(s, s))
	_poly([Vector2(0, 0), Vector2(30, -96), Vector2(330, -96), Vector2(300, 0)], OUTLINE)
	_poly([Vector2(10, -8), Vector2(35, -88), Vector2(318, -88), Vector2(293, -8)], state_color)
	_text("BULLET", Vector2(44, -64), 20, OUTLINE, 0)
	_text(state_text, Vector2(40, -18), 54, Color.WHITE, 12)

	# Targets left, top left.
	draw_set_transform(Vector2(28 * s, 92 * s), 0.0, Vector2(s, s))
	_poly([Vector2(0, 0), Vector2(22, -66), Vector2(290, -66), Vector2(268, 0)], OUTLINE)
	_poly([Vector2(9, -7), Vector2(27, -59), Vector2(279, -59), Vector2(261, -7)], MAGENTA)
	_text("TARGETS  %d" % targets, Vector2(36, -16), 40, Color.WHITE, 10)

	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	draw_string(font, Vector2(0, h - 12 * s), HINT, HORIZONTAL_ALIGNMENT_RIGHT,
		w - 20 * s, int(15 * s), Color(1, 1, 1, 0.75))

	if _busy:
		_draw_banner(w, h, s)


func _draw_banner(w: float, h: float, s: float) -> void:
	draw_set_transform(Vector2(w * 0.5 + banner_x * w, h * 0.38), -0.1, Vector2(s, s))
	_poly([Vector2(-1100, -95), Vector2(1100, -120), Vector2(1100, 95), Vector2(-1100, 120)],
		OUTLINE, 0.0)
	_poly([Vector2(-1100, -78), Vector2(1100, -100), Vector2(1100, 78), Vector2(-1100, 100)],
		_banner_color, 0.0)
	_poly([Vector2(-1100, 62), Vector2(1100, 40), Vector2(1100, 52), Vector2(-1100, 74)],
		Color.WHITE, 0.0)
	var fs := 120
	while fs > 40 and font.get_string_size(_banner_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > 1100:
		fs -= 8
	var tw := font.get_string_size(_banner_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	_text(_banner_text, Vector2(-tw / 2.0, fs * 0.36), fs, Color.WHITE, 22)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_crosshair(c: Vector2, s: float) -> void:
	var gap := 6.0 * s
	var arm := 14.0 * s
	for d in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
		draw_line(c + d * gap, c + d * (gap + arm), OUTLINE, 6.0 * s)
	for d in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
		draw_line(c + d * gap, c + d * (gap + arm), Color.WHITE, 2.5 * s)


func _text(text: String, pos: Vector2, fs: int, color: Color, outline: int) -> void:
	if outline > 0:
		draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, outline, OUTLINE)
	draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, color)


func _poly(points: Array, fill: Color, outline_w := 5.0) -> void:
	var pts := PackedVector2Array(points)
	draw_colored_polygon(pts, fill)
	if outline_w > 0.0:
		var closed := pts.duplicate()
		closed.append(pts[0])
		draw_polyline(closed, OUTLINE, outline_w, true)
