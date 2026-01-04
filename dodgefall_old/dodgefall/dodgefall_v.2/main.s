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

NEWHIGH_BASE = $D8   ; sprites 54..61
NEWHIGH_Y    = $68
NEWHIGH_X    = $58


; =========================
; Scoring (packed BCD)
; =========================
SCORE_GOOD    = $10   ; +10
SCORE_POWER  = $25   ; +25
SCORE_BAD   = $10   ; −10 (used by subtract routine)
SCORE_MISS   = $00   ; optional later

HISCORE_Y  = $08      ; top row
HISCORE_X0 = $70      ; centered


PAUSE_Y = $60   ; Y position for the PAUSE text when visible

PAUSE_BASE = $C4   ; safe area after GAMEOVER ($A4..$C3)


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

score_bcd0: .res 1   ; low 2 digits: tens|ones  (TT OO)
score_bcd1: .res 1   ; next 2 digits: thousands|hundreds (Th Hu)
                       ; for your 3-digit HUD we use only the HUNDREDS nibble

high_bcd0:  .res 1   ; tens|ones
high_bcd1:  .res 1   ; thousands|hundreds

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

digit_th: .res 1

new_high:      .res 1   ; 0=no, 1=yes (set when a new high score is achieved)

jingle_on:     .res 1   ; 0=off, 1=playing
jingle_timer:  .res 1   ; frame countdown between notes
jingle_step:   .res 1   ; which note in the sequence (0..N-1)


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


StartHighScoreJingle:
  lda #$01
  sta jingle_on
  lda #$00
  sta jingle_step
  lda #$01
  sta jingle_timer     ; trigger immediate first note next NMI
  rts


UpdateHighScore:
  ; assume not new high unless we update
  lda #$00
  sta new_high

  ; if score_bcd1 > high_bcd1 => update
  lda score_bcd1
  cmp high_bcd1
  bcc @done
  bne @update

  ; score_bcd1 == high_bcd1, compare low byte
  lda score_bcd0
  cmp high_bcd0
  bcc @done
  beq @done

@update:
  lda score_bcd0
  sta high_bcd0
  lda score_bcd1
  sta high_bcd1

  lda #$01
  sta new_high
  jsr StartHighScoreJingle

@done:
  rts





; ----------------------------------------
; AddScoreA
; Adds A (0..99 works great) to score_bcd0/score_bcd1 (packed BCD)
; score_bcd0 = tens|ones, score_bcd1 = thousands|hundreds
; NES CPU has NO decimal mode, so we do manual BCD adjust.
; ----------------------------------------
AddScoreA:
  ; add to low byte
  clc
  adc score_bcd0
  sta score_bcd0

  ; adjust ones nibble if >= 10
  lda score_bcd0
  and #$0F
  cmp #$0A
  bcc :+
    lda score_bcd0
    clc
    adc #$06
    sta score_bcd0
  :

  ; adjust tens nibble if >= 10 (i.e. byte >= $A0)
  lda score_bcd0
  and #$F0
  cmp #$A0
  bcc :+
    lda score_bcd0
    clc
    adc #$60
    sta score_bcd0

    ; carry +1 into next byte (hundreds/thousands)
    lda score_bcd1
    clc
    adc #$01
    sta score_bcd1
  :

  ; adjust hundreds nibble
  lda score_bcd1
  and #$0F
  cmp #$0A
  bcc :+
    lda score_bcd1
    clc
    adc #$06
    sta score_bcd1
  :

  ; adjust thousands nibble (optional, but keeps it valid BCD forever)
  lda score_bcd1
  and #$F0
  cmp #$A0
  bcc :+
    lda score_bcd1
    clc
    adc #$60
    sta score_bcd1
  :

  rts

