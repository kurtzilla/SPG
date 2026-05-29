class_name FogOverlay
extends CanvasLayer

## Sliding-window fog mask (1 texel = 1 grid cell). Screen-space quad; projection via ViewFrame.

const FOG_SHADER: Shader = preload("res://src/Godot/Shaders/FogOverlay.gdshader")
const ViewMetricsRes = preload("res://src/Godot/Scripts/ViewMetrics.gd")
const ViewTransformsScript = preload("res://src/Godot/Scripts/ViewTransforms.gd")
const ViewFrameScript = preload("res://src/Godot/Scripts/ViewFrame.gd")

const DEFAULT_BUFFER_SIZE_CELLS: int = 128
const DEFAULT_RECENTER_MARGIN_CELLS: int = 24
const MAX_BUFFER_SIZE_CELLS: int = 512
const BUFFER_SIZE_STEP_CELLS: int = 32
const REVEALED_BYTE: int = 255
const FALLBACK_MIN_ZOOM: float = 0.2

@onready var _fog_rect: ColorRect = $FogRect

var _shader_mat: ShaderMaterial
var _visibility: Object

var _fog_image: Image
var _fog_texture: ImageTexture
var _mask_bytes: PackedByteArray = PackedByteArray()

var _buffer_size_cells: int = DEFAULT_BUFFER_SIZE_CELLS
var _settings_buffer_floor: int = DEFAULT_BUFFER_SIZE_CELLS
var _recenter_margin_cells: int = DEFAULT_RECENTER_MARGIN_CELLS
var _initial_reveal_radius: int = 1
var _player_reveal_radius: int = 1

var _current_buffer_center_grid: Vector2i = Vector2i.ZERO
var _buffer_origin_grid: Vector2i = Vector2i.ZERO
var _last_reveal_cell: Vector2i = Vector2i(999999, 999999)
var _is_first_draw: bool = true
var _configured: bool = false
var _fog_enabled: bool = false

var _cached_canvas_to_map: Transform2D = Transform2D.IDENTITY
var _canvas_to_map_cached: bool = false


func _ready() -> void:
	_fog_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fog_rect.color = Color(0.0, 0.0, 0.0, 0.0)
	_fog_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fog_rect.anchor_right = 1.0
	_fog_rect.anchor_bottom = 1.0
	_fog_rect.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_fog_rect.grow_vertical = Control.GROW_DIRECTION_BOTH

	_shader_mat = ShaderMaterial.new()
	_shader_mat.shader = FOG_SHADER
	_fog_rect.material = _shader_mat
	_fog_rect.visible = false

	if not Settings.fog_changed.is_connected(_on_fog_settings_changed):
		Settings.fog_changed.connect(_on_fog_settings_changed)
	_read_buffer_settings()


func set_enabled_visible(fog_enabled: bool) -> void:
	_fog_enabled = fog_enabled
	_fog_rect.visible = _configured and _fog_enabled


func is_configured() -> bool:
	return _configured


func apply_view_frame(frame: ViewFrameScript) -> void:
	if _shader_mat == null or frame == null:
		return
	_push_projection_uniforms(frame)


func ensure_buffer_for_viewport() -> void:
	if not _configured:
		return
	var required: int = _required_buffer_size_for_min_zoom()
	if required == _buffer_size_cells:
		return
	_rebuild_buffer_storage(required)
	_recompute_buffer_origin()
	_bind_buffer_layout_uniforms()
	_fill_buffer_from_core()
	_commit_mask_to_gpu()


func setup(visibility: Object, start_cell: Vector2i) -> void:
	_visibility = visibility
	_read_buffer_settings()
	_load_reveal_radii_from_settings()

	_current_buffer_center_grid = start_cell
	_rebuild_buffer_storage(_required_buffer_size_for_min_zoom())
	_recompute_buffer_origin()
	_bind_buffer_layout_uniforms()

	_configured = true
	_is_first_draw = true
	_last_reveal_cell = Vector2i(999999, 999999)
	_invalidate_projection_cache()

	_bootstrap_initial_reveal(start_cell)
	on_player_cell_changed(start_cell)


func on_player_cell_changed(cell: Vector2i) -> void:
	if not _configured or _visibility == null:
		return
	if cell == _last_reveal_cell:
		return

	var radius: int = _initial_reveal_radius if _is_first_draw else _player_reveal_radius
	if _is_first_draw:
		_is_first_draw = false
	_last_reveal_cell = cell

	if _needs_recenter(cell):
		_recenter_buffer(cell, radius)
	else:
		reveal_cells_at(cell, radius)
		_commit_mask_to_gpu()


