extends CanvasLayer

## Upper-right HUD (live stats, panel visibility, player movement tuning).

signal settings_changed

const ARROW_EXPANDED: String = "▲"
const ARROW_COLLAPSED: String = "▼"

const ViewMetricsRes = preload("res://src/Godot/Scripts/ViewMetrics.gd")

const PV: String = (
	"HudRoot/TopRightVBox/SettingsPanelRoot/ContentMargin/PanelVBox/MainBodyVBox"
)
const STATS_GRID: String = PV + "/StatsBlock/StatsMargin/StatsGrid"
const PERF_GRID: String = PV + "/PerfBlock/PerfMargin/PerfVBox/PerfGrid"
const PERF_CONTROLS_GRID: String = PV + "/PerfBlock/PerfMargin/PerfVBox/PerfControlsGrid"
const PATH_INTERNAL_SCALE: String = "view.internal_scale"
const MOVEMENT_GRID: String = PV + "/MovementBlock/MovementMargin/MovementVBox/MovementGrid"
const FOG_GRID: String = PV + "/FogBlock/FogMargin/FogVBox/FogGrid"
const PATH_EDGE_FEATHER: String = "fog.edge_feather_px"
const PATH_REVEAL_FADE: String = "fog.reveal_fade_seconds"
const MOUSE_SCREEN_UNSET: Vector2 = Vector2(-1, -1)

const TOOLTIP_TPS: String = "Tiles per second — grid cells traversed per second"
const TOOLTIP_MPS: String = "Meters per second — world distance traveled per second"

enum SpeedUnit { TPS, MPS }

@onready var _top_right_vbox: VBoxContainer = $HudRoot/TopRightVBox
@onready var _panel_root: PanelContainer = $HudRoot/TopRightVBox/SettingsPanelRoot
@onready var _main_body: VBoxContainer = (
	$HudRoot/TopRightVBox/SettingsPanelRoot/ContentMargin/PanelVBox/MainBodyVBox
)
@onready var _show_panel_toggle: Button = (
	$HudRoot/TopRightVBox/SettingsPanelRoot/ContentMargin/PanelVBox/TitleHeaderPanel/TitleRow/ShowPanelToggle
)
@onready var _fps_value: Label = get_node(STATS_GRID + "/FpsValue") as Label
@onready var _zoom_value: Label = get_node(STATS_GRID + "/ZoomValue") as Label
@onready var _foot_value: Label = get_node(STATS_GRID + "/FootValue") as Label
@onready var _mouse_value: Label = get_node(STATS_GRID + "/MouseValue") as Label
@onready var _speed_key: Button = get_node(STATS_GRID + "/SpeedKey") as Button
@onready var _speed_value: Label = get_node(STATS_GRID + "/SpeedValue") as Label
@onready var _viewport_value: Label = get_node(PERF_GRID + "/ViewportValue") as Label
@onready var _max_fps_value: Label = get_node(PERF_GRID + "/MaxFpsValue") as Label
@onready var _fog_toggle: CheckButton = get_node(PERF_CONTROLS_GRID + "/FogToggle") as CheckButton
@onready var _grid_toggle: CheckButton = get_node(PERF_CONTROLS_GRID + "/GridToggle") as CheckButton
@onready var _vsync_toggle: CheckButton = get_node(PERF_CONTROLS_GRID + "/VsyncToggle") as CheckButton
@onready var _scale_slider: HSlider = get_node(PERF_CONTROLS_GRID + "/ScaleSlider") as HSlider
@onready var _scale_value: Label = get_node(PERF_CONTROLS_GRID + "/ScaleValue") as Label
@onready var _max_speed_slider: HSlider = get_node(MOVEMENT_GRID + "/MaxSpeedSlider") as HSlider
@onready var _max_speed_value: Label = get_node(MOVEMENT_GRID + "/MaxSpeedValue") as Label
@onready var _edge_feather_slider: HSlider = get_node(FOG_GRID + "/EdgeFeatherSlider") as HSlider
@onready var _edge_feather_value: Label = get_node(FOG_GRID + "/EdgeFeatherValue") as Label
@onready var _reveal_fade_slider: HSlider = get_node(FOG_GRID + "/RevealFadeSlider") as HSlider
@onready var _reveal_fade_value: Label = get_node(FOG_GRID + "/RevealFadeValue") as Label

var _party: PartyModelGd = null
var _player: CharacterBody2D = null
var _speed_unit: SpeedUnit = SpeedUnit.TPS
var _movement_sliders_bound: bool = false
var _fog_sliders_bound: bool = false
var _perf_controls_bound: bool = false
var _mouse_inside_window: bool = true
var _last_mouse_screen: Vector2 = MOUSE_SCREEN_UNSET
var _cached_mouse_pos_text: String = "--"


