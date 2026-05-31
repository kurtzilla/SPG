class_name FogOverlay
extends CanvasLayer

## Sliding-window fog mask (1 texel = 1 grid cell). Screen-space quad; projection via ViewFrame.
##
## WIRING INVARIANT — read before moving script or @onready paths:
##   This file must live on the **CanvasLayer** node named `FogOverlay` in FogOverlay.tscn.
##   `FogRect` is a fullscreen child ColorRect only (material target via `$FogRect`); it must NOT
##   carry FogOverlay.gd. MainSandbox and FogExplorationMap must bind `$FogOverlay`, never
##   `$FogOverlay/FogRect`.
##   GridOverlay uses the same CanvasLayer-controller pattern; fog and grid child rects must NOT
##   carry controller scripts — partial refactors that
##   move the script OR change @onready without updating the other produce a silent failure:
##   a plain ColorRect may still paint black while setup(), mask upload, and apply_view_frame()
##   never run on the node you think is the fog controller.
##   If restructuring: change .tscn script host, `extends`, and every `$FogOverlay` reference
##   together (grep all three). See validate_host_node().

const FOG_SHADER: Shader = preload("res://src/Godot/Shaders/FogOverlay.gdshader")
const ViewMetricsRes = preload("res://src/Godot/Scripts/ViewMetrics.gd")
const ViewTransformsScript = preload("res://src/Godot/Scripts/ViewTransforms.gd")
const ViewFrameScript = preload("res://src/Godot/Scripts/ViewFrame.gd")
const FogPerfProfileRes = preload("res://src/Godot/Scripts/Systems/fog-of-war/FogPerfProfile.gd")

const DEFAULT_BUFFER_SIZE_CELLS: int = 128
const DEFAULT_RECENTER_MARGIN_CELLS: int = 24
const MAX_BUFFER_SIZE_CELLS: int = 512
const BUFFER_SIZE_STEP_CELLS: int = 32
const DEFAULT_EDGE_FEATHER_PX: float = 48.0
const DISC_FEATHER_MIN_CELL_FRACTION: float = 0.875
const FALLBACK_MIN_ZOOM: float = 0.25
const INVALID_BOUNDS: Vector4i = Vector4i(0, 0, -1, -1)
const FULL_MASK_UPLOAD_AREA_FRAC: float = 0.8
const DEFAULT_GPU_COMMIT_MIN_INTERVAL_SEC: float = 1.0 / 60.0
const PATH_STAMP_SINGLE_DISC_MAX_CHEBYSHEV: int = 2
const UNINITIALIZED_STAMP_CELL: int = 900000
const QUEUED_CELL_RECENTER_NONE: Vector2i = Vector2i(900001, 900001)
const UNINITIALIZED_STAMP_MAP_PX: float = -900000.0
const MOVING_STAMP_MIN_VELOCITY_SQ: float = 1.0
const MOTION_DISC_STAMP_MIN_DISTANCE_PX: float = 4.0
const FOG_SETTINGS_REFRESH_DEBOUNCE_SEC: float = 0.12
## Sentinel: full-window graded hole restore (settings refresh), not strip-scoped shift restore.
const NO_SHIFT_ORIGIN: Vector2i = Vector2i(2147483647, 2147483647)
## Must match VisibilityModel.DefaultMovementRevealRadius (not user-tunable).
const PLAYER_REVEAL_RADIUS_CELLS: int = 14

@onready var _fog_rect: ColorRect = $FogRect


static func validate_host_node(node: Node) -> bool:
	if node == null:
		return false
	if not node is FogOverlay:
		return false
	return node.has_method("setup") and node.has_method("apply_view_frame")


## Headless regression gate (res://tools/fog_smoke.gd). Returns human-readable failure lines.
static func collect_scene_wiring_failures(fog_root: Node) -> PackedStringArray:
	var failures: PackedStringArray = PackedStringArray()
	if not validate_host_node(fog_root):
		failures.append("FogOverlay host must be CanvasLayer + FogOverlay.gd with setup/apply_view_frame")
		return failures
	var fog: FogOverlay = fog_root as FogOverlay
	var rect: Node = fog.get_node_or_null("FogRect")
	if rect == null:
		failures.append("FogOverlay missing child FogRect")
	elif not rect is ColorRect:
		failures.append("FogOverlay/FogRect must be ColorRect")
	else:
		var color_rect: ColorRect = rect as ColorRect
		if color_rect.color.r < 0.99 or color_rect.color.g < 0.99 or color_rect.color.b < 0.99:
			failures.append("FogRect.color must be white (1,1,1,1) so shader alpha is not zeroed")
		if color_rect.get_script() != null:
			failures.append("FogOverlay.gd must not be on FogRect — move script to CanvasLayer root")
	return failures


static func collect_shader_failures() -> PackedStringArray:
	var failures: PackedStringArray = PackedStringArray()
	var shader: Shader = load("res://src/Godot/Shaders/FogOverlay.gdshader") as Shader
	if shader == null:
		failures.append("FogOverlay.gdshader failed to load (compile error — check Godot output)")
		return failures
	var mat := ShaderMaterial.new()
	mat.shader = shader
	if mat.shader == null:
		failures.append("FogOverlay.gdshader did not bind to ShaderMaterial")
	return failures


static func collect_bootstrap_failures(fog: FogOverlay) -> PackedStringArray:
	var failures: PackedStringArray = PackedStringArray()
	if not fog.is_configured():
		failures.append("FogOverlay.setup/bootstrap did not set is_configured")
		return failures
	var rect: ColorRect = fog.get_node("FogRect") as ColorRect
	if rect == null:
		failures.append("FogRect missing after bootstrap")
		return failures
	var mat: Material = rect.material
	if mat == null or not mat is ShaderMaterial:
		failures.append("FogRect has no ShaderMaterial after bootstrap")
	elif (mat as ShaderMaterial).shader == null:
		failures.append("FogRect ShaderMaterial.shader is null after bootstrap")
	return failures

var _shader_mat: ShaderMaterial
var _visibility: Object

var _mask_image: Image
var _fog_texture: ImageTexture
var _mask_bytes: PackedByteArray = PackedByteArray()

var _buffer_size_cells: int = DEFAULT_BUFFER_SIZE_CELLS
var _settings_buffer_floor: int = DEFAULT_BUFFER_SIZE_CELLS
var _recenter_margin_cells: int = DEFAULT_RECENTER_MARGIN_CELLS
var _initial_reveal_radius: int = 1
var _initial_reveal_corner_radius: int = 12
var _edge_feather_px: float = DEFAULT_EDGE_FEATHER_PX
var _fog_edge_aa_strength: float = 0.0

var _initial_reveal_anchor_cell: Vector2i = Vector2i.ZERO
var _current_buffer_center_grid: Vector2i = Vector2i.ZERO
var _buffer_origin_grid: Vector2i = Vector2i.ZERO
var _last_reveal_cell: Vector2i = Vector2i(999999, 999999)
var _last_stamp_cell: Vector2i = Vector2i(999999, 999999)
var _cached_player_map_px: Vector2 = Vector2(-999999.0, -999999.0)
var _last_pushed_player_map_px: Vector2 = Vector2(-999999.0, -999999.0)
var _last_gpu_commit_sec: float = -999999.0
var _force_immediate_gpu_commit: bool = false
var _initial_square_committed: bool = false
var _is_first_draw: bool = true
var _was_moving_for_stamp: bool = false
var _last_motion_bake_map_px: Vector2 = Vector2(UNINITIALIZED_STAMP_MAP_PX, UNINITIALIZED_STAMP_MAP_PX)
var _last_motion_bake_sec: float = -999999.0
var _last_motion_disc_stamp_map_px: Vector2 = Vector2(UNINITIALIZED_STAMP_MAP_PX, UNINITIALIZED_STAMP_MAP_PX)
var _configured: bool = false
var _fog_enabled: bool = false

