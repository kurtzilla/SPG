extends CharacterBody2D

## Factorio-style top-down movement: snappy acceleration, active braking, tight reversal.
## Zoom speed: normalize camera zoom, curve with pow(), lerp between min/max speeds (Inspector-tuned).
## screen_px_s ≈ world_speed * zoom (map scroll scale in MainSandbox).

const ZERO := Vector2.ZERO

const ViewMetricsRes = preload("res://src/Godot/Scripts/ViewMetrics.gd")
const PlaceholderTextureGenerator = preload("res://src/Godot/Assets/PlaceholderTextureGenerator.gd")

signal grid_cell_changed(cell: Vector2i)
signal map_position_changed(map_px: Vector2)

@export_group("Zoom speed")
@export var min_zoom_speed: float = 50.0
@export var max_zoom_speed: float = 800.0
@export var min_zoom_level: float = 0.2
@export var max_zoom_level: float = 2.0
@export var zoom_curve_exponent: float = 2.0

var _max_speed: float = 250.0
var _acceleration: float = 25.0
var _friction: float = 45.0
var _velocity_snap_threshold_sq: float = 0.01
var _last_grid_cell: Vector2i = Vector2i.ZERO
var _cached_zoom: float = -1.0
var _cached_max_speed: float = 250.0

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
	if not ViewProjection.view_changed.is_connected(_invalidate_zoom_speed_cache):
		ViewProjection.view_changed.connect(_invalidate_zoom_speed_cache)
	_apply_movement_settings()
	_invalidate_zoom_speed_cache()


func _apply_movement_settings() -> void:
	_max_speed = Settings.max_speed
	_acceleration = Settings.acceleration
	_friction = Settings.friction
	_velocity_snap_threshold_sq = Settings.velocity_snap_threshold_sq


func _invalidate_zoom_speed_cache() -> void:
	_cached_zoom = -1.0


func _process(delta: float) -> void:
	var zoom: float = ViewProjection.zoom
	var max_speed: float = _max_speed_for_zoom_cached(zoom)
	var steer_scale: float = max_speed / _max_speed if _max_speed > 0.0 else 1.0
	var acceleration: float = _acceleration * steer_scale
	var friction: float = _friction * steer_scale

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


func _max_speed_for_zoom_cached(zoom: float) -> float:
	if is_equal_approx(zoom, _cached_zoom):
		return _cached_max_speed
	_cached_zoom = zoom
	_cached_max_speed = _max_speed_for_zoom(zoom)
	return _cached_max_speed


func _max_speed_for_zoom(zoom: float) -> float:
	var span: float = max_zoom_level - min_zoom_level
	if is_zero_approx(span):
		return lerpf(min_zoom_speed, max_zoom_speed, 0.5)
	var t: float = clampf((zoom - min_zoom_level) / span, 0.0, 1.0)
	var t_curved: float = pow(t, zoom_curve_exponent)
	return lerpf(min_zoom_speed, max_zoom_speed, t_curved)


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
