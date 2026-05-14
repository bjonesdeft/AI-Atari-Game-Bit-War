; main.s — AtariTest entry point.
;
; Phase P3: title screen + dual-sprite play kernel with integer-momentum
; movement and screen-bound clamping.
;
;   - VBLANK reads INPT4/INPT5 for fire (edge-detected) and SWCHA for joysticks.
;   - TITLE -> PLAY transition on either fire-press edge.
;   - In PLAY, each frame applies ACCEL on held axes, integer FRICTION toward
;     zero on released axes, clamps |V| <= MAX_SPEED, then advances X/Y and
;     clamps to PF_LEFT/RIGHT/TOP/BOTTOM. Velocity zeros at boundaries.
;   - Horizontal positioning uses the canonical sta WSYNC + RESP/HMOVE pattern
;     across two VBLANK scanlines (one per player).
;   - 1-line dual-sprite kernel: GRP0/GRP1 are pre-computed per scanline and
;     written within HBLANK (cycles 3, 6, 9, 12) so both sprites display
;     correctly regardless of horizontal position.
;
; ROM layout: 4KB single-bank, no bankswitching. Origin $F000; reset/IRQ
; vectors at $FFFC..$FFFF.
;
; Sprite: 8x8 diamond, identical for both players; players differ by COLOR ONLY.

        processor 6502
        include "vcs.h"

;---------------------------------------------------------------
; Zero-page variables
;---------------------------------------------------------------
GameState   equ $80   ; 0 = TITLE, 1 = PLAY
P0FirePrev  equ $81   ; INPT4 prev frame (bit 7: 1=released)
P1FirePrev  equ $82
P0FireEdge  equ $83   ; bit 7 = press edge this frame
P1FireEdge  equ $84

