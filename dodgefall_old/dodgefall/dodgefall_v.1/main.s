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

GAMEOVER_Y    = $78
GAMEOVER_ATTR = $00


; =========================
; ZEROPAGE vars
; =========================
.segment "ZEROPAGE"
pad1:      .res 1
pad1_prev: .res 1   ; NEW: for Start edge-detect
new_presses: .res 1   ; optional, but super handy
paused:      .res 1    ; 0=running, 1=paused
player_x:  .res 1
nmi_ready: .res 1
game_state: .res 1   ; 0=title, 1=playing


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

heart_pulse: .res 1   ; counts frames for pulsing
heart_phase: .res 1

sfx_timer: .res 1

respawn_pending: .res 1   ; 0=no, 1=yes (spawn when pause_timer reaches 0)

zig_dir:   .res 1   ; 0 = left, 1 = right (or use $FF/$01 if you prefer)
zig_tick:  .res 1   ; small divider so it doesn't move every frame

power_timer: .res 1

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

; Snap player slightly toward the caught object (±2px), clamped to 08..F0
SnapPlayerTowardObj:
  lda obj_x
  cmp player_x
  beq @done           ; already aligned

  bcc @obj_left       ; obj_x < player_x

@obj_right:
  lda player_x
  clc
  adc #$02
  cmp #$F0
  bcc :+
    lda #$F0
  :
  sta player_x
  rts

@obj_left:
  lda player_x
  sec
  sbc #$02
  cmp #$08
  bcs :+
    lda #$08
  :
  sta player_x

@done:
  rts

; Spawn object at top with new X and new type
SpawnObject:
  ; if RNG ever hits 0, it will get stuck forever -> re-seed
  lda rng
  bne :+
    lda #$A7
    sta rng
  :

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

  ; advance RNG once (for X)
  jsr NextRNG

  ; choose X on an 8px grid
   lda rng
  eor frame_lo     ; mix in time so X can’t get “stuck-looking”
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
  and #$07          ; 0..7
  cmp #$01
  beq @make_power   ; ~1/8 chance (when ==1)
  cmp #$04
  bcc @make_good    ; 0,2,3 => good (3/8)
  ; 4,5,6,7 => bad (4/8)
  lda #$01
  sta obj_type
  rts

@make_good:
  lda #$00
  sta obj_type
  rts

@make_power:
  lda #$02
  sta obj_type
  rts



StartNewGame:
lda #$00
sta respawn_pending

lda #$00
sta power_timer

lda #$01
sta zig_dir
lda #$00
sta zig_tick

sta sfx_timer

  lda #$00
  sta misses
  sta game_over
  sta paused
  sta pause_timer
  sta flash_timer
  sta flash_pal
  sta score_lo
  sta score_hi

  lda #$01
  sta fall_speed
  lda #$00
  sta speed_pending
  sta frame_lo
  sta frame_hi

  lda #$78
  sta player_x

  jsr SpawnObject
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

lda #$80
sta OAM_BUF+0      ; Y
lda #$00
sta OAM_BUF+1      ; tile 0 (solid block)
lda #$00
sta OAM_BUF+2      ; pal 0
lda #$80
sta OAM_BUF+3      ; X

; wait vblank
@v1:
bit $2002
bpl @v1

; clear RAM ($0000-$07FF)
lda #$00
tax

lda #$00
sta sfx_timer

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

; --- APU hard reset / silence everything ---
lda #$00
sta $4015          ; disable all channels

lda #$30           ; pulse1 constant volume, volume=0
sta $4000
lda #$00
sta $4001
sta $4002
sta $4003

lda #$00
sta sfx_timer


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

lda #$00
sta heart_pulse
sta heart_phase

lda #$00
sta pad1_prev
sta paused

lda #$00
sta game_state       ; start on title


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

; ---- Lives HUD (16x16 hearts) ----
; We’ll use sprites 5..16 (12 sprites total)
; Place them lower than the score to avoid sprite-per-scanline overflow.
; Heart 0 at X=$C0, Heart 1 at X=$D4, Heart 2 at X=$E8
; Top row Y=$18, bottom row Y=$20

