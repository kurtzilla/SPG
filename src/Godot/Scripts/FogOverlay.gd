extends Sprite2D

## Fog of war: GPU shader driven by FogExploredMemory texture.
## Samples the explored mask and outputs black with alpha = hidden value
## (1 = opaque fog, 0 = transparent/revealed).

const ObliqueBridge = preload("res://src/Godot/Scripts/ObliqueBridge.gd")
const RevealMathScript = preload("res://src/Godot/Scripts/RevealMath.gd")
const FogExploredMemoryScript = preload("res://src/Godot/Scripts/FogExploredMemory.gd")
const ViewTransformsScript = preload("res://src/Godot/Scripts/ViewTransforms.gd")

const MAX_MASK_TEXELS: int = 512
const DEBUG_REVEAL_BORDER: bool = true

var _enabled: bool = true
var _fog_active: bool = true
var _fog_enabled: bool = true
var _center_x: int = 0
var _center_y: int = 0
var _visual_radius: int = 0
var _last_stamp_cell: Vector2i = Vector2i(-99999, -99999)
var _player_world_m: Vector2 = Vector2.ZERO
var _sight_radius_m: float = 0.0
var _explored_stamp_radius_m: float = 0.0
var _mask_origin_world_m: Vector2 = Vector2.ZERO
var _last_mask_origin_world_m: Vector2 = Vector2(-99999.0, -99999.0)
var _explored: FogExploredMemory
var _last_meters_per_texel: float = -1.0
var _last_feather_cells: int = -1
var _bootstrapped: bool = false
var _map_scroll: Node2D
var _fog_stamp_version: int = 0
var _shader_material: ShaderMaterial


func _ready() -> void:
	z_index = 1
	visible = false
	_explored = FogExploredMemoryScript.new()
	_setup_shader_sprite()


func _setup_shader_sprite() -> void:
	var fog_shader: Shader = load("res://src/Godot/Shaders/FogMask.gdshader")
	_shader_material = ShaderMaterial.new()
	_shader_material.shader = fog_shader
	material = _shader_material
	var white_img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	white_img.fill(Color.WHITE)
	texture = ImageTexture.create_from_image(white_img)
	centered = false


func set_map_scroll(map_scroll: Node2D) -> void:
	_map_scroll = map_scroll


func get_center_cell() -> Vector2i:
	return Vector2i(_center_x, _center_y)


func sync_map_scroll() -> void:
	if _bootstrapped:
		_sync_transform()
		_sync_shader_params()


func configure(enabled: bool, fog_active: bool = true) -> void:
	_enabled = enabled
	_fog_active = fog_active
	_apply_active()


func set_fog_enabled(enabled: bool) -> void:
	_fog_enabled = enabled
	_apply_active()


func set_visibility(visibility) -> void:
	if visibility == null:
		return
	_fog_enabled = visibility.FogEnabled
	var move_cells: int = visibility.MovementRevealRadius
	if move_cells > 0:
		_sight_radius_m = RevealMathScript.radius_cells_to_meters(move_cells)
		_explored_stamp_radius_m = _sight_radius_m


func get_explored_memory() -> FogExploredMemory:
	return _explored


func get_player_world_m() -> Vector2:
	return _player_world_m


func get_live_radius_m() -> float:
	return _sight_radius_m


func get_feather_m() -> float:
	return _feather_meters()


func get_mask_origin_world_m() -> Vector2:
	return _mask_origin_world_m


func get_mask_world_size() -> Vector2:
	return _mask_world_size()


func get_mask_meters_per_texel() -> float:
	return ViewProjection.get_fog_mask_meters_per_texel()


func update_region(
	center_x: int,
	center_y: int,
	visual_radius: int,
	sight_radius_cells: int = -1
) -> void:
	_center_x = center_x
	_center_y = center_y
	_visual_radius = visual_radius
	_player_world_m = RevealMathScript.cell_center_world_m(center_x, center_y)
	if sight_radius_cells >= 0:
		_sight_radius_m = RevealMathScript.radius_cells_to_meters(sight_radius_cells)
		_explored_stamp_radius_m = _sight_radius_m

	if not _is_active():
		_apply_active()
		return

	_mask_origin_world_m = _compute_mask_origin_world_m()
	if _needs_rebuild():
		_rebuild_mask(false)
	else:
		_sync_transform()
		_sync_shader_params()
	if _bootstrapped and _is_active():
		_finish_present()


func on_view_changed() -> void:
	if not _is_active():
		return
	_mask_origin_world_m = _compute_mask_origin_world_m()
	if _needs_rebuild() or _mask_origin_shifted():
		_rebuild_mask(false)
	else:
		_sync_transform()
		_sync_shader_params()


