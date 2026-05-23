class_name TerrainMapSync
extends RefCounted

## Syncs Core GridModel cells into a TileMapLayer (batched atlas placement).

const TerrainSandboxTileSetScript = preload("res://src/Godot/Scripts/TerrainSandboxTileSet.gd")
const ObliqueBridge = preload("res://src/Godot/Scripts/ObliqueBridge.gd")

var _layer: TileMapLayer
var _written: Dictionary = {}


func setup(layer: TileMapLayer) -> void:
	_layer = layer
	_layer.tile_set = TerrainSandboxTileSetScript.build()
	_layer.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_layer.scale = Vector2.ONE


func clear_cell(gx: int, gy: int) -> void:
	if _layer == null:
		return
	var key: String = _cell_key(gx, gy)
	if not _written.has(key):
		return
	_layer.erase_cell(Vector2i(gx, gy))
	_written.erase(key)


func sync_region(
	grid,
	center_x: int,
	center_y: int,
	data_radius: int,
	visual_radius: int,
	reveal_context: FogRevealContext = null
) -> void:
	if _layer == null:
		return

	var land_cells: Array[Vector2i] = []
	var water_cells: Array[Vector2i] = []
	var mud_cells: Array[Vector2i] = []
	var neighbor_refresh: Dictionary = {}

	for gx in range(center_x - visual_radius, center_x + visual_radius + 1):
		for gy in range(center_y - visual_radius, center_y + visual_radius + 1):
			if not _can_paint_cell(reveal_context, gx, gy):
				continue
			var primary: int = grid.GetCellPrimary(gx, gy)
			var key: String = _cell_key(gx, gy)
			var needs_paint: bool = not _written.has(key) or int(_written[key]) != primary

			if needs_paint:
				_queue_cell(primary, gx, gy, land_cells, water_cells, mud_cells)
				_written[key] = primary
				_queue_neighbor_refresh(gx, gy, reveal_context, neighbor_refresh)

	for key in neighbor_refresh:
		var parts: PackedStringArray = key.split(",")
		var ngx: int = int(parts[0])
		var ngy: int = int(parts[1])
		if not _can_paint_cell(reveal_context, ngx, ngy):
			continue
		var n_primary: int = grid.GetCellPrimary(ngx, ngy)
		_queue_cell(n_primary, ngx, ngy, land_cells, water_cells, mud_cells)
		_written[key] = n_primary

	_flush_batches(land_cells, water_cells, mud_cells)


func sync_revealed_in_view(
	grid,
	reveal_context: FogRevealContext,
	center_x: int,
	center_y: int,
	visual_radius: int
) -> void:
	if _layer == null or reveal_context == null or not reveal_context.fog_enabled:
		return

	var land_cells: Array[Vector2i] = []
	var water_cells: Array[Vector2i] = []
	var mud_cells: Array[Vector2i] = []
	var neighbor_refresh: Dictionary = {}

	for gx in range(center_x - visual_radius, center_x + visual_radius + 1):
		for gy in range(center_y - visual_radius, center_y + visual_radius + 1):
			if not _can_paint_cell(reveal_context, gx, gy):
				continue
			var primary: int = grid.GetCellPrimary(gx, gy)
			var key: String = _cell_key(gx, gy)
			_queue_cell(primary, gx, gy, land_cells, water_cells, mud_cells)
			_written[key] = primary
			_queue_neighbor_refresh(gx, gy, reveal_context, neighbor_refresh)

	for key in neighbor_refresh:
		var parts: PackedStringArray = key.split(",")
		var ngx: int = int(parts[0])
		var ngy: int = int(parts[1])
		if not _can_paint_cell(reveal_context, ngx, ngy):
			continue
		var n_primary: int = grid.GetCellPrimary(ngx, ngy)
		_queue_cell(n_primary, ngx, ngy, land_cells, water_cells, mud_cells)
		_written[key] = n_primary

	_flush_batches(land_cells, water_cells, mud_cells)


