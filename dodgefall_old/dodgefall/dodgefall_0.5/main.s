; =========================
; main.s — Catch/Avoid base (ca65) with left/right only
; - NROM-128 (16KB PRG), 8KB CHR-ROM
; - Sprite-only rendering (BG off)
; - Frame-locked main loop using NMI flag
; - Controller 1 left/right movement
; - One falling object + 3 misses (lives)
; - Score counters + player flash on catch (palette swap)
; =========================

PRG_BANKS = 1
CHR_BANKS = 1

OAM_BUF   = $0200

; Tuning constants
PLAYER_Y    = $C8      ; slightly above bottom edge
OBJ_START_Y = $10
OBJ_RESET_Y = $F0      ; past bottom => counts as a miss

; =========================
; ZEROPAGE vars
; =========================
.segment "ZEROPAGE"
pad1:      .res 1
player_x:  .res 1
nmi_ready: .res 1

obj_x:     .res 1
obj_y:     .res 1
misses:    .res 1
game_over: .res 1
rng:       .res 1

score_lo:  .res 1
score_hi:  .res 1

flash_timer: .res 1
flash_pal:   .res 1   ; which sprite palette to use while flashing

obj_type: .res 1    ; 0 = good, 1 = bad

good_count: .res 1
fall_speed: .res 1
speed_pending: .res 1


frame_lo: .res 1
frame_hi: .res 1

tmp:     .res 1
digit_h: .res 1
digit_t: .res 1
digit_o: .res 1

pause_timer: .res 1




; =========================
; iNES HEADER
; =========================
.segment "HEADER"
.byte 'N','E','S',$1A
.byte PRG_BANKS
.byte CHR_BANKS
.byte $01              ; vertical mirroring, mapper 0
.byte $00
.byte $00
.byte $00
.byte $00
.byte $00,$00,$00,$00,$00

; =========================
; PRG CODE
; =========================
.segment "CODE"

; Convert score_lo (0..255) to 3 decimal digits: digit_h, digit_t, digit_o
CalcScoreDigits:
lda score_lo
sta tmp

lda #$00
sta digit_h
sta digit_t
sta digit_o

; hundreds
@hund_loop:
lda tmp
cmp #100
bcc @tens
sec
sbc #100
sta tmp
inc digit_h
jmp @hund_loop

; tens
@tens:
@tens_loop:
lda tmp
cmp #10
bcc @ones
sec
sbc #10
sta tmp
inc digit_t
jmp @tens_loop

; ones
@ones:
lda tmp
sta digit_o
rts


; Spawn object at top with new X and new type
; X range will be clamped to player's reachable area.
SpawnObject:
; reset Y
lda #OBJ_START_Y
sta obj_y

; apply pending speed-up only at spawn (fair pacing)
lda speed_pending
beq :+
lda #$00
sta speed_pending
lda fall_speed
cmp #$03
bcs :+
inc fall_speed
jsr PlaySpeedupBeep

: 
; ---- continue spawn ----
; advance RNG once (for X)
jsr NextRNG

; choose X on an 8px grid
lda rng
and #$F8

; clamp left to $08
cmp #$08
bcs :+
lda #$08
:
; clamp right to $F0
cmp #$F0
bcc :+
lda #$F0
:
sta obj_x

; advance RNG again (for type)
jsr NextRNG
lda rng
and #$01
sta obj_type

rts


Reset:
sei
cld
ldx #$40
stx $4017              ; disable APU frame IRQ
ldx #$FF
txs
inx                     ; X = 0

stx $2000              ; NMI off
stx $2001              ; rendering off
stx $4010              ; DMC IRQs off

; wait vblank
@v1:
bit $2002
bpl @v1

; clear RAM ($0000-$07FF)
lda #$00
tax

@clr:
sta $0000,x
sta $0100,x
sta $0200,x
sta $0300,x
sta $0400,x
sta $0500,x
sta $0600,x
sta $0700,x
inx
bne @clr

