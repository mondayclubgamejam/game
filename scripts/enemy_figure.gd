extends RefCounted
## Low-poly humanoid built from flat-shaded (faceted) primitives, posed by
## joint positions. Origin at the feet, facing -Z, about 1.8 m tall.

## Joint positions per pose. Keys: shoulder/elbow/wrist and hip/knee/ankle,
## suffixed _r / _l. The figure's right side is -X (it faces -Z).
const POSES := [
	{  # aim: right arm out, left hand supporting
		"elbow_r": Vector3(-0.17, 1.42, -0.28), "wrist_r": Vector3(-0.09, 1.42, -0.52),
		"elbow_l": Vector3(0.16, 1.30, -0.22), "wrist_l": Vector3(-0.04, 1.38, -0.46),
		"knee_r": Vector3(-0.14, 0.50, 0.08), "ankle_r": Vector3(-0.16, 0.08, 0.22),
		"knee_l": Vector3(0.13, 0.52, -0.12), "ankle_l": Vector3(0.14, 0.08, 0.00),
	},
	{  # stride: mid-step, arms swinging
		"elbow_r": Vector3(-0.25, 1.20, -0.15), "wrist_r": Vector3(-0.22, 1.02, -0.32),
		"elbow_l": Vector3(0.25, 1.20, 0.15), "wrist_l": Vector3(0.22, 1.05, 0.30),
		"knee_r": Vector3(-0.11, 0.50, 0.12), "ankle_r": Vector3(-0.12, 0.20, 0.38),
		"knee_l": Vector3(0.11, 0.55, -0.25), "ankle_l": Vector3(0.12, 0.10, -0.20),
	},
	{  # guard: gun held up at the chest, wide stance
		"elbow_r": Vector3(-0.26, 1.24, -0.14), "wrist_r": Vector3(-0.08, 1.44, -0.30),
		"elbow_l": Vector3(0.25, 1.15, 0.02), "wrist_l": Vector3(0.27, 0.90, -0.06),
		"knee_r": Vector3(-0.17, 0.50, 0.04), "ankle_r": Vector3(-0.21, 0.08, 0.05),
		"knee_l": Vector3(0.17, 0.50, -0.04), "ankle_l": Vector3(0.21, 0.08, -0.05),
	},
]

const SHOULDER_R := Vector3(-0.25, 1.44, 0)
const SHOULDER_L := Vector3(0.25, 1.44, 0)
const HIP_R := Vector3(-0.11, 0.95, 0)
const HIP_L := Vector3(0.11, 0.95, 0)


static func build(parent: Node3D, body: Material, visor: Material, gun: Material,
		pose_index: int) -> void:
	var pose: Dictionary = POSES[pose_index % POSES.size()]

	# Torso: a tapered hexagonal prism, flattened front to back.
	var torso := CylinderMesh.new()
	torso.top_radius = 0.25
	torso.bottom_radius = 0.17
	torso.height = 0.56
	torso.radial_segments = 6
	torso.rings = 1
	_add(parent, torso, Vector3(0, 1.22, 0), body, Vector3(1, 1, 0.62))
	var pelvis := CylinderMesh.new()
	pelvis.top_radius = 0.17
	pelvis.bottom_radius = 0.18
	pelvis.height = 0.2
	pelvis.radial_segments = 6
	pelvis.rings = 1
	_add(parent, pelvis, Vector3(0, 0.95, 0), body, Vector3(1, 1, 0.7))

	# Neck and head.
	_limb(parent, Vector3(0, 1.48, 0), Vector3(0, 1.57, -0.01), 0.06, body)
	var head := SphereMesh.new()
	head.radius = 0.13
	head.height = 0.27
	head.radial_segments = 7
	head.rings = 4
	_add(parent, head, Vector3(0, 1.68, -0.01), body)
	var band := BoxMesh.new()
	band.size = Vector3(0.19, 0.035, 0.05)
	_add(parent, band, Vector3(0, 1.69, -0.105), visor)

	# Arms.
	for side in ["r", "l"]:
		var shoulder: Vector3 = SHOULDER_R if side == "r" else SHOULDER_L
		var elbow: Vector3 = pose["elbow_" + side]
		var wrist: Vector3 = pose["wrist_" + side]
		_limb(parent, shoulder, elbow, 0.075, body)
		_limb(parent, elbow, wrist, 0.06, body)
		var hand := SphereMesh.new()
		hand.radius = 0.055
		hand.height = 0.1
		hand.radial_segments = 5
		hand.rings = 2
		_add(parent, hand, wrist + (wrist - elbow).normalized() * 0.04, body)

	# Legs and feet.
	for side in ["r", "l"]:
		var hip: Vector3 = HIP_R if side == "r" else HIP_L
		var knee: Vector3 = pose["knee_" + side]
		var ankle: Vector3 = pose["ankle_" + side]
		_limb(parent, hip, knee, 0.105, body)
		_limb(parent, knee, ankle, 0.08, body)
		var foot := BoxMesh.new()
		foot.size = Vector3(0.12, 0.08, 0.26)
		_add(parent, foot, ankle + Vector3(0, -0.04, -0.06), body)

	# Pistol in the right hand, pointing along the forearm.
	var wrist_r: Vector3 = pose["wrist_r"]
	var elbow_r: Vector3 = pose["elbow_r"]
	var aim := (wrist_r - elbow_r).normalized()
	var pistol := BoxMesh.new()
	pistol.size = Vector3(0.035, 0.09, 0.17)
	var mi := _add(parent, pistol, wrist_r + aim * 0.09 + Vector3(0, 0.03, 0), gun)
	if absf(aim.y) < 0.99:
		mi.basis = Basis.looking_at(aim, Vector3.UP)


## A low-poly capsule between two joints.
static func _limb(parent: Node3D, a: Vector3, b: Vector3, radius: float, mat: Material) -> void:
	var cap := CapsuleMesh.new()
	cap.radius = radius
	cap.height = a.distance_to(b) + radius * 2.0
	cap.radial_segments = 6
	cap.rings = 1
	var mi := _add(parent, cap, (a + b) / 2.0, mat)
	var d := b - a
	if d.length() > 0.0001:
		mi.quaternion = Quaternion(Vector3.UP, d.normalized())


static func _add(parent: Node3D, mesh: PrimitiveMesh, pos: Vector3, mat: Material,
		scale := Vector3.ONE) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = _faceted(mesh)
	mi.material_override = mat
	parent.add_child(mi)
	mi.position = pos
	mi.scale = scale
	return mi


## Split shared vertices so every triangle gets its own normal: hard facets.
static func _faceted(mesh: PrimitiveMesh) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.create_from(mesh, 0)
	st.deindex()
	st.generate_normals()
	return st.commit()
