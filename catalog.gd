extends RefCounted
## Reading and filtering the merged kit index. No UI, no editor, no I/O beyond
## one file read — so every decision the browser makes is testable headless.
##
## The dock is a thin shell over this. Anything that decides WHAT to show lives
## here; anything that decides how it looks lives in kit_browser.gd.

const Facets := preload("res://addons/kit_browser/facets.gd")
const Settings := preload("res://addons/kit_browser/settings.gd")

const KITS_DIR := "res://Assets/Kits"
const VARIANT := "1K"
const THUMB_DIR := "thumbnails"
const THUMB_EXT := ".webp"


## Every asset from every indexed kit under every root. Empty kit_roots means
## the configured roots (Settings.roots()).
##
## Reads the per-kit indexes rather than catalog/merged_index.json. The merged
## file is generated, gitignored and rebuilt by hand, so it goes stale silently:
## Safehouse's 99 weapons were correctly classified in its own index and absent
## from the merged one for long enough that the weapons looked deleted. Reading
## the source of truth means an attached kit cannot be missing from the browser
## because someone forgot to re-run a script.
static func load_assets(kit_roots: PackedStringArray = PackedStringArray(),
		variant: String = VARIANT) -> Array:
	if kit_roots.is_empty():
		kit_roots = Settings.roots()
	var assets := []
	for root in kit_roots:
		for kit in find_kits(root):
			# "." means the root itself is the kit (a flat folder of meshes with
			# no subdirectories); every other kit name nests under root.
			var kit_dir := root if kit == "." else "%s/%s" % [root, kit]
			var doc: Variant = _read_json("%s/index.json" % kit_dir)
			if typeof(doc) != TYPE_DICTIONARY:
				continue
			# Schema 1 predates "base" and its paths were always relative to the
			# hardcoded 1K variant dir. Schema 2 states where its paths live;
			# "" means directly under the kit.
			var base: String = String(doc.get("base", variant)) \
				if int(doc.get("schema", 1)) >= 2 else variant
			# The dropdown shows the root's own basename rather than ".", which
			# would be meaningless in a "Kit" filter.
			var kit_label := root.get_file() if kit == "." else kit
			for asset in doc.get("assets", []):
				var entry: Dictionary = asset.duplicate()
				entry["kit"] = kit_label
				var rel: String = asset.get("path", "")
				# The mesh path stays, because the thumbnail is keyed off it and
				# the index describes the mesh. What gets placed is the wrapper
				# scene: instancing the glTF directly welds a scene to it, and
				# adding collision or a script later would then mean editing
				# every scene that used it. Falls back to the mesh where no
				# wrapper exists yet.
				entry["mesh_path"] = ("%s/%s" % [kit_dir, rel]) if base.is_empty() \
					else ("%s/%s/%s" % [kit_dir, base, rel])
				entry["thumb_path"] = "%s/%s/%s%s" % [kit_dir, THUMB_DIR,
					rel.get_basename(), THUMB_EXT]
				var wrapper := "%s.tscn" % String(entry["mesh_path"]).get_basename()
				entry["path"] = wrapper if ResourceLoader.exists(wrapper) else entry["mesh_path"]
				assets.append(entry)
	assets.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["kit"] != b["kit"]:
			return a["kit"] < b["kit"]
		return a["path"] < b["path"])
	# Shelf labels are derived here rather than read from the index: they are a
	# browsing convenience, and keeping them out of the kit repos means the
	# vocabulary can change without a reindex or a submodule commit.
	Facets.annotate(assets)
	return assets


