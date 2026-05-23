class_name RevealMath
extends RefCounted

## Shared world-space reveal tests for fog and terrain (smooth circular frontier).

const ViewTransforms = preload("res://src/Godot/Scripts/ViewTransforms.gd")

const HIDDEN_BYTE: int = 255


static func cell_center_world_m(gx: int, gy: int) -> Vector2:
	var m: float = ViewTransforms.METERS_PER_CELL
	return Vector2((float(gx) + 0.5) * m, (float(gy) + 0.5) * m)


static func distance_point_to_cell_aabb(world_m: Vector2, gx: int, gy: int) -> float:
	var m: float = ViewTransforms.METERS_PER_CELL
	var min_p: Vector2 = ViewTransforms.grid_to_world_m(float(gx), float(gy))
	var max_p: Vector2 = min_p + Vector2(m, m)
	var closest: Vector2 = Vector2(
		clampf(world_m.x, min_p.x, max_p.x),
		clampf(world_m.y, min_p.y, max_p.y)
	)
	return world_m.distance_to(closest)


static func _cell_corner_world_positions(gx: int, gy: int) -> Array[Vector2]:
	var m: float = ViewTransforms.METERS_PER_CELL
	var gx_f: float = float(gx)
	var gy_f: float = float(gy)
	return [
		ViewTransforms.grid_to_world_m(gx_f, gy_f),
		ViewTransforms.grid_to_world_m(gx_f + 1.0, gy_f),
		ViewTransforms.grid_to_world_m(gx_f, gy_f + 1.0),
		ViewTransforms.grid_to_world_m(gx_f + 1.0, gy_f + 1.0),
	]


static func cell_inside_live_radius(
	gx: int,
	gy: int,
	player_world_m: Vector2,
	radius_m: float
) -> bool:
	if radius_m <= 0.0:
		return false
	for corner: Vector2 in _cell_corner_world_positions(gx, gy):
		if player_world_m.distance_to(corner) >= radius_m:
			return false
	return true


static func cell_revealed(
	gx: int,
	gy: int,
	player_world_m: Vector2,
	live_radius_m: float,
	explored_memory
) -> bool:
	if explored_memory != null and explored_memory.is_cell_explored(gx, gy):
		return true
	return cell_inside_live_radius(gx, gy, player_world_m, live_radius_m)


static func radius_cells_to_meters(radius_cells: int) -> float:
	return float(radius_cells) * ViewTransforms.METERS_PER_CELL