var _cached_canvas_to_map: Transform2D = Transform2D.IDENTITY
var _canvas_to_map_cached: bool = false
var _cached_projection_zoom: float = -1.0
var _shutting_down: bool = false
var _gpu_commit_suppressed: bool = false
var _mask_commit_pending: bool = false
var _commit_dirty_bounds: Vector4i = INVALID_BOUNDS

var _region_commit_image: Image
var _region_commit_bytes: PackedByteArray = PackedByteArray()
var _fog_settings_refresh_timer: SceneTreeTimer

var _cached_live_disc_map_px: Vector2 = Vector2(-999999.0, -999999.0)
var _cached_live_disc_moving: bool = false
var _cached_live_disc_enabled: bool = false
var _cached_live_disc_radius_cells: float = -1.0
var _cached_live_disc_feather_cells: float = -1.0

var _recenter_trigger: StringName = &"cell"
var _pending_recenter_center: Vector2i = Vector2i.ZERO
var _recenter_old_origin_grid: Vector2i = Vector2i.ZERO
var _recenter_old_mask_bytes: PackedByteArray = PackedByteArray()
var _view_settling: bool = false
var _queued_cell_recenter_center: Vector2i = QUEUED_CELL_RECENTER_NONE
var _buffer_viewport_pass_running: bool = false
var _ensure_buffer_player_map_px: Vector2 = Vector2(-999999.0, -999999.0)


func _ready() -> void:
	_fog_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fog_rect.color = Color(1.0, 1.0, 1.0, 1.0)
	_fog_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fog_rect.anchor_right = 1.0
	_fog_rect.anchor_bottom = 1.0
	_fog_rect.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_fog_rect.grow_vertical = Control.GROW_DIRECTION_BOTH

	_shader_mat = ShaderMaterial.new()
	_shader_mat.shader = FOG_SHADER
	_fog_rect.material = _shader_mat
	_bind_shader_safe_defaults()
	_fog_rect.visible = false

	if not Settings.fog_changed.is_connected(_on_fog_settings_changed):
		Settings.fog_changed.connect(_on_fog_settings_changed)
	_read_buffer_settings()
	_push_projection_fallback()


func _exit_tree() -> void:
	prepare_for_shutdown()


func prepare_for_shutdown() -> void:
	if _shutting_down:
		return
	_shutting_down = true
	if _fog_settings_refresh_timer != null and is_instance_valid(_fog_settings_refresh_timer):
		var cb := Callable(self, "_apply_fog_settings_refresh")
		if _fog_settings_refresh_timer.timeout.is_connected(cb):
			_fog_settings_refresh_timer.timeout.disconnect(cb)
		_fog_settings_refresh_timer = null
	if Settings.fog_changed.is_connected(_on_fog_settings_changed):
		Settings.fog_changed.disconnect(_on_fog_settings_changed)
	_visibility = null
	if _fog_rect != null:
		_fog_rect.material = null
	_shader_mat = null
	_fog_texture = null
	_mask_image = null
	_region_commit_image = null


func set_enabled_visible(fog_enabled: bool) -> void:
	_fog_enabled = fog_enabled
	_update_fog_rect_visibility()
	if not _fog_enabled:
		return
	if _configured and _initial_square_committed:
		_bind_buffer_layout_uniforms()
		_commit_mask_to_gpu()
	_push_projection_fallback()


func _update_fog_rect_visibility() -> void:
	if _fog_rect == null:
		return
	# Never show until bootstrap mask + shader uniforms are ready — white base shows through if shader fails.
	_fog_rect.visible = _configured and _fog_enabled and _initial_square_committed


func _bind_shader_safe_defaults() -> void:
	if _shader_mat == null:
		return
	var cell_px := float(ViewMetricsRes.CELL_SIZE_PX)
	_shader_mat.set_shader_parameter(&"cell_size_px", cell_px)
	_shader_mat.set_shader_parameter(&"buffer_size_cells", Vector2(DEFAULT_BUFFER_SIZE_CELLS, DEFAULT_BUFFER_SIZE_CELLS))
	_shader_mat.set_shader_parameter(&"world_buffer_origin_px", Vector2.ZERO)
	_shader_mat.set_shader_parameter(&"player_map_px", Vector2.ZERO)
	_shader_mat.set_shader_parameter(&"fog_opacity", 1.0)
	_shader_mat.set_shader_parameter(&"fog_edge_aa_strength", 0.0)
	_shader_mat.set_shader_parameter(&"reveal_radius_cells", float(PLAYER_REVEAL_RADIUS_CELLS))
	_shader_mat.set_shader_parameter(&"reveal_feather_cells", 0.0)
	_shader_mat.set_shader_parameter(&"live_disc_enabled", 0.0)
	if _fog_texture != null:
		_shader_mat.set_shader_parameter(&"fog_texture", _fog_texture)


func is_configured() -> bool:
	return _configured


func begin_view_transition() -> void:
	_view_settling = true
	if _has_cached_player_map_px():
		_sync_live_disc_uniforms(_cached_player_map_px)


func end_view_transition() -> void:
	_view_settling = false
	_reset_motion_disc_stamp_anchor()
	if _has_cached_player_map_px():
		_sync_live_disc_uniforms(_cached_player_map_px)


func tick_presentation(delta: float) -> void:
	if not _fog_enabled:
		return
	FogPerfProfileRes.notify_frame()
	try_flush_presentation_commits(false)
	FogPerfProfileRes.maybe_report(delta)


func flush_presentation(force: bool = false) -> void:
	if not _mask_commit_pending:
		return
	if not force and not _force_immediate_gpu_commit:
		var min_interval: float = _gpu_commit_min_interval_sec()
		if min_interval > 0.0:
			var now_sec: float = Time.get_ticks_msec() * 0.001
			if now_sec - _last_gpu_commit_sec < min_interval:
				return
	_force_immediate_gpu_commit = false
	_mask_commit_pending = false
	_last_gpu_commit_sec = Time.get_ticks_msec() * 0.001
	_commit_mask_to_gpu()


func try_flush_presentation_commits(force: bool = false) -> void:
	flush_presentation(force)


func apply_canvas_transform(canvas_to_map: Transform2D) -> void:
	if _shader_mat == null:
		return
	_push_canvas_to_map_uniforms(canvas_to_map)


func apply_view_frame(frame: ViewFrameScript) -> void:
	if not _fog_enabled:
		return
	apply_overlay_projection(frame)


func flush_pending_on_view_changed() -> void:
	try_flush_presentation_commits(true)


func update_player_reveal(map_px: Vector2, velocity_map_px: Vector2 = Vector2.ZERO) -> void:
	if not _fog_enabled or _shader_mat == null or not _configured or not _initial_square_committed:
		return
	_cached_player_map_px = map_px
	var moving: bool = velocity_map_px.length_squared() >= MOVING_STAMP_MIN_VELOCITY_SQ
	if moving:
		if not _was_moving_for_stamp:
			_reset_motion_bake_anchor(map_px)
			_reset_motion_disc_stamp_anchor()
		_stamp_motion_disc_if_moved(map_px)
	elif _was_moving_for_stamp:
		if _has_last_motion_bake_map_px() and not _last_motion_bake_map_px.is_equal_approx(map_px):
			if _should_bake_motion_reveal_segment(_last_motion_bake_map_px, map_px):
				_bake_motion_reveal_segment(_last_motion_bake_map_px, map_px)
		_stamp_disc_at_map_px(map_px)
		_schedule_mask_commit(_mask_bounds_for_disc_at_map_px(map_px), true)
		_reset_motion_bake_anchor(map_px)
		_reset_motion_disc_stamp_anchor(map_px)
	_sync_live_disc_uniforms(map_px)
	_was_moving_for_stamp = moving


func flush_motion_reveal() -> void:
	try_flush_presentation_commits(false)


