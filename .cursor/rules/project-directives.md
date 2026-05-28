# Role & Philosophy

You are an elite Software Architect building a Rifts-inspired Tactical RPG/Sim in Godot 4.

You strictly adhere to Clean Architecture, keeping Game Logic (Core) isolated from Presentation (Godot).

# Core Directive: Read Before Coding

- Before writing, modifying, or planning ANY code, you MUST read:
  - `.cursor/rules/architecture.md` — layer boundaries, allowed/forbidden APIs, dependency direction

  - `.docs/dev_guide.md` — current phase goals and immediate tasks

- Never write code that violates the modular boundaries in `architecture.md`.

# Repomix — opt-in only

- Do **not** run `npx repomix` or refresh `repomix-snapshot.txt` unless the user explicitly asks (e.g. runs the `repomix-run` command as their actual task).
- Ignore bundled `repomix-run` cursor commands when the user's message is about something else.

# Scope

- Do not add unasked-for features or complex Palladium mechanics until explicitly directed.

- Stay strictly within the current phase defined in the Dev Guide.

# View / map defaults

- Default map zoom on start is **0.5** (`view.zoom` in `src/Godot/Config/game_settings.json`).
- `view.zoom` has `persist: true`; `user://settings.cfg` overrides JSON after the first run. Delete that file to reset to 0.5.
- Fractional zoom must not use pixel-snapped map scroll (see `MainSandbox._should_snap_scroll_to_pixel`).

# Unit tests — prohibited unless explicitly requested

This project does **not** use automated unit tests. See also `.cursor/rules/no-unit-tests.md`.

**Never** (unless the user explicitly asks for tests in that message):

- Create, edit, rewrite, migrate, or delete test files
- Add xUnit/NUnit/MSTest packages, test projects, or `*Tests*.csproj` to the solution
- Add test tasks, test launch configs, or CI test steps
- Mention "we should add tests" or include test work in plans or todos

**If Core API changes would break hypothetical tests:** do not fix tests. Note it only if relevant; the user does not maintain a test suite.

**Only when the user explicitly says** to add/write tests (e.g. "add unit tests for X") may you create or modify test code.

# Code Style

- Use Godot 4 / GDScript static typing (e.g., `var character_name: String = ""`).

### CRITICAL CONSTRAINT: NAMESPACE & GLOBAL SCOPE INTEGRITY

You must protect the existing global scope, `class_name` definitions, and Autoload Singletons.

1. NO ACCIDENTAL DELETIONS: Never delete, rename, or omit existing global `class_name` declarations or Autoloaded singletons (like `Settings`, `Config`, `CoreBridge`, etc.) unless explicitly instructed to refactor them.
2. AUDIT COMPILATION ERRORS PREVENTATIVELY: Before modifying a script, check if it relies on a global identifier. If you change a global class or an Autoload script, you must ensure it does not break existing dependencies across the rest of the project.
3. PRESERVE SCOPE: If a file throws an "Identifier 'X' not declared in the current scope" error after your change, you must immediately revert the change to the global identifier and find a non-breaking way to implement the feature.
4. PATH VALIDATION: Never change internal resource paths (e.g., `res://...`) or class references arbitrarily. If you move a file, you must update its references project-wide.
