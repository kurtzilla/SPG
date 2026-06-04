extends Node2D

## Streams terrain chunks in a window around the player grid position.
##
## Prefetch ring (viewport-aware) queues chunk jobs; prefetch ring controls unloads after bootstrap.
## Multiple ChunkLoadJobs share a per-frame cell + time budget via round-robin _process.
## TileMapLayer nodes are pooled to avoid alloc/free hitches on chunk boundaries.

const NO_CHUNK: Vector2i = Vector2i(999999, 999999)

const ChunkDataScript = preload("res://src/Godot/Scripts/World/ChunkData.gd")
const ChunkLoadJobScript = preload("res://src/Godot/Scripts/World/ChunkLoadJob.gd")
const ChunkPerfProfileRes = preload("res://src/Godot/Scripts/World/ChunkPerfProfile.gd")
const TT = preload("res://src/Godot/Scripts/World/TerrainType.gd")
const ViewMetricsScript = preload("res://src/Godot/Scripts/ViewMetrics.gd")
const TerrainSandboxTileSetScript = preload("res://src/Godot/Scripts/TerrainSandboxTileSet.gd")
enum BootstrapPhase {NONE, KEEP, PREFETCH, DONE}

signal chunk_finished(chunk_coord: Vector2i)

var _chunk_size: int = 32
var _cells_per_chunk: int = 1024
var _keep_offsets: Array[Vector2i] = []
var _prefetch_offsets: Array[Vector2i] = []
var _pool_target_size: int = 9

var _noise_seed: int = 42
var _noise_frequency: float = 0.04
var _water_threshold: float = 0.62
var _mud_threshold: float = 0.45
var _cells_per_frame: int = 192
var _cells_paint_per_frame: int = 96
var _max_paint_cells_per_frame: int = 64
var _max_gen_cells_per_frame: int = 128
var _chunk_show_min_paint_cells: int = 256
var _chunk_frame_budget_usec: int = 3500
var _bootstrap_cells_per_frame: int = 512
var _bootstrap_cells_paint_per_frame: int = 256
var _bootstrap_chunk_frame_budget_usec: int = 6000
var _bootstrap_max_active_jobs: int = 3
var _bootstrap_layer_acquires_per_frame: int = 3
var _unload_chunks_per_frame: int = 1
var _max_active_jobs: int = 2
var _layer_acquires_per_frame: int = 2
var _bootstrap_phase: BootstrapPhase = BootstrapPhase.NONE
var _spawn_safe_zone_x: int = 0
var _spawn_safe_zone_y: int = 0
var _safe_zone_radius: int = 2
var _safe_zone_lo_x: int = 0
var _safe_zone_hi_x: int = 0
var _safe_zone_lo_y: int = 0
var _safe_zone_hi_y: int = 0
var _load_radius: int = 2
var _load_radius_buffer: int = 1
var _load_radius_view_padding: int = 2

var _noise: FastNoiseLite
var _tile_set: TileSet
var _chunks: Dictionary = {}
var _layers: Dictionary = {}
var _last_center_chunk: Vector2i = NO_CHUNK
var _last_load_center_chunk: Vector2i = NO_CHUNK
var _tile_size: int = ViewMetricsScript.CELL_SIZE_PX

var _atlas_land: Vector2i
var _atlas_water: Vector2i
var _atlas_mud: Vector2i
var _atlas_by_terrain: Array[Vector2i] = []

var _pending_coords: Array[Vector2i] = []
var _pending_loads: Dictionary = {}
var _active_jobs: Array[ChunkLoadJob] = []
var _unload_queue: Array[Vector2i] = []
var _keep_wanted: Dictionary = {}
var _prefetch_wanted: Dictionary = {}

var _layer_pool: Array[TileMapLayer] = []
var _layer_acquires_this_frame: int = 0
var _prewarm_remaining: int = 0

const VIEW_REFRESH_BURST_FRAMES: int = 3
const VIEW_REFRESH_BURST_JOB_MULT: int = 3
const VIEW_REFRESH_BURST_ACQUIRE_MULT: int = 3

const MOTION_BURST_FRAMES: int = 4
const MOTION_BURST_JOB_MULT: int = 2
const MOTION_BURST_ACQUIRE_MULT: int = 2
const CHUNK_CROSS_BURST_MAX_FRAMES: int = 30
const CHUNK_EDGE_PREFETCH_CELLS: int = 16
const CHUNK_EDGE_URGENT_CELLS: int = 8

var _view_refresh_burst_remaining: int = 0
var _burst_max_active_jobs: int = 0
var _burst_layer_acquires_per_frame: int = 0

var _motion_burst_remaining: int = 0
var _motion_burst_max_active_jobs: int = 0
var _motion_burst_layer_acquires_per_frame: int = 0
var _chunk_cross_burst_remaining: int = 0
var _chunk_cross_burst_elapsed: int = 0
var _chunk_cross_burst_max_active_jobs: int = 0
var _chunk_cross_burst_layer_acquires_per_frame: int = 0
var _motion_lead_chunks: int = 1
var _motion_reprio_min_speed_sq: float = 80.0 * 80.0
var _motion_reprio_interval_sec: float = 0.1
var _last_motion_reprio_sec: float = -999999.0
var _load_priority_axis: Vector2i = Vector2i.ZERO


