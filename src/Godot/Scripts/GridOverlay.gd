extends Node2D

## Viewport-space grid lines aligned to the scrolling tile map (debug / readability).
## Lives on a CanvasLayer (not under $Tiles) so zoom does not scale line width.

const ViewTransforms = preload("res://src/Godot/Scripts/ViewTransforms.gd")

const GRID_LINE_WIDTH_SCREEN_PX: float = 1.0
const GRID_LINE_COLOR: Color = Color(0.12, 0.14, 0.1, 0.38)

var _enabled: bool = true
var _reveal_context: FogRevealContext = FogRevealContext.disabled()
var _map_scroll: Node2D
var _center_x: int = 0
var _center_y: int = 0
var _visual_radius: int = 0


func configure(enabled: bool) -> void:
	_enabled = enabled
	queue_redraw()


func set_reveal_context(reveal_context: FogRevealContext) -> void:
	_reveal_context = reveal_context if reveal_context != null else FogRevealContext.disabled()


func set_map_scroll(map_scroll: Node2D) -> void:
	_map_scroll = map_scroll


func update_region(center_x: int, center_y: int, visual_radius: int) -> void:
	_center_x = center_x
	_center_y = center_y
	_visual_radius = visual_radius
	queue_redraw()


func on_view_changed() -> void:
	queue_redraw()


func _cell_size() -> float:
	return float(ViewTransforms.CELL_SIZE_PX)


func _corner_screen(gx: float, gy: float) -> Vector2:
	if _map_scroll == null:
		return Vector2.ZERO
	return ViewTransforms.grid_to_canvas(gx, gy, _view_context())


func _screen_to_local(screen_pos: Vector2) -> Vector2:
	return ViewTransforms.canvas_to_overlay_local(screen_pos, self)


func _view_context() -> ViewContext:
	return ViewContext.from_viewport(_map_scroll, get_viewport(), ViewProjection.zoom)


func _draw_screen_segment(screen_from: Vector2, screen_to: Vector2) -> void:
	draw_line(
		_screen_to_local(screen_from),
		_screen_to_local(screen_to),
		GRID_LINE_COLOR,
		GRID_LINE_WIDTH_SCREEN_PX,
		false
	)


func _should_draw_cell(gx: int, gy: int) -> bool:
	return true


func _draw() -> void:
	if not _enabled or _visual_radius <= 0 or _map_scroll == null:
		return

	var min_gx: int = _center_x - _visual_radius
	var max_gx: int = _center_x + _visual_radius
	var min_gy: int = _center_y - _visual_radius
	var max_gy: int = _center_y + _visual_radius

	for gx in range(min_gx, max_gx + 1):
		for gy in range(min_gy, max_gy + 1):
			if not _should_draw_cell(gx, gy):
				continue
			var top_left: Vector2 = _corner_screen(float(gx), float(gy))
			var top_right: Vector2 = _corner_screen(float(gx + 1), float(gy))
			var bottom_left: Vector2 = _corner_screen(float(gx), float(gy + 1))
			_draw_screen_segment(top_left, top_right)
			_draw_screen_segment(top_left, bottom_left)
