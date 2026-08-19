@tool
extends VBoxContainer
## The Kit Browser dock: filter the merged index, see thumbnails, place meshes.
##
## Every decision about WHAT to show lives in catalog.gd and is tested headless;
## this file is the presentation and the editor wiring.

const Catalog := preload("res://addons/kit_browser/catalog.gd")
const AssetList := preload("res://addons/kit_browser/asset_list.gd")

const ICON_PX := 96
## Thumbnails are .gdignore'd, so they are files on disk rather than imported
## resources and must be decoded by hand. Doing that for 1,575 of them in one
## frame locks the editor, so a budget's worth are decoded per frame instead.
const ICONS_PER_FRAME := 24

var _all: Array = []
## The filtered assets before variants were collapsed -- what a grouped tile
## stands for, and therefore what its right-click menu has to offer.
var _filtered: Array = []
var _shown: Array = []
var _icon_cache: Dictionary = {}
var _pending: Array = []

var _search: LineEdit
var _kit_pick: OptionButton
var _cat_pick: OptionButton
var _bay_pick: OptionButton
var _review_only: CheckBox
var _group_variants: CheckBox
var _list: ItemList
var _status: Label
var _details: Label
var _variants: PopupMenu
var _variant_assets: Array = []


func _ready() -> void:
	name = "Kits"
	_build_ui()
	reload()


func _build_ui() -> void:
	add_theme_constant_override("separation", 4)

	_search = LineEdit.new()
	_search.placeholder_text = "Search name (all terms must match)"
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(_t: String) -> void: _apply())
	add_child(_search)

	# Flow rather than box containers: this is a side dock and the user decides
	# how narrow it gets. Anything that will not fit on a row moves to the next
	# one instead of setting a floor under the whole dock.
	var row := HFlowContainer.new()
	add_child(row)
	_kit_pick = _picker(row, "Kit")
	_cat_pick = _picker(row, "Shelf — what kind of thing it is")
	_bay_pick = _picker(row, "Bay width — pieces that line up with each other")

	var row2 := HFlowContainer.new()
	add_child(row2)
	_review_only = CheckBox.new()
	_review_only.text = "Needs review"
	_review_only.tooltip_text = "Only assets the classifier flagged as uncertain"
	_review_only.toggled.connect(func(_p: bool) -> void: _apply())
	row2.add_child(_review_only)
	_group_variants = CheckBox.new()
	_group_variants.text = "Group variants"
	_group_variants.tooltip_text = "One tile per family, not one per finish"
	_group_variants.button_pressed = true
	_group_variants.toggled.connect(func(_p: bool) -> void: _apply())
	row2.add_child(_group_variants)
	var refresh := Button.new()
	refresh.text = "Reload"
	refresh.tooltip_text = "Re-read every attached kit's index.json"
	refresh.pressed.connect(reload)
	row2.add_child(refresh)

	_list = AssetList.new()
	# Long vendor names are trimmed to the tile rather than widening it. The
	# tooltip carries the full name and taxonomy, so nothing is lost.
	_list.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_list.fixed_column_width = ICON_PX + 24
	_list.max_columns = 0                        # as many columns as fit
	_list.icon_mode = ItemList.ICON_MODE_TOP
	_list.fixed_icon_size = Vector2i(ICON_PX, ICON_PX)
	_list.same_column_width = true
	_list.select_mode = ItemList.SELECT_MULTI
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_selected)
	_list.item_activated.connect(_on_activated)
	_list.item_clicked.connect(_on_clicked)
	add_child(_list)

	_variants = PopupMenu.new()
	_variants.id_pressed.connect(_on_variant_chosen)
	add_child(_variants)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 11)
	add_child(_status)

	_details = Label.new()
	_details.add_theme_font_size_override("font_size", 11)
	_details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_details.custom_minimum_size.y = 34
	add_child(_details)


## A filter dropdown that does not hold the dock open.
##
## fit_to_longest_item defaults to true, so a picker reserves room for its
## longest entry even when a short one is selected. Three of them did that at
## once and pinned the dock to 727 px: "LaylaDesign/Megastructure_Scifi_World"
## alone claimed 337 of it.
func _picker(parent: Node, tip: String) -> OptionButton:
	var picker := OptionButton.new()
	picker.fit_to_longest_item = false
	picker.clip_text = true
	picker.custom_minimum_size.x = 84
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.set_meta("hint", tip)
	picker.tooltip_text = tip
	picker.item_selected.connect(func(_i: int) -> void: _apply())
	parent.add_child(picker)
	return picker