; Heart tile IDs
HEART_TL = $0D
HEART_TR = $0E
HEART_BL = $0F
HEART_BR = $10

HEART_Y_TOP = $18
HEART_Y_BOT = $20

; Attributes: use sprite palette 3 (no flip)
HEART_ATTR = $03

; --- Heart 0 (sprites 5-8) ---
lda #HEART_Y_TOP
sta OAM_BUF+20    ; s5 Y (TL)
sta OAM_BUF+24    ; s6 Y (TR)
lda #HEART_Y_BOT
sta OAM_BUF+28    ; s7 Y (BL)
sta OAM_BUF+32    ; s8 Y (BR)

lda #HEART_TL
sta OAM_BUF+21
lda #HEART_TR
sta OAM_BUF+25
lda #HEART_BL
sta OAM_BUF+29
lda #HEART_BR
sta OAM_BUF+33

lda #HEART_ATTR
sta OAM_BUF+22
sta OAM_BUF+26
sta OAM_BUF+30
sta OAM_BUF+34

lda #$C0
sta OAM_BUF+23    ; TL X
clc
adc #$08
sta OAM_BUF+27    ; TR X
lda #$C0
sta OAM_BUF+31    ; BL X
clc
adc #$08
sta OAM_BUF+35    ; BR X

; --- Heart 1 (sprites 9-12) ---
lda #HEART_Y_TOP
sta OAM_BUF+36
sta OAM_BUF+40
lda #HEART_Y_BOT
sta OAM_BUF+44
sta OAM_BUF+48

lda #HEART_TL
sta OAM_BUF+37
lda #HEART_TR
sta OAM_BUF+41
lda #HEART_BL
sta OAM_BUF+45
lda #HEART_BR
sta OAM_BUF+49

lda #HEART_ATTR
sta OAM_BUF+38
sta OAM_BUF+42
sta OAM_BUF+46
sta OAM_BUF+50

lda #$D4
sta OAM_BUF+39
clc
adc #$08
sta OAM_BUF+43
lda #$D4
sta OAM_BUF+47
clc
adc #$08
sta OAM_BUF+51

; --- Heart 2 (sprites 13-16) ---
lda #HEART_Y_TOP
sta OAM_BUF+52
sta OAM_BUF+56
lda #HEART_Y_BOT
sta OAM_BUF+60
sta OAM_BUF+64

lda #HEART_TL
sta OAM_BUF+53
lda #HEART_TR
sta OAM_BUF+57
lda #HEART_BL
sta OAM_BUF+61
lda #HEART_BR
sta OAM_BUF+65

lda #HEART_ATTR
sta OAM_BUF+54
sta OAM_BUF+58
sta OAM_BUF+62
sta OAM_BUF+66

lda #$E8
sta OAM_BUF+55
clc
adc #$08
sta OAM_BUF+59
lda #$E8
sta OAM_BUF+63
clc
adc #$08
sta OAM_BUF+67

; ---- PAUSED text (sprites 17..21), hidden by default ----
; Tile IDs (new): $11..$15 = P A U S E
PAUSE_Y = $60



; Y = hidden initially
lda #$FE
sta OAM_BUF+68   ; s17 Y
sta OAM_BUF+72   ; s18 Y
sta OAM_BUF+76   ; s19 Y
sta OAM_BUF+80   ; s20 Y
sta OAM_BUF+84   ; s21 Y

; tiles
lda #$11         ; 'P'
sta OAM_BUF+69
lda #$12         ; 'A'
sta OAM_BUF+73
lda #$13         ; 'U'
sta OAM_BUF+77
lda #$14         ; 'S'
sta OAM_BUF+81
lda #$15         ; 'E'
sta OAM_BUF+85

; attributes (palette 0)
lda #$00
sta OAM_BUF+70
sta OAM_BUF+74
sta OAM_BUF+78
sta OAM_BUF+82
sta OAM_BUF+86

; X positions (center-ish)
lda #$68
sta OAM_BUF+71    ; P
lda #$70
sta OAM_BUF+75    ; A
lda #$78
sta OAM_BUF+79    ; U
lda #$80
sta OAM_BUF+83    ; S
lda #$88
sta OAM_BUF+87    ; E

