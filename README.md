# Racing — a 3D racing game (Godot 4)

A small 3D racing game built with Godot 4's built-in `VehicleBody3D` physics:
real suspension, steering, and traction, a chase camera, a walled circuit,
and a speed HUD.

## How to run

1. Install **Godot 4.3 or newer** (standard, non-.NET build is fine): https://godotengine.org/download
2. Open the Godot project manager → **Import** → select this folder's `project.godot`.
3. Press **F5** (or the ▶ Play button, top-right) to run.

## Controls

| Key            | Action              |
| -------------- | ------------------- |
| `W` / `↑`      | Accelerate          |
| `S` / `↓`      | Brake / reverse     |
| `A` `D` / `← →`| Steer               |
| `R`            | Reset car to start  |

## Project layout

- `scenes/main.tscn` — the world: track, barriers, lighting, camera, HUD (main scene).
- `scenes/car.tscn` — the car: body + 4 physics wheels.
- `scripts/car.gd` — reads input and drives the vehicle.
- `scripts/chase_camera.gd` — smooth follow camera.
- `scripts/main.gd` — speed HUD + reset handling.

## Easy things to tweak

- **Car feel:** select the `Car` node in `car.tscn` → Inspector → `max_engine_force`,
  `max_steer`, `max_brake`, etc. Grip lives on each `Wheel*` node
  (`wheel_friction_slip` — higher = more grip).
- **Camera:** select `ChaseCamera` in `main.tscn` → `distance`, `height`, `follow_speed`.
- **Track:** move/resize the `Wall*` and `Infield` boxes in `main.tscn`.

## Ideas for next steps

- Lap timer + checkpoints, spinning wheel visuals, engine sound,
  an AI opponent, or a proper curved track mesh.
