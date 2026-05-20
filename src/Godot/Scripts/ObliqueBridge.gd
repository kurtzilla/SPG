extends RefCounted

## Canonical view-layer metric adapter for oblique / cabinet projection.
## Rule: PIXELS_PER_METER screen pixels = exactly 1.0 world meter.
## One logical grid cell (Core x/y step) = METERS_PER_CELL meters (2m x 2m) = CELL_SIZE_PX pixels.

const PIXELS_PER_METER: int = 32
const METERS_PER_CELL: float = 2.0
const CELL_SIZE_PX: int = PIXELS_PER_METER * int(METERS_PER_CELL)
const HEIGHT_OFFSET_PX: int = PIXELS_PER_METER


static func meters_to_pixels(meters: float) -> float:
	return meters * float(PIXELS_PER_METER)


static func pixels_to_meters(pixels: float) -> float:
	return pixels / float(PIXELS_PER_METER)


static func grid_to_meters(x: int, y: int) -> Vector2:
	return Vector2(
		float(x) * METERS_PER_CELL,
		float(y) * METERS_PER_CELL
	)


## Flat orthographic grid-to-screen offset (no viewport center). One Core cell = CELL_SIZE_PX.
static func data_to_screen(x: int, y: int) -> Vector2:
	# Future: subtract Z height from .y (e.g. via HEIGHT_OFFSET_PX per meter of elevation).
	return Vector2(x * CELL_SIZE_PX, y * CELL_SIZE_PX)


static func grid_to_screen(x: int, y: int, z: int = 0) -> Vector2:
	var meters: Vector2 = grid_to_meters(x, y)
	return Vector2(
		meters_to_pixels(meters.x),
		meters_to_pixels(meters.y) - meters_to_pixels(float(z))
	)


static func grid_to_screen_centered(
	x: int,
	y: int,
	viewport_center: Vector2,
	z: int = 0
) -> Vector2:
	return viewport_center + grid_to_screen(x, y, z)


static func speed_meters_per_second_to_pixels(meters_per_second: float) -> float:
	return meters_to_pixels(meters_per_second)