; wait vblank again (safe PPU writes)
@v2:
bit $2002
bpl @v2

; load palette to $3F00-$3F1F
lda $2002
lda #$3F
sta $2006
lda #$00
sta $2006
ldx #$00

@pal:
lda Palette,x
sta $2007
inx
cpx #$20
bne @pal

; --- APU init: enable Pulse 1 ---
lda #$01
sta $4015          ; enable pulse channel 1


; init game state
lda #$00
sta misses
sta game_over
sta nmi_ready
lda #$00
sta flash_timer
sta flash_pal


sta score_lo
sta score_hi

lda #$00
sta good_count

lda #$01
sta fall_speed

lda #$00
sta speed_pending
lda #$A7
sta rng
lda #$00
sta frame_lo
sta frame_hi
lda #$01

lda #$00
sta pause_timer



; init player position
lda #$78
sta player_x
jsr SpawnObject

; init OAM sprite 0 (player)
lda #PLAYER_Y
sta OAM_BUF+0          ; Y
lda #$00
sta OAM_BUF+1          ; tile 0 (solid)
lda #$00
sta OAM_BUF+2          ; attributes: sprite palette 0
lda player_x
sta OAM_BUF+3          ; X

; init OAM sprite 1 (falling object)
lda obj_y
sta OAM_BUF+4          ; Y
lda #$00
sta OAM_BUF+5          ; tile 0 (solid)
lda #$00
sta OAM_BUF+6          ; attributes: sprite palette 0
lda obj_x
sta OAM_BUF+7          ; X


; ---- Score HUD sprites (sprites 2,3,4) ----
; Position top-left: X=8,16,24  Y=8
; Tile = 1 + digit (start at '0')
lda #$08
sta OAM_BUF+8      ; sprite 2 Y
sta OAM_BUF+12     ; sprite 3 Y
sta OAM_BUF+16     ; sprite 4 Y

lda #$01           ; tile '0' (tile 1)
sta OAM_BUF+9
sta OAM_BUF+13
sta OAM_BUF+17

lda #$00           ; attributes (palette 0)
sta OAM_BUF+10
sta OAM_BUF+14
sta OAM_BUF+18

lda #$08
sta OAM_BUF+11     ; sprite 2 X
lda #$10
sta OAM_BUF+15     ; sprite 3 X
lda #$18
sta OAM_BUF+19     ; sprite 4 X

 
; ---- Lives HUD sprites (sprites 5,6,7) ----
; three small hearts at top-right-ish
lda #$08
sta OAM_BUF+20     ; sprite 5 Y
sta OAM_BUF+24     ; sprite 6 Y
sta OAM_BUF+28     ; sprite 7 Y

lda #$0B           ; tile 11 = 1-bit heart
sta OAM_BUF+21
sta OAM_BUF+25
sta OAM_BUF+29

lda #$03           ; attributes: sprite palette 3
sta OAM_BUF+22
sta OAM_BUF+26
sta OAM_BUF+30

lda #$D0
sta OAM_BUF+23
lda #$DA
sta OAM_BUF+27
lda #$E4
sta OAM_BUF+31

; hide remaining sprites
ldx #$20
@hide:
  lda #$FE
  sta OAM_BUF,x
  inx
  bne @hide


; enable NMI + rendering
lda #%10000000
sta $2000              ; NMI on
lda #%00010110
sta $2001              ; sprites ON, background OFF

Forever:
; wait for next frame
@wait:
lda nmi_ready
beq @wait
lda #$00
sta nmi_ready


jsr ReadPad1

; if game over, skip gameplay updates (still show sprites)
  lda game_over
  beq :+
  jmp Apply
:
  lda pause_timer
  beq @do_game
  dec pause_timer
  jmp Apply


@do_game:
; ---- Player movement (Left/Right only) ----
; Left = bit1, Right = bit0 (with ReadPad1 routine below)

lda pad1
and #%00000010         ; Left
beq @checkRight
lda player_x
cmp #$08
bcc @checkRight
sec
sbc #$01
sta player_x

