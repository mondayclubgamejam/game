extends MultiMeshInstance3D
## A thin glowing polyline (straight shot or recall curve) as one MultiMesh of
## stretched boxes. Updating it only rewrites transforms; nothing is allocated.

const Palette := preload("res://scripts/palette.gd")

const MAX_SEGMENTS := 24
const THICKNESS := 0.014


func _ready() -> void:
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = MAX_SEGMENTS
	multimesh.visible_instance_count = 0
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	custom_aabb = AABB(Vector3(-500, -50, -500), Vector3(1000, 200, 1000))


## Draws points[0] -> points[count - 1].
func show_path(points: PackedVector3Array, count: int, color: Color) -> void:
	material_override = Palette.glow(Color(color, 0.85), 3.0, true)
	var n := 0
	for i in mini(count - 1, MAX_SEGMENTS):
		var a := points[i]
		var b := points[i + 1]
		var d := b - a
		var length := d.length()
		if length < 0.001:
			continue
		var up := Vector3.UP if absf(d.y / length) < 0.98 else Vector3.RIGHT
		var seg_basis := Basis.looking_at(d, up) * Basis.from_scale(Vector3(THICKNESS, THICKNESS, length))
		multimesh.set_instance_transform(n, Transform3D(seg_basis, (a + b) * 0.5))
		n += 1
	multimesh.visible_instance_count = n


func hide_path() -> void:
	multimesh.visible_instance_count = 0
