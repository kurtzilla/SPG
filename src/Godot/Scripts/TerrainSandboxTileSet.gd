class_name TerrainSandboxTileSet
extends RefCounted

## Builds the sandbox TileSet (land / water / mud solids) at runtime.

const ViewMetrics = preload("res://src/Godot/Scripts/ViewMetrics.gd")
const TerrainTileTextures = preload("res://src/Godot/Scripts/TerrainTileTextures.gd")
const ObliqueBridge = preload("res://src/Godot/Scripts/ObliqueBridge.gd")

const SOURCE_ID: int = 0
const TERRAIN_SET: int = 0

const ATLAS_LAND: Vector2i = Vector2i(0, 0)
const ATLAS_WATER: Vector2i = Vector2i(1, 0)
const ATLAS_MUD: Vector2i = Vector2i(2, 0)

## Godot 4.3 TileSet.CellNeighbor peering slots (0..15); no TERRAIN_PEERING_BITS_COUNT.
const PEERING_BIT_COUNT: int = 16


static func atlas_for_terrain(terrain: int) -> Vector2i:
	match terrain:
		ObliqueBridge.TERRAIN_WATER:
			return ATLAS_WATER
		ObliqueBridge.TERRAIN_MUD:
			return ATLAS_MUD
		_:
			return ATLAS_LAND


static func build() -> TileSet:
	var tile_size: int = ViewMetrics.CELL_SIZE_PX
	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i(tile_size, tile_size)

	var atlas := TileSetAtlasSource.new()
	atlas.texture_region_size = Vector2i(tile_size, tile_size)
	atlas.texture = _build_atlas_texture(tile_size)

	var _source_id: int = tile_set.add_source(atlas, SOURCE_ID)
	for atlas_coords in [ATLAS_LAND, ATLAS_WATER, ATLAS_MUD]:
		atlas.create_tile(atlas_coords)

	tile_set.add_terrain_set()
	# add_terrain() returns void; terrain ids are 0..n in add order (matches Core ordinals).
	tile_set.add_terrain(TERRAIN_SET)
	tile_set.add_terrain(TERRAIN_SET)
	tile_set.add_terrain(TERRAIN_SET)

	_configure_terrain_tile(atlas, ATLAS_LAND, ObliqueBridge.TERRAIN_LAND)
	_configure_terrain_tile(atlas, ATLAS_WATER, ObliqueBridge.TERRAIN_WATER)
	_configure_terrain_tile(atlas, ATLAS_MUD, ObliqueBridge.TERRAIN_MUD)

	return tile_set


static func _build_atlas_texture(tile_size: int) -> Texture2D:
	var land: Image = TerrainTileTextures.create_solid_land_texture().get_image()
	var water: Image = TerrainTileTextures.create_solid_water_texture().get_image()
	var mud: Image = TerrainTileTextures.create_solid_mud_texture().get_image()

	var atlas_image := Image.create(tile_size * 3, tile_size, false, Image.FORMAT_RGBA8)
	atlas_image.blit_rect(land, Rect2i(0, 0, tile_size, tile_size), Vector2i(0, 0))
	atlas_image.blit_rect(water, Rect2i(0, 0, tile_size, tile_size), Vector2i(tile_size, 0))
	atlas_image.blit_rect(mud, Rect2i(0, 0, tile_size, tile_size), Vector2i(tile_size * 2, 0))
	return ImageTexture.create_from_image(atlas_image)


static func _configure_terrain_tile(
	atlas: TileSetAtlasSource,
	atlas_coords: Vector2i,
	terrain_id: int
) -> void:
	var tile_data: TileData = atlas.get_tile_data(atlas_coords, 0)
	tile_data.set_terrain_set(TERRAIN_SET)
	tile_data.set_terrain(terrain_id)
	for bit in range(PEERING_BIT_COUNT):
		if tile_data.is_valid_terrain_peering_bit(bit):
			tile_data.set_terrain_peering_bit(bit, terrain_id)
