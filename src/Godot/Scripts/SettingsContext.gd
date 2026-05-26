class_name SettingsContext
extends RefCounted

## Settings scope for persistence and future per-context overrides.

enum Context { GAME, MAP, PLAYER }


static func from_string(name: String) -> Context:
	match name.to_lower():
		"map":
			return Context.MAP
		"player":
			return Context.PLAYER
		_:
			return Context.GAME


static func to_section_name(ctx: Context) -> String:
	match ctx:
		Context.MAP:
			return "map"
		Context.PLAYER:
			return "player"
		_:
			return "game"
