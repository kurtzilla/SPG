# Godot ↔ Core interop (`src/Godot/Interop`)

GDScript reaches Core only through C# wrappers here and the **`CoreBridge`** autoload. This document covers binding rules that apply across features (future map layers, procedural buffers, etc.).

## Caller-owned buffers: `PackedByteArray` → `byte[]`

When GDScript passes a `PackedByteArray` to a C# parameter typed as `byte[]`, Godot **marshals a copy** into managed memory. The C# method mutates that copy. **The original `PackedByteArray` in GDScript is not updated.**

This affects any API shaped like `void DoWork(..., byte[] buffer)` or `int StampInto(..., byte[] buffer)`.

### Symptoms

- Core state updates correctly (e.g. model fields).
- GDScript buffer unchanged.
- Presentation breaks silently.

**Do not** assume in-place write-back after `*Into` calls.

### Correct patterns

| Goal | C# wrapper pattern | GDScript usage |
|------|-------------------|----------------|
| Mutate a caller buffer and use result | `byte[] FooNative(..., byte[] buffer)` — modify buffer, **return** `buffer` | `_bytes = PackedByteArray(obj.FooNative(..., _bytes))` |
| Allocate and fill a new buffer | `byte[] FooNative(...)` — allocate, fill, return | `_bytes = PackedByteArray(obj.FooNative(...))` |
| Core-only mutation (no GDScript buffer) | `void` / `int` return count only | No buffer assignment needed |

**Naming:** suffix **`Native`** on methods that return `byte[]` (or other blittable blobs) for GDScript assignment. Keep `*Into` only when callers accept binary-only fallback + separate sync.

### Adding new buffer APIs

1. Implement logic in `src/Core/` against `Span<byte>` or `byte[]`.
2. Expose on `*Gd.cs` wrapper in this folder.
3. If GDScript owns the buffer, expose **`*Native` return path** — do not rely on `*Into` write-back alone.
4. Document the GDScript assign step in the feature script (one-line comment + link here).

---

## Related

- [`.cursor/rules/architecture.md`](../../.cursor/rules/architecture.md) — layer boundaries
- [`CoreBridge.cs`](CoreBridge.cs) — factory entry points for models
