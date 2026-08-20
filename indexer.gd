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


static func scan_kit(kit_dir: String) -> Array:
	var files := []
	_scan_dir(kit_dir, "", files)
	# A .tscn sitting beside a mesh of the same stem is that mesh's wrapper:
	# the catalog already prefers it at placement time, so indexing it too
	# would show every wrapped asset twice.
	var mesh_stems := {}
	for f in files:
		if String(f["path"]).get_extension() != "tscn":
			mesh_stems[String(f["path"]).get_basename()] = true
	var out := []
	for f in files:
		var path := String(f["path"])
		if path.get_extension() == "tscn":
			if mesh_stems.has(path.get_basename()):
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
## anything a directory scan can rebuild. Force is the human overriding that.
static func can_overwrite(old_doc: Variant, force: bool) -> bool:
	if typeof(old_doc) != TYPE_DICTIONARY:
		return true
	return force or old_doc.get("generator", "") == GENERATOR


static func plan(scanned: Array, old_doc: Variant, existing: Dictionary,
		force: bool) -> Dictionary:
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
		if not force and typeof(prior) == TYPE_DICTIONARY \
				and int(prior.get("mtime", -1)) == int(file["mtime"]) \
				and existing.has(thumb):
			entries.append(prior)
			continue
		var parts := rel.split("/")
		render.append(entries.size())
		entries.append({
			"path": rel,
			"name": file["name"],
			"mtime": file["mtime"],
			"category": parts[0].to_lower() if parts.size() > 1 else "",
			"subcategory": parts[1].to_lower() if parts.size() > 2 else "",
		})
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


static func build_doc(entries: Array) -> Dictionary:
	return {
		"schema": 2,
		"generator": GENERATOR,
		"base": "",
		"generated": Time.get_datetime_string_from_system(true) + "Z",
		"assets": entries,
	}


static func write_index(kit_dir: String, doc: Dictionary) -> Error:
	var thumb_abs := ProjectSettings.globalize_path("%s/%s" % [kit_dir, THUMB_DIR])
	DirAccess.make_dir_recursive_absolute(thumb_abs)
	if not FileAccess.file_exists("%s/%s/.gdignore" % [kit_dir, THUMB_DIR]):
		var marker := FileAccess.open("%s/%s/.gdignore" % [kit_dir, THUMB_DIR],
			FileAccess.WRITE)
		if marker != null:
			marker.close()
	var tmp := "%s/index.json.tmp" % kit_dir
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(doc, "\t"))
	f.close()
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp),
		ProjectSettings.globalize_path("%s/index.json" % kit_dir))
