@tool
extends Node
## Offscreen thumbnail renderer: the pipeline's Blender rig, rebuilt on a
## SubViewport so a public user needs nothing but the editor they are in.
## Orthographic 3/4 view, key/fill/rim lights, AABB-fit framing — a 0.1 m
## handle and a 20 m bridge frame identically.

const VIEW_DIR := Vector3(1.0, -1.2, 0.8)
const MARGIN := 1.06
## (euler degrees, energy) per light. Starting values transliterated from
## tools/blender_thumbnail.py's sun rig; the quality gate (side-by-side with
## Blender renders) is what settles them — adjust there, not here first.
const LIGHTS := [
	[Vector3(-50, 0, 40), 1.2],
	[Vector3(-20, 0, -120), 0.5],
	[Vector3(-110, 0, 160), 0.6],
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

	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_viewport.add_child(_camera)
	_camera.current = true

	for light in LIGHTS:
		var sun := DirectionalLight3D.new()
		var deg: Vector3 = light[0]
		sun.rotation_degrees = deg
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
	return _merge_aabb(root, Transform3D.IDENTITY, AABB())


static func _merge_aabb(node: Node, xform: Transform3D, merged: AABB) -> AABB:
	var local := xform
	if node is Node3D:
		local = xform * (node as Node3D).transform
	if node is VisualInstance3D:
		var world := local * (node as VisualInstance3D).get_aabb()
		merged = world if not merged.has_volume() else merged.merge(world)
	for child in node.get_children():
		merged = _merge_aabb(child, local, merged)
	return merged


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
	var packed: Resource = ResourceLoader.load(src)
	if not packed is PackedScene:
		return {"ok": false}
	var scene: Node = (packed as PackedScene).instantiate()
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