; ---- TITLE sprites (22..40) ----
; Lines:
;   "DODGE"  (5) at Y=$3C
;   "FALL"   (4) at Y=$48
;   "PRESS"  (5) at Y=$68
;   "START"  (5) at Y=$74
; Tile IDs:
;   D=$16 O=$17 G=$18 F=$19 L=$1A R=$1B T=$1C
;   P=$11 A=$12 E=$15 S=$14 (already exist)

TITLE_ATTR = $00

; ---- DODGE (sprites 22-26) ----
lda #$3C
sta OAM_BUF+88
sta OAM_BUF+92
sta OAM_BUF+96
sta OAM_BUF+100
sta OAM_BUF+104

lda #$16  ; D
sta OAM_BUF+89
lda #$17  ; O
sta OAM_BUF+93
lda #$16  ; D
sta OAM_BUF+97
lda #$18  ; G
sta OAM_BUF+101
lda #$15  ; E
sta OAM_BUF+105

lda #TITLE_ATTR
sta OAM_BUF+90
sta OAM_BUF+94
sta OAM_BUF+98
sta OAM_BUF+102
sta OAM_BUF+106

lda #$6C
sta OAM_BUF+91
lda #$74
sta OAM_BUF+95
lda #$7C
sta OAM_BUF+99
lda #$84
sta OAM_BUF+103
lda #$8C
sta OAM_BUF+107

; ---- FALL (sprites 27-30) ----
lda #$48
sta OAM_BUF+108
sta OAM_BUF+112
sta OAM_BUF+116
sta OAM_BUF+120

lda #$19  ; F
sta OAM_BUF+109
lda #$12  ; A
sta OAM_BUF+113
lda #$1A  ; L
sta OAM_BUF+117
lda #$1A  ; L
sta OAM_BUF+121

lda #TITLE_ATTR
sta OAM_BUF+110
sta OAM_BUF+114
sta OAM_BUF+118
sta OAM_BUF+122

lda #$70
sta OAM_BUF+111
lda #$78
sta OAM_BUF+115
lda #$80
sta OAM_BUF+119
lda #$88
sta OAM_BUF+123

; ---- PRESS (sprites 31-35) ----
lda #$68
sta OAM_BUF+124
sta OAM_BUF+128
sta OAM_BUF+132
sta OAM_BUF+136
sta OAM_BUF+140

lda #$11  ; P
sta OAM_BUF+125
lda #$1B  ; R
sta OAM_BUF+129
lda #$15  ; E
sta OAM_BUF+133
lda #$14  ; S
sta OAM_BUF+137
lda #$14  ; S
sta OAM_BUF+141

lda #TITLE_ATTR
sta OAM_BUF+126
sta OAM_BUF+130
sta OAM_BUF+134
sta OAM_BUF+138
sta OAM_BUF+142

lda #$6C
sta OAM_BUF+127
lda #$74
sta OAM_BUF+131
lda #$7C
sta OAM_BUF+135
lda #$84
sta OAM_BUF+139
lda #$8C
sta OAM_BUF+143

; ---- START (sprites 36-40) ----
lda #$74
sta OAM_BUF+144
sta OAM_BUF+148
sta OAM_BUF+152
sta OAM_BUF+156
sta OAM_BUF+160

lda #$14  ; S
sta OAM_BUF+145
lda #$1C  ; T
sta OAM_BUF+149
lda #$12  ; A
sta OAM_BUF+153
lda #$1B  ; R
sta OAM_BUF+157
lda #$1C  ; T
sta OAM_BUF+161

lda #TITLE_ATTR
sta OAM_BUF+146
sta OAM_BUF+150
sta OAM_BUF+154
sta OAM_BUF+158
sta OAM_BUF+162

lda #$6C
sta OAM_BUF+147
lda #$74
sta OAM_BUF+151
lda #$7C
sta OAM_BUF+155
lda #$84
sta OAM_BUF+159
lda #$8C
sta OAM_BUF+163

; hide remaining sprites
ldx #$A4
@hide:
  lda #$FE
  sta OAM_BUF,x
  inx
  bne @hide

  ; ---- GAME OVER text (sprites 41..48), hidden by default ----
