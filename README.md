# Bit War!  For the Atari 2600

A 4KB NTSC Atari 2600 game ROM written in 6502 assembly and built with DASM.
Two joysticks each control a sprite (acceleration + friction movement) and can
fire a single-pixel missile in any of 8 directions.

## Title Screen

The title screen features a custom bitmap-art title drawn as a row-major
bit-array template (line-height 1, one scanline per row) using an asymmetric
playfield.  The playfield color cycles between shades of blue and yellow, and
a **TRON-style E-minor arpeggio** loops in the background.  Pressing fire on
either joystick starts gameplay.

## Gameplay

- A score band at the top of the screen shows two single-digit scores. First
  to **8 hits** wins (best of 15).
- **Game select**: the SWCHB Select switch toggles between Game 1
  (single-player vs AI) and Game 2 (two-player).  In Game 1, whichever
  stick fires first is human; the other becomes AI.
- The two console **difficulty switches** (SWCHB bits 6/7) gate per-player
  acceleration. Pro/A accelerates every frame; Novice/B only every other
  frame.
- **Stored playfield layouts** (5 unique designs cycling per round) provide
  walls that block player motion and reflect missiles.
- **Pickups** spawn periodically and award a random +1 or −1 to a random
  player's score when collected.
- On a player-vs-player overlap, a **bounce** pushes the sprites apart and
  the faster player is slowed.  Both sprites show a hollow outline during
  the bounce cooldown.
- When a score reaches 8 the game enters **GAME_OVER**: the winner's color
  rainbow-cycles, auto-fire missiles burst in random directions, and the
  loser flickers.  After ~4 seconds the game returns to the title screen.

## Sound Engine

A table-driven **per-frame sound engine** supports frequency sweeps and volume
envelopes on both TIA channels.  Sound effects are defined as compact 6-byte
records (duration, waveform, start freq, freq delta, start vol, vol decay):

- **Fire**: descending laser sweep (pure square)
- **Hit**: white-noise explosion decay
- **Bounce**: ascending poly4 "boing"
- **Pickup gain**: ascending chime
- **Pickup loss**: descending bonk
- **Title melody**: TRON-style AABA arpeggio (note-table sequencer)

## Code Architecture

Missile logic for both players is unified into parameterized subroutines
(`MissileUpdate`, `CelebSpawnMissile`, `CelebUpdateMissiles`, `ProcessHit`)
using X-indexed zero-page addressing with a consistent 12-byte offset between
the M0 and M1 variable blocks.  This eliminated ~390 bytes of duplicated code,
making room for the sound engine and title artwork.

See [PRD.md](./PRD.md) and [SPECIFICATION.md](./SPECIFICATION.md) for goals,
requirements, and the implementation plan.

## Toolchain (macOS)

Required tools (verified versions used during development):

- **DASM** 2.20.14.1 — 6502 assembler
- **go-task** (`task`) 3.50.0 — build runner
- **Stella** (latest) — Atari 2600 emulator for verification
- **Git** 2.50.x

### Install via Homebrew

```bash
brew install go-task dasm
brew install --cask stella
```

Verify:

```bash
task --version
dasm 2>&1 | head -n 1
ls -d /Applications/Stella.app
```

## Build

```bash
task build      # produces build/ataritest.bin (exactly 4096 bytes)
task run        # launch Stella with the built ROM
task clean      # remove build/
```

The build invokes DASM with format 3 (raw cartridge image), writes a listing
(`build/ataritest.lst`) and symbol file (`build/ataritest.sym`) alongside the ROM.

## Smoke test

After `task build`:

```bash
task run        # opens build/ataritest.bin in Stella
```

### Stella default key mapping (macOS)

- **P0 fire**: spacebar
- **P0 joystick**: arrow keys
- **P1 fire**: `4` on the numeric keypad
- **P1 joystick**: numeric keypad `8/2/4/6`

(Customize via Stella -> Options -> Input Settings if your keyboard doesn't have a numeric keypad.)

### Phased acceptance checklist

**Power-on / title (Phase P2)**
- [ ] Stable NTSC frame at 60Hz; no rolling, no flicker
- [ ] Centered "DEFT WARS" rendered ONCE across the screen via an asymmetric
      (non-mirrored) playfield with mid-line PF0/PF1/PF2 right-half writes
- [ ] Pressing fire on P0 OR P1 transitions to play state
- [ ] Pressing only a joystick direction (no fire) does NOT transition

**Game-over flow (v3 polish)**
- [ ] On reaching score 8, game enters GAME_OVER and the losing player
      flickers between its normal color and black for ~1 second
- [ ] After ~1 second the game auto-returns to the title screen
- [ ] Pressing fire during GAME_OVER returns to the title immediately
- [ ] Both scores reset to 0 when a new game starts from the title

**Players + movement (Phase P3)**
- [ ] Two color-distinct sprites in play state (yellow P0, cyan P1; identical shape)
- [ ] All 8 directions on each joystick produce visible motion at the same max speed
- [ ] Acceleration: brief ramp (1 px frame 1 -> 2 px frame 2+) when a direction is held
- [ ] Friction: sprite decelerates to a stop after the joystick is released
- [ ] Sprites cannot leave the visible playfield in any direction (clamp at edges)

**Missiles (Phase P4)**
- [ ] Edge-triggered fire: tapping fire spawns ONE missile per press; holding fire does NOT auto-fire
- [ ] Centered joystick + fire spawns NO missile
- [ ] All 8 joystick directions at the moment of fire produce a missile in that direction
- [ ] Each player has at most one active missile at a time
- [ ] Missile despawns cleanly at any screen edge; refire is allowed immediately
- [ ] Both players can fire simultaneously and independently

**Hit flash (Phase P5)**
- [ ] M0 hitting P1 produces a brief white flash on P1 (~6 frames) and consumes M0; play continues
- [ ] M1 hitting P0 produces a brief white flash on P0 and consumes M1
- [ ] No score, lives, position-reset, or game-over occurs on hit
- [ ] Flash on one player does not affect the other player's color

**Build (Phase P6)**
- [ ] `task build` produces `build/ataritest.bin` of EXACTLY 4096 bytes
- [ ] Two consecutive `task clean && task build` runs produce identical `task hash` output
- [ ] `dasm` reports `Complete. (0)` with no errors or warnings

Known deviations from `SPECIFICATION.md`:

- Kernel is **2-line** (sprite is 8 px wide x 16 physical scanlines tall) rather than the originally drafted 1-line 8x8 kernel. This was needed to fit the 4-object (2 players + 2 missiles) per-scanline cycle budget within 76 CPU cycles.
- Missiles are **1 px wide x 2 physical scanlines tall** (a small dot rather than a single TIA pixel). Visually equivalent to a single dot.
- Title screen uses a **custom bitmap** (row-major, line-height 1) instead of the original "DEFT WARS" glyph table.  Sound was listed as out-of-scope in the original PRD but has been fully implemented.

## Project layout

```
.
├── PRD.md                        # Product requirements
├── SPECIFICATION.md              # Rendered spec (do not edit; regenerate)
├── Taskfile.yml                  # Project build runner
├── src/                          # 6502 assembly source
│   └── main.s                    # all game code (single-file 4KB ROM)
├── include/                      # shared headers
│   └── vcs.h                     # TIA/RIOT register definitions
├── build/                        # build artifacts (gitignored)
└── vbrief/                       # specification source-of-truth (vBRIEF JSON)
```
