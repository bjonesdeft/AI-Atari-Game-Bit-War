# AtariTest PRD

## Problem Statement
Demonstrate independent two-player joystick control on the Atari 2600 platform: each
player drives a sprite around the screen with momentum-based movement and can fire a
missile in the direction of joystick input. The artifact is a runnable ROM produced
with DASM that can be loaded in Stella for verification, intended as a controls and
build-pipeline proof of concept rather than a full game.

Audience: developers/learners exploring 2600 assembly, joystick handling, and the
DASM toolchain on macOS.

## Goals

### Primary Goal
- G1: Produce a 4KB Atari 2600 NTSC ROM (`build/ataritest.bin`) built with DASM that
  demonstrates two-joystick movement and 8-way missile firing for two players.

### Secondary Goals
- G2: Provide a title screen ("TEST GAME") on power-on; transition to gameplay on any
  fire-button press from either joystick.
- G3: Establish a Taskfile-driven build pipeline that compiles assembly to a runnable
  ROM with a single command.
- G4: Verify behavior via the Stella emulator on macOS through manual smoke testing.

### Non-Goals (explicitly out of scope for v1)
- NG1: Sound/audio.
- NG2: Score, HUD, lives, or game-over screen.
- NG3: Multiple levels or stages.
- NG4: AI/CPU opponents.
- NG5: Save state, high-score persistence, or difficulty switches.
- NG6: PAL build, bankswitching, or ROM sizes >4KB.
- NG7: Player-versus-player damage logic, respawn, or scoring on hit (only a brief
  visual flash on hit).

## User Stories
- US1: As a player, I want to move my sprite around the screen using my joystick so
  that I can navigate the playfield with smooth momentum-based controls.
- US2: As a player, I want to fire a missile in the direction my joystick is held so
  that I can shoot in any of eight directions.
- US3: As a player, I want firing to require a discrete button press (not auto-fire on
  hold) so that my shots feel intentional.
- US4: As a player, I want to see a title screen on power-on so that I know the game
  has loaded before gameplay starts.
- US5: As a player, I want to start the game by pressing fire on either joystick so
  that either player can begin play.
- US6: As a developer, I want a single build command that produces a runnable ROM so
  that I can iterate quickly.
- US7: As a developer, I want the ROM to load in Stella on macOS so that I can verify
  behavior without hardware.

## Requirements

### Functional Requirements

#### Title Screen
- FR-1: The ROM MUST display a title screen on power-on/reset that shows the text
  "TEST GAME" rendered using the playfield (PF) registers.
- FR-2: The title screen MUST transition to gameplay when the fire button on EITHER
  joystick (P0 or P1) is pressed.
- FR-3: The title screen MUST NOT transition based on joystick directional input
  alone.

#### Player Movement
- FR-4: Each joystick (P0, P1) MUST control exactly one corresponding sprite.
- FR-5: While a joystick direction is held, the corresponding sprite MUST accelerate
  in that direction up to a fixed maximum speed.
- FR-6: When no direction is held, the sprite MUST decelerate via friction toward
  zero velocity.
- FR-7: Both player sprites MUST be constrained within the visible playfield bounds
  of a standard NTSC Atari 2600 frame; sprites MUST NOT travel off-screen.
- FR-8: The two players MUST be visually distinguished by COLOR ONLY (identical
  sprite shape).

#### Missile Firing
- FR-9: Each player MUST have at most ONE active missile at any time.
- FR-10: Firing MUST be EDGE-TRIGGERED on the fire button: a new missile is launched
  only on a button press transition (must release and press again to fire again).
- FR-11: A missile MUST NOT be fired when the joystick is in the neutral/centered
  position (no direction held) at the moment of fire-button press.
- FR-12: When fired, a missile MUST travel in the direction of the held joystick,
  supporting all 8 directions: N, NE, E, SE, S, SW, W, NW.
- FR-13: A missile MUST be visually rendered as a single dot (1 TIA missile pixel).
- FR-14: A missile MUST despawn immediately when it reaches the edge of the visible
  playfield.

