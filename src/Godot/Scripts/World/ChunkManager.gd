extends Node2D

## Streams terrain chunks in a window around the player grid position.
##
## Prefetch ring (viewport-aware) queues chunk jobs; prefetch ring controls unloads after bootstrap.
## Multiple ChunkLoadJobs share a per-frame cell + time budget via round-robin _process.
## TileMapLayer nodes are pooled to avoid alloc/free hitches on chunk boundaries.

const NO_CHUNK: Vector2i = Vector2i(999999, 999999)

const ChunkDataScript = preload("res://src/Godot/Scripts/World/ChunkData.gd")
const ChunkLoadJobScript = preload("res://src/Godot/Scripts/World/ChunkLoadJob.gd")
const TT = preload("res://src/Godot/Scripts/World/TerrainType.gd")
const ViewMetricsScript = preload("res://src/Godot/Scripts/ViewMetrics.gd")
const TerrainSandboxTileSetScript = preload("res://src/Godot/Scripts/TerrainSandboxTileSet.gd")
enum BootstrapPhase {NONE, KEEP, PREFETCH, DONE}

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
var _load_radius: int = 2
var _load_radius_buffer: int = 1
var _load_radius_view_padding: int = 2

var _noise: FastNoiseLite
var _tile_set: TileSet
var _chunks: Dictionary = {}
var _layers: Dictionary = {}
var _last_center_chunk: Vector2i = NO_CHUNK
var _tile_size: int = ViewMetricsScript.CELL_SIZE_PX

var _atlas_land: Vector2i
var _atlas_water: Vector2i
var _atlas_mud: Vector2i

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
const VIEW_REFRESH_BURST_CELL_MULT: int = 2

var _view_refresh_burst_remaining: int = 0
var _burst_max_active_jobs: int = 0
var _burst_layer_acquires_per_frame: int = 0
var _burst_cells_per_frame: int = 0
var _burst_cells_paint_per_frame: int = 0


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
	_load_radius = Settings.get_int("world.load_radius")
	_load_radius_buffer = Settings.get_int("world.load_radius_buffer")
	if Settings.has("world.load_radius_view_padding"):
		_load_radius_view_padding = maxi(Settings.get_int("world.load_radius_view_padding"), 0)
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


func _process(_delta: float) -> void:
	_layer_acquires_this_frame = 0
	_try_start_jobs()
	_step_active_jobs()
	_advance_bootstrap_phase()
	if _view_refresh_burst_remaining > 0:
		_view_refresh_burst_remaining -= 1
	else:
		_step_unload_budget()


func force_viewport_chunk_refresh() -> void:
	_build_chunk_offsets()
	_cancel_unloads_in_wanted(_prefetch_wanted)
	_purge_unload_queue_for_wanted(_prefetch_wanted)
	_begin_view_refresh_burst()
	if _last_center_chunk != NO_CHUNK:
		_refresh_active_chunks(_last_center_chunk)


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
	_burst_cells_per_frame = _cells_per_frame * VIEW_REFRESH_BURST_CELL_MULT
	_burst_cells_paint_per_frame = _cells_paint_per_frame * VIEW_REFRESH_BURST_CELL_MULT


func sync_center_from_player_map_px(map_px: Vector2) -> void:
	update_center_grid(world_px_to_grid_tile(map_px))


func update_center_grid(grid_tile: Vector2i) -> void:
	var center_chunk := grid_to_chunk_coord(grid_tile)
	if center_chunk == _last_center_chunk:
		return
	_last_center_chunk = center_chunk
	_refresh_active_chunks(center_chunk)


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


func _refresh_active_chunks(center: Vector2i) -> void:
	if _layers.is_empty():
		_bootstrap_phase = BootstrapPhase.KEEP

	_keep_wanted.clear()
	for offset: Vector2i in _keep_offsets:
		_keep_wanted[center + offset] = true

	_prefetch_wanted.clear()
	for offset: Vector2i in _prefetch_offsets:
		_prefetch_wanted[center + offset] = true

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
				_enqueue_load(coord, center)
		BootstrapPhase.PREFETCH:
			_enqueue_prefetch_ring(center)
		_:
			for offset: Vector2i in _prefetch_offsets:
				var coord: Vector2i = center + offset
				if _layers.has(coord) or _is_chunk_pending(coord):
					continue
				_enqueue_load(coord, center)


func _enqueue_prefetch_ring(center: Vector2i) -> void:
	for offset: Vector2i in _prefetch_offsets:
		var coord: Vector2i = center + offset
		if _layers.has(coord) or _is_chunk_pending(coord):
			continue
		_enqueue_load(coord, center)


func _enqueue_load(coord: Vector2i, center: Vector2i) -> void:
	if _pending_loads.has(coord):
		return
	var priority: int = 0 if coord == center and _bootstrap_phase == BootstrapPhase.KEEP else absi(coord.x - center.x) + absi(coord.y - center.y)
	var insert_at: int = _pending_coords.size()
	for i: int in range(_pending_coords.size()):
		var existing: Vector2i = _pending_coords[i]
		var existing_priority: int = absi(existing.x - center.x) + absi(existing.y - center.y)
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
	if _view_refresh_burst_remaining > 0:
		return maxi(_burst_cells_per_frame, 1)
	if _bootstrap_phase == BootstrapPhase.KEEP:
		return maxi(_bootstrap_cells_per_frame, 1)
	return maxi(_cells_per_frame, 1)