func _ready() -> void:
	_read_world_settings()
	_build_chunk_offsets()
	_noise = FastNoiseLite.new()
	_noise.seed = _noise_seed
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.frequency = _noise_frequency
	_tile_set = TerrainSandboxTileSetScript.build()
	_atlas_land = TerrainSandboxTileSetScript.atlas_for_terrain(TT.LAND)
	_atlas_water = TerrainSandboxTileSetScript.atlas_for_terrain(TT.WATER)
	_atlas_mud = TerrainSandboxTileSetScript.atlas_for_terrain(TT.MUD)
	_atlas_by_terrain = [_atlas_land, _atlas_water, _atlas_mud]
	_prewarm_remaining = mini(_keep_offsets.size(), 9)
	call_deferred("_prewarm_layer_pool_tick")


func _read_world_settings() -> void:
	_chunk_size = Settings.get_int("world.chunk_size")
	_cells_per_chunk = _chunk_size * _chunk_size
	_noise_seed = Settings.get_int("world.noise_seed")
	_noise_frequency = Settings.get_float("world.noise_frequency")
	_water_threshold = Settings.get_float("world.water_threshold")
	_mud_threshold = Settings.get_float("world.mud_threshold")
	_cells_per_frame = Settings.get_int("world.cells_per_frame")
	_cells_paint_per_frame = Settings.get_int("world.cells_paint_per_frame")
	_max_paint_cells_per_frame = maxi(Settings.get_int("world.max_paint_cells_per_frame"), 1)
	_max_gen_cells_per_frame = maxi(Settings.get_int("world.max_gen_cells_per_frame"), 1)
	_chunk_show_min_paint_cells = clampi(
		Settings.get_int("world.chunk_show_min_paint_cells"),
		1,
		_chunk_size * _chunk_size
	)
	_chunk_frame_budget_usec = Settings.get_int("world.chunk_frame_budget_usec")
	_unload_chunks_per_frame = Settings.get_int("world.unload_chunks_per_frame")
	_max_active_jobs = maxi(Settings.get_int("world.max_active_chunk_jobs"), 1)
	_layer_acquires_per_frame = maxi(Settings.get_int("world.layer_acquires_per_frame"), 1)
	_bootstrap_cells_per_frame = Settings.get_int("world.bootstrap_cells_per_frame")
	_bootstrap_cells_paint_per_frame = Settings.get_int("world.bootstrap_cells_paint_per_frame")
	_bootstrap_chunk_frame_budget_usec = Settings.get_int("world.bootstrap_chunk_frame_budget_usec")
	_bootstrap_max_active_jobs = maxi(Settings.get_int("world.bootstrap_max_active_chunk_jobs"), 1)
	_bootstrap_layer_acquires_per_frame = maxi(Settings.get_int("world.layer_acquires_per_frame"), 1)
	_spawn_safe_zone_x = Settings.get_int("world.spawn_safe_zone_x")
	_spawn_safe_zone_y = Settings.get_int("world.spawn_safe_zone_y")
	_safe_zone_radius = Settings.get_int("world.safe_zone_radius")
	_safe_zone_lo_x = _spawn_safe_zone_x - _safe_zone_radius
	_safe_zone_hi_x = _spawn_safe_zone_x + _safe_zone_radius
	_safe_zone_lo_y = _spawn_safe_zone_y - _safe_zone_radius
	_safe_zone_hi_y = _spawn_safe_zone_y + _safe_zone_radius
	_load_radius = Settings.get_int("world.load_radius")
	_load_radius_buffer = Settings.get_int("world.load_radius_buffer")
	if Settings.has("world.load_radius_view_padding"):
		_load_radius_view_padding = maxi(Settings.get_int("world.load_radius_view_padding"), 0)
	_motion_lead_chunks = maxi(Settings.get_int("world.motion_lead_chunks"), 0)
	var motion_speed: float = Settings.get_float("world.motion_reprio_min_speed_px")
	_motion_reprio_min_speed_sq = motion_speed * motion_speed
	_motion_reprio_interval_sec = maxf(Settings.get_float("world.motion_reprio_interval_sec"), 0.0)
	_cells_paint_per_frame = mini(_cells_paint_per_frame, _cells_per_frame)
	_bootstrap_cells_paint_per_frame = mini(_bootstrap_cells_paint_per_frame, _bootstrap_cells_per_frame)


func _compute_prefetch_radius() -> int:
	var base_radius: int = _load_radius
	var buffer: int = _load_radius_buffer
	if not ViewProjection.are_viewport_metrics_ready():
		return base_radius + buffer
	var cell_radius: int = ViewProjection.get_visual_radius(buffer)
	var viewport_radius: int = _div_floor(cell_radius, _chunk_size) + 1
	return maxi(base_radius + buffer, viewport_radius + _load_radius_view_padding)


func _build_chunk_offsets() -> void:
	_keep_offsets.clear()
	var keep_radius: int = _load_radius
	for dy: int in range(-keep_radius, keep_radius + 1):
		for dx: int in range(-keep_radius, keep_radius + 1):
			_keep_offsets.append(Vector2i(dx, dy))

	_prefetch_offsets.clear()
	var prefetch_radius: int = _compute_prefetch_radius()
	for dy: int in range(-prefetch_radius, prefetch_radius + 1):
		for dx: int in range(-prefetch_radius, prefetch_radius + 1):
			_prefetch_offsets.append(Vector2i(dx, dy))

	_pool_target_size = maxi(_keep_offsets.size(), _prefetch_offsets.size())


