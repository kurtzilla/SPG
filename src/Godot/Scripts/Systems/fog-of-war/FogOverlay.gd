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
const MAX_BUFFER_SIZE_CELLS: int = 512
const BUFFER_SIZE_STEP_CELLS: int = 32

const REVEALED_BYTE: int = 255
const DEFAULT_FOG_OPACITY: float = 0.85

@onready var _fog_rect: ColorRect = $FogRect

var _shader_mat: ShaderMaterial
var _visibility: Object

var _fog_image: Image
var _fog_texture: ImageTexture
var _mask_bytes: PackedByteArray = PackedByteArray()

var _buffer_size_cells: int = DEFAULT_BUFFER_SIZE_CELLS
var _settings_buffer_floor: int = DEFAULT_BUFFER_SIZE_CELLS
var _recenter_margin_cells: int = DEFAULT_RECENTER_MARGIN_CELLS
var _initial_reveal_radius: int = DEFAULT_INITIAL_REVEAL_RADIUS
var _player_reveal_radius: int = DEFAULT_PLAYER_REVEAL_RADIUS
var _bootstrap_rows_per_frame: int = DEFAULT_BOOTSTRAP_ROWS_PER_FRAME

var _current_buffer_center_grid: Vector2i = Vector2i.ZERO
var _buffer_origin_grid: Vector2i = Vector2i.ZERO
var _last_fill_origin_grid: Vector2i = Vector2i(999999, 999999)
var _last_reveal_cell: Vector2i = Vector2i(999999, 999999)
var _is_first_draw: bool = true
var _configured: bool = false
var _buffer_seeded_from_disc: bool = false
var _bootstrap_in_progress: bool = false
var _projection_aligned: bool = false
var _fog_enabled: bool = false

var _cached_viewport_center: Vector2 = Vector2(-99999.0, -99999.0)
var _cached_camera_focus: Vector2 = Vector2(-99999.0, -99999.0)
var _cached_player_world_pos: Vector2 = Vector2(-99999.0, -99999.0)
var _cached_zoom: float = -1.0

var _debug_bootstrap_logged: bool = false
var _debug_shader_snapshot_logged: bool = false


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
	if not ViewProjection.projection_changed.is_connected(_on_projection_changed):
		ViewProjection.projection_changed.connect(_on_projection_changed)
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
func sync_view_transform(
	viewport_center_px: Vector2,
	camera_focus_map_px: Vector2,
	safe_zoom: float,
	player_world_pos: Vector2
) -> void:
	if _shader_mat == null:
		return
	var zoom_val: float = ViewProjection.safe_zoom(safe_zoom)
	if _configured:
		var center_grid: Vector2i = ViewProjection.map_local_px_to_grid_cell(camera_focus_map_px)
		_ensure_buffer_covers_viewport(zoom_val, center_grid)
	_push_projection_uniforms(viewport_center_px, camera_focus_map_px, zoom_val, player_world_pos)
	if OS.is_debug_build() and _configured and not _debug_shader_snapshot_logged:
		_debug_shader_snapshot_logged = true
		_debug_log_shader_snapshot(viewport_center_px, camera_focus_map_px, zoom_val)


func setup(visibility: Object, start_cell: Vector2i) -> void:
	_visibility = visibility
	_read_buffer_settings()
	_load_reveal_radii_from_settings()

	var safe_zoom: float = ViewProjection.zoom
	if is_zero_approx(safe_zoom):
		safe_zoom = 1.0
	_current_buffer_center_grid = start_cell
	_rebuild_buffer_storage(_required_buffer_size_cells(safe_zoom))

	_recompute_buffer_origin()
	_bind_shader_uniforms()
	_sync_buffer_center_shader()

	_configured = true
	_is_first_draw = true
	_buffer_seeded_from_disc = false
	_projection_aligned = false
	_last_reveal_cell = Vector2i(999999, 999999)

	_invalidate_projection_cache()
	_sync_projection_uniforms()

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


func reveal_cells_at(grid_coord: Vector2i, radius_cells: int, force_square: bool = false) -> void:
	if _visibility == null:
		return

	if force_square and _visibility.has_method("RevealSquare"):
		_visibility.RevealSquare(grid_coord.x, grid_coord.y, radius_cells)
	elif _visibility.has_method("RevealDisc"):
		_visibility.RevealDisc(grid_coord.x, grid_coord.y, radius_cells)
	elif _visibility.has_method("RevealDiscCollect"):
		var _discard: Array = _visibility.RevealDiscCollect(grid_coord.x, grid_coord.y, radius_cells)

	_fill_buffer_from_core()


func _needs_recenter(cell: Vector2i) -> bool:
	var local: Vector2i = cell - _buffer_origin_grid

	var safe_zoom: float = ViewProjection.zoom
	if is_zero_approx(safe_zoom):
		safe_zoom = 1.0
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
	_configure_fog_texture()
	if _shader_mat != null and _fog_texture != null:
		_shader_mat.set_shader_parameter(&"fog_texture", _fog_texture)


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


