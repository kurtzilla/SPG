namespace SPG.Core;

public readonly struct RevealedBounds
{
	public int MinX { get; }
	public int MinY { get; }
	public int MaxX { get; }
	public int MaxY { get; }

	public RevealedBounds(int minX, int minY, int maxX, int maxY)
	{
		MinX = minX;
		MinY = minY;
		MaxX = maxX;
		MaxY = maxY;
	}
}

public sealed class VisibilityModel
{
	// Must match game_settings.json fog.initial_reveal_radius min / max clamp range.
	public const int RadiusMin = 1;
	public const int RadiusMax = 256;
	// Must match game_settings.json fog.initial_reveal_radius default.
	public const int DefaultInitialRevealRadius = 20;
	// Fixed movement reveal radius (cells); not exposed in settings UI.
	public const int DefaultMovementRevealRadius = 14;

	private const float RevealRadiusScaleMin = 0.25f;
	private const float RevealRadiusScaleMax = 4f;

	private readonly HashSet<long> _revealed = new();

	private float _revealRadiusScaleX = 1f;
	private float _revealRadiusScaleY = 1f;

	private bool _hasRevealedBounds;
	private int _revealedMinX;
	private int _revealedMaxX;
	private int _revealedMinY;
	private int _revealedMaxY;

	public float RevealRadiusScaleX
	{
		get => _revealRadiusScaleX;
		set => _revealRadiusScaleX = ClampRevealRadiusScale(value);
	}

	public float RevealRadiusScaleY
	{
		get => _revealRadiusScaleY;
		set => _revealRadiusScaleY = ClampRevealRadiusScale(value);
	}

	public int InitialRevealRadius
	{
		get => _initialRevealRadius;
		set => _initialRevealRadius = ClampRadius(value);
	}

	public int MovementRevealRadius
	{
		get => _movementRevealRadius;
		set => _movementRevealRadius = ClampRadius(value);
	}

	private int _initialRevealRadius = DefaultInitialRevealRadius;
	private int _movementRevealRadius = DefaultMovementRevealRadius;
	private float _revealStampFeatherCells = 1.25f;

	/// <summary>
	/// Soft edge width (in cells) baked into mask stamps. Set from Godot <c>edge_feather_px / cell_size</c>.
	/// </summary>
	public float RevealStampFeatherCells
	{
		get => _revealStampFeatherCells;
		set => _revealStampFeatherCells = Math.Max(value, 0f);
	}

	public int RevealedCount => _revealed.Count;

	public bool IsRevealed(int x, int y) => _revealed.Contains(MakeKey(x, y));

	public CellVisibility GetVisibility(int x, int y) =>
		IsRevealed(x, y) ? CellVisibility.Revealed : CellVisibility.Hidden;

	public void SetVisibility(int x, int y, CellVisibility visibility)
	{
		long key = MakeKey(x, y);
		if (visibility == CellVisibility.Revealed)
		{
			if (_revealed.Add(key))
			{
				ExpandRevealedBounds(x, y);
			}

			return;
		}

		if (_revealed.Remove(key))
		{
			// Bounds are not shrunk on hide; callers use ClearAll for full reset.
		}
	}

	public void RevealCell(int x, int y) => RevealCell(x, y, null);

	/// <summary>
	/// Marks a cell revealed. When <paramref name="newlyRevealed"/> is non-null, appends the cell if it was hidden.
	/// </summary>
	public bool RevealCell(int x, int y, List<(int X, int Y)>? newlyRevealed)
	{
		long key = MakeKey(x, y);
		if (!_revealed.Add(key))
		{
			return false;
		}

		ExpandRevealedBounds(x, y);
		newlyRevealed?.Add((x, y));
		return true;
	}

	public int RevealDisc(int centerX, int centerY, int radius) =>
		RevealDisc(centerX, centerY, radius, null);

	/// <summary>
	/// Reveals cells inside the scaled ellipse. Returns count of newly revealed cells.
	/// </summary>
	public int RevealDisc(int centerX, int centerY, int radius, List<(int X, int Y)>? newlyRevealed)
	{
		int clampedRadius = ClampRadius(radius);
		int minX = centerX - clampedRadius;
		int maxX = centerX + clampedRadius;
		int minY = centerY - clampedRadius;
		int maxY = centerY + clampedRadius;
		int count = 0;

		for (int gx = minX; gx <= maxX; gx++)
		{
			for (int gy = minY; gy <= maxY; gy++)
			{
				if (!IsInsideRevealEllipse(gx, gy, centerX + 0.5f, centerY + 0.5f, clampedRadius))
				{
					continue;
				}

				if (RevealCell(gx, gy, newlyRevealed))
				{
					count++;
				}
			}
		}

		return count;
	}

	public int RevealSquare(int centerX, int centerY, int radius) =>
		RevealSquare(centerX, centerY, radius, null);

	/// <summary>
	/// Reveals cells inside an axis-aligned square. Returns count of newly revealed cells.
	/// </summary>
	public int RevealSquare(int centerX, int centerY, int radius, List<(int X, int Y)>? newlyRevealed)
	{
		int clampedRadius = ClampRadius(radius);
		int minX = centerX - clampedRadius;
		int maxX = centerX + clampedRadius;
		int minY = centerY - clampedRadius;
		int maxY = centerY + clampedRadius;
		int count = 0;

		for (int gx = minX; gx <= maxX; gx++)
		{
			for (int gy = minY; gy <= maxY; gy++)
			{
				if (RevealCell(gx, gy, newlyRevealed))
				{
					count++;
				}
			}
		}

		return count;
	}

	public int RevealRoundedSquare(int centerX, int centerY, int radius, int cornerRadius) =>
		RevealRoundedSquare(centerX, centerY, radius, cornerRadius, null);