; ----------------------------------------
; SubScoreA
; Subtracts packed BCD A from score_bcd0/1
; A is packed BCD (e.g. $10 = 10, $25 = 25)
; Clamps at 0000
; ----------------------------------------
SubScoreA:
  sta tmp                ; tmp = amount to subtract (BCD)

  ; 16-bit subtract: score_bcd0/1 -= tmp
  lda score_bcd0
  sec
  sbc tmp
  sta score_bcd0

  lda score_bcd1
  sbc #$00               ; propagate borrow
  sta score_bcd1

  ; if underflow, clamp to 0000
  lda score_bcd1
  bmi @clamp_zero

  ; ---- BCD adjust low byte ----
  lda score_bcd0
  and #$0F
  cmp #$0A
  bcc :+
    lda score_bcd0
    sec
    sbc #$06
    sta score_bcd0
  :

  lda score_bcd0
  and #$F0
  cmp #$A0
  bcc :+
    lda score_bcd0
    sec
    sbc #$60
    sta score_bcd0
  :

  ; ---- BCD adjust high byte ----
  lda score_bcd1
  and #$0F
  cmp #$0A
  bcc :+
    lda score_bcd1
    sec
    sbc #$06
    sta score_bcd1
  :

  lda score_bcd1
  and #$F0
  cmp #$A0
  bcc :+
    lda score_bcd1
    sec
    sbc #$60
    sta score_bcd1
  :

  rts

@clamp_zero:
  lda #$00
  sta score_bcd0
  sta score_bcd1
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
sta new_high
sta jingle_on
sta jingle_timer
sta jingle_step

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
sta score_bcd0
sta score_bcd1


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


sta score_bcd0
sta score_bcd1


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

lda #$00
sta high_bcd0
sta high_bcd1

lda #$00
sta new_high
sta jingle_on
sta jingle_timer
sta jingle_step


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

; ---- Score HUD sprites (sprites 2,3,4,5) ----
; X = 8,16,24,32   Y = 8
lda #$08
; 4-digit score: sprites 2,3,4,5 => OAM +8,+12,+16,+20

; ---- High Score HUD sprites (sprites 18..21) ----
; base offsets: 72,76,80,84
lda #$00
sta OAM_BUF+74
sta OAM_BUF+78
sta OAM_BUF+82
sta OAM_BUF+86          ; attributes = palette 0

lda #HISCORE_X0
sta OAM_BUF+75
clc
adc #$08
sta OAM_BUF+79
lda #HISCORE_X0
clc
adc #$10
sta OAM_BUF+83
lda #HISCORE_X0
clc
adc #$18
sta OAM_BUF+87          ; X positions


; --- restore score Y (4 digits) ---
lda #$08
sta OAM_BUF+8
sta OAM_BUF+12
sta OAM_BUF+16
sta OAM_BUF+20


lda #$01
sta OAM_BUF+9
sta OAM_BUF+13
sta OAM_BUF+17
sta OAM_BUF+21      ; digit 4 tile

lda #$00
sta OAM_BUF+10
sta OAM_BUF+14
sta OAM_BUF+18
sta OAM_BUF+22      ; digit 4 attr

lda #$08
sta OAM_BUF+11
lda #$10
sta OAM_BUF+15
lda #$18
sta OAM_BUF+19
lda #$20
sta OAM_BUF+23      ; digit 4 X

; ---- Lives HUD (16x16 hearts) ----
; Hearts use sprites 6-17 (12 sprites total)
; Heart 0 base = +24, Heart 1 base = +40, Heart 2 base = +56

HEART_TL = $0D
HEART_TR = $0E
HEART_BL = $0F
HEART_BR = $10

HEART_Y_TOP = $18
HEART_Y_BOT = $20

HEART_ATTR = $03

; --- Heart 0 (sprites 6-9), base = +24 ---
HEART0_X = $C0

lda #HEART_Y_TOP
sta OAM_BUF+24    ; TL Y
sta OAM_BUF+28    ; TR Y
lda #HEART_Y_BOT
sta OAM_BUF+32    ; BL Y
sta OAM_BUF+36    ; BR Y

lda #HEART_TL
sta OAM_BUF+25
lda #HEART_TR
sta OAM_BUF+29
lda #HEART_BL
sta OAM_BUF+33
lda #HEART_BR
sta OAM_BUF+37

lda #HEART_ATTR
sta OAM_BUF+26
sta OAM_BUF+30
sta OAM_BUF+34
sta OAM_BUF+38

