# Developer Guide: Rifts Isometric Prototype



## 1. Current Phase: Minimum Viable Sandbox

The goal of this phase is strictly to achieve an isometric view with a 2-character party selection and grid movement. Do not implement complex Palladium rules yet.



## 2. Architecture Rules

- **Full modular boundaries** (dependency direction, allowed/forbidden APIs, layer flow): see [`.cursor/rules/architecture.md`](../.cursor/rules/architecture.md).

- **Core (`src/Core/`, project [`src/SPG.Core.csproj`](../src/SPG.Core.csproj)):** C# class library — no Godot references.

  - `Models/`: `PartyModel`, `CharacterModel`, `VisibilityModel`

  - `Math/`: `GridMath`

- **Interop (`src/Godot/Interop/`):** C# `RefCounted` wrappers + `CoreBridge` autoload. GDScript calls use **PascalCase** (e.g. `CoreBridge.CreatePartyModel()`, `character.MoveRelative()`).
- **World streaming (`src/Godot/Scripts/World/`):** `ChunkManager` — 32×32 procedural chunks, 3×3 load window, `get_tile_type_at_global_pos()`. Follow `.cursor/rules/godot-performance.mdc` (Self-Correction Step for hot-path changes). Grid overlay sync is throttled to scroll movement, not idle frames.

- **Godot (`src/Godot/`):** GDScript scenes and visuals.

  - Reads state from Interop wrappers and updates sprites / tiles.

  - Passes input back through wrapper methods (`move_relative`, `select_character`, …).



## 3. Toolchain

| Tool | Version |
|------|---------|
| Godot | **4.3 .NET (mono)** — not the GDScript-only build |
| .NET SDK | **6+** (`dotnet build SPG.sln`) |
| gdvm / CLI | Pin **4.3-mono** for this repo |

Open the project once in the Godot .NET editor so it can sync the C# solution. CLI builds use `Godot.NET.Sdk` **4.3.0** (matches Godot 4.3 stable).

### No **Project → Build**?

That menu item does not exist in the **standard** (GDScript-only) Godot build. You need **Godot 4.3 .NET** — the download is labeled **Mono** / **.NET** (e.g. `Godot_v4.3-stable_mono_win64.exe`).

**How to tell:** the .NET editor shows a **hammer / MSBuild** button in the **top-right** (next to Play). The window title often includes **.NET** or **Mono**.

**Open this repo with the right binary:**

```powershell
# gdvm (reads "C#" from project.godot)
& (gdvm show --csharp) --path D:\source\SPG --editor

# or run from repo
.\.tools\open_godot_csharp_editor.bat
```

**Build without the editor:** `dotnet build D:\source\SPG\SPG.sln` — Godot picks up `.godot\mono\temp\bin\Debug\SPG.dll` on run.

In the .NET editor, **Build** is the top-bar hammer icon, not under **Project**. **Project → Tools → C#** has solution/editor helpers only.

### Display: design viewport vs window size

[`project.godot`](../project.godot) uses a **native design viewport** (**3840×2160**) matching the target display. That size drives how many grid cells are generated and how the debug grid overlay scales—see `MainSandbox._visual_spawn_radius()`. **Window overrides** are set to the same size for fullscreen; **`window/stretch/mode="viewport"`** with **`stretch/aspect="keep"`** yields 1:1 rendering (no upscale) on that monitor.

A smaller design viewport (e.g. 1280×720 or 1920×1080) plus stretch upscaling reduces visible map area and CPU/GPU load; use that if performance becomes an issue on weaker displays.

### VS Code: format on save

Workspace settings in [`.vscode/settings.json`](../.vscode/settings.json) enable **format on save** for GDScript (Godot Tools) and C# (C# Dev Kit). Godot cache files under `.godot/` are treated as **plaintext** with formatting off (avoids false errors on `global_script_class_cache.cfg`).

After changing editor settings, run **Developer: Reload Window** once so associations and formatters apply.

### VS Code: F5 debug (GDScript)

Default **F5** uses **GDScript: Launch Main Project** in [`.vscode/launch.json`](../.vscode/launch.json): builds `SPG.sln`, then starts Godot 4.3 .NET with the main scene. You should see a **game window** (not just an empty debug toolbar).

| Config | When to use |
|--------|-------------|
| **Launch Main Project** (default F5) | Run/debug the game from VS Code; breakpoints in `.gd` files |
| **Launch Current Scene** | Run the open `.tscn` or scene context |
| **Attach to Editor** | Debug while using the Godot editor — editor must already be running |

**Attach workflow:**

1. Run [`.tools/open_godot_csharp_editor.bat`](../.tools/open_godot_csharp_editor.bat)
2. Godot: **Editor → Editor Settings → Network → Debug** — Remote Port **6007**
3. VS Code: choose **GDScript: Attach to Editor** from the Run and Debug dropdown, then start debugging

If F5 still attaches to nothing, confirm the dropdown shows **Launch Main Project** (Cursor may remember the old default).

**Godot window still does not open:**

1. Install the **Godot Tools** extension (`geequlim.godot-tools`) — required for `type: "godot"` debug configs.
2. Confirm [`.vscode/settings.json`](../.vscode/settings.json) has `godotTools.editorPath.godot4` pointing at the **4.3 mono** exe (not the GDScript-only Godot).
3. Try **Godot: Run Project (direct)** in the debug dropdown — starts Godot via the integrated terminal (breakpoints need Godot Tools attach).
4. Or run: `powershell -File .tools/run_godot_game.ps1` from the repo root.
5. If **preLaunchTask** fails, use **GDScript: Launch Main Project (no build)** or fix `dotnet build SPG.sln` in a terminal first.

### External editor: suppress "reload local" dialog

If the **Godot editor** is open while VS Code saves or formats scripts (or F5 runs `dotnet build`), Godot may pop up:

> *The following files were modified on disk … Discard local changes and reload?*

That is normal for external-editor workflows. It is controlled by **Editor Settings** on your machine (not in `project.godot`).

**One-time fix (recommended):** In the Godot 4.3 .NET editor:

**Editor → Editor Settings → Text Editor → Behavior → Files**

| Setting | Set to |
|---------|--------|
| **Auto Reload Scripts on External Change** | **On** |
| **Auto Reload and Parse Scripts on Save** | On |

Optional (less churn when switching between VS Code and Godot):

- **Interface → Editor → Save on Focus Loss** — On
- **Interface → Editor → Import Resources When Unfocused** — On

Godot then reloads from disk when you focus the editor, without asking every time. See [Using an external text editor](https://docs.godotengine.org/en/stable/getting_started/editor/external_editor.html).

**Avoid two Godot instances on the same project:**

| What you want | Workflow |
|---------------|----------|
| **F5 game window from VS Code** | **Close** the Godot editor before F5, or do not run `open_godot_csharp_editor.bat` first |
| **Edit/play in Godot editor** | Press Play in Godot; use VS Code **Attach to Editor** for breakpoints — do not also F5 **Launch** while the editor is open |

**If the editor must stay open:** use **GDScript: Launch Main Project (no build)** in the debug dropdown so F5 skips `dotnet build` (rebuilds also trigger C# assembly reload prompts). Run `dotnet build SPG.sln` manually after C# changes.

See also [`.vscode/launch.README.md`](../.vscode/launch.README.md) for a short launch-config cheat sheet.



## 4. Immediate Goal

Extend the sandbox (party selection, movement polish) without moving rules into `src/Godot/`. New logic belongs in `SPG.Core`; expose via Interop if GDScript needs it.
