class_name TerrainTileTextures
extends RefCounted

## Solid terrain tiles, transition overlays, and noise masks for grid rendering.

const ViewMetrics = preload("res://src/Godot/Scripts/ViewMetrics.gd")

const SOLID_LAND_COLOR: Color = Color(0.35, 0.45, 0.32)
const SOLID_WATER_COLOR: Color = Color(0.22, 0.38, 0.55)
const SOLID_MUD_COLOR: Color = Color(0.45, 0.32, 0.22)
const TRANSITION_BLEED: float = 0.4


static func create_solid_land_texture() -> ImageTexture:
	return _create_solid_fill_texture(SOLID_LAND_COLOR)


static func create_solid_water_texture() -> ImageTexture:
	return _create_solid_fill_texture(SOLID_WATER_COLOR)


static func create_solid_mud_texture() -> ImageTexture:
	return _create_solid_fill_texture(SOLID_MUD_COLOR)


static func create_directional_transition_texture(
	transition_color: Color,
	neighbor_flags: Vector4,
	noise_mask: Texture2D
) -> ImageTexture:
	var size: int = ViewMetrics.CELL_SIZE_PX
	var noise_image: Image = noise_mask.get_image()
	var image: Image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	var bleed: float = TRANSITION_BLEED

	for y in range(size):
		for x in range(size):
			var uv_x: float = (float(x) + 0.5) / float(size)
			var uv_y: float = (float(y) + 0.5) / float(size)
			var alpha: float = 0.0

			if neighbor_flags.x > 0.0:
				alpha = maxf(alpha, 1.0 - _smoothstep(0.0, bleed, uv_y))
			if neighbor_flags.y > 0.0:
				alpha = maxf(alpha, _smoothstep(1.0 - bleed, 1.0, uv_y))
			if neighbor_flags.z > 0.0:
				alpha = maxf(alpha, _smoothstep(1.0 - bleed, 1.0, uv_x))
			if neighbor_flags.w > 0.0:
				alpha = maxf(alpha, 1.0 - _smoothstep(0.0, bleed, uv_x))

			var noise_sample: float = noise_image.get_pixel(x, y).r
			alpha *= noise_sample
			image.set_pixel(x, y, Color(transition_color.r, transition_color.g, transition_color.b, alpha))

	return _image_to_texture(image)


static func create_seamless_noise_mask_texture() -> ImageTexture:
	var size: int = ViewMetrics.CELL_SIZE_PX
	var noise: FastNoiseLite = FastNoiseLite.new()
	noise.seed = 1337
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.04
	var image: Image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in range(size):
		for x in range(size):
			var n: float = (noise.get_noise_2d(float(x), float(y)) + 1.0) * 0.5
			image.set_pixel(x, y, Color(n, n, n, 1.0))
	return _image_to_texture(image)


static func _create_solid_fill_texture(fill: Color) -> ImageTexture:
	var size: int = ViewMetrics.CELL_SIZE_PX
	var image: Image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(fill)
	return _image_to_texture(image)


static func _smoothstep(edge0: float, edge1: float, x: float) -> float:
	var t: float = clampf((x - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


static func _image_to_texture(image: Image) -> ImageTexture:
	return ImageTexture.create_from_image(image)
