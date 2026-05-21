using Godot;
using SPG.Core;

namespace SPG.Interop;

[GlobalClass]
public partial class PartyModelGd : RefCounted
{
	private readonly PartyModel _model = new();

	public string SelectedCharacterId => _model.SelectedCharacterId;

	public void AddCharacter(CharacterModelGd character)
	{
		if (character == null)
		{
			return;
		}

		_model.AddCharacter(character.Model);
	}

	public CharacterModelGd? GetSelectedCharacter()
	{
		CharacterModel? selected = _model.GetSelectedCharacter();
		return selected == null ? null : new CharacterModelGd(selected);
	}

	public bool SelectCharacter(string id) => _model.SelectCharacter(id);

	internal PartyModel Model => _model;
}
