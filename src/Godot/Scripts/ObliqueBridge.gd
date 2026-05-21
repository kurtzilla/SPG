class_name ObliqueBridge
extends RefCounted

## Canonical view-layer metric adapter for oblique / cabinet projection.
## Rule: PIXELS_PER_METER screen pixels = exactly 1.0 world meter.
## One logical grid cell (Core x/y step) = METERS_PER_CELL meters (2m x 2m) = CELL_SIZE_PX pixels.

const ViewMetrics = preload("res://src/Godot/Scripts/ViewMetrics.gd")
const TerrainTileTextures = preload("res://src/Godot/Scripts/TerrainTileTextures.gd")

# Mirror CoreGridModel.TerrainType ordinals for IDE analysis (LAND=0, WATER=1, MUD=2).
const TERRAIN_LAND: int = 0
const TERRAIN_WATER: int = 1
const TERRAIN_MUD: int = 2

const PIXELS_PER_METER: int = ViewMetrics.PIXELS_PER_METER
const METERS_PER_CELL: float = ViewMetrics.METERS_PER_CELL
const CELL_SIZE_PX: int = ViewMetrics.CELL_SIZE_PX
const HEIGHT_OFFSET_PX: int = ViewMetrics.PIXELS_PER_METER


static func meters_to_pixels(meters: float) -> float:
	return meters * float(PIXELS_PER_METER)


static func pixels_to_meters(pixels: float) -> float:
	return pixels / float(PIXELS_PER_METER)


static func grid_to_meters(x: int, y: int) -> Vector2:
	return Vector2(
		float(x) * METERS_PER_CELL,
		float(y) * METERS_PER_CELL
	)


## Compressed profile 2.5D projection matrix conversion.
## Rows stay completely flat horizontally, eliminating diagonal stair-step jitter.
static func data_to_screen(x: float, y: float) -> Vector2:
	var screen_x = float(x) * CELL_SIZE_PX
	# Compress the Y-axis by 0.75 to give a tilted presentation 
	# without introducing horizontal drift or diagonal chattering.
	var screen_y = float(y) * CELL_SIZE_PX * 0.75
	return Vector2(screen_x, screen_y)


static func grid_to_screen(x: int, y: int, z: int = 0) -> Vector2:
	var meters: Vector2 = grid_to_meters(x, y)
	
	var screen_x = meters_to_pixels(meters.x)
	var screen_y = (meters_to_pixels(meters.y) * 0.75) - meters_to_pixels(float(z))
	
	return Vector2(screen_x, screen_y)


static func grid_to_screen_centered(
	x: int,
	y: int,
	viewport_center: Vector2,
	z: int = 0
) -> Vector2:
	return viewport_center + grid_to_screen(x, y, z)


static func speed_meters_per_second_to_pixels(meters_per_second: float) -> float:
	return meters_to_pixels(meters_per_second)


static func build_solid_terrain_texture_map() -> Dictionary:
	return {
		TERRAIN_LAND: TerrainTileTextures.create_solid_land_texture(),
		TERRAIN_WATER: TerrainTileTextures.create_solid_water_texture(),
		TERRAIN_MUD: TerrainTileTextures.create_solid_mud_texture(),
	}


static func build_solid_terrain_color_map() -> Dictionary:
	return {
		TERRAIN_LAND: TerrainTileTextures.SOLID_LAND_COLOR,
		TERRAIN_WATER: TerrainTileTextures.SOLID_WATER_COLOR,
		TERRAIN_MUD: TerrainTileTextures.SOLID_MUD_COLOR,
	}


static func compute_neighbor_mismatch_flags(
	grid,
	gx: int,
	gy: int,
	base_type: int
) -> Vector4:
	return Vector4(
		_neighbor_mismatch_flag(grid, gx, gy - 1, base_type),
		_neighbor_mismatch_flag(grid, gx, gy + 1, base_type),
		_neighbor_mismatch_flag(grid, gx + 1, gy, base_type),
		_neighbor_mismatch_flag(grid, gx - 1, gy, base_type)
	)


static func resolve_transition_terrain_type(
	grid,
	gx: int,
	gy: int,
	base_type: int,
	mismatch_flags: Vector4
) -> int:
	var best_type: int = base_type
	var best_priority: int = -1
	var offsets: Array[Vector2i] = [Vector2i(0, -1), Vector2i(0, 1), Vector2i(1, 0), Vector2i(-1, 0)]
	var flags: Array[float] = [
		mismatch_flags.x,
		mismatch_flags.y,
		mismatch_flags.z,
		mismatch_flags.w,
	]

	for i in range(offsets.size()):
		if flags[i] <= 0.0:
			continue
		var offset: Vector2i = offsets[i]
		var neighbor_type: int = grid.GetCellPrimary(gx + offset.x, gy + offset.y)
		var priority: int = _terrain_overlay_priority(neighbor_type)
		if priority > best_priority:
			best_priority = priority
			best_type = neighbor_type

	return best_type