; "GAMEOVER" (no space; we just leave a wider gap between E and O if desired)
; Tiles: G=$18 A=$12 M=$1D E=$15 O=$17 V=$1E E=$15 R=$1B
; Adjust $1D/$1E to your actual M/V tile IDs.


; hide by default (Y = FE)
lda #$FE
sta OAM_BUF+$A4  ; s41 Y
sta OAM_BUF+$A8  ; s42 Y
sta OAM_BUF+$AC  ; s43 Y
sta OAM_BUF+$B0  ; s44 Y
sta OAM_BUF+$B4  ; s45 Y
sta OAM_BUF+$B8  ; s46 Y
sta OAM_BUF+$BC  ; s47 Y
sta OAM_BUF+$C0  ; s48 Y

; tiles
lda #$18  ; G
sta OAM_BUF+$A5
lda #$12  ; A
sta OAM_BUF+$A9
lda #$1D  ; M
sta OAM_BUF+$AD
lda #$15  ; E
sta OAM_BUF+$B1
lda #$17  ; O
sta OAM_BUF+$B5
lda #$1E  ; V
sta OAM_BUF+$B9
lda #$15  ; E
sta OAM_BUF+$BD
lda #$1B  ; R
sta OAM_BUF+$C1

; attributes
lda #GAMEOVER_ATTR
sta OAM_BUF+$A6
sta OAM_BUF+$AA
sta OAM_BUF+$AE
sta OAM_BUF+$B2
sta OAM_BUF+$B6
sta OAM_BUF+$BA
sta OAM_BUF+$BE
sta OAM_BUF+$C2

; X positions (center-ish). Tweak to taste.
lda #$58
sta OAM_BUF+$A7   ; G
lda #$60
sta OAM_BUF+$AB   ; A
lda #$68
sta OAM_BUF+$AF   ; M
lda #$70
sta OAM_BUF+$B3   ; E

lda #$80          ; (small gap before OVER)
sta OAM_BUF+$B7   ; O
lda #$88
sta OAM_BUF+$BB   ; V
lda #$90
sta OAM_BUF+$BF   ; E
lda #$98
sta OAM_BUF+$C3   ; R




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


; ---- detect new button presses ----
lda pad1_prev
eor #$FF
and pad1
sta new_presses
lda pad1
sta pad1_prev

; =========================
; Start button (single unified handler)
; =========================
lda new_presses
and #%00010000          ; Start just pressed?
beq @after_start

  lda game_state
  bne @start_not_title

  ; --- on title: start game ---
  lda #$01
  sta game_state
  jsr StartNewGame
  jmp Apply

@start_not_title:
  lda game_over
  beq @start_toggle_pause

  ; --- game over: restart ---
  jsr StartNewGame
  jmp Apply

@start_toggle_pause:
  lda paused
  eor #$01
  sta paused
  beq :+
    jsr PlayPauseOnBeep
    jmp @after_start
  :
    jsr PlayPauseOffBeep

@after_start:

; =========================
; If still on title, DO NOT run gameplay logic
; =========================
lda game_state
bne :+
jmp Apply
:



; if game over, skip gameplay updates (still show sprites)
  lda game_over
  beq :+
  jmp Apply
:
  lda game_over
  beq :+
  jmp Apply
:
  lda paused
  beq :+
  jmp Apply          ; paused: freeze gameplay, still render
:

   lda pause_timer
  beq @do_game

  dec pause_timer
  bne @pause_apply

  ; pause just ended this frame
  lda respawn_pending
  beq @pause_apply
  lda #$00
  sta respawn_pending
  jsr SpawnObject

@pause_apply:
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
sbc #$02
sta player_x

@checkRight:
lda pad1
and #%00000001         ; Right
beq @fall
lda player_x
cmp #$F0
bcs @fall
clc
adc #$02
sta player_x

; ---- Falling object ----
@fall:
  lda obj_y
  clc
  adc fall_speed
  sta obj_y

  ; --- powerup zigzag ---
  lda obj_type
  cmp #$02
  bne @after_zig

  inc zig_tick
  lda zig_tick
  and #$03          ; move every 4 frames
  bne @after_zig

  lda zig_dir
  beq @zig_left

