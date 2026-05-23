class_name FogCoverEval
extends RefCounted

## CPU twin of FogMask.gdshader cover logic (explored trail + live feather).

const ObliqueBridge = preload("res://src/Godot/Scripts/ObliqueBridge.gd")


static func cover_at_world(
	world_m: Vector2,
	player_world_m: Vector2,
	sight_radius_m: float,
	feather_m: float,
	explored_memory,
	mask_origin_world_m: Vector2,
	mask_world_size: Vector2
) -> float:
	var hidden: float = explored_memory.get_hidden_at_world(world_m)
	var dist_m: float = world_m.distance_to(player_world_m)
	var live: float = smoothstep(sight_radius_m, sight_radius_m - feather_m, dist_m)
	var reveal: float = maxf(live, 1.0 - hidden)
	return clampf(1.0 - reveal, 0.0, 1.0)


static func _sample_explored_hidden(
	world_m: Vector2,
	explored_memory,
	_mask_origin_world_m: Vector2,
	_mask_world_size: Vector2
) -> float:
	if explored_memory == null:
		return 1.0
	if explored_memory.has_method("get_hidden_at_world"):
		return explored_memory.get_hidden_at_world(world_m)
	return 1.0
