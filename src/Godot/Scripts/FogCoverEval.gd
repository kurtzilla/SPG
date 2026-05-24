class_name FogCoverEval
extends RefCounted

## CPU twin of FogMask.gdshader cover logic (explored mask only).

const ObliqueBridge = preload("res://src/Godot/Scripts/ObliqueBridge.gd")


static func cover_at_world(
	world_m: Vector2,
	_player_world_m: Vector2,
	_sight_radius_m: float,
	_feather_m: float,
	explored_memory,
	_mask_origin_world_m: Vector2,
	_mask_world_size: Vector2
) -> float:
	return clampf(explored_memory.get_hidden_at_world(world_m), 0.0, 1.0)


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