static func find_base_sprite(parent: Node2D, gx: int, gy: int) -> Sprite2D:
	for child in parent.get_children():
		if child is Sprite2D:
			var sprite: Sprite2D = child as Sprite2D
			if not sprite.get_meta("is_transition", false):
				if sprite.get_meta("grid_x") == gx and sprite.get_meta("grid_y") == gy:
					return sprite
	return null


static func remove_transition_sprites(parent: Node2D, gx: int, gy: int) -> void:
	var to_remove: Array[Sprite2D] = []
	for child in parent.get_children():
		if child is Sprite2D:
			var sprite: Sprite2D = child as Sprite2D
			if sprite.get_meta("is_transition", false):
				if sprite.get_meta("grid_x") == gx and sprite.get_meta("grid_y") == gy:
					to_remove.append(sprite)
	for sprite in to_remove:
		sprite.free()


static func spawn_transition_overlay(
	parent: Node2D,
	grid,
	gx: int,
	gy: int,
	local_position: Vector2,
	primary: int,
	color_map: Dictionary,
	noise_mask: Texture2D
) -> void:
	var mismatch_flags: Vector4 = compute_neighbor_mismatch_flags(grid, gx, gy, primary)
	var max_mismatch: float = maxf(
		maxf(mismatch_flags.x, mismatch_flags.y),
		maxf(mismatch_flags.z, mismatch_flags.w)
	)
	if max_mismatch <= 0.0:
		return

	var overlay_type: int = resolve_transition_terrain_type(
		grid, gx, gy, primary, mismatch_flags
	)
	var transition_color: Color = color_map[overlay_type] as Color
	var transition_texture: Texture2D = TerrainTileTextures.create_directional_transition_texture(
		transition_color,
		mismatch_flags,
		noise_mask
	)

	var transition_sprite: Sprite2D = Sprite2D.new()
	transition_sprite.texture = transition_texture
	transition_sprite.centered = true
	transition_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	transition_sprite.z_index = 1
	transition_sprite.set_meta("grid_x", gx)
	transition_sprite.set_meta("grid_y", gy)
	transition_sprite.set_meta("is_transition", true)
	transition_sprite.position = local_position
	parent.add_child(transition_sprite)


static func spawn_cell_visuals(
	parent: Node2D,
	grid,
	gx: int,
	gy: int,
	local_position: Vector2,
	solid_texture_map: Dictionary,
	color_map: Dictionary,
	noise_mask: Texture2D
) -> void:
	var primary: int = grid.GetCellPrimary(gx, gy)

	var base_sprite: Sprite2D = Sprite2D.new()
	base_sprite.texture = solid_texture_map[primary] as Texture2D
	base_sprite.centered = true
	base_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	base_sprite.set_meta("grid_x", gx)
	base_sprite.set_meta("grid_y", gy)
	base_sprite.set_meta("is_transition", false)
	base_sprite.position = local_position
	parent.add_child(base_sprite)

	spawn_transition_overlay(
		parent, grid, gx, gy, local_position, primary, color_map, noise_mask
	)


static func refresh_cell_visuals(
	parent: Node2D,
	grid,
	gx: int,
	gy: int,
	local_position: Vector2,
	solid_texture_map: Dictionary,
	color_map: Dictionary,
	noise_mask: Texture2D
) -> void:
	var primary: int = grid.GetCellPrimary(gx, gy)
	var base_sprite: Sprite2D = find_base_sprite(parent, gx, gy)
	if base_sprite == null:
		spawn_cell_visuals(
			parent, grid, gx, gy, local_position, solid_texture_map, color_map, noise_mask
		)
		return

	base_sprite.texture = solid_texture_map[primary] as Texture2D
	base_sprite.position = local_position
	remove_transition_sprites(parent, gx, gy)
	spawn_transition_overlay(
		parent, grid, gx, gy, local_position, primary, color_map, noise_mask
	)


static func _neighbor_mismatch_flag(
	grid,
	nx: int,
	ny: int,
	base_type: int
) -> float:
	if grid.GetCellPrimary(nx, ny) != base_type:
		return 1.0
	return 0.0


static func _terrain_overlay_priority(terrain_type: int) -> int:
	match terrain_type:
		TERRAIN_WATER:
			return 3
		TERRAIN_MUD:
			return 2
		_:
			return 1