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
const MOVEMENT_GRID: String = PV + "/MovementBlock/MovementMargin/MovementVBox/MovementGrid"
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
@onready var _max_speed_slider: HSlider = get_node(MOVEMENT_GRID + "/MaxSpeedSlider") as HSlider
@onready var _max_speed_value: Label = get_node(MOVEMENT_GRID + "/MaxSpeedValue") as Label
@onready var _accel_slider: HSlider = get_node(MOVEMENT_GRID + "/AccelSlider") as HSlider
@onready var _accel_value: Label = get_node(MOVEMENT_GRID + "/AccelValue") as Label
@onready var _friction_slider: HSlider = get_node(MOVEMENT_GRID + "/FrictionSlider") as HSlider
@onready var _friction_value: Label = get_node(MOVEMENT_GRID + "/FrictionValue") as Label

var _party = null
var _player: CharacterBody2D = null
var _speed_unit: SpeedUnit = SpeedUnit.TPS
var _movement_sliders_bound: bool = false
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
	call_deferred("_update_hud_layout")


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_MOUSE_ENTER:
		_mouse_inside_window = true
	elif what == NOTIFICATION_WM_MOUSE_EXIT:
		_mouse_inside_window = false
		_last_mouse_screen = MOUSE_SCREEN_UNSET


func setup(
	party = null,
	_map_scroll: Node2D = null,
	player: CharacterBody2D = null
) -> void:
	_party = party
	_player = player
	_bind_movement_sliders()
	_apply_panel_visibility(ViewProjection.get_settings_panel_visible())
	call_deferred("_update_hud_layout")


func _process(_delta: float) -> void:
	if not _main_body.visible:
		return
	_update_stats_labels()


func _apply_hud_theme() -> void:
	var hud_theme := Theme.new()
	var base_font: Font = ThemeDB.fallback_font
	if base_font != null:
		hud_theme.default_font = base_font
	hud_theme.default_font_size = Settings.get_int("hud.font_size")
	_apply_compact_slider_theme(hud_theme)
	_panel_root.theme = hud_theme


func _apply_compact_slider_theme(hud_theme: Theme) -> void:
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.22, 0.24, 0.28)
	track.set_content_margin(SIDE_TOP, 5)
	track.set_content_margin(SIDE_BOTTOM, 5)

	var grabber := StyleBoxFlat.new()
	grabber.bg_color = Color(0.88, 0.9, 0.94)
	grabber.set_corner_radius_all(4)
	grabber.set_content_margin(SIDE_LEFT, 3)
	grabber.set_content_margin(SIDE_RIGHT, 3)
	grabber.set_content_margin(SIDE_TOP, 3)
	grabber.set_content_margin(SIDE_BOTTOM, 3)

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
	_accel_slider.min_value = float(Settings.get_min("player_movement.acceleration"))
	_accel_slider.max_value = float(Settings.get_max("player_movement.acceleration"))
	_accel_slider.step = Settings.get_float("hud.acceleration_slider_step")
	_friction_slider.min_value = float(Settings.get_min("player_movement.friction"))
	_friction_slider.max_value = float(Settings.get_max("player_movement.friction"))
	_friction_slider.step = Settings.get_float("hud.friction_slider_step")

	_max_speed_slider.value_changed.connect(_on_max_speed_slider_changed)
	_accel_slider.value_changed.connect(_on_accel_slider_changed)
	_friction_slider.value_changed.connect(_on_friction_slider_changed)
	_movement_sliders_bound = true
	_sync_movement_sliders_from_settings()


func _sync_movement_sliders_from_settings() -> void:
	_max_speed_slider.set_value_no_signal(Settings.max_speed)
	_max_speed_value.text = "%.0f" % Settings.max_speed
	_accel_slider.set_value_no_signal(Settings.acceleration)
	_accel_value.text = "%.0f" % Settings.acceleration
	_friction_slider.set_value_no_signal(Settings.friction)
	_friction_value.text = "%.0f" % Settings.friction


func _on_max_speed_slider_changed(value: float) -> void:
	_max_speed_value.text = "%.0f" % value
	Settings.set_max_speed(value)


func _on_accel_slider_changed(value: float) -> void:
	_accel_value.text = "%.0f" % value
	Settings.set_acceleration(value)


func _on_friction_slider_changed(value: float) -> void:
	_friction_value.text = "%.0f" % value
	Settings.set_friction(value)


func _on_movement_settings_changed() -> void:
	if _movement_sliders_bound:
		_sync_movement_sliders_from_settings()


func _sync_collapse_button(btn: Button, expanded: bool) -> void:
	btn.text = ARROW_EXPANDED if expanded else ARROW_COLLAPSED
	btn.tooltip_text = (
		"Hide stats panel" if expanded else "Show stats panel"
	)


func _update_stats_labels() -> void:
	_fps_value.text = "%d" % int(round(Engine.get_frames_per_second()))
	_zoom_value.text = "%.1f" % ViewProjection.zoom

	var character = _party.GetSelectedCharacter() if _party != null else null
	if character != null:
		_foot_value.text = "(%d, %d)" % [character.X, character.Y]
	else:
		_foot_value.text = "(--, --)"

	_update_mouse_pos_label()
	_update_speed_label()


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
