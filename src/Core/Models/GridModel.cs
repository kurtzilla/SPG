namespace SPG.Core;

public sealed class GridModel
{
	private readonly Dictionary<string, CellRecord> _cells = new();

	public bool IsInBounds(int x, int y) => true;

	public TerrainType GetCellPrimary(int x, int y)
	{
		if (_cells.TryGetValue(MakeKey(x, y), out CellRecord? cell))
		{
			return cell.PrimaryType;
		}

		return TerrainType.Land;
	}

	public Dictionary<TerrainType, float> GetCellComposition(int x, int y)
	{
		if (_cells.TryGetValue(MakeKey(x, y), out CellRecord? cell))
		{
			return new Dictionary<TerrainType, float>(cell.Composition);
		}

		return DefaultComposition();
	}

	public void SetCellTerrain(
		int x,
		int y,
		TerrainType primary,
		Dictionary<TerrainType, float> composition)
	{
		_cells[MakeKey(x, y)] = new CellRecord
		{
			PrimaryType = primary,
			Composition = new Dictionary<TerrainType, float>(composition),
		};
	}

	public void ClearGrid() => _cells.Clear();

	private static Dictionary<TerrainType, float> DefaultComposition() =>
		new() { [TerrainType.Land] = 1.0f };

	private static string MakeKey(int x, int y) => $"{x},{y}";

	private sealed class CellRecord
	{
		public TerrainType PrimaryType { get; init; } = TerrainType.Land;
		public Dictionary<TerrainType, float> Composition { get; init; } = new();
	}
}