## Kit names relative to the kits directory, e.g. "Rooftop", "Deckogon/Safehouse".
##
## A vendor directory holds several kits rather than being one, so a directory
## without its own index.json is searched one level deeper. Anything with no
## index at either level is simply skipped -- an exported-but-unindexed kit and
## an unchecked-out submodule both look like that, and neither is an error here.
##
## "." is returned alone when kits_dir itself has an index.json directly in
## it AND no other kits were found -- the root-as-kit case, where
## indexer.gd's find_kits wrote the index for the root rather than for a
## subdirectory. Mirrors indexer.gd's own exclusivity guard: a root that has
## since grown real kit subdirectories must not also surface a stale
## root-level index left over from before the reorganization -- that would
## double-list the same assets under "." and under their new kit.
static func find_kits(kits_dir: String = KITS_DIR) -> PackedStringArray:
	var out := PackedStringArray()
	for entry in _subdirs(kits_dir):
		if FileAccess.file_exists("%s/%s/index.json" % [kits_dir, entry]):
			out.append(entry)
			continue
		for sub in _subdirs("%s/%s" % [kits_dir, entry]):
			var nested := "%s/%s" % [entry, sub]
			if FileAccess.file_exists("%s/%s/index.json" % [kits_dir, nested]):
				out.append(nested)
	out.sort()
	if out.is_empty() and FileAccess.file_exists("%s/index.json" % kits_dir):
		out.append(".")
	return out


static func _subdirs(path: String) -> PackedStringArray:
	var dir := DirAccess.open(path)
	if dir == null:
		return PackedStringArray()
	return dir.get_directories()


static func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


## Stamped at load time, where the root, kit and base are all known; deriving
## it later from string surgery on mesh_path is how the old version came to
## hardcode the Assets/Kits prefix.
static func thumbnail_path(asset: Dictionary) -> String:
	return asset.get("thumb_path", "")


## Sorted, de-duplicated kit names.
static func kits_of(assets: Array) -> PackedStringArray:
	return _distinct(assets, "kit")


## Shelf labels for the dropdown, most populated first, each carrying its count.
##
## Replaces the raw index categories. Offering "other (2297)" as a browsing
## choice is technically accurate and useless; these are the shelves a person
## would look on, and the counts say up front how much of the library each holds.
static func shelves_of(assets: Array) -> PackedStringArray:
	var counts := {}
	for a in assets:
		for shelf in a.get("shelves", []):
			counts[shelf] = counts.get(shelf, 0) + 1
	return Facets.menu(counts)


## Sorted category names. Subcategories are folded in as "category/subcategory"
## so one control can filter both levels — the taxonomy is only two deep, and a
## second dropdown for it would sit empty most of the time.
static func categories_of(assets: Array) -> PackedStringArray:
	var seen := {}
	for a in assets:
		var cat: String = a.get("category", "")
		if cat.is_empty():
			continue
		seen[cat] = true
		var sub: String = a.get("subcategory", "")
		if not sub.is_empty():
			seen["%s/%s" % [cat, sub]] = true
	var out := PackedStringArray(seen.keys())
	out.sort()
	return out


static func _distinct(assets: Array, key: String) -> PackedStringArray:
	var seen := {}
	for a in assets:
		var v: String = a.get(key, "")
		if not v.is_empty():
			seen[v] = true
	var out := PackedStringArray(seen.keys())
	out.sort()
	return out


## Bay widths present across the given assets, widest first, as "3.50 m".
##
## Drawn from each kit's derived module grid: pieces sharing a bay are the ones
## that line up with each other, which is the question a designer is actually
## asking when they reach for a wall.
static func bays_of(assets: Array) -> PackedStringArray:
	var seen := {}
	for a in assets:
		for size in a.get("modules_m", []):
			seen[float(size)] = true
	var sizes := seen.keys()
	sizes.sort()
	sizes.reverse()
	var out := PackedStringArray()
	for size in sizes:
		out.append(format_bay(size))
	return out


static func format_bay(size: float) -> String:
	return "%.2f m" % size


## Assets matching every supplied constraint. Empty constraints match everything.
##
## `query` matches on name, case-insensitively, and every whitespace-separated
## term must appear — so "wall door" finds Wall_doorway_2 without the user
## having to guess the vendor's word order.
static func filter(assets: Array, query: String = "", kit: String = "",
		category: String = "", needs_review_only: bool = false,
		bay: String = "") -> Array:
	var terms := query.strip_edges().to_lower().split(" ", false)
	var out := []
	for a in assets:
		if not kit.is_empty() and a.get("kit", "") != kit:
			continue
		if not category.is_empty() and not _in_category(a, category):
			continue
		if not bay.is_empty() and not _in_bay(a, bay):
			continue
		if needs_review_only and not a.get("needs_review", false):
			continue
		if terms.size() > 0 and not _matches_terms(a, terms):
			continue
		out.append(a)
	return out