@checkRight:
lda pad1
and #%00000001         ; Right
beq @fall
lda player_x
cmp #$F0
bcs @fall
clc
adc #$01
sta player_x

; ---- Falling object ----
@fall:
lda obj_y
clc
adc fall_speed
sta obj_y


; ---- Miss check (past bottom) ----
cmp #OBJ_RESET_Y
bcc CheckCatch

; If bad object: miss is OK (no penalty)
lda obj_type
bne RespawnOnly

; Missed GOOD => penalty
inc misses

lda #$08
sta flash_timer

jsr PlayMissBeep

lda #$03
sta pause_timer
lda #$02
sta flash_pal

lda misses
cmp #$03
bcc DoRespawnAfterMiss   ; misses < 3 => keep playing

lda #$01
sta game_over
jmp Apply

DoRespawnAfterMiss:
jsr SpawnObject
jmp Apply

RespawnOnly:
jsr SpawnObject
jmp Apply

RespawnOnCatch:
jsr SpawnObject
jmp Apply



; ---- Catch check ----
CheckCatch:
; Y proximity: |obj_y - PLAYER_Y| < 8
lda obj_y
sec
sbc #PLAYER_Y
cmp #$08
bcs Apply

; X proximity: abs(obj_x - player_x) < 8
lda obj_x
sec
sbc player_x
bcs @dx_ok
eor #$FF
clc
adc #$01
@dx_ok:
cmp #$08
bcs Apply

; -------- Caught! --------
lda obj_type
bne @caught_bad

@caught_good:
inc score_lo
bne @no_carry
inc score_hi
@no_carry:
lda #$08
sta flash_timer
lda #$02
sta pause_timer
lda #$01
sta flash_pal
jsr PlayCatchBeep
jmp RespawnOnCatch


@no_speedup:
lda #$08
sta flash_timer
lda #$01
sta flash_pal
jmp RespawnOnCatch


@caught_bad:
inc misses

lda #$08
sta flash_timer
jsr PlayMissBeep

lda #$03
sta pause_timer
lda #$02
sta flash_pal

lda misses
cmp #$03
bcc DoRespawnAfterBadCatch

lda #$01
sta game_over
jmp Apply

DoRespawnAfterBadCatch:
jsr SpawnObject
jmp Apply

; apply sprite positions / attributes to OAM buffer
Apply:
; ---- frame counter (always runs) ----
inc frame_lo
bne ApplyTimerCheck
inc frame_hi

ApplyTimerCheck:
; ---- request ramp every ~15 seconds (900 frames = $0384) ----
lda frame_hi
cmp #$03
bcc ApplyAfterRampCheck     ; hi < 3 -> not time

bne ApplyDoRamp             ; hi > 3 -> time

; hi == 3, check low byte
lda frame_lo
cmp #$84
bcc ApplyAfterRampCheck     ; lo < 84 -> not time

ApplyDoRamp:
; reset timer
lda #$00
sta frame_lo
sta frame_hi

