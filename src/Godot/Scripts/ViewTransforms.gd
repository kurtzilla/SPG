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


## Map-local px at the center of a grid cell (matches Core stamp centers and fog bootstrap).
static func grid_cell_center_to_map_local_px(gx: float, gy: float) -> Vector2:
	return grid_to_map_local_px(gx + 0.5, gy + 0.5)


static func map_local_px_to_grid(px: Vector2) -> Vector2:
	return Vector2(px.x / float(ViewMetrics.CELL_SIZE_PX), px.y / float(ViewMetrics.CELL_SIZE_PX))


static func world_m_to_map_local_px(world_m: Vector2) -> Vector2:
	return Vector2(meters_to_pixels(world_m.x), meters_to_pixels(world_m.y))


static func map_local_px_to_world_m(px: Vector2) -> Vector2:
	return Vector2(pixels_to_meters(px.x), pixels_to_meters(px.y))


## On-screen cell size in canvas px (map-local cell * zoom). Viewport metrics only.
static func on_screen_cell_px(zoom: float) -> float:
	return float(ViewMetrics.CELL_SIZE_PX) * maxf(zoom, 0.0001)


## True when each map cell maps to a whole canvas pixel (crisp nearest-neighbor tiles).
static func is_zoom_pixel_aligned(zoom: float) -> bool:
	var cell_px: float = on_screen_cell_px(zoom)
	return is_equal_approx(cell_px, roundf(cell_px))


## Snap map-local camera focus so cell/chunk edges land on whole canvas pixels.
static func snap_map_scroll_pixel_aligned(map_scroll: Vector2, zoom: float) -> Vector2:
	if not is_zoom_pixel_aligned(zoom):
		return map_scroll
	var screen_cell_px: float = roundf(on_screen_cell_px(zoom))
	if screen_cell_px <= 0.0:
		return map_scroll
	var step: float = float(ViewMetrics.CELL_SIZE_PX) / screen_cell_px
	return Vector2(
		roundf(map_scroll.x / step) * step,
		roundf(map_scroll.y / step) * step
	)


## Nearest zoom where CELL_SIZE_PX * zoom is an integer (zoom = n / CELL_SIZE_PX).
static func snap_zoom_pixel_aligned(zoom: float) -> float:
	var cell_size: int = ViewMetrics.CELL_SIZE_PX
	if cell_size <= 0:
		return zoom
	var n: int = maxi(1, roundi(float(cell_size) * zoom))
	return float(n) / float(cell_size)


static func snap_zoom_pixel_aligned_clamped(zoom: float, min_zoom: float, max_zoom: float) -> float:
	var z: float = clampf(zoom, min_zoom, max_zoom)
	z = snap_zoom_pixel_aligned(z)
	return clampf(z, min_zoom, max_zoom)


## Next/previous pixel-aligned zoom for wheel input (direction: +1 in, -1 out).
static func adjacent_pixel_aligned_zoom(
	zoom: float,
	direction: int,
	min_zoom: float,
	max_zoom: float
) -> float:
	var cell_size: int = ViewMetrics.CELL_SIZE_PX
	if cell_size <= 0 or direction == 0:
		return snap_zoom_pixel_aligned_clamped(zoom, min_zoom, max_zoom)
	var min_n: int = maxi(1, int(ceil(min_zoom * float(cell_size) - 0.001)))
	var max_n: int = maxi(min_n, int(floor(max_zoom * float(cell_size) + 0.001)))
	var current_n: int = clampi(roundi(float(cell_size) * zoom), min_n, max_n)
	var target_n: int = clampi(current_n + (1 if direction > 0 else -1), min_n, max_n)
	return float(target_n) / float(cell_size)


static func visible_grid_radius_from_viewport(vp_size: Vector2, zoom: float, buffer_cells: int = 0) -> int:
	var cell_px: float = on_screen_cell_px(zoom)
	if cell_px <= 0.0:
		return buffer_cells
	var half_x: float = vp_size.x * 0.5 / cell_px
	var half_y: float = vp_size.y * 0.5 / cell_px
	# Corner distance from center — max(half_x, half_y) under-covers wide viewports.
	var half_diag: float = sqrt(half_x * half_x + half_y * half_y)
	return int(ceil(half_diag)) + buffer_cells
