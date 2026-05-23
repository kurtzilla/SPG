namespace SPG.Core;

/// <summary>
/// Grid-index utilities in Core space. MetersPerCell must match ViewMetrics.METERS_PER_CELL in Godot.
/// </summary>
public static class GridMath
{
	public const float MetersPerCell = 2.0f;

	public static readonly (int dx, int dy)[] Neighbor4 =
	{
		(0, -1),
		(0, 1),
		(1, 0),
		(-1, 0),
	};

	public static readonly (int dx, int dy)[] Neighbor8 =
	{
		(0, -1),
		(0, 1),
		(1, 0),
		(-1, 0),
		(1, -1),
		(1, 1),
		(-1, -1),
		(-1, 1),
	};

	public static (int gx, int gy) FloorToCell(float worldX, float worldY) =>
		((int)MathF.Floor(worldX / MetersPerCell), (int)MathF.Floor(worldY / MetersPerCell));

	public static (float x, float y) CellCenter(int gx, int gy) =>
		(gx + 0.5f, gy + 0.5f);

	public static (float x, float y) CellCornerWorldM(int gx, int gy) =>
		(gx * MetersPerCell, gy * MetersPerCell);

	public static (float x, float y) CellCenterWorldM(int gx, int gy)
	{
		var (cx, cy) = CellCenter(gx, gy);
		return (cx * MetersPerCell, cy * MetersPerCell);
	}

	public static (float minX, float minY, float maxX, float maxY) CellAabbWorldM(int gx, int gy)
	{
		var (minX, minY) = CellCornerWorldM(gx, gy);
		return (minX, minY, minX + MetersPerCell, minY + MetersPerCell);
	}

	public static int Manhattan(int ax, int ay, int bx, int by) =>
		Math.Abs(ax - bx) + Math.Abs(ay - by);

	public static int Chebyshev(int ax, int ay, int bx, int by) =>
		Math.Max(Math.Abs(ax - bx), Math.Abs(ay - by));

	public static float EuclideanSquared(int ax, int ay, int bx, int by)
	{
		float dx = ax - bx;
		float dy = ay - by;
		return dx * dx + dy * dy;
	}
}
