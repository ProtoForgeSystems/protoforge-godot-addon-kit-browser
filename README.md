# protoforge-godot-addon-kit-browser

Godot 4.7 editor dock for browsing ProtoForge asset kits. Reads each attached kit's
`index.json` under `res://Assets/Kits/` (the path standardized across all ProtoForge
game projects), groups variant families per kit, and offers faceted search.

Source-agnostic by design: kits arrive from Unreal, Unity, or direct Blender intake,
but the browser only ever sees the published `index.json` contract.

## Consuming

Mount as a git submodule at `addons/kit_browser` (or `game/addons/kit_browser` when the
Godot project is nested), then enable `res://addons/kit_browser/plugin.cfg` under
`[editor_plugins]` in `project.godot`.

## Developing

The development home is `ProtoForgeSystems/unreal-assets`, which carries the test
suites (`tests/test_kit_browser_*.gd`) against its attached kit library. Edit there,
commit and push here, then bump the consuming repos' submodule pointers.
