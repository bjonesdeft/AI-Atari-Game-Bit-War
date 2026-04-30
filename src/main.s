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
M0Active    equ $91
M0X         equ $92
M0Y         equ $93
M0DX        equ $94   ; signed: -MISSILE_SPEED, 0, +MISSILE_SPEED
M0DY        equ $95
M0RowState  equ $96   ; init = (1-M0Y) when active, else 0 (never enables)
M0Curr      equ $97   ; precomputed ENAM0 byte for next scanline ($00 or $02)
M1Active    equ $98
M1X         equ $99
M1Y         equ $9A
M1DX        equ $9B
M1DY        equ $9C
M1RowState  equ $9D
M1Curr      equ $9E

P0FlashCount equ $9F  ; frames remaining of P0 hit-flash (0 = no flash)
P1FlashCount equ $A0
FireSoundCount equ $A1 ; frames remaining of fire sound on AUDC0
HitSoundCount  equ $A2 ; frames remaining of hit sound on AUDC1
BounceCool     equ $A3 ; frames remaining where joystick input is ignored
                       ; after a P0-P1 bounce, so the negated velocity has
                       ; time to actually separate the sprites.

; v3 state
P0Score      equ $A4   ; 0..8
P1Score      equ $A5
RoundTimer   equ $A6   ; ROUND_OVER pause counter (frames)
AIFlags      equ $A7   ; bit 7 set = P0 is AI; bit 6 set = P1 is AI
FrameCounter equ $A8   ; increments every frame; LSB used for difficulty gate
P0DigitBase  equ $A9   ; precomputed P0Score * 8 (offset into DigitGfx)
P1DigitBase  equ $AA   ; precomputed P1Score * 8
AIFireCool   equ $AB   ; per-frame countdown until next AI fire attempt
GameOverWin  equ $AC   ; 0 = P0 wins, 1 = P1 wins (only valid in GAME_OVER)
SynthSWCHA   equ $AD   ; SWCHA copy with AI players' bits overridden
TempSpeed    equ $AE   ; scratch byte for collision-slowdown speed compare
TempScratch  equ $AF   ; general scratch byte (e.g. second speed sum)
SpriteCache  equ $B0   ; 8-byte sprite-row cache ($B0..$B7); SpriteGfx or
AIRand       equ $B8   ; LCG-driven pseudo-random byte; gates AI movement

; Pre-update positions, used to revert on wall collisions.
; Prev = position one frame ago, Prev2 = position two frames ago.
; Wall hit reverts to Prev2 (Prev is itself often inside the wall).
P0XPrev      equ $B9
P0YPrev      equ $BA
P1XPrev      equ $BB
P1YPrev      equ $BC
M0XPrev      equ $BD
M0YPrev      equ $BE
M1XPrev      equ $BF
M1YPrev      equ $C0
P0XPrev2     equ $C1
P0YPrev2     equ $C2
P1XPrev2     equ $C3
P1YPrev2     equ $C4
M0XPrev2     equ $C5
M0YPrev2     equ $C6
M1XPrev2     equ $C7
M1YPrev2     equ $C8
M0Life       equ $C9   ; frames remaining before missile auto-despawns
M1Life       equ $CA
                       ; SpriteHollow is copied here each frame in VBLANK.

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
AI_FIRE_PERIOD equ 90       ; AI tries to fire every ~1.5s
SCORE_BAND    equ 16        ; physical scanlines reserved at top for score
SCORE_P0_X    equ 36        ; pixel X of P0 score digit on score band
SCORE_P1_X    equ 108       ; pixel X of P1 score digit on score band
SCORE_DIGIT_TOP equ 5       ; first scoreband line where digit appears (1..8)

