class_name FogOverlay
extends CanvasLayer

## Sliding-window fog presentation buffer (1 texel = 1 grid cell).
## Screen-space fullscreen quad; shader projects canvas px to map-local via ViewProjection uniforms.

const FOG_SHADER: Shader = preload("res://src/Godot/Shaders/FogOverlay.gdshader")
const ViewMetricsRes = preload("res://src/Godot/Scripts/ViewMetrics.gd")
const ViewTransformsScript = preload("res://src/Godot/Scripts/ViewTransforms.gd")

const PATH_BOOTSTRAP_ROWS: String = "fog.bootstrap_rows_per_frame"

const DEFAULT_BUFFER_SIZE_CELLS: int = 128
const DEFAULT_RECENTER_MARGIN_CELLS: int = 24
const DEFAULT_INITIAL_REVEAL_RADIUS: int = 20
const DEFAULT_PLAYER_REVEAL_RADIUS: int = 8
const DEFAULT_BOOTSTRAP_ROWS_PER_FRAME: int = 0
const ASYNC_BOOTSTRAP_MIN_RADIUS: int = 32
const ASYNC_BOOTSTRAP_CELLS_PER_ROW_BATCH: int = 256

const REVEALED_BYTE: int = 255

@onready var _fog_rect: ColorRect = $FogRect

var _shader_mat: ShaderMaterial
var _visibility: Object

var _fog_image: Image
var _fog_texture: ImageTexture
var _mask_bytes: PackedByteArray = PackedByteArray()

var _buffer_size_cells: int = DEFAULT_BUFFER_SIZE_CELLS
var _recenter_margin_cells: int = DEFAULT_RECENTER_MARGIN_CELLS
var _initial_reveal_radius: int = DEFAULT_INITIAL_REVEAL_RADIUS
var _player_reveal_radius: int = DEFAULT_PLAYER_REVEAL_RADIUS
var _bootstrap_rows_per_frame: int = DEFAULT_BOOTSTRAP_ROWS_PER_FRAME

var _current_buffer_center_grid: Vector2i = Vector2i.ZERO
var _buffer_origin_grid: Vector2i = Vector2i.ZERO
var _last_reveal_cell: Vector2i = Vector2i(999999, 999999)
var _is_first_draw: bool = true
var _configured: bool = false
var _buffer_seeded_from_disc: bool = false
var _bootstrap_in_progress: bool = false
var _projection_aligned: bool = false
var _fog_enabled: bool = false

var _cached_viewport_center: Vector2 = Vector2(-99999.0, -99999.0)
var _cached_camera_focus: Vector2 = Vector2(-99999.0, -99999.0)
var _cached_zoom: float = -1.0


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
	if not ViewProjection.view_changed.is_connected(_on_view_projection_changed):
		ViewProjection.view_changed.connect(_on_view_projection_changed)
	_read_buffer_settings()


func get_shader_material() -> ShaderMaterial:
	return _shader_mat


func set_enabled_visible(fog_enabled: bool) -> void:
	_fog_enabled = fog_enabled
	_update_fog_rect_visibility()


func _update_fog_rect_visibility() -> void:
	var debug_bypass: bool = Settings.has("fog.debug_disable_overlay") and Settings.get_bool("fog.debug_disable_overlay")
	_fog_rect.visible = _configured and _fog_enabled and not debug_bypass


func get_buffer_center_grid() -> Vector2i:
	return _current_buffer_center_grid


func is_configured() -> bool:
	return _configured


func get_mask_center_byte(player_cell: Vector2i) -> int:
	if not _configured or _mask_bytes.is_empty():
		return 0
	var idx: int = _mask_index_for_cell(player_cell)
	if idx < 0:
		return 0
	return int(_mask_bytes[idx])


## Buffer recenters when the player nears the window edge; camera uniforms sync every call.
func sync_view_transform(_center_grid: Vector2i, camera_center: Vector2, current_zoom: float, viewport_center: Vector2) -> void:
	if _shader_mat == null:
		return
	_shader_mat.set_shader_parameter("camera_focus_map_px", camera_center)
	_shader_mat.set_shader_parameter("zoom", current_zoom)
	_shader_mat.set_shader_parameter("viewport_center_px", viewport_center)