func _process(delta: float) -> void:
	ChunkPerfProfileRes.notify_frame()
	_layer_acquires_this_frame = 0
	_try_start_jobs()
	_step_active_jobs()
	_advance_bootstrap_phase()
	ChunkPerfProfileRes.maybe_report(delta)
	if _view_refresh_burst_remaining > 0:
		_view_refresh_burst_remaining -= 1
	if _motion_burst_remaining > 0:
		_motion_burst_remaining -= 1
	if _chunk_cross_burst_remaining > 0:
		_chunk_cross_burst_elapsed += 1
		if (
			_chunk_cross_burst_elapsed >= CHUNK_CROSS_BURST_MAX_FRAMES
			or not _leading_edge_streaming_incomplete()
		):
			_chunk_cross_burst_remaining = 0
			_chunk_cross_burst_elapsed = 0
	if (
		_view_refresh_burst_remaining <= 0
		and _motion_burst_remaining <= 0
		and _chunk_cross_burst_remaining <= 0
	):
		_step_unload_budget()
	elif _motion_burst_remaining > 0 or _chunk_cross_burst_remaining > 0:
		# Defer unloads while catching up terrain ahead of movement / chunk cross.
		_purge_unload_queue_for_wanted(_active_wanted_set())


func force_viewport_chunk_refresh() -> void:
	_build_chunk_offsets()
	_cancel_unloads_in_wanted(_prefetch_wanted)
	_purge_unload_queue_for_wanted(_prefetch_wanted)
	_begin_view_refresh_burst()
	if _last_center_chunk != NO_CHUNK:
		var load_center: Vector2i = _last_load_center_chunk
		if load_center == NO_CHUNK:
			load_center = _last_center_chunk
		_refresh_active_chunks(_last_center_chunk, load_center)


## One-shot synchronous load of the keep ring on scene start.
func force_immediate_startup_pass(center_grid_tile: Vector2i) -> void:
	_last_center_chunk = NO_CHUNK
	update_center_grid(center_grid_tile)
	var deadline: int = Time.get_ticks_usec() + 3_000_000_000
	while _bootstrap_phase == BootstrapPhase.KEEP:
		if Time.get_ticks_usec() >= deadline:
			if OS.is_debug_build():
				push_warning("ChunkManager: keep-ring startup pass timed out before full paint")
			break
		_layer_acquires_this_frame = 0
		_try_start_jobs()
		_step_active_jobs()
		if _keep_ring_loaded() and _pending_coords.is_empty() and _active_jobs.is_empty():
			break


func _active_wanted_set() -> Dictionary:
	if _bootstrap_phase == BootstrapPhase.KEEP:
		return _keep_wanted
	return _prefetch_wanted


func _purge_unload_queue_for_wanted(wanted: Dictionary) -> void:
	var i: int = 0
	while i < _unload_queue.size():
		if wanted.has(_unload_queue[i]):
			_unload_queue.remove_at(i)
		else:
			i += 1


func _begin_view_refresh_burst() -> void:
	_view_refresh_burst_remaining = VIEW_REFRESH_BURST_FRAMES
	_burst_max_active_jobs = _max_active_jobs * VIEW_REFRESH_BURST_JOB_MULT
	_burst_layer_acquires_per_frame = _layer_acquires_per_frame * VIEW_REFRESH_BURST_ACQUIRE_MULT


func _begin_motion_burst() -> void:
	_motion_burst_remaining = MOTION_BURST_FRAMES
	_motion_burst_max_active_jobs = _max_active_jobs * MOTION_BURST_JOB_MULT
	_motion_burst_layer_acquires_per_frame = _layer_acquires_per_frame * MOTION_BURST_ACQUIRE_MULT


func _begin_chunk_cross_burst() -> void:
	_chunk_cross_burst_remaining = 1
	_chunk_cross_burst_elapsed = 0
	_chunk_cross_burst_max_active_jobs = _max_active_jobs * MOTION_BURST_JOB_MULT
	_chunk_cross_burst_layer_acquires_per_frame = _layer_acquires_per_frame * MOTION_BURST_ACQUIRE_MULT


func _leading_edge_streaming_incomplete() -> bool:
	var load_center: Vector2i = _last_load_center_chunk
	if load_center == NO_CHUNK:
		load_center = _last_center_chunk
	if load_center == NO_CHUNK:
		return not _active_jobs.is_empty()
	for job: ChunkLoadJob in _active_jobs:
		if _is_leading_edge_coord(job.coord, load_center):
			return true
	for coord: Vector2i in _pending_coords:
		if _is_leading_edge_coord(coord, load_center):
			return true
	return false


func _is_leading_edge_coord(coord: Vector2i, load_center: Vector2i) -> bool:
	if _load_priority_axis == Vector2i.ZERO:
		return absi(coord.x - load_center.x) + absi(coord.y - load_center.y) <= 1
	if _load_priority_axis.x > 0:
		return coord.x >= load_center.x
	if _load_priority_axis.x < 0:
		return coord.x <= load_center.x
	if _load_priority_axis.y > 0:
		return coord.y >= load_center.y
	return coord.y <= load_center.y


func _load_priority(coord: Vector2i, load_center: Vector2i) -> int:
	var priority: int = absi(coord.x - load_center.x) + absi(coord.y - load_center.y)
	if _load_priority_axis.x > 0 and coord.x > load_center.x:
		priority -= 2
	elif _load_priority_axis.x < 0 and coord.x < load_center.x:
		priority -= 2
	if _load_priority_axis.y > 0 and coord.y > load_center.y:
		priority -= 2
	elif _load_priority_axis.y < 0 and coord.y < load_center.y:
		priority -= 2
	return priority


func _reprioritize_pending(load_center: Vector2i) -> void:
	if _pending_coords.is_empty():
		return
	_pending_coords.sort_custom(
		func(a: Vector2i, b: Vector2i) -> bool:
			return _load_priority(a, load_center) < _load_priority(b, load_center)
	)


