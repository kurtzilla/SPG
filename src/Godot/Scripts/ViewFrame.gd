extends RefCounted

## Per-frame view snapshot built once in MainSandbox._apply_view_frame().

var map_scroll: Vector2 = Vector2.ZERO
var camera_focus_map_px: Vector2 = Vector2.ZERO
var zoom: float = 1.0
var viewport_center: Vector2 = Vector2.ZERO
var viewport_size: Vector2 = Vector2.ZERO
var canvas_transform: Transform2D = Transform2D.IDENTITY
var canvas_to_map_local: Transform2D = Transform2D.IDENTITY
var camera_grid: Vector2i = Vector2i.ZERO


static func build(player: Node2D = null) -> RefCounted:
	var frame: RefCounted = load("res://src/Godot/Scripts/ViewFrame.gd").new()
	frame.viewport_center = ViewProjection.get_screen_center_offset()
	frame.viewport_size = ViewProjection.get_viewport_size()
	frame.zoom = ViewProjection.safe_zoom()
	frame.camera_focus_map_px = ViewProjection.resolve_camera_focus_map_px(player)
	frame.map_scroll = frame.camera_focus_map_px
	frame.canvas_transform = ViewProjection.forward_canvas_transform()
	frame.canvas_to_map_local = frame.canvas_transform.affine_inverse()
	frame.camera_grid = ViewProjection.map_local_px_to_grid_cell(frame.camera_focus_map_px)
	return frame
