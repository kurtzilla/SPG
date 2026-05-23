extends CanvasLayer

## Upper-right HUD (live stats, panel visibility). Fog tuning is code constants only.

signal settings_changed

const HUD_FONT_SIZE: int = 10
const HUD_VALUE_COLOR: Color = Color(0.75, 0.78, 0.82, 1)
const ARROW_EXPANDED: String = "▲"
const ARROW_COLLAPSED: String = "▼"

const PV: String = (
	"HudRoot/TopRightVBox/SettingsPanelRoot/ContentMargin/PanelVBox/MainBodyVBox"
)
const STATS_GRID: String = PV + "/StatsBlock/StatsMargin/StatsGrid"
const MOUSE_SCREEN_UNSET: Vector2 = Vector2(-1, -1)

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

var _party = null
var _mouse_inside_window: bool = true
var _last_mouse_screen: Vector2 = MOUSE_SCREEN_UNSET
var _cached_mouse_pos_text: String = "--"


func _ready() -> void:
	_apply_hud_theme()
	_show_panel_toggle.pressed.connect(_on_show_panel_pressed)
	if not ViewProjection.view_changed.is_connected(_on_view_changed):
		ViewProjection.view_changed.connect(_on_view_changed)
	call_deferred("_update_hud_layout")


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_MOUSE_ENTER:
		_mouse_inside_window = true
	elif what == NOTIFICATION_WM_MOUSE_EXIT:
		_mouse_inside_window = false
		_last_mouse_screen = MOUSE_SCREEN_UNSET


func setup(_visibility, party = null, _map_scroll: Node2D = null) -> void:
	_party = party
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
	hud_theme.default_font_size = HUD_FONT_SIZE
	_panel_root.theme = hud_theme


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


func _update_mouse_pos_label() -> void:
	if not _mouse_inside_window:
		_mouse_value.text = "--"
		return

	var screen_pos: Vector2 = get_viewport().get_mouse_position()
	if screen_pos != _last_mouse_screen:
		_last_mouse_screen = screen_pos
		_cached_mouse_pos_text = "(%d, %d)" % [int(screen_pos.x), int(screen_pos.y)]
	_mouse_value.text = _cached_mouse_pos_text


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