func apply_overlay_projection(frame: ViewFrameScript) -> void:
	if _shader_mat == null or frame == null:
		return
	var t0: int = FogPerfProfileRes.begin(&"apply_overlay_projection")
	_push_projection_uniforms(frame)
	FogPerfProfileRes.end(&"apply_overlay_projection", t0)


## Recenter-only live disc position; movement reveal uses native mask stamps.
func sync_player_disc_position(map_px: Vector2) -> void:
	if _shutting_down or not _configured:
		return
	_cached_player_map_px = map_px
	if _view_settling:
		_sync_live_disc_uniforms(map_px)


func on_player_cell_changed(cell: Vector2i) -> void:
	if not _configured or _visibility == null:
		return
	if _needs_recenter(cell):
		var from_cell := _last_stamp_cell
		_schedule_recenter_buffer(cell, &"cell")
		if not _initial_square_committed:
			return
		_last_reveal_cell = cell
		if from_cell.x < UNINITIALIZED_STAMP_CELL and cell != from_cell:
			_persist_player_reveal(from_cell, cell, _resolve_player_reveal_map_px(cell))
			_flush_cell_cross_mask_commit()
		else:
			_last_stamp_cell = cell
		_sync_initial_square_if_at_anchor(cell)
		return
	if not _initial_square_committed:
		return
	if cell == _last_reveal_cell:
		return

	_last_reveal_cell = cell
	_persist_player_reveal(_last_stamp_cell, cell, _resolve_player_reveal_map_px(cell))
	_flush_cell_cross_mask_commit()
	_sync_initial_square_if_at_anchor(cell)


## Grow-only: sized for min zoom at current viewport. Zoom changes update projection only.
func ensure_buffer_for_viewport(player_map_px: Vector2 = Vector2(-999999.0, -999999.0)) -> void:
	if not _configured or _buffer_viewport_pass_running:
		return
	var required: int = _required_buffer_size_for_min_zoom()
	if required <= _buffer_size_cells:
		return
	_ensure_buffer_player_map_px = player_map_px
	_run_ensure_buffer_viewport_grow_pass()
	_ensure_buffer_player_map_px = Vector2(-999999.0, -999999.0)


func _run_ensure_buffer_viewport_grow_pass() -> void:
	_buffer_viewport_pass_running = true
	var player_cell: Vector2i = _player_grid_cell()
	var required: int = _required_buffer_size_for_min_zoom()
	if required <= _buffer_size_cells:
		_buffer_viewport_pass_running = false
		return
	begin_view_transition()
	var old_size: int = _buffer_size_cells
	var old_origin: Vector2i = _buffer_origin_grid
	var old_mask: PackedByteArray = _mask_bytes.duplicate()
	_current_buffer_center_grid = player_cell
	_rebuild_buffer_storage(required)
	_recompute_buffer_origin()
	if old_mask.size() == old_size * old_size:
		_shift_mask_bytes_from(old_origin, old_mask, old_size)
	else:
		_clear_mask_bytes()
	_restore_presentation_mask(NO_SHIFT_ORIGIN)
	_upload_full_mask()
	_bind_buffer_layout_uniforms()
	end_view_transition()
	_invalidate_projection_cache()
	_push_projection_fallback()
	_buffer_viewport_pass_running = false


func _player_grid_cell() -> Vector2i:
	if _ensure_buffer_player_map_px.x > -999000.0:
		return ViewProjection.map_local_px_to_grid_cell(_ensure_buffer_player_map_px)
	if _has_cached_player_map_px():
		return ViewProjection.map_local_px_to_grid_cell(_cached_player_map_px)
	return _current_buffer_center_grid


func setup(visibility: Object, start_cell: Vector2i) -> void:
	_visibility = visibility
	_read_buffer_settings()
	_load_reveal_radii_from_settings()

	_initial_reveal_anchor_cell = start_cell
	_current_buffer_center_grid = start_cell
	_rebuild_buffer_storage(_required_buffer_size_for_min_zoom())
	_recompute_buffer_origin()
	_bind_buffer_layout_uniforms()

	_configured = true
	_is_first_draw = true
	_initial_square_committed = false
	_was_moving_for_stamp = false
	_last_motion_bake_map_px = Vector2(UNINITIALIZED_STAMP_MAP_PX, UNINITIALIZED_STAMP_MAP_PX)
	_last_motion_bake_sec = -999999.0
	_reset_motion_disc_stamp_anchor()
	_last_reveal_cell = Vector2i(999999, 999999)
	_last_stamp_cell = Vector2i(999999, 999999)
	_cached_player_map_px = Vector2.ZERO
	_commit_dirty_bounds = INVALID_BOUNDS
	_invalidate_projection_cache()
	_push_projection_fallback()

	_sync_visibility_feather_from_settings()
	_bootstrap_initial_reveal(start_cell)
	on_player_cell_changed(start_cell)


func reveal_cells_at(
	grid_coord: Vector2i,
	radius_cells: int,
	force_square: bool = false,
	sync_mask: bool = false
) -> void:
	_reveal_core_disc_at(grid_coord, radius_cells, force_square)
	if sync_mask:
		_fill_buffer_from_core()


func _reveal_core_disc_at(grid_coord: Vector2i, radius_cells: int, force_square: bool = false) -> void:
	if _visibility == null:
		return
	if force_square and _visibility.has_method("RevealRoundedSquare"):
		var corner_radius: int = _effective_initial_corner_radius(radius_cells)
		_visibility.RevealRoundedSquare(
			grid_coord.x, grid_coord.y, radius_cells, corner_radius
		)
	elif force_square and _visibility.has_method("RevealSquare"):
		_visibility.RevealSquare(grid_coord.x, grid_coord.y, radius_cells)
	elif _visibility.has_method("RevealDisc"):
		_visibility.RevealDisc(grid_coord.x, grid_coord.y, radius_cells)


func _effective_initial_corner_radius(radius_cells: int) -> int:
	if _initial_reveal_corner_radius > 0:
		return mini(_initial_reveal_corner_radius, radius_cells)
	return maxi(4, radius_cells * 3 / 4)


func _needs_recenter(cell: Vector2i) -> bool:
	if cell == _initial_reveal_anchor_cell:
		return false

	var local: Vector2i = cell - _buffer_origin_grid
	var safe_zoom: float = ViewProjection.safe_zoom()
	var view_half: int = ViewTransformsScript.visible_grid_radius_from_viewport(
		ViewProjection.get_viewport_size(), safe_zoom, 0
	)
	var reveal_pad: int = maxi(maxi(PLAYER_REVEAL_RADIUS_CELLS, _initial_reveal_radius), 2) + 2
	var buffer_half: int = _buffer_size_cells >> 1
	var max_margin: int = maxi(1, buffer_half - reveal_pad - 1)
	var at_buffer_center: bool = cell == _current_buffer_center_grid
	var dynamic_margin: int
	if at_buffer_center:
		dynamic_margin = mini(reveal_pad, max_margin)
	else:
		dynamic_margin = mini(maxi(reveal_pad, view_half), max_margin)
	return (
		local.x < dynamic_margin
		or local.y < dynamic_margin
		or local.x >= _buffer_size_cells - dynamic_margin
		or local.y >= _buffer_size_cells - dynamic_margin
	)


func _schedule_recenter_buffer(new_center: Vector2i, trigger: StringName = &"cell") -> void:
	_pending_recenter_center = new_center
	if _view_settling:
		if trigger == &"cell":
			_queued_cell_recenter_center = new_center
		return
	var old_origin: Vector2i = _buffer_origin_grid
	var t_dup: int = FogPerfProfileRes.begin(&"recenter_duplicate")
	_recenter_old_origin_grid = old_origin
	_recenter_old_mask_bytes = _mask_bytes.duplicate()
	FogPerfProfileRes.end(&"recenter_duplicate", t_dup)
	_recenter_trigger = trigger
	if trigger == &"zoom":
		begin_view_transition()
	_recenter_buffer_body(old_origin, _recenter_old_mask_bytes, new_center)