func setup(visibility: Object, start_cell: Vector2i) -> void:
	_visibility = visibility
	_read_buffer_settings()
	_load_reveal_radii_from_settings()

	_allocate_mask_buffer()

	_fog_image = Image.create(_buffer_size_cells, _buffer_size_cells, false, Image.FORMAT_R8)
	_apply_mask_to_image()

	_fog_texture = ImageTexture.create_from_image(_fog_image)

	_current_buffer_center_grid = start_cell
	_recompute_buffer_origin()
	_bind_shader_uniforms()
	_sync_buffer_center_shader()

	_configured = true
	_is_first_draw = true
	_buffer_seeded_from_disc = false
	_projection_aligned = false
	_last_reveal_cell = Vector2i(999999, 999999)

	var spawn_focus: Vector2 = ViewTransformsScript.grid_to_map_local_px(
		float(start_cell.x), float(start_cell.y)
	)
	var safe_zoom: float = ViewProjection.zoom
	if is_zero_approx(safe_zoom):
		safe_zoom = 1.0
	_sync_camera_shader_uniforms(
		ViewProjection.get_screen_center_offset(),
		spawn_focus,
		safe_zoom
	)

	var use_async: bool = _should_bootstrap_async()
	print(
		"[FogOverlay] setup start_cell=%s initial_reveal_radius=%d configured=%s async=%s"
		% [start_cell, _initial_reveal_radius, _configured, use_async]
	)

	if use_async:
		_bootstrap_in_progress = true
		_bootstrap_initial_reveal_async(start_cell)
	else:
		_bootstrap_initial_reveal(start_cell)

	on_player_cell_changed(start_cell)


func on_player_cell_changed(cell: Vector2i) -> void:
	if not _configured or _visibility == null or _bootstrap_in_progress:
		return
	if cell == _last_reveal_cell:
		return

	var radius: int = _initial_reveal_radius if _is_first_draw else _player_reveal_radius
	if _is_first_draw:
		_is_first_draw = false
	_last_reveal_cell = cell
	_buffer_seeded_from_disc = false

	if _needs_recenter(cell):
		_recenter_buffer(cell, radius)
	else:
		reveal_cells_at(cell, radius)
		_commit_mask_to_gpu()


func reveal_cells_at(grid_coord: Vector2i, radius_cells: int) -> void:
	if _visibility == null:
		return

	if _visibility.has_method("RevealDiscCollect"):
		var new_cells: Array = _visibility.RevealDiscCollect(grid_coord.x, grid_coord.y, radius_cells)
		_stamp_cells_in_buffer(new_cells)
	elif _visibility.has_method("RevealDisc"):
		_visibility.RevealDisc(grid_coord.x, grid_coord.y, radius_cells)
		_fill_buffer_from_core()


func _needs_recenter(cell: Vector2i) -> bool:
	var local: Vector2i = cell - _buffer_origin_grid

	# Dynamically scale the margin to your maximum possible sight line plus a small safety buffer.
	# This prevents clipping at texture boundaries and avoids the fixed dead-zone trap.
	var dynamic_margin: int = maxi(_player_reveal_radius, _initial_reveal_radius) + 2

	return (
		local.x < dynamic_margin
		or local.y < dynamic_margin
		or local.x >= _buffer_size_cells - dynamic_margin
		or local.y >= _buffer_size_cells - dynamic_margin
	)


func _recenter_buffer(new_center: Vector2i, pending_radius: int) -> void:
	_buffer_seeded_from_disc = false
	_current_buffer_center_grid = new_center
	_recompute_buffer_origin()
	_sync_buffer_center_shader()

	_clear_mask_bytes()
	_fill_buffer_from_core()
	var radius: int = _effective_reveal_radius(pending_radius)
	reveal_cells_at(new_center, radius)
	_commit_mask_to_gpu()
	_verify_center_revealed(new_center)


func _effective_reveal_radius(pending_radius: int) -> int:
	if pending_radius > 0:
		return pending_radius
	if _is_first_draw:
		return _initial_reveal_radius
	return _player_reveal_radius


func _allocate_mask_buffer() -> void:
	var mask_size: int = _buffer_size_cells * _buffer_size_cells
	_mask_bytes.resize(mask_size)
	_clear_mask_bytes()


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
	if OS.is_debug_build():
		_debug_log_mask_nonzero_count()


func _reveal_disc_stamp_into_buffer(_grid_coord: Vector2i, _radius_cells: int) -> bool:
	return false


## Bulk history restore: row-major mask from Core into reusable scratch buffer.
func _fill_buffer_from_core() -> void:
	if _visibility == null or not _visibility.has_method("FillRevealedMask"):
		return
	var origin: Vector2i = _buffer_origin_grid
	var expected: int = _buffer_size_cells * _buffer_size_cells
	var mask: PackedByteArray = PackedByteArray(
		_visibility.FillRevealedMask(
			origin.x,
			origin.y,
			_buffer_size_cells,
			_buffer_size_cells
		)
	)
	if mask.size() != expected:
		push_warning(
			"FogOverlay: FillRevealedMask size mismatch (got %d, expected %d)"
			% [mask.size(), expected]
		)
		return
	_mask_bytes = mask


