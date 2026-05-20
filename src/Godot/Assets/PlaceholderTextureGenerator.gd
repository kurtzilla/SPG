extends RefCounted

## Procedural placeholder textures sized via ObliqueBridge metric constants.
## Ground tile: CELL_SIZE_PX (2m x 2m). Billboard: 1m wide x 2m tall.

const ObliqueBridge = preload("res://src/Godot/Scripts/ObliqueBridge.gd")


static func create_ground_tile_texture() -> ImageTexture:
	var size: int = ObliqueBridge.CELL_SIZE_PX
	var fill: Color = Color(0.35, 0.45, 0.32)
	var border: Color = Color(0.18, 0.24, 0.16)
	var image: Image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(fill)
	_draw_border(image, border)
	return _image_to_texture(image)


static func create_character_billboard_texture() -> ImageTexture:
	var width: int = ObliqueBridge.PIXELS_PER_METER
	var height: int = ObliqueBridge.CELL_SIZE_PX
	var fill: Color = Color(0.85, 0.35, 0.2)
	var border: Color = Color(0.55, 0.2, 0.1)
	var image: Image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	image.fill(fill)
	_draw_border(image, border)
	return _image_to_texture(image)


static func _draw_border(image: Image, border_color: Color) -> void:
	var w: int = image.get_width()
	var h: int = image.get_height()
	for x in range(w):
		image.set_pixel(x, 0, border_color)
		image.set_pixel(x, h - 1, border_color)
	for y in range(h):
		image.set_pixel(0, y, border_color)
		image.set_pixel(w - 1, y, border_color)


static func _image_to_texture(image: Image) -> ImageTexture:
	var texture: ImageTexture = ImageTexture.create_from_image(image)
	return texture
