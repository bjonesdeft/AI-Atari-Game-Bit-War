; vcs.h — Atari 2600 hardware register definitions for DASM.
;
; Standard memory-mapped register names used in 6502 assembly for the VCS.
; Register addresses follow the canonical 2600 hardware layout:
;   $00..$3F  TIA write registers (and read shadow at $30..$3D)
;   $80..$FF  RIOT RAM (zero-page; 128 bytes)
;   $0280..$0297  RIOT I/O + timers
;
; Include with:  include "vcs.h"

;-------------------------------------------------------------------------
; TIA write registers
;-------------------------------------------------------------------------
VSYNC   = $00   ; vertical sync set/clear
VBLANK  = $01   ; vertical blank set/clear
WSYNC   = $02   ; wait for horizontal blank
RSYNC   = $03   ; reset horizontal sync counter
NUSIZ0  = $04   ; number/size player/missile 0
NUSIZ1  = $05   ; number/size player/missile 1
COLUP0  = $06   ; color-luminance player 0
COLUP1  = $07   ; color-luminance player 1
COLUPF  = $08   ; color-luminance playfield
COLUBK  = $09   ; color-luminance background
CTRLPF  = $0A   ; control playfield ball size & collisions
REFP0   = $0B   ; reflect player 0
REFP1   = $0C   ; reflect player 1
PF0     = $0D   ; playfield register byte 0
PF1     = $0E   ; playfield register byte 1
PF2     = $0F   ; playfield register byte 2
RESP0   = $10   ; reset player 0
RESP1   = $11   ; reset player 1
RESM0   = $12   ; reset missile 0
RESM1   = $13   ; reset missile 1
RESBL   = $14   ; reset ball
AUDC0   = $15   ; audio control 0
AUDC1   = $16   ; audio control 1
AUDF0   = $17   ; audio frequency 0
AUDF1   = $18   ; audio frequency 1
AUDV0   = $19   ; audio volume 0
AUDV1   = $1A   ; audio volume 1
GRP0    = $1B   ; graphics player 0
GRP1    = $1C   ; graphics player 1
ENAM0   = $1D   ; graphics (enable) missile 0
ENAM1   = $1E   ; graphics (enable) missile 1
ENABL   = $1F   ; graphics (enable) ball
HMP0    = $20   ; horizontal motion player 0
HMP1    = $21   ; horizontal motion player 1
HMM0    = $22   ; horizontal motion missile 0
HMM1    = $23   ; horizontal motion missile 1
HMBL    = $24   ; horizontal motion ball
VDELP0  = $25   ; vertical delay player 0
VDELP1  = $26   ; vertical delay player 1
VDELBL  = $27   ; vertical delay ball
RESMP0  = $28   ; reset missile 0 to player 0
RESMP1  = $29   ; reset missile 1 to player 1
HMOVE   = $2A   ; apply horizontal motion
HMCLR   = $2B   ; clear horizontal motion registers
CXCLR   = $2C   ; clear collision latches

;-------------------------------------------------------------------------
; TIA read registers (collision + input). Note: same address space as writes.
;-------------------------------------------------------------------------
CXM0P   = $30   ; collision M0-P1, M0-P0
CXM1P   = $31   ; collision M1-P0, M1-P1
CXP0FB  = $32   ; collision P0-PF, P0-BL
CXP1FB  = $33   ; collision P1-PF, P1-BL
CXM0FB  = $34   ; collision M0-PF, M0-BL
CXM1FB  = $35   ; collision M1-PF, M1-BL
CXBLPF  = $36   ; collision BL-PF
CXPPMM  = $37   ; collision P0-P1, M0-M1
INPT0   = $38   ; pot port 0 (paddle / button)
INPT1   = $39   ; pot port 1
INPT2   = $3A   ; pot port 2
INPT3   = $3B   ; pot port 3
INPT4   = $3C   ; input port 4 — joystick 0 fire button (active low; bit 7)
INPT5   = $3D   ; input port 5 — joystick 1 fire button (active low; bit 7)

;-------------------------------------------------------------------------
; RIOT (PIA 6532) — I/O ports and timers
;-------------------------------------------------------------------------
SWCHA   = $0280 ; port A (joysticks: P0=hi nibble, P1=lo nibble; active low)
SWACNT  = $0281 ; port A direction
SWCHB   = $0282 ; port B (console switches: select/reset/colour/diff)
SWBCNT  = $0283 ; port B direction
INTIM   = $0284 ; timer current value
TIMINT  = $0285 ; timer interrupt flag

TIM1T   = $0294 ; set timer, 1 clock interval
TIM8T   = $0295 ; set timer, 8 clock interval
TIM64T  = $0296 ; set timer, 64 clock interval
T1024T  = $0297 ; set timer, 1024 clock interval
