@tool
extends RefCounted
## Where the browser's configuration lives. Roots and thumbnail resolution are
## project truth (ProjectSettings); tile size is a personal preference
## (EditorSettings) so two people sharing a project keep their own eyes.

const ROOTS_KEY := "kit_browser/roots"
const RESOLUTION_KEY := "kit_browser/thumbnail_resolution"
const TIERS_KEY := "kit_browser/variant_tiers"
const TILE_KEY := "kit_browser/tile_size"
const TIER_CHOICE_KEY := "kit_browser/selected_tier"
const DEFAULT_ROOT := "res://Assets/Kits"
const DEFAULT_RESOLUTION := 512
const DEFAULT_TILE := 96


static func roots() -> PackedStringArray:
	var stored: Variant = ProjectSettings.get_setting(ROOTS_KEY, PackedStringArray())
	var out := PackedStringArray(stored)
	# The unconfigured default is this pipeline's own layout, so the addon works
	# in ProtoForge repos with zero setup and prompts everyone else once. Only
	# applies before anything has ever been stored -- once the setting exists,
	# an explicitly emptied list (the user removed the last root) must stay
	# empty, not silently regrow the default.
	if out.is_empty() and not ProjectSettings.has_setting(ROOTS_KEY) \
			and DirAccess.dir_exists_absolute(
				ProjectSettings.globalize_path(DEFAULT_ROOT)):
		out.append(DEFAULT_ROOT)
	return out


static func set_roots(value: PackedStringArray) -> void:
	ProjectSettings.set_setting(ROOTS_KEY, value)
	ProjectSettings.save()


## Top-level directory names that are resolution tiers of the same asset
## (e.g. ["1K", "2K"]) rather than distinct content. Default empty: tier
## layouts are a pipeline convention, and a public addon must not assume
## anyone else's. Project truth, like roots — which dirs are tiers is a fact
## about the library, not a personal preference.
static func variant_tiers() -> PackedStringArray:
	return PackedStringArray(ProjectSettings.get_setting(TIERS_KEY,
		PackedStringArray()))


static func set_variant_tiers(value: PackedStringArray) -> void:
	ProjectSettings.set_setting(TIERS_KEY, value)
	ProjectSettings.save()


## Which tier the dock currently resolves tiles to. A browsing preference,
## like tile size: two people on one project may deliberately place different
## tiers, so it lives in EditorSettings. Falls back to the first configured
## tier, and to "" (meaningless, ignored) when no tiers are configured.
static func selected_tier() -> String:
	var tiers := variant_tiers()
	if tiers.is_empty():
		return ""
	if Engine.is_editor_hint():
		var editor := EditorInterface.get_editor_settings()
		if editor.has_setting(TIER_CHOICE_KEY):
			var stored := String(editor.get_setting(TIER_CHOICE_KEY))
			if tiers.has(stored):
				return stored
	return tiers[0]


static func set_selected_tier(value: String) -> void:
	if Engine.is_editor_hint():
		EditorInterface.get_editor_settings().set_setting(TIER_CHOICE_KEY, value)


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