func sync_annulus(
	grid,
	center_x: int,
	center_y: int,
	inner_radius: int,
	outer_radius: int,
	reveal_context: FogRevealContext = null
) -> void:
	if _layer == null or outer_radius <= inner_radius:
		return

	var land_cells: Array[Vector2i] = []
	var water_cells: Array[Vector2i] = []
	var mud_cells: Array[Vector2i] = []
	var neighbor_refresh: Dictionary = {}

	for gx in range(center_x - outer_radius, center_x + outer_radius + 1):
		for gy in range(center_y - outer_radius, center_y + outer_radius + 1):
			var dx: int = absi(gx - center_x)
			var dy: int = absi(gy - center_y)
			if maxi(dx, dy) <= inner_radius:
				continue
			if not _can_paint_cell(reveal_context, gx, gy):
				continue

			var primary: int = grid.GetCellPrimary(gx, gy)
			var key: String = _cell_key(gx, gy)
			var needs_paint: bool = not _written.has(key) or int(_written[key]) != primary
			if not needs_paint:
				continue

			_queue_cell(primary, gx, gy, land_cells, water_cells, mud_cells)
			_written[key] = primary
			_queue_neighbor_refresh(gx, gy, reveal_context, neighbor_refresh)

	for key in neighbor_refresh:
		var parts: PackedStringArray = key.split(",")
		var ngx: int = int(parts[0])
		var ngy: int = int(parts[1])
		if not _can_paint_cell(reveal_context, ngx, ngy):
			continue
		var n_primary: int = grid.GetCellPrimary(ngx, ngy)
		_queue_cell(n_primary, ngx, ngy, land_cells, water_cells, mud_cells)
		_written[key] = n_primary

	_flush_batches(land_cells, water_cells, mud_cells)


func _can_paint_cell(reveal_context: FogRevealContext, gx: int, gy: int) -> bool:
	if reveal_context == null or not reveal_context.fog_enabled:
		return true
	return true


func _flush_batches(
	land_cells: Array[Vector2i],
	water_cells: Array[Vector2i],
	mud_cells: Array[Vector2i]
) -> void:
	_paint_batch(land_cells, ObliqueBridge.TERRAIN_LAND)
	_paint_batch(water_cells, ObliqueBridge.TERRAIN_WATER)
	_paint_batch(mud_cells, ObliqueBridge.TERRAIN_MUD)
	if _layer != null:
		_layer.update_internals()


func _paint_batch(cells: Array[Vector2i], terrain: int) -> void:
	if cells.is_empty():
		return
	var atlas: Vector2i = TerrainSandboxTileSetScript.atlas_for_terrain(terrain)
	for coords in cells:
		_layer.set_cell(coords, TerrainSandboxTileSetScript.SOURCE_ID, atlas)


func _queue_cell(
	primary: int,
	gx: int,
	gy: int,
	land_cells: Array[Vector2i],
	water_cells: Array[Vector2i],
	mud_cells: Array[Vector2i]
) -> void:
	var coords := Vector2i(gx, gy)
	match primary:
		ObliqueBridge.TERRAIN_WATER:
			water_cells.append(coords)
		ObliqueBridge.TERRAIN_MUD:
			mud_cells.append(coords)
		_:
			land_cells.append(coords)


func _queue_neighbor_refresh(
	gx: int,
	gy: int,
	reveal_context: FogRevealContext,
	neighbor_refresh: Dictionary
) -> void:
	var offsets: Array[Vector2i] = [
		Vector2i(0, -1), Vector2i(0, 1), Vector2i(1, 0), Vector2i(-1, 0)
	]
	for offset in offsets:
		var ngx: int = gx + offset.x
		var ngy: int = gy + offset.y
		var key: String = _cell_key(ngx, ngy)
		if not _written.has(key):
			continue
		if not _can_paint_cell(reveal_context, ngx, ngy):
			continue
		neighbor_refresh[key] = true


static func _cell_key(gx: int, gy: int) -> String:
	return str(gx) + "," + str(gy)
