using Godot;
using SPG.Core;

namespace SPG.Interop;

[GlobalClass]
public partial class CharacterModelGd : RefCounted
{
	private readonly CharacterModel _model;

	public string Id => _model.Id;
	public string Name => _model.Name;
	public int X => _model.X;
	public int Y => _model.Y;

	public CharacterModelGd(string id, string name, int startX = 0, int startY = 0)
	{
		_model = new CharacterModel(id, name, startX, startY);
	}

	internal CharacterModel Model => _model;

	internal CharacterModelGd(CharacterModel model) => _model = model;

	public void MoveTo(int newX, int newY) => _model.MoveTo(newX, newY);

	public void MoveRelative(int dx, int dy) => _model.MoveRelative(dx, dy);
}