lda #HEART0_X
sta OAM_BUF+27
clc
adc #$08
sta OAM_BUF+31
lda #HEART0_X
sta OAM_BUF+35
clc
adc #$08
sta OAM_BUF+39


; --- Heart 1 (sprites 10-13), base = +40 ---
HEART1_X = $D4

lda #HEART_Y_TOP
sta OAM_BUF+40
sta OAM_BUF+44
lda #HEART_Y_BOT
sta OAM_BUF+48
sta OAM_BUF+52

lda #HEART_TL
sta OAM_BUF+41
lda #HEART_TR
sta OAM_BUF+45
lda #HEART_BL
sta OAM_BUF+49
lda #HEART_BR
sta OAM_BUF+53

lda #HEART_ATTR
sta OAM_BUF+42
sta OAM_BUF+46
sta OAM_BUF+50
sta OAM_BUF+54

lda #HEART1_X
sta OAM_BUF+43
clc
adc #$08
sta OAM_BUF+47
lda #HEART1_X
sta OAM_BUF+51
clc
adc #$08
sta OAM_BUF+55


; --- Heart 2 (sprites 14-17), base = +56 ---
HEART2_X = $E8

lda #HEART_Y_TOP
sta OAM_BUF+56
sta OAM_BUF+60
lda #HEART_Y_BOT
sta OAM_BUF+64
sta OAM_BUF+68

lda #HEART_TL
sta OAM_BUF+57
lda #HEART_TR
sta OAM_BUF+61
lda #HEART_BL
sta OAM_BUF+65
lda #HEART_BR
sta OAM_BUF+69

lda #HEART_ATTR
sta OAM_BUF+58
sta OAM_BUF+62
sta OAM_BUF+66
sta OAM_BUF+70

lda #HEART2_X
sta OAM_BUF+59
clc
adc #$08
sta OAM_BUF+63
lda #HEART2_X
sta OAM_BUF+67
clc
adc #$08
sta OAM_BUF+71


; ---- PAUSED text (5 sprites), hidden by default ----
; Tile IDs: $11..$15 = P A U S E

lda #$FE
sta OAM_BUF+PAUSE_BASE+0    ; P Y
sta OAM_BUF+PAUSE_BASE+4    ; A Y
sta OAM_BUF+PAUSE_BASE+8    ; U Y
sta OAM_BUF+PAUSE_BASE+12   ; S Y
sta OAM_BUF+PAUSE_BASE+16   ; E Y

; tiles
lda #$11
sta OAM_BUF+PAUSE_BASE+1    ; P tile
lda #$12
sta OAM_BUF+PAUSE_BASE+5    ; A tile
lda #$13
sta OAM_BUF+PAUSE_BASE+9    ; U tile
lda #$14
sta OAM_BUF+PAUSE_BASE+13   ; S tile
lda #$15
sta OAM_BUF+PAUSE_BASE+17   ; E tile

; attributes
lda #$00
sta OAM_BUF+PAUSE_BASE+2
sta OAM_BUF+PAUSE_BASE+6
sta OAM_BUF+PAUSE_BASE+10
sta OAM_BUF+PAUSE_BASE+14
sta OAM_BUF+PAUSE_BASE+18

; X positions
lda #$68
sta OAM_BUF+PAUSE_BASE+3
lda #$70
sta OAM_BUF+PAUSE_BASE+7
lda #$78
sta OAM_BUF+PAUSE_BASE+11
lda #$80
sta OAM_BUF+PAUSE_BASE+15
lda #$88
sta OAM_BUF+PAUSE_BASE+19



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

; hide remaining sprites (after PAUSE block) — Y bytes only
ldx #$D8
lda #$FE
@hide:
  sta OAM_BUF,x       ; Y
  inx
  inx
  inx
  inx                ; next sprite
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

; ---- NEW HIGH text (sprites 54..60), hidden by default ----
lda #$FE
sta OAM_BUF+NEWHIGH_BASE+0
sta OAM_BUF+NEWHIGH_BASE+4
sta OAM_BUF+NEWHIGH_BASE+8
sta OAM_BUF+NEWHIGH_BASE+12
sta OAM_BUF+NEWHIGH_BASE+16
sta OAM_BUF+NEWHIGH_BASE+20
sta OAM_BUF+NEWHIGH_BASE+24

