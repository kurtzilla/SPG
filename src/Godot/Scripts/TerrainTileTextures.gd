class_name TerrainTileTextures
extends RefCounted

## Solid terrain tiles for grid rendering.

const ViewMetrics = preload("res://src/Godot/Scripts/ViewMetrics.gd")

const SOLID_LAND_COLOR: Color = Color(0.35, 0.45, 0.32)
const SOLID_WATER_COLOR: Color = Color(0.22, 0.38, 0.55)
const SOLID_MUD_COLOR: Color = Color(0.45, 0.32, 0.22)


static func create_solid_land_texture() -> ImageTexture:
	return _create_solid_fill_texture(SOLID_LAND_COLOR)


static func create_solid_water_texture() -> ImageTexture:
	return _create_solid_fill_texture(SOLID_WATER_COLOR)


static func create_solid_mud_texture() -> ImageTexture:
	return _create_solid_fill_texture(SOLID_MUD_COLOR)


static func _create_solid_fill_texture(fill: Color) -> ImageTexture:
	var size: int = ViewMetrics.CELL_SIZE_PX
	var image: Image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(fill)
	return _image_to_texture(image)


static func _image_to_texture(image: Image) -> ImageTexture:
	return ImageTexture.create_from_image(image)