#### Player-vs-Player Interaction
- FR-15: When a missile collides with the OTHER player's sprite, the game MUST
  display a brief visual flash (e.g., short color change on the hit player) and
  continue play; the missile is consumed (despawned) by the hit.
- FR-16: A missile collision MUST NOT modify any score, lives, position-reset, or
  end the game.

#### Build / Toolchain
- FR-17: The project MUST build via a Taskfile target (`task build`) that invokes
  the DASM compiler on the assembly source.
- FR-18: The successful build artifact MUST be `build/ataritest.bin`, suitable for
  loading in Stella and on real hardware (4KB cartridge image).
- FR-19: The build MUST target the standard Atari 2600 4KB cartridge layout with NO
  bankswitching scheme.

### Non-Functional Requirements
- NFR-1: Performance — The ROM MUST run at NTSC 60Hz with stable frame timing
  (target: 262 scanlines per frame, no rolling).
- NFR-2: Compatibility — The ROM MUST load and run in the latest stable Stella
  emulator on macOS without errors.
- NFR-3: Size — The compiled ROM MUST fit within 4KB.
- NFR-4: Reproducibility — `task build` MUST produce a byte-identical ROM given the
  same source on the same DASM version.
- NFR-5: Toolchain — The build MUST work with DASM installed locally on macOS;
  installation steps MUST be documented (README or PROJECT.md).
- NFR-6: Maintainability — Assembly source files MUST be organized by concern
  (e.g., main kernel, title screen, input, movement, missile) and MUST include
  comments describing each subroutine's purpose.

## Success Metrics
- SM-1: `task build` completes without errors and produces `build/ataritest.bin` of
  exactly 4096 bytes.
- SM-2: Loading `build/ataritest.bin` in Stella on macOS shows a stable "TEST GAME"
  title screen at NTSC 60Hz with no visual artifacts.
- SM-3: Pressing fire on either joystick from the title screen reliably enters
  gameplay.
- SM-4: In gameplay, each joystick independently moves its sprite with visible
  acceleration and friction, and sprites cannot leave the visible playfield.
- SM-5: Each player can fire one missile at a time in 8 directions; missiles
  despawn cleanly at the screen edge.
- SM-6: A missile striking the opposing player triggers a brief, visible flash and
  gameplay continues uninterrupted.
- SM-7: All twelve interview decisions (see Open Questions / Decisions) are
  reflected in the implementation.

## Open Questions
- OQ-1: Exact movement tuning constants (acceleration rate, friction rate, max
  speed) — to be tuned during implementation against feel; initial values to be
  proposed in SPECIFICATION.
- OQ-2: Exact sprite shape/bitmap — to be defined in SPECIFICATION (constraint:
  identical for both players, distinguishable color palette).
- OQ-3: DASM version pinning policy on macOS (Homebrew vs. source build) — to be
  decided in SPECIFICATION.
- OQ-4: Whether to keep an extra debug build target (e.g., `task build:debug`)
  with assertions/symbol output — deferred; default to single release build.

## Decisions Locked (from Interview)
- D-1: ROM target: 4KB, no bankswitching.
- D-2: Player-on-player missile hit: brief visual flash, play continues.
- D-3: Missiles per player: 1 active at a time.
- D-4: Movement model: acceleration + friction + max speed cap.
- D-5: Missile direction: 8-way (matches joystick direction at fire time).
- D-6: Missile boundary behavior: despawn at edge.
- D-7: Video timing: NTSC-first (60Hz); PAL deferred.
- D-8: Fire button: edge-triggered (no auto-fire).
- D-9: Player visual differentiation: different colors, identical sprite shape.
- D-10: Build pipeline: DASM via Taskfile (`task build`) producing
  `build/ataritest.bin`.
- D-11: Verification: Stella emulator on macOS, manual smoke test after each build.
- D-12: Out-of-scope (v1): sound, score/HUD, levels, AI opponents, game-over, save
  state.
