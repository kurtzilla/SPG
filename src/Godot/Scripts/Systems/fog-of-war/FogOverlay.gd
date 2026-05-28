extends Node2D

## Sliding-window fog presentation buffer (1 texel = 1 grid cell).
## Authoritative exploration history lives in Core VisibilityModel.

const FOG_SHADER: Shader = preload("res://src/Godot/Shaders/FogOverlay.gdshader")
const ViewMetricsRes = preload("res://src/Godot/Scripts/ViewMetrics.gd")

const PATH_INITIAL_REVEAL: String = "fog.initial_reveal_radius"
const PATH_PLAYER_REVEAL: String = "fog.player_reveal_radius"

const DEFAULT_BUFFER_SIZE_CELLS: int = 128
const DEFAULT_RECENTER_MARGIN_CELLS: int = 24
const DEFAULT_INITIAL_REVEAL_RADIUS: int = 20
const DEFAULT_PLAYER_REVEAL_RADIUS: int = 8

@onready var _fog_rect: ColorRect = $FogRect

var _shader_mat: ShaderMaterial
var _visibility: Object

var _fog_image: Image
var _fog_texture: ImageTexture

var _buffer_size_cells: int = DEFAULT_BUFFER_SIZE_CELLS
var _recenter_margin_cells: int = DEFAULT_RECENTER_MARGIN_CELLS
var _initial_reveal_radius: int = DEFAULT_INITIAL_REVEAL_RADIUS
var _player_reveal_radius: int = DEFAULT_PLAYER_REVEAL_RADIUS

var _current_buffer_center_grid: Vector2i = Vector2i.ZERO
var _buffer_origin_grid: Vector2i = Vector2i.ZERO
var _last_reveal_cell: Vector2i = Vector2i(999999, 999999)
var _is_first_draw: bool = true
var _configured: bool = false


func _ready() -> void:
	z_as_relative = false
	z_index = 100
	_fog_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fog_rect.color = Color(0.0, 0.0, 0.0, 0.0)

	_shader_mat = ShaderMaterial.new()
	_shader_mat.shader = FOG_SHADER
	_fog_rect.material = _shader_mat

	_read_buffer_settings()


func get_shader_material() -> ShaderMaterial:
	return _shader_mat


func set_enabled_visible(fog_enabled: bool) -> void:
	visible = fog_enabled


## Re-align fog quad + texture after scroll/zoom changes (viewport-sized coverage check).
func sync_view_transform(
	viewport_size: Vector2,
	zoom: float,
	player_cell: Vector2i,
	camera_center: Vector2
) -> void:
	if not _configured or _visibility == null:
		return

	_sync_view_uniforms(viewport_size, zoom, camera_center)
	_warn_if_viewport_exceeds_buffer(viewport_size, zoom)

	if player_cell != _current_buffer_center_grid or _needs_recenter(player_cell):
		_recenter_buffer(player_cell, 0)
	else:
		_apply_rect_layout()
		_sync_buffer_center_uniform()
		_fill_buffer_from_core()
		_fog_texture.update(_fog_image)


func setup(visibility: Object, start_cell: Vector2i) -> void:
	_visibility = visibility
	_read_buffer_settings()
	_load_reveal_radii_from_settings()

	_fog_image = Image.create(_buffer_size_cells, _buffer_size_cells, false, Image.FORMAT_R8)
	_fog_image.fill(Color(0, 0, 0, 1))

	_fog_texture = ImageTexture.create_from_image(_fog_image)

	_current_buffer_center_grid = start_cell
	_recompute_buffer_origin()
	_apply_rect_layout()
	_bind_shader_uniforms()

	_configured = true
	_is_first_draw = true
	_last_reveal_cell = Vector2i(999999, 999999)
	_bootstrap_initial_reveal(start_cell)


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
		_fog_texture.update(_fog_image)


func reveal_cells_at(grid_coord: Vector2i, radius_cells: int) -> void:
	if _visibility == null:
		return

	_visibility.RevealDisc(grid_coord.x, grid_coord.y, radius_cells)
	_stamp_disc_in_buffer(grid_coord, radius_cells)


func _needs_recenter(cell: Vector2i) -> bool:
	var local: Vector2i = cell - _buffer_origin_grid
	var margin: int = _recenter_margin_cells
	return (
		local.x < margin
		or local.y < margin
		or local.x >= _buffer_size_cells - margin
		or local.y >= _buffer_size_cells - margin
	)


func _recenter_buffer(new_center: Vector2i, pending_radius: int) -> void:
	_current_buffer_center_grid = new_center
	_recompute_buffer_origin()
	_apply_rect_layout()
	_sync_buffer_center_uniform()

	_fog_image.fill(Color(0, 0, 0, 1))
	_fill_buffer_from_core()
	reveal_cells_at(_last_reveal_cell, pending_radius)
	_fog_texture.update(_fog_image)


func _fill_buffer_from_core() -> void:
	var origin: Vector2i = _buffer_origin_grid
	var mask: PackedByteArray = PackedByteArray(
		_visibility.FillRevealedMask(
			origin.x,
			origin.y,
			_buffer_size_cells,
			_buffer_size_cells
		)
	)
	if mask.size() != _buffer_size_cells * _buffer_size_cells:
		push_warning(
			"FogOverlay: FillRevealedMask size mismatch (got %d, expected %d)"
			% [mask.size(), _buffer_size_cells * _buffer_size_cells]
		)
		return
	_fog_image.set_data(_buffer_size_cells, _buffer_size_cells, false, Image.FORMAT_R8, mask)