func _stamp_cells_in_buffer(cells: Array) -> void:
	var w: int = _buffer_size_cells
	for cell in cells:
		var gx: int
		var gy: int
		if cell is Vector2i:
			gx = cell.x
			gy = cell.y
		else:
			gx = int(cell.x)
			gy = int(cell.y)
		var local: Vector2i = Vector2i(gx, gy) - _buffer_origin_grid
		if local.x < 0 or local.y < 0:
			continue
		if local.x >= w or local.y >= w:
			continue
		_mask_bytes[local.y * w + local.x] = REVEALED_BYTE
	_buffer_seeded_from_disc = true


func _recompute_buffer_origin() -> void:
	var half: int = _buffer_size_cells >> 1
	_buffer_origin_grid = _current_buffer_center_grid - Vector2i(half, half)


func _sync_buffer_center_shader() -> void:
	if _shader_mat == null:
		return
	var cell_px := float(ViewMetricsRes.CELL_SIZE_PX)
	var buffer_center_px := Vector2(_current_buffer_center_grid) * cell_px
	_shader_mat.set_shader_parameter(&"buffer_size_cells", float(_buffer_size_cells))
	_shader_mat.set_shader_parameter(&"world_buffer_center_px", buffer_center_px)


func _resolve_player_cell_from_scene() -> Vector2i:
	var player: Node2D = _find_player_node()
	if player == null:
		return Vector2i.ZERO
	ViewProjection.register_camera_focus(player.position)
	return ViewProjection.resolve_map_center_from_player(player)


func _resolve_camera_focus(explicit: Vector2) -> Vector2:
	if explicit.is_finite() and ViewProjection.is_camera_registered():
		return explicit
	return ViewProjection.resolve_camera_focus_map_px(_find_player_node())


func _on_view_projection_changed() -> void:
	if not _configured or _shader_mat == null:
		return
	var player: Node2D = _find_player_node()
	var focus: Vector2 = ViewProjection.resolve_camera_focus_map_px(player)
	var center: Vector2 = ViewProjection.get_screen_center_offset()
	var safe_zoom: float = ViewProjection.zoom
	if is_zero_approx(safe_zoom):
		safe_zoom = 1.0
	_sync_camera_shader_uniforms(center, focus, safe_zoom)


func _verify_center_revealed(player_cell: Vector2i) -> void:
	if not _configured or _mask_bytes.is_empty():
		return
	var idx: int = _mask_index_for_cell(player_cell)
	if idx < 0:
		return
	if _mask_bytes[idx] != 0:
		return
	reveal_cells_at(player_cell, _initial_reveal_radius)
	_commit_mask_to_gpu()


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


func _debug_log_mask_nonzero_count() -> void:
	var nonzero: int = 0
	for i: int in _mask_bytes.size():
		if _mask_bytes[i] != 0:
			nonzero += 1
	if nonzero == 0:
		push_warning("[FogOverlay] fog mask has zero revealed cells after commit")
	else:
		print("[FogOverlay] fog mask nonzero cells=%d / %d" % [nonzero, _mask_bytes.size()])


func _sync_camera_shader_uniforms(viewport_center: Vector2, camera_focus: Vector2, zoom: float) -> void:
	if _shader_mat == null:
		return
	var safe_zoom: float = zoom if not is_zero_approx(zoom) else 1.0
	if viewport_center != _cached_viewport_center:
		_shader_mat.set_shader_parameter(&"viewport_center_px", viewport_center)
		_cached_viewport_center = viewport_center
	if camera_focus != _cached_camera_focus:
		_shader_mat.set_shader_parameter(&"camera_focus_map_px", camera_focus)
		_cached_camera_focus = camera_focus
	if not is_equal_approx(safe_zoom, _cached_zoom):
		_shader_mat.set_shader_parameter(&"zoom", safe_zoom)
		_cached_zoom = safe_zoom


func _bind_shader_uniforms() -> void:
	if _shader_mat == null:
		return
	_shader_mat.set_shader_parameter(&"fog_data_texture", _fog_texture)
	_shader_mat.set_shader_parameter(&"buffer_size_cells", float(_buffer_size_cells))
	_shader_mat.set_shader_parameter(&"cell_size_px", float(ViewMetricsRes.CELL_SIZE_PX))
	_shader_mat.set_shader_parameter(&"fog_color", Color(0.0, 0.0, 0.0, 0.85))


