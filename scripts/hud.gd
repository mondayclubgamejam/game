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
var kinds_left := [0, 0, 0]      ## enemies still standing, by kind (gun, sword, knives)
var team: Array = []             ## teammates: [name, role, alive, has the gun]
var gun_line := ""               ## gun card: who has the gun
var gun_line_col := Color.WHITE
var bullet_line := ""            ## gun card: where the bullet is
var bullet_line_col := Color.WHITE
var gun_loaded := true
var prompt_key := ""             ## under the crosshair: "LMB" ...
var prompt_text := ""            ## ... "FIRE"
var threats: Array = []          ## [angle from straight ahead (rad, + = right), urgency 0..1]
var move := 0.0                  ## how fast we move (crosshair spread)

var _hit_t := 0.0                ## hit marker
var _down_t := 0.0               ## red flash when we go down
var _pop := 0.0                  ## target counter bump
var _shown_targets := -1
var _gun_flash := 0.0            ## gun card flashes when the gun or bullet changes hands
var _last_gun_key := ""
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


func _process(delta: float) -> void:
	_hit_t = maxf(_hit_t - delta, 0.0)
	_down_t = maxf(_down_t - delta * 0.8, 0.0)
	_pop = maxf(_pop - delta * 4.0, 0.0)
	_gun_flash = maxf(_gun_flash - delta * 3.0, 0.0)
	if targets != _shown_targets:
		if _shown_targets >= 0:
			_pop = 1.0
		_shown_targets = targets
	var key := gun_line + bullet_line
	if key != _last_gun_key:
		_last_gun_key = key
		_gun_flash = 1.0
	queue_redraw()


## A kill by our bullet: an X flashes on the crosshair.
func hit() -> void:
	_hit_t = 0.28


## We went down: the screen edges flash red.
func went_down() -> void:
	_down_t = 1.0


## `hold`: seconds the banner stays put between sliding in and out.
func banner(text: String, color: Color, hold := 0.55) -> void:
	_banner_queue.append([text, color, hold])
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
	_banner_tween.tween_interval(item[2])
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

	if _down_t > 0.0:
		_draw_vignette(w, h, Color(Palette.DANGER, 0.55 * _down_t))
	elif not threats.is_empty() and spectating == "":
		var worst := 0.0
		for t in threats:
			worst = maxf(worst, t[1])
		_draw_vignette(w, h, Color(Palette.DANGER, 0.18 * worst * (0.7 + 0.3 * sin(Time.get_ticks_msec() / 70.0))))

	if spectating == "":
		_draw_crosshair(Vector2(w, h) * 0.5, s, role_col)

	_draw_targets(s)
	if tut_title == "":
		# Attempt counter (Endless: room and best), tucked under the targets panel.
		var sub := "ATTEMPT  %d" % attempt if best < 0 else "ROOM %d  ·  BEST %d" % [room_no, best]
		var sub_w := font.get_string_size(sub, HORIZONTAL_ALIGNMENT_LEFT, -1, int(20 * s)).x / s
		_panel(Vector2(36, 112) * s, Vector2(maxf(170.0, sub_w + 56.0), 34) * s, Palette.INK.lightened(0.18))
		_text(sub, Vector2(58, 137) * s, int(20 * s), Palette.SIGNAL, 0)

	# Role tag, top right, sized to the word; teammates listed under it.
	var role_name := "NORMAL" if role == 0 else "INVERTED"
	var word_w := font.get_string_size(role_name, HORIZONTAL_ALIGNMENT_LEFT, -1, int(26 * s)).x
	var tag := Vector2(word_w / s + 64, 46)
	_panel(Vector2(w - (tag.x + 24) * s, 24 * s), tag * s, role_col)
	_text(role_name, Vector2(w - (tag.x - 6) * s, 58 * s), int(26 * s), Color.WHITE, int(7 * s))
	_draw_team(w, s)
	if gun_line != "" and spectating == "":
		_draw_gun_card(h, s)

	if spectating != "":
		_draw_spectating(w, h, s)
	elif tut_title != "":
		_draw_tutorial(w, h, s, role_col)

	var hint := HINT if ping_ms < 0 else "%s     PING %d MS" % [HINT, ping_ms]
	draw_string(font, Vector2(0, h - 10 * s), hint, HORIZONTAL_ALIGNMENT_RIGHT, w - 16 * s,
		int(13 * s), Color(1, 1, 1, 0.8))

	if _banner_x < 1.6:
		_draw_banner(w, h, s)


