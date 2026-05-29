class_name ViewTransforms
extends RefCounted

## View-layer coordinate conversions. Grid rules mirror Core GridMath; scale from ViewMetrics.

const ViewMetrics = preload("res://src/Godot/Scripts/ViewMetrics.gd")


static func meters_to_pixels(meters: float) -> float:
	return meters * float(ViewMetrics.PIXELS_PER_METER)


static func pixels_to_meters(pixels: float) -> float:
	return pixels / float(ViewMetrics.PIXELS_PER_METER)


static func grid_to_world_m(gx: float, gy: float) -> Vector2:
	return Vector2(gx * ViewMetrics.METERS_PER_CELL, gy * ViewMetrics.METERS_PER_CELL)


static func world_m_to_grid(world_m: Vector2) -> Vector2:
	return Vector2(world_m.x / ViewMetrics.METERS_PER_CELL, world_m.y / ViewMetrics.METERS_PER_CELL)


static func world_m_to_grid_i(world_m: Vector2) -> Vector2i:
	return Vector2i(
		int(floor(world_m.x / ViewMetrics.METERS_PER_CELL)),
		int(floor(world_m.y / ViewMetrics.METERS_PER_CELL))
	)


static func grid_to_map_local_px(gx: float, gy: float) -> Vector2:
	return Vector2(gx * float(ViewMetrics.CELL_SIZE_PX), gy * float(ViewMetrics.CELL_SIZE_PX))


static func map_local_px_to_grid(px: Vector2) -> Vector2:
	return Vector2(px.x / float(ViewMetrics.CELL_SIZE_PX), px.y / float(ViewMetrics.CELL_SIZE_PX))


static func world_m_to_map_local_px(world_m: Vector2) -> Vector2:
	return Vector2(meters_to_pixels(world_m.x), meters_to_pixels(world_m.y))


static func map_local_px_to_world_m(px: Vector2) -> Vector2:
	return Vector2(pixels_to_meters(px.x), pixels_to_meters(px.y))


## On-screen cell size in canvas px (map-local cell * zoom). Viewport metrics only.
static func on_screen_cell_px(zoom: float) -> float:
	return float(ViewMetrics.CELL_SIZE_PX) * maxf(zoom, 0.0001)


static func visible_grid_radius_from_viewport(vp_size: Vector2, zoom: float, buffer_cells: int = 0) -> int:
	var cell_px: float = on_screen_cell_px(zoom)
	if cell_px <= 0.0:
		return buffer_cells
	var half_x: int = int(ceil(vp_size.x * 0.5 / cell_px)) + buffer_cells
	var half_y: int = int(ceil(vp_size.y * 0.5 / cell_px)) + buffer_cells
	return maxi(half_x, half_y)