; Audio settings.
;   AUDC values (TIA waveforms): 4=pure square tone, 6=square low octave,
;                                8=white noise.
;   AUDF: divisor (higher = lower pitch).
;   AUDV: volume 0..15.
FIRE_DURATION equ 5   ; frames the fire sound plays
FIRE_AUDC     equ 6   ; low-octave square wave
FIRE_AUDF     equ 22  ; low pitch
FIRE_AUDV     equ 10
HIT_DURATION  equ 8   ; frames the hit sound plays
HIT_AUDC      equ 8   ; white noise
HIT_AUDF      equ 5   ; high-pitched noise
HIT_AUDV      equ 12

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
        lda P0FireEdge
        ora P1FireEdge
        bmi DoTitleStart        ; bit 7 set => press edge present (long-form)
        jmp RunSoundDecay
DoTitleStart:
        ; AI assignment: whichever player did NOT press fire becomes AI.
        ; If both pressed (rare), neither is AI.
        lda #0
        sta AIFlags
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

        ; Reset everything for a fresh game.
        lda #INIT_P0X
        sta P0X
        lda #INIT_P0Y
        sta P0Y
        lda #INIT_P1X
        sta P1X
        lda #INIT_P1Y
        sta P1Y
        lda #0
        sta P0VX
        sta P0VY
        sta P1VX
        sta P1VY
        sta P0Score
        sta P1Score
        sta M0Active
        sta M1Active
        sta P0FlashCount
        sta P1FlashCount
        sta BounceCool
        sta RoundTimer
        lda #ST_PLAY
        sta GameState
        jmp RunSoundDecay

NotTitleState:
        cmp #ST_PLAY
        beq InPlay
        cmp #ST_ROUND_OVER
        beq InRoundOver

        ; --- GAME_OVER state ---
        ; Frozen scene with final scores. Fire press returns to TITLE.
        lda P0FireEdge
        ora P1FireEdge
        bmi GODoReset
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
        sta GameState           ; A=0 = ST_TITLE
        jmp RunSoundDecay

InRoundOver:
        ; Brief pause after a successful hit. On timer expiry, reset
        ; positions/velocities/missiles for the next round.
        dec RoundTimer
        bne ROWaiting
        lda #INIT_P0X
        sta P0X
        lda #INIT_P0Y
        sta P0Y
        lda #INIT_P1X
        sta P1X
        lda #INIT_P1Y
        sta P1Y
        lda #0
        sta P0VX
        sta P0VY
        sta P1VX
        sta P1VY
        sta M0Active
        sta M1Active
        sta P0FlashCount
        sta P1FlashCount
        sta BounceCool
        lda #ST_PLAY
        sta GameState
ROWaiting:
        jmp RunSoundDecay

InPlay:
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

        ; --- AI fire logic: every AI_FIRE_PERIOD frames, force a fire-edge
        ; for each AI player whose missile is not already active. ---
        lda AIFireCool
        beq AIFireReady
        dec AIFireCool
        jmp AIFireDone
AIFireReady:
        bit AIFlags
        bpl P1AIFire            ; P0 not AI
        lda M0Active
        bmi P1AIFire            ; P0 missile already active
        lda #$80
        sta P0FireEdge
P1AIFire:
        lda AIFlags
        and #$40
        beq AIFireResetCool     ; P1 not AI
        lda M1Active
        bmi AIFireResetCool
        lda #$80
        sta P1FireEdge
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
        ; Missile update: per-player either spawn (on fire-press edge with
        ; non-neutral joystick and missile not active) or advance the active
        ; missile by (DX, DY) and despawn at the screen edge.
        ;-------------------------------------------------------

        ; ----- M0 -----
        lda M0Active
        bpl M0NotActive             ; bit 7 clear => not active, fall through to spawn
        jmp M0Update                ; bit 7 set => already active (long-form)
M0NotActive:

        ; Not active: try to spawn.
        lda P0FireEdge
        bmi M0CheckJoy              ; bit 7 set => press edge present
        jmp M0End                   ; no fire-press edge (long-form)
