class_name ViewMetrics
extends RefCounted

## Shared view-layer metric constants (no script dependencies).
## Values are snapshotted from Settings at startup; scale changes require restart.
## Must match SPG.Core.GridMath.MetersPerCell (1.0).

static var PIXELS_PER_METER: int = 64
static var METERS_PER_CELL: float = 1.0
static var CELL_SIZE_PX: int = 64


static func apply_scale(pixels_per_meter: int, meters_per_cell: float) -> void:
	PIXELS_PER_METER = maxi(pixels_per_meter, 1)
	METERS_PER_CELL = maxf(meters_per_cell, 0.001)
	CELL_SIZE_PX = PIXELS_PER_METER * int(METERS_PER_CELL)
