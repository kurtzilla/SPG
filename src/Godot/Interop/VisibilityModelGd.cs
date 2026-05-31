using Godot;
using Godot.Collections;
using SPG.Core;

namespace SPG.Interop;

/// <summary>
/// Godot wrapper for <see cref="VisibilityModel"/>.
/// Mask stamps: GDScript PackedByteArray is not updated by *StampInto(byte[]) — use *StampNative return paths.
/// See src/Godot/Interop/INTEROP.md — caller-owned buffer rules and *Native naming.
/// </summary>
[GlobalClass]
public partial class VisibilityModelGd : RefCounted
{
	private readonly VisibilityModel _model = new();
	private int _lastHoleFillCount;

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

	public float RevealStampFeatherCells
	{
		get => _model.RevealStampFeatherCells;
		set => _model.RevealStampFeatherCells = value;
	}

	public int GetRevealedCount() => _model.RevealedCount;

	public int GetLastHoleFillCount() => _lastHoleFillCount;

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

	public int RevealRoundedSquare(int centerX, int centerY, int radius, int cornerRadius) =>
		_model.RevealRoundedSquare(centerX, centerY, radius, cornerRadius);

	/// <summary>Reveals rounded square in Core and stamps R8 mask into caller buffer (no cell list).</summary>
	public int RevealRoundedSquareStampInto(
		int originX,
		int originY,
		int width,
		int height,
		int centerX,
		int centerY,
		int radius,
		int cornerRadius,
		byte[] buffer) =>
		_model.RevealRoundedSquareStampInto(
			originX, originY, width, height, centerX, centerY, radius, cornerRadius, buffer);

	/// <summary>Stamps rounded square and returns the modified mask buffer for GDScript assignment.</summary>
	public byte[] RevealRoundedSquareStampNative(
		int originX,
		int originY,
		int width,
		int height,
		int centerX,
		int centerY,
		int radius,
		int cornerRadius,
		byte[] buffer)
	{
		_model.RevealRoundedSquareStampInto(
			originX, originY, width, height, centerX, centerY, radius, cornerRadius, buffer);
		return buffer;
	}

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

	/// <summary>Fills explored cells where mask texel is 0 after buffer shift; returns caller buffer.</summary>
	public byte[] FillRevealedHolesInWindowNative(
		int originX,
		int originY,
		int width,
		int height,
		byte[] buffer)
	{
		_lastHoleFillCount = _model.FillRevealedHolesInWindow(originX, originY, width, height, buffer);
		return buffer;
	}

	/// <summary>Strip-scoped hole fill after buffer shift; binary 255 in incoming strips + graded edge bands.</summary>
	public byte[] FillRevealedHolesAfterShiftNative(
		int originX,
		int originY,
		int width,
		int height,
		int shiftDeltaX,
		int shiftDeltaY,
		int edgeBandCells,
		byte[] buffer)
	{
		_lastHoleFillCount = _model.FillRevealedHolesInWindow(
			originX,
			originY,
			width,
			height,
			buffer,
			shiftDeltaX,
			shiftDeltaY,
			edgeBandCells);
		return buffer;
	}

	/// <summary>Restores graded mask texels for explored cells after buffer shift; returns caller buffer.</summary>
	public byte[] RefreshPresentationGradientsNative(
		int originX,
		int originY,
		int width,
		int height,
		float playerCenterCellX,
		float playerCenterCellY,
		int movementRadius,
		int initialCenterX,
		int initialCenterY,
		int initialRadius,
		int initialCornerRadius,
		byte[] buffer)
	{
		_model.RefreshPresentationGradientsInWindow(
			originX,
			originY,
			width,
			height,
			playerCenterCellX,
			playerCenterCellY,
			movementRadius,
			initialCenterX,
			initialCenterY,
			initialRadius,
			initialCornerRadius,
			buffer);
		return buffer;
	}

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

	/// <summary>Reveals disc at fractional cell-space center and stamps R8 mask into caller buffer.</summary>
	public int RevealDiscStampInto(
		int originX,
		int originY,
		int width,
		int height,
		float centerCellX,
		float centerCellY,
		int radius,
		byte[] buffer) =>
		_model.RevealDiscStampInto(
			originX, originY, width, height, centerCellX, centerCellY, radius, buffer);

	/// <summary>Stamps disc and returns the modified mask buffer for GDScript assignment.</summary>
	public byte[] RevealDiscStampNative(
		int originX,
		int originY,
		int width,
		int height,
		float centerCellX,
		float centerCellY,
		int radius,
		byte[] buffer)
	{
		_model.RevealDiscStampInto(
			originX, originY, width, height, centerCellX, centerCellY, radius, buffer);
		return buffer;
	}

	/// <summary>Stamps discs along a grid segment into the mask buffer (single interop).</summary>
	public int RevealDiscPathStampInto(
		int originX,
		int originY,
		int width,
		int height,
		int fromX,
		int fromY,
		int toX,
		int toY,
		int radius,
		byte[] buffer) =>
		_model.RevealDiscPathStampInto(
			originX, originY, width, height, fromX, fromY, toX, toY, radius, buffer);

	/// <summary>Stamps discs along a segment using fractional cell-space centers.</summary>
	public int RevealDiscPathStampInto(
		int originX,
		int originY,
		int width,
		int height,
		float fromCenterCellX,
		float fromCenterCellY,
		float toCenterCellX,
		float toCenterCellY,
		int radius,
		byte[] buffer) =>
		_model.RevealDiscPathStampInto(
			originX,
			originY,
			width,
			height,
			fromCenterCellX,
			fromCenterCellY,
			toCenterCellX,
			toCenterCellY,
			radius,
			buffer);

	/// <summary>Stamps path and returns the modified mask buffer for GDScript assignment.</summary>
	public byte[] RevealDiscPathStampNative(
		int originX,
		int originY,
		int width,
		int height,
		float fromCenterCellX,
		float fromCenterCellY,
		float toCenterCellX,
		float toCenterCellY,
		int radius,
		byte[] buffer)
	{
		_model.RevealDiscCapsuleStampInto(
			originX,
			originY,
			width,
			height,
			fromCenterCellX,
			fromCenterCellY,
			toCenterCellX,
			toCenterCellY,
			radius,
			buffer);
		return buffer;
	}

	/// <summary>Single-pass capsule stamp along a segment; returns mask for GDScript assignment.</summary>
	public byte[] RevealDiscCapsuleStampNative(
		int originX,
		int originY,
		int width,
		int height,
		float fromCenterCellX,
		float fromCenterCellY,
		float toCenterCellX,
		float toCenterCellY,
		int radius,
		byte[] buffer)
	{
		_model.RevealDiscCapsuleStampInto(
			originX,
			originY,
			width,
			height,
			fromCenterCellX,
			fromCenterCellY,
			toCenterCellX,
			toCenterCellY,
			radius,
			buffer);
		return buffer;
	}

	/// <summary>REVISIT: dormant — enclosed-pocket auto-reveal removed from Godot hot path.</summary>
	public int FillSmallEnclosedHolesInWindow(
		int originX,
		int originY,
		int width,
		int height,
		int maxHoleCells) =>
		_model.FillSmallEnclosedHolesInWindow(originX, originY, width, height, maxHoleCells);

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
