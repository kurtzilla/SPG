using Godot;

namespace SPG.Interop;

/// <summary>
/// Autoload factory for Core types exposed to GDScript.
/// </summary>
public partial class CoreBridge : Node
{
	public PartyModelGd CreatePartyModel() => new();

	public CharacterModelGd CreateCharacter(string id, string name, int startX = 0, int startY = 0) =>
		new(id, name, startX, startY);

	public GridMathGd CreateGridMath() => new();
}