@zig_right:
  lda obj_x
  cmp #$EE         ; if >= EE, next +2 would hit F0
  bcs @flip_left
  clc
  adc #$02
  sta obj_x
  jmp @after_zig

@zig_left:
  lda obj_x
  cmp #$0A         ; if < 0A, next -2 would go below 08
  bcc @flip_right
  sec
  sbc #$02
  sta obj_x
  jmp @after_zig


@flip_left:
  lda #$00
  sta zig_dir
  jmp @after_zig

@flip_right:
  lda #$01
  sta zig_dir

@after_zig:

lda power_timer
beq @normal_speed

dec power_timer
lda #$01
sta fall_speed
jmp @after_speed

@normal_speed:
; existing fall_speed logic continues here

@after_speed:


; ---- Miss check (past bottom) ----
  lda obj_y          ; <-- restore correct value into A
  cmp #OBJ_RESET_Y
  bcc CheckCatch

; If bad OR powerup: miss is OK (no penalty)
lda obj_type
cmp #$00
bne RespawnOnly


; Missed GOOD => penalty
inc misses

lda #$08
sta flash_timer

jsr PlayMissBeep

lda #$03
sta pause_timer
lda #$03      ; <-- red palette now
sta flash_pal


lda misses
cmp #$03
bcc DoRespawnAfterMiss   ; misses < 3 => keep playing

lda #$01
sta game_over
jmp Apply

DoRespawnAfterMiss:
  lda #$01
  sta respawn_pending

  lda #$FE          ; hide object while paused
  sta obj_y

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
; obj_type: 0=good, 1=bad, 2=powerup
lda obj_type
beq @caught_good
cmp #$01
beq @caught_bad
jmp CaughtPower

@caught_good:
jsr SnapPlayerTowardObj

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

@caught_bad:
jsr SnapPlayerTowardObj

  inc misses

  lda #$08
  sta flash_timer
  jsr PlayMissBeep

lda #$03
sta pause_timer
lda #$03      ; <-- red palette now
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

CaughtPower:
jsr SnapPlayerTowardObj

  ; --- heal 1 heart ---
  lda misses
  beq :+
  dec misses
:

  ; --- slow time ---
  lda #180          ; ~3 seconds at 60fps
  sta power_timer

  lda #$06
  sta flash_timer
  lda #$02          ; blue flash
  sta flash_pal
  lda #$02
  sta pause_timer

  jsr PlayPowerupBeep
  jmp RespawnOnCatch





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
lda game_state
beq TitleApply
jmp PlayingApply

TitleApply:


; TITLE: hide gameplay UI + player/object + paused text
; GAME OVER text (sprites 41..48)
sta OAM_BUF+$A4
sta OAM_BUF+$A8
sta OAM_BUF+$AC
sta OAM_BUF+$B0
sta OAM_BUF+$B4
sta OAM_BUF+$B8
sta OAM_BUF+$BC
sta OAM_BUF+$C0

lda #$FE
sta OAM_BUF+0    ; player
sta OAM_BUF+4    ; object

sta OAM_BUF+8    ; score digit 1
sta OAM_BUF+12
sta OAM_BUF+16

; hearts (sprites 5..16)
sta OAM_BUF+20
sta OAM_BUF+24
sta OAM_BUF+28
sta OAM_BUF+32
sta OAM_BUF+36
sta OAM_BUF+40
sta OAM_BUF+44
sta OAM_BUF+48
sta OAM_BUF+52
sta OAM_BUF+56
sta OAM_BUF+60
sta OAM_BUF+64

; PAUSED text (17..21)
sta OAM_BUF+68
sta OAM_BUF+72
sta OAM_BUF+76
sta OAM_BUF+80
sta OAM_BUF+84

; Force title sprites visible every frame (22..40)
lda #$3C
sta OAM_BUF+88
sta OAM_BUF+92
sta OAM_BUF+96
sta OAM_BUF+100
sta OAM_BUF+104

lda #$48
sta OAM_BUF+108
sta OAM_BUF+112
sta OAM_BUF+116
sta OAM_BUF+120

lda #$68
sta OAM_BUF+124
sta OAM_BUF+128
sta OAM_BUF+132
sta OAM_BUF+136
sta OAM_BUF+140

