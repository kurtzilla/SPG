class_name ChunkLoadJob
extends RefCounted

## Per-chunk async load state for ChunkManager's cooperative queue.

enum Phase { WAIT_TREE, GENERATE, PAINT, DONE }

var coord: Vector2i
var phase: Phase = Phase.WAIT_TREE
var layer: TileMapLayer
var data: ChunkData
var origin: Vector2i
var cell_index: int = 0
## Movement axis when PAINT started; drives leading-edge scan order.
var paint_axis: Vector2i = Vector2i.ZERO
var cells_painted: int = 0
var layer_shown: bool = false
var skip_safe_zone: bool = false
## Chunk AABB is fully inside spawn safe zone — fill LAND without noise.
var fill_land: bool = false
