@tool
extends RefCounted
## The in-editor index producer: scans user-designated roots and writes the
## same index.json contract the ProtoForge pipeline writes. Decisions are
## static and pure so they run headless; only scan and write touch the disk.

const MESH_EXTS := ["glb", "gltf", "fbx", "obj", "blend", "dae"]
const GENERATOR := "addon"
const THUMB_DIR := "thumbnails"
const THUMB_EXT := ".webp"
const MIN_FAMILY := 2

## Where a kit declares, per composite scene, which OTHER kits that scene
## instances props from. Written by the pipeline's composite generator and
## shipped inside the kit; absent from every kit that has no composites.
const COMPOSITE_MANIFEST := "Composites/composites.json"

## Mirrors catalog/variants.py's _MARKER and _DIMENSION exactly -- the addon
## indexer and the pipeline must agree on what a variant marker is, or the
## same kit groups differently depending on which one indexed it. Compiled
## once, lazily: RegEx has no literal syntax, so it cannot be a const.
static var _marker_re: RegEx
static var _dimension_re: RegEx


static func _ensure_regex() -> void:
	if _marker_re != null:
		return
	_marker_re = RegEx.new()
	_marker_re.compile("(?i)_*(\\d{1,3})([a-z])?_*$")
	_dimension_re = RegEx.new()
	_dimension_re.compile("(?i)\\d(m|cm|mm|k)$")


## The name this mesh is a variant of, or the name itself if it is not one.
## Where a marker carries both digits and a letter the digits are kept:
## SM_Rifle_02a through SM_Rifle_67h are different rifles that share finish
## letters, and stripping both would present distinct weapons as one family.
static func family_of(name: String) -> String:
	_ensure_regex()
	var m := _marker_re.search(name)
	if m == null:
		return name
	if _dimension_re.search(m.get_string(0)) != null:
		return name
	var cut: String = name.substr(0, m.get_start(2)) if m.get_string(2) != "" \
		else name.substr(0, m.get_start(0))
	cut = cut.rstrip("_")
	return cut if not cut.is_empty() else name


## Adds or removes "family" on every entry, computed over the full list
## together -- a kept entry from an old index can gain or lose siblings as
## other entries in the same kit come and go, so every entry is recomputed
## rather than only the freshly (re)scanned ones. Single-member families get
## no field: the field exists to say "there are others", and alone it would
## say nothing.
static func annotate_families(entries: Array) -> void:
	var grouped := {}
	for e in entries:
		var fam := family_of(e.get("name", ""))
		if not grouped.has(fam):
			grouped[fam] = []
		grouped[fam].append(e)
	for fam in grouped:
		var members: Array = grouped[fam]
		var keep: bool = members.size() >= MIN_FAMILY
		for e in members:
			if keep:
				e["family"] = fam
			else:
				e.erase("family")


## Kits directly under root; kits one level down inside a vendor directory
## (a subdirectory that holds several kits rather than being one itself,
## e.g. "Deckogon/Safehouse") are returned as "Vendor/Kit". Mirrors
## catalog.gd's find_kits so the addon indexer and the browsing catalog agree
## on what counts as a kit, but a vendor's un-indexed siblings are still
## kits here (there is nothing to index yet), where the catalog would have
## nothing to read for them.
##
## When none of that finds a kit and the root itself directly holds at least
## one mesh file, the root is the kit: "." is returned alone. A root pointed
## straight at a flat asset folder (no subdirectories at all) used to yield
## an empty array and Index would silently do nothing.
static func find_kits(root: String) -> PackedStringArray:
	var dir := DirAccess.open(root)
	if dir == null:
		return PackedStringArray()
	var out := PackedStringArray()
	for entry in dir.get_directories():
		if FileAccess.file_exists("%s/%s/index.json" % [root, entry]):
			out.append(entry)
			continue
		var sub_dir := DirAccess.open("%s/%s" % [root, entry])
		var subs := sub_dir.get_directories() if sub_dir != null else PackedStringArray()
		var is_vendor := false
		for sub in subs:
			if FileAccess.file_exists("%s/%s/%s/index.json" % [root, entry, sub]):
				is_vendor = true
				break
		if is_vendor:
			for sub in subs:
				out.append("%s/%s" % [entry, sub])
		else:
			out.append(entry)
	out.sort()
	if out.is_empty() and _has_mesh_file(dir):
		out.append(".")
	return out


