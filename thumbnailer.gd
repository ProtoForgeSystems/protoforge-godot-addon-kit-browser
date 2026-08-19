@tool
extends Node
## Offscreen thumbnail renderer: the pipeline's Blender rig, rebuilt on a
## SubViewport so a public user needs nothing but the editor they are in.
## Orthographic 3/4 view, key/fill/rim lights, AABB-fit framing — a 0.1 m
## handle and a 20 m bridge frame identically.

## Front-left-above, converted from tools/blender_thumbnail.py's Blender-space
## (Z-up) camera direction via (x, y, z) -> (x, z, -y).
const VIEW_DIR := Vector3(1.0, 0.8, 1.2)
const MARGIN := 1.06
## (travel direction, energy) per light, in Godot space. Starting values
## transliterated from tools/blender_thumbnail.py's sun rig; the quality gate
## (side-by-side with Blender renders) is what settles them — adjust there,
## not here first.
const LIGHTS := [
	[Vector3(0.5, -1.5, -1.0), 1.2],
	[Vector3(-1.5, -0.3, -0.8), 0.5],
	[Vector3(0.3, -1.0, 1.2), 0.6],
]

var _viewport: SubViewport
var _camera: Camera3D
var _subject: Node3D


func setup() -> void:
	_viewport = SubViewport.new()
	_viewport.transparent_bg = true
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)

	# A flat-color sky, not just a flat ambient term: tools/blender_thumbnail.py's
	# background feeds EEVEE's world lighting AND its reflections, and metallic
	# kit materials read as flat black without a reflection source to catch —
	# ambient diffuse alone is not enough. transparent_bg still yields a
	# transparent PNG/webp; the sky only feeds lighting, it is never composited.
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.55, 0.57, 0.62)
	sky_mat.sky_horizon_color = Color(0.55, 0.57, 0.62)
	sky_mat.ground_bottom_color = Color(0.55, 0.57, 0.62)
	sky_mat.ground_horizon_color = Color(0.55, 0.57, 0.62)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.6
	var world := World3D.new()
	world.environment = env
	_viewport.world_3d = world

	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_viewport.add_child(_camera)
	_camera.current = true

	for light in LIGHTS:
		var sun := DirectionalLight3D.new()
		var dir: Vector3 = (light[0] as Vector3).normalized()
		var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.999 else Vector3.FORWARD
		sun.basis = Basis.looking_at(dir, up)
		sun.light_energy = light[1]
		_viewport.add_child(sun)

	_subject = Node3D.new()
	_viewport.add_child(_subject)


## Pure: where the camera goes and how wide it opens for a given bounds box.
static func frame_for(aabb: AABB) -> Dictionary:
	var dir := VIEW_DIR.normalized()
	var basis := Basis.looking_at(-dir, Vector3.UP)
	var center := aabb.get_center()
	var half_w := 0.0
	var half_h := 0.0
	var half_d := 0.0
	for i in 8:
		var corner := aabb.get_endpoint(i) - center
		half_w = maxf(half_w, absf(corner.dot(basis.x)))
		half_h = maxf(half_h, absf(corner.dot(basis.y)))
		half_d = maxf(half_d, absf(corner.dot(basis.z)))
	var size := maxf(half_w, half_h) * 2.0 * MARGIN
	return {
		"basis": basis,
		"position": center + dir * (half_d + size) * 2.0,
		"size": size,
	}


## Merged world-space bounds of every visual instance. Accumulates transforms
## by hand so it works on a tree that is not inside the scene tree.
static func scene_aabb(root: Node) -> AABB:
	var state := _merge_aabb(root, Transform3D.IDENTITY, {"aabb": AABB(), "found": false})
	return state["aabb"]


## Threads {"aabb", "found"} instead of gating on the accumulated AABB's own
## has_volume() — a zero-thickness instance (a flat plane, a decal) produces
## an AABB with no volume, and using that as the "nothing merged yet"
## sentinel would let it get silently replaced by the next instance instead
## of merged.
static func _merge_aabb(node: Node, xform: Transform3D, state: Dictionary) -> Dictionary:
	var local := xform
	if node is Node3D:
		local = xform * (node as Node3D).transform
	if node is VisualInstance3D:
		var world := local * (node as VisualInstance3D).get_aabb()
		if not state["found"]:
			state["aabb"] = world
			state["found"] = true
		else:
			state["aabb"] = (state["aabb"] as AABB).merge(world)
	for child in node.get_children():
		state = _merge_aabb(child, local, state)
	return state


## The index's size convention: w x d x h, Godot Y-up, so h is y and d is z.
static func size_m(aabb: AABB) -> Dictionary:
	return {
		"w": snappedf(aabb.size.x, 0.001),
		"d": snappedf(aabb.size.z, 0.001),
		"h": snappedf(aabb.size.y, 0.001),
	}


## Render one asset to one webp. Coroutine: awaits the draw. Failures return
## ok=false and never throw — a mesh that will not load is the caller's count
## to keep, not this function's problem to solve.
func render_one(src: String, out_path: String, res: int) -> Dictionary:
	var resource: Resource = ResourceLoader.load(src)
	var scene: Node = null
	if resource is PackedScene:
		scene = (resource as PackedScene).instantiate()
	elif resource is Mesh:
		# A bare .obj (or any mesh format with no wrapper scene) imports as an
		# ArrayMesh, not a PackedScene — give it the MeshInstance3D a wrapper
		# would have provided so it renders like everything else.
		var instance := MeshInstance3D.new()
		instance.mesh = resource as Mesh
		scene = instance
	else:
		return {"ok": false}
	if scene == null:
		return {"ok": false}
	_subject.add_child(scene)

	var aabb := scene_aabb(scene)
	if not aabb.has_volume():
		scene.queue_free()
		return {"ok": false}

	var frame := frame_for(aabb)
	_camera.transform = Transform3D(frame["basis"], frame["position"])
	_camera.size = frame["size"]
	_camera.near = 0.01
	_camera.far = (frame["position"] as Vector3).distance_to(aabb.get_center()) \
		+ aabb.get_longest_axis_size() * 2.0
	_viewport.size = Vector2i(res, res)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

	await RenderingServer.frame_post_draw
	var image := _viewport.get_texture().get_image()
	scene.queue_free()

	var abs := ProjectSettings.globalize_path(out_path)
	DirAccess.make_dir_recursive_absolute(abs.get_base_dir())
	var err := image.save_webp(abs, true, 0.9)
	return {"ok": err == OK, "size_m": size_m(aabb)}