func _ready() -> void:
	_apply_hud_theme()
	_sync_speed_key_label()
	_show_panel_toggle.pressed.connect(_on_show_panel_pressed)
	_speed_key.pressed.connect(_on_speed_key_pressed)
	if not ViewProjection.view_changed.is_connected(_on_view_changed):
		ViewProjection.view_changed.connect(_on_view_changed)
	if not Settings.movement_changed.is_connected(_on_movement_settings_changed):
		Settings.movement_changed.connect(_on_movement_settings_changed)
	if not Settings.fog_changed.is_connected(_on_fog_settings_changed):
		Settings.fog_changed.connect(_on_fog_settings_changed)
	if not Settings.view_changed.is_connected(_on_settings_view_changed):
		Settings.view_changed.connect(_on_settings_view_changed)
	if not Settings.setting_changed.is_connected(_on_setting_changed):
		Settings.setting_changed.connect(_on_setting_changed)
	call_deferred("_update_hud_layout")


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_MOUSE_ENTER:
		_mouse_inside_window = true
	elif what == NOTIFICATION_WM_MOUSE_EXIT:
		_mouse_inside_window = false
		_last_mouse_screen = MOUSE_SCREEN_UNSET


func setup(
	party: PartyModelGd = null,
	player: CharacterBody2D = null
) -> void:
	_party = party
	_player = player
	_bind_movement_sliders()
	_bind_fog_sliders()
	_bind_perf_controls()
	_apply_panel_visibility(ViewProjection.get_settings_panel_visible())
	call_deferred("_update_hud_layout")


const STATS_UPDATE_INTERVAL_SEC: float = 0.1

var _stats_update_timer_sec: float = 0.0


func _process(delta: float) -> void:
	if not _main_body.visible:
		return
	_stats_update_timer_sec -= delta
	if _stats_update_timer_sec > 0.0:
		return
	_stats_update_timer_sec = STATS_UPDATE_INTERVAL_SEC
	_update_stats_labels()


func _apply_hud_theme() -> void:
	var hud_theme := Theme.new()
	var base_font: Font = ThemeDB.fallback_font
	if base_font != null:
		hud_theme.default_font = base_font
	hud_theme.default_font_size = Settings.get_int("hud.font_size") * 2
	_apply_compact_slider_theme(hud_theme)
	_panel_root.theme = hud_theme


func _apply_compact_slider_theme(hud_theme: Theme) -> void:
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.22, 0.24, 0.28)
	track.set_content_margin(SIDE_TOP, 10)
	track.set_content_margin(SIDE_BOTTOM, 10)

	var grabber := StyleBoxFlat.new()
	grabber.bg_color = Color(0.88, 0.9, 0.94)
	grabber.set_corner_radius_all(8)
	grabber.set_content_margin(SIDE_LEFT, 6)
	grabber.set_content_margin(SIDE_RIGHT, 6)
	grabber.set_content_margin(SIDE_TOP, 6)
	grabber.set_content_margin(SIDE_BOTTOM, 6)

	var grabber_area := StyleBoxFlat.new()
	grabber_area.bg_color = Color(0, 0, 0, 0)
	grabber_area.set_content_margin_all(0)

	hud_theme.set_stylebox("slider", "HSlider", track)
	hud_theme.set_stylebox("grabber", "HSlider", grabber)
	hud_theme.set_stylebox("grabber_highlight", "HSlider", grabber)
	hud_theme.set_stylebox("grabber_area", "HSlider", grabber_area)
	hud_theme.set_stylebox("grabber_area_highlight", "HSlider", grabber_area)


func _bind_movement_sliders() -> void:
	if _movement_sliders_bound:
		_sync_movement_sliders_from_settings()
		return

	_max_speed_slider.min_value = float(Settings.get_min("player_movement.max_speed"))
	_max_speed_slider.max_value = float(Settings.get_max("player_movement.max_speed"))
	_max_speed_slider.step = Settings.get_float("hud.max_speed_slider_step")

	_max_speed_slider.value_changed.connect(_on_max_speed_slider_changed)
	_movement_sliders_bound = true
	_sync_movement_sliders_from_settings()


func _sync_movement_sliders_from_settings() -> void:
	_max_speed_slider.set_value_no_signal(Settings.max_speed)
	_max_speed_value.text = "%.0f" % Settings.max_speed