func _velocity_chunk_axis(velocity_map_px: Vector2) -> Vector2i:
	if velocity_map_px.length_squared() < _motion_reprio_min_speed_sq:
		return Vector2i.ZERO
	if absf(velocity_map_px.x) >= absf(velocity_map_px.y):
		if is_zero_approx(velocity_map_px.x):
			return Vector2i.ZERO
		return Vector2i(signi(int(sign(velocity_map_px.x))), 0)
	if is_zero_approx(velocity_map_px.y):
		return Vector2i.ZERO
	return Vector2i(0, signi(int(sign(velocity_map_px.y))))


func sync_center_from_player_map_px(map_px: Vector2) -> void:
	sync_center_from_player_motion(map_px, Vector2.ZERO)


## Keeps prefetch ahead of fast movement; throttled reprioritize while moving (not every frame).
func sync_center_from_player_motion(map_px: Vector2, velocity_map_px: Vector2 = Vector2.ZERO) -> void:
	_load_priority_axis = _velocity_chunk_axis(velocity_map_px)
	var grid_tile: Vector2i = world_px_to_grid_tile(map_px)
	var center_chunk: Vector2i = grid_to_chunk_coord(grid_tile)
	var load_center: Vector2i = center_chunk
	if _load_priority_axis != Vector2i.ZERO and _motion_lead_chunks > 0:
		load_center = center_chunk + _load_priority_axis * _motion_lead_chunks

	if center_chunk != _last_center_chunk:
		update_center_grid(grid_tile, load_center)
		return

	_maybe_prefetch_chunk_edge(grid_tile, load_center, velocity_map_px)
	_maybe_motion_prefetch(load_center, velocity_map_px)


func _maybe_motion_prefetch(load_center: Vector2i, velocity_map_px: Vector2) -> void:
	if velocity_map_px.length_squared() < _motion_reprio_min_speed_sq:
		return
	var now_sec: float = Time.get_ticks_msec() * 0.001
	if _motion_reprio_interval_sec > 0.0 and now_sec - _last_motion_reprio_sec < _motion_reprio_interval_sec:
		return
	_last_motion_reprio_sec = now_sec
	_reprioritize_pending(load_center)
	_ensure_prefetch_at_load_center(load_center)
	if _motion_burst_remaining <= 0:
		_begin_motion_burst()


func update_center_grid(grid_tile: Vector2i, load_center: Vector2i = NO_CHUNK) -> void:
	var center_chunk: Vector2i = grid_to_chunk_coord(grid_tile)
	if load_center == NO_CHUNK:
		load_center = center_chunk
	if center_chunk == _last_center_chunk and load_center == _last_load_center_chunk:
		return
	_last_center_chunk = center_chunk
	_last_load_center_chunk = load_center
	var t0: int = ChunkPerfProfileRes.begin(&"chunk_cross_refresh")
	_refresh_active_chunks(center_chunk, load_center)
	ChunkPerfProfileRes.end(&"chunk_cross_refresh", t0)
	_reprioritize_pending(load_center)
	_begin_chunk_cross_burst()


func _maybe_prefetch_chunk_edge(grid_tile: Vector2i, load_center: Vector2i, velocity_map_px: Vector2) -> void:
	if _bootstrap_phase == BootstrapPhase.KEEP:
		return
	if velocity_map_px.length_squared() < _motion_reprio_min_speed_sq:
		return
	var chunk_origin: Vector2i = grid_to_chunk_coord(grid_tile) * _chunk_size
	var local: Vector2i = grid_tile - chunk_origin
	var edge_limit: int = CHUNK_EDGE_PREFETCH_CELLS
	var near_edge: bool = (
		local.x <= edge_limit
		or local.y <= edge_limit
		or local.x >= _chunk_size - 1 - edge_limit
		or local.y >= _chunk_size - 1 - edge_limit
	)
	if near_edge:
		var urgent: bool = (
			local.x <= CHUNK_EDGE_URGENT_CELLS
			or local.y <= CHUNK_EDGE_URGENT_CELLS
			or local.x >= _chunk_size - 1 - CHUNK_EDGE_URGENT_CELLS
			or local.y >= _chunk_size - 1 - CHUNK_EDGE_URGENT_CELLS
		)
		if not urgent:
			var now_sec: float = Time.get_ticks_msec() * 0.001
			if (
				_motion_reprio_interval_sec > 0.0
				and now_sec - _last_motion_reprio_sec < _motion_reprio_interval_sec
			):
				return
		_last_motion_reprio_sec = Time.get_ticks_msec() * 0.001
		_reprioritize_pending(load_center)
		_ensure_prefetch_at_load_center(load_center)
		if _motion_burst_remaining <= 0 and _chunk_cross_burst_remaining <= 0:
			_begin_motion_burst()


func get_tile_type_at_grid(grid_tile: Vector2i) -> int:
	var chunk_coord := grid_to_chunk_coord(grid_tile)
	var local := grid_tile - chunk_coord * _chunk_size
	if _chunks.has(chunk_coord):
		var data: ChunkData = _chunks[chunk_coord]
		return data.get_tile_index(local.y * _chunk_size + local.x)
	return _terrain_at_grid_tile(grid_tile)


func get_tile_type_at_global_pos(pos: Vector2) -> int:
	return get_tile_type_at_grid(world_px_to_grid_tile(pos))


## Floor division for grid tile -> chunk index (correct for negative coordinates).
func grid_to_chunk_coord(grid_tile: Vector2i) -> Vector2i:
	return Vector2i(
		_div_floor(grid_tile.x, _chunk_size),
		_div_floor(grid_tile.y, _chunk_size)
	)


func world_px_to_grid_tile(pos: Vector2) -> Vector2i:
	return Vector2i(
		floori(pos.x / float(_tile_size)),
		floori(pos.y / float(_tile_size))
	)


