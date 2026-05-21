using Godot;
using Godot.Collections;
using SPG.Core;

namespace SPG.Interop;

[GlobalClass]
public partial class GridModelGd : RefCounted
{
	private readonly GridModel _model = new();

	internal GridModel Model => _model;

	public bool IsInBounds(int x, int y) => _model.IsInBounds(x, y);

	public int GetCellPrimary(int x, int y) => (int)_model.GetCellPrimary(x, y);

	public Dictionary GetCellComposition(int x, int y)
	{
		var composition = _model.GetCellComposition(x, y);
		var result = new Dictionary();
		foreach (var pair in composition)
		{
			result[(int)pair.Key] = pair.Value;
		}

		return result;
	}

	public void SetCellTerrain(int x, int y, int primary, Dictionary composition)
	{
		var parsed = new System.Collections.Generic.Dictionary<TerrainType, float>();
		foreach (Variant key in composition.Keys)
		{
			int terrainKey = key.AsInt32();
			parsed[(TerrainType)terrainKey] = composition[key].AsSingle();
		}

		_model.SetCellTerrain(x, y, (TerrainType)primary, parsed);
	}

	public void ClearGrid() => _model.ClearGrid();
}