func _recenter_buffer(new_center: Vector2i, _pending_radius: int) -> void:
	var old_origin: Vector2i = _buffer_origin_grid
	_recenter_buffer_body(old_origin, _mask_bytes.duplicate(), new_center)


func _recenter_buffer_body(
	old_origin: Vector2i, old_mask: PackedByteArray, new_center: Vector2i
) -> void:
	_current_buffer_center_grid = new_center
	_recompute_buffer_origin()
	var t_total: int = FogPerfProfileRes.begin(&"recenter_total")
	var t_shift: int = FogPerfProfileRes.begin(&"recenter_shift")
	_shift_mask_bytes_from(old_origin, old_mask)
	FogPerfProfileRes.end(&"recenter_shift", t_shift)
	var restore_info: Dictionary = _restore_presentation_mask(old_origin)
	var t_upload: int = FogPerfProfileRes.begin(&"recenter_upload")
	_upload_full_mask()
	FogPerfProfileRes.end(&"recenter_upload", t_upload)
	FogPerfProfileRes.end(&"recenter_total", t_total)
	_bind_buffer_layout_uniforms()
	_log_recenter_completed(old_origin, restore_info)
	end_view_transition()
	_invalidate_projection_cache()
	_push_projection_fallback()
	_try_run_queued_cell_recenter()


func _try_run_queued_cell_recenter() -> void:
	if _queued_cell_recenter_center == QUEUED_CELL_RECENTER_NONE:
		return
	var center: Vector2i = _queued_cell_recenter_center
	_queued_cell_recenter_center = QUEUED_CELL_RECENTER_NONE
	if not _needs_recenter(center):
		return
	_schedule_recenter_buffer(center, &"cell")


func _initial_square_overlaps_buffer() -> bool:
	var n: int = _buffer_size_cells
	var local: Vector2i = _initial_reveal_anchor_cell - _buffer_origin_grid
	var margin: int = maxi(_initial_reveal_radius, 1) + int(ceil(_disc_feather_cells())) + 1
	var local_min: Vector2i = local - Vector2i(margin, margin)
	var local_max: Vector2i = local + Vector2i(margin, margin)
	return local_max.x >= 0 and local_max.y >= 0 and local_min.x < n and local_min.y < n


func _restamp_initial_square_if_in_buffer() -> void:
	if _initial_square_overlaps_buffer():
		_stamp_initial_square_into_mask()


func _sync_initial_square_if_at_anchor(cell: Vector2i) -> void:
	if cell != _initial_reveal_anchor_cell or not _initial_square_overlaps_buffer():
		return
	_restamp_initial_square_if_in_buffer()
	_schedule_mask_commit(_mask_bounds_for_initial_square(), true)
	flush_presentation(false)


func _bootstrap_initial_reveal(start_cell: Vector2i) -> void:
	if not _is_first_draw or _visibility == null:
		return
	_initial_reveal_anchor_cell = start_cell
	var start_map_px: Vector2 = _cell_center_map_px(start_cell)
	_commit_initial_square_mask()
	_last_stamp_cell = start_cell
	_cached_player_map_px = start_map_px
	_last_reveal_cell = start_cell
	_is_first_draw = false


func _allocate_mask_buffers() -> void:
	var mask_size: int = _buffer_size_cells * _buffer_size_cells
	_mask_bytes.resize(mask_size)
	_mask_bytes.fill(0)


func _rebuild_buffer_storage(new_size: int) -> void:
	if new_size <= 0:
		return
	_buffer_size_cells = new_size
	_allocate_mask_buffers()

	var mask_size: int = _buffer_size_cells
	var needs_new_image: bool = (
		_mask_image == null
		or _mask_image.get_width() != mask_size
		or _mask_image.get_height() != mask_size
	)
	if needs_new_image:
		_mask_image = Image.create(mask_size, mask_size, false, Image.FORMAT_R8)
	else:
		_mask_image.fill(0)

	if _fog_texture == null:
		_fog_texture = ImageTexture.create_from_image(_mask_image)
	else:
		_fog_texture.update(_mask_image)
	if _shader_mat != null and _fog_texture != null:
		_shader_mat.set_shader_parameter(&"fog_texture", _fog_texture)


func _mask_size_cells() -> int:
	return _buffer_size_cells


func _required_buffer_size_for_min_zoom() -> int:
	var min_zoom: float = FALLBACK_MIN_ZOOM
	var min_val: Variant = Settings.get_min("view.zoom")
	if min_val != null:
		min_zoom = float(min_val)
	return maxi(_required_buffer_size_cells(min_zoom), _settings_buffer_floor)


func _required_buffer_size_cells(zoom: float) -> int:
	var safe_zoom: float = zoom if not is_zero_approx(zoom) else 1.0
	var vp_size: Vector2 = ViewProjection.get_viewport_size()
	var pad: int = maxi(maxi(PLAYER_REVEAL_RADIUS_CELLS, _initial_reveal_radius), _recenter_margin_cells)
	pad += int(ceil(_disc_feather_cells())) + 2
	pad += int(ceil(_edge_feather_px / float(ViewMetricsRes.CELL_SIZE_PX))) + 1
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


func _commit_mask_to_gpu() -> void:
	if _shutting_down or _gpu_commit_suppressed or _mask_image == null or _fog_texture == null:
		return
	var t0: int = FogPerfProfileRes.begin(&"commit_mask_gpu")
	var mask_size: int = _mask_size_cells()
	var bounds: Vector4i = _expand_mask_bounds_for_sampling(_commit_dirty_bounds)
	_commit_dirty_bounds = INVALID_BOUNDS

	if bounds.z < bounds.x or bounds.w < bounds.y:
		_mask_image.set_data(mask_size, mask_size, false, Image.FORMAT_R8, _mask_bytes)
		_fog_texture.update(_mask_image)
		FogPerfProfileRes.record_mask_commit(false)
		FogPerfProfileRes.end(&"commit_mask_gpu", t0)
		return

	var min_x: int = clampi(bounds.x, 0, mask_size - 1)
	var min_y: int = clampi(bounds.y, 0, mask_size - 1)
	var max_x: int = clampi(bounds.z, 0, mask_size - 1)
	var max_y: int = clampi(bounds.w, 0, mask_size - 1)
	var region_w: int = max_x - min_x + 1
	var region_h: int = max_y - min_y + 1
	var region_area: int = region_w * region_h
	var total_area: int = mask_size * mask_size

	if region_area >= int(float(total_area) * FULL_MASK_UPLOAD_AREA_FRAC):
		_mask_image.set_data(mask_size, mask_size, false, Image.FORMAT_R8, _mask_bytes)
		_fog_texture.update(_mask_image)
		FogPerfProfileRes.record_mask_commit(false)
	else:
		_blit_mask_bytes_to_image_region(min_x, min_y, region_w, region_h)
		_fog_texture.update(_mask_image)
		FogPerfProfileRes.record_mask_commit(true)
	FogPerfProfileRes.end(&"commit_mask_gpu", t0)


func _blit_mask_bytes_to_image_region(origin_x: int, origin_y: int, region_w: int, region_h: int) -> void:
	var mask_size: int = _mask_size_cells()
	var region_area: int = region_w * region_h
	if _region_commit_bytes.size() != region_area:
		_region_commit_bytes.resize(region_area)
	var region_bytes: PackedByteArray = _region_commit_bytes
	var dst: int = 0
	for ly: int in range(origin_y, origin_y + region_h):
		var row_start: int = ly * mask_size + origin_x
		for _lx: int in range(region_w):
			region_bytes[dst] = _mask_bytes[row_start + _lx]
			dst += 1

	if (
		_region_commit_image == null
		or _region_commit_image.get_width() != region_w
		or _region_commit_image.get_height() != region_h
	):
		_region_commit_image = Image.create_from_data(
			region_w, region_h, false, Image.FORMAT_R8, region_bytes
		)
	else:
		_region_commit_image.set_data(region_w, region_h, false, Image.FORMAT_R8, region_bytes)

	_mask_image.blit_rect(
		_region_commit_image,
		Rect2i(0, 0, region_w, region_h),
		Vector2i(origin_x, origin_y)
	)