func _refresh_active_chunks(center: Vector2i, load_center: Vector2i = NO_CHUNK) -> void:
	if load_center == NO_CHUNK:
		load_center = center
	if _layers.is_empty():
		_bootstrap_phase = BootstrapPhase.KEEP

	_keep_wanted.clear()
	for offset: Vector2i in _keep_offsets:
		_keep_wanted[center + offset] = true

	_prefetch_wanted.clear()
	for offset: Vector2i in _prefetch_offsets:
		_prefetch_wanted[center + offset] = true
	if load_center != center:
		for offset: Vector2i in _prefetch_offsets:
			_prefetch_wanted[load_center + offset] = true

	if _bootstrap_phase == BootstrapPhase.KEEP:
		_cancel_loads_not_in_prefetch(_keep_wanted)
	else:
		_cancel_loads_not_in_prefetch(_prefetch_wanted)
	var wanted: Dictionary = _active_wanted_set()
	_cancel_unloads_in_wanted(wanted)

	for chunk_coord in _layers.keys():
		if not wanted.has(chunk_coord):
			_enqueue_unload(chunk_coord)

	match _bootstrap_phase:
		BootstrapPhase.KEEP:
			for offset: Vector2i in _keep_offsets:
				var coord: Vector2i = center + offset
				if _layers.has(coord) or _is_chunk_pending(coord):
					continue
				_enqueue_load(coord, load_center)
		BootstrapPhase.PREFETCH:
			_enqueue_prefetch_ring(load_center)
		_:
			_enqueue_prefetch_ring(load_center)


func _enqueue_prefetch_ring(load_center: Vector2i) -> void:
	for offset: Vector2i in _prefetch_offsets:
		var coord: Vector2i = load_center + offset
		if _layers.has(coord) or _is_chunk_pending(coord):
			continue
		_enqueue_load(coord, load_center)


func _ensure_prefetch_at_load_center(load_center: Vector2i) -> void:
	if _bootstrap_phase == BootstrapPhase.KEEP:
		return
	_enqueue_prefetch_ring(load_center)


func _enqueue_load(coord: Vector2i, load_center: Vector2i) -> void:
	if _pending_loads.has(coord):
		return
	var priority: int = _load_priority(coord, load_center)
	if coord == load_center and _bootstrap_phase == BootstrapPhase.KEEP:
		priority = 0
	var insert_at: int = _pending_coords.size()
	for i: int in range(_pending_coords.size()):
		var existing: Vector2i = _pending_coords[i]
		var existing_priority: int = _load_priority(existing, load_center)
		if priority < existing_priority:
			insert_at = i
			break
	_pending_coords.insert(insert_at, coord)
	_pending_loads[coord] = true


func _enqueue_unload(chunk_coord: Vector2i) -> void:
	if _unload_queue.has(chunk_coord):
		return
	_unload_queue.append(chunk_coord)


func _cancel_unloads_in_wanted(wanted: Dictionary) -> void:
	var i: int = 0
	while i < _unload_queue.size():
		if wanted.has(_unload_queue[i]):
			_unload_queue.remove_at(i)
		else:
			i += 1


func _step_unload_budget() -> void:
	var wanted: Dictionary = _active_wanted_set()
	var budget: int = maxi(_unload_chunks_per_frame, 1)
	while budget > 0 and not _unload_queue.is_empty():
		var chunk_coord: Vector2i = _unload_queue.pop_front()
		if wanted.has(chunk_coord):
			continue
		if _layers.has(chunk_coord):
			_unload_chunk(chunk_coord)
		budget -= 1


func _is_chunk_pending(coord: Vector2i) -> bool:
	for job: ChunkLoadJob in _active_jobs:
		if job.coord == coord:
			return true
	return _pending_loads.has(coord)


func _cancel_loads_not_in_prefetch(prefetch_wanted: Dictionary) -> void:
	var i: int = _active_jobs.size() - 1
	while i >= 0:
		var job: ChunkLoadJob = _active_jobs[i]
		if not prefetch_wanted.has(job.coord):
			_cancel_job(job)
			_active_jobs.remove_at(i)
		i -= 1

	i = 0
	while i < _pending_coords.size():
		var queued: Vector2i = _pending_coords[i]
		if not prefetch_wanted.has(queued):
			_pending_coords.remove_at(i)
			_pending_loads.erase(queued)
		else:
			i += 1


func _effective_gen_budget() -> int:
	var budget: int = _cells_per_frame
	if _bootstrap_phase == BootstrapPhase.KEEP:
		budget = _bootstrap_cells_per_frame
	return mini(maxi(budget, 1), _max_gen_cells_per_frame)


func _effective_paint_budget() -> int:
	var budget: int = _cells_paint_per_frame
	if _bootstrap_phase == BootstrapPhase.KEEP:
		budget = _bootstrap_cells_paint_per_frame
	return mini(maxi(budget, 1), _max_paint_cells_per_frame)


func _effective_frame_budget_usec() -> int:
	var budget: int = _chunk_frame_budget_usec
	if _bootstrap_phase == BootstrapPhase.KEEP:
		budget = _bootstrap_chunk_frame_budget_usec
	return budget


func _effective_max_active_jobs() -> int:
	var jobs: int = _max_active_jobs
	if _bootstrap_phase == BootstrapPhase.KEEP:
		jobs = _bootstrap_max_active_jobs
	if _view_refresh_burst_remaining > 0:
		jobs = maxi(_burst_max_active_jobs, jobs)
	if _motion_burst_remaining > 0:
		jobs = maxi(_motion_burst_max_active_jobs, jobs)
	if _chunk_cross_burst_remaining > 0:
		jobs = maxi(_chunk_cross_burst_max_active_jobs, jobs)
	return maxi(jobs, 1)


