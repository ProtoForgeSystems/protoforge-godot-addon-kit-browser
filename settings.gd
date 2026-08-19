@tool
extends RefCounted
## Where the browser's configuration lives. Roots and thumbnail resolution are
## project truth (ProjectSettings); tile size is a personal preference
## (EditorSettings) so two people sharing a project keep their own eyes.

const ROOTS_KEY := "kit_browser/roots"
const RESOLUTION_KEY := "kit_browser/thumbnail_resolution"
const TILE_KEY := "kit_browser/tile_size"
const DEFAULT_ROOT := "res://Assets/Kits"
const DEFAULT_RESOLUTION := 512
const DEFAULT_TILE := 96


static func roots() -> PackedStringArray:
	var stored: Variant = ProjectSettings.get_setting(ROOTS_KEY, PackedStringArray())
	var out := PackedStringArray(stored)
	# The unconfigured default is this pipeline's own layout, so the addon works
	# in ProtoForge repos with zero setup and prompts everyone else once.
	if out.is_empty() and DirAccess.dir_exists_absolute(
			ProjectSettings.globalize_path(DEFAULT_ROOT)):
		out.append(DEFAULT_ROOT)
	return out


static func set_roots(value: PackedStringArray) -> void:
	ProjectSettings.set_setting(ROOTS_KEY, value)
	ProjectSettings.save()


static func resolution() -> int:
	return int(ProjectSettings.get_setting(RESOLUTION_KEY, DEFAULT_RESOLUTION))


static func set_resolution(value: int) -> void:
	ProjectSettings.set_setting(RESOLUTION_KEY, value)
	ProjectSettings.save()


static func tile_size() -> int:
	if not Engine.is_editor_hint():
		return DEFAULT_TILE
	var editor := EditorInterface.get_editor_settings()
	if not editor.has_setting(TILE_KEY):
		return DEFAULT_TILE
	return int(editor.get_setting(TILE_KEY))


static func set_tile_size(value: int) -> void:
	if Engine.is_editor_hint():
		EditorInterface.get_editor_settings().set_setting(TILE_KEY, value)
