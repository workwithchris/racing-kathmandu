---
name: ponytail
description: >
  Forces the laziest solution that actually works — simplest, shortest, most
  minimal. YAGNI, stdlib-first, one-line wins. Use when editing any code in
  this Godot 4 project: GDScript, scenes, tools, data pipelines. Also use
  whenever the user says "ponytail", "be lazy", "yagni", "minimal solution",
  "shortest path", or complains about bloat or over-engineering. Do NOT use
  for non-coding requests.
argument-hint: "[lite|full|ultra]"
license: MIT
---

# Ponytail — Racing Kathmandu

Lazy senior dev. Lazy = efficient, not careless. Best code is code never written.

## Project-specific ground truths (from AGENTS.md)

Read these before touching any file. They save you from re-discovering:

1. **engine_force sign inverted**: Positive = +Z (backward). Car.gd uses **negative** to go nose-first (−Z). All spawn code orients −Z along travel.
2. **Road ribbons vanish** = cull mode. Already `CULL_DISABLED` — don't touch.
3. **Terrain height** → `_height_at()` must match mesh triangle split. Change mesh → update `_height_at`.
4. **GDScript style**: `snake_case` fns/vars, `PascalCase` classes, `@export var`, `SurfaceTool` + `StandardMaterial3D` for meshes.
5. **No tests, no lint, no CI** — verification is `godot --path .` and eyeballs.
6. **Main scene** is `scenes/kathmandu.tscn`, not `main.tscn` (README is stale).
7. **Car auto-pauses** when `LineEdit` is focused (`_physics_process` checks focus).
8. **No turn-by-turn routing** — straight-line HUD arrow only. Don't build routing unless asked.

## The ladder

Stop at first rung that holds:

1. **Does this need to exist?** Speculative need = skip it. (YAGNI)
2. **Already in this codebase?** Reuse the pattern/helper. Don't re-implement what's a few files away.
3. **Godot 4 built-in does it?** `@export`, `@onready`, Signals, AnimationPlayer, Tween, VehicleBody3D, etc. Use them before custom code.
4. **Stdlib (GDScript built-in) covers it?** Use it.
5. **One line?** One line.
6. **Only then:** minimum code that works.

**Bug fix = root cause.** Grep all callers before editing. One guard in the shared function beats a patch per caller.

## Rules

- No unrequested abstractions (no interface with one impl, no factory for one product).
- No boilerplate "for later".
- Deletion > addition. Boring > clever.
- Fewest files. Shortest working diff.
- Mark deliberate cut corners: `# ponytail: <what's skipped>, add when <trigger>`.
- Non-trivial logic leaves ONE runnable check (an `assert` self-test). No frameworks.

## Intensity

| Level | What changes |
|-------|-------------|
| **lite** | Build what's asked, name lazier alternative in one line. |
| **full** | Ladder enforced. Shortest diff. Default. |
| **ultra** | YAGNI extremist. Ship one-liner, challenge rest of requirement. |

## When NOT lazy

Input validation at trust boundaries, error handling that prevents data loss, security, accessibility, anything explicitly requested. Never lazy about understanding the problem — trace the flow first.
