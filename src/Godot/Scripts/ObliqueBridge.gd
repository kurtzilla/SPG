class_name ObliqueBridge
extends RefCounted

## Facade for view-layer metrics. Coordinate math delegates to ViewTransforms.

const ViewMetricsRes = preload("res://src/Godot/Scripts/ViewMetrics.gd")
const ViewTransformsRes = preload("res://src/Godot/Scripts/ViewTransforms.gd")
const TT = preload("res://src/Godot/Scripts/World/TerrainType.gd")

const TERRAIN_LAND: int = TT.LAND
const TERRAIN_WATER: int = TT.WATER
const TERRAIN_MUD: int = TT.MUD

const PIXELS_PER_METER: int = ViewMetricsRes.PIXELS_PER_METER
const METERS_PER_CELL: float = ViewMetricsRes.METERS_PER_CELL
const CELL_SIZE_PX: int = ViewMetricsRes.CELL_SIZE_PX
const HEIGHT_OFFSET_PX: int = ViewMetricsRes.PIXELS_PER_METER


static func meters_to_pixels(meters: float) -> float:
	return ViewTransformsRes.meters_to_pixels(meters)


static func pixels_to_meters(pixels: float) -> float:
	return ViewTransformsRes.pixels_to_meters(pixels)


static func grid_to_meters(x: int, y: int) -> Vector2:
	return ViewTransformsRes.grid_to_world_m(float(x), float(y))


static func data_to_screen(x: float, y: float) -> Vector2:
	return ViewTransformsRes.grid_to_map_local_px(x, y)


static func global_screen_to_grid(screen_pos: Vector2, map_scroll: Node2D) -> Vector2:
	if map_scroll == null:
		return Vector2.ZERO
	var ctx: ViewContext = ViewContext.from_viewport(map_scroll, null)
	ctx.map_scroll = map_scroll
	return ViewTransformsRes.canvas_to_grid(screen_pos, ctx)


static func grid_to_screen(x: int, y: int, z: int = 0) -> Vector2:
	var base: Vector2 = ViewTransformsRes.grid_to_map_local_px(float(x), float(y))
	if z != 0:
		base.y -= ViewTransformsRes.meters_to_pixels(float(z))
	return base


static func grid_to_screen_centered(
	x: int,
	y: int,
	viewport_center: Vector2,
	z: int = 0
) -> Vector2:
	return viewport_center + grid_to_screen(x, y, z)


static func speed_meters_per_second_to_pixels(meters_per_second: float) -> float:
	return meters_to_pixels(meters_per_second)