; set pending (don't stack)
lda speed_pending
bne ApplyAfterRampCheck
lda #$01
sta speed_pending

ApplyAfterRampCheck:
; (continue with existing Apply code: score HUD, lives HUD, flash, etc.)

; ---- update score HUD (always runs) ----
jsr CalcScoreDigits

; tile index = 1 + digit (tile 1 is '0')
lda digit_h
clc
adc #$01
sta OAM_BUF+9      ; sprite 2 tile

lda digit_t
clc
adc #$01
sta OAM_BUF+13     ; sprite 3 tile

lda digit_o
clc
adc #$01
sta OAM_BUF+17     ; sprite 4 tile

; ---- lives HUD update (3 small hearts) ----
lda misses
cmp #$01
bcc @lives3
beq @lives2
cmp #$02
beq @lives1
jmp @lives0

@lives3:
lda #$08
sta OAM_BUF+20
sta OAM_BUF+24
sta OAM_BUF+28
jmp @lives_done

@lives2:
lda #$08
sta OAM_BUF+20
sta OAM_BUF+24
lda #$FE
sta OAM_BUF+28
jmp @lives_done

@lives1:
lda #$08
sta OAM_BUF+20
lda #$FE
sta OAM_BUF+24
sta OAM_BUF+28
jmp @lives_done

@lives0:
lda #$FE
sta OAM_BUF+20
sta OAM_BUF+24
sta OAM_BUF+28

@lives_done:


; (then your flash logic, player X, object logic, etc continues here)

; --- flash effect on player attributes ---
lda flash_timer
beq @flash_off
dec flash_timer
lda flash_pal      ; use palette chosen by event
jmp @set_attr
@flash_off:
lda #$00           ; normal palette (white)
@set_attr:
sta OAM_BUF+2


; Player X
lda player_x
sta OAM_BUF+3

; Object sprite: hide on game over, otherwise show
lda game_over
beq @obj_visible
lda #$FE
sta OAM_BUF+4
jmp @done_obj

@obj_visible:
; set object palette by type
lda obj_type
beq @good_obj
lda #$02          ; palette 2 = red (bad)
jmp @set_obj_pal
@good_obj:
lda #$01          ; palette 1 = green (good)
@set_obj_pal:
sta OAM_BUF+6

lda obj_y
sta OAM_BUF+4
lda obj_x
sta OAM_BUF+7


@done_obj:
jmp Forever

; -------------------------
; NMI: OAM DMA + frame flag
; -------------------------
NMI:
lda #$00
sta $2003
lda #$02
sta $4014              ; DMA from $0200
    
lda #$01
sta nmi_ready
rti


IRQ:
rti

; -------------------------
; Controller read
; Produces:
; bit0=Right, bit1=Left, bit2=Down, bit3=Up, bit4=Start, bit5=Select, bit6=B, bit7=A
; -------------------------
ReadPad1:
lda #$01
sta $4016
lda #$00
sta $4016

lda #$00
sta pad1

ldx #$08
@rloop:
lda $4016
lsr
rol pad1
dex
bne @rloop
rts

; -------------------------
; Simple RNG step (8-bit)
; -------------------------
NextRNG:
lda rng
asl
bcc @no_xor
eor #$1D
@no_xor:
sta rng
rts

SpeedupPitchTable:
.byte $B0, $90, $70     ; speed 1,2,3 (lower timer = higher pitch)

PlayCatchBeep:
  lda #%10011111   ; duty/volume
  sta $4000
  lda #$00
  sta $4001
  lda #$70         ; higher pitch
  sta $4002
  lda #%00010000   ; short length
  sta $4003
  rts

PlayMissBeep:
  lda #%10011111
  sta $4000
  lda #$00
  sta $4001
  lda #$C0         ; lower pitch
  sta $4002
  lda #%00110000   ; a bit longer
  sta $4003
  rts

PlaySpeedupBeep:
  lda #%10011111
  sta $4000
  lda #$00
  sta $4001

  ; index = fall_speed - 1 (cap 0..2)
  lda fall_speed
  sec
  sbc #$01
  cmp #$03
  bcc :+
  lda #$02
:
  tax
  lda SpeedupPitchTable,x
  sta $4002

  lda #%00100000
  sta $4003
  rts



@mod5:
cmp #$05
bcc @check
sec
sbc #$05
jmp @mod5

@check:
bne @done              ; remainder != 0 → not a multiple of 5





@done:
rts


; -------------------------
; Palette (32 bytes)
; Background off, but universal color still matters.
; Sprite palette 0 = white, palette 1 = red (flash).
; -------------------------
Palette:
; BG palettes (16)
.byte $0F,$00,$10,$20
.byte $0F,$00,$10,$20
.byte $0F,$00,$10,$20
.byte $0F,$00,$10,$20

; Sprite palettes (16 bytes total)
.byte $0F,$20,$20,$20   ; pal0 player (flat white)
.byte $0F,$2A,$2A,$2A   ; pal1 good (flat green)
.byte $0F,$16,$16,$16   ; pal2 bad (flat red)

; sprite palette 3 (hearts): outline / fill / highlight (darker)
.byte $0F,$06,$06,$06




; =========================
; VECTORS
; =========================
.segment "VECTORS"
.word NMI
.word Reset
.word IRQ

; =========================
; CHR ROM (8KB)
; Tile 0 = solid block (all 1s)
; =========================
.segment "CHARS"
; Tile 0: solid block (for player/object)
.byte $FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF
.byte $FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF

; Tiles 1..10: digits 0..9 (plane 0 set, plane 1 clear => color index 1)
Digits:
; 0
.byte $3C,$66,$6E,$76,$66,$66,$3C,$00
.byte $00,$00,$00,$00,$00,$00,$00,$00
; 1
.byte $18,$38,$18,$18,$18,$18,$7E,$00
.byte $00,$00,$00,$00,$00,$00,$00,$00
; 2
.byte $3C,$66,$06,$0C,$18,$30,$7E,$00
.byte $00,$00,$00,$00,$00,$00,$00,$00
; 3
.byte $3C,$66,$06,$1C,$06,$66,$3C,$00
.byte $00,$00,$00,$00,$00,$00,$00,$00
; 4
.byte $0C,$1C,$3C,$6C,$7E,$0C,$0C,$00
.byte $00,$00,$00,$00,$00,$00,$00,$00
; 5
.byte $7E,$60,$7C,$06,$06,$66,$3C,$00
.byte $00,$00,$00,$00,$00,$00,$00,$00
; 6
.byte $1C,$30,$60,$7C,$66,$66,$3C,$00
.byte $00,$00,$00,$00,$00,$00,$00,$00
; 7
.byte $7E,$06,$0C,$18,$30,$30,$30,$00
.byte $00,$00,$00,$00,$00,$00,$00,$00
; 8
.byte $3C,$66,$66,$3C,$66,$66,$3C,$00
.byte $00,$00,$00,$00,$00,$00,$00,$00
; 9
.byte $3C,$66,$66,$3E,$06,$0C,$38,$00
.byte $00,$00,$00,$00,$00,$00,$00,$00

; Tile 11: heart icon (uses color index 1 like digits)
; (plane 0 on, plane 1 off)
Heart:
  .byte $00,$66,$FF,$FF,$FF,$7E,$3C,$18   ; plane 0
  .byte $00,$00,$00,$00,$00,$00,$00,$00   ; plane 1

;; Tile 12 ($0C): shaded heart (clearer silhouette)
; plane 0 (LSB)
.byte $24,$66,$FF,$7E,$3C,$18,$08,$00
; plane 1 (MSB)
.byte $66,$FF,$FF,$7E,$3C,$18,$08,$00

; Tiles 13-16 ($0D-$10): 16x16 heart metasprite (1-bit silhouette)
; Layout:
;  $0D = top-left     $0E = top-right
;  $0F = bottom-left  $10 = bottom-right

Heart16_TL:  ; tile $0D
  .byte $00,$3C,$7E,$FE,$FF,$7F,$3F,$1F   ; plane 0
  .byte $00,$00,$00,$00,$00,$00,$00,$00   ; plane 1

Heart16_TR:  ; tile $0E
  .byte $00,$3C,$7E,$7F,$FF,$FE,$FC,$F8
  .byte $00,$00,$00,$00,$00,$00,$00,$00

Heart16_BL:  ; tile $0F
  .byte $0F,$07,$03,$01,$00,$00,$00,$00
  .byte $00,$00,$00,$00,$00,$00,$00,$00

Heart16_BR:  ; tile $10
  .byte $F0,$E0,$C0,$80,$00,$00,$00,$00
  .byte $00,$00,$00,$00,$00,$00,$00,$00


; Fill remaining CHR (8192 - 272 bytes)
.res 8192-272, $00