func _schedule_mask_commit(dirty_bounds: Vector4i = INVALID_BOUNDS, immediate: bool = false) -> void:
	if _shutting_down or _gpu_commit_suppressed:
		return
	if dirty_bounds.z >= dirty_bounds.x:
		_commit_dirty_bounds = _union_mask_bounds(_commit_dirty_bounds, dirty_bounds)
	_mask_commit_pending = true
	if immediate:
		_force_immediate_gpu_commit = true


func _upload_full_mask() -> void:
	var mask_size: int = _mask_size_cells()
	_schedule_mask_commit(Vector4i(0, 0, mask_size - 1, mask_size - 1), true)
	flush_presentation(true)


func _persist_player_reveal(from_cell: Vector2i, to_cell: Vector2i, map_px: Vector2) -> void:
	var t0: int = FogPerfProfileRes.begin(&"persist_player_reveal")
	_stamp_mask_segment(from_cell, to_cell, PLAYER_REVEAL_RADIUS_CELLS)

	var trail_cells: Array[Vector2i] = _cells_on_segment(from_cell, to_cell)
	var dirty_bounds: Vector4i = _mask_bounds_for_disc_trail(trail_cells, PLAYER_REVEAL_RADIUS_CELLS)
	if dirty_bounds.z < dirty_bounds.x:
		dirty_bounds = _mask_bounds_for_disc_reveal(to_cell, PLAYER_REVEAL_RADIUS_CELLS)

	_schedule_mask_commit(dirty_bounds, true)

	_last_stamp_cell = to_cell
	_cached_player_map_px = map_px
	FogPerfProfileRes.end(&"persist_player_reveal", t0)


func _flush_cell_cross_mask_commit() -> void:
	# Deferred to tick_presentation; _schedule_mask_commit(..., true) sets force flag.
	pass


func _stamp_mask_segment(from_cell: Vector2i, to_cell: Vector2i, radius_cells: int) -> void:
	if _visibility == null:
		return
	var from_x: int = from_cell.x if from_cell.x < UNINITIALIZED_STAMP_CELL else to_cell.x
	var from_y: int = from_cell.y if from_cell.x < UNINITIALIZED_STAMP_CELL else to_cell.y
	var chebyshev: int = maxi(absi(to_cell.x - from_x), absi(to_cell.y - from_y))
	var to_center := Vector2(to_cell) + Vector2(0.5, 0.5)
	if chebyshev <= PATH_STAMP_SINGLE_DISC_MAX_CHEBYSHEV and _visibility.has_method("RevealDiscStampNative"):
		_assign_mask_from_native(
			_visibility.RevealDiscStampNative(
				_buffer_origin_grid.x,
				_buffer_origin_grid.y,
				_buffer_size_cells,
				_buffer_size_cells,
				to_center.x,
				to_center.y,
				radius_cells,
				_mask_bytes
			)
		)
		return
	var from_center := Vector2(from_x, from_y) + Vector2(0.5, 0.5)
	var t0: int = FogPerfProfileRes.begin(&"reveal_disc_path_stamp")
	_stamp_path_reveal_native(from_center, to_center, radius_cells)
	FogPerfProfileRes.end(&"reveal_disc_path_stamp", t0)
	return
	_reveal_core_disc_at(to_cell, radius_cells)
	_fill_buffer_from_core()


func _cells_on_segment(from_cell: Vector2i, to_cell: Vector2i) -> Array[Vector2i]:
	if from_cell.x >= UNINITIALIZED_STAMP_CELL:
		return [to_cell]
	if from_cell == to_cell:
		return [to_cell]

	var cells: Array[Vector2i] = []
	var x0: int = from_cell.x
	var y0: int = from_cell.y
	var x1: int = to_cell.x
	var y1: int = to_cell.y
	var dx: int = absi(x1 - x0)
	var dy: int = absi(y1 - y0)
	var sx: int = 1 if x0 < x1 else -1
	var sy: int = 1 if y0 < y1 else -1
	var err: int = dx - dy

	while true:
		cells.append(Vector2i(x0, y0))
		if x0 == x1 and y0 == y1:
			break
		var e2: int = err * 2
		if e2 > -dy:
			err -= dy
			x0 += sx
		if e2 < dx:
			err += dx
			y0 += sy

	return cells


func _union_mask_bounds(a: Vector4i, b: Vector4i) -> Vector4i:
	if a.z < a.x or a.w < a.y:
		return b
	if b.z < b.x or b.w < b.y:
		return a
	return Vector4i(mini(a.x, b.x), mini(a.y, b.y), maxi(a.z, b.z), maxi(a.w, b.w))


func _expand_mask_bounds_for_sampling(bounds: Vector4i) -> Vector4i:
	if bounds.z < bounds.x or bounds.w < bounds.y:
		return bounds
	var pad: int = maxi(int(ceil(_disc_feather_cells())) + 2, 2)
	var edge_pad: int = int(ceil(_edge_feather_px / float(ViewMetricsRes.CELL_SIZE_PX))) + 1
	pad = maxi(pad, edge_pad)
	var n: int = _buffer_size_cells
	return Vector4i(
		maxi(bounds.x - pad, 0),
		maxi(bounds.y - pad, 0),
		mini(bounds.z + pad, n - 1),
		mini(bounds.w + pad, n - 1)
	)


func _has_last_motion_bake_map_px() -> bool:
	return _last_motion_bake_map_px.x > UNINITIALIZED_STAMP_MAP_PX + 1.0


## PackedByteArray is not updated in-place by C# *Into — assign *Native return. See INTEROP.md.
func _assign_mask_from_native(stamped_buffer: Variant) -> void:
	if stamped_buffer != null:
		_mask_bytes = PackedByteArray(stamped_buffer)


func _restore_presentation_mask(shift_old_origin: Vector2i = NO_SHIFT_ORIGIN) -> Dictionary:
	if _visibility == null:
		return {"holes_filled": 0, "square_restamp": "skipped"}
	var holes_filled: int = _fill_revealed_holes_after_shift(shift_old_origin)
	var square_restamp: String = "skipped"
	var t0: int = FogPerfProfileRes.begin(&"recenter_restore")
	if shift_old_origin == NO_SHIFT_ORIGIN and _initial_square_overlaps_buffer():
		var t_sq: int = FogPerfProfileRes.begin(&"recenter_restore_square")
		_stamp_initial_square_into_mask()
		FogPerfProfileRes.end(&"recenter_restore_square", t_sq)
		square_restamp = "yes"
	if not _was_moving_for_stamp:
		var t_disc: int = FogPerfProfileRes.begin(&"recenter_restore_disc")
		_restamp_soft_disc_at_player()
		FogPerfProfileRes.end(&"recenter_restore_disc", t_disc)
	FogPerfProfileRes.end(&"recenter_restore", t0)
	return {"holes_filled": holes_filled, "square_restamp": square_restamp}