lda #$74
sta OAM_BUF+144
sta OAM_BUF+148
sta OAM_BUF+152
sta OAM_BUF+156
sta OAM_BUF+160

jmp Forever


PlayingApply:

; ---- GAME OVER text visibility ----
lda game_over
beq @go_hide

  lda #GAMEOVER_Y
  sta OAM_BUF+$A4
  sta OAM_BUF+$A8
  sta OAM_BUF+$AC
  sta OAM_BUF+$B0
  sta OAM_BUF+$B4
  sta OAM_BUF+$B8
  sta OAM_BUF+$BC
  sta OAM_BUF+$C0
  jmp @go_done

@go_hide:
  lda #$FE
  sta OAM_BUF+$A4
  sta OAM_BUF+$A8
  sta OAM_BUF+$AC
  sta OAM_BUF+$B0
  sta OAM_BUF+$B4
  sta OAM_BUF+$B8
  sta OAM_BUF+$BC
  sta OAM_BUF+$C0

@go_done:



; --- restore player sprite (title mode hid it) ---
lda #PLAYER_Y
sta OAM_BUF+0          ; player Y back on-screen
lda #$00
sta OAM_BUF+1          ; tile 0 (solid) (optional but good)

; --- restore score Y ---
lda #$08
sta OAM_BUF+8
sta OAM_BUF+12
sta OAM_BUF+16

; Hide title sprites (22..40) by setting their Y to FE
lda #$FE
sta OAM_BUF+88
sta OAM_BUF+92
sta OAM_BUF+96
sta OAM_BUF+100
sta OAM_BUF+104
sta OAM_BUF+108
sta OAM_BUF+112
sta OAM_BUF+116
sta OAM_BUF+120
sta OAM_BUF+124
sta OAM_BUF+128
sta OAM_BUF+132
sta OAM_BUF+136
sta OAM_BUF+140
sta OAM_BUF+144
sta OAM_BUF+148
sta OAM_BUF+152
sta OAM_BUF+156
sta OAM_BUF+160

; ...then continue with your existing Apply code as normal...



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

; ---- lives HUD update (16x16 hearts) ----
; lives = 3 - misses
lda #$03
sec
sbc misses          ; A = lives (0..3)
sta tmp             ; reuse tmp as lives count

; Heart 0 visible if lives >= 1
lda tmp
cmp #$01
bcc @hide_heart0
  lda #HEART_Y_TOP
  sta OAM_BUF+20
  sta OAM_BUF+24
  lda #HEART_Y_BOT
  sta OAM_BUF+28
  sta OAM_BUF+32
  jmp @heart1
@hide_heart0:
  lda #$FE
  sta OAM_BUF+20
  sta OAM_BUF+24
  sta OAM_BUF+28
  sta OAM_BUF+32

@heart1:
; Heart 1 visible if lives >= 2
lda tmp
cmp #$02
bcc @hide_heart1
  lda #HEART_Y_TOP
  sta OAM_BUF+36
  sta OAM_BUF+40
  lda #HEART_Y_BOT
  sta OAM_BUF+44
  sta OAM_BUF+48
  jmp @heart2
@hide_heart1:
  lda #$FE
  sta OAM_BUF+36
  sta OAM_BUF+40
  sta OAM_BUF+44
  sta OAM_BUF+48

@heart2:
; Heart 2 visible if lives >= 3
lda tmp
cmp #$03
bcc @hide_heart2
  lda #HEART_Y_TOP
  sta OAM_BUF+52
  sta OAM_BUF+56
  lda #HEART_Y_BOT
  sta OAM_BUF+60
  sta OAM_BUF+64
  jmp @lives_done
@hide_heart2:
  lda #$FE
  sta OAM_BUF+52
  sta OAM_BUF+56
  sta OAM_BUF+60
  sta OAM_BUF+64

@lives_done:
; ---- PAUSED text visibility ----
lda paused
beq @pause_text_hide

  lda #PAUSE_Y
  sta OAM_BUF+68
  sta OAM_BUF+72
  sta OAM_BUF+76
  sta OAM_BUF+80
  sta OAM_BUF+84
  jmp @pause_text_done

