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

## Zoom / view transition (manual)

At spawn without moving: wheel zoom out through all levels below default — reveal must stay the same **world** size as default (tracks terrain); player stays visible. Wheel zoom in — same check.

After changing fog buffer recenter or zoom hooks: zoom in/out stationary at spawn; reveal disc must track immediately (no pill trail); `[FogPerf] recenter_holes` should not spike 100ms+ per frame during wheel.

Walk across a cell boundary while zooming: fog must still recenter (queued cell recenter runs after deferred zoom body — not dropped).

## Move / stop edge parity (manual)

Walk in any direction: reveal edge/feather must match **while moving** and after stopping — no snap-back at trail or player disc. Repeat at default zoom and at min/max zoom while walking.

## East walk / recenter (manual)

Walk east 60+ cells from spawn **without zooming**. After the first buffer recenter, expect no horizontal ghost strips and no detached revealed blocks separated by fog from the explored trail.

## What smoke checks

1. `FogOverlay.gdshader` loads / compiles
2. `FogOverlay.tscn` — script on CanvasLayer, white `FogRect`, no script on rect
3. `MainSandbox` — `$FogOverlay` wiring + bootstrap sets `is_configured` + material bound

## Agent / Cursor

See `.cursor/rules/fog-regression-gate.mdc` — run smoke after fog edits, finish with atomic commit.
