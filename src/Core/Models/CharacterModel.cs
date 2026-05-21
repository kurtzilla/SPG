namespace SPG.Core;

/// <summary>
/// Core character state. Grid position: positive x = East, negative x = West;
/// positive y = South, negative y = North.
/// </summary>
public sealed class CharacterModel
{
	public string Id { get; }
	public string Name { get; }
	public int X { get; private set; }
	public int Y { get; private set; }

	public CharacterModel(string id, string name, int startX = 0, int startY = 0)
	{
		Id = id;
		Name = name;
		X = startX;
		Y = startY;
	}

	public void MoveTo(int newX, int newY)
	{
		X = newX;
		Y = newY;
	}

	public void MoveRelative(int dx, int dy)
	{
		X += dx;
		Y += dy;
	}
}
