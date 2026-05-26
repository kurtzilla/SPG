extends Node2D



## Streams terrain chunks in a window around the player grid position.

##

## Loads are queued and painted over multiple frames (cells_per_frame) to avoid

## chunk-boundary hitches. Movement / scroll stay on the main thread.



const NO_CHUNK: Vector2i = Vector2i(999999, 999999)



const ChunkDataScript = preload("res://src/Godot/Scripts/World/ChunkData.gd")

const TT = preload("res://src/Godot/Scripts/World/TerrainType.gd")

const ViewMetricsScript = preload("res://src/Godot/Scripts/ViewMetrics.gd")

const TerrainSandboxTileSetScript = preload("res://src/Godot/Scripts/TerrainSandboxTileSet.gd")



var _chunk_size: int = 32

var _cells_per_chunk: int = 1024

var _chunk_offsets: Array[Vector2i] = []



var _noise_seed: int = 42

var _noise_frequency: float = 0.04

var _water_threshold: float = 0.62

var _mud_threshold: float = 0.45

var _cells_per_frame: int = 256

var _spawn_safe_zone_x: int = 0

var _spawn_safe_zone_y: int = 0

var _safe_zone_radius: int = 2



var _noise: FastNoiseLite

var _tile_set: TileSet

var _chunks: Dictionary = {}

var _layers: Dictionary = {}

var _last_center_chunk: Vector2i = NO_CHUNK

var _tile_size: int = ViewMetricsScript.CELL_SIZE_PX



var _atlas_land: Vector2i

var _atlas_water: Vector2i

var _atlas_mud: Vector2i



var _load_queue: Array[Vector2i] = []

var _painting_coord: Vector2i = NO_CHUNK

var _painting_layer: TileMapLayer

var _painting_data

var _painting_origin: Vector2i

var _painting_cell_index: int = 0





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





func _read_world_settings() -> void:

	_chunk_size = Settings.get_int("world.chunk_size")

	_cells_per_chunk = _chunk_size * _chunk_size

	_noise_seed = Settings.get_int("world.noise_seed")

	_noise_frequency = Settings.get_float("world.noise_frequency")

	_water_threshold = Settings.get_float("world.water_threshold")

	_mud_threshold = Settings.get_float("world.mud_threshold")

	_cells_per_frame = Settings.get_int("world.cells_per_frame")

	_spawn_safe_zone_x = Settings.get_int("world.spawn_safe_zone_x")

	_spawn_safe_zone_y = Settings.get_int("world.spawn_safe_zone_y")

	_safe_zone_radius = Settings.get_int("world.safe_zone_radius")





func _build_chunk_offsets() -> void:

	_chunk_offsets.clear()

	var radius: int = Settings.get_int("world.load_radius")

	for dy: int in range(-radius, radius + 1):

		for dx: int in range(-radius, radius + 1):

			_chunk_offsets.append(Vector2i(dx, dy))





func _process(_delta: float) -> void:

	if _painting_coord != NO_CHUNK:

		_step_chunk_load()

		return

	if not _load_queue.is_empty():

		_begin_chunk_load(_load_queue.pop_front())





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

		var data = _chunks[chunk_coord]

		return data.get_tile_index(local.y * _chunk_size + local.x)

	return _terrain_at_grid_tile(grid_tile)





func get_tile_type_at_global_pos(pos: Vector2) -> int:

	return get_tile_type_at_grid(world_px_to_grid_tile(pos))





func grid_to_chunk_coord(grid_tile: Vector2i) -> Vector2i:

	return Vector2i(

		_div_floor(grid_tile.x, _chunk_size),

		_div_floor(grid_tile.y, _chunk_size)

	)





func world_px_to_grid_tile(pos: Vector2) -> Vector2i:

	return Vector2i(

		_div_floor(int(pos.x), _tile_size),

		_div_floor(int(pos.y), _tile_size)

	)





