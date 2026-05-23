using Godot;
using SPG.Core;

namespace SPG.Interop;

/// <summary>
/// Exposes Core grid math to GDScript for cross-layer rules (not per-frame hot paths).
/// </summary>
[GlobalClass]
public partial class GridMathGd : RefCounted
{
	public float MetersPerCell => GridMath.MetersPerCell;

	public Vector2 CellCenter(int gx, int gy)
	{
		var (x, y) = GridMath.CellCenterWorldM(gx, gy);
		return new Vector2(x, y);
	}

	public Vector2 CellCornerWorldM(int gx, int gy)
	{
		var (x, y) = GridMath.CellCornerWorldM(gx, gy);
		return new Vector2(x, y);
	}

	public Vector2I FloorToCell(float worldX, float worldY)
	{
		var (gx, gy) = GridMath.FloorToCell(worldX, worldY);
		return new Vector2I(gx, gy);
	}

	public int Manhattan(int ax, int ay, int bx, int by) =>
		GridMath.Manhattan(ax, ay, bx, by);

	public int Chebyshev(int ax, int ay, int bx, int by) =>
		GridMath.Chebyshev(ax, ay, bx, by);
}