; Tiles: N E W H I G H
lda #$1F  ; N
sta OAM_BUF+NEWHIGH_BASE+1
lda #$15  ; E
sta OAM_BUF+NEWHIGH_BASE+5
lda #$20  ; W
sta OAM_BUF+NEWHIGH_BASE+9
lda #$21  ; H
sta OAM_BUF+NEWHIGH_BASE+13
lda #$22  ; I
sta OAM_BUF+NEWHIGH_BASE+17
lda #$18  ; G
sta OAM_BUF+NEWHIGH_BASE+21
lda #$21  ; H
sta OAM_BUF+NEWHIGH_BASE+25

; attributes (palette 0) for NEW HIGH (7 sprites)
lda #$00
sta OAM_BUF+NEWHIGH_BASE+2
sta OAM_BUF+NEWHIGH_BASE+6
sta OAM_BUF+NEWHIGH_BASE+10
sta OAM_BUF+NEWHIGH_BASE+14
sta OAM_BUF+NEWHIGH_BASE+18
sta OAM_BUF+NEWHIGH_BASE+22
sta OAM_BUF+NEWHIGH_BASE+26

; X positions: NEWHIGH_X + 0,8,16, 32,40,48,56
lda #NEWHIGH_X
sta OAM_BUF+NEWHIGH_BASE+3      ; N
clc
adc #$08
sta OAM_BUF+NEWHIGH_BASE+7      ; E
clc
adc #$08
sta OAM_BUF+NEWHIGH_BASE+11     ; W

; ---- space here (skip +$08) ----
clc
adc #$10
sta OAM_BUF+NEWHIGH_BASE+15     ; H
clc
adc #$08
sta OAM_BUF+NEWHIGH_BASE+19     ; I
clc
adc #$08
sta OAM_BUF+NEWHIGH_BASE+23     ; G
clc
adc #$08
sta OAM_BUF+NEWHIGH_BASE+27     ; H



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
; Gate: only run gameplay when actually playing
; =========================

; If still on title, just render title
lda game_state
bne :+
  jmp Apply
:

; If game over, just render (still shows GAME OVER)
lda game_over
beq :+
  jmp Apply
:

; If paused, just render (PAUSE text handled in Apply)
lda paused
beq :+
  jmp Apply
:

; If pause_timer running (post-catch/miss freeze), count it down,
; maybe spawn when it hits 0, then render.
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

; ---- Player movement ----
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
beq @afterMove
  lda player_x
  cmp #$F0
  bcs @afterMove
  clc
  adc #$02
  sta player_x

@afterMove:
; ---- choose effective fall speed (tmp = effective speed) ----
  lda power_timer
  beq @use_normal_speed

  dec power_timer
  lda #$01
  sta tmp              ; slowed => speed 1
  jmp @have_speed

@use_normal_speed:
  lda fall_speed
  sta tmp              ; normal speed

@have_speed:
; ---- Falling object (Y) ----
  lda obj_y
  clc
  adc tmp
  sta obj_y

; --- powerup zigzag (X) ---
  lda obj_type
  cmp #$02
  bne @after_zig

  inc zig_tick
  lda zig_tick
  and #$03              ; move every 4 frames
  bne @after_zig

  lda zig_dir
  beq @zig_left

@zig_right:
  lda obj_x
  cmp #$EE
  bcs @flip_left
  clc
  adc #$02
  sta obj_x
  jmp @after_zig

@zig_left:
  lda obj_x
  cmp #$0A
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

; ---- Miss check (past bottom) ----
  lda obj_y
  cmp #OBJ_RESET_Y
  bcc CheckCatch


; If bad OR powerup: miss is OK (no penalty)
lda obj_type
cmp #$00
bne RespawnOnly


; Missed GOOD => penalty
inc misses

lda #SCORE_BAD  
jsr SubScoreA


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

; --- GAME OVER (missed good) ---
lda game_over
bne @already_over_miss

