# Grid regression gate

Automated checks for grid overlay silent failures (shader compile errors, wrong node wiring, bootstrap never initializing material).

## Run manually

```powershell
.tools/run_grid_smoke.ps1
```

Or VS Code/Cursor: **Tasks → grid-smoke** (builds C# first).

## On git commit

When staged files touch grid overlay paths, pre-commit runs grid-smoke (see `.tools/pre-commit.ps1`).

Partial commits of the **atomic set** are blocked unless:

```powershell
$env:GRID_SKIP_ATOMIC = "1"
git commit ...
```

### Atomic grid files (commit together)

| File | Role |
|------|------|
| `src/Godot/Shaders/GridOverlay.gdshader` | Shader |
| `src/Godot/Scripts/GridOverlay.gd` | Controller (CanvasLayer) |
| `src/Godot/Scenes/GridOverlay.tscn` | Scene wiring |

Also update `MainSandbox.gd` when changing `@onready` paths or bootstrap hooks.

### Never do this

```bash
git checkout HEAD -- src/Godot/Shaders/GridOverlay.gdshader   # without matching .gd + .tscn
```

## What smoke checks

1. `GridOverlay.gdshader` loads / compiles
2. `GridOverlay.tscn` — script on CanvasLayer, `GridDrawRect` + `GridDisplay` without scripts
3. `MainSandbox` — `$GridOverlay` wiring + `configure(true)` binds ShaderMaterial

## Performance notes

- `grid.debug_grid_lines` enables a debug overlay; default is **off** for higher idle FPS.
- With grid on, GPU work runs only when the view projection changes (`SubViewport` `UPDATE_ONCE`); idle intervals should show `gpu_refresh_count: 0` in `[GridPerf]` logs.

## Agent / Cursor

See `.cursor/rules/grid-regression-gate.mdc` — run smoke after grid edits, finish with atomic commit.