## Non-recursive: at least one MESH_EXTS file sitting directly in the
## directory the DirAccess is already open on.
static func _has_mesh_file(dir: DirAccess) -> bool:
	for file in dir.get_files():
		if MESH_EXTS.has(file.get_extension().to_lower()):
			return true
	return false


## Each composite scene's declared dep_kits, keyed by the kit-root-relative
## .tscn path ("Composites/PF_House_04.tscn") so a scan can look one up by
## the path it already has. Empty for a kit with no manifest.
##
## A composite is authored against a whole asset bundle: PF_House_04 instances
## its walls from its own kit but its candles from Hivemind/ModularDungeon and
## a barrel from Hivemind/BanditVillage. Check out one kit of that bundle and
## the .tscn still ships -- loading it then logs one "Failed loading resource"
## per absent prop and draws a building stripped of its dressing. The kit
## already ships the answer to "would this load"; nothing read it.
static func composite_deps(kit_dir: String) -> Dictionary:
	var path := "%s/%s" % [kit_dir, COMPOSITE_MANIFEST]
	if not FileAccess.file_exists(path):
		return {}
	var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(doc) != TYPE_DICTIONARY:
		return {}
	var out := {}
	for entry in doc.get("composites", []):
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var rel := String(entry.get("tscn", ""))
		if not rel.is_empty():
			out[rel] = PackedStringArray(entry.get("dep_kits", []))
	return out


## Which of `dep_kits` is not checked out under any of `roots`, in declared
## order. A dep_kit is named from the pipeline's kits directory the way
## find_kits names a kit -- "Hivemind/ModularDungeon" -- but a configured root
## may sit at that level, at the vendor, or at the kit itself (find_kits
## accepts all three), so each root is tried in whichever of those roles its
## own path allows. `cache` maps a probed directory to its presence; pass one
## dictionary across many calls and each directory is probed once.
static func unmet_deps(dep_kits: Variant, roots: PackedStringArray,
		cache: Dictionary = {}) -> PackedStringArray:
	var out := PackedStringArray()
	if typeof(dep_kits) != TYPE_ARRAY and typeof(dep_kits) != TYPE_PACKED_STRING_ARRAY:
		return out
	for dep in dep_kits:
		var name := String(dep)
		if name.is_empty():
			continue
		var present := false
		for root in roots:
			for candidate in _dep_candidates(root, name):
				if not cache.has(candidate):
					cache[candidate] = _kit_present(candidate)
				if cache[candidate]:
					present = true
					break
			if present:
				break
		if not present:
			out.append(name)
	return out


## Where `name` would live if `root` were the kits directory, the dep's
## vendor directory, or the dep kit itself. A root only qualifies for the
## latter two when its path actually ends in the vendor or the kit, so a
## same-named kit under another vendor never stands in for the dep.
static func _dep_candidates(root: String, name: String) -> PackedStringArray:
	var base := root.rstrip("/")
	var out := PackedStringArray(["%s/%s" % [base, name]])
	if base.ends_with("/" + name):
		out.append(base)
	var vendor := name.get_base_dir()
	if not vendor.is_empty() and base.ends_with("/" + vendor):
		out.append("%s/%s" % [base, name.get_file()])
	return out


