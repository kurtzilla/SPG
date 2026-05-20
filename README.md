# SPG

Tactical RPG / sim prototype in **Godot 4**: 2D isometric view, grid-based movement, and party selection. Setting and mechanics are inspired by the **Palladium Rifts** universe. Rules reference material lives at `D:\source\Rifts` (consult specific docs when needed; do not bulk-import the whole tree).

## Architecture

Game **data and logic** are separated from the **visual layer**:

| Layer | Path | Role |
| :--- | :--- | :--- |
| Core | `src/Core/` | Pure models and systems — no Godot nodes or engine types |
| Godot | `src/Godot/` | Scenes, TileMaps, input, sprites, adapters |

**Canonical boundary rules:** [.cursor/rules/architecture.md](.cursor/rules/architecture.md)

**Current phase and immediate goals:** [.docs/dev_guide.md](.docs/dev_guide.md)

**Agent role and directives:** [.cursor/rules/project-directives.md](.cursor/rules/project-directives.md)

## Repository layout

```
SPG/
  project.godot
  src/
    Core/
      Models/     # GridModel, PartyModel, CharacterModel, ...
      Systems/    # Turn/grid sim, rules (future)
    Godot/
      Scenes/     # .tscn
      Scripts/    # Nodes, input, Core adapters
      Assets/     # Art, tilesets, audio
```

## Getting started

1. Install [Godot 4.3+](https://godotengine.org/).
2. Open this repository root (`SPG/`) as a project in the Godot editor.
3. Read `.docs/dev_guide.md` before implementing gameplay code.

No main scene or gameplay is configured yet — scaffold only.