func _effective_paint_budget() -> int:
	if _view_refresh_burst_remaining > 0:
		return maxi(_burst_cells_paint_per_frame, 1)
	if _bootstrap_phase == BootstrapPhase.KEEP:
		return maxi(_bootstrap_cells_paint_per_frame, 1)
	return maxi(_cells_paint_per_frame, 1)


func _effective_frame_budget_usec() -> int:
	if _bootstrap_phase == BootstrapPhase.KEEP:
		return _bootstrap_chunk_frame_budget_usec
	return _chunk_frame_budget_usec


func _effective_max_active_jobs() -> int:
	if _view_refresh_burst_remaining > 0:
		return maxi(_burst_max_active_jobs, 1)
	if _bootstrap_phase == BootstrapPhase.KEEP:
		return _bootstrap_max_active_jobs
	return _max_active_jobs


func _effective_layer_acquires_per_frame() -> int:
	if _view_refresh_burst_remaining > 0:
		return maxi(_burst_layer_acquires_per_frame, 1)
	if _bootstrap_phase == BootstrapPhase.KEEP:
		return _bootstrap_layer_acquires_per_frame
	return _layer_acquires_per_frame


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
	var job_index: int = 0

	while job_index < _active_jobs.size():
		if Time.get_ticks_usec() >= deadline:
			break
		if gen_budget <= 0 and paint_budget <= 0:
			break

		var job: ChunkLoadJob = _active_jobs[job_index]
		var step := _step_job(job, deadline, gen_budget, paint_budget)
		gen_budget = step.gen_budget
		paint_budget = step.paint_budget
		if step.finished:
			_active_jobs.remove_at(job_index)
			continue
		job_index += 1


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
	var processed: int = 0

	if job.fill_land:
		while job.cell_index < _cells_per_chunk and processed < cell_cap:
			if Time.get_ticks_usec() >= deadline:
				break
			job.data.tiles[job.cell_index] = TT.LAND
			job.cell_index += 1
			processed += 1
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
				return processed
			var gx: int = gx_row + lx
			var idx: int = row_base + lx
			if job.skip_safe_zone:
				job.data.tiles[idx] = _terrain_noise_at_xy(gx, gy)
			else:
				job.data.tiles[idx] = _terrain_at_xy(gx, gy)
			processed += 1

	job.cell_index = _cells_per_chunk
	return processed


func _step_paint_job(job: ChunkLoadJob, deadline: int, cell_cap: int) -> int:
	var processed: int = 0
	var source_id: int = TerrainSandboxTileSetScript.SOURCE_ID

	var ly_start: int = int(job.cell_index / float(_chunk_size))
	var lx_start: int = job.cell_index % _chunk_size

	for ly: int in range(ly_start, _chunk_size):
		var row_base: int = ly * _chunk_size
		var lx_begin: int = lx_start if ly == ly_start else 0
		for lx: int in range(lx_begin, _chunk_size):
			if processed >= cell_cap or Time.get_ticks_usec() >= deadline:
				job.cell_index = row_base + lx
				return processed
			var idx: int = row_base + lx
			var terrain: int = job.data.tiles[idx]
			job.layer.set_cell(Vector2i(lx, ly), source_id, _atlas_for_terrain(terrain))
			processed += 1

	job.cell_index = _cells_per_chunk
	return processed


func _finish_job(job: ChunkLoadJob) -> void:
	_chunks[job.coord] = job.data
	_layers[job.coord] = job.layer
	job.phase = ChunkLoadJobScript.Phase.DONE


func _cancel_job(job: ChunkLoadJob) -> void:
	if job.layer != null:
		_release_layer(job.layer)


func _acquire_layer(chunk_coord: Vector2i) -> TileMapLayer:
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
	if not layer.is_inside_tree():
		add_child(layer)
	return layer


func _set_layer_chunk_origin(layer: TileMapLayer, chunk_coord: Vector2i) -> void:
	var origin_cells: Vector2i = chunk_coord * _chunk_size
	layer.position = Vector2(float(origin_cells.x), float(origin_cells.y)) * float(_tile_size)


func _release_layer(layer: TileMapLayer) -> void:
	if layer == null:
		return
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


func _atlas_for_terrain(terrain: int) -> Vector2i:
	match terrain:
		TT.WATER:
			return _atlas_water
		TT.MUD:
			return _atlas_mud
		_:
			return _atlas_land


## Canonical floor division; equivalent to int(floor(float(value) / float(divisor))).
static func _div_floor(value: int, divisor: int) -> int:
	if divisor == 0:
		return 0
	if value >= 0:
		return int(floori(float(value) / float(divisor)))
	return -int(ceili(-float(value) / float(divisor)))
