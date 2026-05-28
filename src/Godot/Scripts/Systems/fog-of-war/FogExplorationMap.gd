extends Node

## Owns Core visibility state and drives the Godot sliding fog presentation buffer.

@export var enabled: bool = true

var _fog_overlay: FogOverlay
var _visibility: Object


func _ready() -> void:
	_read_fog_settings()
	if not Settings.fog_changed.is_connected(_on_fog_settings_changed):
		Settings.fog_changed.connect(_on_fog_settings_changed)


func _read_fog_settings() -> void:
	if Settings.has("fog.enabled"):
		enabled = Settings.get_bool("fog.enabled")


func _on_fog_settings_changed() -> void:
	_read_fog_settings()
	_apply_overlay_visibility()
	if _visibility != null:
		_visibility.InitialRevealRadius = Settings.initial_reveal_radius
		_visibility.MovementRevealRadius = Settings.player_reveal_radius


func setup(_player: Node2D, fog_overlay: FogOverlay) -> void:
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
	_fog_overlay.setup(_visibility, start_cell)


func on_player_cell_changed(cell: Vector2i) -> void:
	if not enabled or _fog_overlay == null:
		return
	_fog_overlay.on_player_cell_changed(cell)


func _apply_overlay_visibility() -> void:
	if _fog_overlay != null:
		_fog_overlay.set_enabled_visible(enabled)
