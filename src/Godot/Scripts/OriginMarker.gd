extends Node2D

## Debug reference at map-local grid origin (0,0). Child of Tiles — scales with zoom.

const ViewMetricsRes = preload("res://src/Godot/Scripts/ViewMetrics.gd")

const PATH_SHOW_ORIGIN_MARKER: String = "view.show_origin_marker"
## Cyan — distinct from player placeholder crimson (0.8, 0.2, 0.2) in PlaceholderTextureGenerator.
const MARKER_COLOR: Color = Color(0.15, 0.92, 1.0, 0.95)


func _ready() -> void:
	z_index = 0
	position = Vector2.ZERO
	if not Settings.setting_changed.is_connected(_on_setting_changed):
		Settings.setting_changed.connect(_on_setting_changed)
	_sync_visibility()


func _on_setting_changed(path: String) -> void:
	if path == PATH_SHOW_ORIGIN_MARKER:
		_sync_visibility()


func _sync_visibility() -> void:
	var show_marker: bool = OS.is_debug_build() and Settings.get_bool(PATH_SHOW_ORIGIN_MARKER)
	visible = show_marker
	if show_marker:
		queue_redraw()


func _draw() -> void:
	var cell_px: float = float(ViewMetricsRes.CELL_SIZE_PX)
	if cell_px <= 0.0:
		return
	var arm: float = cell_px
	var line_w: float = maxf(4.0, cell_px * 0.08)
	var half_line: float = line_w * 0.5
	draw_line(Vector2(-arm, 0.0), Vector2(arm, 0.0), MARKER_COLOR, line_w)
	draw_line(Vector2(0.0, -arm), Vector2(0.0, arm), MARKER_COLOR, line_w)
	draw_rect(
		Rect2(Vector2(-half_line, -half_line), Vector2(line_w, line_w)),
		MARKER_COLOR,
		true
	)
	draw_arc(Vector2.ZERO, cell_px * 0.12, 0.0, TAU, 12, MARKER_COLOR, line_w)
