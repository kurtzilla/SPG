extends CharacterBody2D

## Factorio-style top-down movement: snappy acceleration, active braking, tight reversal.
## player_movement.* values in game_settings.json are tuned at view.zoom default (0.5).
## Centered camera + Tiles.scale ≈ on-screen rate / zoom; scale map values by (z / z_default)^2:
##   max_speed, acceleration, friction at runtime.

const ZERO := Vector2.ZERO

const ViewMetricsRes = preload("res://src/Godot/Scripts/ViewMetrics.gd")
const PlaceholderTextureGenerator = preload("res://src/Godot/Assets/PlaceholderTextureGenerator.gd")

signal grid_cell_changed(cell: Vector2i)
signal map_position_changed(map_px: Vector2)

var _base_acceleration: float = 50.0
var _base_friction: float = 90.0
var _velocity_snap_threshold_sq: float = 0.01
var _last_grid_cell: Vector2i = Vector2i.ZERO
var _zoom_min: float = 0.25
var _zoom_max: float = 2.0
var _zoom_default: float = 0.5
var _cached_zoom: float = -1.0
var _cached_base_max_speed: float = -1.0
var _cached_movement_scale: float = 1.0

@onready var _sprite: Sprite2D = $Sprite2D


func _ready() -> void:
	process_priority = 10
	motion_mode = MOTION_MODE_FLOATING
	collision_layer = 0
	collision_mask = 0
	z_index = 1
	add_to_group("player")
	_setup_sprite()
	_last_grid_cell = _grid_cell_from_position()
	if not Settings.movement_changed.is_connected(_apply_movement_settings):
		Settings.movement_changed.connect(_apply_movement_settings)
	if not Settings.view_changed.is_connected(_on_view_settings_changed):
		Settings.view_changed.connect(_on_view_settings_changed)
	if not ViewProjection.view_changed.is_connected(_invalidate_movement_cache):
		ViewProjection.view_changed.connect(_invalidate_movement_cache)
	_cache_zoom_limits()
	_apply_movement_settings()
	_invalidate_movement_cache()


func apply_movement_settings() -> void:
	_apply_movement_settings()


func _apply_movement_settings() -> void:
	_base_acceleration = Settings.acceleration
	_base_friction = Settings.friction
	_velocity_snap_threshold_sq = Settings.velocity_snap_threshold_sq
	_invalidate_movement_cache()


func _on_view_settings_changed() -> void:
	_cache_zoom_limits()
	_invalidate_movement_cache()


func _cache_zoom_limits() -> void:
	_zoom_min = float(Settings.get_min("view.zoom"))
	_zoom_max = float(Settings.get_max("view.zoom"))
	var default_zoom: Variant = Settings.get_default("view.zoom")
	_zoom_default = float(default_zoom) if default_zoom != null else 0.5
	if is_zero_approx(_zoom_default):
		_zoom_default = 0.5


func _invalidate_movement_cache() -> void:
	_cached_zoom = -1.0
	_cached_base_max_speed = -1.0


func _process(delta: float) -> void:
	var zoom: float = ViewProjection.safe_zoom()
	var base_max_speed: float = Settings.max_speed
	var movement: Dictionary = _movement_for_zoom_cached(zoom, base_max_speed)
	var max_speed: float = movement["max_speed"]
	var acceleration: float = movement["acceleration"]
	var friction: float = movement["friction"]

	var input_dir := _read_input_direction()
	if input_dir != ZERO:
		var target := input_dir * max_speed
		velocity = velocity.lerp(target, minf(acceleration * delta, 1.0))
	else:
		velocity = velocity.lerp(ZERO, minf(friction * delta, 1.0))

	if velocity.length_squared() < _velocity_snap_threshold_sq:
		velocity = ZERO

	move_and_slide()
	ViewProjection.set_camera_focus(position)

	if input_dir != ZERO or not velocity.is_zero_approx():
		map_position_changed.emit(position)
	_emit_grid_cell_if_changed()


func _movement_for_zoom_cached(zoom: float, base_max_speed: float) -> Dictionary:
	if (
		is_equal_approx(zoom, _cached_zoom)
		and is_equal_approx(base_max_speed, _cached_base_max_speed)
	):
		return {
			"max_speed": base_max_speed * _cached_movement_scale,
			"acceleration": _base_acceleration * _cached_movement_scale,
			"friction": _base_friction * _cached_movement_scale,
		}
	var movement_scale: float = _zoom_movement_scale(zoom)
	_cached_zoom = zoom
	_cached_base_max_speed = base_max_speed
	_cached_movement_scale = movement_scale
	return {
		"max_speed": base_max_speed * movement_scale,
		"acceleration": _base_acceleration * movement_scale,
		"friction": _base_friction * movement_scale,
	}


func _zoom_movement_scale(zoom: float) -> float:
	var z: float = clampf(zoom, _zoom_min, _zoom_max)
	if is_zero_approx(_zoom_default):
		return 1.0
	var t: float = z / _zoom_default
	return t * t


func _setup_sprite() -> void:
	_sprite.texture = PlaceholderTextureGenerator.create_character_billboard_texture()
	_sprite.centered = true
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST


func _read_input_direction() -> Vector2:
	var dx: int = 0
	var dy: int = 0
	if Input.is_physical_key_pressed(KEY_D):
		dx = 1
	elif Input.is_physical_key_pressed(KEY_A):
		dx = -1
	if Input.is_physical_key_pressed(KEY_S):
		dy = 1
	elif Input.is_physical_key_pressed(KEY_W):
		dy = -1
	var input_dir := Vector2(float(dx), float(dy))
	if input_dir != ZERO:
		input_dir = input_dir.normalized()
	return input_dir


func _grid_cell_from_position() -> Vector2i:
	var cell_size: float = float(ViewMetricsRes.CELL_SIZE_PX)
	return Vector2i(
		int(floor(position.x / cell_size)),
		int(floor(position.y / cell_size))
	)


func _emit_grid_cell_if_changed() -> void:
	var cell := _grid_cell_from_position()
	if cell != _last_grid_cell:
		_last_grid_cell = cell
		grid_cell_changed.emit(cell)