static func _in_bay(asset: Dictionary, wanted: String) -> bool:
	for size in asset.get("modules_m", []):
		if format_bay(float(size)) == wanted:
			return true
	return false


## One entry per variant family, carrying "family_count".
##
## A kit that ships BackyardChair01 through 24 is not offering twenty-four
## choices, it is offering one with twenty-four finishes. Collapsing them is what
## makes a 275-asset kit scannable; the count is kept so the grid still says how
## many are behind each tile. Assets with no family pass through untouched.
static func collapse_families(assets: Array) -> Array:
	var counts := {}
	for a in assets:
		if not String(a.get("family", "")).is_empty():
			var key := _family_key(a)
			counts[key] = counts.get(key, 0) + 1

	var seen := {}
	var out := []
	for a in assets:
		var family: String = a.get("family", "")
		if family.is_empty():
			out.append(a)
			continue
		var key := _family_key(a)
		if seen.has(key):
			continue
		seen[key] = true
		var entry: Dictionary = a.duplicate()
		entry["family_count"] = counts[key]
		out.append(entry)
	return out


## A family identifies a group only within its own kit: the indexer derives
## families one kit at a time, and vendors reuse the same words -- SM_pipe occurs
## in twelve of the attached kits. Keying on the bare name showed one tile for all
## twelve, hid eleven kits' pipes behind it, and let the variant menu mix kits.
static func _family_key(asset: Dictionary) -> String:
	return "%s\n%s" % [asset.get("kit", ""), asset.get("family", "")]


## A constraint matches either a shelf label or a raw index category, so the
## dropdown can offer shelves while a caller that knows the taxonomy — the tests,
## or a future tool — can still ask for "weapon/rifle" directly.
static func _in_category(asset: Dictionary, wanted: String) -> bool:
	var shelf := Facets.shelf_of_label(wanted)
	for name in asset.get("shelves", []):
		if name == shelf:
			return true

	var cat: String = asset.get("category", "")
	var sub: String = asset.get("subcategory", "")
	if wanted.contains("/"):
		return "%s/%s" % [cat, sub] == wanted
	return cat == wanted


static func _matches_terms(asset: Dictionary, terms: PackedStringArray) -> bool:
	var name: String = String(asset.get("name", "")).to_lower()
	for t in terms:
		if not name.contains(t):
			return false
	return true


## "2.50 x 0.40 x 2.50 m" — w x d x h, the order the index stores them.
static func format_size(asset: Dictionary) -> String:
	var s: Variant = asset.get("size_m")
	if typeof(s) != TYPE_DICTIONARY:
		return ""
	return "%.2f x %.2f x %.2f m" % [s.get("w", 0.0), s.get("d", 0.0), s.get("h", 0.0)]


## Every asset in one variant family, in index order.
##
## Drawn from the same list the tile was collapsed out of, not from the whole
## library: a tile that says "(4)" must open a menu of exactly four, or the badge
## is lying about what is behind it.
static func family_members(assets: Array, family: String, kit: String) -> Array:
	var out := []
	if family.is_empty():
		return out
	for a in assets:
		if a.get("family", "") == family and a.get("kit", "") == kit:
			out.append(a)
	return out


## One-line summary for the details pane and the item tooltip.
static func describe(asset: Dictionary) -> String:
	var cat: String = asset.get("category", "")
	var sub: String = asset.get("subcategory", "")
	var label := cat if sub.is_empty() else "%s/%s" % [cat, sub]
	var bits := PackedStringArray([asset.get("name", "?"), label, format_size(asset)])

	var bays := PackedStringArray()
	for size in asset.get("modules_m", []):
		bays.append(format_bay(float(size)))
	if bays.size() > 0:
		bits.append("bay " + ", ".join(bays))

	var count: int = asset.get("family_count", 0)
	if count > 1:
		bits.append("%d variants" % count)
	if asset.get("needs_review", false):
		bits.append("needs review")
	return " — ".join(bits)