func _refresh_active_chunks(center: Vector2i) -> void:

	var wanted: Dictionary = {}

	for offset: Vector2i in _chunk_offsets:

		wanted[center + offset] = true



	_cancel_loads_not_in_wanted(wanted)



	for chunk_coord in _layers.keys():

		if not wanted.has(chunk_coord):

			_unload_chunk(chunk_coord)



	for offset: Vector2i in _chunk_offsets:

		var coord: Vector2i = center + offset

		if _layers.has(coord) or _is_chunk_pending(coord):

			continue

		_load_queue.append(coord)





func _is_chunk_pending(coord: Vector2i) -> bool:

	if coord == _painting_coord:

		return true

	return _load_queue.has(coord)





func _cancel_loads_not_in_wanted(wanted: Dictionary) -> void:

	if _painting_coord != NO_CHUNK and not wanted.has(_painting_coord):

		_cancel_active_load()



	var i: int = 0

	while i < _load_queue.size():

		if not wanted.has(_load_queue[i]):

			_load_queue.remove_at(i)

		else:

			i += 1





func _begin_chunk_load(chunk_coord: Vector2i) -> void:

	if _layers.has(chunk_coord):

		return



	var layer := TileMapLayer.new()

	layer.name = "Chunk_%d_%d" % [chunk_coord.x, chunk_coord.y]

	layer.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	layer.tile_set = _tile_set

	add_child(layer)



	_painting_coord = chunk_coord

	_painting_layer = layer

	_painting_data = ChunkDataScript.new(chunk_coord)

	_painting_origin = chunk_coord * _chunk_size

	_painting_cell_index = 0





func _step_chunk_load() -> void:

	var budget: int = maxi(_cells_per_frame, 1)

	var source_id: int = TerrainSandboxTileSetScript.SOURCE_ID

	var end_index: int = mini(_painting_cell_index + budget, _cells_per_chunk)



	while _painting_cell_index < end_index:

		var idx: int = _painting_cell_index

		var lx: int = idx % _chunk_size

		var ly: int = int(idx / float(_chunk_size))

		var grid_tile: Vector2i = _painting_origin + Vector2i(lx, ly)

		var terrain: int = _terrain_at_grid_tile(grid_tile)

		_painting_data.tiles[idx] = terrain

		_painting_layer.set_cell(grid_tile, source_id, _atlas_for_terrain(terrain))

		_painting_cell_index += 1



	if _painting_cell_index >= _cells_per_chunk:

		_finish_active_load()





func _finish_active_load() -> void:

	_chunks[_painting_coord] = _painting_data

	_layers[_painting_coord] = _painting_layer

	_painting_coord = NO_CHUNK

	_painting_layer = null

	_painting_data = null

	_painting_cell_index = 0





func _cancel_active_load() -> void:

	if _painting_layer != null:

		_painting_layer.queue_free()

	_painting_coord = NO_CHUNK

	_painting_layer = null

	_painting_data = null

	_painting_cell_index = 0





func _unload_chunk(chunk_coord: Vector2i) -> void:

	if _layers.has(chunk_coord):

		var layer: TileMapLayer = _layers[chunk_coord]

		layer.queue_free()

		_layers.erase(chunk_coord)

	_chunks.erase(chunk_coord)





func _terrain_at_grid_tile(grid_tile: Vector2i) -> int:

	var dx: int = absi(grid_tile.x - _spawn_safe_zone_x)

	var dy: int = absi(grid_tile.y - _spawn_safe_zone_y)

	if maxi(dx, dy) <= _safe_zone_radius:

		return TT.LAND



	var n01: float = (_noise.get_noise_2d(float(grid_tile.x), float(grid_tile.y)) + 1.0) * 0.5

	if n01 >= _water_threshold:

		return TT.WATER

	if n01 >= _mud_threshold:

		return TT.MUD

	return TT.LAND





func _atlas_for_terrain(terrain: int) -> Vector2i:

	match terrain:

		TT.WATER:

			return _atlas_water

		TT.MUD:

			return _atlas_mud

		_:

			return _atlas_land





static func _div_floor(value: int, divisor: int) -> int:

	if divisor == 0:

		return 0

	if value >= 0:

		return int(floori(float(value) / float(divisor)))

	return -int(ceili(-float(value) / float(divisor)))