func _fill_revealed_holes_after_shift(shift_old_origin: Vector2i) -> int:
	if _visibility == null:
		return 0
	var t0: int = FogPerfProfileRes.begin(&"recenter_holes")
	var holes_filled: int = 0
	if shift_old_origin == NO_SHIFT_ORIGIN:
		if _visibility.has_method("FillRevealedHolesInWindowNative"):
			_assign_mask_from_native(
				_visibility.FillRevealedHolesInWindowNative(
					_buffer_origin_grid.x,
					_buffer_origin_grid.y,
					_buffer_size_cells,
					_buffer_size_cells,
					_mask_bytes
				)
			)
			if _visibility.has_method("GetLastHoleFillCount"):
				holes_filled = int(_visibility.GetLastHoleFillCount())
	elif _visibility.has_method("FillRevealedHolesAfterShiftNative"):
		var delta: Vector2i = _buffer_origin_grid - shift_old_origin
		var edge_band: int = PLAYER_REVEAL_RADIUS_CELLS + int(ceil(_disc_feather_cells())) + 2
		var result: Variant = _visibility.FillRevealedHolesAfterShiftNative(
			_buffer_origin_grid.x,
			_buffer_origin_grid.y,
			_buffer_size_cells,
			_buffer_size_cells,
			delta.x,
			delta.y,
			edge_band,
			_mask_bytes
		)
		if result != null:
			_assign_mask_from_native(result)
		if _visibility.has_method("GetLastHoleFillCount"):
			holes_filled = int(_visibility.GetLastHoleFillCount())
	elif _visibility.has_method("FillRevealedHolesInWindowNative"):
		_assign_mask_from_native(
			_visibility.FillRevealedHolesInWindowNative(
				_buffer_origin_grid.x,
				_buffer_origin_grid.y,
				_buffer_size_cells,
				_buffer_size_cells,
				_mask_bytes
			)
		)
	FogPerfProfileRes.end(&"recenter_holes", t0)
	return holes_filled


func _log_recenter_completed(old_origin: Vector2i, restore_info: Dictionary) -> void:
	var new_origin: Vector2i = _buffer_origin_grid
	var delta: Vector2i = new_origin - old_origin
	var revealed_count: int = 0
	if _visibility != null and _visibility.has_method("GetRevealedCount"):
		revealed_count = int(_visibility.GetRevealedCount())
	var edge_band: int = PLAYER_REVEAL_RADIUS_CELLS + int(ceil(_disc_feather_cells())) + 2
	var holes_filled: int = int(restore_info.get("holes_filled", 0))
	var square_restamp: String = String(restore_info.get("square_restamp", "skipped"))
	FogPerfProfileRes.log_recenter(
		"trigger=%s origin (%d,%d)->(%d,%d) delta=(%d,%d) revealed=%d buffer=%d edge_band=%d holes_filled=%d square_restamp=%s viewport_oob=%s"
		% [
			_recenter_trigger,
			old_origin.x,
			old_origin.y,
			new_origin.x,
			new_origin.y,
			delta.x,
			delta.y,
			revealed_count,
			_buffer_size_cells,
			edge_band,
			holes_filled,
			square_restamp,
			"yes" if _viewport_corners_oob_buffer() else "no",
		]
	)


func _viewport_corners_oob_buffer() -> bool:
	if not ViewProjection.are_viewport_metrics_ready():
		return false
	var vp_size: Vector2 = ViewProjection.get_viewport_size()
	var origin: Vector2i = _buffer_origin_grid
	var max_g: Vector2i = origin + Vector2i(_buffer_size_cells - 1, _buffer_size_cells - 1)
	var corners: Array[Vector2] = [
		Vector2.ZERO,
		Vector2(vp_size.x, 0.0),
		Vector2(0.0, vp_size.y),
		Vector2(vp_size.x, vp_size.y),
	]
	for corner: Vector2 in corners:
		var grid: Vector2i = ViewProjection.canvas_to_map(corner)
		if grid.x < origin.x or grid.y < origin.y or grid.x > max_g.x or grid.y > max_g.y:
			return true
	return false


func _shift_mask_bytes_from(old_origin: Vector2i, old_mask: PackedByteArray, old_size: int = -1) -> void:
	var new_size: int = _buffer_size_cells
	if old_size < 0:
		old_size = new_size
	var expected: int = old_size * old_size
	if old_mask.size() != expected:
		_clear_mask_bytes()
		return

	var new_origin: Vector2i = _buffer_origin_grid
	_mask_bytes.fill(0)

	for new_ly: int in range(new_size):
		var world_y: int = new_origin.y + new_ly
		var new_row: int = new_ly * new_size
		for new_lx: int in range(new_size):
			var world_x: int = new_origin.x + new_lx
			var old_lx: int = world_x - old_origin.x
			var old_ly: int = world_y - old_origin.y
			if old_lx < 0 or old_ly < 0 or old_lx >= old_size or old_ly >= old_size:
				continue
			var value: int = old_mask[old_ly * old_size + old_lx]
			if value > 0:
				_mask_bytes[new_row + new_lx] = value


func _stamp_initial_square_into_mask() -> void:
	if _visibility == null:
		return
	var radius: int = maxi(_initial_reveal_radius, 1)
	var corner_radius: int = _effective_initial_corner_radius(radius)
	var anchor: Vector2i = _initial_reveal_anchor_cell
	if _visibility.has_method("RevealRoundedSquare"):
		_visibility.RevealRoundedSquare(anchor.x, anchor.y, radius, corner_radius)
	elif _visibility.has_method("RevealSquare"):
		_visibility.RevealSquare(anchor.x, anchor.y, radius)
	if _visibility.has_method("RevealRoundedSquareStampNative"):
		_assign_mask_from_native(
			_visibility.RevealRoundedSquareStampNative(
				_buffer_origin_grid.x,
				_buffer_origin_grid.y,
				_buffer_size_cells,
				_buffer_size_cells,
				anchor.x,
				anchor.y,
				radius,
				corner_radius,
				_mask_bytes
			)
		)
	elif _visibility.has_method("FillRevealedMaskNative"):
		push_warning(
			"[FogOverlay] RevealRoundedSquareStampNative missing; mask will be binary (no feather). Rebuild Core."
		)
		_assign_mask_from_native(
			_visibility.FillRevealedMaskNative(
				_buffer_origin_grid.x,
				_buffer_origin_grid.y,
				_buffer_size_cells,
				_buffer_size_cells
			)
		)


func _restamp_soft_disc_at_player() -> void:
	if _visibility == null or not _has_cached_player_map_px():
		return
	var center: Vector2 = _map_px_to_cell_center(_cached_player_map_px)
	if _visibility.has_method("RevealDiscStampNative"):
		_assign_mask_from_native(
			_visibility.RevealDiscStampNative(
				_buffer_origin_grid.x,
				_buffer_origin_grid.y,
				_buffer_size_cells,
				_buffer_size_cells,
				center.x,
				center.y,
				PLAYER_REVEAL_RADIUS_CELLS,
				_mask_bytes
			)
		)


func _stamp_disc_at_map_px(map_px: Vector2) -> void:
	if _visibility == null:
		return
	var center: Vector2 = _map_px_to_cell_center(map_px)
	if _visibility.has_method("RevealDisc"):
		_visibility.RevealDisc(int(floor(center.x)), int(floor(center.y)), PLAYER_REVEAL_RADIUS_CELLS)
	if _visibility.has_method("RevealDiscStampNative"):
		_assign_mask_from_native(
			_visibility.RevealDiscStampNative(
				_buffer_origin_grid.x,
				_buffer_origin_grid.y,
				_buffer_size_cells,
				_buffer_size_cells,
				center.x,
				center.y,
				PLAYER_REVEAL_RADIUS_CELLS,
				_mask_bytes
			)
		)


func _map_px_to_cell_center(map_px: Vector2) -> Vector2:
	var cell_px: float = float(ViewMetricsRes.CELL_SIZE_PX)
	return map_px / cell_px


func _disc_feather_cells() -> float:
	var cell_px: float = float(ViewMetricsRes.CELL_SIZE_PX)
	if cell_px <= 0.0:
		return 0.0
	return maxf(_edge_feather_px / cell_px, DISC_FEATHER_MIN_CELL_FRACTION)


