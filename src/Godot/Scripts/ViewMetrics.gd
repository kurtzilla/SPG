extends RefCounted

## Shared view-layer metric constants (no script dependencies).
## ObliqueBridge re-exports these; texture generators read CELL_SIZE_PX from here.

const PIXELS_PER_METER: int = 32
const METERS_PER_CELL: float = 2.0
const CELL_SIZE_PX: int = PIXELS_PER_METER * int(METERS_PER_CELL)
