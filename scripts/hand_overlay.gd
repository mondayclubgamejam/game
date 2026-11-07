extends Control
## Draws the player's gloved hand and pistol over the 3D view, comic style,
## with no art assets. Fire kicks the gun up. Recall plays that kick backwards:
## the hand is yanked forward as the bullet slams back into the barrel.

const OUTLINE := Color("1a1026")
const GLOVE := Color("ff7a1a")
const GLOVE_LIGHT := Color("ffab5e")
const GUN_DARK := Color("2b2140")
const GUN_LIGHT := Color("6d5f8f")
const BARREL := Color("8f86a8")
const FLASH_OUTER := Color("ffd23f")
const FLASH_INNER := Color("fffbe6")
const RECALL_BLUE := Color("2fa8ff")

var player: Node  ## Reads `move_amount` for walk bob.

var kick := 0.0          ## +1 = fire recoil, -1 = recall yank
var flash := 0.0         ## muzzle flash 0..1
var recall_flash := 0.0  ## blue implosion 0..1
var slide_back := 0.0    ## 1 = slide locked back (gun empty)
var shake := 0.0

var _bob_t := 0.0
var _bob := 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	var move := 0.0
	if player and "move_amount" in player:
		move = clampf(player.move_amount, 0.0, 1.8)
	_bob = lerpf(_bob, move, delta * 8.0)
	_bob_t += delta * (6.0 + 4.0 * move)
	queue_redraw()


func play_fire() -> void:
	var tw := create_tween().set_parallel(true)
	kick = 0.0
	flash = 1.0
	tw.tween_property(self, "flash", 0.0, 0.12)
	tw.tween_property(self, "slide_back", 1.0, 0.06)
	var k := create_tween()
	k.tween_property(self, "kick", 1.0, 0.04).set_trans(Tween.TRANS_QUAD)
	k.tween_property(self, "kick", 0.0, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func play_recall() -> void:
	var tw := create_tween().set_parallel(true)
	recall_flash = 1.0
	tw.tween_property(self, "recall_flash", 0.0, 0.25)
	tw.tween_property(self, "slide_back", 0.0, 0.06)
	var k := create_tween()
	k.tween_property(self, "kick", -1.0, 0.05).set_trans(Tween.TRANS_QUAD)
	k.tween_property(self, "kick", 0.0, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func play_blocked() -> void:
	var tw := create_tween()
	for i in 4:
		tw.tween_property(self, "shake", 1.0 if i % 2 == 0 else -1.0, 0.04)
	tw.tween_property(self, "shake", 0.0, 0.04)


func _draw() -> void:
	if size.y < 1.0:
		return
	var s := size.y / 720.0
	var bob := Vector2(sin(_bob_t) * 14.0, absf(cos(_bob_t)) * 10.0) * _bob
	var origin := Vector2(size.x * 0.6, size.y + 30.0 * s) \
		+ (bob + Vector2(shake * 18.0, kick * 70.0)) * s
	var rot := -0.1 - kick * 0.2
	var sc := s * (1.0 - kick * 0.12)
	draw_set_transform(origin, rot, Vector2(sc, sc))

	var top := -300.0 + slide_back * 45.0

	# Recall: blue rings collapsing into the barrel.
	if recall_flash > 0.0:
		for i in 3:
			var radius := 30.0 + (recall_flash + i * 0.3) * 110.0
			var col := RECALL_BLUE
			col.a = recall_flash
			draw_arc(Vector2(0, -320), radius, 0, TAU, 32, col, 10.0)

	# Barrel (shows when the slide is locked back), then the slide over it.
	_poly([Vector2(-16, -120), Vector2(-16, -308), Vector2(16, -308), Vector2(16, -120)], BARREL)
	_ellipse(Vector2(0, -308), Vector2(14, 6), OUTLINE)
	_poly([Vector2(-50, -110), Vector2(-36, top), Vector2(36, top), Vector2(50, -110)], GUN_DARK)
	_poly([Vector2(-12, -118), Vector2(-9, top + 10), Vector2(9, top + 10), Vector2(12, -118)],
		GUN_LIGHT, 0.0)
	if slide_back > 0.5:
		# Exposed chamber glows orange when empty.
		_poly([Vector2(-10, top - 4), Vector2(-10, top - 40), Vector2(10, top - 40),
			Vector2(10, top - 4)], GLOVE, 4.0)

	# Glove gripping the gun.
	_poly([Vector2(-118, 60), Vector2(-112, -10), Vector2(118, -10), Vector2(124, 60)], OUTLINE)
	draw_line(Vector2(-114, 8), Vector2(120, 8), GLOVE, 6.0)
	_poly([Vector2(-110, -10), Vector2(-100, -70), Vector2(-70, -135), Vector2(-20, -165),
		Vector2(60, -155), Vector2(105, -95), Vector2(112, -10)], GLOVE)
	for x in [-35.0, 5.0, 45.0]:
		draw_line(Vector2(x, -150), Vector2(x - 4, -105), OUTLINE, 5.0)
	_poly([Vector2(-72, -120), Vector2(-98, -178), Vector2(-78, -205), Vector2(-48, -150)],
		GLOVE_LIGHT)

	# Muzzle flash starburst.
	if flash > 0.0:
		_star(Vector2(0, top - 40), 40.0 + 90.0 * flash, 18.0 + 30.0 * flash, FLASH_OUTER)
		_star(Vector2(0, top - 40), 20.0 + 45.0 * flash, 10.0 + 15.0 * flash, FLASH_INNER)

	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _poly(points: Array, fill: Color, outline_w := 6.0) -> void:
	var pts := PackedVector2Array(points)
	draw_colored_polygon(pts, fill)
	if outline_w > 0.0:
		var closed := pts.duplicate()
		closed.append(pts[0])
		draw_polyline(closed, OUTLINE, outline_w, true)


func _ellipse(center: Vector2, radii: Vector2, color: Color) -> void:
	var pts := PackedVector2Array()
	for i in 16:
		var a := TAU * i / 16.0
		pts.append(center + Vector2(cos(a) * radii.x, sin(a) * radii.y))
	draw_colored_polygon(pts, color)


func _star(center: Vector2, outer: float, inner: float, color: Color) -> void:
	var pts := []
	var spikes := 9
	for i in spikes * 2:
		var a := TAU * i / (spikes * 2) + flash
		var r := outer if i % 2 == 0 else inner
		pts.append(center + Vector2(cos(a), sin(a)) * r)
	_poly(pts, color, 5.0)
