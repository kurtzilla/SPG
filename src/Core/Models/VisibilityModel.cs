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
	public const int RadiusMin = 1;
	public const int RadiusMax = 32;
	public const int DefaultInitialRevealRadius = 12;
    public const int DefaultMovementRevealRadius = 12;

	private const float RevealRadiusScaleMin = 0.25f;
	private const float RevealRadiusScaleMax = 4f;

	private readonly Dictionary<long, CellVisibility> _cells = new();

	private float _revealRadiusScaleX = 1f;
	private float _revealRadiusScaleY = 1f;

	private bool _hasRevealedBounds;
	private int _revealedMinX;
	private int _revealedMaxX;
	private int _revealedMinY;
	private int _revealedMaxY;

	public bool FogEnabled { get; set; } = true;

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

	public CellVisibility GetVisibility(int x, int y)
	{
		if (_cells.TryGetValue(MakeKey(x, y), out CellVisibility visibility))
		{
			return visibility;
		}

		return CellVisibility.Hidden;
	}

	public void SetVisibility(int x, int y, CellVisibility visibility)
	{
		long key = MakeKey(x, y);
		_cells[key] = visibility;
		if (visibility == CellVisibility.Revealed)
		{
			ExpandRevealedBounds(x, y);
		}
	}

	public void RevealCell(int x, int y) => RevealCell(x, y, null);

	/// <summary>
	/// Marks a cell revealed. When <paramref name="newlyRevealed"/> is non-null, appends the cell if it was hidden.
	/// </summary>
	public bool RevealCell(int x, int y, List<(int X, int Y)>? newlyRevealed)
	{
		long key = MakeKey(x, y);
		if (_cells.TryGetValue(key, out CellVisibility existing) && existing == CellVisibility.Revealed)
		{
			return false;
		}

		_cells[key] = CellVisibility.Revealed;
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
				if (!IsInsideRevealEllipse(gx, gy, centerX, centerY, clampedRadius))
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

	public void ClearAll()
	{
		_cells.Clear();
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

	/// <summary>
	/// Texel dimensions for a binary fog mask (0 = revealed, 255 = hidden).
	/// </summary>
	public static void GetBinaryMaskDimensions(
		int cellWidth,
		int cellHeight,
		int cellStride,
		out int texelWidth,
		out int texelHeight)
	{
		int stride = Math.Max(1, cellStride);
		texelWidth = (cellWidth + stride - 1) / stride;
		texelHeight = (cellHeight + stride - 1) / stride;
	}

	/// <summary>
	/// Fills a row-major binary mask (0 = revealed, 255 = hidden). One texel per cellStride×cellStride block.
	/// </summary>
	public byte[] FillBinaryMask(
		int minX,
		int minY,
		int maxX,
		int maxY,
		int cellStride)
	{
		int cellWidth = maxX - minX + 1;
		int cellHeight = maxY - minY + 1;
		GetBinaryMaskDimensions(cellWidth, cellHeight, cellStride, out int texelWidth, out int texelHeight);
		var buffer = new byte[texelWidth * texelHeight];
		FillBinaryMask(minX, minY, maxX, maxY, cellStride, buffer, 0);
		return buffer;
	}

	public void FillBinaryMask(
		int minX,
		int minY,
		int maxX,
		int maxY,
		int cellStride,
		byte[] buffer,
		int bufferOffset = 0)
	{
		int cellWidth = maxX - minX + 1;
		int cellHeight = maxY - minY + 1;
		int stride = Math.Max(1, cellStride);
		GetBinaryMaskDimensions(cellWidth, cellHeight, stride, out int texelWidth, out int texelHeight);
		int requiredLength = bufferOffset + texelWidth * texelHeight;
		if (texelWidth <= 0 || texelHeight <= 0 || buffer.Length < requiredLength)
		{
			return;
		}

		for (int ty = 0; ty < texelHeight; ty++)
		{
			int blockY = minY + ty * stride;
			for (int tx = 0; tx < texelWidth; tx++)
			{
				int blockX = minX + tx * stride;
				buffer[bufferOffset + ty * texelWidth + tx] = GetBinaryMaskTexelAlpha(blockX, blockY, stride);
			}
		}
	}

	private byte GetBinaryMaskTexelAlpha(int blockX, int blockY, int blockSize)
	{
		for (int dy = 0; dy < blockSize; dy++)
		{
			for (int dx = 0; dx < blockSize; dx++)
			{
				if (GetVisibility(blockX + dx, blockY + dy) == CellVisibility.Revealed)
				{
					return 0;
				}
			}
		}

		return 255;
	}

	private bool IsInsideRevealEllipse(int gx, int gy, int centerX, int centerY, int radius)
	{
		float scaleX = radius * _revealRadiusScaleX;
		float scaleY = radius * _revealRadiusScaleY;
		if (scaleX <= 0f || scaleY <= 0f)
		{
			return false;
		}

		var (px, py) = GridMath.CellCenter(gx, gy);
		float dx = (px - centerX) / scaleX;
		float dy = (py - centerY) / scaleY;
		return dx * dx + dy * dy <= 1f;
	}

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

	private static long MakeKey(int x, int y) => ((long)x << 32) | (uint)y;
}
