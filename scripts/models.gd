extends RefCounted
## Loads a model built by tools/blender/*.py from assets/models/ and colours
## its parts. Each part is a mesh named for its material (dark, steel,
## accent, ...), so `mats` maps those names to materials.

static var _scenes := {}


## The model's root, or null if that model hasn't been built.
static func build(model: String, mats: Dictionary, cast_shadows := true) -> Node3D:
	if not _scenes.has(model):
		var path := "res://assets/models/%s.glb" % model
		_scenes[model] = load(path) if ResourceLoader.exists(path) else null
	var scene: PackedScene = _scenes[model]
	if scene == null:
		return null
	var root: Node3D = scene.instantiate()
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		if mats.has(mi.name):
			mi.material_override = mats[mi.name]
		if not cast_shadows:
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return root