jsr UpdateHighScore     ; ← capture final score ONCE
lda #$01
sta game_over

@already_over_miss:
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


CheckCatch:
  ; tmp = catch threshold (8 normally, 10 for powerup)
  lda obj_type
  cmp #$02
  bne :+
    lda #$0A       ; powerup leniency = 10
    sta tmp
    jmp @have_thr
:
  lda #$08
  sta tmp
@have_thr:

   ; Y proximity
  lda obj_y
  sec
  sbc #PLAYER_Y
  cmp tmp
  bcs @apply

  ; X proximity (abs diff)
  lda obj_x
  sec
  sbc player_x
  bcs @dx_ok
  eor #$FF
  clc
  adc #$01
@dx_ok:
  cmp tmp
  bcs @apply


  ; -------- Caught! --------
  lda obj_type
  beq @caught_good
  cmp #$01
  beq @caught_bad
  jmp CaughtPower

@apply:
  jmp Apply


@caught_good:
jsr SnapPlayerTowardObj

  lda #SCORE_GOOD
jsr AddScoreA


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

  lda #SCORE_BAD     ; −10 points
  jsr SubScoreA

  inc misses

  lda #$08
  sta flash_timer
  jsr PlayMissBeep

  lda #$03
  sta pause_timer
  lda #$03
  sta flash_pal

lda misses
cmp #$03
bcc DoRespawnAfterBadCatch

; --- GAME OVER (caught bad) ---
lda game_over
bne @already_over_bad

jsr UpdateHighScore     ; ← capture final score ONCE
lda #$01
sta game_over

@already_over_bad:
jmp Apply




DoRespawnAfterBadCatch:
  jsr SpawnObject
  jmp Apply

CaughtPower:

  lda #SCORE_POWER
jsr AddScoreA


  lda #180
  sta power_timer       ; refresh duration every time

  jsr SnapPlayerTowardObj

  lda misses
  beq :+
  dec misses
:
  lda #$06
  sta flash_timer
  lda #$02
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
beq @title
jmp PlayingApply
@title:
jmp TitleApply


TitleApply:
  ; Hide ALL sprites (Y = $FE for every sprite) to prevent leftovers
  ldx #$00
  lda #$FE
@hide_all_title:
  sta OAM_BUF,x
  inx
  inx
  inx
  inx
  bne @hide_all_title

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

  ; =========================
  ; HIGH SCORE (top-left)
  ; Uses score sprites 2..5
  ; =========================

  ; Y position
  lda #$08
  sta OAM_BUF+8
  sta OAM_BUF+12
  sta OAM_BUF+16
  sta OAM_BUF+20

  ; Attributes (palette 0)
  lda #$00
  sta OAM_BUF+10
  sta OAM_BUF+14
  sta OAM_BUF+18
  sta OAM_BUF+22

  ; X positions
  lda #$08
  sta OAM_BUF+11
  lda #$10
  sta OAM_BUF+15
  lda #$18
  sta OAM_BUF+19
  lda #$20
  sta OAM_BUF+23

 ; ---- digits from high score (packed BCD) ----

; thousands
lda high_bcd1
lsr
lsr
lsr
lsr
and #$0F
clc
adc #$01
sta OAM_BUF+9

; hundreds
lda high_bcd1
and #$0F
clc
adc #$01
sta OAM_BUF+13

; tens
lda high_bcd0
lsr
lsr
lsr
lsr
and #$0F
clc
adc #$01
sta OAM_BUF+17

; ones
lda high_bcd0
and #$0F
clc
adc #$01
sta OAM_BUF+21

jmp Forever


PlayingApply:
  ; Hide ALL sprites first (prevents stray lines / fragments)
  ldx #$00
  lda #$FE
@hide_all_play:
  sta OAM_BUF,x
  inx
  inx
  inx
  inx
  bne @hide_all_play

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

; ---- NEW HIGH visibility (blink while jingle plays) ----
lda game_over
beq @nh_hide
lda new_high
beq @nh_hide

; if jingle is playing, blink text
lda jingle_on
beq @nh_show_solid

  lda frame_lo
  and #$10          ; toggle every 16 frames
  bne @nh_hide

