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
	// Must match game_settings.json core_reference.visibility_radius_min (manual sync).
	public const int RadiusMin = 1;
	// Must match game_settings.json core_reference.visibility_radius_max (manual sync).
	public const int RadiusMax = 32;
	// Must match game_settings.json core_reference.visibility_initial_reveal_radius (manual sync).
	public const int DefaultInitialRevealRadius = 24;
	// Must match game_settings.json core_reference.visibility_movement_reveal_radius (manual sync).
	public const int DefaultMovementRevealRadius = 24;

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
