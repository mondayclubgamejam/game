extends Control
## Comic HUD: slanted ink-bordered panels, crosshair, world markers for the
## partner / gun / bullet, and cut-in banners that slash across the screen.

const Palette := preload("res://scripts/palette.gd")

const HINT := "WASD MOVE   SPACE JUMP   CTRL CROUCH   LMB FIRE / RECALL   RMB THROW   R RESTART   ESC MOUSE"

var font: Font

# Set by the game every frame.
var role := 0
var can_act := false
var targets := 0
var attempt := 1
var room_no := 1
var best := -1                   ## Endless: best room reached (-1 outside Endless)
var top_label := ""              ## replaces "TARGETS n" (tutorials)
var tut_title := ""              ## tutorial panel: step title ("" = no panel)
var tut_text := ""               ## tutorial panel: what to do in this step
var tut_hint := ""               ## tutorial panel: what to do right now
var ping_ms := -1
var markers: Array = []          ## [Vector2 pos, Color, String label, bool on_screen]
var spectating := ""             ## while dead: the teammate being watched
var slowmo := 0.0                ## 0 normal time .. 1 full slow motion

var _banner_text := ""
var _banner_color := Palette.FORWARD
var _banner_x := 2.0
var _banner_queue: Array = []
var _banner_tween: Tween


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Bundled, so text looks the same everywhere and needs no system fonts.
	font = preload("res://assets/fonts/Anton-Regular.ttf")


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

	if slowmo > 0.2:
		_draw_slowmo(w, s)

	for m in markers:
		_draw_marker(m[0], m[1], m[2], m[3], s)

	# Crosshair: role colour when the gun will do something, white otherwise.
	# None while spectating: there's nothing to aim.
	var c := Vector2(w, h) * 0.5
	if spectating != "":
		c = Vector2(-1000, -1000)
	var ch_col := role_col if can_act else Color.WHITE
	draw_arc(c, 9.0 * s, 0, TAU, 24, Palette.INK, 5.0 * s)
	draw_arc(c, 9.0 * s, 0, TAU, 24, ch_col, 2.0 * s)
	draw_circle(c, 2.2 * s, ch_col)

	# Targets, top left.
	_panel(Vector2(24, 24) * s, Vector2(250, 54) * s, Palette.ENEMY)
	_text(top_label if top_label != "" else "TARGETS  %d" % targets, Vector2(48, 66) * s, int(34 * s), Color.WHITE, int(8 * s))
	# Attempt counter (Endless: room and best), tucked under the targets panel.
	if tut_title == "":
		var sub := "ATTEMPT  %d" % attempt if best < 0 else "ROOM %d  ·  BEST %d" % [room_no, best]
		var sub_w := font.get_string_size(sub, HORIZONTAL_ALIGNMENT_LEFT, -1, int(20 * s)).x / s
		_panel(Vector2(36, 84) * s, Vector2(maxf(170.0, sub_w + 56.0), 34) * s, Palette.INK.lightened(0.18))
		_text(sub, Vector2(58, 109) * s, int(20 * s), Palette.SIGNAL, 0)

	# Role tag, top right, sized to the word.
	var role_name := "NORMAL" if role == 0 else "INVERTED"
	var word_w := font.get_string_size(role_name, HORIZONTAL_ALIGNMENT_LEFT, -1, int(26 * s)).x
	var tag := Vector2(word_w / s + 64, 46)
	_panel(Vector2(w - (tag.x + 24) * s, 24 * s), tag * s, role_col)
	_text(role_name, Vector2(w - (tag.x - 6) * s, 58 * s), int(26 * s), Color.WHITE, int(7 * s))

	if spectating != "":
		_draw_spectating(w, h, s)
	elif tut_title != "":
		_draw_tutorial(w, h, s, role_col)

	var hint := HINT if ping_ms < 0 else "%s     PING %d MS" % [HINT, ping_ms]
	draw_string(font, Vector2(0, h - 10 * s), hint, HORIZONTAL_ALIGNMENT_RIGHT, w - 16 * s,
		int(13 * s), Color(1, 1, 1, 0.8))

	if _banner_x < 1.6:
		_draw_banner(w, h, s)


## While dead: whose eyes you're watching through.
func _draw_spectating(w: float, h: float, s: float) -> void:
	var text := "YOU'RE DOWN  ·  WATCHING %s" % spectating
	var fs := int(30 * s)
	var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var size := Vector2(tw / s + 90, 74)
	var pos := Vector2(w * 0.5 - size.x * 0.5 * s, h - 130 * s)
	_panel(pos, size * s, Palette.DANGER)
	_text(text, pos + Vector2(42, 40) * s, fs, Color.WHITE, int(7 * s))
	_text("CLICK FOR THE NEXT TEAMMATE", pos + Vector2(46, 62) * s, int(15 * s), Palette.INK, 0)


## Tutorials: the step, what to do in it, and what to do right now.
func _draw_tutorial(w: float, h: float, s: float, role_col: Color) -> void:
	var sizes := [26, 18, 18]
	var lines := [tut_title, tut_text, tut_hint]
	var widest := 0.0
	for i in 3:
		widest = maxf(widest, font.get_string_size(lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, int(sizes[i] * s)).x / s)
	var size := Vector2(widest + 100, 112)
	var pos := Vector2(w * 0.5 - size.x * 0.5 * s, h - 150 * s)
	_panel(pos, size * s, Palette.INK.lightened(0.1))
	_text(tut_title, pos + Vector2(46, 38) * s, int(26 * s), Palette.SIGNAL, int(6 * s))
	_text(tut_text, pos + Vector2(40, 66) * s, int(18 * s), Color.WHITE, 0)
	_text(tut_hint, pos + Vector2(34, 94) * s, int(18 * s), role_col, int(5 * s))


const SLOW_COLOR := Color("8fd3ff")


## A bold banner across the top while time is slowed, gently pulsing.
func _draw_slowmo(w: float, s: float) -> void:
	var a := clampf((slowmo - 0.2) / 0.3, 0.0, 1.0)
	var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 260.0)
	var size := Vector2(380, 62)
	var pos := Vector2(w * 0.5 - size.x * 0.5 * s, 62 * s)
	var outer := PackedVector2Array([pos + Vector2(22, 0) * s, pos + Vector2(size.x, 0) * s,
		pos + Vector2(size.x - 22, size.y) * s, pos + Vector2(0, size.y) * s])
	draw_colored_polygon(outer, Color(Palette.INK, a))
	var inset := PackedVector2Array([pos + Vector2(28, 6) * s, pos + Vector2(size.x - 8, 6) * s,
		pos + Vector2(size.x - 28, size.y - 6) * s, pos + Vector2(8, size.y - 6) * s])
	draw_colored_polygon(inset, Color(SLOW_COLOR.lerp(Color.WHITE, pulse * 0.35), a))
	var text := "TIME SLOWED"
	var fs := int(40 * s)
	var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var at := pos + Vector2(size.x * 0.5 * s - tw * 0.5, 47 * s)
	draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, int(9 * s), Color(Palette.INK, a))
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(Color.WHITE, a))


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
