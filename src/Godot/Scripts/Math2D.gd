class_name Math2D
extends RefCounted

## Engine-agnostic 2D math helpers (no coordinate-space semantics).


static func remap(value: float, from_min: float, from_max: float, to_min: float, to_max: float) -> float:
	if is_equal_approx(from_min, from_max):
		return to_min
	var t: float = (value - from_min) / (from_max - from_min)
	return lerpf(to_min, to_max, t)


static func inverse_remap(value: float, from_min: float, from_max: float, to_min: float, to_max: float) -> float:
	return remap(value, to_min, to_max, from_min, from_max)


static func smoothstep(edge0: float, edge1: float, x: float) -> float:
	if is_equal_approx(edge0, edge1):
		return 0.0 if x < edge0 else 1.0
	var t: float = clampf((x - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


static func distance_squared(a: Vector2, b: Vector2) -> float:
	var dx: float = a.x - b.x
	var dy: float = a.y - b.y
	return dx * dx + dy * dy


static func point_in_rect(point: Vector2, rect: Rect2) -> bool:
	return rect.has_point(point)


static func closest_point_on_rect(point: Vector2, rect: Rect2) -> Vector2:
	return Vector2(
		clampf(point.x, rect.position.x, rect.end.x),
		clampf(point.y, rect.position.y, rect.end.y)
	)


static func rect_intersects_circle(rect: Rect2, center: Vector2, radius: float) -> bool:
	var closest: Vector2 = closest_point_on_rect(center, rect)
	return center.distance_squared_to(closest) <= radius * radius


static func wrap_angle(radians: float) -> float:
	var tau: float = TAU
	return fposmod(radians + PI, tau) - PI


static func angle_from_direction(direction: Vector2) -> float:
	return direction.angle()


static func direction_from_angle(radians: float) -> Vector2:
	return Vector2.from_angle(radians)


static func snap_to_step(value: float, step: float) -> float:
	if is_zero_approx(step):
		return value
	return round(value / step) * step


static func snap_vector_to_grid(vector: Vector2, cell_size: float) -> Vector2:
	return Vector2(
		snap_to_step(vector.x, cell_size),
		snap_to_step(vector.y, cell_size)
	)


static func expand_rect(rect: Rect2, margin: float) -> Rect2:
	return rect.grow(margin)


static func rect_union(a: Rect2, b: Rect2) -> Rect2:
	return a.merge(b)


static func rect_from_center_size(center: Vector2, size: Vector2) -> Rect2:
	return Rect2(center - size * 0.5, size)
