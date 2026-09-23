@tool
extends AcceptDialog
## Roots, excluded folders, thumbnail resolution, Index, and the force
## re-index escape hatch.
## The dialog edits Settings directly and emits settings_changed on close,
## which is what makes the dock re-read them.

const Settings := preload("res://addons/kit_browser/settings.gd")

## Index used to share the dock's own rows with Reload, but both act on the
## same roots this dialog configures, so the architect moved Index here.
## Reload itself was removed: Index already ends with a reload, and
## reload() still runs internally on scene changes, so a standalone button
## for it was redundant.
signal index_requested
signal force_reindex_requested
## The dialog closed and something behind it may now be stale. Tiers are the
## visible case: they gate a dock control that stays hidden until someone
## re-reads the setting.
signal settings_changed

var _roots: ItemList
var _resolution: SpinBox
var _tiers: LineEdit
var _excludes: ItemList
var _exclude_name: LineEdit
## Exposed so the dock can disable it while a run is in progress -- run_index
## stays owned by the dock, this dialog only signals the request.
var index_button: Button

## Also owned by the dock while a run is in flight, for the same reason.
var force_button: Button

## Settings as they stood when the dialog opened. Empty until the first popup,
## which guards the close handler: before then the tiers field is empty
## because nothing was loaded into it, not because the user cleared it, and
## storing that would wipe the project's configured tiers. Compared on close,
## so a dialog that was opened and shut with nothing touched -- most closes --
## costs the dock nothing.
var _opened_with := {}
## Set while the dialog closes to hand a run to the dock, which reloads at the
## end of that run anyway. Without it every Index press pays for two full
## passes over every index.json.
var _handing_off := false


func _init() -> void:
	title = "Kit Browser Settings"
	# Tall enough that the roots list below never collapses to zero height
	# (an AcceptDialog shrinks to fit its buttons when nothing else claims
	# space, and an ItemList reports no minimum size of its own).
	min_size = Vector2i(460, 540)
	var box := VBoxContainer.new()
	add_child(box)

	box.add_child(_label("Asset roots — each subfolder of a root is a kit:"))
	_roots = ItemList.new()
	_roots.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# A real floor under the list itself: size_flags_vertical only says it
	# wants to grow into free space, not that it needs any to begin with, so
	# on first open -- before the dialog has been resized by hand -- the
	# roots the user already added were invisible above an empty gap.
	_roots.custom_minimum_size.y = 140
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
	index_button = Button.new()
	index_button.text = "Index"
	index_button.tooltip_text = "Scan the asset roots and render missing thumbnails"
	index_button.pressed.connect(func() -> void:
		_close_for_run()
		index_requested.emit())
	row.add_child(index_button)

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

	var tier_row := HBoxContainer.new()
	box.add_child(tier_row)
	var tier_label := _label("Resolution tiers:")
	tier_label.tooltip_text = ("Comma-separated directory names that are " +
		"resolution tiers of the same asset (e.g. 1K, 2K). Leave empty " +
		"unless your kits use that layout — tiered kits collapse to one " +
		"tile with a tier switch in the dock.")
	tier_row.add_child(tier_label)
	_tiers = LineEdit.new()
	_tiers.placeholder_text = "e.g. 1K, 2K"
	_tiers.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tiers.tooltip_text = tier_label.tooltip_text
	_tiers.text_submitted.connect(func(_t: String) -> void: _store_tiers())
	_tiers.focus_exited.connect(_store_tiers)
	tier_row.add_child(_tiers)

	var exclude_label := _label("Excluded folders — never indexed, never listed:")
	exclude_label.tooltip_text = ("A folder name or glob (Anims, *_old) " +
		"skips every folder of that name below a root. A res:// path skips " +
		"that one folder. Use it for animation clips, audio and other files " +
		"that are not placeable assets.")
	box.add_child(exclude_label)
	_excludes = ItemList.new()
	_excludes.custom_minimum_size.y = 90
	_excludes.tooltip_text = exclude_label.tooltip_text
	box.add_child(_excludes)
	var exclude_row := HBoxContainer.new()
	box.add_child(exclude_row)
	_exclude_name = LineEdit.new()
	_exclude_name.placeholder_text = "Name or glob, e.g. Anims"
	_exclude_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_exclude_name.tooltip_text = exclude_label.tooltip_text
	_exclude_name.text_submitted.connect(func(_t: String) -> void: _add_exclude_name())
	exclude_row.add_child(_exclude_name)
	var add_name := Button.new()
	add_name.text = "Add"
	add_name.pressed.connect(_add_exclude_name)
	exclude_row.add_child(add_name)
	var add_dir := Button.new()
	add_dir.text = "Add folder…"
	add_dir.pressed.connect(_pick_exclude)
	exclude_row.add_child(add_dir)
	var remove_exclude := Button.new()
	remove_exclude.text = "Remove"
	remove_exclude.pressed.connect(_remove_exclude)
	exclude_row.add_child(remove_exclude)

	force_button = Button.new()
	force_button.text = "Force re-index (rebuild all indexes and thumbnails)"
	force_button.pressed.connect(func() -> void:
		_close_for_run()
		force_reindex_requested.emit())
	box.add_child(force_button)

	about_to_popup.connect(_on_about_to_popup)
	# Every way out of this dialog -- OK, the window's close button, Escape --
	# ends in a hide, so that is the one place worth listening to. focus_exited
	# already stores the tiers field in the common case, but not when the field
	# still holds focus as the dialog goes away.
	visibility_changed.connect(_on_visibility_changed)


