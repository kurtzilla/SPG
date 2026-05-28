extends ColorRect

const FOG_SHADER: Shader = preload("res://src/Godot/Shaders/FogOverlay.gdshader")
const ViewMetricsScript = preload("res://src/Godot/Scripts/ViewMetrics.gd")
const FogExplorationMapScript = preload("res://src/Godot/Scripts/Systems/fog-of-war/FogExplorationMap.gd")

@export var reveal_radius_cells: float = 6.0

var _player: Node2D
var _map_scroll: Node2D
var _shader_mat: ShaderMaterial
var _cached_player_world_pos: Vector2 = Vector2(-99999.0, -99999.0)
var _cached_reveal_radius: float = -1.0
var _cached_fog_enabled: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_as_relative = false
	z_index = 100
	anchors_preset = Control.PRESET_FULL_RECT
	anchor_right = 1.0
	anchor_bottom = 1.0
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BOTH
	color = Color(0.0, 0.0, 0.0, 0.0)

	_shader_mat = ShaderMaterial.new()
	_shader_mat.shader = FOG_SHADER
	material = _shader_mat
	_shader_mat.set_shader_parameter(&"fog_enabled", false)
	_shader_mat.set_shader_parameter(&"fog_color", Color(0.0, 0.0, 0.0, 0.85))
	_shader_mat.set_shader_parameter(&"player_world_pos", Vector2.ZERO)
	_shader_mat.set_shader_parameter(&"reveal_radius", reveal_radius_cells * float(ViewMetricsScript.CELL_SIZE_PX))
	_cached_fog_enabled = false
	_cached_player_world_pos = Vector2.ZERO
	_cached_reveal_radius = reveal_radius_cells * float(ViewMetricsScript.CELL_SIZE_PX)


func get_shader_material() -> ShaderMaterial:
	return _shader_mat


func set_player(player: Node2D) -> void:
	_player = player
	_cached_player_world_pos = Vector2(-99999.0, -99999.0)
	sync_uniforms()


func set_map_scroll(map_scroll: Node2D) -> void:
	_map_scroll = map_scroll
	_cached_player_world_pos = Vector2(-99999.0, -99999.0)
	sync_uniforms()


func update_fog_vision_metrics(radius_cells: float, _feather_cells: float) -> void:
	# Feather is intentionally ignored in the new hard-edge mask shader.
	reveal_radius_cells = maxf(radius_cells, 0.0)
	sync_uniforms()


func configure(fog_enabled: bool, fog_color: Color) -> void:
	if _shader_mat == null:
		return
	_shader_mat.set_shader_parameter(&"fog_enabled", fog_enabled)
	_shader_mat.set_shader_parameter(&"fog_color", fog_color)
	_cached_fog_enabled = fog_enabled
	sync_uniforms()


func on_view_changed() -> void:
	sync_uniforms()


func sync_runtime(fog_map: FogExplorationMapScript) -> void:
	if _shader_mat == null:
		return
	if fog_map == null:
		sync_uniforms()
		return
	var fog_enabled: bool = fog_map.enabled
	if fog_enabled != _cached_fog_enabled:
		_shader_mat.set_shader_parameter(&"fog_enabled", fog_enabled)
		_cached_fog_enabled = fog_enabled
	var cell_px: float = maxf(float(ViewMetricsScript.CELL_SIZE_PX), 1.0)
	reveal_radius_cells = fog_map.get_reveal_radius_map_px() / cell_px
	sync_uniforms()


func sync_player_position() -> void:
	sync_uniforms()


func sync_uniforms() -> void:
	if _shader_mat == null:
		return

	var player_world_pos: Vector2 = Vector2.ZERO
	if _player != null:
		player_world_pos = _player.position
		if _map_scroll != null:
			player_world_pos = _map_scroll.to_local(_player.global_position)
	if not player_world_pos.is_equal_approx(_cached_player_world_pos):
		_shader_mat.set_shader_parameter(&"player_world_pos", player_world_pos)
		_cached_player_world_pos = player_world_pos

	var reveal_radius: float = reveal_radius_cells * float(ViewMetricsScript.CELL_SIZE_PX)
	if not is_equal_approx(reveal_radius, _cached_reveal_radius):
		_shader_mat.set_shader_parameter(&"reveal_radius", reveal_radius)
		_cached_reveal_radius = reveal_radius
