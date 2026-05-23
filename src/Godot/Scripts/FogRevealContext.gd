class_name FogRevealContext
extends RefCounted

## World-space reveal state shared by fog, terrain, and grid (no Core cell discs).

var fog_enabled: bool = false
var player_world_m: Vector2 = Vector2.ZERO
var live_radius_m: float = 0.0
var explored_memory = null


static func disabled() -> FogRevealContext:
	return FogRevealContext.new()


static func from_overlay(fog_overlay: Sprite2D, fog_enabled: bool) -> FogRevealContext:
	var ctx := FogRevealContext.new()
	ctx.fog_enabled = fog_enabled
	if not fog_enabled or fog_overlay == null:
		return ctx
	ctx.player_world_m = fog_overlay.get_player_world_m()
	ctx.live_radius_m = fog_overlay.get_live_radius_m()
	ctx.explored_memory = fog_overlay.get_explored_memory()
	return ctx