	/// <summary>
	/// Reveals cells inside a rounded axis-aligned square. Returns count of newly revealed cells.
	/// </summary>
	public int RevealRoundedSquare(
		int centerX,
		int centerY,
		int radius,
		int cornerRadius,
		List<(int X, int Y)>? newlyRevealed)
	{
		int clampedRadius = ClampRadius(radius);
		int clampedCorner = Math.Clamp(cornerRadius, 0, clampedRadius);
		float centerPxX = centerX + 0.5f;
		float centerPxY = centerY + 0.5f;
		float halfExtent = clampedRadius + 0.5f;
		int minX = centerX - clampedRadius;
		int maxX = centerX + clampedRadius;
		int minY = centerY - clampedRadius;
		int maxY = centerY + clampedRadius;
		int count = 0;

		for (int gx = minX; gx <= maxX; gx++)
		{
			for (int gy = minY; gy <= maxY; gy++)
			{
				if (!CellIntersectsRoundedSquare(gx, gy, centerPxX, centerPxY, halfExtent, clampedCorner))
				{
					continue;
				}

				if (RevealCell(gx, gy, newlyRevealed))
				{
					count++;
				}
			}
		}

		return count;
	}

	/// <summary>
	/// Reveals a rounded square in Core and stamps 255 into <paramref name="outMask"/> for cells inside the window.
	/// </summary>
	public int RevealRoundedSquareStampInto(
		int originX,
		int originY,
		int width,
		int height,
		int centerX,
		int centerY,
		int radius,
		int cornerRadius,
		Span<byte> outMask)
	{
		int area = width * height;
		if (outMask.Length < area)
		{
			throw new ArgumentException("Mask buffer is too small.", nameof(outMask));
		}

		int clampedRadius = ClampRadius(radius);
		int clampedCorner = Math.Clamp(cornerRadius, 0, clampedRadius);
		int featherPad = (int)MathF.Ceiling(_revealStampFeatherCells);
		float centerPxX = centerX + 0.5f;
		float centerPxY = centerY + 0.5f;
		float halfExtent = clampedRadius + 0.5f;
		int minX = centerX - clampedRadius - featherPad;
		int maxX = centerX + clampedRadius + featherPad;
		int minY = centerY - clampedRadius - featherPad;
		int maxY = centerY + clampedRadius + featherPad;
		int maxOriginX = originX + width - 1;
		int maxOriginY = originY + height - 1;
		int count = 0;

		for (int gx = minX; gx <= maxX; gx++)
		{
			for (int gy = minY; gy <= maxY; gy++)
			{
				float strength = ComputeRoundedSquareRevealStrength(
					gx,
					gy,
					centerPxX,
					centerPxY,
					halfExtent,
					clampedCorner,
					_revealStampFeatherCells);
				if (strength <= 0f)
				{
					continue;
				}

				if (RevealCell(gx, gy, null))
				{
					count++;
				}

				if (gx < originX || gx > maxOriginX || gy < originY || gy > maxOriginY)
				{
					continue;
				}

				int localX = gx - originX;
				int localY = gy - originY;
				StampMaskMax(outMask, localY * width + localX, strength);
			}
		}

		return count;
	}

	/// <summary>
	/// Reveals an ellipse and stamps 255 into <paramref name="outMask"/> for cells inside the window.
	/// Avoids allocating a newly-revealed cell list for presentation updates.
	/// </summary>
	public int RevealDiscStampInto(
		int originX,
		int originY,
		int width,
		int height,
		int centerX,
		int centerY,
		int radius,
		Span<byte> outMask) =>
		RevealDiscStampInto(
			originX,
			originY,
			width,
			height,
			centerX + 0.5f,
			centerY + 0.5f,
			radius,
			outMask);

	/// <summary>
	/// Reveals an ellipse centered at fractional cell coordinates and stamps the mask window.
	/// </summary>
	public int RevealDiscStampInto(
		int originX,
		int originY,
		int width,
		int height,
		float centerCellX,
		float centerCellY,
		int radius,
		Span<byte> outMask)
	{
		int area = width * height;
		if (outMask.Length < area)
		{
			throw new ArgumentException("Mask buffer is too small.", nameof(outMask));
		}

		int clampedRadius = ClampRadius(radius);
		int featherPad = (int)MathF.Ceiling(_revealStampFeatherCells);
		int minX = (int)MathF.Floor(centerCellX - clampedRadius - featherPad);
		int maxX = (int)MathF.Ceiling(centerCellX + clampedRadius + featherPad);
		int minY = (int)MathF.Floor(centerCellY - clampedRadius - featherPad);
		int maxY = (int)MathF.Ceiling(centerCellY + clampedRadius + featherPad);
		int maxOriginX = originX + width - 1;
		int maxOriginY = originY + height - 1;
		int count = 0;

		for (int gx = minX; gx <= maxX; gx++)
		{
			for (int gy = minY; gy <= maxY; gy++)
			{
				float strength = ComputeEllipseRevealStrength(
					gx,
					gy,
					centerCellX,
					centerCellY,
					clampedRadius,
					_revealStampFeatherCells);
				if (strength <= 0f)
				{
					continue;
				}

				if (RevealCell(gx, gy, null))
				{
					count++;
				}

				if (gx < originX || gx > maxOriginX || gy < originY || gy > maxOriginY)
				{
					continue;
				}

				int localX = gx - originX;
				int localY = gy - originY;
				StampMaskMax(outMask, localY * width + localX, strength);
			}
		}

		return count;
	}