## Clipped text hides which value is selected, so the tooltip has to carry it.
func _retip(picker: OptionButton) -> void:
	var hint: String = picker.get_meta("hint", "")
	var chosen := picker.get_item_text(picker.selected) if picker.selected >= 0 else ""
	picker.tooltip_text = hint if chosen.is_empty() else "%s\n%s" % [hint, chosen]


## The editor opened, closed or switched scenes.
func on_scene_changed(_root: Node = null) -> void:
	_refresh_status()


## Re-read the index from disk and rebuild the facet dropdowns.
func reload() -> void:
	_all = Catalog.load_assets()
	_icon_cache.clear()
	_fill_picker(_kit_pick, "All kits", Catalog.kits_of(_all))
	_fill_picker(_cat_pick, "All shelves", Catalog.shelves_of(_all))
	_fill_picker(_bay_pick, "All bays", Catalog.bays_of(_all))
	_apply()


func _fill_picker(picker: OptionButton, all_label: String, values: PackedStringArray) -> void:
	var previous := picker.get_item_text(picker.selected) if picker.selected >= 0 else ""
	picker.clear()
	picker.add_item(all_label)
	for v in values:
		picker.add_item(v)
	# Keep the user's choice across a reload where possible; losing the filter
	# on every refresh makes the button useless during iteration.
	for i in picker.item_count:
		if picker.get_item_text(i) == previous:
			picker.select(i)
			_retip(picker)
			return
	picker.select(0)
	_retip(picker)


func _picked(picker: OptionButton) -> String:
	return "" if picker.selected <= 0 else picker.get_item_text(picker.selected)


func _apply() -> void:
	for picker in [_kit_pick, _cat_pick, _bay_pick]:
		_retip(picker)
	_filtered = Catalog.filter(_all, _search.text, _picked(_kit_pick),
		_picked(_cat_pick), _review_only.button_pressed, _picked(_bay_pick))
	_shown = (Catalog.collapse_families(_filtered)
		if _group_variants.button_pressed else _filtered)
	_populate()


func _populate() -> void:
	_list.clear()
	_pending.clear()
	var paths := PackedStringArray()
	for i in _shown.size():
		var asset: Dictionary = _shown[i]
		var siblings: int = asset.get("family_count", 0)
		var idx := _list.add_item(_caption(asset.get("name", "?"), siblings))
		_list.set_item_tooltip(idx, Catalog.describe(asset))
		paths.append(asset.get("path", ""))

		var thumb := Catalog.thumbnail_path(asset)
		if thumb.is_empty():
			continue
		if _icon_cache.has(thumb):
			_list.set_item_icon(idx, _icon_cache[thumb])
		else:
			_pending.append([idx, thumb])
	_list.mesh_paths = paths

	_refresh_status()
	_details.text = ""
	set_process(not _pending.is_empty())


## The count line, plus a warning when double-clicking cannot do anything.
##
## Placing a tile needs an edited scene, and with none open the attempt used to
## fail into the small details label where nobody saw it -- the dock looked
## broken rather than unready. The condition is worth stating before it is hit,
## not after.
func _refresh_status() -> void:
	if _all.is_empty():
		_status.text = "No kit indexes found. Run tools/index_kit.py."
		return

	var counted := ("%d tiles of %d assets" % [_shown.size(), _all.size()]
		if _group_variants.button_pressed
		# Collapsed, the tile count is not an asset count, and saying "218 of
		# 1926 assets" while showing 218 families would be a plain lie.
		else "%d of %d assets" % [_shown.size(), _all.size()])

	if _edited_root() == null:
		_status.text = "%s  —  open a scene to place them" % counted
		_status.add_theme_color_override("font_color",
			Color(1.0, 0.72, 0.35))
	else:
		_status.text = counted
		_status.remove_theme_color_override("font_color")


## The scene a double-click would add to, or null when the editor has none.
## Guarded so the dock can be built and tested outside an editor.
func _edited_root() -> Node:
	if not Engine.is_editor_hint():
		return null
	return EditorInterface.get_edited_scene_root()


## A tile caption that keeps its variant count.
##
## The count is the one thing on a tile that cannot be recovered by looking at
## the thumbnail, and letting the ItemList trim the whole string removes it
## first: almost every vendor name is long enough that "(6)" fell off the end.
## So the name is trimmed to leave room for the suffix, rather than the suffix
## being trimmed to leave room for the name.
func _caption(label: String, siblings: int) -> String:
	if siblings <= 1:
		return label
	var suffix := " (%d)" % siblings
	var font := _list.get_theme_font("font")
	var font_size := _list.get_theme_font_size("font_size")
	if font == null:
		return label + suffix

	# A couple of pixels in hand, so this trim lands before the ItemList's own
	# backstop trim does and the suffix survives.
	var budget := float(_list.fixed_column_width) - 10.0 - _width(font, font_size, suffix)
	if _width(font, font_size, label) <= budget:
		return label + suffix

	var ellipsis := "..."
	budget -= _width(font, font_size, ellipsis)
	# Longest prefix that still fits, by bisection -- character-by-character is
	# 3,291 measurements per repopulate and this runs on every keystroke.
	var lo := 0
	var hi := label.length()
	while lo < hi:
		var mid := (lo + hi + 1) / 2
		if _width(font, font_size, label.substr(0, mid)) <= budget:
			lo = mid
		else:
			hi = mid - 1
	return label.substr(0, lo) + ellipsis + suffix