func _ensure_buffer_covers_viewport(zoom: float, center_grid: Vector2i) -> void:
	if not _configured or _bootstrap_in_progress:
		return

	var required: int = _required_buffer_size_cells(zoom)
	if required == _buffer_size_cells:
		if OS.is_debug_build():
			_warn_if_viewport_exceeds_buffer(ViewProjection.get_viewport_size(), zoom)
		return

	if OS.is_debug_build():
		print(
			"[FogOverlay] buffer resize %d -> %d (zoom=%s)"
			% [_buffer_size_cells, required, zoom]
		)

	_current_buffer_center_grid = center_grid
	_rebuild_buffer_storage(required)
	_recompute_buffer_origin()
	_bind_buffer_layout_uniforms()
	_last_fill_origin_grid = Vector2i(999999, 999999)
	_fill_buffer_from_core()
	_commit_mask_to_gpu()
	if OS.is_debug_build():
		_warn_if_viewport_exceeds_buffer(ViewProjection.get_viewport_size(), zoom)


func _clear_mask_bytes() -> void:
	_mask_bytes.fill(0)


func _configure_fog_texture() -> void:
	if _fog_texture == null:
		return
	# Runtime ImageTexture has no repeat toggle; out-of-bounds samples return opaque fog in
	# FogOverlay.gdshader instead of clamping edge texels across the viewport.


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
	if _visibility == null or not _visibility.has_method("FillRevealedMaskNative"):
		return

	var origin: Vector2i = _buffer_origin_grid

	if origin != _last_fill_origin_grid:
		print("[FogOverlay:BufferShift] Origin Grid: ", origin, " Size: ", _buffer_size_cells)
		_last_fill_origin_grid = origin

	var raw_array = _visibility.FillRevealedMaskNative(
		origin.x,
		origin.y,
		_buffer_size_cells,
		_buffer_size_cells
	)

	if raw_array != null:
		_mask_bytes = PackedByteArray(raw_array)


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
	_bind_buffer_layout_uniforms()


func _bind_buffer_layout_uniforms() -> void:
	if _shader_mat == null:
		return
	var cell_px := float(ViewMetricsRes.CELL_SIZE_PX)
	var world_buffer_origin_px := Vector2(_buffer_origin_grid) * cell_px

	_shader_mat.set_shader_parameter(&"world_buffer_origin_px", world_buffer_origin_px)
	_shader_mat.set_shader_parameter(&"buffer_size_cells", Vector2(_buffer_size_cells, _buffer_size_cells))
	_shader_mat.set_shader_parameter(&"cell_size_px", cell_px)
	_shader_mat.set_shader_parameter(&"fog_opacity", DEFAULT_FOG_OPACITY)
	if _fog_texture != null:
		_shader_mat.set_shader_parameter(&"fog_texture", _fog_texture)


func _resolve_player_cell_from_scene() -> Vector2i:
	var player: Node2D = _find_player_node()
	if player == null:
		return Vector2i.ZERO
	ViewProjection.register_camera_focus(player.position)
	return ViewProjection.resolve_map_center_from_player(player)


func _resolve_camera_focus() -> Vector2:
	return ViewProjection.resolve_camera_focus_map_px(_find_player_node())


func _sync_projection_uniforms() -> void:
	if _shader_mat == null:
		return
	var player: Node2D = _find_player_node()
	var player_world_pos: Vector2 = player.position if player != null else _resolve_camera_focus()
	_push_projection_uniforms(
		ViewProjection.get_screen_center_offset(),
		_resolve_camera_focus(),
		ViewProjection.safe_zoom(),
		player_world_pos
	)


func _on_projection_changed() -> void:
	if not _configured or _shader_mat == null:
		return
	_invalidate_projection_cache()
	_sync_projection_uniforms()


func _on_view_projection_changed() -> void:
	if not _configured or _shader_mat == null:
		return
	_invalidate_projection_cache()
	var player: Node2D = _find_player_node()
	var safe_zoom: float = ViewProjection.safe_zoom()
	var center_grid: Vector2i = ViewProjection.resolve_camera_center_grid(player)
	_ensure_buffer_covers_viewport(safe_zoom, center_grid)
	_sync_projection_uniforms()


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


func _debug_log_bootstrap_state(start_cell: Vector2i) -> void:
	if not OS.is_debug_build() or _debug_bootstrap_logged or _visibility == null:
		return
	_debug_bootstrap_logged = true

	var revealed_count: int = 0
	if _visibility.has_method("GetRevealedCount"):
		revealed_count = int(_visibility.GetRevealedCount())

	var bounds_text: String = "none"
	if _visibility.has_method("GetRevealedBounds"):
		var bounds: Array = _visibility.GetRevealedBounds()
		if bounds.size() >= 4:
			var min_x: int = int(bounds[0])
			var min_y: int = int(bounds[1])
			var max_x: int = int(bounds[2])
			var max_y: int = int(bounds[3])
			var width: int = max_x - min_x + 1
			var height: int = max_y - min_y + 1
			var expected_span: int = _initial_reveal_radius * 2 + 1
			bounds_text = "[%d,%d]-[%d,%d] size=%dx%d" % [min_x, min_y, max_x, max_y, width, height]
			if width != expected_span or height != expected_span:
				push_warning(
					"[FogOverlay] bootstrap bounds %dx%d != expected square %dx%d"
					% [width, height, expected_span, expected_span]
				)

	var center_byte: int = get_mask_center_byte(start_cell)
	if center_byte != REVEALED_BYTE:
		push_warning(
			"[FogOverlay] bootstrap center cell %s mask byte=%d (expected %d)"
			% [start_cell, center_byte, REVEALED_BYTE]
		)

	print(
		"[FogOverlay] bootstrap debug revealed_count=%d bounds=%s center_byte=%d"
		% [revealed_count, bounds_text, center_byte]
	)