## Presence is "the directory exists and holds something", not "it has an
## index.json": an exported-but-unindexed kit's meshes still load, and loading
## is all a composite needs from it. Emptiness rather than existence is the
## test because an un-initialised git submodule -- far and away the common way
## a dep kit goes missing -- leaves the directory behind. One entry is read,
## not the listing: a kit directory can hold thousands of files.
static func _kit_present(dir_path: String) -> bool:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return false
	dir.list_dir_begin()
	var first := dir.get_next()
	dir.list_dir_end()
	return not first.is_empty()


## `roots` is the configured kit roots, used only to resolve the composite
## dep_kits described on composite_deps. Passing none disables that check
## rather than declaring every dep unmet: with nowhere to look, "missing" is
## not a fact this can establish.
static func scan_kit(kit_dir: String, roots: PackedStringArray = PackedStringArray()) -> Array:
	var files := []
	_scan_dir(kit_dir, "", files)
	# A .tscn sitting beside a mesh of the same stem is that mesh's wrapper:
	# the catalog already prefers it at placement time, so indexing it too
	# would show every wrapped asset twice.
	var mesh_stems := {}
	for f in files:
		if String(f["path"]).get_extension() != "tscn":
			mesh_stems[String(f["path"]).get_basename()] = true
	var deps := composite_deps(kit_dir)
	var present := {}
	var out := []
	for f in files:
		var path := String(f["path"])
		if path.get_extension() == "tscn":
			if mesh_stems.has(path.get_basename()):
				continue
			if deps.has(path):
				# What the composite needs is a fact about the asset and goes
				# in the index; which of those are checked out is a fact about
				# this machine and is only used here, to decide what to load.
				f["kind"] = "composite"
				f["dep_kits"] = deps[path]
				# Checked before _has_3d_visuals, which instantiates the scene
				# and is therefore itself one of the two places the missing-
				# prop errors came from. A manifest entry already says this is
				# a 3D composite, so the gate the load would have provided is
				# not needed here.
				var missing := unmet_deps(deps[path], roots, present) \
					if not roots.is_empty() else PackedStringArray()
				if not missing.is_empty():
					f["unmet_deps"] = missing
					out.append(f)
					continue
			if not _has_3d_visuals("%s/%s" % [kit_dir, path]):
				continue
		out.append(f)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["path"] < b["path"])
	return out


static func _scan_dir(kit_dir: String, rel: String, out: Array) -> void:
	var abs := kit_dir if rel.is_empty() else "%s/%s" % [kit_dir, rel]
	var dir := DirAccess.open(abs)
	if dir == null:
		return
	for sub in dir.get_directories():
		if rel.is_empty() and sub == THUMB_DIR:
			continue
		_scan_dir(kit_dir, sub if rel.is_empty() else "%s/%s" % [rel, sub], out)
	for file in dir.get_files():
		var ext := file.get_extension().to_lower()
		if not (MESH_EXTS.has(ext) or ext == "tscn"):
			continue
		var rel_path := file if rel.is_empty() else "%s/%s" % [rel, file]
		out.append({
			"path": rel_path,
			"name": file.get_basename(),
			"mtime": FileAccess.get_modified_time("%s/%s" % [kit_dir, rel_path]),
		})


## Whether a scene is 3D content or something else saved as .tscn (UI, audio
## banks, tool scenes). Instantiated briefly; scenes are cheap next to render.
static func _has_3d_visuals(scene_path: String) -> bool:
	var packed: Resource = ResourceLoader.load(scene_path)
	if not packed is PackedScene:
		return false
	var node: Node = packed.instantiate()
	if node == null:
		return false
	var found := _find_visual(node)
	node.free()
	return found


static func _find_visual(node: Node) -> bool:
	if node is VisualInstance3D:
		return true
	for child in node.get_children():
		if _find_visual(child):
			return true
	return false


static func existing_thumbs(kit_dir: String) -> Dictionary:
	var out := {}
	_collect_thumbs(kit_dir, THUMB_DIR, out)
	return out


