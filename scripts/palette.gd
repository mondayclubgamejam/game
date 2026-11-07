extends RefCounted
## Colours from game-style/STYLE_BRIEF.md and a cache of shared materials, so
## every enemy, wall and effect reuses the same few material objects.

## Comic look: toon light bands plus the ink / halftone post pass
## (shaders/comic.gdshader). Off gives plain smooth shading.
const COMIC := false

const FORWARD := Color("ff7a1a")   ## player A, the shot
const REVERSE := Color("2fa8ff")   ## player B, the recall
const ENEMY := Color("ff2e88")
const SIGNAL := Color("ffcc1a")    ## the gun when loose, titles
const TARGET := Color("ffe14d")
const DANGER := Color("ff3344")
const INK := Color("1a1026")
const WALL := Color("ebe7ef")      ## pale, faintly violet: lets the role and enemy colours pop
const CEILING := Color("f4f2f6")
const FLOOR_A := Color("f1eee9")
const FLOOR_B := Color("e6e1da")
const SKY_TOP := Color("2a1446")
const SKY_HORIZON := Color("ff6fa8")
const STEEL := Color("3a3052")
const BLADE := Color("d8dcec")
const MUTED := Color("6d5f8f")
const CRATE := Color("dcd5ca")
## Enemy weapon colours (belt, weapon accents, HUD tags), by RoomGen.Kind:
## gun = red (ranged danger), sword = blue steel (reads on pale walls), knives = lime.
const KIND_COLORS := [Color("ff3344"), Color("6f7da6"), Color("9bff3a")]
const KIND_NAMES := ["GUN", "SWORD", "KNIVES"]
const KNIFE_BLADE := Color("8b93ad")
const CRATE_EDGE := Color("c4bbad")

static var _toon_cache := {}
static var _glow_cache := {}


## Flat toon material (two or three light bands, no specular).
static func toon(color: Color) -> StandardMaterial3D:
	var key := color.to_rgba32()
	if _toon_cache.has(key):
		return _toon_cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	if COMIC:
		m.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
		m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		m.roughness = 1.0
	else:
		m.roughness = 0.8
	_toon_cache[key] = m
	return m


## Unshaded, emissive and transparent: draws after the ink pass, so effects
## glow and are never outlined.
##
## `xray` draws through walls (used for aim previews, so a blocked recall is
## still visible from behind cover).
static func glow(color: Color, energy := 4.0, xray := false) -> StandardMaterial3D:
	var key := "%d:%f:%s" % [color.to_rgba32(), energy, xray]
	if _glow_cache.has(key):
		return _glow_cache[key]
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = Color(color, 1.0)
	m.emission_energy_multiplier = energy
	m.disable_receive_shadows = true
	m.no_depth_test = xray
	_glow_cache[key] = m
	return m


static func role_color(role: int) -> Color:
	return FORWARD if role == 0 else REVERSE