func _effective_layer_acquires_per_frame() -> int:
	var acquires: int = _layer_acquires_per_frame
	if _bootstrap_phase == BootstrapPhase.KEEP:
		acquires = _bootstrap_layer_acquires_per_frame
	if _view_refresh_burst_remaining > 0:
		acquires = maxi(_burst_layer_acquires_per_frame, acquires)
	if _motion_burst_remaining > 0:
		acquires = maxi(_motion_burst_layer_acquires_per_frame, acquires)
	if _chunk_cross_burst_remaining > 0:
		acquires = maxi(_chunk_cross_burst_layer_acquires_per_frame, acquires)
	return maxi(acquires, 1)


func _advance_bootstrap_phase() -> void:
	if _bootstrap_phase == BootstrapPhase.KEEP:
		if _keep_ring_loaded():
			_bootstrap_phase = BootstrapPhase.PREFETCH
			if _last_center_chunk != NO_CHUNK:
				_enqueue_prefetch_ring(_last_center_chunk)
	elif _bootstrap_phase == BootstrapPhase.PREFETCH:
		if _prefetch_ring_loaded():
			_bootstrap_phase = BootstrapPhase.DONE


func _keep_ring_loaded() -> bool:
	if _keep_wanted.is_empty():
		return false
	for coord in _keep_wanted.keys():
		if not _layers.has(coord):
			return false
	return true


func _prefetch_ring_loaded() -> bool:
	if _prefetch_wanted.is_empty():
		return true
	for coord in _prefetch_wanted.keys():
		if not _layers.has(coord):
			return false
	return true


func _prewarm_layer_pool_tick() -> void:
	var per_frame: int = 2
	while _prewarm_remaining > 0 and per_frame > 0:
		if _layer_pool.size() >= _pool_target_size:
			_prewarm_remaining = 0
			break
		var layer := TileMapLayer.new()
		layer.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		layer.tile_set = _tile_set
		_layer_pool.append(layer)
		_prewarm_remaining -= 1
		per_frame -= 1
	if _prewarm_remaining > 0:
		call_deferred("_prewarm_layer_pool_tick")


func _try_start_jobs() -> void:
	var max_jobs: int = _effective_max_active_jobs()
	var max_acquires: int = _effective_layer_acquires_per_frame()
	while (
		_active_jobs.size() < max_jobs
		and not _pending_coords.is_empty()
		and _layer_acquires_this_frame < max_acquires
	):
		var coord: Vector2i = _pending_coords.pop_front()
		_pending_loads.erase(coord)
		if _layers.has(coord):
			continue
		_start_job(coord)


func _start_job(chunk_coord: Vector2i) -> void:
	var job: ChunkLoadJob = ChunkLoadJobScript.new()
	job.coord = chunk_coord
	job.origin = chunk_coord * _chunk_size
	job.layer = _acquire_layer(chunk_coord)
	job.data = ChunkDataScript.new(chunk_coord, _chunk_size)
	job.fill_land = _chunk_fully_inside_safe_zone(chunk_coord)
	job.skip_safe_zone = _chunk_fully_outside_safe_zone(chunk_coord)
	_layer_acquires_this_frame += 1
	if job.layer.is_inside_tree():
		job.phase = ChunkLoadJobScript.Phase.GENERATE
	else:
		job.phase = ChunkLoadJobScript.Phase.WAIT_TREE
	_active_jobs.append(job)


func _step_active_jobs() -> void:
	if _active_jobs.is_empty():
		return

	var deadline: int = Time.get_ticks_usec() + _effective_frame_budget_usec()
	var gen_budget: int = _effective_gen_budget()
	var paint_budget: int = _effective_paint_budget()
	_step_job_list(_active_jobs_burst_ordered(), deadline, gen_budget, paint_budget)


func _resolve_load_center() -> Vector2i:
	if _last_load_center_chunk != NO_CHUNK:
		return _last_load_center_chunk
	return _last_center_chunk


func _active_jobs_burst_ordered() -> Array[ChunkLoadJob]:
	if _chunk_cross_burst_remaining <= 0:
		return _active_jobs
	var load_center: Vector2i = _resolve_load_center()
	if load_center == NO_CHUNK:
		return _active_jobs
	var leading_jobs: Array[ChunkLoadJob] = []
	var other_jobs: Array[ChunkLoadJob] = []
	for job: ChunkLoadJob in _active_jobs:
		if _is_leading_edge_coord(job.coord, load_center):
			leading_jobs.append(job)
		else:
			other_jobs.append(job)
	var ordered: Array[ChunkLoadJob] = []
	ordered.append_array(leading_jobs)
	ordered.append_array(other_jobs)
	return ordered


func _step_job_list(
	jobs: Array[ChunkLoadJob],
	deadline: int,
	gen_budget: int,
	paint_budget: int
) -> Dictionary:
	var job_index: int = 0
	while job_index < jobs.size():
		if Time.get_ticks_usec() >= deadline:
			break
		if gen_budget <= 0 and paint_budget <= 0:
			break

		var job: ChunkLoadJob = jobs[job_index]
		var step := _step_job(job, deadline, gen_budget, paint_budget)
		gen_budget = step.gen_budget
		paint_budget = step.paint_budget
		if step.finished:
			var active_index: int = _active_jobs.find(job)
			if active_index >= 0:
				_active_jobs.remove_at(active_index)
			jobs.remove_at(job_index)
			continue
		job_index += 1
	return {"gen_remaining": gen_budget, "paint_remaining": paint_budget}