func _debug_log_shader_snapshot(
	viewport_center_px: Vector2,
	camera_focus_map_px: Vector2,
	safe_zoom: float
) -> void:
	var cell_px: float = float(ViewMetricsRes.CELL_SIZE_PX)
	var origin_px: Vector2 = Vector2(_buffer_origin_grid) * cell_px
	print(
		(
			"[FogOverlay] shader snapshot zoom=%s origin_px=%s buffer_cells=%d "
			+ "camera_focus=%s viewport_center=%s"
		)
		% [safe_zoom, origin_px, _buffer_size_cells, camera_focus_map_px, viewport_center_px]
	)


func _push_projection_uniforms(
	viewport_center_px: Vector2,
	camera_focus_map_px: Vector2,
	safe_zoom: float,
	player_world_pos: Vector2
) -> void:
	if _shader_mat == null:
		return
	var center_changed: bool = viewport_center_px != _cached_viewport_center
	var focus_changed: bool = camera_focus_map_px != _cached_camera_focus
	var player_changed: bool = player_world_pos != _cached_player_world_pos
	var zoom_changed: bool = not is_equal_approx(safe_zoom, _cached_zoom)
	if not center_changed and not focus_changed and not player_changed and not zoom_changed:
		return
	if center_changed:
		_shader_mat.set_shader_parameter(&"viewport_center_px", viewport_center_px)
	if focus_changed:
		_shader_mat.set_shader_parameter(&"camera_focus_map_px", camera_focus_map_px)
	if zoom_changed:
		_shader_mat.set_shader_parameter(&"zoom", safe_zoom)
	if player_changed:
		_shader_mat.set_shader_parameter(&"player_world_pos", player_world_pos)
	_cached_viewport_center = viewport_center_px
	_cached_camera_focus = camera_focus_map_px
	_cached_player_world_pos = player_world_pos
	_cached_zoom = safe_zoom


func _invalidate_projection_cache() -> void:
	_cached_viewport_center = Vector2(-99999.0, -99999.0)
	_cached_camera_focus = Vector2(-99999.0, -99999.0)
	_cached_player_world_pos = Vector2(-99999.0, -99999.0)
	_cached_zoom = -1.0


func _bind_shader_uniforms() -> void:
	if _shader_mat == null:
		return
	_bind_buffer_layout_uniforms()
	_invalidate_projection_cache()


func _bootstrap_initial_reveal(start_cell: Vector2i) -> void:
	if not _is_first_draw or _visibility == null:
		print(
			"[FogOverlay] bootstrap reveal skipped: is_first_draw=%s visibility=%s"
			% [_is_first_draw, _visibility]
		)
		return
	var radius: int = maxi(_initial_reveal_radius, 1)
	print("[FogOverlay] bootstrap reveal start_cell=%s radius=%d" % [start_cell, radius])
	reveal_cells_at(start_cell, radius, true)
	_commit_mask_to_gpu()
	_last_reveal_cell = start_cell
	_is_first_draw = false
	print("[FogOverlay] bootstrap reveal committed; last_reveal_cell=%s" % _last_reveal_cell)
	_verify_center_revealed(start_cell)
	_debug_log_bootstrap_state(start_cell)


func _bootstrap_initial_reveal_async(start_cell: Vector2i) -> void:
	if not _is_first_draw or _visibility == null:
		_bootstrap_in_progress = false
		return

	var radius: int = maxi(_initial_reveal_radius, 1)
	if _reveal_disc_stamp_into_buffer(start_cell, radius):
		_commit_mask_to_gpu()
	else:
		if not _visibility.has_method("RevealSquareCollect"):
			_bootstrap_initial_reveal(start_cell)
			_bootstrap_in_progress = false
			return

		var new_cells: Array = _visibility.RevealSquareCollect(start_cell.x, start_cell.y, radius)
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
	var safe_zoom: float = ViewProjection.zoom
	if is_zero_approx(safe_zoom):
		safe_zoom = 1.0
	var center_grid: Vector2i = _resolve_player_cell_from_scene()
	_ensure_buffer_covers_viewport(safe_zoom, center_grid)
	_invalidate_projection_cache()
	_sync_projection_uniforms()
	var pending_cell: Vector2i = center_grid
	if pending_cell != _last_reveal_cell:
		on_player_cell_changed(pending_cell)
	_debug_log_bootstrap_state(start_cell)


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
	_settings_buffer_floor = _read_int_setting(&"fog.buffer_size_cells", DEFAULT_BUFFER_SIZE_CELLS)
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
