@tool
extends AcceptDialog
## Roots, thumbnail resolution, Index, and the force re-index escape hatch.
## The dialog edits Settings directly; the dock re-reads on close.

const Settings := preload("res://addons/kit_browser/settings.gd")

## Index used to share the dock's own rows with Reload, but both act on the
## same roots this dialog configures, so the architect moved Index here.
## Reload itself was removed: Index already ends with a reload, and
## reload() still runs internally on scene changes, so a standalone button
## for it was redundant.
signal index_requested
signal force_reindex_requested

var _roots: ItemList
var _resolution: SpinBox
## Exposed so the dock can disable it while a run is in progress -- run_index
## stays owned by the dock, this dialog only signals the request.
var index_button: Button


func _init() -> void:
	title = "Kit Browser Settings"
	min_size = Vector2i(420, 320)
	var box := VBoxContainer.new()
	add_child(box)

	box.add_child(_label("Asset roots — each subfolder of a root is a kit:"))
	_roots = ItemList.new()
	_roots.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_roots)

	var row := HBoxContainer.new()
	box.add_child(row)
	var add := Button.new()
	add.text = "Add folder…"
	add.pressed.connect(_pick_root)
	row.add_child(add)
	var remove := Button.new()
	remove.text = "Remove"
	remove.pressed.connect(_remove_selected)
	row.add_child(remove)

	var res_row := HBoxContainer.new()
	box.add_child(res_row)
	res_row.add_child(_label("Thumbnail resolution:"))
	_resolution = SpinBox.new()
	_resolution.min_value = 128
	_resolution.max_value = 1024
	_resolution.step = 128
	_resolution.value_changed.connect(
		func(v: float) -> void: Settings.set_resolution(int(v)))
	res_row.add_child(_resolution)

	var action_row := HBoxContainer.new()
	box.add_child(action_row)
	index_button = Button.new()
	index_button.text = "Index"
	index_button.tooltip_text = "Scan the asset roots and render missing thumbnails"
	index_button.pressed.connect(func() -> void:
		hide()
		index_requested.emit())
	action_row.add_child(index_button)

	var force := Button.new()
	force.text = "Force re-index (rebuild all indexes and thumbnails)"
	force.pressed.connect(func() -> void:
		hide()
		force_reindex_requested.emit())
	box.add_child(force)

	about_to_popup.connect(_refresh)


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


func _refresh() -> void:
	_roots.clear()
	for root in Settings.roots():
		_roots.add_item(root)
	_resolution.set_value_no_signal(Settings.resolution())


func _pick_root() -> void:
	var dialog := EditorFileDialog.new()
	dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
	dialog.access = EditorFileDialog.ACCESS_RESOURCES
	dialog.dir_selected.connect(func(dir: String) -> void:
		var roots := Settings.roots()
		if not roots.has(dir):
			roots.append(dir)
			Settings.set_roots(roots)
		_refresh()
		dialog.queue_free())
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered_ratio(0.5)


func _remove_selected() -> void:
	var selected := _roots.get_selected_items()
	if selected.is_empty():
		return
	var roots := Settings.roots()
	roots.remove_at(selected[0])
	Settings.set_roots(roots)
	_refresh()
