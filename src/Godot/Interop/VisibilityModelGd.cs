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

	public int GetRevealedCount() => _model.RevealedCount;

	public bool IsRevealed(int x, int y) => _model.IsRevealed(x, y);

	public int GetVisibility(int x, int y) => (int)_model.GetVisibility(x, y);

	public void SetVisibility(int x, int y, int visibility) =>
		_model.SetVisibility(x, y, (CellVisibility)visibility);

	public void RevealCell(int x, int y) => _model.RevealCell(x, y);

	public int RevealDisc(int centerX, int centerY, int radius) =>
		_model.RevealDisc(centerX, centerY, radius);

	/// <summary>Reveals disc in Core and returns newly revealed grid cells.</summary>
	public Array<Vector2I> RevealDiscCollect(int centerX, int centerY, int radius)
	{
		var newly = new System.Collections.Generic.List<(int X, int Y)>();
		_model.RevealDisc(centerX, centerY, radius, newly);
		var result = new Array<Vector2I>();
		foreach (var (x, y) in newly)
		{
			result.Add(new Vector2I(x, y));
		}

		return result;
	}

	public int RevealSquare(int centerX, int centerY, int radius) =>
		_model.RevealSquare(centerX, centerY, radius);

	/// <summary>Reveals square in Core and returns newly revealed grid cells.</summary>
	public Array<Vector2I> RevealSquareCollect(int centerX, int centerY, int radius)
	{
		var newly = new System.Collections.Generic.List<(int X, int Y)>();
		_model.RevealSquare(centerX, centerY, radius, newly);
		var result = new Array<Vector2I>();
		foreach (var (x, y) in newly)
		{
			result.Add(new Vector2I(x, y));
		}

		return result;
	}

	public void ClearAll() => _model.ClearAll();

	public byte[] FillRevealedMask(int originX, int originY, int width, int height)
	{
		var mask = new byte[width * height];
		_model.FillRevealedMask(originX, originY, width, height, mask);
		return mask;
	}

	public byte[] FillRevealedMaskNative(int originX, int originY, int width, int height) =>
		_model.FillRevealedMaskNative(originX, originY, width, height);

	/// <summary>Writes row-major R8 mask into caller buffer (no allocation).</summary>
	public void FillRevealedMaskInto(int originX, int originY, int width, int height, byte[] buffer)
	{
		_model.FillRevealedMask(originX, originY, width, height, buffer);
	}

	/// <summary>Reveals disc in Core and stamps R8 mask into caller buffer (no cell list).</summary>
	public int RevealDiscStampInto(
		int originX,
		int originY,
		int width,
		int height,
		int centerX,
		int centerY,
		int radius,
		byte[] buffer) =>
		_model.RevealDiscStampInto(originX, originY, width, height, centerX, centerY, radius, buffer);

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