func bootstrap_at(
	center_x: int,
	center_y: int,
	sight_radius_cells: int,
	visual_radius: int,
	initial_radius_cells: int = -1
) -> void:
	_center_x = center_x
	_center_y = center_y
	_visual_radius = visual_radius
	_player_world_m = RevealMathScript.cell_center_world_m(center_x, center_y)
	_sight_radius_m = RevealMathScript.radius_cells_to_meters(sight_radius_cells)
	_explored_stamp_radius_m = _sight_radius_m
	_visual_radius = maxi(_visual_radius, 1)
	configure(true, true)
	_bootstrapped = true
	_last_mask_origin_world_m = Vector2(-99999.0, -99999.0)
	_last_stamp_cell = Vector2i(-99999, -99999)
	update_region(center_x, center_y, _visual_radius, sight_radius_cells)

	var stamp_radius_m: float = _sight_radius_m
	if initial_radius_cells >= 0:
		stamp_radius_m = RevealMathScript.radius_cells_to_meters(initial_radius_cells)
	if _explored != null and stamp_radius_m > 0.0:
		_explored.stamp_disc(_player_world_m, stamp_radius_m)
		_fog_stamp_version += 1
		_sync_shader_params()

	_last_stamp_cell = Vector2i(center_x, center_y)
	_finish_present()


func on_player_moved(
	center_x: int,
	center_y: int,
	reveal_radius_cells: int,
	visual_radius: int
) -> void:
	if not _is_active():
		return
	_center_x = center_x
	_center_y = center_y
	_visual_radius = visual_radius
	_player_world_m = RevealMathScript.cell_center_world_m(center_x, center_y)
	_sight_radius_m = RevealMathScript.radius_cells_to_meters(reveal_radius_cells)
	_explored_stamp_radius_m = _sight_radius_m

	var new_origin: Vector2 = _compute_mask_origin_world_m()
	var origin_shifted: bool = _mask_origin_shifted_with(new_origin)
	var old_origin: Vector2 = _last_mask_origin_world_m

	if _needs_rebuild():
		_mask_origin_world_m = new_origin
		_rebuild_mask(true)
		return

	if origin_shifted:
		var snap: Dictionary = _explored.take_buffer_snapshot()
		_mask_origin_world_m = new_origin
		_explored.set_origin_world_m(_mask_origin_world_m)
		_explored.scroll_from(old_origin, snap["buffer"], snap["dims"])
		_sync_transform()
		_stamp_explored_if_moved(center_x, center_y)
		_sync_shader_params()
		_last_mask_origin_world_m = _mask_origin_world_m
		return

	_mask_origin_world_m = new_origin
	_explored.set_origin_world_m(_mask_origin_world_m)
	_sync_transform()
	_stamp_explored_if_moved(center_x, center_y)
	_sync_shader_params()
	_last_mask_origin_world_m = _mask_origin_world_m


func get_fog_stamp_version() -> int:
	return _fog_stamp_version


func _is_active() -> bool:
	return _enabled and _fog_active and _fog_enabled and _visual_radius > 0


func _apply_active() -> void:
	if not _is_active() or not _bootstrapped:
		visible = false
		return
	visible = true
	if _visual_radius > 0:
		var sight_cells: int = int(round(_sight_radius_m / ObliqueBridge.METERS_PER_CELL))
		update_region(_center_x, _center_y, _visual_radius, sight_cells)
	elif _is_active():
		update_region(_center_x, _center_y, _visual_radius)


func _stamp_explored_if_moved(center_x: int, center_y: int) -> void:
	var cell: Vector2i = Vector2i(center_x, center_y)
	if cell == _last_stamp_cell:
		return
	var from_world: Vector2 = RevealMathScript.cell_center_world_m(
		_last_stamp_cell.x, _last_stamp_cell.y
	)
	var to_world: Vector2 = _player_world_m
	var radius_m: float = _explored_stamp_radius_m
	if from_world.distance_squared_to(to_world) > 0.0001:
		_explored.stamp_capsule(from_world, to_world, radius_m)
	_last_stamp_cell = cell
	_fog_stamp_version += 1
	_sync_shader_params()


func _viewport_half_extent_m() -> float:
	var ctx: ViewContext = ViewContext.from_viewport(_map_scroll, get_viewport(), ViewProjection.zoom)
	var rect: Rect2 = ViewTransformsScript.visible_world_m_rect(ctx)
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return 0.0
	return maxf(rect.size.x * 0.5, rect.size.y * 0.5)


