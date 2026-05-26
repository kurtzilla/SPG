# SPG

Tactical RPG / sim prototype in **Godot 4**: 2D isometric view, grid-based movement, and party selection. Setting and mechanics are inspired by the **Palladium Rifts** universe. Rules reference material lives at `D:\source\Rifts` (consult specific docs when needed; do not bulk-import the whole tree).

## Architecture

Game **data and logic** are separated from the **visual layer**:

| Layer | Path | Role |
| :--- | :--- | :--- |
| Core | `src/Core/` + `src/SPG.Core.csproj` | C# class library — Models and Systems, no Godot APIs |
| Interop | `src/Godot/Interop/` | C# wrappers + `CoreBridge` autoload for GDScript |
| Godot | `src/Godot/` | GDScript scenes, TileMaps, input, sprites |

**Canonical boundary rules:** [.cursor/rules/architecture.md](.cursor/rules/architecture.md)

**Current phase and immediate goals:** [.docs/dev_guide.md](.docs/dev_guide.md)

**Agent role and directives:** [.cursor/rules/project-directives.md](.cursor/rules/project-directives.md)

## Repository layout

```
SPG/
  project.godot
  src/
    SPG.Core.csproj
    Core/
      Models/     # PartyModel, CharacterModel, VisibilityModel
      Math/       # GridMath
    Godot/
      Interop/    # C# CoreBridge + *Gd wrappers
      Scenes/     # .tscn
      Scripts/    # GDScript nodes, input, presentation
      Assets/     # Art, tilesets, audio
  SPG.sln           # Godot game project + SPG.Core reference
```

## Getting started

1. Install [.NET 6 SDK](https://dotnet.microsoft.com/download) and [Godot 4.3 .NET (mono)](https://godotengine.org/download).
2. Open this repository root (`SPG/`) in the **Godot 4.3 .NET** editor; build the C# solution once (Project → Build).
3. Optional CLI: `dotnet build SPG.sln`, `godot_console --path .` (pin gdvm to **4.3-mono**).
4. Read `.docs/dev_guide.md` before implementing gameplay code.

Main scene: `src/Godot/Scenes/MainSandbox.tscn`.