func _draw_vignette(w: float, h: float, col: Color) -> void:
	var edge := minf(w, h) * 0.16
	var clear := Color(col, 0.0)
	# Four soft bands along the edges.
	draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(w, 0), Vector2(w - edge, edge), Vector2(edge, edge)]),
		PackedColorArray([col, col, clear, clear]))
	draw_polygon(PackedVector2Array([Vector2(0, h), Vector2(edge, h - edge), Vector2(w - edge, h - edge), Vector2(w, h)]),
		PackedColorArray([col, clear, clear, col]))
	draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(edge, edge), Vector2(edge, h - edge), Vector2(0, h)]),
		PackedColorArray([col, clear, clear, col]))
	draw_polygon(PackedVector2Array([Vector2(w, 0), Vector2(w, h), Vector2(w - edge, h - edge), Vector2(w - edge, edge)]),
		PackedColorArray([col, col, clear, clear]))


## Ring in the role colour when the gun will do something, white otherwise,
## with four ticks that spread as you move. Threat arcs, hit marker and the
## action prompt sit around it.
func _draw_crosshair(c: Vector2, s: float, role_col: Color) -> void:
	var ch_col := role_col if can_act else Color.WHITE
	var spread := (14.0 + move * 9.0) * s
	for i in 4:
		var d := Vector2.RIGHT.rotated(i * PI * 0.5)
		draw_line(c + d * spread, c + d * (spread + 7.0 * s), Palette.INK, 5.0 * s)
		draw_line(c + d * spread, c + d * (spread + 7.0 * s), ch_col, 2.0 * s)
	draw_arc(c, 8.0 * s, 0, TAU, 24, Palette.INK, 5.0 * s)
	draw_arc(c, 8.0 * s, 0, TAU, 24, ch_col, 2.0 * s)
	draw_circle(c, 2.2 * s, ch_col)
	# Threats: red arcs pointing at enemies winding up on us, tighter as they near.
	var pulse := 0.6 + 0.4 * sin(Time.get_ticks_msec() / 60.0)
	for t in threats:
		var ang: float = t[0] - PI * 0.5
		var u: float = t[1]
		var r := (70.0 - 22.0 * u) * s
		var half := 0.35 - 0.12 * u
		draw_arc(c, r, ang - half, ang + half, 16, Palette.INK, (9.0 + 6.0 * u) * s)
		draw_arc(c, r, ang - half, ang + half, 16, Color(Palette.DANGER, 0.6 + 0.4 * pulse), (5.0 + 5.0 * u) * s)
		var tip := c + Vector2.from_angle(ang) * (r + 12.0 * s)
		var side := Vector2.from_angle(ang + PI * 0.5) * 7.0 * s
		draw_colored_polygon(PackedVector2Array([tip + Vector2.from_angle(ang) * 9.0 * s, tip + side, tip - side]), Palette.DANGER)
	if _hit_t > 0.0:
		var k := _hit_t / 0.28
		var r0 := (10.0 + 10.0 * (1.0 - k)) * s
		for i in 4:
			var d := Vector2.from_angle(PI * 0.25 + i * PI * 0.5)
			draw_line(c + d * r0, c + d * (r0 + 10.0 * s), Palette.INK, 6.0 * s)
			draw_line(c + d * r0, c + d * (r0 + 10.0 * s), Color(Palette.TARGET, k), 3.0 * s)
	if prompt_key != "":
		var fs := int(15 * s)
		var kw := font.get_string_size(prompt_key, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var tw := font.get_string_size(prompt_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var total := kw + 16.0 * s + 8.0 * s + tw
		var at := c + Vector2(-total * 0.5, 44.0 * s)
		var key_box := Rect2(at - Vector2(0, 15.0 * s), Vector2(kw + 16.0 * s, 21.0 * s))
		draw_rect(key_box, Palette.INK)
		draw_rect(key_box.grow(-2.0 * s), Color(1, 1, 1, 0.92))
		draw_string(font, at + Vector2(8.0 * s, 1.0 * s), prompt_key, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Palette.INK)
		_text(prompt_text, at + Vector2(kw + 24.0 * s, 1.0 * s), fs, ch_col, int(5 * s))


## Top left: the number of targets left, with a pip per enemy coloured by kind.
func _draw_targets(s: float) -> void:
	var bump := 1.0 + 0.18 * _pop
	_panel(Vector2(24, 24) * s, Vector2(250, 54) * s, Palette.ENEMY.lerp(Color.WHITE, _pop * 0.5))
	var label := top_label if top_label != "" else "TARGETS"
	if top_label != "":
		_text(label, Vector2(48, 66) * s, int(34 * s), Color.WHITE, int(8 * s))
		return
	_text(label, Vector2(48, 62) * s, int(22 * s), Color.WHITE, int(6 * s))
	var num := str(targets)
	var fs := int(40 * s * bump)
	_text(num, Vector2(160, 68 + 4 * _pop) * s, fs, Color.WHITE, int(9 * s))
	# Pips: one diamond per enemy left, by kind.
	var x := 40.0
	var total := 0
	for k in 3:
		total += kinds_left[k]
	var step := 13.0 if total <= 16 else 208.0 / total
	for k in 3:
		for i in kinds_left[k]:
			var p := Vector2(x, 94) * s
			var r := 5.5 * s
			var pts := PackedVector2Array([p + Vector2(0, -r), p + Vector2(r, 0), p + Vector2(0, r), p + Vector2(-r, 0)])
			draw_colored_polygon(pts, Palette.KIND_COLORS[k])
			pts.append(pts[0])
			draw_polyline(pts, Palette.INK, 2.0 * s)
			x += step


## Under the role tag: each teammate, their role colour, and who has the gun.
func _draw_team(w: float, s: float) -> void:
	var y := 84.0
	for t in team:
		var col: Color = Palette.role_color(t[1]) if t[2] else Palette.MUTED
		var name: String = t[0]
		var fs := int(17 * s)
		var tw := font.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x / s
		var width := tw + 92.0
		var pos := Vector2(w / s - width - 24.0, y)
		_panel(pos * s, Vector2(width, 30) * s, Palette.INK.lightened(0.12))
		draw_rect(Rect2((pos + Vector2(14, 7)) * s, Vector2(6, 16) * s), col)
		_text(name, (pos + Vector2(28, 21)) * s, fs, Color.WHITE if t[2] else Palette.MUTED.lightened(0.3), 0)
		var icon := (pos + Vector2(width - 30, 15)) * s
		if not t[2]:
			draw_line(icon + Vector2(-5, -5) * s, icon + Vector2(5, 5) * s, Palette.DANGER, 3.0 * s)
			draw_line(icon + Vector2(5, -5) * s, icon + Vector2(-5, 5) * s, Palette.DANGER, 3.0 * s)
		elif t[3]:
			_gun_icon(icon + Vector2(-6, 2) * s, 0.24 * s, gun_loaded)
		y += 36.0


## Bottom left: the gun and the bullet, the two things the whole team tracks.
func _draw_gun_card(h: float, s: float) -> void:
	var pos := Vector2(24, h / s - 108)
	var size := Vector2(300, 74)
	_panel(pos * s, size * s, Palette.INK.lightened(0.08).lerp(Palette.SIGNAL, _gun_flash * 0.35))
	_gun_icon((pos + Vector2(56, 36)) * s, 0.56 * s, gun_loaded)
	_text(gun_line, (pos + Vector2(108, 32)) * s, int(19 * s), gun_line_col, int(5 * s))
	_text(bullet_line, (pos + Vector2(104, 58)) * s, int(16 * s), bullet_line_col, int(4 * s))


## A little revolver: barrel, frame, grip and a cylinder that glows when loaded.
func _gun_icon(at: Vector2, k: float, loaded: bool) -> void:
	var ink := Palette.INK
	var steel := Palette.STEEL.lightened(0.35)
	var barrel := Rect2(at + Vector2(10, -16) * k, Vector2(70, 12) * k)
	draw_rect(barrel.grow(3 * k), ink)
	draw_rect(barrel, steel)
	var frame := PackedVector2Array([at + Vector2(-34, -20) * k, at + Vector2(14, -20) * k,
		at + Vector2(14, 6) * k, at + Vector2(-34, 6) * k])
	var grip := PackedVector2Array([at + Vector2(-34, 0) * k, at + Vector2(-12, 0) * k,
		at + Vector2(-20, 34) * k, at + Vector2(-44, 30) * k])
	for poly in [grip, frame]:
		var outline: PackedVector2Array = poly.duplicate()
		outline.append(poly[0])
		draw_colored_polygon(poly, Color("7a4a2c") if poly == grip else steel)
		draw_polyline(outline, ink, 4.0 * k)
	var drum := at + Vector2(-10, -7) * k
	draw_circle(drum, 15 * k, ink)
	draw_circle(drum, 12 * k, Palette.FORWARD if loaded else Palette.MUTED)
	if loaded:
		draw_circle(drum, 5 * k, Color(1, 0.95, 0.8))


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
