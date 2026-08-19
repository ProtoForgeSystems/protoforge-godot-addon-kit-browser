@tool
extends ItemList
## An ItemList whose items can be dragged into the 3D viewport.
##
## The payload is deliberately Godot's own {"type": "files"} shape rather than
## anything custom: the 3D viewport, the FileSystem dock and the scene tree all
## already accept it, so dragging a kit mesh onto the viewport instantiates it
## with the editor's own placement and undo handling. A bespoke payload would
## mean reimplementing all of that badly.

var mesh_paths: PackedStringArray = PackedStringArray()


func _get_drag_data(_at_position: Vector2) -> Variant:
	var selected := get_selected_items()
	if selected.is_empty():
		return null

	var files := PackedStringArray()
	for i in selected:
		if i < mesh_paths.size():
			files.append(mesh_paths[i])
	if files.is_empty():
		return null

	var preview := Label.new()
	preview.text = files[0].get_file() if files.size() == 1 else "%d meshes" % files.size()
	set_drag_preview(preview)
	return {"type": "files", "files": files, "from": self}
