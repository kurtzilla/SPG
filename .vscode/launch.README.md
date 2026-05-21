# VS Code / Cursor launch configs

Full debug and external-editor notes: [`.docs/dev_guide.md`](../.docs/dev_guide.md).

## Quick pick

| Config | Use when |
|--------|----------|
| **GDScript: Launch Main Project** | Default F5 — editor **closed**; builds C# then runs game |
| **GDScript: Launch Main Project (no build)** | Godot editor **open**; avoids reload / assembly prompts from `dotnet build` |
| **Godot: Run Project (direct)** | Godot Tools launch broken; runs exe in terminal |
| **GDScript: Attach to Editor** | Godot editor already running; remote debug port 6007 |

## Reload dialog on F5

Enable **Auto Reload Scripts on External Change** in Godot (Editor Settings). Do not run F5 **Launch** while the Godot editor is open on the same project unless you use **(no build)**.