@nh_show_solid:
  lda #NEWHIGH_Y
  sta OAM_BUF+NEWHIGH_BASE+0
  sta OAM_BUF+NEWHIGH_BASE+4
  sta OAM_BUF+NEWHIGH_BASE+8
  sta OAM_BUF+NEWHIGH_BASE+12
  sta OAM_BUF+NEWHIGH_BASE+16
  sta OAM_BUF+NEWHIGH_BASE+20
  sta OAM_BUF+NEWHIGH_BASE+24
  jmp @nh_done


@nh_hide:
  lda #$FE
  sta OAM_BUF+NEWHIGH_BASE+0
  sta OAM_BUF+NEWHIGH_BASE+4
  sta OAM_BUF+NEWHIGH_BASE+8
  sta OAM_BUF+NEWHIGH_BASE+12
  sta OAM_BUF+NEWHIGH_BASE+16
  sta OAM_BUF+NEWHIGH_BASE+20
  sta OAM_BUF+NEWHIGH_BASE+24

@nh_done:


; --- restore player sprite (title mode hid it) ---
lda #PLAYER_Y
sta OAM_BUF+0          ; player Y back on-screen
lda #$00
sta OAM_BUF+1          ; tile 0 (solid) (optional but good)

; --- restore score Y (4 digits) ---
lda #$08
sta OAM_BUF+8
sta OAM_BUF+12
sta OAM_BUF+16
sta OAM_BUF+20

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

; ---- update score HUD from packed BCD ----

; score_bcd1: thousands|hundreds  (high nibble | low nibble)
; score_bcd0: tens|ones           (high nibble | low nibble)

; thousands
lda score_bcd1
lsr
lsr
lsr
lsr
and #$0F
sta digit_th

; hundreds
lda score_bcd1
and #$0F
sta digit_h

; tens
lda score_bcd0
lsr
lsr
lsr
lsr
and #$0F
sta digit_t

; ones
lda score_bcd0
and #$0F
sta digit_o

; write to OAM: tiles are 1..10 for digits 0..9, so +1
lda digit_th
clc
adc #$01
sta OAM_BUF+9      ; sprite 2 tile (thousands)

lda digit_h
clc
adc #$01
sta OAM_BUF+13     ; sprite 3 tile (hundreds)

lda digit_t
clc
adc #$01
sta OAM_BUF+17     ; sprite 4 tile (tens)

lda digit_o
clc
adc #$01
sta OAM_BUF+21     ; sprite 5 tile (ones)

; =========================
; HIGH SCORE HUD (top-center, sprites 18..21)
; =========================

; Y position (same scanline as score)
lda #HISCORE_Y
sta OAM_BUF+72
sta OAM_BUF+76
sta OAM_BUF+80
sta OAM_BUF+84

; X positions (centered)
lda #HISCORE_X0
sta OAM_BUF+75
clc
adc #$08
sta OAM_BUF+79
lda #HISCORE_X0
clc
adc #$10
sta OAM_BUF+83
lda #HISCORE_X0
clc
adc #$18
sta OAM_BUF+87

; thousands
lda high_bcd1
lsr
lsr
lsr
lsr
and #$0F
clc
adc #$01
sta OAM_BUF+73

; hundreds
lda high_bcd1
and #$0F
clc
adc #$01
sta OAM_BUF+77

; tens
lda high_bcd0
lsr
lsr
lsr
lsr
and #$0F
clc
adc #$01
sta OAM_BUF+81

; ones
lda high_bcd0
and #$0F
clc
adc #$01
sta OAM_BUF+85


; ---- lives HUD update (16x16 hearts) ----
; lives = 3 - misses
lda #$03
sec
sbc misses          ; A = lives (0..3)
sta tmp             ; tmp = lives

; Heart 0 visible if lives >= 1
lda tmp
cmp #$01
bcc @hide_heart0
  lda #HEART_Y_TOP
  sta OAM_BUF+24    ; TL Y
  sta OAM_BUF+28    ; TR Y
  lda #HEART_Y_BOT
  sta OAM_BUF+32    ; BL Y
  sta OAM_BUF+36    ; BR Y
  jmp @heart1