@pause_text_hide:
  lda #$FE
  sta OAM_BUF+68
  sta OAM_BUF+72
  sta OAM_BUF+76
  sta OAM_BUF+80
  sta OAM_BUF+84

@pause_text_done:




; --- player attributes ---
; If paused: blink palette (overrides normal flash)
lda paused
beq @not_paused

lda frame_lo
lsr
lsr
lsr
lsr
lsr              ; divide by 32
and #$01
sta OAM_BUF+2

  sta OAM_BUF+2    ; palette 0/1
  jmp @attr_done

@not_paused:
  ; Normal flash effect on player attributes
  lda flash_timer
  beq @flash_off
  dec flash_timer
  lda flash_pal      ; use palette chosen by event
  jmp @set_attr
@flash_off:
  lda #$00           ; normal palette
@set_attr:
  sta OAM_BUF+2

@attr_done:




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
  lda obj_type
  beq @good_obj

  cmp #$01
  beq @bad_obj

  ; powerup
  lda #$02          ; palette 2 = blue
  jmp @set_obj_pal

@bad_obj:
  lda #$03          ; palette 3 = red (also used by hearts)
  jmp @set_obj_pal

@good_obj:
  lda #$01          ; palette 1 = green
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
    
; ---- gentle heart pulse (freeze while paused) ----
lda paused
bne @skip_pulse       ; paused? do nothing

inc heart_pulse
lda heart_pulse
and #$3F              ; pulse timing
bne @skip_pulse

lda heart_phase
eor #$01
sta heart_phase
tax

lda $2002
lda #$3F
sta $2006
lda #$1D              ; sprite palette 3, entry 1
sta $2006
lda HeartRedTable,x
sta $2007

@skip_pulse:

; ---- SFX auto-off (turn Pulse 1 back off) ----
lda sfx_timer
beq :+
dec sfx_timer
bne :+
  lda #$00
  sta $4015          ; disable all channels
  lda #$30
  sta $4000          ; volume = 0 (extra safety)
:
inc nmi_ready
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
  bne @done
  lda #$A7
  sta rng
@done:
  rts



SpeedupPitchTable:
.byte $B0, $90, $70     ; speed 1,2,3 (lower timer = higher pitch)

PlayPauseOnBeep:
  lda #$01
  sta $4015
  lda #%10011111
  sta $4000
  lda #$00
  sta $4001
  lda #$60
  sta $4002
  lda #%00010000
  sta $4003
  lda #$06
  sta sfx_timer
  rts

PlayPauseOffBeep:
  lda #$01
  sta $4015
  lda #%10011111
  sta $4000
  lda #$00
  sta $4001
  lda #$90
  sta $4002
  lda #%00010000
  sta $4003
  lda #$06
  sta sfx_timer
  rts


PlayCatchBeep:
  lda #$01
  sta $4015          ; enable pulse 1 only (during SFX)

  lda #%10011111
  sta $4000
  lda #$00
  sta $4001
  lda #$70
  sta $4002
  lda #%00010000
  sta $4003

  lda #$08           ; SFX lasts ~8 frames (tweak)
  sta sfx_timer
  rts

  PlayPowerupBeep:
  lda #$01
  sta $4015          ; enable pulse 1

  lda #%10011111     ; constant volume, loud
  sta $4000
  lda #$00
  sta $4001

  lda #$40           ; HIGHER pitch than normal catch
  sta $4002

  lda #%00110000     ; longer length counter
  sta $4003

  lda #$10           ; lasts ~16 frames (longer decay)
  sta sfx_timer
  rts



PlayMissBeep:
  lda #$01
  sta $4015          ; enable pulse 1

  lda #%10011111
  sta $4000
  lda #$00
  sta $4001
  lda #$C0           ; lower pitch
  sta $4002
  lda #%00110000     ; longer
  sta $4003

  lda #$08           ; lasts ~8 frames
  sta sfx_timer
  rts