M0CheckJoy:
        lda SynthSWCHA
        and #$F0                    ; P0 joystick (bits 4..7)
        cmp #$F0
        bne M0DoSpawn               ; non-neutral => spawn (long-form below)
        jmp M0End                   ; centered => skip
M0DoSpawn:

        ; Spawn at player center.
        clc
        lda P0X
        adc #4
        sta M0X
        clc
        lda P0Y
        adc #4
        sta M0Y

        ; DX from right(bit7) / left(bit6)
        lda SynthSWCHA
        and #$80
        bne M0CheckLeft
        lda #MISSILE_SPEED
        sta M0DX
        jmp M0SetDY
M0CheckLeft:
        lda SynthSWCHA
        and #$40
        bne M0DXZero
        lda #(256-MISSILE_SPEED)
        sta M0DX
        jmp M0SetDY
M0DXZero:
        lda #0
        sta M0DX
M0SetDY:
        ; DY from up(bit4) / down(bit5)
        lda SynthSWCHA
        and #$10
        bne M0CheckDown
        lda #(256-MISSILE_SPEED)
        sta M0DY
        jmp M0Activate
M0CheckDown:
        lda SynthSWCHA
        and #$20
        bne M0DYZero
        lda #MISSILE_SPEED
        sta M0DY
        jmp M0Activate
M0DYZero:
        lda #0
        sta M0DY
M0Activate:
        lda #$80
        sta M0Active
        lda #MISSILE_LIFE
        sta M0Life
        ; Seed Prev/Prev2 so a missile fired into a wall has a Prev2
        ; that's outside the wall along its trajectory.
        lda M0X
        sta M0XPrev
        sec
        sbc M0DX
        sec
        sbc M0DX
        sta M0XPrev2
        lda M0Y
        sta M0YPrev
        sec
        sbc M0DY
        sec
        sbc M0DY
        sta M0YPrev2
        ; Fire sound (shared AUDC0 channel; last fire wins)
        lda #FIRE_DURATION
        sta FireSoundCount
        lda #FIRE_AUDC
        sta AUDC0
        lda #FIRE_AUDF
        sta AUDF0
        lda #FIRE_AUDV
        sta AUDV0
        jmp M0End

M0Update:
        ; Lifespan tick: despawn after MISSILE_LIFE frames.
        dec M0Life
        beq M0Despawn
        ; Shift Prev2 := Prev, then Prev := current.
        lda M0XPrev
        sta M0XPrev2
        lda M0YPrev
        sta M0YPrev2
        lda M0X
        sta M0XPrev
        lda M0Y
        sta M0YPrev
        ; Advance position by (DX, DY).
        clc
        lda M0X
        adc M0DX
        sta M0X
        clc
        lda M0Y
        adc M0DY
        sta M0Y

        ; Edge despawn check (X then Y).
        lda M0X
        cmp #MPF_LEFT
        bcc M0Despawn
        cmp #(MPF_RIGHT+1)
        bcs M0Despawn
        lda M0Y
        cmp #MPF_TOP
        bcc M0Despawn
        cmp #(MPF_BOTTOM+1)
        bcs M0Despawn
        jmp M0End
M0Despawn:
        lda #0
        sta M0Active
M0End:

        ; ----- M1 -----
        lda M1Active
        bpl M1NotActive
        jmp M1Update
M1NotActive:

        lda P1FireEdge
        bmi M1CheckJoy              ; bit 7 set => press edge
        jmp M1End
M1CheckJoy:
        lda SynthSWCHA
        and #$0F                    ; P1 joystick (bits 0..3)
        cmp #$0F
        bne M1DoSpawn
        jmp M1End
M1DoSpawn:

        clc
        lda P1X
        adc #4
        sta M1X
        clc
        lda P1Y
        adc #4
        sta M1Y

        ; DX from right(bit3) / left(bit2)
        lda SynthSWCHA
        and #$08
        bne M1CheckLeft
        lda #MISSILE_SPEED
        sta M1DX
        jmp M1SetDY
