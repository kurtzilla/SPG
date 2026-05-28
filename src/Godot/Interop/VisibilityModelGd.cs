using Godot;
using Godot.Collections;
using SPG.Core;

namespace SPG.Interop;

[GlobalClass]
public partial class VisibilityModelGd : RefCounted
{
	private readonly VisibilityModel _model = new();

	internal VisibilityModel Model => _model;

	public int InitialRevealRadius
	{
		get => _model.InitialRevealRadius;
		set => _model.InitialRevealRadius = value;
	}

	public int MovementRevealRadius
	{
		get => _model.MovementRevealRadius;
		set => _model.MovementRevealRadius = value;
	}

	public bool IsRevealed(int x, int y) => _model.IsRevealed(x, y);

	public int GetVisibility(int x, int y) => (int)_model.GetVisibility(x, y);

	public void SetVisibility(int x, int y, int visibility) =>
		_model.SetVisibility(x, y, (CellVisibility)visibility);

	public void RevealCell(int x, int y) => _model.RevealCell(x, y);

	public int RevealDisc(int centerX, int centerY, int radius) =>
		_model.RevealDisc(centerX, centerY, radius);

	public void ClearAll() => _model.ClearAll();

	public byte[] FillRevealedMask(int originX, int originY, int width, int height)
	{
		var mask = new byte[width * height];
		_model.FillRevealedMask(originX, originY, width, height, mask);
		return mask;
	}

	public bool TryGetRevealedBounds(out int minX, out int minY, out int maxX, out int maxY)
	{
		if (_model.TryGetRevealedBounds(out RevealedBounds bounds))
		{
			minX = bounds.MinX;
			minY = bounds.MinY;
			maxX = bounds.MaxX;
			maxY = bounds.MaxY;
			return true;
		}

		minX = minY = maxX = maxY = 0;
		return false;
	}

	/// <summary>GDScript-friendly bounds: [minX, minY, maxX, maxY] or empty if none.</summary>
	public Array<int> GetRevealedBounds()
	{
		var result = new Array<int>();
		if (_model.TryGetRevealedBounds(out RevealedBounds bounds))
		{
			result.Add(bounds.MinX);
			result.Add(bounds.MinY);
			result.Add(bounds.MaxX);
			result.Add(bounds.MaxY);
		}

		return result;
	}

}