func reveal_cells_at(grid_coord: Vector2i, radius_cells: int, force_square: bool = false) -> void:
	if _visibility == null:
		return
	if force_square and _visibility.has_method("RevealSquare"):
		_visibility.RevealSquare(grid_coord.x, grid_coord.y, radius_cells)
	elif _visibility.has_method("RevealDisc"):
		_visibility.RevealDisc(grid_coord.x, grid_coord.y, radius_cells)
	_fill_buffer_from_core()


func _needs_recenter(cell: Vector2i) -> bool:
	var local: Vector2i = cell - _buffer_origin_grid
	var safe_zoom: float = ViewProjection.safe_zoom()
	var view_half: int = ViewTransformsScript.visible_grid_radius_from_viewport(
		ViewProjection.get_viewport_size(), safe_zoom, 0
	)
	var dynamic_margin: int = maxi(maxi(_player_reveal_radius, _initial_reveal_radius) + 2, view_half)
	return (
		local.x < dynamic_margin
		or local.y < dynamic_margin
		or local.x >= _buffer_size_cells - dynamic_margin
		or local.y >= _buffer_size_cells - dynamic_margin
	)


func _recenter_buffer(new_center: Vector2i, pending_radius: int) -> void:
	_current_buffer_center_grid = new_center
	_recompute_buffer_origin()
	_bind_buffer_layout_uniforms()
	_clear_mask_bytes()
	_fill_buffer_from_core()
	var radius: int = pending_radius if pending_radius > 0 else _player_reveal_radius
	reveal_cells_at(new_center, radius)
	_commit_mask_to_gpu()
	_ensure_center_revealed(new_center)


func _bootstrap_initial_reveal(start_cell: Vector2i) -> void:
	if not _is_first_draw or _visibility == null:
		return
	var radius: int = maxi(_initial_reveal_radius, 1)
	reveal_cells_at(start_cell, radius, true)
	_commit_mask_to_gpu()
	_last_reveal_cell = start_cell
	_is_first_draw = false
	_ensure_center_revealed(start_cell)


func _ensure_center_revealed(player_cell: Vector2i) -> void:
	if not _configured or _mask_bytes.is_empty():
		return
	var idx: int = _mask_index_for_cell(player_cell)
	if idx < 0 or _mask_bytes[idx] != 0:
		return
	reveal_cells_at(player_cell, _initial_reveal_radius)
	_commit_mask_to_gpu()


func _allocate_mask_buffer() -> void:
	var mask_size: int = _buffer_size_cells * _buffer_size_cells
	_mask_bytes.resize(mask_size)
	_mask_bytes.fill(0)


func _rebuild_buffer_storage(new_size: int) -> void:
	if new_size <= 0:
		return
	_buffer_size_cells = new_size
	_allocate_mask_buffer()

	var needs_new_image: bool = (
		_fog_image == null
		or _fog_image.get_width() != new_size
		or _fog_image.get_height() != new_size
	)
	if needs_new_image:
		_fog_image = Image.create(new_size, new_size, false, Image.FORMAT_R8)
	else:
		_fog_image.fill(0)
	_apply_mask_to_image()

	if _fog_texture == null:
		_fog_texture = ImageTexture.create_from_image(_fog_image)
	else:
		_fog_texture.update(_fog_image)
	if _shader_mat != null and _fog_texture != null:
		_shader_mat.set_shader_parameter(&"fog_texture", _fog_texture)


func _required_buffer_size_for_min_zoom() -> int:
	var min_zoom: float = FALLBACK_MIN_ZOOM
	var min_val: Variant = Settings.get_min("view.zoom")
	if min_val != null:
		min_zoom = float(min_val)
	return _required_buffer_size_cells(min_zoom)


func _required_buffer_size_cells(zoom: float) -> int:
	var safe_zoom: float = zoom if not is_zero_approx(zoom) else 1.0
	var vp_size: Vector2 = ViewProjection.get_viewport_size()
	var pad: int = maxi(maxi(_player_reveal_radius, _initial_reveal_radius), _recenter_margin_cells)
	var radius: int = ViewTransformsScript.visible_grid_radius_from_viewport(vp_size, safe_zoom, pad)
	var required: int = maxi(radius * 2, _settings_buffer_floor)
	required = _round_up_to_step(required, BUFFER_SIZE_STEP_CELLS)
	return mini(required, MAX_BUFFER_SIZE_CELLS)


