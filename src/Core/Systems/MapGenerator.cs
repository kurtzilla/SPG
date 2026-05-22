namespace SPG.Core;

/// <summary>
/// Deterministic procedural terrain for GridModel. Pure Core — no Godot types.
/// </summary>
public sealed class MapGenerator
{
	public const float BlockedThreshold = 0.62f;
	public const int SafeZoneRadius = 2;
	public const int SpawnSafeZoneX = 0;
	public const int SpawnSafeZoneY = 0;

	private readonly int _seed;

	public MapGenerator(int seed) => _seed = seed;

	/// <summary>
	/// Fills every cell where max(|x - centerX|, |y - centerY|) &lt;= radius (inclusive patch).
	/// </summary>
	public void GenerateRegion(GridModel grid, int centerX, int centerY, int radius)
	{
		int minX = centerX - radius;
		int maxX = centerX + radius;
		int minY = centerY - radius;
		int maxY = centerY + radius;

		for (int gx = minX; gx <= maxX; gx++)
		{
			for (int gy = minY; gy <= maxY; gy++)
			{
				CellTerrain terrain = GetCellTerrainForCoord(gx, gy);
				grid.SetCellTerrain(gx, gy, terrain.PrimaryType, terrain.Composition);
			}
		}
	}

	public CellTerrain GetCellTerrainForCoord(int x, int y)
	{
		int dx = Math.Abs(x - SpawnSafeZoneX);
		int dy = Math.Abs(y - SpawnSafeZoneY);
		if (Math.Max(dx, dy) <= SafeZoneRadius)
		{
			return SolidTerrain(TerrainType.Land);
		}

		if (Noise01(x, y) >= BlockedThreshold)
		{
			return SolidTerrain(TerrainType.Water);
		}

		return SolidTerrain(TerrainType.Land);
	}

	private static CellTerrain SolidTerrain(TerrainType type) =>
		new(type, new Dictionary<TerrainType, float> { [type] = 1.0f });

	private float Noise01(int x, int y)
	{
		float n0 = Hash01(x, y);
		float n1 = Hash01(x * 2, y * 2) * 0.5f;
		float n2 = Hash01(x * 4, y * 4) * 0.25f;
		return (n0 + n1 + n2) / 1.75f;
	}

	private float Hash01(int x, int y)
	{
		int n = _seed;
		n = (n ^ (x * 374761393)) & 0x7FFFFFFF;
		n = (n ^ (y * 668265263)) & 0x7FFFFFFF;
		n = (n ^ (n >> 13)) * 1274126177;
		n = (n ^ (n >> 16)) & 0x7FFFFFFF;
		return n / 2147483647f;
	}

	public readonly struct CellTerrain
	{
		public TerrainType PrimaryType { get; init; }
		public Dictionary<TerrainType, float> Composition { get; init; }

		public CellTerrain(TerrainType primaryType, Dictionary<TerrainType, float> composition)
		{
			PrimaryType = primaryType;
			Composition = composition;
		}
	}
}