func _bootstrap_initial_reveal(start_cell: Vector2i) -> void:
	if not _is_first_draw or _visibility == null:
		print(
			"[FogOverlay] bootstrap reveal skipped: is_first_draw=%s visibility=%s"
			% [_is_first_draw, _visibility]
		)
		return
	var radius: int = maxi(_initial_reveal_radius, 1)
	print("[FogOverlay] bootstrap reveal start_cell=%s radius=%d" % [start_cell, radius])
	reveal_cells_at(start_cell, radius)
	_commit_mask_to_gpu()
	_last_reveal_cell = start_cell
	_is_first_draw = false
	print("[FogOverlay] bootstrap reveal committed; last_reveal_cell=%s" % _last_reveal_cell)
	_verify_center_revealed(start_cell)


func _bootstrap_initial_reveal_async(start_cell: Vector2i) -> void:
	if not _is_first_draw or _visibility == null:
		_bootstrap_in_progress = false
		return

	var radius: int = maxi(_initial_reveal_radius, 1)
	if _reveal_disc_stamp_into_buffer(start_cell, radius):
		_commit_mask_to_gpu()
	else:
		if not _visibility.has_method("RevealDiscCollect"):
			_bootstrap_initial_reveal(start_cell)
			_bootstrap_in_progress = false
			return

		var new_cells: Array = _visibility.RevealDiscCollect(start_cell.x, start_cell.y, radius)
		var batch: int = maxi(_bootstrap_rows_per_frame * ASYNC_BOOTSTRAP_CELLS_PER_ROW_BATCH, 1)
		var i: int = 0
		while i < new_cells.size():
			var end_i: int = mini(i + batch, new_cells.size())
			var slice: Array = new_cells.slice(i, end_i)
			_stamp_cells_in_buffer(slice)
			_commit_mask_to_gpu()
			i = end_i
			if i < new_cells.size():
				await get_tree().process_frame

	_last_reveal_cell = start_cell
	_is_first_draw = false
	_bootstrap_in_progress = false
	var focus: Vector2 = ViewProjection.resolve_camera_focus_map_px(_find_player_node())
	_sync_camera_shader_uniforms(
		ViewProjection.get_screen_center_offset(),
		focus,
		ViewProjection.zoom
	)
	var pending_cell: Vector2i = _resolve_player_cell_from_scene()
	if pending_cell != _last_reveal_cell:
		on_player_cell_changed(pending_cell)


func _find_player_node() -> Node2D:
	var tree: SceneTree = get_tree()
	if tree == null:
		return null
	var players: Array[Node] = tree.get_nodes_in_group("player")
	if players.is_empty():
		return null
	return players[0] as Node2D


func _should_bootstrap_async() -> bool:
	if _bootstrap_rows_per_frame <= 0:
		return false
	var radius: int = maxi(_initial_reveal_radius, 1)
	return radius >= ASYNC_BOOTSTRAP_MIN_RADIUS


func _load_reveal_radii_from_settings() -> void:
	_initial_reveal_radius = maxi(Settings.initial_reveal_radius, 1)
	_player_reveal_radius = maxi(Settings.player_reveal_radius, 1)


func _on_fog_settings_changed() -> void:
	_load_reveal_radii_from_settings()
	if _visibility != null:
		_visibility.InitialRevealRadius = _initial_reveal_radius
		_visibility.MovementRevealRadius = _player_reveal_radius


func _read_buffer_settings() -> void:
	_buffer_size_cells = _read_int_setting(&"fog.buffer_size_cells", DEFAULT_BUFFER_SIZE_CELLS)
	_recenter_margin_cells = _read_int_setting(
		&"fog.recenter_margin_cells",
		DEFAULT_RECENTER_MARGIN_CELLS
	)
	_bootstrap_rows_per_frame = _read_int_setting(
		PATH_BOOTSTRAP_ROWS,
		DEFAULT_BOOTSTRAP_ROWS_PER_FRAME
	)


func _read_int_setting(key: StringName, default_value: int) -> int:
	if Settings.has(key):
		return maxi(int(Settings.get_float(key)), 0)
	return default_value


func _warn_if_viewport_exceeds_buffer(viewport_size: Vector2, zoom: float) -> void:
	if viewport_size.x < 1.0 or viewport_size.y < 1.0:
		return
	var half_buffer: int = _buffer_size_cells >> 1
	var cell_px_scaled: float = ViewTransformsScript.on_screen_cell_px(zoom)
	var view_half_cells: int = int(
		ceil(maxf(viewport_size.x, viewport_size.y) * 0.5 / cell_px_scaled)
	)
	if view_half_cells > half_buffer - _recenter_margin_cells:
		push_warning(
			"FogOverlay: viewport (~%d cells) exceeds buffer half (%d); increase fog.buffer_size_cells or zoom in"
			% [view_half_cells, half_buffer]
		)