func _feather_meters() -> float:
	return float(ViewProjection.get_fog_feather_cells()) * ObliqueBridge.METERS_PER_CELL


func _mask_half_extent_m() -> float:
	var pad_cells: int = ViewProjection.get_fog_feather_cells()
	var feather_m: float = _feather_meters()
	var from_sight: float = _sight_radius_m + feather_m + float(pad_cells) * ObliqueBridge.METERS_PER_CELL
	var from_cells: float = float(_visual_radius + pad_cells) * ObliqueBridge.METERS_PER_CELL
	var from_viewport: float = _viewport_half_extent_m() + feather_m
	return maxf(from_sight, maxf(from_cells, from_viewport))


func _compute_mask_origin_world_m() -> Vector2:
	var half: float = _mask_half_extent_m()
	return _player_world_m - Vector2(half, half)


func _mask_origin_shifted() -> bool:
	return _mask_origin_shifted_with(_mask_origin_world_m)


func _mask_origin_shifted_with(new_origin: Vector2) -> bool:
	var mpt: float = ViewProjection.get_fog_mask_meters_per_texel()
	var epsilon: float = mpt * 0.5
	return (
		absf(new_origin.x - _last_mask_origin_world_m.x) > epsilon
		or absf(new_origin.y - _last_mask_origin_world_m.y) > epsilon
	)


func _mask_texel_dims() -> Vector2i:
	var extent_m: float = _mask_half_extent_m() * 2.0
	var mpt: float = maxf(ViewProjection.get_fog_mask_meters_per_texel(), 0.5)
	var w: int = mini(int(ceil(extent_m / mpt)), MAX_MASK_TEXELS)
	return Vector2i(maxi(w, 1), maxi(w, 1))


func _mask_world_size() -> Vector2:
	var dims: Vector2i = _mask_texel_dims()
	var mpt: float = ViewProjection.get_fog_mask_meters_per_texel()
	return Vector2(float(dims.x) * mpt, float(dims.y) * mpt)


func _needs_rebuild() -> bool:
	if _explored == null:
		return true
	var dims: Vector2i = _mask_texel_dims()
	var current: Vector2i = _explored.get_texel_dims()
	if current == Vector2i.ZERO:
		return true
	if current != dims:
		return true
	return not is_equal_approx(
		ViewProjection.get_fog_mask_meters_per_texel(), _last_meters_per_texel
	)


func _sync_transform() -> void:
	if _map_scroll == null:
		return
	var ctx: ViewContext = _view_context()
	var canvas_pos: Vector2 = ViewTransformsScript.world_m_to_canvas(_mask_origin_world_m, ctx)
	var world_size: Vector2 = _mask_world_size()
	var ppm: float = float(ViewTransformsScript.PIXELS_PER_METER)
	var z: float = maxf(ctx.zoom, 0.001)
	var screen_size: Vector2 = world_size * ppm * z
	position = canvas_pos
	scale = screen_size


func _sync_shader_params() -> void:
	if _shader_material == null or _explored == null:
		return
	var tex: ImageTexture = _explored.get_texture()
	if tex != null:
		_shader_material.set_shader_parameter("explored_mask", tex)


func _view_context() -> ViewContext:
	return ViewContext.from_viewport(_map_scroll, get_viewport(), ViewProjection.zoom)


func _finish_present() -> void:
	_sync_transform()
	_sync_shader_params()
	visible = _is_active()


func _rebuild_mask(stamp_explored: bool) -> void:
	if not _is_active():
		_apply_active()
		return

	var snap: Dictionary = _explored.take_buffer_snapshot() if _explored != null else {}
	var old_buffer: PackedByteArray = snap.get("buffer", PackedByteArray())
	var old_dims: Vector2i = snap.get("dims", Vector2i.ZERO)
	var old_origin: Vector2 = _last_mask_origin_world_m

	_mask_origin_world_m = _compute_mask_origin_world_m()
	var dims: Vector2i = _mask_texel_dims()
	var mpt: float = ViewProjection.get_fog_mask_meters_per_texel()
	_explored.configure(_mask_origin_world_m, mpt, dims)
	_last_meters_per_texel = mpt
	_last_feather_cells = ViewProjection.get_fog_feather_cells()

	if old_buffer.size() == old_dims.x * old_dims.y and old_dims.x > 0:
		_explored.scroll_from(old_origin, old_buffer, old_dims)

	_sync_transform()
	if stamp_explored:
		_stamp_explored_if_moved(_center_x, _center_y)
	_fog_stamp_version += 1
	_sync_shader_params()
	_last_mask_origin_world_m = _mask_origin_world_m
	if _bootstrapped:
		_finish_present()