func _stamp_disc_in_buffer(center: Vector2i, radius_cells: int) -> void:
	var r_sq: int = radius_cells * radius_cells
	var min_x: int = center.x - radius_cells
	var max_x: int = center.x + radius_cells
	var min_y: int = center.y - radius_cells
	var max_y: int = center.y + radius_cells
	var revealed := Color(1, 1, 1, 1)

	for gy in range(min_y, max_y + 1):
		var dy: int = gy - center.y
		var dy_sq: int = dy * dy
		for gx in range(min_x, max_x + 1):
			var dx: int = gx - center.x
			if dx * dx + dy_sq > r_sq:
				continue
			var local: Vector2i = Vector2i(gx, gy) - _buffer_origin_grid
			if local.x < 0 or local.y < 0:
				continue
			if local.x >= _buffer_size_cells or local.y >= _buffer_size_cells:
				continue
			_fog_image.set_pixel(local.x, local.y, revealed)


func _recompute_buffer_origin() -> void:
	var half: int = _buffer_size_cells >> 1
	_buffer_origin_grid = _current_buffer_center_grid - Vector2i(half, half)


func _apply_rect_layout() -> void:
	var vp_size: Vector2 = get_viewport_rect().size
	position = Vector2.ZERO
	_fog_rect.position = Vector2.ZERO
	_fog_rect.size = vp_size
	_fog_rect.offset_left = 0.0
	_fog_rect.offset_top = 0.0
	_fog_rect.offset_right = vp_size.x
	_fog_rect.offset_bottom = vp_size.y


func _world_buffer_center_px() -> Vector2:
	var cell_px: float = float(ViewMetricsRes.CELL_SIZE_PX)
	return Vector2(_current_buffer_center_grid) * cell_px


func _bind_shader_uniforms() -> void:
	if _shader_mat == null:
		return
	_shader_mat.set_shader_parameter(&"fog_data_texture", _fog_texture)
	_shader_mat.set_shader_parameter(&"buffer_size_cells", float(_buffer_size_cells))
	_shader_mat.set_shader_parameter(&"cell_size_px", float(ViewMetricsRes.CELL_SIZE_PX))
	_shader_mat.set_shader_parameter(&"zoom", 1.0)
	_shader_mat.set_shader_parameter(&"rect_size", _fog_rect.size)
	_shader_mat.set_shader_parameter(&"world_camera_center_px", _world_buffer_center_px())
	_shader_mat.set_shader_parameter(&"fog_color", Color(0.0, 0.0, 0.0, 0.85))
	_sync_buffer_center_uniform()


func _sync_buffer_center_uniform() -> void:
	if _shader_mat != null:
		_shader_mat.set_shader_parameter(&"world_buffer_center_px", _world_buffer_center_px())


func _sync_view_uniforms(viewport_size: Vector2, view_zoom: float, camera_center: Vector2) -> void:
	if _shader_mat == null:
		return
	var vp_size: Vector2 = viewport_size
	_fog_rect.size = vp_size
	_fog_rect.offset_right = vp_size.x
	_fog_rect.offset_bottom = vp_size.y
	_shader_mat.set_shader_parameter(&"rect_size", vp_size)
	_shader_mat.set_shader_parameter(&"world_camera_center_px", camera_center)
	_shader_mat.set_shader_parameter(&"world_buffer_center_px", _current_buffer_center_grid * 64.0)
	_shader_mat.set_shader_parameter(&"zoom", view_zoom if has_node("/root/ViewProjection") else 1.0)


func _bootstrap_initial_reveal(start_cell: Vector2i) -> void:
	if not _is_first_draw or _visibility == null:
		return
	var radius: int = maxi(int(Settings.initial_reveal_radius), 1)
	reveal_cells_at(start_cell, radius)
	_fog_texture.update(_fog_image)
	_last_reveal_cell = start_cell
	_is_first_draw = false


func _load_reveal_radii_from_settings() -> void:
	_initial_reveal_radius = maxi(
		int(Settings.get_setting(PATH_INITIAL_REVEAL, DEFAULT_INITIAL_REVEAL_RADIUS)),
		1
	)
	_player_reveal_radius = maxi(
		int(Settings.get_setting(PATH_PLAYER_REVEAL, DEFAULT_PLAYER_REVEAL_RADIUS)),
		1
	)


func _read_buffer_settings() -> void:
	_buffer_size_cells = _read_int_setting(&"fog.buffer_size_cells", DEFAULT_BUFFER_SIZE_CELLS)
	_recenter_margin_cells = _read_int_setting(
		&"fog.recenter_margin_cells",
		DEFAULT_RECENTER_MARGIN_CELLS
	)


func _read_int_setting(key: StringName, default_value: int) -> int:
	if Settings.has(key):
		return maxi(int(Settings.get_float(key)), 1)
	return default_value


func _warn_if_viewport_exceeds_buffer(viewport_size: Vector2, zoom: float) -> void:
	if viewport_size.x < 1.0 or viewport_size.y < 1.0:
		return
	var half_buffer: int = _buffer_size_cells >> 1
	var cell_px_scaled: float = float(ViewMetricsRes.CELL_SIZE_PX) * maxf(zoom, 0.0001)
	var view_half_cells: int = int(
		ceil(maxf(viewport_size.x, viewport_size.y) * 0.5 / cell_px_scaled)
	)
	if view_half_cells > half_buffer - _recenter_margin_cells:
		push_warning(
			"FogOverlay: viewport (~%d cells) exceeds buffer half (%d); increase fog.buffer_size_cells or zoom in"
			% [view_half_cells, half_buffer]
		)