func _sync_visibility_feather_from_settings() -> void:
	if _visibility == null:
		return
	_visibility.RevealStampFeatherCells = _disc_feather_cells()


func _sync_live_disc_uniforms(map_px: Vector2) -> void:
	if _shader_mat == null:
		return
	var radius_cells: float = float(PLAYER_REVEAL_RADIUS_CELLS)
	var feather_cells: float = _disc_feather_cells()
	var disc_enabled: bool = _view_settling
	var changed: bool = (
		not map_px.is_equal_approx(_cached_live_disc_map_px)
		or disc_enabled != _cached_live_disc_enabled
		or not is_equal_approx(radius_cells, _cached_live_disc_radius_cells)
		or not is_equal_approx(feather_cells, _cached_live_disc_feather_cells)
	)
	if not changed:
		return
	_shader_mat.set_shader_parameter(&"player_map_px", map_px)
	_shader_mat.set_shader_parameter(&"reveal_radius_cells", radius_cells)
	_shader_mat.set_shader_parameter(&"reveal_feather_cells", feather_cells)
	_shader_mat.set_shader_parameter(&"live_disc_enabled", 1.0 if disc_enabled else 0.0)
	_cached_live_disc_map_px = map_px
	_cached_live_disc_moving = false
	_cached_live_disc_enabled = disc_enabled
	_cached_live_disc_radius_cells = radius_cells
	_cached_live_disc_feather_cells = feather_cells
	_last_pushed_player_map_px = map_px


func _reset_motion_disc_stamp_anchor(
	map_px: Vector2 = Vector2(UNINITIALIZED_STAMP_MAP_PX, UNINITIALIZED_STAMP_MAP_PX)
) -> void:
	_last_motion_disc_stamp_map_px = map_px


func _has_last_motion_disc_stamp_map_px() -> bool:
	return _last_motion_disc_stamp_map_px.x > UNINITIALIZED_STAMP_MAP_PX + 1.0


func _stamp_motion_disc_if_moved(map_px: Vector2) -> bool:
	if (
		_has_last_motion_disc_stamp_map_px()
		and map_px.distance_to(_last_motion_disc_stamp_map_px) < MOTION_DISC_STAMP_MIN_DISTANCE_PX
	):
		return false
	var t0: int = FogPerfProfileRes.begin(&"motion_disc_stamp")
	_stamp_disc_at_map_px(map_px)
	_schedule_mask_commit(_mask_bounds_for_disc_at_map_px(map_px), true)
	_last_motion_disc_stamp_map_px = map_px
	FogPerfProfileRes.end(&"motion_disc_stamp", t0)
	return true


func _mask_bounds_for_disc_at_map_px(map_px: Vector2) -> Vector4i:
	var center_cell: Vector2i = Vector2i(
		int(floor(_map_px_to_cell_center(map_px).x)),
		int(floor(_map_px_to_cell_center(map_px).y))
	)
	return _mask_bounds_for_disc_reveal(center_cell, PLAYER_REVEAL_RADIUS_CELLS)


func _gpu_commit_min_interval_sec() -> float:
	if Settings.has("fog.gpu_commit_min_interval_sec"):
		return maxf(Settings.get_float("fog.gpu_commit_min_interval_sec"), 0.0)
	return DEFAULT_GPU_COMMIT_MIN_INTERVAL_SEC


func _reset_motion_bake_anchor(map_px: Vector2) -> void:
	_last_motion_bake_map_px = map_px
	_last_motion_bake_sec = Time.get_ticks_msec() * 0.001


func _stamp_path_reveal_native(
	from_center: Vector2,
	to_center: Vector2,
	radius_cells: int,
	perf_scope: StringName = &""
) -> void:
	if _visibility == null:
		return
	var t0: int = 0
	if not perf_scope.is_empty():
		t0 = FogPerfProfileRes.begin(perf_scope)
	var stamped: Variant = null
	if _visibility.has_method("RevealDiscCapsuleStampNative"):
		stamped = _visibility.RevealDiscCapsuleStampNative(
			_buffer_origin_grid.x,
			_buffer_origin_grid.y,
			_buffer_size_cells,
			_buffer_size_cells,
			from_center.x,
			from_center.y,
			to_center.x,
			to_center.y,
			radius_cells,
			_mask_bytes
		)
	elif _visibility.has_method("RevealDiscPathStampNative"):
		stamped = _visibility.RevealDiscPathStampNative(
			_buffer_origin_grid.x,
			_buffer_origin_grid.y,
			_buffer_size_cells,
			_buffer_size_cells,
			from_center.x,
			from_center.y,
			to_center.x,
			to_center.y,
			radius_cells,
			_mask_bytes
		)
	if stamped != null:
		_assign_mask_from_native(stamped)
	if not perf_scope.is_empty():
		FogPerfProfileRes.end(perf_scope, t0)


func _bake_motion_reveal_segment(from_map_px: Vector2, to_map_px: Vector2) -> void:
	var from_center: Vector2 = _map_px_to_cell_center(from_map_px)
	var to_center: Vector2 = _map_px_to_cell_center(to_map_px)
	_stamp_path_reveal_native(from_center, to_center, PLAYER_REVEAL_RADIUS_CELLS, &"motion_bake_stamp")
	var dirty: Vector4i = _mask_bounds_for_disc_at_map_px(to_map_px)
	dirty = _union_mask_bounds(dirty, _mask_bounds_for_disc_at_map_px(from_map_px))
	_schedule_mask_commit(dirty, true)


func _should_bake_motion_reveal_segment(from_map_px: Vector2, to_map_px: Vector2) -> bool:
	var from_cell: Vector2i = ViewProjection.map_local_px_to_grid_cell(from_map_px)
	var to_cell: Vector2i = ViewProjection.map_local_px_to_grid_cell(to_map_px)
	var chebyshev: int = maxi(absi(to_cell.x - from_cell.x), absi(to_cell.y - from_cell.y))
	# Cell-cross persist already stamped short moves; capsule only for multi-cell gaps.
	return chebyshev > PATH_STAMP_SINGLE_DISC_MAX_CHEBYSHEV


func _mask_bounds_for_local_cells(local_min: Vector2i, local_max: Vector2i) -> Vector4i:
	var n: int = _buffer_size_cells
	local_min.x = clampi(local_min.x, 0, n - 1)
	local_min.y = clampi(local_min.y, 0, n - 1)
	local_max.x = clampi(local_max.x, 0, n - 1)
	local_max.y = clampi(local_max.y, 0, n - 1)
	if local_min.x > local_max.x or local_min.y > local_max.y:
		return INVALID_BOUNDS
	return Vector4i(local_min.x, local_min.y, local_max.x, local_max.y)


func _resolve_player_reveal_map_px(cell: Vector2i) -> Vector2:
	if _has_cached_player_map_px():
		return _cached_player_map_px
	return _cell_center_map_px(cell)


func _mask_bounds_for_disc_reveal(center_cell: Vector2i, radius_cells: int) -> Vector4i:
	var margin_cells: int = radius_cells + int(ceil(_disc_feather_cells())) + 2
	var local_center: Vector2i = center_cell - _buffer_origin_grid
	var local_min: Vector2i = local_center - Vector2i(margin_cells, margin_cells)
	var local_max: Vector2i = local_center + Vector2i(margin_cells, margin_cells)
	return _mask_bounds_for_local_cells(local_min, local_max)


func _mask_bounds_for_disc_trail(trail_cells: Array[Vector2i], radius_cells: int) -> Vector4i:
	var bounds: Vector4i = INVALID_BOUNDS
	for cell: Vector2i in trail_cells:
		bounds = _union_mask_bounds(bounds, _mask_bounds_for_disc_reveal(cell, radius_cells))
	return bounds