M1CheckLeft:
        lda SynthSWCHA
        and #$04
        bne M1DXZero
        lda #(256-MISSILE_SPEED)
        sta M1DX
        jmp M1SetDY
M1DXZero:
        lda #0
        sta M1DX
M1SetDY:
        ; DY from up(bit0) / down(bit1)
        lda SynthSWCHA
        and #$01
        bne M1CheckDown
        lda #(256-MISSILE_SPEED)
        sta M1DY
        jmp M1Activate
M1CheckDown:
        lda SynthSWCHA
        and #$02
        bne M1DYZero
        lda #MISSILE_SPEED
        sta M1DY
        jmp M1Activate
M1DYZero:
        lda #0
        sta M1DY
M1Activate:
        lda #$80
        sta M1Active
        lda #MISSILE_LIFE
        sta M1Life
        lda M1X
        sta M1XPrev
        sec
        sbc M1DX
        sec
        sbc M1DX
        sta M1XPrev2
        lda M1Y
        sta M1YPrev
        sec
        sbc M1DY
        sec
        sbc M1DY
        sta M1YPrev2
        lda #FIRE_DURATION
        sta FireSoundCount
        lda #FIRE_AUDC
        sta AUDC0
        lda #FIRE_AUDF
        sta AUDF0
        lda #FIRE_AUDV
        sta AUDV0
        jmp M1End

M1Update:
        dec M1Life
        beq M1Despawn
        lda M1XPrev
        sta M1XPrev2
        lda M1YPrev
        sta M1YPrev2
        lda M1X
        sta M1XPrev
        lda M1Y
        sta M1YPrev
        clc
        lda M1X
        adc M1DX
        sta M1X
        clc
        lda M1Y
        adc M1DY
        sta M1Y

        lda M1X
        cmp #MPF_LEFT
        bcc M1Despawn
        cmp #(MPF_RIGHT+1)
        bcs M1Despawn
        lda M1Y
        cmp #MPF_TOP
        bcc M1Despawn
        cmp #(MPF_BOTTOM+1)
        bcs M1Despawn
        jmp M1End
M1Despawn:
        lda #0
        sta M1Active
M1End:

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

        bit CXM0P                ; bit 7 -> N flag
        bpl NoM0Hit
        lda #FLASH_FRAMES
        sta P1FlashCount
        lda #0
        sta M0Active
        ; Hit sound (channel 1)
        lda #HIT_DURATION
        sta HitSoundCount
        lda #HIT_AUDC
        sta AUDC1
        lda #HIT_AUDF
        sta AUDF1
        lda #HIT_AUDV
        sta AUDV1
        ; v3: P0 scored on P1.  Increment P0Score and transition state.
        inc P0Score
        lda P0Score
        cmp #WIN_SCORE
        bcc M0HitRound
        lda #0
        sta GameOverWin       ; 0 = P0 wins
        lda #ST_GAME_OVER
        sta GameState
        jmp NoM0Hit
M0HitRound:
        lda #ROUND_PAUSE
        sta RoundTimer
        lda #ST_ROUND_OVER
        sta GameState
NoM0Hit:
        bit CXM1P
        bpl NoM1Hit
        lda #FLASH_FRAMES
        sta P0FlashCount
        lda #0
        sta M1Active
        lda #HIT_DURATION
        sta HitSoundCount
        lda #HIT_AUDC
        sta AUDC1
        lda #HIT_AUDF
        sta AUDF1
        lda #HIT_AUDV
        sta AUDV1
        ; v3: P1 scored on P0.
        inc P1Score
        lda P1Score
        cmp #WIN_SCORE
        bcc M1HitRound
        lda #1
        sta GameOverWin       ; 1 = P1 wins
        lda #ST_GAME_OVER
        sta GameState
        jmp NoM1Hit