func _close_for_run() -> void:
	_store_tiers()
	_handing_off = true
	hide()
	_handing_off = false


func _on_about_to_popup() -> void:
	_refresh()
	_opened_with = _current()


func _on_visibility_changed() -> void:
	if visible or _handing_off or _opened_with.is_empty():
		return
	_store_tiers()
	if _current() != _opened_with:
		settings_changed.emit()


## Everything the dock reads back from Settings on a reload.
func _current() -> Dictionary:
	return {
		"roots": Settings.roots(),
		"resolution": Settings.resolution(),
		"tiers": Settings.variant_tiers(),
		"excludes": Settings.excluded_dirs(),
	}


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


func _refresh() -> void:
	_roots.clear()
	for root in Settings.roots():
		_roots.add_item(root)
	_resolution.set_value_no_signal(Settings.resolution())
	_tiers.text = ", ".join(Settings.variant_tiers())
	_excludes.clear()
	for entry in Settings.excluded_dirs():
		_excludes.add_item(entry)


func _store_tiers() -> void:
	var out := PackedStringArray()
	for part in _tiers.text.split(","):
		var trimmed := part.strip_edges()
		if not trimmed.is_empty() and not out.has(trimmed):
			out.append(trimmed)
	if out != Settings.variant_tiers():
		Settings.set_variant_tiers(out)


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


## Stored as typed, trimmed: the field is also how a res:// path the picker
## cannot reach gets in, so it is not restricted to bare names.
func add_exclude(entry: String) -> void:
	var trimmed := entry.strip_edges().rstrip("/")
	if trimmed.is_empty():
		return
	var excludes := Settings.excluded_dirs()
	if not excludes.has(trimmed):
		excludes.append(trimmed)
		Settings.set_excluded_dirs(excludes)
	_refresh()


func _add_exclude_name() -> void:
	add_exclude(_exclude_name.text)
	_exclude_name.clear()


func _pick_exclude() -> void:
	var dialog := EditorFileDialog.new()
	dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
	dialog.access = EditorFileDialog.ACCESS_RESOURCES
	dialog.dir_selected.connect(func(dir: String) -> void:
		add_exclude(dir)
		dialog.queue_free())
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered_ratio(0.5)


func _remove_exclude() -> void:
	var selected := _excludes.get_selected_items()
	if selected.is_empty():
		return
	var excludes := Settings.excluded_dirs()
	excludes.remove_at(selected[0])
	Settings.set_excluded_dirs(excludes)
	_refresh()
