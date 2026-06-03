# VS Code / Cursor launch configs

Full debug and external-editor notes: [`.docs/dev_guide.md`](../.docs/dev_guide.md).

## Quick pick

| Config | Use when |
|--------|----------|
| **GDScript: Launch Main Project** | Default F5 — **verify-spg** (build + grid-smoke), then runs game |
| **GDScript: Launch Main Project (no build)** | Godot editor **open**; skips verify (run **grid-smoke** manually if you changed that system) |
| **Godot: Run Project (direct)** | Godot Tools launch broken; runs exe in terminal |
| **GDScript: Attach to Editor** | Godot editor already running; remote debug port 6007 |

## Reload dialog on F5

Enable **Auto Reload Scripts on External Change** in Godot (Editor Settings). Do not run F5 **Launch** while the Godot editor is open on the same project unless you use **(no build)**.

## Regression gates

- Grid: [`tools/GRID_REGRESSION.md`](../tools/GRID_REGRESSION.md) — task **grid-smoke**
- F5 preLaunch: **verify-spg** (build + grid-smoke). One-time: **install-git-hooks** for commit-time checks.