func _round_up_to_step(value: int, step: int) -> int:
	if step <= 0:
		return value
	return int(ceil(float(value) / float(step))) * step


func _clear_mask_bytes() -> void:
	_mask_bytes.fill(0)


func _apply_mask_to_image() -> void:
	if _fog_image == null:
		return
	_fog_image.set_data(_buffer_size_cells, _buffer_size_cells, false, Image.FORMAT_R8, _mask_bytes)


func _commit_mask_to_gpu() -> void:
	_apply_mask_to_image()
	if _fog_texture != null:
		_fog_texture.update(_fog_image)


func _fill_buffer_from_core() -> void:
	if _visibility == null or not _visibility.has_method("FillRevealedMaskNative"):
		return
	var raw_array = _visibility.FillRevealedMaskNative(
		_buffer_origin_grid.x,
		_buffer_origin_grid.y,
		_buffer_size_cells,
		_buffer_size_cells
	)
	if raw_array != null:
		_mask_bytes = PackedByteArray(raw_array)


func _recompute_buffer_origin() -> void:
	var half: int = _buffer_size_cells >> 1
	_buffer_origin_grid = _current_buffer_center_grid - Vector2i(half, half)


func _bind_buffer_layout_uniforms() -> void:
	if _shader_mat == null:
		return
	var cell_px := float(ViewMetricsRes.CELL_SIZE_PX)
	var world_buffer_origin_px := Vector2(_buffer_origin_grid) * cell_px
	_shader_mat.set_shader_parameter(&"world_buffer_origin_px", world_buffer_origin_px)
	_shader_mat.set_shader_parameter(&"buffer_size_cells", Vector2(_buffer_size_cells, _buffer_size_cells))
	_shader_mat.set_shader_parameter(&"cell_size_px", cell_px)
	_shader_mat.set_shader_parameter(&"fog_opacity", 1.0)
	if _fog_texture != null:
		_shader_mat.set_shader_parameter(&"fog_texture", _fog_texture)


func _push_projection_uniforms(frame: ViewFrameScript) -> void:
	if _shader_mat == null:
		return
	var canvas_to_map: Transform2D = frame.canvas_to_map_local
	if _canvas_to_map_cached and canvas_to_map.is_equal_approx(_cached_canvas_to_map):
		return
	_shader_mat.set_shader_parameter(&"canvas_to_map_x", canvas_to_map.x)
	_shader_mat.set_shader_parameter(&"canvas_to_map_y", canvas_to_map.y)
	_shader_mat.set_shader_parameter(&"canvas_to_map_origin", canvas_to_map.origin)
	_cached_canvas_to_map = canvas_to_map
	_canvas_to_map_cached = true


func _invalidate_projection_cache() -> void:
	_cached_canvas_to_map = Transform2D.IDENTITY
	_canvas_to_map_cached = false


func _mask_index_for_cell(player_cell: Vector2i) -> int:
	var local: Vector2i = player_cell - _buffer_origin_grid
	if local.x < 0 or local.y < 0:
		return -1
	if local.x >= _buffer_size_cells or local.y >= _buffer_size_cells:
		return -1
	var idx: int = local.y * _buffer_size_cells + local.x
	if idx < 0 or idx >= _mask_bytes.size():
		return -1
	return idx


func _load_reveal_radii_from_settings() -> void:
	_initial_reveal_radius = maxi(Settings.initial_reveal_radius, 1)
	_player_reveal_radius = maxi(Settings.player_reveal_radius, 1)


func _on_fog_settings_changed() -> void:
	_load_reveal_radii_from_settings()
	if _visibility != null:
		_visibility.InitialRevealRadius = _initial_reveal_radius
		_visibility.MovementRevealRadius = _player_reveal_radius


func _read_buffer_settings() -> void:
	_settings_buffer_floor = _read_int_setting(&"fog.buffer_size_cells", DEFAULT_BUFFER_SIZE_CELLS)
	_recenter_margin_cells = _read_int_setting(
		&"fog.recenter_margin_cells",
		DEFAULT_RECENTER_MARGIN_CELLS
	)


func _read_int_setting(key: StringName, default_value: int) -> int:
	if Settings.has(key):
		return maxi(int(Settings.get_float(key)), 0)
	return default_value