func _step_job(job: ChunkLoadJob, deadline: int, gen_budget: int, paint_budget: int) -> Dictionary:
	var result := {"finished": false, "gen_budget": gen_budget, "paint_budget": paint_budget}
	match job.phase:
		ChunkLoadJobScript.Phase.WAIT_TREE:
			if job.layer == null or not job.layer.is_inside_tree():
				return result
			job.phase = ChunkLoadJobScript.Phase.GENERATE
			job.cell_index = 0
			return result
		ChunkLoadJobScript.Phase.GENERATE:
			if gen_budget <= 0:
				return result
			var gen_used: int = _step_generate_job(job, deadline, gen_budget)
			result.gen_budget = gen_budget - gen_used
			if job.cell_index >= _cells_per_chunk:
				job.cell_index = 0
				job.paint_axis = _load_priority_axis
				job.cells_painted = 0
				job.layer_shown = false
				job.phase = ChunkLoadJobScript.Phase.PAINT
			return result
		ChunkLoadJobScript.Phase.PAINT:
			if paint_budget <= 0:
				return result
			var paint_used: int = _step_paint_job(job, deadline, paint_budget)
			result.paint_budget = paint_budget - paint_used
			if job.cell_index >= _cells_per_chunk:
				_finish_job(job)
				result.finished = true
			return result
		_:
			result.finished = true
			return result


func _step_generate_job(job: ChunkLoadJob, deadline: int, cell_cap: int) -> int:
	var t0: int = ChunkPerfProfileRes.begin(&"generate")
	var processed: int = 0

	if job.fill_land:
		while job.cell_index < _cells_per_chunk and processed < cell_cap:
			if Time.get_ticks_usec() >= deadline:
				break
			job.data.tiles[job.cell_index] = TT.LAND
			job.cell_index += 1
			processed += 1
		ChunkPerfProfileRes.end(&"generate", t0)
		return processed

	var ly_start: int = int(job.cell_index / float(_chunk_size))
	var lx_start: int = job.cell_index % _chunk_size

	for ly: int in range(ly_start, _chunk_size):
		var gx_row: int = job.origin.x
		var gy: int = job.origin.y + ly
		var row_base: int = ly * _chunk_size
		var lx_begin: int = lx_start if ly == ly_start else 0
		for lx: int in range(lx_begin, _chunk_size):
			if processed >= cell_cap or Time.get_ticks_usec() >= deadline:
				job.cell_index = row_base + lx
				ChunkPerfProfileRes.end(&"generate", t0)
				return processed
			var gx: int = gx_row + lx
			var idx: int = row_base + lx
			if job.skip_safe_zone:
				job.data.tiles[idx] = _terrain_noise_at_xy(gx, gy)
			elif gx >= _safe_zone_lo_x and gx <= _safe_zone_hi_x and gy >= _safe_zone_lo_y and gy <= _safe_zone_hi_y:
				job.data.tiles[idx] = TT.LAND
			else:
				job.data.tiles[idx] = _terrain_noise_at_xy(gx, gy)
			processed += 1

	job.cell_index = _cells_per_chunk
	ChunkPerfProfileRes.end(&"generate", t0)
	return processed


func _step_paint_job(job: ChunkLoadJob, deadline: int, cell_cap: int) -> int:
	var t0: int = ChunkPerfProfileRes.begin(&"paint_cells")
	var processed: int = 0
	var source_id: int = TerrainSandboxTileSetScript.SOURCE_ID
	var n: int = _chunk_size
	var axis: Vector2i = job.paint_axis
	var local: Vector2i = _paint_local_for_index(job, job.cell_index)

	while job.cell_index < _cells_per_chunk and processed < cell_cap:
		if Time.get_ticks_usec() >= deadline:
			break
		var idx: int = local.y * n + local.x
		var terrain: int = job.data.tiles[idx]
		if terrain >= 0 and terrain < _atlas_by_terrain.size():
			job.layer.set_cell(local, source_id, _atlas_by_terrain[terrain])
		else:
			job.layer.set_cell(local, source_id, _atlas_land)
		job.cell_index += 1
		job.cells_painted += 1
		processed += 1
		local = _advance_paint_local(local, axis, n)

	if processed > 0:
		_maybe_show_layer(job)

	ChunkPerfProfileRes.record_paint_cells(processed)
	ChunkPerfProfileRes.end(&"paint_cells", t0)
	return processed


func _advance_paint_local(local: Vector2i, axis: Vector2i, n: int) -> Vector2i:
	if axis.x > 0:
		var ly: int = local.y + 1
		if ly >= n:
			return Vector2i(local.x + 1, 0)
		return Vector2i(local.x, ly)
	if axis.x < 0:
		var ly_neg: int = local.y + 1
		if ly_neg >= n:
			return Vector2i(local.x - 1, 0)
		return Vector2i(local.x, ly_neg)
	if axis.y < 0:
		var lx_up: int = local.x + 1
		if lx_up >= n:
			return Vector2i(0, local.y - 1)
		return Vector2i(lx_up, local.y)
	var lx_down: int = local.x + 1
	if lx_down >= n:
		return Vector2i(0, local.y + 1)
	return Vector2i(lx_down, local.y)


## Movement-aware scan: leading row/column first, then fill outward (all cells, no hollow perimeter).
func _paint_local_for_index(job: ChunkLoadJob, index: int) -> Vector2i:
	var n: int = _chunk_size
	var last: int = n - 1
	var axis: Vector2i = job.paint_axis
	var row: int = floori(float(index) / float(n))
	if axis.x > 0:
		var ly: int = index % n
		return Vector2i(row, ly)
	if axis.x < 0:
		var ly_neg: int = index % n
		return Vector2i(last - row, ly_neg)
	if axis.y < 0:
		var lx_up: int = index % n
		return Vector2i(lx_up, last - row)
	var lx_down: int = index % n
	return Vector2i(lx_down, row)