M1HitRound:
        lda #ROUND_PAUSE
        sta RoundTimer
        lda #ST_ROUND_OVER
        sta GameState
NoM1Hit:

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

        ; Lock out joystick input so the negated velocities can separate
        ; the sprites before the user can push them back together.
        lda #BOUNCE_FRAMES
        sta BounceCool
NoBounce:
        sta CXCLR                ; clear all collision latches

RunSoundDecay:
        ;-------------------------------------------------------
        ; Per-frame sound decay.  When a counter reaches 0, mute its channel
        ; by zeroing AUDV.  AUDC/AUDF retain last values but are inaudible.
        ;-------------------------------------------------------
        lda FireSoundCount
        beq FireSoundOff
        dec FireSoundCount
        bne FireSoundDone
        lda #0
        sta AUDV0
        jmp FireSoundDone
FireSoundOff:
        ; counter already 0; ensure muted
        sta AUDV0
FireSoundDone:

        lda HitSoundCount
        beq HitSoundOff
        dec HitSoundCount
        bne HitSoundDone
        lda #0
        sta AUDV1
        jmp HitSoundDone
HitSoundOff:
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

        ; Set sprite colors. While a flash counter is non-zero, override the
        ; player's color with FLASH_COLOR for the brief hit-flash effect.
        lda P0FlashCount
        beq UseP0Color
        lda #FLASH_COLOR
        jmp SetP0Color
UseP0Color:
        lda #P0_COLOR
SetP0Color:
        sta COLUP0

        lda P1FlashCount
        beq UseP1Color
        lda #FLASH_COLOR
        jmp SetP1Color
UseP1Color:
        lda #P1_COLOR
SetP1Color:
        sta COLUP1

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
        ;-------------------------------------------------------
        ldx #0
        lda #SCORE_P0_X
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

        ; Restore the player colors for the play kernel.
        lda P0FlashCount
        beq SBUseP0Color
        lda #FLASH_COLOR
        jmp SBSetP0Color
SBUseP0Color:
        lda #P0_COLOR
SBSetP0Color:
        sta COLUP0

        lda P1FlashCount
        beq SBUseP1Color
        lda #FLASH_COLOR
        jmp SBSetP1Color
SBUseP1Color:
        lda #P1_COLOR
SBSetP1Color:
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
; TITLE KERNEL — renders "TEST GAME" via PF1/PF2, 192 scanlines.
;---------------------------------------------------------------
TitleKernel:
        lda #TITLE_COLOR
        sta COLUPF
        lda #0
        sta CTRLPF              ; bit0=0 -> repeat (unmirrored)
        sta PF0
        sta PF1
        sta PF2

        ; Top spacing: 36 black scanlines
        ldx #36
T_TopLoop:
        sta WSYNC
        dex
        bne T_TopLoop

        ; "TEST" — 6 glyph rows x 8 scanlines
        ldy #0
T_TestOuter:
        ldx #8
T_TestInner:
        sta WSYNC
        lda TestPF1Tbl,Y
        sta PF1
        lda TestPF2Tbl,Y
        sta PF2
        dex
        bne T_TestInner
        iny
        cpy #6
        bne T_TestOuter

        lda #0
        sta PF1
        sta PF2

        ; Mid gap: 24 lines
        ldx #24
T_GapLoop:
        sta WSYNC
        dex
        bne T_GapLoop

        ; "GAME"
        ldy #0
T_GameOuter:
        ldx #8
T_GameInner:
        sta WSYNC
        lda GamePF1Tbl,Y
        sta PF1
        lda GamePF2Tbl,Y
        sta PF2
        dex
        bne T_GameInner
        iny
        cpy #6
        bne T_GameOuter

        lda #0
        sta PF1
        sta PF2

        ; Bottom spacing: 36 lines
        ldx #36