static func _collect_thumbs(kit_dir: String, rel: String, out: Dictionary) -> void:
	var dir := DirAccess.open("%s/%s" % [kit_dir, rel])
	if dir == null:
		return
	for sub in dir.get_directories():
		_collect_thumbs(kit_dir, "%s/%s" % [rel, sub], out)
	for file in dir.get_files():
		if file.get_extension() == "webp":
			out["%s/%s" % [rel, file]] = true


## An index someone else produced is a thing this button must not destroy:
## inside a ProtoForge repo the pipeline's classifications are richer than
## anything a directory scan can rebuild.
##
## `overwrite_foreign` is the human overriding that, and it is deliberately
## NOT the same flag as plan()'s `rebuild`. One says "redraw everything you
## already know about"; the other says "throw away what another tool
## established and re-derive it from directory names". They used to be one
## boolean called `force`, which is how a per-kit run meant only to redraw
## thumbnails came to be permitted to replace a pipeline index.
static func can_overwrite(old_doc: Variant, overwrite_foreign: bool) -> bool:
	if typeof(old_doc) != TYPE_DICTIONARY:
		return true
	return overwrite_foreign or old_doc.get("generator", "") == GENERATOR


## `rebuild` re-derives every entry and schedules every thumbnail, instead of
## keeping an entry whose mtime and thumbnail both say nothing changed. It
## decides how much work this kit is worth, and nothing else -- whether the
## kit may be written at all is can_overwrite's question, asked separately.
##
## `tiers` (Settings.variant_tiers()) names resolution-tier directories to
## skip when deriving category/subcategory from the path — a tiered kit's
## first component is "1K", and "1k" as a category is a tier masquerading as
## taxonomy. The path itself always stays real; only the labels skip.
static func plan(scanned: Array, old_doc: Variant, existing: Dictionary,
		rebuild: bool, tiers: PackedStringArray = PackedStringArray()) -> Dictionary:
	var old := {}
	if typeof(old_doc) == TYPE_DICTIONARY:
		for a in old_doc.get("assets", []):
			old[a.get("path", "")] = a
	var entries := []
	var render := []
	for file in scanned:
		var rel: String = file["path"]
		var thumb := "%s/%s%s" % [THUMB_DIR, rel.get_basename(), THUMB_EXT]
		var prior: Variant = old.get(rel)
		# The entry is kept whole, not rebuilt: it may carry size_m from a
		# previous render, and rebuilding would throw that away for a file
		# that has not changed.
		if not rebuild and typeof(prior) == TYPE_DICTIONARY \
				and int(prior.get("mtime", -1)) == int(file["mtime"]) \
				and existing.has(thumb):
			# JSON.parse_string has no int type, so a kept entry's mtime came
			# back as a float and would be re-written as "100.0" — flipping
			# every index's format the first time the addon re-indexes it.
			prior["mtime"] = int(prior.get("mtime", -1))
			# Kept whole, except for what the scan knows better: the manifest
			# is the authority on a composite's dependencies, and a stored
			# unmet_deps (older addon builds wrote one) is a machine-local
			# answer that must never survive into another machine's dock.
			prior.erase("unmet_deps")
			if file.has("dep_kits"):
				prior["kind"] = file["kind"]
				prior["dep_kits"] = file["dep_kits"]
			entries.append(prior)
			continue
		var parts := PackedStringArray()
		for part in rel.split("/"):
			if not tiers.has(part):
				parts.append(part)
		var entry := {
			"path": rel,
			"name": file["name"],
			"mtime": file["mtime"],
			"category": parts[0].to_lower() if parts.size() > 1 else "",
			"subcategory": parts[1].to_lower() if parts.size() > 2 else "",
		}
		if file.has("dep_kits"):
			entry["kind"] = file["kind"]
			entry["dep_kits"] = file["dep_kits"]
		# Indexed, but never rendered: the thumbnail is the second place the
		# scene gets loaded, and a composite drawn without the props it is
		# missing is a picture that lies about the asset. The reason itself
		# stays out of the entry -- the catalog re-derives it on whichever
		# machine reads the index, from the dep_kits written above.
		if not file.has("unmet_deps"):
			render.append(entries.size())
		entries.append(entry)
	return {"entries": entries, "render": render}


