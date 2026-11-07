extends Control
## First-person glove and pistol drawn as flat comic shapes (no art assets).
## The glove takes the player's time colour. Fire kicks the gun up; recall is
## the same motion reversed: the gun is yanked forward as the bullet slams in.

const Palette := preload("res://scripts/palette.gd")

var player: Node = null
var role := 0
var holding := false
var loaded := true

var raise := 0.0      ## 0 = lowered out of view, 1 = up
var kick := 0.0       ## +1 fire recoil, -1 recall yank
var flash := 0.0      ## muzzle starburst
var implode := 0.0    ## blue rings collapsing into the barrel
var _bob_t := 0.0
var _bob := 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	raise = move_toward(raise, 1.0 if holding else 0.0, delta * 5.0)
	var move := 0.0
	if player != null and is_instance_valid(player):
		move = clampf(player.move_amount, 0.0, 1.5)
	_bob = lerpf(_bob, move, delta * 8.0)
	_bob_t += delta * (5.0 + 5.0 * move)
	queue_redraw()


func play_fire() -> void:
	flash = 1.0
	var t := create_tween()
	t.tween_property(self, "kick", 1.0, 0.04)
	t.tween_property(self, "kick", 0.0, 0.32).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	create_tween().tween_property(self, "flash", 0.0, 0.12)


func play_recall_catch() -> void:
	implode = 1.0
	var t := create_tween()
	t.tween_property(self, "kick", -1.0, 0.05)
	t.tween_property(self, "kick", 0.0, 0.36).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	create_tween().tween_property(self, "implode", 0.0, 0.3)


func play_throw() -> void:
	var t := create_tween()
	t.tween_property(self, "kick", -0.8, 0.08)
	t.tween_property(self, "kick", 0.0, 0.2)


func play_catch() -> void:
	raise = 0.4
	kick = 0.5
	create_tween().tween_property(self, "kick", 0.0, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _draw() -> void:
	if raise <= 0.01 or size.y < 1.0:
		return
	var s := size.y / 720.0
	var glove := Palette.role_color(role)
	var bob := Vector2(sin(_bob_t) * 12.0, absf(cos(_bob_t)) * 9.0) * _bob
	var lowered := (1.0 - raise) * 420.0
	var origin := Vector2(size.x * 0.64, size.y + 40.0 * s) + (bob + Vector2(0, lowered + kick * 60.0)) * s
	draw_set_transform(origin, -0.08 - kick * 0.22, Vector2.ONE * s * (1.0 - kick * 0.1))

	if implode > 0.0:
		for i in 3:
			var col := Palette.REVERSE
			col.a = implode
			draw_arc(Vector2(0, -330), 24.0 + (implode + i * 0.35) * 120.0, 0, TAU, 32, col, 9.0)

	# Pistol: slide, barrel tip, sights; the chamber window shows if it's loaded.
	_poly([Vector2(-44, -100), Vector2(-38, -296), Vector2(38, -296), Vector2(44, -100)], Palette.STEEL)
	_poly([Vector2(-20, -296), Vector2(-20, -322), Vector2(20, -322), Vector2(20, -296)], Palette.INK)
	_poly([Vector2(-8, -322), Vector2(-8, -336), Vector2(8, -336), Vector2(8, -322)], Palette.INK, 0.0)
	var chamber := Palette.FORWARD if loaded else Palette.MUTED
	_poly([Vector2(-14, -200), Vector2(-14, -250), Vector2(14, -250), Vector2(14, -200)], chamber, 4.0)
	draw_line(Vector2(-30, -140), Vector2(30, -140), Palette.INK, 4.0)
	draw_line(Vector2(-30, -160), Vector2(30, -160), Palette.INK, 4.0)

	# Glove wrapped round the grip.
	_poly([Vector2(-120, 80), Vector2(-108, -40), Vector2(-60, -126), Vector2(10, -150),
		Vector2(84, -128), Vector2(116, -50), Vector2(122, 80)], glove)
	_poly([Vector2(-120, 80), Vector2(-116, 30), Vector2(122, 30), Vector2(122, 80)], Palette.INK)
	for x in [-50.0, -8.0, 34.0, 72.0]:
		draw_line(Vector2(x, -136 + absf(x) * 0.25), Vector2(x - 6, -86), Palette.INK, 5.0)
	_poly([Vector2(-70, -110), Vector2(-104, -170), Vector2(-86, -196), Vector2(-46, -140)], glove.lightened(0.3))

	if flash > 0.0:
		_star(Vector2(0, -350), 30.0 + 100.0 * flash, 14.0 + 30.0 * flash, Palette.SIGNAL)
		_star(Vector2(0, -350), 14.0 + 50.0 * flash, 8.0 + 14.0 * flash, Color("fffbe6"))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _poly(points: Array, fill: Color, outline := 6.0) -> void:
	var pts := PackedVector2Array(points)
	draw_colored_polygon(pts, fill)
	if outline > 0.0:
		var closed := pts.duplicate()
		closed.append(pts[0])
		draw_polyline(closed, Palette.INK, outline, true)


func _star(c: Vector2, outer: float, inner: float, col: Color) -> void:
	var pts := []
	for i in 18:
		var a := TAU * i / 18.0 + flash * 0.6
		pts.append(c + Vector2(cos(a), sin(a)) * (outer if i % 2 == 0 else inner))
	_poly(pts, col, 4.0)