@hide_heart0:
  lda #$FE
  sta OAM_BUF+24
  sta OAM_BUF+28
  sta OAM_BUF+32
  sta OAM_BUF+36

@heart1:
; Heart 1 visible if lives >= 2
lda tmp
cmp #$02
bcc @hide_heart1
  lda #HEART_Y_TOP
  sta OAM_BUF+40    ; TL Y
  sta OAM_BUF+44    ; TR Y
  lda #HEART_Y_BOT
  sta OAM_BUF+48    ; BL Y
  sta OAM_BUF+52    ; BR Y
  jmp @heart2
@hide_heart1:
  lda #$FE
  sta OAM_BUF+40
  sta OAM_BUF+44
  sta OAM_BUF+48
  sta OAM_BUF+52

@heart2:
; Heart 2 visible if lives >= 3
lda tmp
cmp #$03
bcc @hide_heart2
  lda #HEART_Y_TOP
  sta OAM_BUF+56    ; TL Y
  sta OAM_BUF+60    ; TR Y
  lda #HEART_Y_BOT
  sta OAM_BUF+64    ; BL Y
  sta OAM_BUF+68    ; BR Y
  jmp @lives_done
@hide_heart2:
  lda #$FE
  sta OAM_BUF+56
  sta OAM_BUF+60
  sta OAM_BUF+64
  sta OAM_BUF+68

@lives_done:



; ---- PAUSED text visibility ----
lda paused
beq @pause_text_hide

  lda #PAUSE_Y
  sta OAM_BUF+PAUSE_BASE+0
  sta OAM_BUF+PAUSE_BASE+4
  sta OAM_BUF+PAUSE_BASE+8
  sta OAM_BUF+PAUSE_BASE+12
  sta OAM_BUF+PAUSE_BASE+16
  jmp @pause_text_done

@pause_text_hide:
  lda #$FE
  sta OAM_BUF+PAUSE_BASE+0
  sta OAM_BUF+PAUSE_BASE+4
  sta OAM_BUF+PAUSE_BASE+8
  sta OAM_BUF+PAUSE_BASE+12
  sta OAM_BUF+PAUSE_BASE+16

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

; ---- High score jingle ----
lda jingle_on
beq @jingle_done

  lda jingle_timer
  beq @jingle_next
  dec jingle_timer
  jmp @jingle_done

@jingle_next:
  ldx jingle_step
  cpx #JingleLen
  bcc @play_note

  ; done
  lda #$00
  sta jingle_on
  sta $4015          ; silence
  jmp @jingle_done

@play_note:
  ; enable pulse 1
  lda #$01
  sta $4015

  lda #%10011111
  sta $4000
  lda #$00
  sta $4001

  lda JinglePitchTable,x
  sta $4002
  lda #%00010000
  sta $4003

    lda JingleNoteFrames,x
  sta jingle_timer

  inc jingle_step

@jingle_done:

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

  ; If jingle is playing, do NOT disable audio globally
  lda jingle_on
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

JinglePitchTable:
  .byte $B0, $90, $70, $60, $50, $40  ; tweak pitches
JingleDurTable:
  .byte 6,   6,   6,   6,   10,  16    ; frames per note
JingleNoteFrames:
  .byte 6, 6, 6, 6, 10, 16   ; frames per note (timing)

JingleLen = 6

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
CHR_START:
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

; Tile $1F: N
.byte $66,$76,$7E,$7E,$6E,$66,$66,$00
.byte $00,$00,$00,$00,$00,$00,$00,$00

; Tile $20: W
.byte $66,$66,$66,$6E,$7E,$7E,$34,$00
.byte $00,$00,$00,$00,$00,$00,$00,$00

; Tile $21: H
.byte $66,$66,$66,$7E,$66,$66,$66,$00
.byte $00,$00,$00,$00,$00,$00,$00,$00

; Tile $22: I
.byte $7E,$18,$18,$18,$18,$18,$7E,$00
.byte $00,$00,$00,$00,$00,$00,$00,$00


.res 8192-560, $00



