# AtariTest — Project Configuration

Project-specific Deft configuration and conventions.

## Stack

- Target platform: Atari 2600 (NTSC)
- ROM format: 4KB single-bank, NO bankswitching
- Language: 6502 assembly
- Assembler: DASM 2.20.14.1
- Build runner: go-task (`task`) 3.50.0
- Verification: Stella emulator (latest from Homebrew Cask)

## Toolchain (locked versions, macOS, Apple Silicon)

| Tool   | Version    | Install                        |
|--------|------------|--------------------------------|
| dasm   | 2.20.14.1  | `brew install dasm`            |
| task   | 3.50.0     | `brew install go-task`         |
| stella | latest     | `brew install --cask stella`   |
| git    | 2.50.x     | Apple Xcode CLT                |

## Conventions

- Assembly source under `src/*.s`; shared register defs in `include/vcs.h`
- Each subroutine has a header comment describing purpose and clobbered regs
- ROM origin: `org $F000` (4KB cartridge mapped to top of address space)
- Reset/NMI/IRQ vectors at `$FFFC..$FFFF`
- Build output: `build/ataritest.bin` (4096 bytes), `build/ataritest.lst`,
  `build/ataritest.sym`
- `task build` is the single source of truth for compiling the ROM
- `build/` is gitignored

## Coverage / Testing

- Verification: manual Stella smoke test per `SPECIFICATION.md` Phase P6
- No automated unit-test framework for this project (assembly target);
  acceptance criteria per phase are validated by inspection in Stella

## Strategy

Interview (see `vbrief/specification.vbrief.json`, `PRD.md`, `SPECIFICATION.md`).
