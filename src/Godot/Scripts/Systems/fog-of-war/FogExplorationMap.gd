extends Node

## Owns Core visibility state and drives the Godot sliding fog presentation buffer.

@export var enabled: bool = true

var _player: Node2D
var _fog_overlay: Node2D
var _visibility: Object


func _ready() -> void:
	_read_fog_settings()


func _read_fog_settings() -> void:
	if Settings.has("fog.enabled"):
		enabled = Settings.get_bool("fog.enabled")


func setup(player: Node2D, fog_overlay: Node2D) -> void:
	_player = player
	_fog_overlay = fog_overlay
	var core: Node = get_node("/root/CoreBridge")
	_visibility = core.CreateVisibilityModel()
	if _visibility != null:
		_visibility.InitialRevealRadius = Settings.initial_reveal_radius
		_visibility.MovementRevealRadius = Settings.player_reveal_radius
	_apply_overlay_visibility()


func bootstrap_exploration(start_cell: Vector2i) -> void:
	if _visibility == null or _fog_overlay == null:
		return
	if _fog_overlay.has_method("setup"):
		_fog_overlay.setup(_visibility, start_cell)
	if _fog_overlay.has_method("on_player_cell_changed"):
		_fog_overlay.on_player_cell_changed(start_cell)


func on_player_cell_changed(cell: Vector2i) -> void:
	if not enabled or _fog_overlay == null:
		return
	if _fog_overlay.has_method("on_player_cell_changed"):
		_fog_overlay.on_player_cell_changed(cell)


func _apply_overlay_visibility() -> void:
	if _fog_overlay != null and _fog_overlay.has_method("set_enabled_visible"):
		_fog_overlay.set_enabled_visible(enabled)