func _width(font: Font, font_size: int, text: String) -> float:
	return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x


func _process(_delta: float) -> void:
	var budget := ICONS_PER_FRAME
	while budget > 0 and not _pending.is_empty():
		var job: Array = _pending.pop_front()
		var texture := _load_icon(job[1])
		if texture != null and job[0] < _list.item_count:
			_list.set_item_icon(job[0], texture)
		budget -= 1
	if _pending.is_empty():
		set_process(false)


func _load_icon(res_path: String) -> Texture2D:
	if _icon_cache.has(res_path):
		return _icon_cache[res_path]
	var image := Image.new()
	# globalize_path because these are ignored by the importer and therefore
	# are not resources; load_from_file on the real OS path is the way in.
	if image.load(ProjectSettings.globalize_path(res_path)) != OK:
		_icon_cache[res_path] = null
		return null
	image.resize(ICON_PX, ICON_PX, Image.INTERPOLATE_LANCZOS)
	var texture := ImageTexture.create_from_image(image)
	_icon_cache[res_path] = texture
	return texture


func _on_selected(index: int) -> void:
	if index >= _shown.size():
		return
	var text := Catalog.describe(_shown[index])
	if _shown[index].get("family_count", 0) > 1:
		# The gesture is not discoverable on its own, so the details pane says so
		# whenever a tile stands for more than the mesh it is showing.
		text += "  —  right-click to choose a variant"
	_details.text = text


func _on_activated(index: int) -> void:
	if index < _shown.size():
		instantiate(_shown[index])


## Right-click a grouped tile to reach the variants hiding behind it.
##
## Grouping is what makes a 3,291-asset library scannable, but it also puts two
## thirds of it out of reach: a double-click can only ever place the one mesh the
## tile happens to show. This is the way to the rest of the family.
func _on_clicked(index: int, _at: Vector2, mouse_button: int) -> void:
	if mouse_button != MOUSE_BUTTON_RIGHT or index >= _shown.size():
		return
	var asset: Dictionary = _shown[index]
	_variant_assets = Catalog.family_members(_filtered, asset.get("family", ""), asset.get("kit", ""))
	if _variant_assets.size() < 2:
		return

	_variants.clear()
	for i in _variant_assets.size():
		var member: Dictionary = _variant_assets[i]
		var icon := _load_icon(Catalog.thumbnail_path(member))
		var label: String = member.get("name", "?")
		if icon != null:
			_variants.add_icon_item(icon, label, i)
		else:
			_variants.add_item(label, i)
		_variants.set_item_tooltip(_variants.get_item_index(i),
			Catalog.describe(member))
	_variants.reset_size()
	_variants.position = Vector2i(get_screen_position() + get_local_mouse_position())
	_variants.popup()


func _on_variant_chosen(id: int) -> void:
	if id < _variant_assets.size():
		instantiate(_variant_assets[id])


## Add the mesh to the edited scene as a child of its root, undoable in one step.
##
## Reached by double-clicking a tile, or Enter on a selected one.
func instantiate(asset: Dictionary) -> void:
	var root := _edited_root()
	if root == null:
		# Loud, in the line the eye already goes to for counts. The old message
		# went to the details label and was effectively invisible.
		_status.text = "Nothing to place into — open a scene first."
		_status.add_theme_color_override("font_color", Color(1.0, 0.55, 0.45))
		return
	var packed: PackedScene = load(asset.get("path", ""))
	if packed == null:
		_details.text = "Could not load %s" % asset.get("path", "")
		return
	var node := packed.instantiate()
	node.name = asset.get("name", "Mesh")

	var undo := EditorInterface.get_editor_undo_redo()
	undo.create_action("Add %s" % node.name)
	undo.add_do_method(root, "add_child", node, true)
	undo.add_do_method(node, "set_owner", root)
	undo.add_do_reference(node)
	undo.add_undo_method(root, "remove_child", node)
	undo.commit_action()
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(node)
	_details.text = "Added %s" % node.name