func _maybe_show_layer(job: ChunkLoadJob) -> void:
	if job.layer_shown or job.layer == null:
		return
	if job.cells_painted < _chunk_show_min_paint_cells and job.cell_index < _cells_per_chunk:
		return
	var show_t0: int = ChunkPerfProfileRes.begin(&"layer_show")
	job.layer.visible = true
	job.layer_shown = true
	ChunkPerfProfileRes.end(&"layer_show", show_t0)


func _finish_job(job: ChunkLoadJob) -> void:
	_chunks[job.coord] = job.data
	_layers[job.coord] = job.layer
	_maybe_show_layer(job)
	if job.layer != null and not job.layer_shown:
		var show_t0: int = ChunkPerfProfileRes.begin(&"layer_show")
		job.layer.visible = true
		job.layer_shown = true
		ChunkPerfProfileRes.end(&"layer_show", show_t0)
	job.phase = ChunkLoadJobScript.Phase.DONE
	chunk_finished.emit(job.coord)


func _cancel_job(job: ChunkLoadJob) -> void:
	if job.layer != null:
		_release_layer(job.layer)


func _acquire_layer(chunk_coord: Vector2i) -> TileMapLayer:
	var t0: int = ChunkPerfProfileRes.begin(&"layer_acquire")
	var layer: TileMapLayer
	if not _layer_pool.is_empty():
		layer = _layer_pool.pop_back()
		layer.clear()
	else:
		layer = TileMapLayer.new()
	layer.name = "Chunk_%d_%d" % [chunk_coord.x, chunk_coord.y]
	layer.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	layer.tile_set = _tile_set
	_set_layer_chunk_origin(layer, chunk_coord)
	layer.visible = false
	if not layer.is_inside_tree():
		add_child(layer)
	ChunkPerfProfileRes.end(&"layer_acquire", t0)
	return layer


func _set_layer_chunk_origin(layer: TileMapLayer, chunk_coord: Vector2i) -> void:
	var origin_cells: Vector2i = chunk_coord * _chunk_size
	layer.position = Vector2(float(origin_cells.x), float(origin_cells.y)) * float(_tile_size)


func _release_layer(layer: TileMapLayer) -> void:
	if layer == null:
		return
	layer.visible = true
	layer.position = Vector2.ZERO
	layer.clear()
	if _layer_pool.size() < _pool_target_size:
		_layer_pool.append(layer)
	else:
		if layer.is_inside_tree():
			layer.queue_free()


func _unload_chunk(chunk_coord: Vector2i) -> void:
	if _layers.has(chunk_coord):
		var layer: TileMapLayer = _layers[chunk_coord]
		_layers.erase(chunk_coord)
		_release_layer(layer)
	_chunks.erase(chunk_coord)


func _chunk_fully_outside_safe_zone(chunk_coord: Vector2i) -> bool:
	var ox: int = chunk_coord.x * _chunk_size
	var oy: int = chunk_coord.y * _chunk_size
	var ex: int = ox + _chunk_size - 1
	var ey: int = oy + _chunk_size - 1
	var sz_lo_x: int = _spawn_safe_zone_x - _safe_zone_radius
	var sz_hi_x: int = _spawn_safe_zone_x + _safe_zone_radius
	var sz_lo_y: int = _spawn_safe_zone_y - _safe_zone_radius
	var sz_hi_y: int = _spawn_safe_zone_y + _safe_zone_radius
	return ex < sz_lo_x or ox > sz_hi_x or ey < sz_lo_y or oy > sz_hi_y


func _chunk_fully_inside_safe_zone(chunk_coord: Vector2i) -> bool:
	var ox: int = chunk_coord.x * _chunk_size
	var oy: int = chunk_coord.y * _chunk_size
	var ex: int = ox + _chunk_size - 1
	var ey: int = oy + _chunk_size - 1
	var sz_lo_x: int = _spawn_safe_zone_x - _safe_zone_radius
	var sz_hi_x: int = _spawn_safe_zone_x + _safe_zone_radius
	var sz_lo_y: int = _spawn_safe_zone_y - _safe_zone_radius
	var sz_hi_y: int = _spawn_safe_zone_y + _safe_zone_radius
	return ox >= sz_lo_x and ex <= sz_hi_x and oy >= sz_lo_y and ey <= sz_hi_y


func _terrain_noise_at_xy(gx: int, gy: int) -> int:
	var n01: float = (_noise.get_noise_2d(float(gx), float(gy)) + 1.0) * 0.5
	if n01 >= _water_threshold:
		return TT.WATER
	if n01 >= _mud_threshold:
		return TT.MUD
	return TT.LAND


func _terrain_at_xy(gx: int, gy: int) -> int:
	var dx: int = absi(gx - _spawn_safe_zone_x)
	var dy: int = absi(gy - _spawn_safe_zone_y)
	if maxi(dx, dy) <= _safe_zone_radius:
		return TT.LAND
	return _terrain_noise_at_xy(gx, gy)


func _terrain_at_grid_tile(grid_tile: Vector2i) -> int:
	return _terrain_at_xy(grid_tile.x, grid_tile.y)


## Canonical floor division; equivalent to int(floor(float(value) / float(divisor))).
static func _div_floor(value: int, divisor: int) -> int:
	if divisor == 0:
		return 0
	if value >= 0:
		return int(floori(float(value) / float(divisor)))
	return -int(ceili(-float(value) / float(divisor)))
