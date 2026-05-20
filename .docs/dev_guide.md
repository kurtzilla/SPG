# Developer Guide: Rifts Isometric Prototype



## 1. Current Phase: Minimum Viable Sandbox

The goal of this phase is strictly to achieve an isometric view with a 2-character party selection and grid movement. Do not implement complex Palladium rules yet.



## 2. Architecture Rules

- **Full modular boundaries** (dependency direction, allowed/forbidden APIs, layer flow): see [`.cursor/rules/architecture.md`](../.cursor/rules/architecture.md).

- **Core Folder (`src/Core/`):** Contains pure data structures.

  - `GridModel`: Tracks coordinates and what is on them (use `x`/`y` ints or plain coord objects — not `Vector2`).

  - `PartyModel`: Tracks the list of characters and who is currently selected.

  - `CharacterModel`: Holds basic data (ID, name, grid position).

- **Godot Folder (`src/Godot/`):** Contains visuals.

  - Reads data from the Core models and updates the Isometric TileMap and Sprites.

  - Passes player clicks back to the Core folder to handle selection and movement logic.



## 3. Immediate Goal

Create the data structures for the Grid and the Characters inside `src/Core/Models/`.

