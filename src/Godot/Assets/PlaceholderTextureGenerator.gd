extends RefCounted

## Procedural placeholder textures sized via ViewMetrics constants.
## Ground tile: CELL_SIZE_PX (2m x 2m). Billboard: 1m wide x 2m tall.

const ViewMetrics = preload("res://src/Godot/Scripts/ViewMetrics.gd")

static func create_ground_tile_texture() -> ImageTexture:
	var size: int = ViewMetrics.CELL_SIZE_PX
	var fill: Color = Color(0.35, 0.45, 0.32)
	var border: Color = Color(0.18, 0.24, 0.16)
	var image: Image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(fill)
	_draw_border(image, border)
	return _image_to_texture(image)


static func create_blocked_tile_texture() -> ImageTexture:
	var size: int = ViewMetrics.CELL_SIZE_PX
	var fill: Color = Color(0.42, 0.42, 0.48)
	var border: Color = Color(0.22, 0.22, 0.28)
	var image: Image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(fill)
	_draw_border(image, border)
	return _image_to_texture(image)


static func create_water_tile_texture() -> ImageTexture:
	var size: int = ViewMetrics.CELL_SIZE_PX
	var fill: Color = Color(0.22, 0.38, 0.55)
	var border: Color = Color(0.12, 0.22, 0.35)
	var image: Image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(fill)
	_draw_border(image, border)
	return _image_to_texture(image)


static func create_mud_tile_texture() -> ImageTexture:
	var size: int = ViewMetrics.CELL_SIZE_PX
	var fill: Color = Color(0.45, 0.32, 0.22)
	var border: Color = Color(0.28, 0.18, 0.12)
	var image: Image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(fill)
	_draw_border(image, border)
	return _image_to_texture(image)


static func create_splat_land_pattern_texture() -> ImageTexture:
	var size: int = ViewMetrics.CELL_SIZE_PX
	var fill: Color = Color(0.35, 0.45, 0.32)
	var accent: Color = Color(0.28, 0.38, 0.26)
	var border: Color = Color(0.18, 0.24, 0.16)
	var image: Image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(fill)
	_draw_checker_pattern(image, accent, 8)
	_draw_border(image, border)
	return _image_to_texture(image)


static func create_splat_water_pattern_texture() -> ImageTexture:
	var size: int = ViewMetrics.CELL_SIZE_PX
	var fill: Color = Color(0.22, 0.38, 0.55)
	var accent: Color = Color(0.18, 0.32, 0.48)
	var border: Color = Color(0.12, 0.22, 0.35)
	var image: Image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(fill)
	_draw_checker_pattern(image, accent, 8)
	_draw_border(image, border)
	return _image_to_texture(image)


static func create_character_billboard_texture() -> ImageTexture:
	var width: int = ViewMetrics.PIXELS_PER_METER
	var height: int = ViewMetrics.CELL_SIZE_PX
	var fill: Color = Color(0.85, 0.35, 0.2)
	var border: Color = Color(0.55, 0.2, 0.1)
	var image: Image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	image.fill(fill)
	_draw_border(image, border)
	return _image_to_texture(image)


static func _draw_checker_pattern(image: Image, accent_color: Color, cell: int) -> void:
	var w: int = image.get_width()
	var h: int = image.get_height()
	for y in range(h):
		for x in range(w):
			if (int(x / float(cell)) + int(y / float(cell))) % 2 == 0:
				image.set_pixel(x, y, accent_color)


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
