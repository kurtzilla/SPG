extends ColorRect

## GPU fog overlay. Lives on a CanvasLayer; scroll/zoom synced from MainSandbox.

const FOG_SHADER: Shader = preload("res://src/Godot/Shaders/FogOverlay.gdshader")
const ViewContextRes = preload("res://src/Godot/Scripts/ViewContext.gd")

@export var debug_coords: bool = false

var _map_scroll: Node2D
var _player: Node2D
var _viewport_center: Vector2 = Vector2.ZERO
var _shader_mat: ShaderMaterial
var _cached_canvas_to_map: Transform2D = Transform2D.IDENTITY
var _cached_zoom: float = -1.0
var _cached_player_sim_position: Vector2 = Vector2(-99999.0, -99999.0)
var _cached_sandbox_scale: float = -1.0
var _cached_fog_enabled: bool = false
var _cached_debug_coords: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchors_preset = Control.PRESET_FULL_RECT
	anchor_right = 1.0
	anchor_bottom = 1.0
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BOTH
	color = Color(0.0, 0.0, 0.0, 0.0)

	_shader_mat = ShaderMaterial.new()
	_shader_mat.shader = FOG_SHADER
	material = _shader_mat
	_push_debug_coords()


func get_shader_material() -> ShaderMaterial:
	return _shader_mat


func set_map_scroll(map_scroll: Node2D) -> void:
	_map_scroll = map_scroll
	_cached_canvas_to_map = Transform2D.IDENTITY
	_cached_zoom = -1.0
	force_resync_scroll()


func set_player(player: Node2D) -> void:
	_player = player
	_cached_player_sim_position = Vector2(-99999.0, -99999.0)
	_cached_sandbox_scale = -1.0
	_sync_live_reveal_world()
	force_resync_scroll()


func refresh_viewport_center(center: Vector2) -> void:
	_viewport_center = center


func configure(fog_enabled: bool, fog_color: Color) -> void:
	if _shader_mat == null:
		return
	_shader_mat.set_shader_parameter(&"fog_enabled", fog_enabled)
	_shader_mat.set_shader_parameter(&"fog_color", fog_color)
	_cached_fog_enabled = fog_enabled
	_push_debug_coords()


func apply_static_uniforms(
	world_origin: Vector2,
	world_extent: Vector2,
	explored_mask: Texture2D
) -> void:
	if _shader_mat == null:
		return
	_shader_mat.set_shader_parameter(&"world_origin_map_px", world_origin)
	_shader_mat.set_shader_parameter(&"world_extent_map_px", world_extent)
	if explored_mask != null:
		_shader_mat.set_shader_parameter(&"explored_mask", explored_mask)


## Canonical camera scroll (viewport_center - player * zoom) so frame-one center-locks on player.
func sync_scroll(scroll_pos: Vector2, zoom: float) -> void:
	if _shader_mat == null:
		return
	var safe_zoom: float = zoom if not is_zero_approx(zoom) else 1.0
	var origin: Vector2 = scroll_pos
	if _player != null:
		origin = _viewport_center - _player.position * safe_zoom
	var forward := Transform2D(Vector2(safe_zoom, 0.0), Vector2(0.0, safe_zoom), origin)
	var canvas_to_map: Transform2D = forward.affine_inverse()

	if canvas_to_map != _cached_canvas_to_map:
		_shader_mat.set_shader_parameter(&"canvas_to_map_local", canvas_to_map)
		_cached_canvas_to_map = canvas_to_map

	if not is_equal_approx(safe_zoom, _cached_zoom):
		_shader_mat.set_shader_parameter(&"zoom", safe_zoom)
		_cached_zoom = safe_zoom


func force_resync_scroll() -> void:
	_viewport_center = ViewContextRes.viewport_center_from(get_viewport())
	_cached_canvas_to_map = Transform2D.IDENTITY
	_cached_zoom = -1.0
	var scroll_pos: Vector2 = _map_scroll.global_position if _map_scroll != null else Vector2.ZERO
	sync_scroll(scroll_pos, ViewProjection.zoom)


func on_view_changed() -> void:
	_cached_player_sim_position = Vector2(-99999.0, -99999.0)
	_cached_sandbox_scale = -1.0
	force_resync_scroll()
	_sync_live_reveal_world()


func _process(_delta: float) -> void:
	_sync_live_reveal_world()


func sync_runtime(fog_map) -> void:
	if _shader_mat == null or fog_map == null:
		return
	if not fog_map.has_method(&"push_runtime_uniforms"):
		return
	if fog_map.enabled != _cached_fog_enabled:
		_shader_mat.set_shader_parameter(&"fog_enabled", fog_map.enabled)
		_cached_fog_enabled = fog_map.enabled
	fog_map.push_runtime_uniforms(_shader_mat)
	_push_debug_coords()


func _sync_live_reveal_world() -> void:
	if _shader_mat == null or _player == null:
		return
	var sim_pos: Vector2 = _player.position
	var sandbox_scale: float = 1.0
	if _map_scroll != null:
		sandbox_scale = _map_scroll.scale.x
	var sprite: Sprite2D = _player.get_node_or_null("Sprite2D") as Sprite2D
	if sprite != null:
		sandbox_scale *= sprite.scale.x
	if sim_pos != _cached_player_sim_position:
		_shader_mat.set_shader_parameter(&"player_sim_position", sim_pos)
		_cached_player_sim_position = sim_pos
	if not is_equal_approx(sandbox_scale, _cached_sandbox_scale):
		_shader_mat.set_shader_parameter(&"sandbox_scale", sandbox_scale)
		_cached_sandbox_scale = sandbox_scale


func _push_debug_coords() -> void:
	if _shader_mat == null or debug_coords == _cached_debug_coords:
		return
	_shader_mat.set_shader_parameter(&"debug_coords", debug_coords)
	_cached_debug_coords = debug_coords


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_SIZE_CHANGED:
		_cached_player_sim_position = Vector2(-99999.0, -99999.0)
		_cached_sandbox_scale = -1.0
		force_resync_scroll()
		_sync_live_reveal_world()
