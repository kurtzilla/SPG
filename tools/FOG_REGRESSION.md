# Fog regression gate

Automated checks for the silent failures that keep coming back (white screen, wrong node wiring, shader compile errors, bootstrap never running).

## Run manually

```powershell
.tools/run_fog_smoke.ps1
```

Or VS Code/Cursor: **Tasks → fog-smoke** (builds C# first).

## Before F5

Launch config **GDScript: Launch Main Project** runs **verify-spg** (build + fog-smoke) automatically.

## On git commit

One-time per clone:

```powershell
.tools/install-git-hooks.ps1
```

When staged files touch fog, pre-commit runs fog-smoke. Partial commits of the **atomic set** are blocked unless:

```powershell
$env:FOG_SKIP_ATOMIC = "1"
git commit ...
```

### Atomic fog files (commit together)

| File | Role |
|------|------|
| `src/Godot/Shaders/FogOverlay.gdshader` | Shader |
| `src/Godot/Scripts/Systems/fog-of-war/FogOverlay.gd` | Controller (CanvasLayer) |
| `src/Godot/Scenes/FogOverlay.tscn` | Scene wiring |

Also update `MainSandbox.gd` when changing `@onready` paths or bootstrap hooks.

### Never do this

```bash
git checkout HEAD -- src/Godot/Shaders/FogOverlay.gdshader   # without matching .gd + .tscn
```

## What smoke checks

1. `FogOverlay.gdshader` loads / compiles
2. `FogOverlay.tscn` — script on CanvasLayer, white `FogRect`, no script on rect
3. `MainSandbox` — `$FogOverlay` wiring + bootstrap sets `is_configured` + material bound

## Agent / Cursor

See `.cursor/rules/fog-regression-gate.mdc` — run smoke after fog edits, finish with atomic commit.
