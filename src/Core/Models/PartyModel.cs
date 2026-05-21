namespace SPG.Core;

public sealed class PartyModel
{
	private readonly List<CharacterModel> _characters = new();
	public string SelectedCharacterId { get; private set; } = string.Empty;

	public void AddCharacter(CharacterModel character)
	{
		if (character == null)
		{
			return;
		}

		bool autoSelect = string.IsNullOrEmpty(SelectedCharacterId);
		_characters.Add(character);
		if (autoSelect)
		{
			SelectedCharacterId = character.Id;
		}
	}

	public void RemoveCharacter(string id)
	{
		int index = FindIndexById(id);
		if (index < 0)
		{
			return;
		}

		bool wasSelected = SelectedCharacterId == id;
		_characters.RemoveAt(index);
		if (!wasSelected)
		{
			return;
		}

		SelectedCharacterId = _characters.Count == 0 ? string.Empty : _characters[0].Id;
	}

	public CharacterModel? GetCharacter(string id)
	{
		int index = FindIndexById(id);
		return index < 0 ? null : _characters[index];
	}

	public CharacterModel? GetSelectedCharacter()
	{
		if (string.IsNullOrEmpty(SelectedCharacterId))
		{
			return null;
		}

		return GetCharacter(SelectedCharacterId);
	}

	public bool SelectCharacter(string id)
	{
		if (FindIndexById(id) < 0)
		{
			return false;
		}

		SelectedCharacterId = id;
		return true;
	}

	public IReadOnlyList<CharacterModel> GetAllCharacters() => _characters.AsReadOnly();

	private int FindIndexById(string id)
	{
		for (int i = 0; i < _characters.Count; i++)
		{
			if (_characters[i].Id == id)
			{
				return i;
			}
		}

		return -1;
	}
}