func _mask_bounds_for_initial_square() -> Vector4i:
	var margin_cells: int = (
		maxi(_initial_reveal_radius, 1)
		+ int(ceil(_disc_feather_cells()))
		+ 2
	)
	var local_center: Vector2i = _initial_reveal_anchor_cell - _buffer_origin_grid
	var local_min: Vector2i = local_center - Vector2i(margin_cells, margin_cells)
	var local_max: Vector2i = local_center + Vector2i(margin_cells, margin_cells)
	return _mask_bounds_for_local_cells(local_min, local_max)


func _fill_buffer_from_core() -> void:
	if _shutting_down or _visibility == null:
		return
	if _visibility.has_method("FillRevealedMaskNative"):
		_assign_mask_from_native(
			_visibility.FillRevealedMaskNative(
				_buffer_origin_grid.x,
				_buffer_origin_grid.y,
				_buffer_size_cells,
				_buffer_size_cells
			)
		)
	elif _visibility.has_method("FillRevealedMaskInto"):
		push_warning("[FogOverlay] FillRevealedMaskNative missing; Into does not write back to PackedByteArray.")
		_visibility.FillRevealedMaskInto(
			_buffer_origin_grid.x,
			_buffer_origin_grid.y,
			_buffer_size_cells,
			_buffer_size_cells,
			_mask_bytes
		)


func _recompute_buffer_origin() -> void:
	var half: int = _buffer_size_cells >> 1
	_buffer_origin_grid = _current_buffer_center_grid - Vector2i(half, half)


func _cell_center_map_px(cell: Vector2i) -> Vector2:
	var cell_px := float(ViewMetricsRes.CELL_SIZE_PX)
	return (Vector2(cell) + Vector2(0.5, 0.5)) * cell_px


func _has_cached_player_map_px() -> bool:
	return _cached_player_map_px.x > -999000.0


func _commit_initial_square_mask() -> void:
	if _visibility == null:
		return
	_sync_visibility_feather_from_settings()
	_stamp_initial_square_into_mask()
	_initial_square_committed = true
	_push_live_disc_layout_uniforms()
	# First bootstrap commit uploads the full buffer so feather texels cannot be clipped by dirty rects.
	var mask_size: int = _mask_size_cells()
	_schedule_mask_commit(Vector4i(0, 0, mask_size - 1, mask_size - 1), true)
	flush_presentation(true)
	_update_fog_rect_visibility()


func _refresh_initial_square_mask() -> void:
	if _visibility == null:
		return
	_stamp_initial_square_into_mask()
	_schedule_mask_commit(_mask_bounds_for_initial_square(), true)
	flush_presentation(true)


func _bind_buffer_layout_uniforms() -> void:
	_bind_buffer_layout_uniforms_with_origin(_buffer_origin_grid)


func _bind_buffer_layout_uniforms_with_origin(origin_grid: Vector2i) -> void:
	if _shader_mat == null:
		return
	var cell_px := float(ViewMetricsRes.CELL_SIZE_PX)
	var world_buffer_origin_px := Vector2(origin_grid) * cell_px
	_shader_mat.set_shader_parameter(&"world_buffer_origin_px", world_buffer_origin_px)
	_shader_mat.set_shader_parameter(&"buffer_size_cells", Vector2(_buffer_size_cells, _buffer_size_cells))
	_shader_mat.set_shader_parameter(&"cell_size_px", cell_px)
	_shader_mat.set_shader_parameter(&"fog_opacity", 1.0)
	_shader_mat.set_shader_parameter(&"fog_edge_aa_strength", _fog_edge_aa_strength)
	_push_live_disc_layout_uniforms()
	if _fog_texture != null:
		_shader_mat.set_shader_parameter(&"fog_texture", _fog_texture)


func _push_live_disc_layout_uniforms() -> void:
	if _shader_mat == null:
		return
	_shader_mat.set_shader_parameter(&"reveal_radius_cells", float(PLAYER_REVEAL_RADIUS_CELLS))
	_shader_mat.set_shader_parameter(&"reveal_feather_cells", _disc_feather_cells())
	_shader_mat.set_shader_parameter(&"live_disc_enabled", 0.0)


func _push_projection_uniforms(frame: ViewFrameScript) -> void:
	if _shutting_down or _shader_mat == null or frame == null:
		return
	if not is_equal_approx(frame.zoom, _cached_projection_zoom):
		_invalidate_projection_cache()
		_cached_projection_zoom = frame.zoom
	_push_canvas_to_map_uniforms(frame.canvas_to_map_local)


func _push_projection_fallback() -> void:
	if _shutting_down or _shader_mat == null:
		return
	_push_canvas_to_map_uniforms(ViewProjection.canvas_to_map_local_transform())


func _push_canvas_to_map_uniforms(canvas_to_map: Transform2D) -> void:
	if _shader_mat == null:
		return
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
	_cached_projection_zoom = -1.0


func _load_reveal_radii_from_settings() -> void:
	_initial_reveal_radius = maxi(Settings.initial_reveal_radius, 1)
	_initial_reveal_corner_radius = maxi(Settings.initial_reveal_corner_radius, 0)


func _on_fog_settings_changed() -> void:
	if _shutting_down:
		return
	_schedule_fog_settings_refresh()


func _schedule_fog_settings_refresh() -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		call_deferred("_apply_fog_settings_refresh")
		return
	if _fog_settings_refresh_timer != null and is_instance_valid(_fog_settings_refresh_timer):
		var cb := Callable(self, "_apply_fog_settings_refresh")
		if _fog_settings_refresh_timer.timeout.is_connected(cb):
			_fog_settings_refresh_timer.timeout.disconnect(cb)
	_fog_settings_refresh_timer = tree.create_timer(FOG_SETTINGS_REFRESH_DEBOUNCE_SEC)
	_fog_settings_refresh_timer.timeout.connect(_apply_fog_settings_refresh, CONNECT_ONE_SHOT)


func _apply_fog_settings_refresh() -> void:
	if _shutting_down:
		return

	var old_corner: int = _initial_reveal_corner_radius
	_load_reveal_radii_from_settings()
	_read_presentation_settings()

	var initial_corner_changed: bool = _initial_reveal_corner_radius != old_corner

	if _visibility != null:
		_visibility.InitialRevealRadius = _initial_reveal_radius
		_visibility.MovementRevealRadius = PLAYER_REVEAL_RADIUS_CELLS
	_sync_visibility_feather_from_settings()

	if not _configured:
		return

	if initial_corner_changed:
		_refresh_initial_square_mask()
	else:
		_bind_buffer_layout_uniforms()
		flush_presentation(true)
		return

	_bind_buffer_layout_uniforms()
	flush_presentation(true)


func _read_buffer_settings() -> void:
	_settings_buffer_floor = _read_int_setting(&"fog.buffer_size_cells", DEFAULT_BUFFER_SIZE_CELLS)
	_recenter_margin_cells = _read_int_setting(
		&"fog.recenter_margin_cells",
		DEFAULT_RECENTER_MARGIN_CELLS
	)
	_read_presentation_settings()


func _read_presentation_settings() -> void:
	if Settings.has("fog.edge_feather_px"):
		_edge_feather_px = maxf(Settings.fog_edge_feather_px, 0.0)
	else:
		_edge_feather_px = DEFAULT_EDGE_FEATHER_PX
	if Settings.has("fog.edge_aa_strength"):
		_fog_edge_aa_strength = clampf(Settings.get_float("fog.edge_aa_strength"), 0.0, 1.0)
	else:
		_fog_edge_aa_strength = 0.0
	_sync_visibility_feather_from_settings()
	if _shader_mat != null:
		_shader_mat.set_shader_parameter(&"fog_edge_aa_strength", _fog_edge_aa_strength)


func _read_int_setting(key: StringName, default_value: int) -> int:
	if Settings.has(key):
		return maxi(int(Settings.get_float(key)), 0)
	return default_value
