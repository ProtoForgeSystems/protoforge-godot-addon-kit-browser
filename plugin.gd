@tool
extends EditorPlugin
## Registers the Kit Browser dock.
##
## Uses add_dock() with an EditorDock rather than the older
## add_control_to_dock(). The old call wraps the control in an EditorDock whose
## available_layouts is VERTICAL | FLOATING, leaving HORIZONTAL off -- and
## horizontal is what the bottom and centre slots need, so those three positions
## sit greyed out in the dock menu with no way to reach them from the plugin
## side. That default is a sensible one for a control built to be tall and
## narrow; this grid reflows either way, so it opts into all three.

const Browser := preload("res://addons/kit_browser/kit_browser.gd")

var _dock: EditorDock
var _browser: Control


func _enter_tree() -> void:
	_browser = Browser.new()

	_dock = EditorDock.new()
	_dock.title = "Kits"
	# The key the editor stores this dock's position under. Without it the
	# layout is remembered against a generated name and moving the dock does not
	# survive a restart.
	_dock.layout_key = "kit_browser"
	_dock.default_slot = EditorDock.DOCK_SLOT_RIGHT_BL
	_dock.available_layouts = EditorDock.DOCK_LAYOUT_ALL
	_dock.add_child(_browser)

	add_dock(_dock)
	# Double-clicking a tile places it in the edited scene, so the dock has to
	# know when there is one. Without this the hint about opening a scene never
	# clears after you open one.
	scene_changed.connect(_browser.on_scene_changed)


func _exit_tree() -> void:
	if _dock != null:
		remove_dock(_dock)
		_dock.queue_free()
		_dock = null
		_browser = null