func _on_max_speed_slider_changed(value: float) -> void:
	_max_speed_value.text = "%.0f" % value
	Settings.set_max_speed(value)
	if _player != null and _player.has_method("apply_movement_settings"):
		_player.apply_movement_settings()


func _on_movement_settings_changed() -> void:
	if _movement_sliders_bound:
		_sync_movement_sliders_from_settings()


func _bind_perf_controls() -> void:
	if _perf_controls_bound:
		_sync_perf_controls_from_settings()
		return

	_scale_slider.min_value = float(Settings.get_min(PATH_INTERNAL_SCALE))
	_scale_slider.max_value = float(Settings.get_max(PATH_INTERNAL_SCALE))
	_scale_slider.step = float(Settings.get_step(PATH_INTERNAL_SCALE))

	_fog_toggle.toggled.connect(_on_fog_toggle_changed)
	_grid_toggle.toggled.connect(_on_grid_toggle_changed)
	_vsync_toggle.toggled.connect(_on_vsync_toggle_changed)
	_scale_slider.value_changed.connect(_on_scale_slider_changed)
	_perf_controls_bound = true
	_sync_perf_controls_from_settings()


func _sync_perf_controls_from_settings() -> void:
	_fog_toggle.set_pressed_no_signal(Settings.get_bool("fog.enabled"))
	_grid_toggle.set_pressed_no_signal(Settings.get_bool("grid.debug_grid_lines"))
	_vsync_toggle.set_pressed_no_signal(Settings.get_bool("view.vsync_enabled"))
	var internal_scale: float = Settings.get_float(PATH_INTERNAL_SCALE)
	_scale_slider.set_value_no_signal(internal_scale)
	_scale_value.text = "%.2f" % internal_scale


func _on_fog_toggle_changed(pressed: bool) -> void:
	Settings.set_bool("fog.enabled", pressed)


func _on_grid_toggle_changed(pressed: bool) -> void:
	Settings.set_bool("grid.debug_grid_lines", pressed)


func _on_vsync_toggle_changed(pressed: bool) -> void:
	Settings.set_bool("view.vsync_enabled", pressed)


func _on_scale_slider_changed(value: float) -> void:
	_scale_value.text = "%.2f" % value
	Settings.set_float(PATH_INTERNAL_SCALE, value)


func _bind_fog_sliders() -> void:
	if _fog_sliders_bound:
		_sync_fog_sliders_from_settings()
		return

	_edge_feather_slider.min_value = float(Settings.get_min(PATH_EDGE_FEATHER))
	_edge_feather_slider.max_value = float(Settings.get_max(PATH_EDGE_FEATHER))
	_edge_feather_slider.step = Settings.get_float("hud.fog_feather_slider_step")
	_edge_feather_slider.tooltip_text = (
		"Fog reveal edge softness (map px). Affects fog mask and live disc; not terrain tiles."
	)
	_reveal_fade_slider.min_value = float(Settings.get_min(PATH_REVEAL_FADE))
	_reveal_fade_slider.max_value = float(Settings.get_max(PATH_REVEAL_FADE))
	_reveal_fade_slider.step = Settings.get_float("hud.fog_fade_slider_step")
	_hide_deprecated_trail_edge_controls()

	_edge_feather_slider.value_changed.connect(_on_edge_feather_slider_changed)
	_reveal_fade_slider.value_changed.connect(_on_reveal_fade_slider_changed)
	_fog_sliders_bound = true
	_sync_fog_sliders_from_settings()


func _sync_fog_sliders_from_settings() -> void:
	_edge_feather_slider.set_value_no_signal(Settings.fog_edge_feather_px)
	_edge_feather_value.text = "%.0f" % Settings.fog_edge_feather_px
	_reveal_fade_slider.set_value_no_signal(Settings.fog_reveal_fade_seconds)
	_reveal_fade_value.text = "%.2f" % Settings.fog_reveal_fade_seconds


func _on_edge_feather_slider_changed(value: float) -> void:
	_edge_feather_value.text = "%.0f" % value
	Settings.fog_edge_feather_px = value


func _hide_deprecated_trail_edge_controls() -> void:
	for node_name: String in ["TrailEdgeKey", "TrailEdgeSlider", "TrailEdgeValue"]:
		var node: Node = get_node_or_null(FOG_GRID + "/" + node_name)
		if node != null:
			node.visible = false


func _on_reveal_fade_slider_changed(value: float) -> void:
	_reveal_fade_value.text = "%.2f" % value
	Settings.fog_reveal_fade_seconds = value


func _on_fog_settings_changed() -> void:
	if _fog_sliders_bound:
		_sync_fog_sliders_from_settings()
	if _perf_controls_bound:
		_sync_perf_controls_from_settings()
	if _main_body.visible:
		_update_perf_labels()