## Drop the entries a render proved are not assets. scan_kit gates .tscn
## files on _has_3d_visuals, but a file with a mesh extension gets no such
## check — an animation-only glTF passes the scan, renders to nothing, and
## would otherwise sit in the dock forever as a tile with no picture. The
## render is what knows, so the removal happens here rather than as a second
## pre-pass that would pay the same load cost to learn the same fact.
##
## Families are recomputed because removing members can take a family below
## MIN_FAMILY, and a clip's stem often matches the mesh it animates.
static func prune(entries: Array, drop: Array) -> Array:
	if drop.is_empty():
		return entries
	var dropped := {}
	for i in drop:
		dropped[int(i)] = true
	var kept := []
	for i in entries.size():
		if not dropped.has(i):
			kept.append(entries[i])
	annotate_families(kept)
	return kept


## What a run that was cancelled part-way through this kit can still write.
## `jobs[:done]` were rendered (some of them into `dropped`); `jobs[done:]`
## were not reached and take their OLD entry where the old index has one, so
## the next plain Index finds a stale mtime or a missing thumbnail and renders
## them then. Everything not in `jobs` was kept from the old index and stays.
## Returns null when the old index is not the addon's to overwrite: a partial
## addon doc replacing a pipeline index would take the classifier's work with
## it, and that kit is left exactly as it was instead.
static func salvage(entries: Array, jobs: Array, done: int, dropped: Array,
		old_doc: Variant) -> Variant:
	if not can_overwrite(old_doc, false):
		return null
	var old := {}
	if typeof(old_doc) == TYPE_DICTIONARY:
		for a in old_doc.get("assets", []):
			old[a.get("path", "")] = a
	var skip := {}
	for i in dropped:
		skip[int(i)] = true
	var unreached := {}
	for j in range(done, jobs.size()):
		unreached[int(jobs[j])] = true
	var out := []
	for i in entries.size():
		if skip.has(i):
			continue
		if unreached.has(i):
			var prior: Variant = old.get(entries[i].get("path", ""))
			if typeof(prior) != TYPE_DICTIONARY:
				continue
			prior["mtime"] = int(prior.get("mtime", -1))
			out.append(prior)
			continue
		out.append(entries[i])
	annotate_families(out)
	return out


static func build_doc(entries: Array) -> Dictionary:
	return {
		"schema": 2,
		"generator": GENERATOR,
		"base": "",
		"generated": Time.get_datetime_string_from_system(true) + "Z",
		"assets": entries,
	}


## The thumbnail directory, marked .gdignore so Godot leaves it alone.
##
## Thumbnails are decoded by hand at display time and are never wanted as
## imported textures: a kit of a few hundred meshes would otherwise cost the
## same number of import jobs and .import files, inside somebody's submodule.
## Its own function because it used to be a side effect of write_index, which
## made it something a render that writes no index silently did not get.
static func ensure_thumb_dir(kit_dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path("%s/%s" % [kit_dir, THUMB_DIR]))
	var marker_path := "%s/%s/.gdignore" % [kit_dir, THUMB_DIR]
	if FileAccess.file_exists(marker_path):
		return
	var marker := FileAccess.open(marker_path, FileAccess.WRITE)
	if marker != null:
		marker.close()


static func write_index(kit_dir: String, doc: Dictionary) -> Error:
	ensure_thumb_dir(kit_dir)
	var tmp := "%s/index.json.tmp" % kit_dir
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(doc, "\t"))
	f.close()
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp),
		ProjectSettings.globalize_path("%s/index.json" % kit_dir))