PlaySpeedupBeep:
  lda #%10011111
  sta $4000
  lda #$00
  sta $4001
   lda #$08           ; SFX lasts ~8 frames (tweak)
  sta sfx_timer

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
.byte $0F,$20,$20,$20   ; pal0 player/UI (white)
.byte $0F,$2A,$2A,$2A   ; pal1 good (green)
.byte $0F,$12,$12,$12   ; pal2 powerup (blue-ish)  <-- tweak if you want
.byte $0F,$06,$06,$06   ; pal3 red (bad + hearts)  <-- hearts pulse edits entry1


HeartRedTable:
  .byte $06, $16




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

; Tiles 13-16 ($0D-$10): 16x16 heart metasprite (1-bit, rounder silhouette)
;  $0D = top-left     $0E = top-right
;  $0F = bottom-left  $10 = bottom-right

Heart16_TL:  ; tile $0D
  .byte $00,$1C,$3E,$7F,$7F,$3F,$1F,$0F
  .byte $00,$00,$00,$00,$00,$00,$00,$00

Heart16_TR:  ; tile $0E
  .byte $00,$38,$7C,$FE,$FE,$FC,$F8,$F0
  .byte $00,$00,$00,$00,$00,$00,$00,$00

Heart16_BL:  ; tile $0F
  .byte $07,$03,$01,$00,$00,$00,$00,$00
  .byte $00,$00,$00,$00,$00,$00,$00,$00

Heart16_BR:  ; tile $10
  .byte $E0,$C0,$80,$00,$00,$00,$00,$00
  .byte $00,$00,$00,$00,$00,$00,$00,$00

  ; Tiles 17-21 ($11-$15): PAUSE letters (1-bit)
; Each letter uses color index 1 (plane0), plane1 is 0

Pause_P:   ; $11
  .byte $7C,$66,$66,$7C,$60,$60,$60,$00
  .byte $00,$00,$00,$00,$00,$00,$00,$00

Pause_A:   ; $12
  .byte $18,$3C,$66,$66,$7E,$66,$66,$00
  .byte $00,$00,$00,$00,$00,$00,$00,$00

Pause_U:   ; $13
  .byte $66,$66,$66,$66,$66,$66,$3C,$00
  .byte $00,$00,$00,$00,$00,$00,$00,$00

Pause_S:   ; $14
  .byte $3C,$66,$60,$3C,$06,$66,$3C,$00
  .byte $00,$00,$00,$00,$00,$00,$00,$00

Pause_E:   ; $15
  .byte $7E,$60,$60,$7C,$60,$60,$7E,$00
  .byte $00,$00,$00,$00,$00,$00,$00,$00

; Tiles 22-28 ($16-$1C): Title letters D O G F L R T (1-bit)

Title_D: ; $16
  .byte $7C,$66,$66,$66,$66,$66,$7C,$00
  .byte $00,$00,$00,$00,$00,$00,$00,$00

Title_O: ; $17
  .byte $3C,$66,$66,$66,$66,$66,$3C,$00
  .byte $00,$00,$00,$00,$00,$00,$00,$00

Title_G: ; $18
  .byte $3C,$66,$60,$6E,$66,$66,$3C,$00
  .byte $00,$00,$00,$00,$00,$00,$00,$00

Title_F: ; $19
  .byte $7E,$60,$60,$7C,$60,$60,$60,$00
  .byte $00,$00,$00,$00,$00,$00,$00,$00

Title_L: ; $1A
  .byte $60,$60,$60,$60,$60,$60,$7E,$00
  .byte $00,$00,$00,$00,$00,$00,$00,$00

Title_R: ; $1B
  .byte $7C,$66,$66,$7C,$6C,$66,$66,$00
  .byte $00,$00,$00,$00,$00,$00,$00,$00

Title_T: ; $1C
  .byte $7E,$18,$18,$18,$18,$18,$18,$00
  .byte $00,$00,$00,$00,$00,$00,$00,$00

; Tile $1D: M (sharper inner V)
.byte $66,$7E,$5A,$66,$66,$66,$66,$00
.byte $00,$00,$00,$00,$00,$00,$00,$00




; Tile $1E: V
.byte $66,$66,$66,$66,$66,$3C,$18,$00
.byte $00,$00,$00,$00,$00,$00,$00,$00

; Fill remaining CHR (8192 - 496 bytes)
.res 8192-496, $00


