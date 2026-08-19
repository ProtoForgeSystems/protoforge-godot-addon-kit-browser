extends RefCounted
## Browser-side shelf labels, derived at load time from what the index already says.
##
## The index's taxonomy is deliberately narrow -- structural, weapon, other -- and
## that is right for a file shipped inside twenty-six published submodules, where
## a wrong guess propagates and a schema change costs a re-export. It is a poor
## thing to put in a dropdown, because two thirds of the library lands in "other"
## and a human browsing a kit learns nothing from that.
##
## So the shelves live here instead. Nothing computed in this file is ever written
## back to an index. Being wrong costs one confused click, and fixing it is one
## edit to facets.json with no reindex and no submodule commit.
##
## Pure and headless: assets in, labels out.

const FACETS_PATH := "res://addons/kit_browser/facets.json"

## Assets the index already classified keep that label -- it is more reliable than
## a name guess, having been checked against geometry.
const INDEXED := "Indexed"
const UNSHELVED := "Uncategorised"

static var _shelves: Dictionary = {}


## Token sets by shelf name, loaded once.
static func shelves(path: String = FACETS_PATH) -> Dictionary:
	if not _shelves.is_empty():
		return _shelves
	var doc: Variant = null
	if FileAccess.file_exists(path):
		doc = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(doc) != TYPE_DICTIONARY:
		return {}
	for name in doc.get("shelves", {}):
		var words := {}
		for word in String(doc["shelves"][name]).split(" ", false):
			words[word] = true
		_shelves[name] = words
	return _shelves


static func reload(path: String = FACETS_PATH) -> Dictionary:
	_shelves = {}
	return shelves(path)


## Whole words in a mesh name, lower-cased.
##
## Splits on punctuation, on camelCase, and between letters and digits, so
## Backyard_Chair, BackyardChair01 and BACKYARDChair all yield "chair". A trailing
## "s" is folded in alongside the original so "antennas" matches "antenna".
##
## Whole words rather than substrings is the whole point: substring matching is
## what made "arch" match Architecture and "bat" match Battery_Room.
static func tokens(name: String) -> Dictionary:
	var out := {}
	var word := ""
	var previous := ""
	for i in name.length():
		var ch := name[i]
		if not _alnum(ch):
			_add_token(out, word)
			word = ""
			previous = ""
			continue
		# A boundary sits where the character class changes: lower-to-upper
		# (BackyardChair) or letter-to-digit (Chair01) and back.
		if word != "" and _boundary(previous, ch, name, i):
			_add_token(out, word)
			word = ""
		word += ch
		previous = ch
	_add_token(out, word)
	return out


static func _alnum(ch: String) -> bool:
	return (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") \
		or (ch >= "0" and ch <= "9")


static func _boundary(previous: String, ch: String, name: String, i: int) -> bool:
	var was_digit := previous >= "0" and previous <= "9"
	var is_digit := ch >= "0" and ch <= "9"
	if was_digit != is_digit:
		return true
	var was_lower := previous >= "a" and previous <= "z"
	var is_upper := ch >= "A" and ch <= "Z"
	if was_lower and is_upper:
		return true
	# ABCWord -> ABC, Word: an upper run ending before an upper-then-lower pair.
	var was_upper := previous >= "A" and previous <= "Z"
	if was_upper and is_upper and i + 1 < name.length():
		var next := name[i + 1]
		return next >= "a" and next <= "z"
	return false


static func _add_token(out: Dictionary, word: String) -> void:
	if word.is_empty():
		return
	var lower := word.to_lower()
	out[lower] = true
	if lower.length() > 3 and lower.ends_with("s"):
		out[lower.substr(0, lower.length() - 1)] = true


## Shelves this asset belongs on. Never empty.
##
## An asset the index placed keeps its own label instead of being name-guessed:
## the index checked geometry, and "structural/wall" beats anything inferred from
## a filename. Everything else is tagged, and what matches nothing is said to
## match nothing rather than being filed somewhere plausible.
static func shelves_of(asset: Dictionary, table: Dictionary = {}) -> PackedStringArray:
	var out := PackedStringArray()
	var category: String = asset.get("category", "")
	if category != "" and category != "other":
		var sub: String = asset.get("subcategory", "")
		out.append(category if sub.is_empty() else "%s/%s" % [category, sub])
		return out

	var words := tokens(asset.get("name", ""))
	var lookup := table if not table.is_empty() else shelves()
	for name in lookup:
		for word in lookup[name]:
			if words.has(word):
				out.append(name)
				break
	if out.is_empty():
		out.append(UNSHELVED)
	out.sort()
	return out


## Add "shelves" to every asset. Returns shelf name -> count.
static func annotate(assets: Array, table: Dictionary = {}) -> Dictionary:
	var counts := {}
	for asset in assets:
		var found := shelves_of(asset, table)
		asset["shelves"] = found
		for name in found:
			counts[name] = counts.get(name, 0) + 1
	return counts


## Shelf names present, most populated first, each labelled with its count.
##
## Sorted by size rather than alphabetically because the dropdown's job is to
## show what the library is mostly made of, and Uncategorised is pinned last
## however big it grows -- it is a residue, not a shelf.
static func menu(counts: Dictionary) -> PackedStringArray:
	var names := counts.keys()
	names.sort_custom(func(a: String, b: String) -> bool:
		if (a == UNSHELVED) != (b == UNSHELVED):
			return b == UNSHELVED
		if counts[a] != counts[b]:
			return counts[a] > counts[b]
		return a < b)
	var out := PackedStringArray()
	for name in names:
		out.append("%s (%d)" % [name, counts[name]])
	return out


## The shelf name inside a menu label, i.e. "Furniture (237)" -> "Furniture".
static func shelf_of_label(label: String) -> String:
	var cut := label.rfind(" (")
	return label if cut < 0 else label.substr(0, cut)
