extends RefCounted

## Shared view-layer metric constants (no script dependencies).
## Must match SPG.Core.GridMath.MetersPerCell (2.0). ObliqueBridge/ViewTransforms re-export these.

const PIXELS_PER_METER: int = 32
const METERS_PER_CELL: float = 2.0
const CELL_SIZE_PX: int = PIXELS_PER_METER * int(METERS_PER_CELL)