func _sync_collapse_button(btn: Button, expanded: bool) -> void:
	btn.text = ARROW_EXPANDED if expanded else ARROW_COLLAPSED
	btn.tooltip_text = (
		"Hide stats panel" if expanded else "Show stats panel"
	)


func _update_stats_labels() -> void:
	var fps: int = int(round(Engine.get_frames_per_second()))
	var refresh_hz: float = DisplayServer.screen_get_refresh_rate(
		DisplayServer.window_get_current_screen()
	)
	if refresh_hz > 1.0:
		_fps_value.text = "%d / %.0fHz" % [fps, refresh_hz]
	else:
		_fps_value.text = "%d" % fps
	_zoom_value.text = "%.1f" % ViewProjection.zoom

	var character: CharacterModelGd = _party.GetSelectedCharacter() if _party != null else null
	if character != null:
		_foot_value.text = "(%d, %d)" % [character.X, character.Y]
	else:
		_foot_value.text = "(--, --)"

	_update_mouse_pos_label()
	_update_speed_label()
	_update_perf_labels()


func _update_perf_labels() -> void:
	var vp_size: Vector2 = ViewProjection.get_viewport_size()
	_viewport_value.text = "%d×%d" % [int(vp_size.x), int(vp_size.y)]
	var max_fps: int = Settings.get_int("view.max_fps")
	_max_fps_value.text = "uncapped" if max_fps <= 0 else str(max_fps)


func _on_settings_view_changed() -> void:
	if _perf_controls_bound:
		_sync_perf_controls_from_settings()
	if _main_body.visible:
		_update_perf_labels()


func _on_setting_changed(path: String) -> void:
	if _perf_controls_bound and (
		path.begins_with("view.")
		or path.begins_with("grid.")
		or path == "fog.enabled"
	):
		_sync_perf_controls_from_settings()
	if not _main_body.visible:
		return
	if (
		path.begins_with("view.")
		or path.begins_with("grid.")
		or path == "fog.enabled"
	):
		_update_perf_labels()


func _update_mouse_pos_label() -> void:
	if not _mouse_inside_window:
		_mouse_value.text = "--"
		return

	var screen_pos: Vector2 = get_viewport().get_mouse_position()
	if screen_pos != _last_mouse_screen:
		_last_mouse_screen = screen_pos
		_cached_mouse_pos_text = "(%d, %d)" % [int(screen_pos.x), int(screen_pos.y)]
	_mouse_value.text = _cached_mouse_pos_text


func _update_speed_label() -> void:
	if _player == null:
		_speed_value.text = "--"
		return

	var speed_px_s: float = _player.velocity.length()
	if _speed_unit == SpeedUnit.TPS:
		var cell_px: float = float(ViewMetricsRes.CELL_SIZE_PX)
		if cell_px <= 0.0:
			_speed_value.text = "--"
			return
		_speed_value.text = "%.1f" % (speed_px_s / cell_px)
	else:
		_speed_value.text = "%.1f" % ViewTransforms.pixels_to_meters(speed_px_s)


func _sync_speed_key_label() -> void:
	if _speed_unit == SpeedUnit.TPS:
		_speed_key.text = "TPS"
		_speed_key.tooltip_text = TOOLTIP_TPS
	else:
		_speed_key.text = "MPS"
		_speed_key.tooltip_text = TOOLTIP_MPS


func _on_speed_key_pressed() -> void:
	_speed_unit = SpeedUnit.MPS if _speed_unit == SpeedUnit.TPS else SpeedUnit.TPS
	_sync_speed_key_label()
	_update_speed_label()


func _apply_panel_visibility(panel_visible: bool) -> void:
	_main_body.visible = panel_visible
	_panel_root.visible = true
	_sync_collapse_button(_show_panel_toggle, panel_visible)
	call_deferred("_update_hud_layout")


func _update_hud_layout() -> void:
	if _top_right_vbox == null:
		return
	var min_size: Vector2 = _top_right_vbox.get_combined_minimum_size()
	_top_right_vbox.offset_bottom = _top_right_vbox.offset_top + maxf(min_size.y, 1.0)


func _emit_settings_changed() -> void:
	ViewProjection.set_settings_panel_visible(_main_body.visible)
	settings_changed.emit()


func _on_view_changed() -> void:
	if _main_body.visible:
		_zoom_value.text = "%.1f" % ViewProjection.zoom


func _on_show_panel_pressed() -> void:
	_apply_panel_visibility(not _main_body.visible)
	call_deferred("_update_hud_layout")
	_emit_settings_changed()