P0X         equ $85   ; pixel X (0..159 visible; valid PF_LEFT..PF_RIGHT)
P0Y         equ $86   ; top scanline of sprite (1..184 in visible region)
P0VX        equ $87   ; signed velocity (two's complement)
P0VY        equ $88
P1X         equ $89
P1Y         equ $8A
P1VX        equ $8B
P1VY        equ $8C

P0RowState  equ $8D   ; sprite row counter (0..7 = drawing, else off)
P1RowState  equ $8E
P0Curr      equ $8F   ; pre-computed GRP0 byte for next scanline
P1Curr      equ $90   ; pre-computed GRP1 byte for next scanline

; Missile state.  bit 7 of MxActive set => active.
; M0 and M1 are laid out as two contiguous 12-byte blocks so a single
; subroutine can service both via lda M0Active,X (X=0 for M0, X=MIS_OFFSET
; for M1).  All per-missile variables are at the same relative offset.
MIS_OFFSET  equ 12    ; M1 block = M0 block + 12
; --- M0 block ($91..$9C) ---
M0Active    equ $91   ; +0  bit 7 set => active
M0X         equ $92   ; +1
M0Y         equ $93   ; +2
M0DX        equ $94   ; +3  signed: -MISSILE_SPEED, 0, +MISSILE_SPEED
M0DY        equ $95   ; +4
M0RowState  equ $96   ; +5  init = (1-M0Y) when active, else 0
M0Curr      equ $97   ; +6  precomputed ENAM0 byte ($00 or $02)
M0XPrev     equ $98   ; +7
M0YPrev     equ $99   ; +8
M0XPrev2    equ $9A   ; +9
M0YPrev2    equ $9B   ; +10
M0Life      equ $9C   ; +11 frames remaining before auto-despawn
; --- M1 block ($9D..$A8) ---
M1Active    equ $9D   ; +0
M1X         equ $9E   ; +1
M1Y         equ $9F   ; +2
M1DX        equ $A0   ; +3
M1DY        equ $A1   ; +4
M1RowState  equ $A2   ; +5
M1Curr      equ $A3   ; +6
M1XPrev     equ $A4   ; +7
M1YPrev     equ $A5   ; +8
M1XPrev2    equ $A6   ; +9
M1YPrev2    equ $A7   ; +10
M1Life      equ $A8   ; +11

P0FlashCount equ $A9  ; frames remaining of P0 hit-flash (0 = no flash)
P1FlashCount equ $AA
FireSoundCount equ $AB ; frames remaining of fire sound on AUDC0
HitSoundCount  equ $AC ; frames remaining of hit sound on AUDC1
BounceCool     equ $AD ; frames remaining where joystick input is ignored
                       ; after a P0-P1 bounce, so the negated velocity has
                       ; time to actually separate the sprites.

; v3 state
P0Score      equ $AE   ; 0..8
P1Score      equ $AF
RoundTimer   equ $B0   ; ROUND_OVER pause counter (frames)
AIFlags      equ $B1   ; bit 7 set = P0 is AI; bit 6 set = P1 is AI
FrameCounter equ $B2   ; increments every frame; LSB used for difficulty gate
P0DigitBase  equ $B3   ; precomputed P0Score * 8 (offset into DigitGfx)
P1DigitBase  equ $B4   ; precomputed P1Score * 8
AIFireCool   equ $B5   ; per-frame countdown until next AI fire attempt
GameOverWin  equ $B6   ; 0 = P0 wins, 1 = P1 wins (only valid in GAME_OVER)
SynthSWCHA   equ $B7   ; SWCHA copy with AI players' bits overridden
SpriteCache  equ $B8   ; 8-byte sprite-row cache ($B8..$BF)
AIRand       equ $C0   ; LCG-driven pseudo-random byte; gates AI movement

; Pre-update positions, used to revert on wall collisions.
; Prev = position one frame ago, Prev2 = position two frames ago.
; Wall hit reverts to Prev2 (Prev is itself often inside the wall).
P0XPrev      equ $C1
P0YPrev      equ $C2
P1XPrev      equ $C3
P1YPrev      equ $C4
P0XPrev2     equ $C5
P0YPrev2     equ $C6
P1XPrev2     equ $C7
P1YPrev2     equ $C8
TempSpeed    equ $C9   ; scratch byte for collision-slowdown speed compare
TempScratch  equ $CA   ; general scratch byte (e.g. second speed sum)

; Stored-layout playfield renderer state, refreshed each round in
; LoadLayout.  The play kernel walks a list of "bands" in ROM, where
; each band is (start_iter, PF1, PF2) = 3 bytes.  PF0 is always $00
; (every stored layout keeps the leftmost 16 pixels clear so the spawn
; columns stay safe) and is written once in the kernel preamble.
; On every iter, X (downcounting 86..1) is compared against
; NextBandIter; on match, the band's PF1/PF2 pair is written and the
; pointer advances to the next band.  The list ends with a sentinel
; start_iter=0 that X (1..86) never matches, so PF stays stable after
; the last real band.  The full PlayfieldLayouts table is aligned
; into a single 256-byte ROM page so BandPtrL never carries during
; the kernel walk and we can omit the bcc/inc BandPtrH handling.
BandPtrL     equ $CB   ; lo byte of (BandPtr) -> current band
BandPtrH     equ $CC   ; hi byte of (BandPtr)
NextBandIter equ $CD   ; iter at which the band check fires next
LayoutIndex  equ $CE   ; index into PlayfieldLayouts (cycles per round)
MxJoyVal     equ $CF   ; scratch: shifted joystick for missile spawn
             ; $D0 reserved
WallColor    equ $D1   ; randomized COLUPF for each round (kept)

; Game-select state (controlled by SWCHB Select switch on the TITLE screen).
;   GameVariant = 1  -> single-player vs AI; whichever stick fires first is human.
;   GameVariant = 2  -> two-player; both sticks are human.
; SelectPrev caches SWCHB bit 1 to do press-edge detection on the Select switch
; ($00 = pressed, $02 = released).
GameVariant  equ $D2
SelectPrev   equ $D3

; Per-frame cached COLUP values.  Computed once in VBLANK by the
; ApplyP0Color/ApplyP1Color helpers and re-loaded by the score-band
; transition so the play-kernel start scanline is deterministic.
; (Inline color logic varied by ~10–20 cycles depending on hit-flash /
; GAME_OVER state, which crossed the 76-cycle scanline boundary on
; some frames and shifted the walls 1 line up/down vs other frames.)
P0CurrentColor equ $D4
P1CurrentColor equ $D5

; Pickup state.  PickupActive bit 7 set => the pickup is currently visible
; on the play field; either player overlapping it (CXP0FB / CXP1FB bit 6)
; consumes it.  When invisible, PickupTimer counts down frames until the
; next spawn (random 5..9.25 seconds).
;
; The pickup's visible silhouette is a '+' built by *flicker compositing*
; the TIA ball between two configurations on alternating frames (30Hz):
;   - Frame A (FrameCounter bit 0 = 0): 8px-wide x 2-scanline horizontal
;     stripe at the pickup's vertical midline.  CTRLPF=$31.
;   - Frame B (bit 0 = 1): 2px-wide x 10-scanline vertical column over
;     the full pickup band.  CTRLPF=$11.
; Both shapes share the same vertical centre, so the retinal composite
; reads as a '+' silhouette.  The per-frame configuration is encoded in
; PickupCtrlPF (CTRLPF byte) and the existing PickupStartIter /
; PickupEndIter cpx targets in the kernel — no per-iter kernel writes,
; no extra walker, no cycle pressure on the band walker.  All four ZP
; bytes are recomputed each frame in the pickup VBLANK block from the
; stable PickupY base.
PickupActive   equ $D6
PickupX        equ $D7
PickupY        equ $D8
PickupTimer    equ $D9   ; lo byte of frames-until-respawn
PickupTimerHi  equ $DA   ; hi byte of frames-until-respawn
PickupStartIter equ $DB  ; iter-counter X value where ENABL turns on  (per-frame)
PickupEndIter   equ $DC  ; iter-counter X value where ENABL turns off (per-frame)
PickupCtrlPF    equ $DD  ; CTRLPF for the play kernel preamble (mirror + ball size)

; AI fire telegraph counter.  When AIFireCool expires, instead of firing
; immediately the AI starts AIFireTelegraph counting down for ~0.4s.
; During the telegraph the firing AI's sprite flashes white so the
; opposing player has time to dodge.  When the telegraph hits 0 the
; missile is spawned with aim locked strictly toward the opponent's
; current position (ignoring random-skip / deadzone gates).
AIFireTelegraph equ $DE

; AI wall-stuck recovery state.  When an AI player's wall-revert fires
; (player ran into a playfield block while chasing the opponent), the
; AI enters a "creep" mode for AI_STUCK_FRAMES frames where its joystick
; bits in SynthSWCHA are forcibly overridden to a single direction press.
;
; Direction selection cycles deterministically through {up, right, down,
; left} via AIStuckDirIdx, advanced on every wall-hit.  This guarantees
; that within four wall bumps the AI has TRIED EVERY perpendicular and
; parallel direction, so even when one direction is also blocked the AI
; rotates to a different side instead of repeatedly picking the same
; bad direction at random.  AIStuckMask is AND'ed and AIStuckOR is OR'ed
; onto SynthSWCHA each frame the timer is non-zero (mask preserves the
; human player's bits; OR injects the chosen creep direction).
AIStuckTimer  equ $DF
AIStuckMask   equ $E0
AIStuckOR     equ $E1
AIStuckDirIdx equ $E2  ; 0..3 = up,right,down,left

; Sound engine per-channel state.  Each channel has a frame counter,
; current freq/vol, and per-frame deltas for sweeps/envelopes.
Snd0Count   equ $E3   ; frames remaining (0 = silent)
Snd0Freq    equ $E4   ; current AUDF value
Snd0FreqDt  equ $E5   ; signed AUDF delta per frame
Snd0Vol     equ $E6   ; current AUDV value
Snd0VolDt   equ $E7   ; AUDV decrement per frame (unsigned, subtracted)
Snd1Count   equ $E8
Snd1Freq    equ $E9
Snd1FreqDt  equ $EA
Snd1Vol     equ $EB
Snd1VolDt   equ $EC

; Title melody sequencer state.
MelodyIdx   equ $ED   ; byte offset into TitleMelody (advances by 2 per note)
MelodyTimer equ $EE   ; frames remaining on current note (0 = advance)

;---------------------------------------------------------------
; Constants
;---------------------------------------------------------------
TITLE_COLOR  equ $0E  ; near-white
P0_COLOR     equ $1E  ; bright yellow
P1_COLOR     equ $9C  ; bright cyan/blue
FLASH_COLOR  equ $0E  ; bright white during hit flash
FLASH_FRAMES equ 6    ; ~100ms hit flash at 60Hz
BOUNCE_FRAMES equ 16  ; ~267ms input lockout after a player-vs-player bounce
BOUNCE_SPEED  equ 3   ; outward velocity (px/frame) applied on bounce (>MAX_SPEED)
AI_DEADZONE   equ 24  ; AI stops on an axis when within this distance to opponent

; v3 game-state values
ST_TITLE      equ 0
ST_PLAY       equ 1
ST_ROUND_OVER equ 2
ST_GAME_OVER  equ 3

WIN_SCORE     equ 8         ; first to 8 wins (best of 15)
ROUND_PAUSE   equ 60        ; ~1s pause after a successful hit
GAME_OVER_DURATION equ 240  ; ~4s celebration window before auto-return to TITLE
VARIANT_DIGIT_COLOR equ $4E ; bright red so the variant digit contrasts with the white title
NUM_LAYOUTS   equ 5        ; count of entries in PlayfieldLayouts (cycled per round)
AI_FIRE_PERIOD equ 90       ; AI tries to fire every ~1.5s
AI_FIRE_TELEGRAPH equ 24    ; ~0.4s telegraph window between decision and shot
AI_STUCK_FRAMES equ 36      ; ~0.6s of creep after AI hits a wall (clears most
                            ; layout block heights at the 2px/frame MAX_SPEED)
SCORE_BAND    equ 16        ; physical scanlines reserved at top for score
SCORE_P0_X    equ 36        ; pixel X of P0 score digit on score band
SCORE_P1_X    equ 108       ; pixel X of P1 score digit on score band
SCORE_DIGIT_TOP equ 5       ; first scoreband line where digit appears (1..8)

; Sound definition table offsets (index into SndDefs, 6 bytes each).
SND_FIRE      equ 0    ; ch0: descending laser sweep
SND_HIT       equ 6    ; ch1: white-noise explosion decay
SND_BOUNCE    equ 12   ; ch1: ascending boing
SND_PICKUP_HI equ 18   ; ch1: gain chime (ascending sweep)
SND_PICKUP_LO equ 24   ; ch1: loss bonk  (descending sweep)
SND_TELEPORT  equ 30   ; ch0: rapid descending poly4 sweep (Combat-style)

PICKUP_HEIGHT equ 5    ; iters (10 scanlines tall)

MAX_SPEED     equ 2   ; player pixels/frame (integer)
MISSILE_SPEED equ 4   ; missile pixels/frame on each held axis
MISSILE_LIFE  equ 30  ; ~0.5s lifespan; despawn even if still bouncing

PF_LEFT     equ 4     ; min X (sprite is 8 wide)
PF_RIGHT    equ 148   ; max X (sprite top-left pixel)
PF_TOP      equ 8     ; min Y (top scanline of sprite within the PLAY area)
PF_BOTTOM   equ 156   ; max Y — sprite is 16 phys lines tall and the play
                      ; area is only 172 lines (after score band + transition)

; Missile bounds — missile is rendered when its iter post-inc state hits 0,
; which can only happen for iter 1..85 (= MxY/2 in 1..85 -> MxY in 2..170).
MPF_LEFT    equ 8
MPF_RIGHT   equ 156
MPF_TOP     equ 1
MPF_BOTTOM  equ 170

INIT_P0X    equ 50
INIT_P0Y    equ 92
INIT_P1X    equ 100
INIT_P1Y    equ 92

        seg.u VARS
        org $80

        seg CODE
        org $F000

;---------------------------------------------------------------
; Reset entry point
;---------------------------------------------------------------
Reset:
        sei
        cld
        ldx #$FF
        txs

        ; Clear all TIA registers and zero-page RAM.
        lda #0
ClearLoop:
        sta $00,x
        dex
        bne ClearLoop
        sta $00,x

        ; Initialize player positions (velocities are already 0).
        lda #INIT_P0X
        sta P0X
        lda #INIT_P0Y
        sta P0Y
        lda #INIT_P1X
        sta P1X
        lda #INIT_P1Y
        sta P1Y

        ; Seed AIRand to a non-zero value so the LCG progresses.
        lda #$5A
        sta AIRand

        ; Default to single-player Game 1; SelectPrev=$02 means "released"
        ; so the first button press toggles cleanly.
        lda #1
        sta GameVariant
        lda #$02
        sta SelectPrev

        ; First gameplay screen always uses stored layout 0.  Each round
        ; transition (and each new game) refreshes this; explicit init
        ; here covers the very first frame in case any pre-title code
        ; reads it.
        lda #0
        sta LayoutIndex

;---------------------------------------------------------------
; Main frame loop — NTSC: 3 VSYNC + 37 VBLANK + 192 visible + 30 overscan
;---------------------------------------------------------------
FrameLoop:

        ;-------------------------------------------------------
        ; VSYNC (3 scanlines)
        ;-------------------------------------------------------
        lda #2
        sta VSYNC
        sta WSYNC
        sta WSYNC
        sta WSYNC
        lda #0
        sta VSYNC

        ; Time the VBLANK region with TIM64T so its length is independent
        ; of how many cycles the variable-length logic block consumes.
        ; 43 * 64 = 2752 cycles ~= 36 scanlines; the WAIT poll + sta WSYNC
        ; below pad us out to 37 scanlines of VBLANK.
        lda #43
        sta TIM64T

        ;-------------------------------------------------------
        ; VBLANK (37 scanlines)
        ;   Line 1   : game logic (fire edge, title transition,
        ;              joystick read + movement update + clamping,
        ;              kernel state setup).
        ;   Line 2   : horizontal-position P0 (PositionX uses sta WSYNC).
        ;   Line 3   : horizontal-position P1.
        ;   Line 4   : sta HMOVE.
        ;   Lines 5-37: wait via WSYNC.
        ;-------------------------------------------------------

        ; --- Edge-detect P0 fire ---
        lda INPT4
        eor #$80
        and P0FirePrev
        sta P0FireEdge
        lda INPT4
        sta P0FirePrev

        ; --- Edge-detect P1 fire ---
        lda INPT5
        eor #$80
        and P1FirePrev
        sta P1FireEdge
        lda INPT5
        sta P1FirePrev

        inc FrameCounter        ; tick once per frame; LSB drives novice gating

        ; Update AIRand each frame using a simple LCG (x*5 + 1 mod 256).
        ; Used to gate AI direction-press inputs so AI follow doesn't track
        ; the opponent perfectly.
        lda AIRand
        asl
        asl
        clc
        adc AIRand
        clc
        adc #1
        sta AIRand

        ; --- Per-state dispatch ---
        ; ST_TITLE       -> wait for fire to start a new game (resets scores).
        ; ST_PLAY        -> normal movement / missile / collision processing.
        ; ST_ROUND_OVER  -> brief pause after a hit; reset positions on expiry.
        ; ST_GAME_OVER   -> winner displayed via final scores; fire returns to TITLE.
        lda GameState
        bne NotTitleState        ; ST_TITLE = 0

        ; --- TITLE state ---
        ; Press-edge detect the SWCHB Select switch (bit 1) and toggle
        ; GameVariant between 1 and 2.  This runs every TITLE frame so
        ; the on-screen variant digit updates immediately.
        lda SWCHB
        and #$02
        sta TempScratch          ; current Select state ($00 pressed, $02 released)
        eor #$02                 ; A=$02 if pressed, $00 if released
        and SelectPrev           ; SelectPrev bit 1 = $02 only when prev frame released
        beq NoSelectEdge
        lda GameVariant
        eor #$03                 ; XOR with 3 toggles 1<->2
        sta GameVariant
NoSelectEdge:
        lda TempScratch
        sta SelectPrev

        lda P0FireEdge
        ora P1FireEdge
        bmi DoTitleStart        ; bit 7 set => press edge present (long-form)
        jmp TitleMelodyTick     ; run melody sequencer, then sound engine
DoTitleStart:
        ; AI assignment depends on the chosen game variant:
        ;   Game 1 (single player): whichever stick fired the title becomes
        ;     human; the other becomes AI.
        ;   Game 2 (two player):    AIFlags=0, both sticks are human.
        lda #0
        sta AIFlags
        ldx GameVariant
        cpx #2
        beq StartReset           ; Game 2: leave AIFlags = 0 (both human)
        bit P0FireEdge
        bmi P0PressedFire
        lda #$80                ; P0 didn't press => P0 is AI
        sta AIFlags
P0PressedFire:
        bit P1FireEdge
        bmi P1PressedFire
        lda AIFlags             ; P1 didn't press => P1 is AI
        ora #$40
        sta AIFlags
P1PressedFire:
StartReset:

        ; Reset everything for a fresh game.
        lda #0
        sta P0Score
        sta P1Score
        sta M0Active
        sta M1Active
        sta P0FlashCount
        sta P1FlashCount
        sta BounceCool
        sta RoundTimer
        sta PickupActive         ; pickup hidden until the first timer expiry
        sta LayoutIndex          ; first gameplay screen always uses stored layout 0
        sta AIFireTelegraph      ; ensure no stale telegraph carries over
        sta AIStuckTimer         ; clear any stale wall-creep state
        lda AIRand               ; seed direction index with current entropy
        and #$03
        sta AIStuckDirIdx
        lda #AI_FIRE_PERIOD
        sta AIFireCool           ; full cooldown before first AI shot
        lda #0
        jsr ResetPickupTimer     ; seed initial 5..9.25s spawn delay
        jsr LoadLayout           ; point band ptr at the active stored layout
        jsr SpawnPlayers         ; place players safely off the walls
        lda #0
        sta Snd0Count           ; stop melody so engine mutes ch0
        lda #ST_PLAY
        sta GameState
        jmp RunSoundDecay

NotTitleState:
        cmp #ST_PLAY
        beq InPlay
        cmp #ST_ROUND_OVER
        beq InRoundOver

        ; --- GAME_OVER state ---
        ; ~4 second celebration: the winner's color cycles through a rainbow
        ; (handled in the COLUP setup block) and we auto-fire its missile in
        ; random directions every 8 frames.  Both missiles are advanced and
        ; edge-despawned here because InPlay's missile update doesn't run in
        ; this state.  Input is intentionally blocked so the celebration can
        ; play uninterrupted; only the RoundTimer expiry returns to TITLE.
        dec RoundTimer
        beq GODoReset

        ; ----- Auto-fire winner's missile every 8 frames if inactive -----
        lda FrameCounter
        and #$07
        bne GOMissileUpd
        ldx GameOverWin
        bne GOTryFireM1
        ; P0 wins -> spawn M0 from P0 if free
        lda M0Active
        bmi GOMissileUpd
        jsr CelebSpawnM0
        jmp GOMissileUpd
GOTryFireM1:
        lda M1Active
        bmi GOMissileUpd
        jsr CelebSpawnM1
GOMissileUpd:
        ; ----- Advance + edge/lifespan despawn for both missiles -----
        jsr CelebUpdateMissiles
        jmp RunSoundDecay
GODoReset:
        lda #0
        sta P0Score
        sta P1Score
        sta P0FlashCount
        sta P1FlashCount
        sta BounceCool
        sta M0Active
        sta M1Active
        sta PickupActive        ; clear pickup so the next game spawns fresh
        sta AIFireTelegraph     ; clear any pending telegraph
        sta GameState           ; A=0 = ST_TITLE
        sta MelodyIdx           ; restart title melody from beginning
        sta MelodyTimer
        sta AUDV0               ; mute ch0 so melody starts clean
        jmp RunSoundDecay

InRoundOver:
        ; Brief pause after a successful hit. On timer expiry, reset
        ; positions/velocities/missiles for the next round.
        dec RoundTimer
        bne ROWaiting
        lda #0
        sta M0Active
        sta M1Active
        sta P0FlashCount
        sta P1FlashCount
        sta BounceCool
        ; Advance to next stored layout for the upcoming round; wrap at
        ; NUM_LAYOUTS so the iteration cycles indefinitely.
        lda LayoutIndex
        clc
        adc #1
        cmp #NUM_LAYOUTS
        bcc ROKeepIdx
        lda #0
ROKeepIdx:
        sta LayoutIndex
        jsr LoadLayout           ; point band ptr at the new layout
        jsr SpawnPlayers         ; place players safely off the walls
        lda #ST_PLAY
        sta GameState
ROWaiting:
        jmp RunSoundDecay

InPlay:
        ; --- Pickup timer / spawn ---
        ; If the pickup is invisible, count its 16-bit timer down each frame;
        ; when it hits zero, spawn a fresh pickup somewhere clear of the walls.
        ; If it's already visible, do nothing here -- its consumption is handled
        ; in the collision-processing section below via CXP0FB/CXP1FB bit 6.
        lda PickupActive
        bmi PickupTickDone
        sec
        lda PickupTimer
        sbc #1
        sta PickupTimer
        bcs PickupNoBorrow
        dec PickupTimerHi
PickupNoBorrow:
        lda PickupTimer
        ora PickupTimerHi
        bne PickupTickDone
        jsr SpawnPickup
PickupTickDone:

        ; --- Apply movement update (only in PLAY) ---
        ;
        ; SWCHA bit layout (active-low; 0 = pressed):
        ;   bit 7 = P0 right  bit 3 = P1 right
        ;   bit 6 = P0 left   bit 2 = P1 left
        ;   bit 5 = P0 down   bit 1 = P1 down
        ;   bit 4 = P0 up     bit 0 = P1 up

        ; --- Build SynthSWCHA: real bits for human players, computed
        ; direction-toward-opponent bits for AI players. All downstream
        ; input/missile-spawn code reads SynthSWCHA, not SWCHA directly.
        lda SWCHA
        sta SynthSWCHA

        ; P0 AI?
        bit AIFlags
        bpl P1AISynth
        ; Force P0 bits 4..7 to released, then clear bits only when
        ; outside the deadzone so AI doesn't crowd opponent.
        lda SynthSWCHA
        ora #$F0
        sta SynthSWCHA
        ; Random-skip gate: 25% of frames AI doesn't press horizontal.
        lda AIRand
        and #$03
        beq P0AIVert
        ; Horizontal: dx = P1X - P0X.  Skip if |dx| < AI_DEADZONE.
        lda P1X
        sec
        sbc P0X
        bmi P0AINegDx
        cmp #AI_DEADZONE
        bcc P0AIVert            ; |dx| < deadzone
        lda SynthSWCHA
        and #$7F                ; opponent to the right (>>= deadzone): press right
        sta SynthSWCHA
        jmp P0AIVert
P0AINegDx:
        cmp #(256-AI_DEADZONE)
        bcs P0AIVert            ; |dx| < deadzone (signed)
        lda SynthSWCHA
        and #$BF                ; opponent to the left: press left
        sta SynthSWCHA
P0AIVert:
        lda AIRand
        and #$0C
        beq P1AISynth
        lda P1Y
        sec
        sbc P0Y
        bmi P0AINegDy
        cmp #AI_DEADZONE
        bcc P1AISynth
        lda SynthSWCHA
        and #$DF                ; opponent below: press down
        sta SynthSWCHA
        jmp P1AISynth
P0AINegDy:
        cmp #(256-AI_DEADZONE)
        bcs P1AISynth
        lda SynthSWCHA
        and #$EF                ; opponent above: press up
        sta SynthSWCHA

P1AISynth:
        lda AIFlags
        and #$40
        beq SynthSWCHADone
        lda SynthSWCHA
        ora #$0F
        sta SynthSWCHA
        ; Random-skip gate: 25% of frames AI doesn't press horizontal.
        lda AIRand
        and #$30
        beq P1AIVert
        ; Horizontal: dx = P0X - P1X.  Skip if |dx| < AI_DEADZONE.
        lda P0X
        sec
        sbc P1X
        bmi P1AINegDx
        cmp #AI_DEADZONE
        bcc P1AIVert
        lda SynthSWCHA
        and #$F7                ; clear bit 3 (P1 right)
        sta SynthSWCHA
        jmp P1AIVert
P1AINegDx:
        cmp #(256-AI_DEADZONE)
        bcs P1AIVert
        lda SynthSWCHA
        and #$FB                ; clear bit 2 (P1 left)
        sta SynthSWCHA
P1AIVert:
        lda AIRand
        and #$C0
        beq SynthSWCHADone
        lda P0Y
        sec
        sbc P1Y
        bmi P1AINegDy
        cmp #AI_DEADZONE
        bcc SynthSWCHADone
        lda SynthSWCHA
        and #$FD                ; clear bit 1 (P1 down)
        sta SynthSWCHA
        jmp SynthSWCHADone
P1AINegDy:
        cmp #(256-AI_DEADZONE)
        bcs SynthSWCHADone
        lda SynthSWCHA
        and #$FE                ; clear bit 0 (P1 up)
        sta SynthSWCHA
SynthSWCHADone:

        ; --- AI wall-stuck creep override ---
        ; If an AI player is in stuck-recovery (AIStuckTimer > 0), replace
        ; that player's SynthSWCHA bits with the saved perpendicular-creep
        ; direction so it slides along the wall instead of re-pressing the
        ; blocked toward-opponent direction.  Decrements the timer each
        ; frame; once it expires the normal toward-opponent logic above is
        ; back in charge.
        lda AIStuckTimer
        beq AIStuckOverrideDone
        dec AIStuckTimer
        lda SynthSWCHA
        and AIStuckMask
        ora AIStuckOR
        sta SynthSWCHA
AIStuckOverrideDone:

        ; --- AI fire logic with telegraph + aim lock ---
        ; Sequence (per AI player, shared timers):
        ;   1. AIFireCool counts down between shots (AI_FIRE_PERIOD frames).
        ;   2. When AIFireCool hits 0, AIFireTelegraph is seeded with
        ;      AI_FIRE_TELEGRAPH (~0.4s) and AIFireCool restarts.  During
        ;      the telegraph the firing AI's sprite flashes (ApplyPxColor)
        ;      so the opponent can react.
        ;   3. When AIFireTelegraph hits 0, the missile is spawned with
        ;      its joystick state forcibly aimed at the opponent's CURRENT
        ;      position, bypassing the random-skip / deadzone gates that
        ;      sometimes leave the joystick neutral and waste shots.
        lda AIFireTelegraph
        beq AIFireNoTele
        dec AIFireTelegraph
        bne AIFireDone           ; still telegraphing
        ; Telegraph just hit 0 -> fire with aim lock
        bit AIFlags
        bpl AIFireTeleP1
        lda M0Active
        bmi AIFireTeleP1         ; missile busy, skip
        jsr LockP0AimAndFire
AIFireTeleP1:
        lda AIFlags
        and #$40
        beq AIFireDone
        lda M1Active
        bmi AIFireDone
        jsr LockP1AimAndFire
        jmp AIFireDone
AIFireNoTele:
        lda AIFireCool
        beq AIFireCoolReady
        dec AIFireCool
        jmp AIFireDone
AIFireCoolReady:
        ; Cooldown expired - start telegraph if any AI has a free missile
        bit AIFlags
        bpl AIFireCoolP1Test
        lda M0Active
        bmi AIFireCoolP1Test
        lda #AI_FIRE_TELEGRAPH
        sta AIFireTelegraph
        jmp AIFireResetCool
AIFireCoolP1Test:
        lda AIFlags
        and #$40
        beq AIFireResetCool
        lda M1Active
        bmi AIFireResetCool
        lda #AI_FIRE_TELEGRAPH
        sta AIFireTelegraph
AIFireResetCool:
        lda #AI_FIRE_PERIOD
        sta AIFireCool
AIFireDone:

        ; --- Velocity clamp ---
        ; Bounce can leave |V| at BOUNCE_SPEED (>MAX_SPEED). Once the input
        ; lockout ends, drift back toward MAX_SPEED by 1/frame so the input
        ; logic (which assumes |V| <= MAX_SPEED) stays consistent.
        ; P0 X
        lda P0VX
        bmi VC_P0VX_Neg
        cmp #(MAX_SPEED+1)
        bcc VC_P0VX_OK
        dec P0VX
        jmp VC_P0VX_OK
VC_P0VX_Neg:
        cmp #(256-MAX_SPEED)
        bcs VC_P0VX_OK
        inc P0VX
VC_P0VX_OK:
        ; P0 Y
        lda P0VY
        bmi VC_P0VY_Neg
        cmp #(MAX_SPEED+1)
        bcc VC_P0VY_OK
        dec P0VY
        jmp VC_P0VY_OK
VC_P0VY_Neg:
        cmp #(256-MAX_SPEED)
        bcs VC_P0VY_OK
        inc P0VY
VC_P0VY_OK:
        ; P1 X
        lda P1VX
        bmi VC_P1VX_Neg
        cmp #(MAX_SPEED+1)
        bcc VC_P1VX_OK
        dec P1VX
        jmp VC_P1VX_OK
VC_P1VX_Neg:
        cmp #(256-MAX_SPEED)
        bcs VC_P1VX_OK
        inc P1VX
VC_P1VX_OK:
        ; P1 Y
        lda P1VY
        bmi VC_P1VY_Neg
        cmp #(MAX_SPEED+1)
        bcc VC_P1VY_OK
        dec P1VY
        jmp VC_P1VY_OK
VC_P1VY_Neg:
        cmp #(256-MAX_SPEED)
        bcs VC_P1VY_OK
        inc P1VY
VC_P1VY_OK:

        ; Decrement bounce cooldown each frame; when > 0, skip joystick
        ; input handling so the bounced velocities can actually separate
        ; the players before user input pushes them back together.
        lda BounceCool
        beq InputAllowed
        dec BounceCool
        jmp SkipJoyInput
InputAllowed:

        ;----- P0 horizontal -----
        ; Right pressed -> +ACCEL (cap at +MAX_SPEED).
        ; Left  pressed -> -ACCEL (cap at -MAX_SPEED).
        ; Neither       -> friction toward 0.
        lda SynthSWCHA
        and #$80                ; right?
        bne CheckP0Left
        lda P0VX
        cmp #MAX_SPEED          ; signed compare via N flag (VX in [-2..+2])
        bpl P0XDone             ; already at +MAX_SPEED
        jsr DiffGateP0
        bcc P0XDone             ; novice + odd frame: skip accel
        inc P0VX
        jmp P0XDone
CheckP0Left:
        lda SynthSWCHA
        and #$40                ; left?
        bne P0XFriction
        lda P0VX
        cmp #(256-MAX_SPEED)    ; -MAX_SPEED = $FE
        beq P0XDone             ; already at -MAX_SPEED -> skip dec
        jsr DiffGateP0
        bcc P0XDone
        dec P0VX
        jmp P0XDone
P0XFriction:
        lda P0VX
        beq P0XDone
        bmi IncP0VX             ; negative: increment toward 0
        dec P0VX
        jmp P0XDone
IncP0VX:
        inc P0VX
P0XDone:

        ;----- P0 vertical -----
        ; Up   pressed -> -ACCEL (cap at -MAX_SPEED).
        ; Down pressed -> +ACCEL (cap at +MAX_SPEED).
        ; Neither      -> friction toward 0.
        lda SynthSWCHA
        and #$10                ; up?
        bne CheckP0Down
        lda P0VY
        cmp #(256-MAX_SPEED)
        beq P0YDone             ; already at -MAX_SPEED
        jsr DiffGateP0
        bcc P0YDone
        dec P0VY
        jmp P0YDone
CheckP0Down:
        lda SynthSWCHA
        and #$20                ; down?
        bne P0YFriction
        lda P0VY
        cmp #MAX_SPEED
        bpl P0YDone
        jsr DiffGateP0
        bcc P0YDone
        inc P0VY
        jmp P0YDone
P0YFriction:
        lda P0VY
        beq P0YDone
        bmi IncP0VY
        dec P0VY
        jmp P0YDone
IncP0VY:
        inc P0VY
P0YDone:

        ;----- P1 horizontal -----
        lda SynthSWCHA
        and #$08                ; right?
        bne CheckP1Left
        lda P1VX
        cmp #MAX_SPEED
        bpl P1XDone
        jsr DiffGateP1
        bcc P1XDone
        inc P1VX
        jmp P1XDone
CheckP1Left:
        lda SynthSWCHA
        and #$04                ; left?
        bne P1XFriction
        lda P1VX
        cmp #(256-MAX_SPEED)
        beq P1XDone             ; already at -MAX_SPEED
        jsr DiffGateP1
        bcc P1XDone
        dec P1VX
        jmp P1XDone
P1XFriction:
        lda P1VX
        beq P1XDone
        bmi IncP1VX
        dec P1VX
        jmp P1XDone
IncP1VX:
        inc P1VX
P1XDone:

        ;----- P1 vertical -----
        lda SynthSWCHA
        and #$01                ; up?
        bne CheckP1Down
        lda P1VY
        cmp #(256-MAX_SPEED)
        beq P1YDone             ; already at -MAX_SPEED
        jsr DiffGateP1
        bcc P1YDone
        dec P1VY
        jmp P1YDone
CheckP1Down:
        lda SynthSWCHA
        and #$02                ; down?
        bne P1YFriction
        lda P1VY
        cmp #MAX_SPEED
        bpl P1YDone
        jsr DiffGateP1
        bcc P1YDone
        inc P1VY
        jmp P1YDone
P1YFriction:
        lda P1VY
        beq P1YDone
        bmi IncP1VY
        dec P1VY
        jmp P1YDone
IncP1VY:
        inc P1VY
P1YDone:

SkipJoyInput:

        ; --- Apply velocities to positions, then clamp to playfield bounds ---

        ; Shift previous positions: Prev2 := Prev, then Prev := current.
        ; Wall collision reverts to Prev2 because Prev is often itself inside
        ; the wall by the time the latch is read.
        lda P0XPrev
        sta P0XPrev2
        lda P0YPrev
        sta P0YPrev2
        lda P1XPrev
        sta P1XPrev2
        lda P1YPrev
        sta P1YPrev2
        lda P0X
        sta P0XPrev
        lda P0Y
        sta P0YPrev
        lda P1X
        sta P1XPrev
        lda P1Y
        sta P1YPrev

        ; P0 X
        clc
        lda P0X
        adc P0VX                ; signed add (P0VX is two's complement)
        ; sign extension for signed add: if P0VX is negative, A may go below 0;
        ; the carry/borrow handles 8-bit math. Since P0X is 0..159 (well within
        ; signed 8-bit range), simple 8-bit add works for small velocities.
        ; Clamp to [PF_LEFT, PF_RIGHT].
        cmp #PF_LEFT
        bcs P0XAbove
        ; A < PF_LEFT
        lda #PF_LEFT
        sta P0X
        lda #0
        sta P0VX
        jmp P0XClamped
P0XAbove:
        cmp #(PF_RIGHT+1)
        bcc P0XInRange
        ; A >= PF_RIGHT+1 -> too far right
        lda #PF_RIGHT
        sta P0X
        lda #0
        sta P0VX
        jmp P0XClamped
P0XInRange:
        sta P0X
P0XClamped:

        ; P0 Y
        clc
        lda P0Y
        adc P0VY
        cmp #PF_TOP
        bcs P0YAbove
        lda #PF_TOP
        sta P0Y
        lda #0
        sta P0VY
        jmp P0YClamped
P0YAbove:
        cmp #(PF_BOTTOM+1)
        bcc P0YInRange
        lda #PF_BOTTOM
        sta P0Y
        lda #0
        sta P0VY
        jmp P0YClamped
P0YInRange:
        sta P0Y
P0YClamped:

        ; P1 X
        clc
        lda P1X
        adc P1VX
        cmp #PF_LEFT
        bcs P1XAbove
        lda #PF_LEFT
        sta P1X
        lda #0
        sta P1VX
        jmp P1XClamped
P1XAbove:
        cmp #(PF_RIGHT+1)
        bcc P1XInRange
        lda #PF_RIGHT
        sta P1X
        lda #0
        sta P1VX
        jmp P1XClamped
P1XInRange:
        sta P1X
P1XClamped:

        ; P1 Y
        clc
        lda P1Y
        adc P1VY
        cmp #PF_TOP
        bcs P1YAbove
        lda #PF_TOP
        sta P1Y
        lda #0
        sta P1VY
        jmp P1YClamped
P1YAbove:
        cmp #(PF_BOTTOM+1)
        bcc P1YInRange
        lda #PF_BOTTOM
        sta P1Y
        lda #0
        sta P1VY
        jmp P1YClamped
P1YInRange:
        sta P1Y
P1YClamped:

        ;-------------------------------------------------------
        ; Missile update (both players via shared subroutine).
        ;-------------------------------------------------------
        ldx #0
        ldy #0
        jsr MissileUpdate
        ldx #MIS_OFFSET
        ldy #1
        jsr MissileUpdate

        ;-------------------------------------------------------
        ; Collision processing.
        ;
        ; Latches set during the previous visible kernel:
        ;   CXM0P bit 7 = M0 vs P1
        ;   CXM1P bit 7 = M1 vs P0
        ; On a hit, set the hit player's flash counter and despawn the
        ; offending missile. Latches are cleared via CXCLR for next frame.
        ;
        ; Flash counters are decremented BEFORE the hit check so that a hit
        ; this frame survives at the full FLASH_FRAMES value.
        ;-------------------------------------------------------
        lda P0FlashCount
        beq P0FlashSame
        dec P0FlashCount
P0FlashSame:
        lda P1FlashCount
        beq P1FlashSame
        dec P1FlashCount
P1FlashSame:

        ; M0 hit P1?
        bit CXM0P
        bpl NoM0Hit
        ldx #0              ; missile = M0
        ldy #0              ; scorer = P0
        jsr ProcessHit
NoM0Hit:
        ; M1 hit P0?
        bit CXM1P
        bpl NoM1Hit
        ldx #MIS_OFFSET     ; missile = M1
        ldy #1              ; scorer = P1
        jsr ProcessHit
NoM1Hit:

        ;-------------------------------------------------------
        ; Pickup collision (CXP0FB / CXP1FB bit 6 = P{0,1} vs ball).
        ; Wall hit uses bit 7 of the same register and is handled below;
        ; we test bit 6 here first.  Only one player consumes the pickup
        ; per frame; if both overlap simultaneously, P0 wins the toss.
        ;-------------------------------------------------------
        lda PickupActive
        bpl NoPickupColl
        bit CXP0FB
        bvs DoGrantPickup
        bit CXP1FB
        bvc NoPickupColl
DoGrantPickup:
        jsr GrantPickup
NoPickupColl:

        ;-------------------------------------------------------
        ; Wall collisions (CXxFB latches set during last visible kernel).
        ; Revert to Prev2 (two frames ago) because Prev is itself often
        ; inside the wall by the time we read the latch.  We also sync
        ; Prev := Prev2 so the next-frame shift sees a consistent history.
        ;-------------------------------------------------------
        bit CXP0FB
        bpl NoP0Wall
        lda P0XPrev2
        sta P0X
        sta P0XPrev
        lda P0YPrev2
        sta P0Y
        sta P0YPrev
        lda #0
        sta P0VX
        sta P0VY
        ; If P0 is the AI, kick off perpendicular creep so the AI can find
        ; a way around the wall it just hit.
        bit AIFlags
        bpl NoP0Wall
        jsr StartAIStuckP0
NoP0Wall:
        bit CXP1FB
        bpl NoP1Wall
        lda P1XPrev2
        sta P1X
        sta P1XPrev
        lda P1YPrev2
        sta P1Y
        sta P1YPrev
        lda #0
        sta P1VX
        sta P1VY
        lda AIFlags
        and #$40
        beq NoP1Wall
        jsr StartAIStuckP1
NoP1Wall:

        ; Missile-wall: revert to Prev2 then reflect at complementary angle.
        ; If the missile was moving purely horizontally (DY==0) we hit a
        ; vertical wall edge -> -DX (incidence == reflection).  If DX==0 we
        ; must have hit a horizontal edge -> -DY.  For diagonal motion we
        ; assume a vertical bar (the wall pattern is two centred vertical
        ; bars) and reflect -DX.
        bit CXM0FB
        bpl NoM0Wall
        lda M0XPrev2
        sta M0X
        sta M0XPrev
        lda M0YPrev2
        sta M0Y
        sta M0YPrev
        lda M0DX
        beq M0WallReflectY
        sec
        lda #0
        sbc M0DX
        sta M0DX
        jmp NoM0Wall
M0WallReflectY:
        sec
        lda #0
        sbc M0DY
        sta M0DY
NoM0Wall:
        bit CXM1FB
        bpl NoM1Wall
        lda M1XPrev2
        sta M1X
        sta M1XPrev
        lda M1YPrev2
        sta M1Y
        sta M1YPrev
        lda M1DX
        beq M1WallReflectY
        sec
        lda #0
        sbc M1DX
        sta M1DX
        jmp NoM1Wall
M1WallReflectY:
        sec
        lda #0
        sbc M1DY
        sta M1DY
NoM1Wall:

        ;-------------------------------------------------------
        ; Player-vs-player bounce.  CXPPMM bit 7 = P0-P1 collision.
        ; On overlap, negate both players' velocities so they bounce apart.
        ;-------------------------------------------------------
        bit CXPPMM
        bmi BounceMaybe
        jmp NoBounce            ; bit 7 clear -> no overlap
BounceMaybe:
        ; Skip bounce while a previous bounce's cooldown is still active.
        ; Otherwise CXPPMM keeps firing during the few overlap frames after
        ; the initial push and re-fires the bounce each frame, locking the
        ; sprites together.
        lda BounceCool
        beq BounceDoIt
        jmp NoBounce            ; cooldown active -> ignore
BounceDoIt:

        ; --- Position-based push ---
        ; Push direction = sign(P0_pos - P1_pos) for each axis, applied at
        ; BOUNCE_SPEED (which exceeds MAX_SPEED so the players actually
        ; separate before input clamping bleeds the speed back down).
        ; Horizontal
        lda P0X
        cmp P1X
        bcs P0RightOfP1
        ; P0X < P1X -> P0 to the left, push P0 left and P1 right
        lda #(256-BOUNCE_SPEED)
        sta P0VX
        lda #BOUNCE_SPEED
        sta P1VX
        jmp BounceVert
P0RightOfP1:
        lda #BOUNCE_SPEED
        sta P0VX
        lda #(256-BOUNCE_SPEED)
        sta P1VX
BounceVert:
        ; Vertical
        lda P0Y
        cmp P1Y
        bcs P0BelowP1
        lda #(256-BOUNCE_SPEED)
        sta P0VY
        lda #BOUNCE_SPEED
        sta P1VY
        jmp BounceVDone
P0BelowP1:
        lda #BOUNCE_SPEED
        sta P0VY
        lda #(256-BOUNCE_SPEED)
        sta P1VY
BounceVDone:

        ; --- Slowdown: halve the faster-moving player's velocity ---
        ; Compute |VX|+|VY| as a simple speed proxy for each player.
        lda P0VX
        bpl SlowAbsP0VX
        eor #$FF
        clc
        adc #1
SlowAbsP0VX:
        sta TempSpeed
        lda P0VY
        bpl SlowAbsP0VY
        eor #$FF
        clc
        adc #1
SlowAbsP0VY:
        clc
        adc TempSpeed
        sta TempSpeed           ; TempSpeed = |P0VX|+|P0VY|

        lda P1VX
        bpl SlowAbsP1VX
        eor #$FF
        clc
        adc #1
SlowAbsP1VX:
        sta TempScratch
        lda P1VY
        bpl SlowAbsP1VY
        eor #$FF
        clc
        adc #1
SlowAbsP1VY:
        clc
        adc TempScratch         ; A = |P1VX|+|P1VY|
        cmp TempSpeed
        bcc HalveP0Vel          ; P1 sum < P0 sum: P0 was faster
        beq SlowdownDone        ; tied: skip
        ; P1 was faster: halve P1's velocities (arithmetic shift right).
        lda P1VX
        cmp #$80
        ror
        sta P1VX
        lda P1VY
        cmp #$80
        ror
        sta P1VY
        jmp SlowdownDone
HalveP0Vel:
        lda P0VX
        cmp #$80
        ror
        sta P0VX
        lda P0VY
        cmp #$80
        ror
        sta P0VY
SlowdownDone:

        ; Boing!
        ldy #SND_BOUNCE
        jsr TriggerSnd1

        ; Lock out joystick input so the negated velocities can separate
        ; the sprites before the user can push them back together.
        lda #BOUNCE_FRAMES
        sta BounceCool
NoBounce:
        sta CXCLR                ; clear all collision latches

RunSoundDecay:
        ;-------------------------------------------------------
        ; Per-frame sound engine.  Each channel: if count > 0,
        ; write current freq/vol to TIA, then advance freq by
        ; FreqDt and decay vol by VolDt.  When count reaches 0,
        ; mute the channel.
        ;-------------------------------------------------------
        ; --- Channel 0 ---
        lda Snd0Count
        beq .ch0mute
        dec Snd0Count
        lda Snd0Freq
        sta AUDF0
        clc
        adc Snd0FreqDt
        sta Snd0Freq
        lda Snd0Vol
        sta AUDV0
        sec
        sbc Snd0VolDt
        bcs .ch0ok
        lda #0
.ch0ok:
        sta Snd0Vol
        jmp .ch1
.ch0mute:
        sta AUDV0
.ch1:
        ; --- Channel 1 ---
        lda Snd1Count
        beq .ch1mute
        dec Snd1Count
        lda Snd1Freq
        sta AUDF1
        clc
        adc Snd1FreqDt
        sta Snd1Freq
        lda Snd1Vol
        sta AUDV1
        sec
        sbc Snd1VolDt
        bcs .ch1ok
        lda #0
.ch1ok:
        sta Snd1Vol
        jmp HitSoundDone
.ch1mute:
        sta AUDV1
HitSoundDone:

SkipTitleStart:

        ; --- Setup kernel state for both modes ---
        ; 2-line kernel (96 iterations x 2 physical scanlines each). PxY is in
        ; physical scanlines but the kernel state advances once per iter, so
        ; init = 1 - (PxY/2). Each sprite row therefore spans 2 scanlines and
        ; the sprite is 16 physical scanlines tall.
        lda P0Y
        lsr                     ; A = P0Y / 2
        sta P0RowState
        lda #1
        sec
        sbc P0RowState
        sta P0RowState

        lda P1Y
        lsr
        sta P1RowState
        lda #1
        sec
        sbc P1RowState
        sta P1RowState

        ; Missile row counters: when active, init = 1 - (MxY/2) so post-inc 0
        ; lands on the missile's iter (= 2 physical scanlines). When inactive,
        ; init = 0 so the counter never returns to 0 within 96 iterations.
        lda M0Active
        bpl M0Inactive
        lda M0Y
        lsr
        sta M0RowState
        lda #1
        sec
        sbc M0RowState
        sta M0RowState
        jmp M0RowDone
M0Inactive:
        lda #0
        sta M0RowState
M0RowDone:

        lda M1Active
        bpl M1Inactive
        lda M1Y
        lsr
        sta M1RowState
        lda #1
        sec
        sbc M1RowState
        sta M1RowState
        jmp M1RowDone
M1Inactive:
        lda #0
        sta M1RowState
M1RowDone:

        ; --- Pickup ball shape (per-frame) ---
        ; Drive the ball to flicker between a horizontal stripe and a
        ; vertical column on alternating frames so the retina composites
        ; a '+' silhouette.  When inactive, PickupCtrlPF stays at $01
        ; (mirror only) and PickupStartIter / PickupEndIter remain 0 so
        ; the kernel's cpx checks never fire ENABL on.
        lda #$01                ; default: mirror only, no ball size
        sta PickupCtrlPF
        lda PickupActive
        bpl PickupShapeDone
        ; K = 88 - (PickupY / 2) is the iter where the full 5-iter band's
        ; ENABL ON write would land (matches SpawnPickup's StartIter).
        ; Stripe iter (centre, 1-iter window) sits at K-2 / K-3.
        lda PickupY
        lsr
        sta TempScratch
        lda #88
        sec
        sbc TempScratch         ; A = K
        sta TempScratch         ; cache K for both branches
        lda FrameCounter
        lsr                     ; carry = bit 0
        bcs PickupShapeColumn
        ; Frame A: 8px x 2-scanline horizontal stripe at vertical centre
        lda #$31
        sta PickupCtrlPF
        lda TempScratch
        sec
        sbc #2
        sta PickupStartIter     ; K-2 (ENABL on)
        sec
        sbc #1
        sta PickupEndIter       ; K-3 (ENABL off)
        jmp PickupShapeDone
PickupShapeColumn:
        ; Frame B: 2px x 10-scanline vertical column over full band
        lda #$11
        sta PickupCtrlPF
        lda TempScratch
        sta PickupStartIter     ; K
        sec
        sbc #5
        sta PickupEndIter       ; K-5
PickupShapeDone:

        ; --- Sprite source select for the play kernel ---
        ; While BounceCool > 0, both players show the hollow / outline
        ; sprite ("stunned" frame).  Otherwise show the normal diamond.
        ; The chosen 8-row pattern is copied into zero-page SpriteCache
        ; so the kernel can fetch it via 4-cycle zero-page indexing.
        ldx #7
        lda BounceCool
        beq SpriteCacheGfx
SpriteCacheHollow:
        lda SpriteHollow,X
        sta SpriteCache,X
        dex
        bpl SpriteCacheHollow
        jmp SpriteCacheDone
SpriteCacheGfx:
        lda SpriteGfx,X
        sta SpriteCache,X
        dex
        bpl SpriteCacheGfx
SpriteCacheDone:

        lda #0
        sta P0Curr
        sta P1Curr
        sta M0Curr
        sta M1Curr

        ; Clear PF for a clean kernel start.
        sta PF0
        sta PF1
        sta PF2
        sta ENAM0
        sta ENAM1

        ; Compute per-player colors and cache them in zero-page so the
        ; score-band kernel transition can re-load them with a fixed
        ; cycle cost (variable jsr timing here would otherwise shift
        ; the play-kernel start scanline by 1 line on some frames).
        jsr ApplyP0Color
        sta COLUP0
        sta P0CurrentColor
        jsr ApplyP1Color
        sta COLUP1
        sta P1CurrentColor

        ; Pre-compute digit-base offsets (Score * 8) for the score band.
        lda P0Score
        asl
        asl
        asl
        sta P0DigitBase
        lda P1Score
        asl
        asl
        asl
        sta P1DigitBase

        sta WSYNC               ; end of VBLANK line 1

        ;-------------------------------------------------------
        ; Position objects horizontally (one scanline per object).
        ; In non-TITLE states, P0 and P1 are positioned for the SCORE BAND
        ; first; they are repositioned for the play kernel during the
        ; score-to-play transition. M0/M1 use their actual game X.
        ; In TITLE state, P0 is centered (X=76) so the variant digit drawn
        ; in the bottom of the title kernel sits in the middle of the screen.
        ;-------------------------------------------------------
        ldx #0
        lda GameState
        bne UseScoreP0X
        lda #76                  ; TITLE: center variant digit
        jmp DoP0Pos
UseScoreP0X:
        lda #SCORE_P0_X
DoP0Pos:
        jsr PositionX

        ldx #1
        lda #SCORE_P1_X
        jsr PositionX

        ldx #2
        lda M0X
        jsr PositionX

        ldx #3
        lda M1X
        jsr PositionX

        lda PickupX
        jsr PositionBL

        sta WSYNC               ; close out positioning lines

        ;-------------------------------------------------------
        ; HMOVE applies fine motion to all five objects.
        ;-------------------------------------------------------
        sta HMOVE
        sta WSYNC

        ;-------------------------------------------------------
        ; Wait for the TIM64T-set VBLANK timer to expire, then sta WSYNC
        ; to align to the start of the visible region.  This keeps the
        ; total VBLANK length constant regardless of how many cycles the
        ; logic block above consumed (e.g. when a missile spawn fires).
        ;-------------------------------------------------------
VBlankWait:
        lda INTIM
        bne VBlankWait
        sta WSYNC

        ;-------------------------------------------------------
        ; Visible region (192 scanlines)
        ;-------------------------------------------------------
        lda #0
        sta VBLANK
        sta COLUBK              ; black background

        lda GameState
        bne EnterPlayVisible    ; PLAY / ROUND_OVER / GAME_OVER
        jmp TitleKernel

EnterPlayVisible:
        jmp ScoreBandKernel

;---------------------------------------------------------------
; SCORE BAND KERNEL
;
; 16 visible scanlines at the very top of the frame:
;   4 lines blank top padding
;   8 lines digit graphics (P0 score on left, P1 score on right)
;   4 lines blank bottom padding
;
; P0/P1 sprites are positioned at SCORE_P0_X/SCORE_P1_X by VBLANK + HMOVE.
; PxDigitBase is the offset into DigitGfx for that player's current digit.
;
; After this kernel, control falls through to the score->play transition.
;---------------------------------------------------------------
ScoreBandKernel:
        lda #FLASH_COLOR        ; bright white digits
        sta COLUP0
        sta COLUP1
        lda #0
        sta GRP0
        sta GRP1
        sta ENAM0               ; ensure missiles are not visible in score band
        sta ENAM1

        ; Top padding: 4 lines
        ldx #4
ScoreTopPad:
        sta WSYNC
        dex
        bne ScoreTopPad

        ; Digit rows: 8 lines
        ldy #0
ScoreDigitLoop:
        sta WSYNC
        tya
        clc
        adc P0DigitBase
        tax
        lda DigitGfx,X
        sta GRP0
        tya
        clc
        adc P1DigitBase
        tax
        lda DigitGfx,X
        sta GRP1
        iny
        cpy #8
        bne ScoreDigitLoop

        ; Sync to end of the last digit scanline before clearing GRPs.
        ; Otherwise the clear lands in P1's visible window (P1 trigger at
        ; color clock 176, sta GRP1 clear at ~clock 138) and row 7 of P1's
        ; digit never renders.
        sta WSYNC
        lda #0
        sta GRP0
        sta GRP1

        ; Bottom padding: 3 lines (the sta WSYNC above already consumed
        ; one line so the score band still totals 16 scanlines).
        ldx #3
ScoreBotPad:
        sta WSYNC
        dex
        bne ScoreBotPad

        ; --- Score-to-Play transition (4 scanlines) ---
        ; Reposition P0 and P1 at the game-state X coordinates.
        ; HMCLR first so the second HMOVE only shifts what we just wrote.
        sta HMCLR

        ldx #0
        lda P0X
        jsr PositionX

        ldx #1
        lda P1X
        jsr PositionX

        sta WSYNC               ; close last positioning line
        sta HMOVE               ; apply fine motion (P0/P1 only; M0/M1/BL=0)
        sta WSYNC               ; HMOVE-extended HBLANK; resume new line

        ; Restore the player colors for the play kernel.  Use the cached
        ; values written in VBLANK so this path has a deterministic cycle
        ; cost — otherwise the play-kernel start scanline can vary and
        ; the walls appear to shift up/down by 1 line on hit-flash frames.
        lda P0CurrentColor
        sta COLUP0
        lda P1CurrentColor
        sta COLUP1

        jmp PlayKernel

;---------------------------------------------------------------
; PositionX subroutine.
;
; Inputs:  A = pixel X position (0..159)
;          X = object index (0=P0, 1=P1)
; Effect:  sets HMP0+X and writes RESP0+X at the correct CPU cycle so that
;          a subsequent sta HMOVE positions the object at A pixels from the
;          left edge of the visible region. Uses one scanline.
;---------------------------------------------------------------
PositionX:
        sta WSYNC               ; resume at start of next scanline
        sec
PositionXLoop:
        sbc #15
        bcs PositionXLoop       ; A is now -1..-15 after divisions
        eor #7                  ; reflect for HMOVE encoding
        asl
        asl
        asl
        asl
        sta HMP0,X              ; HMP0 ($20) or HMP1 ($21)
        sta RESP0,X             ; RESP0 ($10) or RESP1 ($11)
        rts

;---------------------------------------------------------------
; PositionBL — same canonical sta WSYNC + sbc-loop positioning as
; PositionX, but writes HMBL ($24) and RESBL ($14) instead.  Used
; once per VBLANK after the four PositionX calls so the ball ends
; up at PickupX when the subsequent sta HMOVE applies.
;---------------------------------------------------------------
PositionBL:
        sta WSYNC
        sec
PositionBLLoop:
        sbc #15
        bcs PositionBLLoop
        eor #7
        asl
        asl
        asl
        asl
        sta HMBL
        sta RESBL
        rts

;---------------------------------------------------------------
; ResetPickupTimer — seed PickupTimer/PickupTimerHi with a random
; 5..9.25-second delay (300..555 frames at 60Hz).  Uses AIRand so
; each call yields a different countdown.
;---------------------------------------------------------------
ResetPickupTimer:
        lda AIRand
        clc
        adc #44                  ; 256 + 44 = 300 base
        sta PickupTimer
        lda #1
        adc #0                   ; capture carry from the lo-byte add
        sta PickupTimerHi
        rts

;---------------------------------------------------------------
; SpawnPickup — place the ball pickup at a random position somewhere
; on the play area.  X is restricted to the LEFT (X in [4..19]) or
; RIGHT (X in [128..143]) strips, which fall entirely inside the PF0
; cells (always $00 across every stored layout) so the pickup can
; NEVER spawn on top of a wall block regardless of which layout is
; active or where on the screen the pickup lands vertically.
;
; A previous middle-strip zone could overlap PF1/PF2 wall pixels and
; was removed; restricting to the safe PF0 columns is the simplest
; layout-independent guarantee.
;
; Zone selection uses AIRand bit 7 (high bit, sampled via BMI):
;   bit 7 = 0 -> left   X in [ 4.. 19]
;   bit 7 = 1 -> right  X in [128..143]
;
; (AIRand bit 0 was previously used, but the LCG (5x+1 mod 256) flips
; bit 0 every frame and the respawn timer's parity (300 + AIRand) is
; locked to that same parity, so bit 0 evaluated to 0 every single time
; SpawnPickup fired — the pickup always landed on the left.  Bit 7 has
; no such parity relationship with the timer countdown.)
;
; Y = 8 + (AIRand & $7F)  -> [8..135]; sprite is 10 lines tall so the
; bottom edge stays inside the play-area bounds (PF_BOTTOM=156).
;---------------------------------------------------------------
SpawnPickup:
        lda AIRand
        bmi SpawnXRight
        ; left zone
        lda AIRand
        and #$0F
        clc
        adc #4
        jmp SpawnXSet
SpawnXRight:
        lda AIRand
        and #$0F
        clc
        adc #128
SpawnXSet:
        sta PickupX

        lda AIRand
        eor FrameCounter         ; mix sources so Y isn't correlated with X
        and #$7F
        clc
        adc #8                   ; Y in [8..135]
        sta PickupY

        ; Pre-compute the iter values where ENABL toggles.  The ball
        ; renders during iters X in [PickupEndIter+1 .. PickupStartIter];
        ; setting StartIter = 88 - Y/2 and EndIter = 83 - Y/2 produces
        ; PICKUP_HEIGHT (=5) consecutive lit iters whose first scanline
        ; lines up with PickupY.
        lda PickupY
        lsr                      ; A = Y / 2
        sta TempScratch
        lda #88
        sec
        sbc TempScratch
        sta PickupStartIter
        sec
        sbc #5                   ; height
        sta PickupEndIter

        lda #$80
        sta PickupActive
        rts

;---------------------------------------------------------------
; GrantPickup — consume the pickup regardless of which player touched
; it.  The effect is fully randomized so neither player knows ahead of
; time who benefits:
;   AIRand bit 0 -> sign  (0 = -1, 1 = +1)
;   AIRand bit 1 -> target (0 = P0,  1 = P1)
; This means grabbing the ball is a gamble: it might add to you, add
; to your opponent, subtract from you, or subtract from your opponent.
;
; -1 is clamped at 0 (scores can't go negative).  +1 that reaches
; WIN_SCORE transitions to GAME_OVER with the appropriate winner.
; Plays a short pickup chime on the hit-sound channel (high pitch for
; +1, low pitch for -1) and seeds a fresh respawn timer.
;---------------------------------------------------------------
GrantPickup:
        lda #0
        sta PickupActive
        sta PickupStartIter      ; clear iter values so cpx never matches while waiting for next spawn
        sta PickupEndIter
        jsr ResetPickupTimer
        ; Dispatch on AIRand bit 1 (target player) then bit 0 (sign).
        lda AIRand
        and #$02
        bne GrantTargetP1
        ;----- Target P0 -----
        lda AIRand
        and #$01
        beq GrantP0Minus
        ; +1: gain chime
        ldy #SND_PICKUP_HI
        jsr TriggerSnd1
        inc P0Score
        lda P0Score
        cmp #WIN_SCORE
        bcc GrantDone
        lda #0
        sta GameOverWin
        lda #ST_GAME_OVER
        sta GameState
        lda #GAME_OVER_DURATION
        sta RoundTimer
        rts
GrantP0Minus:
        ; -1: loss bonk (still plays even if the score is already 0)
        ldy #SND_PICKUP_LO
        jsr TriggerSnd1
        lda P0Score
        beq GrantDone            ; clamp at 0; can't go negative
        dec P0Score
        rts
GrantTargetP1:
        ;----- Target P1 -----
        lda AIRand
        and #$01
        beq GrantP1Minus
        ; +1: gain chime
        ldy #SND_PICKUP_HI
        jsr TriggerSnd1
        inc P1Score
        lda P1Score
        cmp #WIN_SCORE
        bcc GrantDone
        lda #1
        sta GameOverWin
        lda #ST_GAME_OVER
        sta GameState
        lda #GAME_OVER_DURATION
        sta RoundTimer
        rts
GrantP1Minus:
        ; -1: loss bonk
        ldy #SND_PICKUP_LO
        jsr TriggerSnd1
        lda P1Score
        beq GrantDone
        dec P1Score
GrantDone:
        rts

;---------------------------------------------------------------
; LockP0AimAndFire / LockP1AimAndFire — called at the end of the AI
; fire telegraph window.  Forcibly overwrite the AI player's bits in
; SynthSWCHA with a strict toward-opponent direction (ignoring the
; random-skip and deadzone gates applied earlier in the frame), then
; raise the corresponding FireEdge.  The downstream missile-spawn code
; later in the frame reads SynthSWCHA, so this guarantees the missile
; spawns with a non-neutral joystick and shoots straight at the
; opponent's current position.
;
; SWCHA bit layout (active-low, 0 = pressed):
;   bit 7 P0 right   bit 6 P0 left   bit 5 P0 down   bit 4 P0 up
;   bit 3 P1 right   bit 2 P1 left   bit 1 P1 down   bit 0 P1 up
;---------------------------------------------------------------
LockP0AimAndFire:
        ; Release all four P0 direction bits, then press one or two below
        lda SynthSWCHA
        ora #$F0
        sta SynthSWCHA
        ; Horizontal: P0 vs P1
        lda P0X
        cmp P1X
        beq LP0V                 ; same column: no horizontal press
        bcs LP0Left              ; P0X > P1X -> opponent left
        lda SynthSWCHA           ; P0X < P1X -> opponent right (press bit 7)
        and #$7F
        sta SynthSWCHA
        jmp LP0V
LP0Left:
        lda SynthSWCHA
        and #$BF                 ; press bit 6 (P0 left)
        sta SynthSWCHA
LP0V:
        ; Vertical: P0 vs P1
        lda P0Y
        cmp P1Y
        beq LP0Fire              ; same row: no vertical press
        bcs LP0Up                ; P0Y > P1Y -> opponent above
        lda SynthSWCHA           ; P0Y < P1Y -> opponent below (press bit 5)
        and #$DF
        sta SynthSWCHA
        jmp LP0Fire
LP0Up:
        lda SynthSWCHA
        and #$EF                 ; press bit 4 (P0 up)
        sta SynthSWCHA
LP0Fire:
        lda #$80
        sta P0FireEdge
        rts

LockP1AimAndFire:
        ; Release all four P1 direction bits, then press one or two below
        lda SynthSWCHA
        ora #$0F
        sta SynthSWCHA
        ; Horizontal: P1 vs P0
        lda P1X
        cmp P0X
        beq LP1V
        bcs LP1Left              ; P1X > P0X -> opponent left
        lda SynthSWCHA           ; P1X < P0X -> opponent right (press bit 3)
        and #$F7
        sta SynthSWCHA
        jmp LP1V
LP1Left:
        lda SynthSWCHA
        and #$FB                 ; press bit 2 (P1 left)
        sta SynthSWCHA
LP1V:
        lda P1Y
        cmp P0Y
        beq LP1Fire
        bcs LP1Up
        lda SynthSWCHA           ; P1Y < P0Y -> opponent below (press bit 1)
        and #$FD
        sta SynthSWCHA
        jmp LP1Fire
LP1Up:
        lda SynthSWCHA
        and #$FE                 ; press bit 0 (P1 up)
        sta SynthSWCHA
LP1Fire:
        lda #$80
        sta P1FireEdge
        rts

;---------------------------------------------------------------
; StartAIStuckP0 / StartAIStuckP1 — invoked from the wall-revert code
; when an AI player runs into a playfield block.  Each call:
;   1. Loads AIStuckTimer with AI_STUCK_FRAMES (~0.6s of creep).
;   2. Reads AIStuckDirIdx and writes the matching single-direction
;      press into AIStuckOR (via the lookup tables below).
;   3. Advances AIStuckDirIdx (mod 4) so the NEXT wall-hit tries a
;      different direction; in at most four bumps the AI has tried
;      up, right, down and left and at least one will be unblocked.
; Random heuristics were attempted earlier (creep perpendicular to the
; dominant approach axis with AIRand bit 5 for sub-direction); they
; misfired when the AI hit a wall CORNER and the heuristic guessed the
; wrong axis, plus the 50/50 random could keep picking the same blocked
; sub-direction.  The deterministic cycle below sidesteps both failure
; modes while staying tiny.
;---------------------------------------------------------------
StartAIStuckP0:
        lda #AI_STUCK_FRAMES
        sta AIStuckTimer
        lda #$0F                 ; preserve P1 bits, clear P0 bits before OR
        sta AIStuckMask
        ldx AIStuckDirIdx
        lda P0StuckDirTbl,X
        sta AIStuckOR
        inx
        cpx #4
        bcc SP0StoreIdx
        ldx #0
SP0StoreIdx:
        stx AIStuckDirIdx
        rts

StartAIStuckP1:
        lda #AI_STUCK_FRAMES
        sta AIStuckTimer
        lda #$F0                 ; preserve P0 bits, clear P1 bits before OR
        sta AIStuckMask
        ldx AIStuckDirIdx
        lda P1StuckDirTbl,X
        sta AIStuckOR
        inx
        cpx #4
        bcc SP1StoreIdx
        ldx #0
SP1StoreIdx:
        stx AIStuckDirIdx
        rts

; --- Stuck-recovery direction tables (mirror bit pattern semantics in
; --- the LockPxAimAndFire helpers): one press, three releases per nibble.
;   index 0 = up    1 = right    2 = down    3 = left
P0StuckDirTbl:
        .byte $E0   ; press P0 up    (bit 4=0)
        .byte $70   ; press P0 right (bit 7=0)
        .byte $D0   ; press P0 down  (bit 5=0)
        .byte $B0   ; press P0 left  (bit 6=0)
P1StuckDirTbl:
        .byte $0E   ; press P1 up    (bit 0=0)
        .byte $07   ; press P1 right (bit 3=0)
        .byte $0D   ; press P1 down  (bit 1=0)
        .byte $0B   ; press P1 left  (bit 2=0)

;---------------------------------------------------------------
; DiffGateP0 / DiffGateP1
;
; Difficulty gate.  SWCHB bit 6 = P0 difficulty, bit 7 = P1 difficulty.
; When the bit is SET (Pro/A), acceleration is allowed every frame.
; When clear (Novice/B), acceleration is allowed only on even frames
; (FrameCounter LSB == 0).  Returns C=1 if accel allowed, else C=0.
;---------------------------------------------------------------
DiffGateP0:
        lda SWCHB
        and #$40
        bne DGP0Allow
        lda FrameCounter
        and #1
        beq DGP0Allow           ; even frame: allow even for novice
        clc
        rts
DGP0Allow:
        sec
        rts

DiffGateP1:
        lda SWCHB
        and #$80
        bne DGP1Allow
        lda FrameCounter
        and #1
        beq DGP1Allow
        clc
        rts
DGP1Allow:
        sec
        rts

;---------------------------------------------------------------
; ApplyP0Color / ApplyP1Color — returns A loaded with the correct
; per-player color for the current frame.  Layered behaviours:
;   1. Hit-flash counter > 0   -> FLASH_COLOR
;   2. ST_GAME_OVER + winner  -> rainbow ((FrameCounter/4)&$0F << 4 | $0E)
;   3. ST_GAME_OVER + loser   -> P{0,1}_COLOR or black (gated by AIRand bit 7)
;   4. Otherwise              -> P{0,1}_COLOR
; Called from both the VBLANK COLUP setup AND the score-band kernel
; restore, so the rainbow / loser flicker survive into the play kernel.
;---------------------------------------------------------------
ApplyP0Color:
        lda P0FlashCount
        beq AP0NoFlash
        lda #FLASH_COLOR
        rts
AP0NoFlash:
        ; Telegraph flash: if P0 is the AI and AIFireTelegraph is counting,
        ; alternate sprite color via FrameCounter bit 2 (~7Hz blink) so the
        ; human opponent can see the AI is about to shoot.
        bit AIFlags
        bpl AP0NoTele            ; bit 7 clear: P0 not AI
        lda AIFireTelegraph
        beq AP0NoTele            ; not telegraphing
        lda FrameCounter
        and #$04
        beq AP0NoTele            ; off-frame: fall through to normal color
        lda #FLASH_COLOR
        rts
AP0NoTele:
        ldx GameState
        cpx #ST_GAME_OVER
        beq AP0InGO
        lda #P0_COLOR
        rts
AP0InGO:
        ldx GameOverWin
        bne AP0Loser            ; GameOverWin=1 => P1 won, P0 is loser
        ; P0 is winner: rainbow color
        lda FrameCounter
        and #$3C
        asl
        asl
        ora #$0E
        rts
AP0Loser:
        ldx AIRand
        bmi AP0Vanish           ; AIRand bit 7 set => black (vanish frame)
        lda #P0_COLOR
        rts
AP0Vanish:
        lda #0
        rts

ApplyP1Color:
        lda P1FlashCount
        beq AP1NoFlash
        lda #FLASH_COLOR
        rts
AP1NoFlash:
        ; Telegraph flash: P1 AI version.
        lda AIFlags
        and #$40
        beq AP1NoTele            ; P1 not AI
        lda AIFireTelegraph
        beq AP1NoTele
        lda FrameCounter
        and #$04
        beq AP1NoTele
        lda #FLASH_COLOR
        rts
AP1NoTele:
        ldx GameState
        cpx #ST_GAME_OVER
        beq AP1InGO
        lda #P1_COLOR
        rts
AP1InGO:
        ldx GameOverWin
        beq AP1Loser            ; GameOverWin=0 => P0 won, P1 is loser
        ; P1 is winner: rainbow color
        lda FrameCounter
        and #$3C
        asl
        asl
        ora #$0E
        rts
AP1Loser:
        ldx AIRand
        bmi AP1Vanish
        lda #P1_COLOR
        rts
AP1Vanish:
        lda #0
        rts

;---------------------------------------------------------------
; LoadLayout — point BandPtrL/H at the active stored layout's first
; band, preload NextBandIter from that band's start_iter, and pick a
; random WallColor for COLUPF.  Called in VBLANK during TITLE and
; ROUND_OVER -> PLAY transitions.
;
; LayoutIndex selects which layout (in [0..NUM_LAYOUTS-1]) is active.
; The kernel walks the band list during render; PF state writes
; happen entirely from this pointer, no further setup is needed.
;---------------------------------------------------------------
LoadLayout:
        ldx LayoutIndex
        lda LayoutBaseLoTbl,X
        sta BandPtrL
        lda LayoutBaseHiTbl,X
        sta BandPtrH

        ; First band's start_iter -> NextBandIter so the kernel's cpx
        ; fires on the correct row boundary.
        ldy #0
        lda (BandPtrL),Y
        sta NextBandIter

        ; Random WallColor (kept from prior random-wall design).  Mix
        ; AIRand with a chained LCG byte so consecutive rounds land on
        ; visibly different colors even when the layout repeats.
        lda AIRand
        asl
        asl
        clc
        adc AIRand
        clc
        adc #1
        sta TempScratch
        lda AIRand
        eor TempScratch
        and #$07
        tay
        lda WallColorTbl,Y
        sta WallColor
        rts

;---------------------------------------------------------------
; MissileUpdate — parameterized missile spawn / update / despawn.
;
; Entry:  X = 0 (M0) or MIS_OFFSET (M1)
;         Y = 0 (P0) or 1 (P1)
; All missile variables are accessed via lda M0xxx,X so both
; players share a single code path.
;
; Joystick bits: P0 uses high nibble (bits 4–7), P1 uses low nibble
; (bits 0–3).  For P1, SynthSWCHA is shifted left 4 so the same
; mask constants ($80/$40/$20/$10) work for both.
;---------------------------------------------------------------
MissileUpdate:
        sty TempScratch          ; save player index (0 or 1)
        ; --- Active check ---
        lda M0Active,X
        bpl MxNotActive
        jmp MxDoUpdate           ; active => update path (long distance)
MxNotActive:

        ; --- Not active: try to spawn ---
        ldy TempScratch
        lda P0FireEdge,Y         ; P0FireEdge or P1FireEdge
        bmi MxCheckJoy
        rts                      ; no fire edge => done
MxCheckJoy:
        ; Joystick neutral check: shift P1 low nibble to high nibble
        lda SynthSWCHA
        ldy TempScratch
        beq MxNoShift
        asl
        asl
        asl
        asl
MxNoShift:
        and #$F0
        cmp #$F0
        bne MxDoSpawn
        rts                      ; neutral joystick => done
MxDoSpawn:
        sta MxJoyVal

        ; --- Spawn at player center ---
        ldy TempScratch
        lda MxPlayerOff,Y        ; 0 (P0) or 4 (P1)
        tay
        clc
        lda P0X,Y
        adc #4
        sta M0X,X
        clc
        lda P0Y,Y
        adc #4
        sta M0Y,X

        ; --- DX from right / left ---
        lda MxJoyVal
        and #$80
        bne MxChkLeft
        lda #MISSILE_SPEED
        sta M0DX,X
        bne MxSetDY              ; always taken
MxChkLeft:
        lda MxJoyVal
        and #$40
        bne MxDXZero
        lda #(256-MISSILE_SPEED)
        sta M0DX,X
        bne MxSetDY              ; always taken
MxDXZero:
        lda #0
        sta M0DX,X
MxSetDY:
        ; --- DY from up / down ---
        lda MxJoyVal
        and #$10
        bne MxChkDown
        lda #(256-MISSILE_SPEED)
        sta M0DY,X
        bne MxActivate           ; always taken (neg value)
MxChkDown:
        lda MxJoyVal
        and #$20
        bne MxDYZero
        lda #MISSILE_SPEED
        sta M0DY,X
        bne MxActivate           ; always taken
MxDYZero:
        lda #0
        sta M0DY,X
MxActivate:
        lda #$80
        sta M0Active,X
        lda #MISSILE_LIFE
        sta M0Life,X
        ; Seed Prev/Prev2 along trajectory
        lda M0X,X
        sta M0XPrev,X
        sec
        sbc M0DX,X
        sec
        sbc M0DX,X
        sta M0XPrev2,X
        lda M0Y,X
        sta M0YPrev,X
        sec
        sbc M0DY,X
        sec
        sbc M0DY,X
        sta M0YPrev2,X
        ; Fire sound
        ldy #SND_FIRE
        jsr TriggerSnd0
        rts

MxDoUpdate:
        ; Lifespan tick
        dec M0Life,X
        beq MxDespawn
        ; Shift Prev2 := Prev, Prev := current
        lda M0XPrev,X
        sta M0XPrev2,X
        lda M0YPrev,X
        sta M0YPrev2,X
        lda M0X,X
        sta M0XPrev,X
        lda M0Y,X
        sta M0YPrev,X
        ; Advance position
        clc
        lda M0X,X
        adc M0DX,X
        sta M0X,X
        clc
        lda M0Y,X
        adc M0DY,X
        sta M0Y,X
        ; Edge despawn check
        lda M0X,X
        cmp #MPF_LEFT
        bcc MxDespawn
        cmp #(MPF_RIGHT+1)
        bcs MxDespawn
        lda M0Y,X
        cmp #MPF_TOP
        bcc MxDespawn
        cmp #(MPF_BOTTOM+1)
        bcs MxDespawn
        rts
MxDespawn:
        lda #0
        sta M0Active,X
        rts

; Player position offset table: P0X is at $85, P1X is at $89 (offset 4).
MxPlayerOff:
        .byte 0, 4

;---------------------------------------------------------------
; TitleMelodyTick — per-frame title-screen melody sequencer.
; Plays a short looping motif on channel 0 via direct TIA writes
; (no SFX conflict since fire can't happen during TITLE state).
; Called from the TITLE idle path; falls through to RunSoundDecay.
;---------------------------------------------------------------
TitleMelodyTick:
        lda MelodyTimer
        beq .advance
        dec MelodyTimer
        jmp RunSoundDecay
.advance:
        ldx MelodyIdx
        lda TitleMelody+1,X      ; duration (0 = loop sentinel)
        beq .loop
        sta MelodyTimer
        sta Snd0Count
        lda TitleMelody,X        ; AUDF
        sta Snd0Freq
        beq .rest
        lda #4                   ; AUDC = pure square (clean electronic)
        sta AUDC0
        lda #4                   ; soft volume
        sta Snd0Vol
        lda #0
        sta Snd0FreqDt
        sta Snd0VolDt
        jmp .next
.rest:
        lda #0
        sta Snd0Count
        sta Snd0Vol
.next:
        inx
        inx
        stx MelodyIdx
        jmp RunSoundDecay
.loop:
        lda #0
        sta MelodyIdx
        lda #1
        sta MelodyTimer
        jmp RunSoundDecay

; TRON-style title melody: driving E-minor arpeggio (AABA form).
; (AUDF, duration) pairs.  AUDF 0 = rest.  Duration 0 = loop.
; The 1-frame engine-mute gap between notes gives natural staccato.
TitleMelody:
        ; === A: "The Grid" — driving octave-pulse (lower register) ===
        .byte 31, 4     ; E lo
        .byte 15, 4     ; E hi
        .byte 26, 4     ; G
        .byte 15, 4     ; E hi
        .byte 23, 4     ; A
        .byte 15, 4     ; E hi
        .byte 26, 4     ; G
        .byte 20, 4     ; B
        ; === A (repeat — locks in the beat) ===
        .byte 31, 4     ; E lo
        .byte 15, 4     ; E hi
        .byte 26, 4     ; G
        .byte 15, 4     ; E hi
        .byte 23, 4     ; A
        .byte 15, 4     ; E hi
        .byte 26, 4     ; G
        .byte 20, 4     ; B
        ; === B: "Light Cycles" — faster ascending run + peak ===
        .byte 31, 3     ; E lo  (16th notes)
        .byte 26, 3     ; G
        .byte 23, 3     ; A
        .byte 20, 3     ; B
        .byte 15, 3     ; E hi
        .byte 12, 6     ; G hi  (peak — held)
        .byte 15, 3     ; E hi  (falling)
        .byte 23, 3     ; A
        .byte 31, 6     ; E lo  (resolve — held)
        .byte 0, 3      ; breath
        ; === A': return + ring-out ending ===
        .byte 31, 4     ; E lo
        .byte 15, 4     ; E hi
        .byte 26, 4     ; G
        .byte 15, 4     ; E hi
        .byte 23, 4     ; A
        .byte 20, 4     ; B
        .byte 15, 8     ; E hi  (ring out)
        .byte 0, 240    ; ~4 second rest before loop
        .byte 0, 0      ; loop sentinel

; Title screen color cycle: blue shades rising into yellow shades.
TitleColorTbl:
        .byte $86   ; dark blue
        .byte $8A   ; medium blue
        .byte $8E   ; bright blue
        .byte $8A   ; medium blue
        .byte $1A   ; dark yellow
        .byte $1C   ; medium yellow
        .byte $1E   ; bright yellow
        .byte $1C   ; medium yellow

;---------------------------------------------------------------
; TriggerSnd0 / TriggerSnd1 — load a 6-byte sound definition into
; the per-channel engine state.  Y = offset into SndDefs.
;---------------------------------------------------------------
TriggerSnd0:
        lda SndDefs+0,Y
        sta Snd0Count
        lda SndDefs+1,Y
        sta AUDC0
        lda SndDefs+2,Y
        sta Snd0Freq
        lda SndDefs+3,Y
        sta Snd0FreqDt
        lda SndDefs+4,Y
        sta Snd0Vol
        lda SndDefs+5,Y
        sta Snd0VolDt
        rts

TriggerSnd1:
        lda SndDefs+0,Y
        sta Snd1Count
        lda SndDefs+1,Y
        sta AUDC1
        lda SndDefs+2,Y
        sta Snd1Freq
        lda SndDefs+3,Y
        sta Snd1FreqDt
        lda SndDefs+4,Y
        sta Snd1Vol
        lda SndDefs+5,Y
        sta Snd1VolDt
        rts

;---------------------------------------------------------------
; Sound definition table: 6 bytes per entry.
;   [duration, AUDC, startFreq, freqDelta, startVol, volDecay]
; freqDelta is signed (+N = pitch falls, -N = pitch rises).
; volDecay is unsigned (subtracted each frame, clamped at 0).
;---------------------------------------------------------------
SndDefs:
        ; SND_FIRE (0): descending laser sweep — ch0
        .byte 6, 4, 4, 3, 12, 2
        ; SND_HIT (6): white-noise explosion decay — ch1
        .byte 10, 8, 2, 1, 15, 1
        ; SND_BOUNCE (12): ascending poly4 boing — ch1
        .byte 8, 1, 16, (256-2), 12, 1
        ; SND_PICKUP_HI (18): gain chime (ascending sweep) — ch1
        .byte 8, 4, 8, (256-1), 14, 1
        ; SND_PICKUP_LO (24): loss bonk (descending sweep) — ch1
        .byte 8, 6, 16, 2, 14, 2
        ; SND_TELEPORT (30): rapid descending poly4 sweep — ch0
        .byte 15, 1, 1, 2, 12, 0

;---------------------------------------------------------------
; ProcessHit
; Entry: X = missile offset (0 or MIS_OFFSET)
;        Y = scorer index  (0 = P0 scored, 1 = P1 scored)
; Despawns missile, flashes victim, plays hit sound, increments
; scorer, and transitions to ROUND_OVER or GAME_OVER.
;---------------------------------------------------------------
ProcessHit:
        lda #0
        sta M0Active,X          ; despawn missile
        ; Flash the victim (1-Y): P0FlashCount=$A9, P1FlashCount=$AA
        tya
        eor #1
        tax                      ; X = victim index (1-Y)
        lda #FLASH_FRAMES
        sta P0FlashCount,X
        ; Score: P0Score=$AE, P1Score=$AF; INC ZP,X needs X=scorer
        ; (must happen BEFORE TriggerSnd1 which clobbers Y)
        tya
        tax
        inc P0Score,X
        lda P0Score,X
        cmp #WIN_SCORE
        bcc .hitRound
        sty GameOverWin          ; Y = 0 (P0 wins) or 1 (P1 wins)
        lda #ST_GAME_OVER
        sta GameState
        lda #GAME_OVER_DURATION
        sta RoundTimer
        ldy #SND_HIT
        jmp TriggerSnd1          ; tail-call
.hitRound:
        lda #ROUND_PAUSE
        sta RoundTimer
        lda #ST_ROUND_OVER
        sta GameState
        ldy #SND_HIT
        jmp TriggerSnd1          ; tail-call

;---------------------------------------------------------------
; PlayfieldLayouts — table of stored playfield layouts, each a list
; of bands (3 bytes each: start_iter, PF1, PF2) terminated by a
; sentinel band with start_iter=0 (X downcounts 86..1 so it never
; matches).  PF0 stays $00 every band so it doesn't appear in the
; format — the kernel preamble clears it once for the whole frame.
;
; Iters are mapped to scanlines as: scanline = 2 * (86 - iter), so
; iter 86 = top of play area, iter 1 = bottom.  Each user-supplied
; "row" of line-height-14 layouts occupies 6 iters (12 scanlines);
; 14 rows + 2 iters of top padding = 86 iters total.
;
; Layouts are referenced via LayoutBaseLoTbl/HiTbl indexed by
; LayoutIndex.  The band walker handles BandPtrL carry so page
; alignment is not required.
;---------------------------------------------------------------
LayoutBaseLoTbl:
        .byte <Layout0Bands
        .byte <Layout1Bands
        .byte <Layout2Bands
        .byte <Layout3Bands
        .byte <Layout4Bands
LayoutBaseHiTbl:
        .byte >Layout0Bands
        .byte >Layout1Bands
        .byte >Layout2Bands
        .byte >Layout3Bands
        .byte >Layout4Bands

; Design rules used for all layouts below (after the gameplay pass):
;   - Rows 0..2 and rows 10..13 are PF-clear (PF1=PF2=$00) so the
;     16-line player sprites at the top (Y 8..15) and bottom (Y 148..
;     155) spawn bands never overlap a wall block in any layout.  This
;     also lets SpawnPlayers use the full [4..19] / [128..143] X jitter
;     across every layout (no per-layout narrow mask needed).
;   - Walls always leave at least one >=12px (>= 3 PF cells) clear gap
;     somewhere along each scanline so the 8px-wide player can navigate
;     vertically through every layout.
;   - Each layout uses 3..5 bands, minimising band-transition lines
;     (each band write lands late in the iter, producing a 1-line
;     mirror-mismatch artifact at every row boundary).

; --- Layout 0: "Center Column" ---
; A single 8px-wide center column on rows 3..9.  Cleanest, most open
; layout; ample 76px gaps on either side of the column.
Layout0Bands:
        .byte 66, $00, $80    ; row 3: center column begins (X 76..83)
        .byte 24, $00, $00    ; row 10: clear
        .byte  0, $00, $00    ; sentinel

; --- Layout 1: "Twin Bars" ---
; Two horizontal bars at rows 4 and 9 leaving a wide 72px center gap
; plus 28px gaps on each side.
Layout1Bands:
        .byte 60, $1E, $00    ; row 4: bar (X 28..43 left, mirror X 116..131)
        .byte 54, $00, $00    ; row 5: clear
        .byte 30, $1E, $00    ; row 9: bar (mirror of row 4)
        .byte 24, $00, $00    ; row 10: clear
        .byte  0, $00, $00    ; sentinel

; --- Layout 2: "Staggered Pillars" ---
; Two pairs of thin pillars at different vertical positions.  Outer
; pillars on rows 4..5, middle pillars on rows 8..9; all gaps >= 16px.
Layout2Bands:
        .byte 60, $40, $00    ; row 4: outer pillars (X 20..23 left, mirror X 136..139)
        .byte 48, $00, $00    ; row 6: clear
        .byte 36, $00, $20    ; row 8: middle pillars (X 68..71 left, mirror X 88..91)
        .byte 24, $00, $00    ; row 10: clear
        .byte  0, $00, $00    ; sentinel

; --- Layout 3: "Plus" ---
; Vertical center column on rows 4..9 crossed by a horizontal beam on
; row 6.  Beam intentionally has 12px notches either side of the
; column so the player can slip through.
;   Row 6 wall pattern:
;     PF1 $FF = X 16..47   (left bar)
;     PF2 $8F = X 48..63 + X 76..79  (right portion of left bar + column)
;   Mirror gives matching right-half walls, leaving 12px gaps at
;   X 64..75 and X 84..95 either side of the X 76..83 column.
Layout3Bands:
        .byte 60, $00, $80    ; row 4: center column begins (X 76..83)
        .byte 48, $FF, $8F    ; row 6: horizontal beam + column (12px side gaps)
        .byte 42, $00, $80    ; row 7: column only
        .byte 24, $00, $00    ; row 10: clear
        .byte  0, $00, $00    ; sentinel

; --- Layout 4: "Edges + Column" ---
; Center column on rows 3..4, edge pillars on rows 7..8.  Asymmetric
; vertical interest; gaps everywhere >= 16px.
Layout4Bands:
        .byte 66, $00, $80    ; row 3: center column (X 76..83)
        .byte 54, $00, $00    ; row 5: clear
        .byte 42, $80, $00    ; row 7: edge pillars (X 16..19 left, mirror X 140..143)
        .byte 30, $00, $00    ; row 9: clear
        .byte  0, $00, $00    ; sentinel

;---------------------------------------------------------------
; Celebration direction tables — 8 cardinal + diagonal directions
; for the auto-fire missile burst during GAME_OVER.  Indexed by
; (AIRand & $07).  All values are signed bytes in two's complement.
;
; Index 0: E   1: NE  2: N   3: NW  4: W   5: SW  6: S   7: SE
;---------------------------------------------------------------
CelebDXTbl:
        .byte MISSILE_SPEED            ; E
        .byte MISSILE_SPEED            ; NE
        .byte 0                        ; N
        .byte (256-MISSILE_SPEED)      ; NW
        .byte (256-MISSILE_SPEED)      ; W
        .byte (256-MISSILE_SPEED)      ; SW
        .byte 0                        ; S
        .byte MISSILE_SPEED            ; SE
CelebDYTbl:
        .byte 0                        ; E
        .byte (256-MISSILE_SPEED)      ; NE
        .byte (256-MISSILE_SPEED)      ; N
        .byte (256-MISSILE_SPEED)      ; NW
        .byte 0                        ; W
        .byte MISSILE_SPEED            ; SW
        .byte MISSILE_SPEED            ; S
        .byte MISSILE_SPEED            ; SE

;---------------------------------------------------------------
; CelebSpawnMissile — parameterized celebration missile spawn.
; Entry: X = 0 (M0) or MIS_OFFSET (M1)
;        Y = 0 (P0) or 1 (P1)
;---------------------------------------------------------------
CelebSpawnMissile:
        lda MxPlayerOff,Y        ; 0 (P0) or 4 (P1)
        tay
        clc
        lda P0X,Y
        adc #4
        sta M0X,X
        clc
        lda P0Y,Y
        adc #4
        sta M0Y,X
        lda AIRand
        and #$07
        tay
        lda CelebDXTbl,Y
        sta M0DX,X
        lda CelebDYTbl,Y
        sta M0DY,X
        lda #$80
        sta M0Active,X
        lda #MISSILE_LIFE
        sta M0Life,X
        lda M0X,X
        sta M0XPrev,X
        sec
        sbc M0DX,X
        sec
        sbc M0DX,X
        sta M0XPrev2,X
        lda M0Y,X
        sta M0YPrev,X
        sec
        sbc M0DY,X
        sec
        sbc M0DY,X
        sta M0YPrev2,X
        ldy #SND_FIRE
        jsr TriggerSnd0
        rts

; Legacy entry points for existing callers.
CelebSpawnM0:
        ldx #0
        ldy #0
        jmp CelebSpawnMissile
CelebSpawnM1:
        ldx #MIS_OFFSET
        ldy #1
        jmp CelebSpawnMissile

;---------------------------------------------------------------
; CelebUpdateMissiles — advance + despawn both missiles.
; Reuses MxDoUpdate from MissileUpdate.
;---------------------------------------------------------------
CelebUpdateMissiles:
        ldx #0
        lda M0Active,X
        bpl .skip0
        jsr MxDoUpdate
.skip0:
        ldx #MIS_OFFSET
        lda M0Active,X
        bpl .skip1
        jsr MxDoUpdate
.skip1:
        rts

;---------------------------------------------------------------
; Wall color palette — eight bright NTSC colors so the wall is
; clearly distinguishable from the playfield background each round.
;---------------------------------------------------------------
WallColorTbl:
        .byte $2E   ; orange
        .byte $4E   ; red
        .byte $6E   ; magenta
        .byte $8E   ; blue
        .byte $AE   ; cyan
        .byte $CE   ; green
        .byte $EE   ; yellow
        .byte $3E   ; light orange

;---------------------------------------------------------------
; Per-layout AIRand mask for the SpawnPlayers X jitter.  Indexed by
; LayoutIndex; $0F gives the full 16-px strip ([4..19] / [128..143]),
; smaller masks narrow it.  After the layout redesign every stored
; layout keeps rows 0..2 and 10..13 PF-clear in the player X range so
; the full mask is safe everywhere; the table is retained so future
; layouts with walls intruding into the spawn bands can locally
; tighten their spawn jitter without touching SpawnPlayers.
;---------------------------------------------------------------
P0XJitterTbl:
        .byte $0F   ; L0
        .byte $0F   ; L1
        .byte $0F   ; L2
        .byte $0F   ; L3
        .byte $0F   ; L4
P1XJitterTbl:
        .byte $0F   ; L0
        .byte $0F   ; L1
        .byte $0F   ; L2
        .byte $0F   ; L3
        .byte $0F   ; L4


;---------------------------------------------------------------
; SpawnPlayers — place P0 in the top blank band and P1 in the bottom
; blank band of the active stored layout, diagonally opposite each
; other.  PF0 is $00 for every band, so the left strip (X in [0..15])
; and right strip (X in [144..159]) are guaranteed clear of wall
; pixels for every layout.
;
; After the layout redesign every stored layout also keeps rows 0..2
; and rows 10..13 PF1/PF2-clear in the full P0/P1 spawn X range
; ([4..19] / [128..143]), so the 16-scanline sprite at Y=8..15 (top)
; or Y=148..155 (bottom) cannot overlap a wall on spawn.
;
; Per-layout safe-X jitter masks are stored in P0XJitterTbl /
; P1XJitterTbl above.  Currently every entry is $0F (full strip);
; the indirection is preserved so any future layout that needs a
; tighter spawn window can override its own entry without touching
; this routine.
;
; A small AIRand-derived Y jitter keeps spawns visually varied.
; Velocities and Prev/Prev2 history are reset so the wall-revert
; logic doesn't teleport the player on the very first frame.
;---------------------------------------------------------------
SpawnPlayers:
        ; P0 Y = 8 + (AIRand & $07)            -> [8..15]
        lda AIRand
        and #$07
        clc
        adc #8
        sta P0Y

        ; P1 Y = 148 + ((AIRand >> 3) & $07)   -> [148..155]
        lda AIRand
        lsr
        lsr
        lsr
        and #$07
        clc
        adc #148
        sta P1Y

        ; P0 X = 4 + (AIRand & P0XJitterTbl[LayoutIndex])
        ldy LayoutIndex
        lda AIRand
        and P0XJitterTbl,Y
        clc
        adc #4
        sta P0X

        ; P1 X = 128 + ((AIRand >> 4) & P1XJitterTbl[LayoutIndex])
        lda AIRand
        lsr
        lsr
        lsr
        lsr
        and P1XJitterTbl,Y
        clc
        adc #128
        sta P1X

        ; Zero velocities so the new round starts at rest.
        lda #0
        sta P0VX
        sta P0VY
        sta P1VX
        sta P1VY

        ; Seed Prev / Prev2 = current so the next-frame position
        ; shift can't pull the player back to a stale (possibly
        ; in-wall) position from the previous round.
        lda P0X
        sta P0XPrev
        sta P0XPrev2
        lda P0Y
        sta P0YPrev
        sta P0YPrev2
        lda P1X
        sta P1XPrev
        sta P1XPrev2
        lda P1Y
        sta P1YPrev
        sta P1YPrev2
        rts

;---------------------------------------------------------------
; TITLE KERNEL — asymmetric playfield, line-height 1 (no repeat).
; Layout: 47 top pad + 34 bitmap scanlines + 111 bottom pad = 192.
;
; Per-scanline timing (right-half PF write windows):
;   PF0R: cycles 28..49    PF1R: cycles 39..55    PF2R: cycles 50..65
;---------------------------------------------------------------
TitleKernel:
        ; Color cycle: blue <-> yellow, changes every 4 frames
        lda FrameCounter
        lsr
        lsr
        and #$07
        tax
        lda TitleColorTbl,X
        sta COLUPF
        lda #0
        sta CTRLPF              ; bit0=0 -> non-mirrored: PF redrawn for right
        sta PF0
        sta PF1
        sta PF2

        ; Top spacing: 47 black scanlines
        ldx #47
T_TopLoop:
        sta WSYNC
        dex
        bne T_TopLoop

        ; Title bitmap — 34 rows, 1 scanline each, asymmetric playfield.
        ldy #0
T_TitleLoop:
        sta WSYNC                ; cycle 0
        lda TitleBitmap+0,Y      ; +4 = 4
        sta PF0                  ; +3 = 7  (HBLANK)
        lda TitleBitmap+1,Y      ; +4 = 11
        sta PF1                  ; +3 = 14 (HBLANK)
        lda TitleBitmap+2,Y      ; +4 = 18
        sta PF2                  ; +3 = 21 (HBLANK)
        pha                      ; +3 = 24 (timing delay)
        pla                      ; +4 = 28
        lda TitleBitmap+3,Y      ; +4 = 32
        sta PF0                  ; +3 = 35 (window 28..49) ✓
        lda TitleBitmap+4,Y      ; +4 = 39
        sta PF1                  ; +3 = 42 (window 39..55) ✓
        lda TitleBitmap+5,Y      ; +4 = 46
        nop                      ; +2 = 48
        sta PF2                  ; +3 = 51 (window 50..65) ✓
        tya                      ; +2 = 53
        clc                      ; +2 = 55
        adc #6                   ; +2 = 57
        tay                      ; +2 = 59
        cpy #204                 ; +2 = 61
        bne T_TitleLoop          ; +3 = 64 (taken)

        lda #0
        sta PF0
        sta PF1
        sta PF2

        ; Variant-digit setup runs in the trailing portion of the line we
        ; just entered (well within HBLANK + visible budget).
        lda #VARIANT_DIGIT_COLOR
        sta COLUP0
        lda GameVariant
        asl
        asl
        asl                      ; A = GameVariant * 8 (DigitGfx row offset)
        sta TempScratch
        ldy #0

        ; Bottom pad: 70 pre + 1 setup + 16 digit + 24 post = 111 lines.
        ldx #70
T_BotPreLoop:
        sta WSYNC
        dex
        bne T_BotPreLoop

        ; Variant digit "1" or "2" — 8 rows x 2 scanlines each, drawn via
        ; P0 (positioned at X=76 in VBLANK during TITLE state).
T_VariantOuter:
        sta WSYNC                ; iter 1: ends setup line. iter k>=2: ends row(k-2) line B.
        tya
        clc
        adc TempScratch
        tax
        lda DigitGfx,X
        sta GRP0                 ; load digit row Y in HBLANK
        sta WSYNC                ; ends row Y line A
        iny
        cpy #8
        bne T_VariantOuter
        sta WSYNC                ; ends row 7 line B (GRP0 still has row 7 byte)
        lda #0
        sta GRP0                 ; clear in HBLANK of first post-pad line

        ldx #24
T_BotPostLoop:
        sta WSYNC
        dex
        bne T_BotPostLoop

        jmp KernelDone

;---------------------------------------------------------------
; PLAY KERNEL — 1-line dual sprite.
;
; Each iteration:
;   - sta WSYNC (resume cycle 0 of next scanline).
;   - Write pre-computed P0Curr -> GRP0 (cycles 3..6).
;   - Write pre-computed P1Curr -> GRP1 (cycles 9..12). Both within HBLANK.
;   - Inc PxRowState; compute next-line PxCurr (= SpriteGfx[RowState] when
;     in [0,7], else 0).
;   - dec line counter; loop.
;
; PxRowState was initialised to (1 - PxY) mod 256 in VBLANK so it wraps
; through 0..7 over scanlines PxY..PxY+7.
;---------------------------------------------------------------
PlayKernel:
        ; 2-line kernel: 86 iterations cover the 172-scanline play area
        ; (192 visible - 16 score band - 4 transition lines).
        ; Each iteration's bookkeeping consumes ~106 cycles, which naturally
        ; spans 2 scanlines (~152 cycles available); GRP/ENAM are written
        ; once during line A's HBLANK and persist through line B unchanged.
        ;
        ; Reset the band walker to the active layout's first band: the
        ; kernel advances BandPtr while drawing, so without this we'd
        ; render correctly the first frame but skip all bands on every
        ; subsequent frame (NextBandIter would be the sentinel 0).
        ldx LayoutIndex
        lda LayoutBaseLoTbl,X
        sta BandPtrL
        lda LayoutBaseHiTbl,X
        sta BandPtrH
        ldy #0
        lda (BandPtrL),Y
        sta NextBandIter

        lda PickupCtrlPF        ; mirror bit + ball size for this frame
        sta CTRLPF
        lda WallColor           ; randomized wall color (refreshed each round)
        sta COLUPF
        lda #0                  ; ensure playfield + ball start cleared at top
        sta PF0
        sta PF1
        sta PF2
        sta ENABL
        ldx #86                 ; iteration count (each iter = 2 scanlines)
PlayLoop:
        sta WSYNC
        ; --- Writes during HBLANK (must finish by end of HBLANK ~cycle 22).
        ; Sequence consumes ~24 cycles total; missile X bound MPF_LEFT=8
        ; ensures the latest write (ENAM1 ~cycle 24) lands before missile
        ; trigger at color clock 76+.  ENABL is NOT written here — it's
        ; toggled later (alongside the band-driven PF writes) via cpx
        ; checks so the per-iter cycle count fits the 2-line kernel.
        lda P0Curr
        sta GRP0
        lda P1Curr
        sta GRP1
        lda M0Curr
        sta ENAM0
        lda M1Curr
        sta ENAM1

        ; --- Bookkeeping for next scanline ---
        inc P0RowState
        lda P0RowState
        cmp #8
        bcs P0Off
        tay
        lda SpriteCache,Y
        sta P0Curr
        jmp P0NextDone
P0Off:
        lda #0
        sta P0Curr
P0NextDone:

        inc P1RowState
        lda P1RowState
        cmp #8
        bcs P1Off
        tay
        lda SpriteCache,Y
        sta P1Curr
        jmp P1NextDone
P1Off:
        lda #0
        sta P1Curr
P1NextDone:

        ; Missile next-scanline enable: $02 only when post-inc state == 0.
        inc M0RowState
        bne M0NextOff
        lda #2
        sta M0Curr
        jmp M0NextDone
M0NextOff:
        lda #0
        sta M0Curr
M0NextDone:

        inc M1RowState
        bne M1NextOff
        lda #2
        sta M1Curr
        jmp M1NextDone
M1NextOff:
        lda #0
        sta M1Curr
M1NextDone:

        ; --- Band-driven playfield transitions ---
        ; X is the iter counter (86..1).  Each stored layout is a list
        ; of (start_iter, PF1, PF2) bands in ROM.  When X hits
        ; NextBandIter, write the band's PF1/PF2 pair and advance
        ; BandPtr by 3 to the next band.  The list ends with
        ; start_iter=0 which X (1..86) never matches, so PF holds the
        ; last band's values.  CTRLPF mirror bit is set by
        ; PickupCtrlPF, so each PF byte reflects to the right half.
        ; PF0 is unconditionally $00 (cleared once in the preamble).
        cpx NextBandIter
        bne NotBandStart
        ldy #1
        lda (BandPtrL),Y         ; PF1
        sta PF1
        iny
        lda (BandPtrL),Y         ; PF2
        sta PF2
        ; Advance BandPtr by 3 to the next band's start_iter.
        clc
        lda BandPtrL
        adc #3
        sta BandPtrL
        bcc BandNoCarry
        inc BandPtrH
BandNoCarry:
        ldy #0
        lda (BandPtrL),Y
        sta NextBandIter
NotBandStart:

        ; --- Pickup ENABL transitions ---
        ; Toggle ENABL via cpx the same way walls toggle PF1.  When the
        ; pickup is inactive, PickupStartIter / PickupEndIter are 0, which
        ; X (1..86) never hits, so ENABL stays cleared.  When active, ENABL
        ; goes high at PickupStartIter and low at PickupEndIter, lighting
        ; the ball for PICKUP_HEIGHT (=5) consecutive iters.
        cpx PickupStartIter
        bne NotPickupStart
        lda #2
        sta ENABL
NotPickupStart:
        cpx PickupEndIter
        bne NotPickupEnd
        lda #0
        sta ENABL
NotPickupEnd:

        dex
        beq PlayLoopExit
        jmp PlayLoop             ; long-form: kernel body exceeds bne's signed-byte reach
PlayLoopExit:

        ; Clear graphics + missile enables to avoid carry-over into overscan.
        lda #0
        sta GRP0
        sta GRP1
        sta ENAM0
        sta ENAM1
        sta ENABL                ; clear ball in case it was rendering
        sta PF0
        sta PF1                  ; clear PF in case last band kept content lit
        sta PF2

KernelDone:
        ;-------------------------------------------------------
        ; Overscan (30 scanlines)
        ;-------------------------------------------------------
        lda #2
        sta VBLANK
        ldx #30
OverscanLoop:
        sta WSYNC
        dex
        bne OverscanLoop

        jmp FrameLoop

;---------------------------------------------------------------
; Sprite graphics — 8x8 diamond, identical for both players.
; Row 0 is the top of the visual sprite.
;---------------------------------------------------------------
SpriteGfx:
        .byte %00011000   ; row 0: ...##...
        .byte %00111100   ; row 1: ..####..
        .byte %01111110   ; row 2: .######.
        .byte %11111111   ; row 3: ########
        .byte %11111111   ; row 4: ########
        .byte %01111110   ; row 5: .######.
        .byte %00111100   ; row 6: ..####..
        .byte %00011000   ; row 7: ...##...

;---------------------------------------------------------------
; Hollow / outline sprite — used while BounceCool > 0 to give a
; "stunned" frame after a player-vs-player bounce. Center pixels
; are cleared so only the diamond outline remains.
;---------------------------------------------------------------
SpriteHollow:
        .byte %00011000   ; row 0: ...##...   (single line, left as-is)
        .byte %00100100   ; row 1: ..#..#..   (outline)
        .byte %01000010   ; row 2: .#....#.
        .byte %10000001   ; row 3: #......#
        .byte %10000001   ; row 4: #......#
        .byte %01000010   ; row 5: .#....#.
        .byte %00100100   ; row 6: ..#..#..
        .byte %00011000   ; row 7: ...##...

;---------------------------------------------------------------
; Score-digit graphics: 8 rows per digit, 0..8 (first to 8 wins).
; Drawn 8 px wide on the score band via P0/P1 sprites.
;---------------------------------------------------------------
DigitGfx:
        ; 0
        .byte %01111110
        .byte %11000011
        .byte %11000011
        .byte %11000011
        .byte %11000011
        .byte %11000011
        .byte %11000011
        .byte %01111110
        ; 1
        .byte %00011000
        .byte %00111000
        .byte %01111000
        .byte %00011000
        .byte %00011000
        .byte %00011000
        .byte %00011000
        .byte %01111110
        ; 2
        .byte %01111110
        .byte %11000011
        .byte %00000011
        .byte %00000110
        .byte %00011000
        .byte %01100000
        .byte %11000000
        .byte %11111111
        ; 3
        .byte %01111110
        .byte %11000011
        .byte %00000011
        .byte %00111110
        .byte %00000011
        .byte %00000011
        .byte %11000011
        .byte %01111110
        ; 4
        .byte %00001110
        .byte %00011110
        .byte %00110110
        .byte %01100110
        .byte %11111111
        .byte %00000110
        .byte %00000110
        .byte %00000110
        ; 5
        .byte %11111111
        .byte %11000000
        .byte %11000000
        .byte %11111110
        .byte %00000011
        .byte %00000011
        .byte %11000011
        .byte %01111110
        ; 6
        .byte %00111110
        .byte %01100000
        .byte %11000000
        .byte %11111110
        .byte %11000011
        .byte %11000011
        .byte %11000011
        .byte %01111110
        ; 7
        .byte %11111111
        .byte %00000011
        .byte %00000110
        .byte %00001100
        .byte %00011000
        .byte %00110000
        .byte %00110000
        .byte %00110000
        ; 8
        .byte %01111110
        .byte %11000011
        .byte %11000011
        .byte %01111110
        .byte %11000011
        .byte %11000011
        .byte %11000011
        .byte %01111110

;---------------------------------------------------------------
; Title Screen Bitmap — mode: asymmetric, line-height 1
;
; 6 bytes per row: PF0L, PF1L, PF2L, PF0R, PF1R, PF2R
; 34 rows (one scanline each).  94 top pad + 34 bitmap + 64 bottom = 192.
;
; PF bit→cell mapping (each cell = 4 color clocks):
;   PF0: bits 4,5,6,7          → 4 cells  (left to right)
;   PF1: bits 7,6,5,4,3,2,1,0  → 8 cells  (reversed!)
;   PF2: bits 0,1,2,3,4,5,6,7  → 8 cells  (left to right)
;---------------------------------------------------------------
TitleBitmap:
        .byte $00,$00,$40,$00,$00,$00 ;|                  X ||                    | (  7)
        .byte $00,$00,$E0,$00,$00,$00 ;|                 XXX||                    | (  8)
        .byte $C0,$BB,$E1,$00,$A9,$08 ;|  XXX XXX XXX    XXX||    X X X  X   X    | (  9)
        .byte $C0,$91,$10,$10,$A9,$08 ;|  XXX  X   X    X   ||X   X X X  X   X    | ( 10)
        .byte $40,$91,$10,$10,$AA,$15 ;|  X X  X   X    X   ||X   X X X X X X X   | ( 11)
        .byte $40,$91,$08,$20,$AA,$15 ;|  X X  X   X   X    || X  X X X X X X X   | ( 12)
        .byte $40,$91,$08,$20,$AA,$15 ;|  X X  X   X   X    || X  X X X X X X X   | ( 13)
        .byte $40,$91,$04,$40,$AA,$15 ;|  X X  X   X  X     ||  X X X X X X X X   | ( 14)
        .byte $40,$91,$44,$40,$AA,$15 ;|  X X  X   X  X   X ||  X X X X X X X X   | ( 15)
        .byte $40,$91,$04,$40,$AA,$15 ;|  X X  X   X  X     ||  X X X X X X X X   | ( 16)
        .byte $40,$91,$04,$40,$AA,$15 ;|  X X  X   X  X     ||  X X X X X X X X   | ( 17)
        .byte $C0,$11,$08,$20,$AA,$15 ;|  XX   X   X   X    || X  X X X X X X X   | ( 18)
        .byte $C0,$11,$08,$20,$AB,$1D ;|  XX   X   X   X    || X  X X X XXX XXX   | ( 19)
        .byte $40,$91,$10,$10,$AB,$0D ;|  X X  X   X    X   ||X   X X X XXX XX    | ( 20)
        .byte $40,$91,$10,$10,$AB,$0D ;|  X X  X   X    X   ||X   X X X XXX XX    | ( 21)
        .byte $40,$91,$A0,$00,$AB,$0D ;|  X X  X   X     X X||    X X X XXX XX    | ( 22)
        .byte $40,$91,$E0,$00,$52,$05 ;|  X X  X   X     XXX||     X X  X X X     | ( 23)
        .byte $40,$91,$40,$00,$52,$15 ;|  X X  X   X      X ||     X X  X X X X   | ( 24)
        .byte $40,$91,$40,$00,$52,$15 ;|  X X  X   X      X ||     X X  X X X X   | ( 25)
        .byte $40,$91,$00,$00,$52,$15 ;|  X X  X   X        ||     X X  X X X X   | ( 26)
        .byte $40,$91,$00,$00,$52,$15 ;|  X X  X   X        ||     X X  X X X X   | ( 27)
        .byte $40,$91,$00,$00,$52,$15 ;|  X X  X   X        ||     X X  X X X X   | ( 28)
        .byte $40,$B9,$00,$00,$52,$15 ;|  X X XXX  X        ||     X X  X X X X   | ( 29)
        .byte $C0,$80,$00,$00,$00,$00 ;|  XXX               ||                    | ( 30)
        .byte $00,$00,$00,$00,$00,$00 ;|                    ||                    | ( 31)
        .byte $00,$00,$00,$00,$00,$00 ;|                    ||                    | ( 32)
        .byte $00,$00,$00,$00,$00,$00 ;|                    ||                    | ( 33)
        .byte $C0,$BB,$01,$00,$FB,$1D ;|  XXX XXX XXX       ||    XXXXX XXX XXX   | ( 34)
        .byte $C0,$BB,$01,$00,$FB,$1D ;|  XXX XXX XXX       ||    XXXXX XXX XXX   | ( 35)
        .byte $40,$AA,$01,$00,$8A,$15 ;|  X X X X X X       ||    X   X X X X X   | ( 36)
        .byte $C0,$BB,$01,$00,$FB,$1D ;|  XXX XXX XXX       ||    XXXXX XXX XXX   | ( 37)
        .byte $00,$00,$00,$00,$00,$00 ;|                    ||                    | ( 38)
        .byte $00,$00,$00,$00,$00,$00 ;|                    ||                    | ( 39)
        .byte $00,$00,$00,$00,$00,$00 ;|                    ||                    | ( 40)

;---------------------------------------------------------------
; Reset / NMI / IRQ vectors
;---------------------------------------------------------------
        org $FFFC
        .word Reset             ; reset vector
        .word Reset             ; IRQ/BRK vector (unused on 2600)