	/// <summary>
	/// Stamps discs along a Bresenham segment (inclusive). One interop call for movement reveals.
	/// </summary>
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
		Span<byte> outMask) =>
		RevealDiscPathStampInto(
			originX,
			originY,
			width,
			height,
			fromX + 0.5f,
			fromY + 0.5f,
			toX + 0.5f,
			toY + 0.5f,
			radius,
			outMask);

	/// <summary>
	/// Stamps discs along a Bresenham segment using fractional cell-space centers at each stamp.
	/// </summary>
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
		Span<byte> outMask) =>
		RevealDiscCapsuleStampInto(
			originX,
			originY,
			width,
			height,
			fromCenterCellX,
			fromCenterCellY,
			toCenterCellX,
			toCenterCellY,
			radius,
			outMask);

	/// <summary>
	/// Single-pass capsule stamp along a segment (replaces per-node disc loops on long paths).
	/// </summary>
	public int RevealDiscCapsuleStampInto(
		int originX,
		int originY,
		int width,
		int height,
		float fromCenterCellX,
		float fromCenterCellY,
		float toCenterCellX,
		float toCenterCellY,
		int radius,
		Span<byte> outMask)
	{
		int area = width * height;
		if (outMask.Length < area)
		{
			throw new ArgumentException("Mask buffer is too small.", nameof(outMask));
		}

		int clampedRadius = ClampRadius(radius);
		int featherPad = (int)MathF.Ceiling(_revealStampFeatherCells);
		float pad = clampedRadius + featherPad + 1f;
		float segMinX = MathF.Min(fromCenterCellX, toCenterCellX) - pad;
		float segMaxX = MathF.Max(fromCenterCellX, toCenterCellX) + pad;
		float segMinY = MathF.Min(fromCenterCellY, toCenterCellY) - pad;
		float segMaxY = MathF.Max(fromCenterCellY, toCenterCellY) + pad;
		int minX = (int)MathF.Floor(segMinX);
		int maxX = (int)MathF.Ceiling(segMaxX);
		int minY = (int)MathF.Floor(segMinY);
		int maxY = (int)MathF.Ceiling(segMaxY);
		int maxOriginX = originX + width - 1;
		int maxOriginY = originY + height - 1;
		int count = 0;

		for (int gx = minX; gx <= maxX; gx++)
		{
			for (int gy = minY; gy <= maxY; gy++)
			{
				float strength = ComputeCapsuleRevealStrength(
					gx,
					gy,
					fromCenterCellX,
					fromCenterCellY,
					toCenterCellX,
					toCenterCellY,
					clampedRadius,
					_revealStampFeatherCells);
				if (strength <= 0f)
				{
					continue;
				}

				if (RevealCell(gx, gy, null))
				{
					count++;
				}

				if (gx < originX || gx > maxOriginX || gy < originY || gy > maxOriginY)
				{
					continue;
				}

				int localX = gx - originX;
				int localY = gy - originY;
				StampMaskMax(outMask, localY * width + localX, strength);
			}
		}

		return count;
	}

	private float ComputeCapsuleRevealStrength(
		int gx,
		int gy,
		float fromCenterCellX,
		float fromCenterCellY,
		float toCenterCellX,
		float toCenterCellY,
		int radius,
		float featherCells)
	{
		int clampedRadius = ClampRadius(radius);
		float cellCenterX = gx + 0.5f;
		float cellCenterY = gy + 0.5f;
		ClosestPointOnSegment(
			cellCenterX,
			cellCenterY,
			fromCenterCellX,
			fromCenterCellY,
			toCenterCellX,
			toCenterCellY,
			out float rejectClosestX,
			out float rejectClosestY);
		float featherNorm = featherCells / clampedRadius;
		float outer = 1f + featherNorm;
		float dist = ComputeEllipseRevealDistanceAtPx(
			cellCenterX,
			cellCenterY,
			rejectClosestX,
			rejectClosestY,
			clampedRadius);
		if (dist > outer + 0.866f)
		{
			return 0f;
		}

		int samples = DiscStampSubcellSamples;
		float invSamples = 1f / samples;
		float sumStrength = 0f;
		int sampleCount = samples * samples;

		for (int sy = 0; sy < samples; sy++)
		{
			for (int sx = 0; sx < samples; sx++)
			{
				float px = gx + (sx + 0.5f) * invSamples;
				float py = gy + (sy + 0.5f) * invSamples;
				ClosestPointOnSegment(
					px,
					py,
					fromCenterCellX,
					fromCenterCellY,
					toCenterCellX,
					toCenterCellY,
					out float closestX,
					out float closestY);
				sumStrength += ComputeEllipseRevealStrengthAtPx(
					px,
					py,
					closestX,
					closestY,
					radius,
					featherCells);
			}
		}

		return sumStrength / sampleCount;
	}

	private static void ClosestPointOnSegment(
		float px,
		float py,
		float ax,
		float ay,
		float bx,
		float by,
		out float closestX,
		out float closestY)
	{
		float dx = bx - ax;
		float dy = by - ay;
		float lenSq = dx * dx + dy * dy;
		if (lenSq <= 1e-8f)
		{
			closestX = ax;
			closestY = ay;
			return;
		}

		float t = ((px - ax) * dx + (py - ay) * dy) / lenSq;
		t = Math.Clamp(t, 0f, 1f);
		closestX = ax + t * dx;
		closestY = ay + t * dy;
	}

	private static void CollectBresenhamPath(int fromX, int fromY, int toX, int toY, List<(int X, int Y)> path)
	{
		int x0 = fromX;
		int y0 = fromY;
		int x1 = toX;
		int y1 = toY;
		int dx = Math.Abs(x1 - x0);
		int dy = Math.Abs(y1 - y0);
		int sx = x0 < x1 ? 1 : -1;
		int sy = y0 < y1 ? 1 : -1;
		int err = dx - dy;

		while (true)
		{
			path.Add((x0, y0));
			if (x0 == x1 && y0 == y1)
			{
				break;
			}

			int e2 = err * 2;
			if (e2 > -dy)
			{
				err -= dy;
				x0 += sx;
			}

			if (e2 < dx)
			{
				err += dx;
				y0 += sy;
			}
		}
	}

	/// <summary>
	/// Fills a row-major R8 mask: 255 = revealed, 0 = hidden.
	/// Uses sparse iteration when revealed cells are a small fraction of the buffer.
	/// </summary>
	public void FillRevealedMask(int originX, int originY, int width, int height, Span<byte> outMask)
	{
		if (outMask.Length < width * height)
		{
			throw new ArgumentException("Mask buffer is too small.", nameof(outMask));
		}

		int area = width * height;
		outMask.Slice(0, area).Clear();

		if (_revealed.Count < area / 4)
		{
			FillRevealedMaskSparse(originX, originY, width, height, outMask);
			return;
		}

		for (int localY = 0; localY < height; localY++)
		{
			int gy = originY + localY;
			int rowOffset = localY * width;

			for (int localX = 0; localX < width; localX++)
			{
				int gx = originX + localX;
				outMask[rowOffset + localX] = IsRevealed(gx, gy) ? (byte)255 : (byte)0;
			}
		}
	}

	private void FillRevealedMaskSparse(int originX, int originY, int width, int height, Span<byte> outMask)
	{
		int maxX = originX + width - 1;
		int maxY = originY + height - 1;

		foreach (long key in _revealed)
		{
			DecodeKey(key, out int gx, out int gy);
			if (gx < originX || gx > maxX || gy < originY || gy > maxY)
			{
				continue;
			}

			int localX = gx - originX;
			int localY = gy - originY;
			outMask[localY * width + localX] = 255;
		}
	}

	/// <summary>
	/// Allocates and fills a row-major R8 mask: 255 = revealed, 0 = hidden.
	/// Returns a native C# byte[] for Godot interop (avoids Span/caller-buffer marshalling).
	/// </summary>
	public byte[] FillRevealedMaskNative(int originX, int originY, int width, int height)
	{
		int area = width * height;
		byte[] outMask = new byte[area];

		if (_revealed.Count < area / 4)
		{
			int maxX = originX + width - 1;
			int maxY = originY + height - 1;
			foreach (long key in _revealed)
			{
				DecodeKey(key, out int gx, out int gy);
				if (gx >= originX && gx <= maxX && gy >= originY && gy <= maxY)
				{
					int localX = gx - originX;
					int localY = gy - originY;
					outMask[localY * width + localX] = 255;
				}
			}

			return outMask;
		}

		for (int localY = 0; localY < height; localY++)
		{
			int gy = originY + localY;
			int rowOffset = localY * width;

			for (int localX = 0; localX < width; localX++)
			{
				int gx = originX + localX;
				outMask[rowOffset + localX] = IsRevealed(gx, gy) ? (byte)255 : (byte)0;
			}
		}

		return outMask;
	}

	/// <summary>
	/// Sparse hole fill after a sliding-window shift: explored cells with zero mask texels get graded restore.
	/// Cheaper than <see cref="RefreshPresentationGradientsInWindow"/> for recenter; preserves graded overlap.
	/// </summary>
	public int FillRevealedHolesInWindow(int originX, int originY, int width, int height, Span<byte> outMask) =>
		FillRevealedHolesInWindow(originX, originY, width, height, outMask, 0, 0, 0);

	/// <summary>
	/// Hole fill scoped to incoming buffer strips after a shift (plus optional edge bands).
	/// Binary 255 in incoming strips; graded restore in edge bands — live disc re-grades nearby.
	/// </summary>
	public int FillRevealedHolesInWindow(
		int originX,
		int originY,
		int width,
		int height,
		Span<byte> outMask,
		int shiftDeltaX,
		int shiftDeltaY,
		int edgeBandCells)
	{
		int area = width * height;
		if (outMask.Length < area)
		{
			throw new ArgumentException("Mask buffer is too small.", nameof(outMask));
		}

		int maxX = originX + width - 1;
		int maxY = originY + height - 1;
		bool stripMode = shiftDeltaX != 0 || shiftDeltaY != 0;

		if (stripMode)
		{
			return FillRevealedHolesStripMode(
				originX,
				originY,
				width,
				height,
				outMask,
				shiftDeltaX,
				shiftDeltaY,
				edgeBandCells);
		}

		int count = 0;
		if (!RevealedBoundsIntersectsWindow(originX, originY, maxX, maxY))
		{
			return 0;
		}

		foreach (long key in _revealed)
		{
			DecodeKey(key, out int gx, out int gy);
			if (gx < originX || gx > maxX || gy < originY || gy > maxY)
			{
				continue;
			}

			int localX = gx - originX;
			int localY = gy - originY;
			int idx = localY * width + localX;
			if (outMask[idx] != 0)
			{
				continue;
			}

			StampMaskMax(outMask, idx, ComputeExploredRestoreStrength(gx, gy, _revealStampFeatherCells));
			count++;
		}

		return count;
	}

	private bool RevealedBoundsIntersectsWindow(int originX, int originY, int maxX, int maxY)
	{
		if (_revealed.Count == 0)
		{
			return false;
		}

		return _revealedMaxX >= originX
			&& _revealedMinX <= maxX
			&& _revealedMaxY >= originY
			&& _revealedMinY <= maxY;
	}

	/// <summary>
	/// After a buffer shift, scan only strip + edge-band cells (O(region)) instead of all revealed keys.
	/// </summary>
	private int FillRevealedHolesStripMode(
		int originX,
		int originY,
		int width,
		int height,
		Span<byte> outMask,
		int shiftDeltaX,
		int shiftDeltaY,
		int edgeBandCells)
	{
		int maxX = originX + width - 1;
		int maxY = originY + height - 1;
		int scanMinGx = originX;
		int scanMaxGx = maxX;
		int scanMinGy = originY;
		int scanMaxGy = maxY;

		if (shiftDeltaX > 0)
		{
			scanMinGx = originX + width - shiftDeltaX;
		}
		else if (shiftDeltaX < 0)
		{
			scanMaxGx = originX + (-shiftDeltaX) - 1;
		}

		if (shiftDeltaY > 0)
		{
			scanMinGy = originY + height - shiftDeltaY;
		}
		else if (shiftDeltaY < 0)
		{
			scanMaxGy = originY + (-shiftDeltaY) - 1;
		}

		if (edgeBandCells > 0)
		{
			if (shiftDeltaX != 0)
			{
				scanMinGy = originY;
				scanMaxGy = maxY;
			}

			if (shiftDeltaY != 0)
			{
				scanMinGx = originX;
				scanMaxGx = maxX;
			}
		}

		scanMinGx = Math.Max(scanMinGx, originX);
		scanMaxGx = Math.Min(scanMaxGx, maxX);
		scanMinGy = Math.Max(scanMinGy, originY);
		scanMaxGy = Math.Min(scanMaxGy, maxY);

		int count = 0;
		for (int gy = scanMinGy; gy <= scanMaxGy; gy++)
		{
			for (int gx = scanMinGx; gx <= scanMaxGx; gx++)
			{
				if (!IsInHoleRestoreRegion(
						gx,
						gy,
						originX,
						originY,
						width,
						height,
						shiftDeltaX,
						shiftDeltaY,
						edgeBandCells))
				{
					continue;
				}

				if (!IsRevealed(gx, gy))
				{
					continue;
				}

				int localX = gx - originX;
				int localY = gy - originY;
				int idx = localY * width + localX;
				if (outMask[idx] != 0)
				{
					continue;
				}

				if (IsInIncomingShiftStrip(gx, gy, originX, originY, width, height, shiftDeltaX, shiftDeltaY))
				{
					outMask[idx] = 255;
				}
				else
				{
					StampMaskMax(outMask, idx, ComputeExploredRestoreStrength(gx, gy, _revealStampFeatherCells));
				}

				count++;
			}
		}

		return count;
	}

	private static bool IsInIncomingShiftStrip(
		int gx,
		int gy,
		int originX,
		int originY,
		int width,
		int height,
		int shiftDeltaX,
		int shiftDeltaY)
	{
		int maxX = originX + width - 1;
		int maxY = originY + height - 1;

		if (shiftDeltaX > 0)
		{
			int stripMinGx = originX + width - shiftDeltaX;
			if (gx >= stripMinGx && gx <= maxX)
			{
				return true;
			}
		}
		else if (shiftDeltaX < 0)
		{
			int stripMaxGx = originX + (-shiftDeltaX) - 1;
			if (gx >= originX && gx <= stripMaxGx)
			{
				return true;
			}
		}

		if (shiftDeltaY > 0)
		{
			int stripMinGy = originY + height - shiftDeltaY;
			if (gy >= stripMinGy && gy <= maxY)
			{
				return true;
			}
		}
		else if (shiftDeltaY < 0)
		{
			int stripMaxGy = originY + (-shiftDeltaY) - 1;
			if (gy >= originY && gy <= stripMaxGy)
			{
				return true;
			}
		}

		return false;
	}

	private static bool IsInHoleRestoreRegion(
		int gx,
		int gy,
		int originX,
		int originY,
		int width,
		int height,
		int shiftDeltaX,
		int shiftDeltaY,
		int edgeBandCells)
	{
		if (IsInIncomingShiftStrip(gx, gy, originX, originY, width, height, shiftDeltaX, shiftDeltaY))
		{
			return true;
		}

		int maxX = originX + width - 1;
		int maxY = originY + height - 1;

		if (shiftDeltaX > 0)
		{
			int overlapMaxGx = originX + width - shiftDeltaX - 1;
			if (gx >= originX && gx <= overlapMaxGx && gy >= originY && gy <= maxY)
			{
				return true;
			}
		}
		else if (shiftDeltaX < 0)
		{
			int overlapMinGx = originX + (-shiftDeltaX);
			if (gx >= overlapMinGx && gx <= maxX && gy >= originY && gy <= maxY)
			{
				return true;
			}
		}

		if (shiftDeltaY > 0)
		{
			int overlapMaxGy = originY + height - shiftDeltaY - 1;
			if (gy >= originY && gy <= overlapMaxGy && gx >= originX && gx <= maxX)
			{
				return true;
			}
		}
		else if (shiftDeltaY < 0)
		{
			int overlapMinGy = originY + (-shiftDeltaY);
			if (gy >= overlapMinGy && gy <= maxY && gx >= originX && gx <= maxX)
			{
				return true;
			}
		}

		if (edgeBandCells > 0)
		{
			if (shiftDeltaX != 0)
			{
				if (gy >= originY && gy < originY + edgeBandCells)
				{
					return true;
				}

				if (gy > maxY - edgeBandCells && gy <= maxY)
				{
					return true;
				}
			}

			if (shiftDeltaY != 0)
			{
				if (gx >= originX && gx < originX + edgeBandCells)
				{
					return true;
				}

				if (gx > maxX - edgeBandCells && gx <= maxX)
				{
					return true;
				}
			}
		}

		return false;
	}

	/// <summary>
	/// Restores graded mask texels for explored cells after a sliding-window shift (sparse iteration).
	/// Uses initial rounded-square and current movement disc strengths; does not replace path history.
	/// </summary>
	public int RefreshPresentationGradientsInWindow(
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
		Span<byte> outMask)
	{
		int area = width * height;
		if (outMask.Length < area)
		{
			throw new ArgumentException("Mask buffer is too small.", nameof(outMask));
		}

		int maxX = originX + width - 1;
		int maxY = originY + height - 1;
		int clampedInitialRadius = ClampRadius(initialRadius);
		int clampedCorner = Math.Clamp(initialCornerRadius, 0, clampedInitialRadius);
		float initialCenterPxX = initialCenterX + 0.5f;
		float initialCenterPxY = initialCenterY + 0.5f;
		float initialHalfExtent = clampedInitialRadius + 0.5f;
		int featherPad = (int)MathF.Ceiling(_revealStampFeatherCells);
		int sqMinX = initialCenterX - clampedInitialRadius - featherPad;
		int sqMaxX = initialCenterX + clampedInitialRadius + featherPad;
		int sqMinY = initialCenterY - clampedInitialRadius - featherPad;
		int sqMaxY = initialCenterY + clampedInitialRadius + featherPad;
		int count = 0;

		for (int gx = sqMinX; gx <= sqMaxX; gx++)
		{
			for (int gy = sqMinY; gy <= sqMaxY; gy++)
			{
				if (gx < originX || gx > maxX || gy < originY || gy > maxY)
				{
					continue;
				}

				float fromInitial = ComputeRoundedSquareRevealStrength(
					gx,
					gy,
					initialCenterPxX,
					initialCenterPxY,
					initialHalfExtent,
					clampedCorner,
					_revealStampFeatherCells);
				if (fromInitial <= 0f)
				{
					continue;
				}

				RevealCell(gx, gy, null);
				int localX = gx - originX;
				int localY = gy - originY;
				StampMaskMax(outMask, localY * width + localX, fromInitial);
				count++;
			}
		}

		foreach (long key in _revealed)
		{
			DecodeKey(key, out int gx, out int gy);
			if (gx < originX || gx > maxX || gy < originY || gy > maxY)
			{
				continue;
			}

			int localX = gx - originX;
			int localY = gy - originY;
			int idx = localY * width + localX;
			float strength = outMask[idx] / 255f;

			float fromInitial = ComputeRoundedSquareRevealStrength(
				gx,
				gy,
				initialCenterPxX,
				initialCenterPxY,
				initialHalfExtent,
				clampedCorner,
				_revealStampFeatherCells);
			strength = MathF.Max(strength, fromInitial);

			float fromDisc = ComputeEllipseRevealStrength(
				gx,
				gy,
				playerCenterCellX,
				playerCenterCellY,
				movementRadius,
				_revealStampFeatherCells);
			strength = MathF.Max(strength, fromDisc);

			// Explored cells can lose graded texels after a sliding-window shift; only fill true holes
			// (strength == 0) so preserved feather values are not flattened to 255.
			if (strength <= 0f)
			{
				strength = ComputeExploredRestoreStrength(gx, gy, _revealStampFeatherCells);
			}

			StampMaskMax(outMask, idx, strength);
			count++;
		}

		return count;
	}

	/// <summary>
	/// Reveals hidden cells in fully enclosed pockets (not connected to window-edge hidden via 4-neighbor paths).
	/// Returns count of newly revealed cells. Skipped when <paramref name="maxHoleCells"/> is 0.
	/// REVISIT: removed from Godot hot path — enclosed-pocket auto-reveal disabled pending redesign.
	/// </summary>
	public int FillSmallEnclosedHolesInWindow(
		int originX,
		int originY,
		int width,
		int height,
		int maxHoleCells)
	{
		if (maxHoleCells <= 0 || width <= 0 || height <= 0)
		{
			return 0;
		}

		int area = width * height;
		EnsureHoleFillScratch(area);
		Span<byte> visited = _holeFillScratch.AsSpan(0, area);
		visited.Clear();
		_holeFillQueue.Clear();

		for (int localX = 0; localX < width; localX++)
		{
			EnqueueExteriorHidden(originX, originY, width, localX, 0, visited);
			EnqueueExteriorHidden(originX, originY, width, localX, height - 1, visited);
		}

		for (int localY = 1; localY < height - 1; localY++)
		{
			EnqueueExteriorHidden(originX, originY, width, 0, localY, visited);
			EnqueueExteriorHidden(originX, originY, width, width - 1, localY, visited);
		}

		while (_holeFillQueue.Count > 0)
		{
			int idx = _holeFillQueue.Dequeue();
			int localX = idx % width;
			int localY = idx / width;
			TryEnqueueExteriorHidden(originX, originY, width, localX - 1, localY, visited);
			TryEnqueueExteriorHidden(originX, originY, width, localX + 1, localY, visited);
			TryEnqueueExteriorHidden(originX, originY, width, localX, localY - 1, visited);
			TryEnqueueExteriorHidden(originX, originY, width, localX, localY + 1, visited);
		}

		int revealedCount = 0;
		for (int idx = 0; idx < area; idx++)
		{
			if (visited[idx] != 0)
			{
				continue;
			}

			int localX = idx % width;
			int localY = idx / width;
			int gx = originX + localX;
			int gy = originY + localY;
			if (IsRevealed(gx, gy))
			{
				continue;
			}

			_holeFillComponent.Clear();
			_holeFillQueue.Clear();
			_holeFillQueue.Enqueue(idx);
			visited[idx] = 2;

			while (_holeFillQueue.Count > 0)
			{
				int componentIdx = _holeFillQueue.Dequeue();
				int cx = componentIdx % width;
				int cy = componentIdx / width;
				_holeFillComponent.Add((originX + cx, originY + cy));

				TryEnqueueHoleComponent(originX, originY, width, cx - 1, cy, visited);
				TryEnqueueHoleComponent(originX, originY, width, cx + 1, cy, visited);
				TryEnqueueHoleComponent(originX, originY, width, cx, cy - 1, visited);
				TryEnqueueHoleComponent(originX, originY, width, cx, cy + 1, visited);
			}

			if (_holeFillComponent.Count > maxHoleCells)
			{
				continue;
			}

			foreach (var (x, y) in _holeFillComponent)
			{
				if (RevealCell(x, y, null))
				{
					revealedCount++;
				}
			}
		}

		return revealedCount;
	}

	public void ClearAll()
	{
		_revealed.Clear();
		_hasRevealedBounds = false;
	}

	public bool TryGetRevealedBounds(out RevealedBounds bounds)
	{
		if (!_hasRevealedBounds)
		{
			bounds = default;
			return false;
		}

		bounds = new RevealedBounds(_revealedMinX, _revealedMinY, _revealedMaxX, _revealedMaxY);
		return true;
	}

	private static bool CellIntersectsRoundedSquare(
		int gx,
		int gy,
		float centerPxX,
		float centerPxY,
		float halfExtent,
		float cornerRadius)
	{
		const int samples = RoundedSquareStampSubcellSamples;
		float invSamples = 1f / samples;
		for (int sy = 0; sy < samples; sy++)
		{
			for (int sx = 0; sx < samples; sx++)
			{
				float px = gx + (sx + 0.5f) * invSamples;
				float py = gy + (sy + 0.5f) * invSamples;
				if (IsInsideRoundedSquarePx(px, py, centerPxX, centerPxY, halfExtent, cornerRadius))
				{
					return true;
				}
			}
		}

		return false;
	}

	private static bool IsInsideRoundedSquarePx(
		float px,
		float py,
		float centerPxX,
		float centerPxY,
		float halfExtent,
		float cornerRadius)
	{
		float ax = Math.Abs(px - centerPxX);
		float ay = Math.Abs(py - centerPxY);
		if (ax > halfExtent || ay > halfExtent)
		{
			return false;
		}

		if (cornerRadius <= 0f)
		{
			return true;
		}

		if (ax <= halfExtent - cornerRadius || ay <= halfExtent - cornerRadius)
		{
			return true;
		}

		float qx = ax - (halfExtent - cornerRadius);
		float qy = ay - (halfExtent - cornerRadius);
		return qx * qx + qy * qy <= cornerRadius * cornerRadius;
	}

	private static bool IsInsideRoundedSquare(
		int gx,
		int gy,
		float centerPxX,
		float centerPxY,
		float halfExtent,
		float cornerRadius)
	{
		var (px, py) = GridMath.CellCenter(gx, gy);
		return IsInsideRoundedSquarePx(px, py, centerPxX, centerPxY, halfExtent, cornerRadius);
	}

	private bool IsInsideRevealEllipse(int gx, int gy, float centerCellX, float centerCellY, int radius)
	{
		return ComputeEllipseRevealDistance(gx, gy, centerCellX, centerCellY, radius) <= 1f;
	}

	private const int DiscStampSubcellSamples = 16;
	private const int RoundedSquareStampSubcellSamples = 32;
	private const float MinStampStrength = 2f / 255f;

	private float ComputeEllipseRevealDistanceAtPx(
		float px,
		float py,
		float centerCellX,
		float centerCellY,
		int radius)
	{
		float scaleX = radius * _revealRadiusScaleX;
		float scaleY = radius * _revealRadiusScaleY;
		if (scaleX <= 0f || scaleY <= 0f)
		{
			return float.MaxValue;
		}

		float dx = (px - centerCellX) / scaleX;
		float dy = (py - centerCellY) / scaleY;
		return MathF.Sqrt(dx * dx + dy * dy);
	}

	private float ComputeEllipseRevealDistance(int gx, int gy, float centerCellX, float centerCellY, int radius)
	{
		var (px, py) = GridMath.CellCenter(gx, gy);
		return ComputeEllipseRevealDistanceAtPx(px, py, centerCellX, centerCellY, radius);
	}

	private float ComputeEllipseRevealStrengthAtPx(
		float px,
		float py,
		float centerCellX,
		float centerCellY,
		int radius,
		float featherCells)
	{
		int clampedRadius = ClampRadius(radius);
		if (clampedRadius <= 0)
		{
			return 0f;
		}

		float distance = ComputeEllipseRevealDistanceAtPx(px, py, centerCellX, centerCellY, clampedRadius);
		float featherNorm = featherCells / clampedRadius;
		if (featherNorm <= 0f)
		{
			return distance <= 1f ? 1f : 0f;
		}

		float inner = 1f - featherNorm;
		float outer = 1f + featherNorm;
		if (distance <= inner)
		{
			return 1f;
		}

		if (distance >= outer)
		{
			return 0f;
		}

		float t = (distance - inner) / (outer - inner);
		return 1f - SmoothStep01(t);
	}

	private float ComputeEllipseRevealStrength(
		int gx,
		int gy,
		float centerCellX,
		float centerCellY,
		int radius,
		float featherCells)
	{
		int clampedRadius = ClampRadius(radius);
		float cellCenterX = gx + 0.5f;
		float cellCenterY = gy + 0.5f;
		float featherNorm = featherCells / clampedRadius;
		float outer = 1f + featherNorm;
		float dist = ComputeEllipseRevealDistanceAtPx(
			cellCenterX,
			cellCenterY,
			centerCellX,
			centerCellY,
			clampedRadius);
		if (dist > outer + 0.866f)
		{
			return 0f;
		}

		int samples = DiscStampSubcellSamples;
		float invSamples = 1f / samples;
		float sumStrength = 0f;
		int sampleCount = samples * samples;

		for (int sy = 0; sy < samples; sy++)
		{
			for (int sx = 0; sx < samples; sx++)
			{
				float px = gx + (sx + 0.5f) * invSamples;
				float py = gy + (sy + 0.5f) * invSamples;
				sumStrength += ComputeEllipseRevealStrengthAtPx(
					px,
					py,
					centerCellX,
					centerCellY,
					radius,
					featherCells);
			}
		}

		return sumStrength / sampleCount;
	}

	private static float ComputeRoundedSquareSignedDistance(
		float px,
		float py,
		float centerPxX,
		float centerPxY,
		float halfExtent,
		float cornerRadius)
	{
		float ax = Math.Abs(px - centerPxX);
		float ay = Math.Abs(py - centerPxY);
		float innerHalf = MathF.Max(halfExtent - cornerRadius, 0f);
		float qx = ax - innerHalf;
		float qy = ay - innerHalf;
		float outside = MathF.Sqrt(MathF.Max(qx, 0f) * MathF.Max(qx, 0f) + MathF.Max(qy, 0f) * MathF.Max(qy, 0f));
		float inside = MathF.Min(MathF.Max(qx, qy), 0f);
		return outside + inside - cornerRadius;
	}

	private static float ComputeRoundedSquareRevealStrengthAtPx(
		float px,
		float py,
		float centerPxX,
		float centerPxY,
		float halfExtent,
		float cornerRadius,
		float featherCells)
	{
		float distance = ComputeRoundedSquareSignedDistance(
			px, py, centerPxX, centerPxY, halfExtent, cornerRadius);

		if (featherCells <= 0f)
		{
			return distance <= 0f ? 1f : 0f;
		}

		if (distance <= 0f)
		{
			return 1f;
		}

		if (distance >= featherCells)
		{
			return 0f;
		}

		float t = distance / featherCells;
		return 1f - SmoothStep01(t);
	}

	/// <summary>
	/// Approximates graded mask strength for explored cells that lost texels after a buffer shift.
	/// Interior cells return 1; frontier cells feather from distance to the nearest hidden cell.
	/// </summary>
	private float ComputeExploredRestoreStrength(int gx, int gy, float featherCells)
	{
		if (featherCells <= 0f)
		{
			return 1f;
		}

		int samples = DiscStampSubcellSamples;
		float invSamples = 1f / samples;
		float sumStrength = 0f;
		int sampleCount = samples * samples;

		for (int sy = 0; sy < samples; sy++)
		{
			for (int sx = 0; sx < samples; sx++)
			{
				float px = gx + (sx + 0.5f) * invSamples;
				float py = gy + (sy + 0.5f) * invSamples;
				sumStrength += ComputeExploredRestoreSampleStrengthAtPx(px, py, featherCells);
			}
		}

		return sumStrength / sampleCount;
	}

	private float ComputeExploredRestoreSampleStrengthAtPx(float px, float py, float featherCells)
	{
		int cellX = (int)MathF.Floor(px);
		int cellY = (int)MathF.Floor(py);
		int search = (int)MathF.Ceiling(featherCells) + 2;
		float minDistToHidden = float.MaxValue;

		for (int dy = -search; dy <= search; dy++)
		{
			for (int dx = -search; dx <= search; dx++)
			{
				int gx = cellX + dx;
				int gy = cellY + dy;
				if (IsRevealed(gx, gy))
				{
					continue;
				}

				float dist = DistanceToCell(px, py, gx, gy);
				minDistToHidden = MathF.Min(minDistToHidden, dist);
			}
		}

		if (minDistToHidden >= featherCells)
		{
			return 1f;
		}

		if (minDistToHidden <= 0f)
		{
			return 0f;
		}

		return SmoothStep01(minDistToHidden / featherCells);
	}

	private static float DistanceToCell(float px, float py, int gx, int gy)
	{
		float cx = gx + 0.5f;
		float cy = gy + 0.5f;
		float dx = MathF.Max(MathF.Abs(px - cx) - 0.5f, 0f);
		float dy = MathF.Max(MathF.Abs(py - cy) - 0.5f, 0f);
		return MathF.Sqrt(dx * dx + dy * dy);
	}

	private static float ComputeRoundedSquareRevealStrength(
		int gx,
		int gy,
		float centerPxX,
		float centerPxY,
		float halfExtent,
		float cornerRadius,
		float featherCells)
	{
		int samples = RoundedSquareStampSubcellSamples;
		float invSamples = 1f / samples;
		float sumStrength = 0f;
		int sampleCount = samples * samples;

		for (int sy = 0; sy < samples; sy++)
		{
			for (int sx = 0; sx < samples; sx++)
			{
				float px = gx + (sx + 0.5f) * invSamples;
				float py = gy + (sy + 0.5f) * invSamples;
				sumStrength += ComputeRoundedSquareRevealStrengthAtPx(
					px,
					py,
					centerPxX,
					centerPxY,
					halfExtent,
					cornerRadius,
					featherCells);
			}
		}

		return sumStrength / sampleCount;
	}

	private static void StampMaskMax(Span<byte> outMask, int index, float strength)
	{
		if (strength < MinStampStrength)
		{
			return;
		}
		byte value = (byte)Math.Clamp((int)MathF.Round(strength * 255f), 0, 255);
		if (value > outMask[index])
		{
			outMask[index] = value;
		}
	}

	private static float SmoothStep01(float t) =>
		t <= 0f ? 0f : t >= 1f ? 1f : t * t * (3f - 2f * t);

	private void ExpandRevealedBounds(int x, int y)
	{
		if (!_hasRevealedBounds)
		{
			_revealedMinX = _revealedMaxX = x;
			_revealedMinY = _revealedMaxY = y;
			_hasRevealedBounds = true;
			return;
		}

		if (x < _revealedMinX)
		{
			_revealedMinX = x;
		}

		if (x > _revealedMaxX)
		{
			_revealedMaxX = x;
		}

		if (y < _revealedMinY)
		{
			_revealedMinY = y;
		}

		if (y > _revealedMaxY)
		{
			_revealedMaxY = y;
		}
	}

	private static float ClampRevealRadiusScale(float scale) =>
		Math.Clamp(scale, RevealRadiusScaleMin, RevealRadiusScaleMax);

	private static int ClampRadius(int radius) =>
		Math.Clamp(radius, RadiusMin, RadiusMax);

	private byte[] _holeFillScratch = Array.Empty<byte>();
	private readonly Queue<int> _holeFillQueue = new();
	private readonly List<(int X, int Y)> _holeFillComponent = new();

	private void EnsureHoleFillScratch(int area)
	{
		if (_holeFillScratch.Length < area)
		{
			_holeFillScratch = new byte[area];
		}
	}

	private void EnqueueExteriorHidden(
		int originX,
		int originY,
		int width,
		int localX,
		int localY,
		Span<byte> visited)
	{
		if (localX < 0 || localY < 0)
		{
			return;
		}

		int idx = localY * width + localX;
		if (visited[idx] != 0)
		{
			return;
		}

		if (IsRevealed(originX + localX, originY + localY))
		{
			return;
		}

		visited[idx] = 1;
		_holeFillQueue.Enqueue(idx);
	}

	private void TryEnqueueExteriorHidden(
		int originX,
		int originY,
		int width,
		int localX,
		int localY,
		Span<byte> visited)
	{
		if (localX < 0 || localY < 0 || localX >= width)
		{
			return;
		}

		int height = visited.Length / width;
		if (localY >= height)
		{
			return;
		}

		EnqueueExteriorHidden(originX, originY, width, localX, localY, visited);
	}

	private void TryEnqueueHoleComponent(
		int originX,
		int originY,
		int width,
		int localX,
		int localY,
		Span<byte> visited)
	{
		if (localX < 0 || localY < 0 || localX >= width)
		{
			return;
		}

		int height = visited.Length / width;
		if (localY >= height)
		{
			return;
		}

		int idx = localY * width + localX;
		if (visited[idx] != 0)
		{
			return;
		}

		if (IsRevealed(originX + localX, originY + localY))
		{
			return;
		}

		visited[idx] = 2;
		_holeFillQueue.Enqueue(idx);
	}

	private static long MakeKey(int x, int y) => ((long)x << 32) | (uint)y;

	internal static void DecodeKey(long key, out int x, out int y)
	{
		x = (int)(key >> 32);
		y = (int)(key & 0xFFFFFFFF);
	}
}