T_BotLoop:
        sta WSYNC
        dex
        bne T_BotLoop

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
        lda #$01                ; mirrored playfield: cells 8..11 of left half
        sta CTRLPF              ; mirror to give two centered vertical bars
        lda #0                  ; ensure walls start cleared at top of play area
        sta PF1
        ldx #86                 ; iteration count (each iter = 2 scanlines)
PlayLoop:
        sta WSYNC
        ; --- Writes during HBLANK (must finish by end of HBLANK ~cycle 22).
        ; Sequence consumes ~24 cycles total; missile X bound MPF_LEFT=8
        ; ensures the latest write (ENAM1 ~cycle 24) lands before missile
        ; trigger at color clock 76+.
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

        ; --- Wall transitions ---
        ; X is the iteration counter (downcount from 86).  Iter K = X = 87-K.
        ; Two wall bands so a missile can ricochet between them:
        ;   Wall A: iters 20..32  (X 67..55) => 13 iters = 26 scanlines
        ;   Wall B: iters 54..66  (X 34..21) => 13 iters = 26 scanlines
        ; Each band is rendered with PF1=$0F under CTRLPF mirror, giving
        ; two centred 16-px-wide vertical bars.
        cpx #68
        bne NotWallAStart
        lda #$0F
        sta PF1
NotWallAStart:
        cpx #55
        bne NotWallAEnd
        lda #0
        sta PF1
NotWallAEnd:
        cpx #34
        bne NotWallBStart
        lda #$0F
        sta PF1
NotWallBStart:
        cpx #21
        bne NotWallBEnd
        lda #0
        sta PF1
NotWallBEnd:

        dex
        bne PlayLoop

        ; Clear graphics + missile enables to avoid carry-over into overscan.
        lda #0
        sta GRP0
        sta GRP1
        sta ENAM0
        sta ENAM1
        sta PF1                 ; clear wall PF in case last iter was inside
        sta PF0
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
; Playfield letter tables (same as Phase P2).
;---------------------------------------------------------------

TestPF1Tbl:
        .byte $EE   ; row 0  T(### ) E(### )
        .byte $48   ; row 1  T(.#. ) E(#.. )
        .byte $4E   ; row 2  T(.#. ) E(### )
        .byte $48   ; row 3  T(.#. ) E(#.. )
        .byte $48   ; row 4  T(.#. ) E(#.. )
        .byte $4E   ; row 5  T(.#. ) E(### )

TestPF2Tbl:
        .byte $77   ; row 0  S(### ) T(### )
        .byte $21   ; row 1  S(#.. ) T(.#. )
        .byte $27   ; row 2  S(### ) T(.#. )
        .byte $24   ; row 3  S(..# ) T(.#. )
        .byte $24   ; row 4  S(..# ) T(.#. )
        .byte $27   ; row 5  S(### ) T(.#. )

GamePF1Tbl:
        .byte $E4   ; row 0  G(### ) A(.#. )
        .byte $8A   ; row 1  G(#.. ) A(#.# )
        .byte $AE   ; row 2  G(#.# ) A(### )
        .byte $AA   ; row 3  G(#.# ) A(#.# )
        .byte $EA   ; row 4  G(### ) A(#.# )
        .byte $EA   ; row 5  G(### ) A(#.# )

GamePF2Tbl:
        .byte $75   ; row 0  M(#.# ) E(### )
        .byte $17   ; row 1  M(### ) E(#.. )
        .byte $75   ; row 2  M(#.# ) E(### )
        .byte $15   ; row 3  M(#.# ) E(#.. )
        .byte $15   ; row 4  M(#.# ) E(#.. )
        .byte $75   ; row 5  M(#.# ) E(### )

;---------------------------------------------------------------
; Reset / NMI / IRQ vectors
;---------------------------------------------------------------
        org $FFFC
        .word Reset             ; reset vector
        .word Reset             ; IRQ/BRK vector (unused on 2600)
