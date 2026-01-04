; =========================
; Dodgefall — NES catch/avoid (ca65)
; - NROM-128 (16KB PRG), 8KB CHR-ROM
; - Sprite-only rendering (BG off)
; - Frame-locked main loop via NMI flag
; - 4 falling objects total + 3 misses (lives)
; - Score + flash + powerups + difficulty ramp
; - version 2.3 
; =========================

; ============================================================
; Dodgefall — Version History
; ============================================================
;
; v1.0  — Initial playable prototype
;   - Single falling object
;   - Left/right player movement
;   - Catch vs miss logic
;   - 3 lives (hearts)
;   - Basic scoring
;
; v2.0  — Core gameplay expansion
;   - Multiple falling objects
;   - Good / Bad object types
;   - Powerups (magnet, slow, etc.)
;   - Pause system
;   - High score tracking
;
; v2.1  — HUD & feedback pass
;   - Combo counter
;   - Score multiplier system
;   - Multiplier badge sprites (x2, x3, …)
;   - Flash & palette feedback
;
; v2.2  — Juice & stability
;   - Streak tracking
;   - Improved spawn timing
;   - Difficulty ramp tuning
;   - Bug fixes (freeze, OAM ordering, sprite flicker)
;
; v2.3  — Playtest cleanup & polish (current)
;   - End-of-run stats screen removed
;   - HUD cleanup & simplification
;   - Combo/multiplier stability fixes
;   - General balance & playtest tuning
;
; v2.4  — (planned)
;   - Reserved for next major feature update
;
; ============================================================


PRG_BANKS = 1
CHR_BANKS = 1

OAM_BUF   = $0200

NUM_OBJS = 2


; ============================================================
; OAM layout helpers
; Each sprite = 4 bytes in OAM: Y, TILE, ATTR, X
; ============================================================
OAM_Y = 0
OAM_T = 1
OAM_A = 2
OAM_X = 3

; Sprite bases (OAM offsets)
PLAYER_BASE = 0        ; sprite 0  (0..3)
OBJ1_BASE   = 4        ; sprite 1  (4..7)
OBJ2_BASE   = $A0      ; sprite 50 (already in use)

; Convenience macro (safe: no name collisions)
.macro OAM_HIDE base
  lda #$FE
  sta OAM_BUF+base+OAM_Y
.endmacro

; --- build/version ---
VERSION_MAJOR = 2
VERSION_MINOR = 3

; --- Version on title screen ---
TITLE_VER_X = $58
TITLE_VER_Y = $D8

; --- version glyph tiles (CHR indices) ---
TILE_DOT = $29
TILE_v   = $2A

VERSION_BASE = $48    ; sprites 18–21

; ============================================================
; Gameplay tuning
; ============================================================
PLAYER_Y    = $C8      ; player row
OBJ_START_Y = $00
OBJ_RESET_Y = $F0      ; past bottom => miss

OBJ2_SPAWN_DELAY = $60 ; 1.6s

; --- Difficulty ramp ---
MAX_DIFF         = 4
RAMP_LOCK_FRAMES  = 90   ; ~1.5s @ 60fps (grace after damage)
RAMP_GOOD_TARGET  = 8    ; goods needed per ramp step (your logic)

; 1500 frames @ 60fps ≈ 25 seconds
RAMP_FRAMES_LO = <$05DC
RAMP_FRAMES_HI = >$05DC

; --- Streak / combo ---
STREAK_TARGET = $05      ; goods in a row
SCORE_STREAK  = $50      ; +50 points (packed BCD)

COMBO_STEP = 5           ; every 3 consecutive GOOD catches => mult++
COMBO_MAX  = 4           ; cap at x4

OBJ_SPAWN_MIN_DX = $18   ; 24px spacing (try $18, $20, or $28)

OBJ2_MIN_DX = $20    ; 32px (try $18 for 24px if you want closer)

; ============================================================
; HUD layout
; ============================================================
SCORE_Y    = $08
HISCORE_Y  = $10
MULTI_Y    = $28

HUD_SAFE_Y = $08        ; keep important HUD above this line

HISCORE_X0 = $70         ; centered

; Multiplier badge uses sprites 62..63
MULTI_BASE = $F8         ; sprite 62 * 4
MULTI_X_X  = $28         ; x position for 'x'
MULTI_X_D  = $30         ; x position for digit

PAUSE_Y    = $60
PAUSE_BASE = $C4         ; safe area after GAMEOVER ($A4..$C3)

GAMEOVER_Y    = $78
GAMEOVER_ATTR = $00

NEWHIGH_BASE = $D8       ; sprites 54..61
NEWHIGH_Y    = $68
NEWHIGH_X    = $58

OBJ2_MIN_OBJ1_Y = $30   ; obj1 must be at/ below this Y before obj2 can spawn


; ============================================================
; Object types (MUST be 0..3 for table indexing)
; ============================================================
OBJ_GOOD  = $00
OBJ_BAD   = $01
OBJ_POWER = $02
OBJ_GOLD  = $03

.assert OBJ_GOOD  = 0, error, "Obj tables assume OBJ_GOOD=0"
.assert OBJ_BAD   = 1, error, "Obj tables assume OBJ_BAD=1"
.assert OBJ_POWER = 2, error, "Obj tables assume OBJ_POWER=2"
.assert OBJ_GOLD  = 3, error, "Obj tables assume OBJ_GOLD=3"

; ============================================================
; Scoring (packed BCD)
; ============================================================
SCORE_GOOD   = $10   ; +10
SCORE_POWER  = $25   ; +25
SCORE_GOLD   = $50   ; +50
SCORE_BAD    = $10   ; -10

; ============================================================
; CHR tile IDs
; ============================================================
TILE_SOLID = $00

TILE_POWER = $23
TILE_GOLD  = $24

TILE_X     = $25      ; small 'x' badge

; “DODGEFALL” title tiles, etc.
TILE_D  = $16
TILE_O  = $17
TILE_G  = $18
TILE_L  = $1A
TILE_R  = $1B
TILE_A  = $12
TILE_V  = $1E
TILE_B  = $26
TILE_x  = $25


; ============================================================
; Visual FX tuning
; ============================================================
TRAIL_BASE      = $D4  ; sprite 53
TRAIL_ATTR      = $02
TRAIL_DY        = $02
TRAIL_MIN_SPEED = $03

; ============================================================
; Tables
; ============================================================
FallSpeedTable:
  .byte 1, 1, 2, 2, 3

FracMaskTable:
  .byte 0, 1, 0, 1, 1

; Object render tables (index = obj_type)
ObjPalTable:
  .byte $01, $03, $02, $02

ObjTileTable:
  .byte TILE_SOLID, TILE_SOLID, TILE_POWER, TILE_GOLD


; =========================
; ZEROPAGE vars
; =========================
.segment "ZEROPAGE"

; -------------------------
; Controller input
; -------------------------
pad1:         .res 1
pad1_prev:    .res 1     ; for edge-detect
new_presses:  .res 1     ; (pad1 ^ pad1_prev) & pad1

; -------------------------
; Global state / timing
; -------------------------
nmi_ready:    .res 1
game_state:   .res 1     ; 0=title, 1=playing (expand later)
paused:       .res 1     ; 0/1

frame_lo:     .res 1
frame_hi:     .res 1
rng:          .res 1

pause_timer:  .res 1
sfx_timer:    .res 1

game_over:    .res 1
misses:       .res 1

; -------------------------
; Player
; -------------------------
player_x:       .res 1
player_x_prev:  .res 1   ; for swept collision
move_spd:       .res 1

flash_timer:    .res 1
flash_pal:      .res 1

; “snap/assist” style mechanics
magnet_active:  .res 1
magnet_timer:   .res 1

power_timer:    .res 1

; -------------------------
; Difficulty / pacing
; -------------------------
diff:          .res 1     ; 0..MAX_DIFF
ramp_lock:     .res 1
streak8:       .res 1
fall_frac:     .res 1

fall_speed:    .res 1
speed_pending: .res 1

zig_dir:       .res 1
zig_tick:      .res 1

; -------------------------
; Scoring / combo / streak
; -------------------------
score_bcd0:   .res 1
score_bcd1:   .res 1

high_bcd0:    .res 1
high_bcd1:    .res 1

combo_count:  .res 1
combo_mult:   .res 1

good_count:   .res 1
streak_chirp: .res 1

new_high:     .res 1
jingle_on:    .res 1
jingle_timer: .res 1
jingle_step:  .res 1

; HUD polish
hud_nudge_timer:    .res 1
hud_nudge_phase:    .res 1
badge_flash_timer:  .res 1


respawn_pending: .res 1

; Catch system
catch_hold:  .res 1
x_swept_ok:  .res 1     ; 0/1: skip absdx check when swept passes


; -------------------------
; UI hearts / pulse
; -------------------------
heart_pulse: .res 1
heart_phase: .res 1

; -------------------------
; Math / scratch temps
; -------------------------
tmp:      .res 1
tmp2:     .res 1
absdx:    .res 1
absdy:    .res 1

magnet_tx: .res 1   ; magnet target X
magnet_ty: .res 1   ; magnet target Y

digit_th: .res 1
digit_h:  .res 1
digit_t:  .res 1
digit_o:  .res 1

; =========================
; BSS (normal RAM) vars
; =========================
.segment "BSS"

; -------------------------
; Falling objects (slot arrays)
; -------------------------
obj_x:       .res NUM_OBJS
obj_y:       .res NUM_OBJS
obj_y_prev:  .res NUM_OBJS
obj_type:    .res NUM_OBJS
obj_alive:   .res NUM_OBJS
obj_speed:   .res NUM_OBJS
obj_cd:      .res NUM_OBJS

; --- slot aliases (temporary bridge) ---
obj2_x      = obj_x+1
obj2_y      = obj_y+1
obj2_y_prev = obj_y_prev+1
obj2_type   = obj_type+1
obj2_alive  = obj_alive+1
obj2_speed  = obj_speed+1
obj2_cd     = obj_cd+1

spawn_cd: .res 1

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

  lda #$10
  sta hud_nudge_timer
  lda #$00
  sta hud_nudge_phase


  jsr StartHighScoreJingle

@done:
  rts

MaybeIncreaseDifficulty:
  lda diff
  cmp #MAX_DIFF
  bcs @done          ; already max

  inc diff
  jsr PlaySpeedupBeep

@done:
  rts


; AddScoreMultA
; A = packed BCD amount (e.g. $10), X = multiplier (1..4)
AddScoreMultA:
  sta tmp          ; amount
@loop:
  lda tmp
  jsr AddScoreA
  dex
  bne @loop
  rts

; A = base points to add
; Uses current combo_mult as multiplier (X)

AddScoreWithMultA:
  ldx combo_mult
  jmp AddScoreMultA

; Convert A (0..99) to tens (tmp) and ones (tmp2)
BinTo2Digits:
  ldx #$00          ; X = tens
@loop10:
  cmp #$0A
  bcc @done10
  sec
  sbc #$0A
  inx
  bne @loop10
@done10:
  stx tmp           ; tens
  sta tmp2          ; ones
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



; Snap player slightly toward target X in A (±2px), clamped to $08..$F0
; IN:  A = target_x
; OUT: player_x nudged
SnapPlayerTowardX:
  sta tmp              ; reuse tmp (safe here)
  lda tmp
  cmp player_x
  beq SPTX_Done

  bcc SPTX_TargetLeft

SPTX_TargetRight:
  lda player_x
  clc
  adc #$02
  cmp #$F0
  bcc :+
    lda #$F0
  :
  sta player_x
  rts

SPTX_TargetLeft:
  lda player_x
  sec
  sbc #$02
  cmp #$08
  bcs :+
    lda #$08
  :
  sta player_x

SPTX_Done:
  rts



; Spawn object at top with new X and new type
; Spawn type odds use rng & $0F (0..15):
;   0      = gold   (1/16)
;   1      = power  (1/16)
;   2..6   = good   (5/16)
;   7..15  = bad    (9/16)
SpawnObject:


  lda #$00
  sta catch_hold

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
  and #$0F          ; 0..15

  cmp #$00
  beq @make_gold    ; 1/16 chance

  cmp #$01
  beq @make_power   ; 1/16 chance

  cmp #$07
  bcc @make_good    ; 2..6 => 5/16 good (tweak)

  ; else bad
  lda #OBJ_BAD
  sta obj_type
  jmp @set_speed

@make_good:
  lda #OBJ_GOOD
  sta obj_type
  jmp @set_speed

@make_power:
  lda #OBJ_POWER
  sta obj_type
  jmp @set_speed

@make_gold:
  lda #OBJ_GOLD
  sta obj_type
  ; falls through

@set_speed:
  lda fall_speed
  ldx obj_type
  cpx #OBJ_GOLD
  bne :+
    clc
    adc #$01        ; gold = base+1
:
  sta obj_speed

jsr SetObj2SpawnCD

  rts





StartNewGame:
  lda #$00
  sta catch_hold

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

  lda #$00
  sta obj2_alive


lda #$00
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
lda #$00
sta diff
sta ramp_lock
sta streak8
sta fall_frac



  lda #$01
  sta fall_speed
  lda #$00
  sta speed_pending

lda #$00
sta magnet_active
sta magnet_timer

  lda #$78
  sta player_x

  jsr SpawnObject

jsr SetObj2SpawnCD


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
sta magnet_timer
sta magnet_active

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

lda #$00
sta diff
sta ramp_lock
sta streak8
sta fall_frac

lda #$00
sta combo_count
lda #$01
sta combo_mult



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
sta OAM_BUF+OBJ1_BASE+0   ; Y
lda #$00
sta OAM_BUF+OBJ1_BASE+1   ; tile
lda #$00
sta OAM_BUF+OBJ1_BASE+2   ; attr
lda obj_x
sta OAM_BUF+OBJ1_BASE+3   ; X

; ---- Falling object trail (previous-frame position) ----
lda tmp
cmp #$03
bcc @trail_hide

lda obj_y_prev
sta OAM_BUF+TRAIL_BASE+0

lda #$00
sta OAM_BUF+TRAIL_BASE+1

lda #TRAIL_ATTR
sta OAM_BUF+TRAIL_BASE+2

lda obj_x
sta OAM_BUF+TRAIL_BASE+3
jmp @trail_done

@trail_hide:
lda #$FE
sta OAM_BUF+TRAIL_BASE+0

@trail_done:



lda #$FE
sta OAM_BUF+MULTI_BASE+0
sta OAM_BUF+MULTI_BASE+4

; hide 2nd falling object sprite on reset
lda #$FE
sta OAM_BUF+OBJ2_BASE+0



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

lda #$FE
sta OAM_BUF+MULTI_BASE+0
sta OAM_BUF+MULTI_BASE+4

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

; =========================
; OBJ2 COOLDOWN TICK (always, even during pause_timer freeze)
; =========================
lda obj2_cd
beq :+
dec obj2_cd
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

; start cooldown so obj2 can spawn later (not same time)
jsr SetObj2SpawnCD


@pause_apply:
jmp Apply

@do_game:

; =========================
; OBJ2 SPAWN (when cd == 0 and obj2 not alive)
; =========================
lda obj2_alive

bne :+
  jmp @after_obj2_spawn
:

lda obj2_cd
beq @cd_done
dec obj2_cd
jmp @after_obj2_spawn
@cd_done:

lda obj_y
cmp #OBJ2_MIN_OBJ1_Y
bcc @after_obj2_spawn


; ---- activate obj2 ----
lda #$01
sta obj2_alive

lda #OBJ_START_Y
sta obj2_y


; IMPORTANT: make sure obj2_type is valid (0..3)
; If you already have logic for picking type, do it here.
; (Example: copy obj_type, or roll RNG, etc.)
; lda obj_type
; sta obj2_type

; --- obj2_x = obj_x +/- $40 (50/50), snapped + clamped ---
jsr NextRNG
lda rng
and #$01
beq @obj2_right

@obj2_left:
  lda obj_x
  sec
  sbc #$40
  jmp @obj2_pos

@obj2_right:
  lda obj_x
  clc
  adc #$40

@obj2_pos:
  and #$F8          ; snap to 8px grid

  ; clamp to safe range
  cmp #$08
  bcs :+
    lda #$08
:
  cmp #$F0
  bcc :+
    lda #$F0
:
  
  sta obj2_x

   ; --- enforce minimum horizontal separation from obj1 ---
  lda obj2_x
  sec
  sbc obj_x
  bcs @obj2dx_pos
    eor #$FF
    clc
    adc #$01
@obj2dx_pos:
  cmp #OBJ2_MIN_DX
  bcs @after_obj2_spawn    ; far enough => keep obj2_x

  ; too close: flip side and recompute once
  jsr NextRNG
  lda rng
  and #$01
  beq @force_right

@force_left:
  lda obj_x
  sec
  sbc #$40
  jmp @force_pos

@force_right:
  lda obj_x
  clc
  adc #$40

@force_pos:
  and #$F8

  ; clamp
  cmp #$08
  bcs :+
    lda #$08
:
  cmp #$F0
  bcc :+
    lda #$F0
:
  sta obj2_x


@after_obj2_spawn:



; ---- GOLD TIMER TICK (single source of truth) ----
lda magnet_active
beq @gold_tick_done

lda magnet_timer
beq @gold_off
dec magnet_timer
bne @gold_tick_done

@gold_off:
  lda #$00
  sta magnet_active
  sta magnet_timer     ; optional, but keeps it clean

@gold_tick_done:

; =============================
; TIMERS: one tick per frame
; =============================

; HUD nudge timer (toggles phase while active)
lda hud_nudge_timer
beq :+
  dec hud_nudge_timer
  lda hud_nudge_phase
  eor #$01
  sta hud_nudge_phase
:

; ramp grace countdown
lda ramp_lock
beq :+
  dec ramp_lock
:

; badge flash timer countdown
lda badge_flash_timer
beq :+
  dec badge_flash_timer
:



lda #$03
sta move_spd          ; normal speed = 3

lda magnet_active
beq :+
  lda #$04
  sta move_spd        ; magnet speed = 4
:


 inc frame_lo
  bne :+
  inc frame_hi
:

lda player_x
sta player_x_prev


; ---- Player movement (with post-clamp) ----
lda pad1
and #%00000010         ; Left
beq @checkRight_move
  lda player_x
  sec
  sbc move_spd
  cmp #$08
  bcs :+
    lda #$08
  :
  sta player_x

@checkRight_move:
lda pad1
and #%00000001         ; Right
beq @afterMove_move
  lda player_x
  clc
  adc move_spd
  cmp #$F0
  bcc :+
    lda #$F0
  :
  sta player_x

@afterMove_move:




; ---- GOLD MAGNET ASSIST (OBJ1 or OBJ2) ----
lda magnet_active
beq @magnet_done

; -------------------------------------------------
; Choose magnet target: prefer any GOLD object alive
; -------------------------------------------------
; default: no target
lda #$00
sta tmp              ; tmp = 0 => no target yet

; if obj1 is GOLD and alive, use it
lda obj_alive
beq @try_obj2
lda obj_type
cmp #OBJ_GOLD
bne @try_obj2
  lda obj_x
  sta magnet_tx
  lda obj_y
  sta magnet_ty
  lda #$01
  sta tmp
  jmp @have_target

@try_obj2:
lda obj2_alive
beq @have_target
lda obj2_type
cmp #OBJ_GOLD
bne @have_target
  lda obj2_x
  sta magnet_tx
  lda obj2_y
  sta magnet_ty
  lda #$01
  sta tmp

@have_target:
lda tmp
beq @magnet_done     ; no gold target => no magnet assist

; -------------------------------------------------
; Engage window (same behavior as before)
; -------------------------------------------------
lda magnet_ty
cmp #$80
bcc @magnet_done
cmp #$E0
bcs @magnet_done

; abs(dx) between player and target
lda player_x
sec
sbc magnet_tx
bcs @dx_pos
eor #$FF
clc
adc #$01
@dx_pos:
cmp #$02
bcc @magnet_done

; pull 2px toward target
lda player_x
cmp magnet_tx
beq @magnet_done
bcc @mag_right
@mag_left:
  dec player_x
  dec player_x
  jmp @magnet_done
@mag_right:
  inc player_x
  inc player_x

@magnet_done:
; ---- END MAGNET ----




@afterMove:
; ---- choose effective fall speed (tmp = effective speed) ----
  lda power_timer
  beq @use_normal_speed

  dec power_timer
  lda #$01
  sta tmp              ; slowed => speed 1
  jmp @have_speed

@use_normal_speed:
  ; tmp = base speed for this difficulty
  ldx diff
  lda FallSpeedTable,x
  sta tmp

  ; optional fractional +1 every other frame for some diffs
  lda FracMaskTable,x
  beq @have_speed

  inc fall_frac
  lda fall_frac
  and #$01
  beq @have_speed

  inc tmp


@have_speed:

; ---- gold falls slightly faster (every other frame) ----
  lda obj_type
  cmp #OBJ_GOLD
  bne :+
    lda frame_lo
    and #$01
    beq :+          ; only on odd frames
    inc tmp
:


; =========================
; UPDATE FALLING OBJECTS (all slots)
; tmp = fall step this frame
; =========================
  ldx #$00
@obj_loop:

  ; if not alive, skip move/bottom-out
  lda obj_alive,x
  beq @next_obj

  ; y_prev = y
  lda obj_y,x
  sta obj_y_prev,x

  ; y += tmp
  clc
  adc tmp
  sta obj_y,x

  ; bottom-out?
  lda obj_y,x
  cmp #OBJ_RESET_Y
  bcc @next_obj

  ; fell past bottom -> if GOOD, penalty
  lda obj_type,x
  cmp #OBJ_GOOD
  bne @kill_obj

  ; ---- Missed GOOD => penalty ----
  lda #$01
  sta combo_mult
  lda #$00
  sta combo_count

  inc misses
  lda #$00
  sta good_count

  lda #SCORE_BAD
  jsr SubScoreA

  lda #$08
  sta flash_timer
  jsr PlayMissBeep

  lda #$03
  sta pause_timer
  lda #$03
  sta flash_pal

  lda misses
  cmp #$03
  bcc @kill_obj

  ; --- GAME OVER ---
  lda game_over
  bne @kill_obj
  jsr UpdateHighScore
  lda #$01
  sta game_over

@kill_obj:
  lda #$00
  sta obj_alive,x

  ; set cooldown for this slot (if you want per-slot pacing)
  ; lda #OBJ_SPAWN_DELAY
  ; sta obj_cd_a,x

@next_obj:
  inx
  cpx #NUM_OBJS
  bcc @obj_loop





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

; ---- CheckCatch2 every frame (so obj2 can be caught) ----
lda obj2_alive
beq :+
  jsr CheckCatch2
:

; ---- Miss check (past bottom) ----
  lda obj_y
  cmp #OBJ_RESET_Y
  bcc CheckCatch





; If bad OR powerup: miss is OK (no penalty)
lda obj_type
cmp #$00
bne RespawnOnly

lda obj_type
cmp #OBJ_BAD



; Missed GOOD => penalty
  lda #$01
sta combo_mult
lda #$00
sta combo_count


inc misses
lda #$00
sta good_count

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

jsr UpdateHighScore

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
  ; If obj2 is near the top, wait a moment before respawning obj1
  lda obj2_alive
  beq :+
  lda obj2_y
  cmp #$10
  bcs :+
    lda #$08          ; 8 frames wait (tune 4..12)
    sta pause_timer   ; reuse existing freeze timer
    jmp Apply         ; skip spawning this frame
:

jsr SpawnObject
jmp Apply

; ============================================================
; CheckCatch (OBJ1) — clean swept-X + hold-window catch
; Expects: called via `bcc CheckCatch` (tail-called)
; Ends by jumping to Apply (no catch) or jumping to Caught* handlers (catch).
; Uses: tmp, tmp2, absdx, absdy, catch_hold
; ============================================================

CATCH_X      = $08     ; horizontal half-width
CATCH_EXTRA  = $04     ; extra padding for hold window to prevent tunneling

CheckCatch:
  ; --------------------------
  ; 1) Swept X overlap gate
  ; --------------------------
  ; tmp  = min(player_x_prev, player_x)
  ; tmp2 = max(player_x_prev, player_x)
  lda player_x_prev
  cmp player_x
  bcc CC1_PrevIsMin
    lda player_x
    sta tmp
    lda player_x_prev
    sta tmp2
    jmp CC1_HaveMinMax
CC1_PrevIsMin:
    lda player_x_prev
    sta tmp
    lda player_x
    sta tmp2
CC1_HaveMinMax:

  ; lower = minX - CATCH_X
  lda tmp
  sec
  sbc #CATCH_X
  sta tmp

  ; upper = maxX + CATCH_X
  lda tmp2
  clc
  adc #CATCH_X
  sta tmp2

  ; if obj_x < lower => hard no-catch (clear hold)
  lda obj_x
  cmp tmp
  bcc CC1_ClearHoldAndApply

  ; if obj_x > upper => hard no-catch (clear hold)
  lda obj_x
  cmp tmp2
  bcs CC1_ClearHoldAndApply

  ; --------------------------
  ; 2) Thresholds (tmp = tight, tmp2 = hold)
  ; --------------------------
  ; tmp = tight threshold (8 normally, 10 for power)
  lda obj_type
  cmp #OBJ_POWER
  bne CC1_ThrNormal
    lda #$0A
    sta tmp
    jmp CC1_ThrDone
CC1_ThrNormal:
  lda #$08
  sta tmp
CC1_ThrDone:

  ; tmp2 = hold threshold = tmp + 2 + extra
  lda tmp
  clc
  adc #$02
  clc
  adc #CATCH_EXTRA
  sta tmp2

  ; --------------------------
  ; 3) Decay hold
  ; --------------------------
  lda catch_hold
  beq CC1_NoHoldDecay
  dec catch_hold
CC1_NoHoldDecay:

  ; --------------------------
  ; 4) Vertical window using tmp2
 ; absdy = |obj_y - PLAYER_Y|
  lda obj_y
  cmp #PLAYER_Y
  bcs CC1_DY_Pos
    lda #PLAYER_Y
    sec
    sbc obj_y
    jmp CC1_DY_Done
CC1_DY_Pos:
    lda obj_y
    sec
    sbc #PLAYER_Y
CC1_DY_Done:
  sta absdy


  ; if absdy >= tmp2 => too far vertically; clear hold and apply
  lda absdy
  cmp tmp2
  bcs CC1_ClearHoldAndApply

  ; --------------------------
  ; 5) Horizontal window using tmp2 (current frame abs dx)
  ; absdx = |obj_x - player_x|
  ; --------------------------
  lda obj_x
  sec
  sbc player_x
  bcs CC1_DxPos
    eor #$FF
    clc
    adc #$01
CC1_DxPos:
  sta absdx

  ; if absdx >= tmp2 => too far horizontally; clear hold and apply
  lda absdx
  cmp tmp2
  bcs CC1_ClearHoldAndApply

  ; We're inside the "near" window: arm hold for 2 frames
  lda #$02
  sta catch_hold

  ; --------------------------
  ; 6) Tight catch (tmp)
  ; --------------------------
  lda absdy
  cmp tmp
  bcs CC1_MaybeHold

  lda absdx
  cmp tmp
  bcs CC1_MaybeHold

  ; tight pass => caught
  jmp CC1_CaughtDispatch

CC1_MaybeHold:
  ; If hold is still armed, allow catch
  lda catch_hold
  beq CC1_Apply
  jmp CC1_CaughtDispatch

CC1_ClearHoldAndApply:
  lda #$00
  sta catch_hold

CC1_Apply:
  jmp Apply

CC1_CaughtDispatch:
  lda #$00
  sta catch_hold

  lda obj_type
  beq CC1_JmpGood

  cmp #OBJ_BAD
  beq CC1_JmpBad

  cmp #OBJ_POWER
  beq CC1_JmpPower

  jmp CaughtGold            ; default (gold)

CC1_JmpGood:
  jmp CaughtGood

CC1_JmpBad:
  jmp CaughtBad

CC1_JmpPower:
  jmp CaughtPower


; ============================================================
; CheckCatch2 (OBJ2) — clean swept-X + tight catch (no hold)
; Called via `jsr CheckCatch2` (must RTS).
; On catch, jumps to Caught (obj2-only dispatch).
; ============================================================

CheckCatch2:
  ; If obj2 not alive, nothing to do
  lda obj2_alive
  bne CC2_Alive
  rts
CC2_Alive:

  ; Optional sanity: don't catch during freeze frames
  lda pause_timer
  beq CC2_NotPaused
  rts
CC2_NotPaused:

  ; --------------------------
  ; 1 Swept X overlap gate (player)
  ; tmp  = min(player_x_prev, player_x)
  ; tmp2 = max(player_x_prev, player_x)
  lda player_x_prev
  cmp player_x
  bcc CC2_PrevIsMin
    lda player_x
    sta tmp
    lda player_x_prev
    sta tmp2
    jmp CC2_HaveMinMax
CC2_PrevIsMin:
    lda player_x_prev
    sta tmp
    lda player_x
    sta tmp2
CC2_HaveMinMax:

  ; lower = minX - CATCH_X
  lda tmp
  sec
  sbc #CATCH_X
  sta tmp

  ; upper = maxX + CATCH_X
  lda tmp2
  clc
  adc #CATCH_X
  sta tmp2

  ; if obj2_x < lower => no catch
  lda obj2_x
  cmp tmp
  bcc CC2_NoCatch

  ; if obj2_x > upper => no catch
  lda obj2_x
  cmp tmp2
  bcs CC2_NoCatch

  ; --------------------------
  ; 2) Tight threshold (tmp)
  ; --------------------------
  lda obj2_type
  cmp #OBJ_POWER
  bne CC2_ThrNormal
    lda #$0A
    sta tmp
    jmp CC2_ThrDone
CC2_ThrNormal:
  lda #$08
  sta tmp
CC2_ThrDone:

; absdy = |obj2_y - PLAYER_Y|
  lda obj2_y
  cmp #PLAYER_Y
  bcs CC2_DY_Pos
    lda #PLAYER_Y
    sec
    sbc obj2_y
    jmp CC2_DY_Done
CC2_DY_Pos:
    lda obj2_y
    sec
    sbc #PLAYER_Y
CC2_DY_Done:
  sta absdy


  ; if dy >= tmp => fail
  lda absdy
  cmp tmp
  bcs CC2_NoCatch

  ; absdx = |obj2_x - player_x|
  lda obj2_x
  sec
  sbc player_x
  bcs CC2_DxPos
    eor #$FF
    clc
    adc #$01
CC2_DxPos:
  sta absdx

  ; if absdx >= tmp => fail
  lda absdx
  cmp tmp
  bcs CC2_NoCatch

  ; caught
  jmp Caught

CC2_NoCatch:
  rts


; ============================================================
; Caught (OBJ2) — obj2-only dispatch + kill obj2 + RTS
; IMPORTANT: does NOT call obj1 handlers (they use obj_x/obj_type).
; ============================================================
Caught:
  lda obj2_x
  jsr SnapPlayerTowardX

  lda obj2_type
  beq C2_JmpGood

  cmp #OBJ_BAD
  beq C2_JmpBad

  cmp #OBJ_POWER
  beq C2_JmpPower

  jmp Caught2_Gold          ; default

C2_JmpGood:
  jmp Caught2_Good

C2_JmpBad:
  jmp Caught2_Bad

C2_JmpPower:
  jmp Caught2_Power

Caught2_Good:

  ; score
  lda #SCORE_GOOD
  jsr AddScoreWithMultA

    ; ---- combo / streak tracking ----
  lda #$00
  sta tmp

  inc combo_count

  lda combo_count
  cmp #STREAK_TARGET
  bne :+
    lda #$01
    sta tmp
:

  ; Multiplier step
  lda combo_count
  cmp #COMBO_STEP
  bne @after_obj2_mult

    lda #$00
    sta combo_count

    lda combo_mult
    cmp #COMBO_MAX
    bcs @after_obj2_mult

    inc combo_mult
    lda #$01
    sta tmp

    lda combo_mult
    cmp #COMBO_MAX
    bne :+
      lda #$40
      sta badge_flash_timer
:

@after_obj2_mult:

  lda tmp
  bne Caught2_ComboFeedbackOnly
  jmp Caught2_GoodFx


  jmp Caught2_GoodFx

Caught2_ComboFeedbackOnly:
  jsr PlayStreakBeep
  lda #$08
  sta flash_timer
  lda #$02
  sta flash_pal        ; blue flash (match obj1)
  lda #$02
  sta pause_timer
  jmp Caught2_Kill

Caught2_GoodFx:
  jsr PlayCatchBeep
  lda #$08
  sta flash_timer
  lda #$01
  sta flash_pal
  lda #$02
  sta pause_timer
  jmp Caught2_Kill




Caught2_Bad:

  ; reset combo on bad
  lda #$01
  sta combo_mult
  lda #$00
  sta combo_count

  lda #SCORE_BAD
  jsr SubScoreA
  inc misses

  jsr PlayMissBeep
  lda #$08
  sta flash_timer
  lda #$03
  sta flash_pal
  lda #$01
  sta pause_timer

  ; game over check (same pattern as your obj1 bad)
  lda misses
  cmp #$03
  bcc Caught2_Kill

  lda game_over
  bne Caught2_Kill
  jsr UpdateHighScore
  lda #$01
  sta game_over
  lda #$00
sta obj2_alive

  jmp Caught2_Kill


Caught2_Power:

  lda #SCORE_POWER
  jsr AddScoreWithMultA
  lda #180
  sta power_timer
  jsr PlayPowerupBeep
  lda #$06
  sta flash_timer
  lda #$02
  sta flash_pal
  lda #$03
  sta pause_timer
  jmp Caught2_Kill


Caught2_Gold:

  lda #SCORE_GOLD
  jsr AddScoreWithMultA
  lda #$01
  sta magnet_active
  lda #$80
  sta magnet_timer
  jsr PlayPowerupBeep
  lda #$08
  sta flash_timer
  lda #$02
  sta flash_pal
  lda #$03
  sta pause_timer
  ; fallthrough

Caught2_Kill:
  lda #$00
  sta obj2_alive
  jsr SetObj2SpawnCD
  rts



@done:
  rts
  
CC1_Continue:

  ; ---- dy = obj_y - PLAYER_Y ----
  lda obj_y
  sec
  sbc #PLAYER_Y
  sta absdy

  ; If dy >= tmp2 -> clear hold and apply
  lda absdy
  cmp tmp2
  bcc :+
    jmp CC_ClearAndApply
:

  ; ---- abs(dx) ----
lda obj_x
sec
sbc player_x
bcs @dx_ok
  eor #$FF
  clc
  adc #$01
@dx_ok:
sta absdx


  ; expand hold window to prevent tunneling at high horizontal speed
  lda tmp2
  clc
  adc #$04          ; try #$04 first; if still glitches, use #$05 or #$06
  sta tmp2          ; (only safe if tmp2 is reloaded each frame before this block)

  lda absdx
  cmp tmp2
  bcc :+
    jmp CC_ClearAndApply
:


  ; near enough: arm hold for 2 frames
  lda #$02
  sta catch_hold

; tight catch if both inside tmp
lda absdy
cmp tmp
bcc @dy_in
  jmp CC_MaybeHold
@dy_in:

lda absdx
cmp tmp
bcc @dx_in
  jmp CC_MaybeHold
@dx_in:

jmp CC_CaughtDispatch


CC_MaybeHold:
  lda catch_hold
  beq CC_Apply
  jmp CC_CaughtDispatch

CC_ClearAndApply:
  lda #$00
  sta catch_hold

CC_Apply:
  jmp Apply

CC_CaughtDispatch:
  lda #$00
  sta catch_hold

  lda obj_type
  bne :+
    jmp CaughtGood
:
  cmp #$01
  bne :+
    jmp CaughtBad
:
  cmp #$02
  bne :+
    jmp CaughtPower
:
  cmp #$03
  bne :+
    jmp CaughtGold
:
  jmp Apply



@go_good:
  jmp CaughtGood

@go_bad:
  jmp CaughtBad

@go_power:
  jmp CaughtPower       ; or jmp CC_DoPower if you want to keep wrappers

@go_gold:
  jmp CaughtGold



CC_DoPower:
  jmp CaughtPower

CC_DoGold:
  jmp CaughtGold


CaughtGold:
  ; --- GOLD ACTIVATE ---
  lda #$01
  sta magnet_active

  lda #$A0          ; duration (tune this: $60, $80, $A0, $FF)
  sta magnet_timer

  lda obj_x
  jsr SnapPlayerTowardX

  lda #SCORE_GOLD
  jsr AddScoreWithMultA

  lda #$08
  sta hud_nudge_timer
  lda #$00
  sta hud_nudge_phase

  jsr PlayPowerupBeep     ; or PlayGoldBeep later

  jmp RespawnOnCatch




CaughtGood:
lda obj_x
jsr SnapPlayerTowardX


  ; apply GOOD score with multiplier
 lda #SCORE_GOOD
jsr AddScoreWithMultA

    ; ---- combo tracking ----
  lda #$00
  sta tmp              ; tmp = 0 (no special feedback yet)

  inc combo_count

  ; streak reached? (set flag but DO NOT jump away)
  lda combo_count
  cmp #STREAK_TARGET
  bne :+
    lda #$01
    sta tmp            ; tmp = 1 => use combo feedback
:

  ; multiplier step
    lda combo_count
  cmp #COMBO_STEP
  bne AfterMultStep1

    lda #$00
    sta combo_count

    lda combo_mult
    cmp #COMBO_MAX
    bcs AfterMultStep1

    inc combo_mult
    lda #$01
    sta tmp

    ; tier-up juice (only on mult increase)
    lda #$06
    sta hud_nudge_timer
    lda #$00
    sta hud_nudge_phase

    lda combo_mult
    cmp #COMBO_MAX
    bne :+
      lda #$40
      sta badge_flash_timer
:

AfterMultStep1:
  lda tmp
  bne @combo_feedback_only
  jmp @normal_good





@combo_feedback_only:
  ; combo-up feedback (ONLY)
  jsr PlayStreakBeep
  lda #$08
  sta flash_timer
  lda #$02
  sta flash_pal        ; blue flash
  lda #$02
  sta pause_timer
  jmp RespawnOnCatch

@normal_good:


  ; normal catch feedback
  jsr PlayCatchBeep
  lda #$08
  sta flash_timer
  lda #$01
  sta flash_pal
  lda #$02
  sta pause_timer
  jmp RespawnOnCatch



CaughtBad:
 lda #$01
sta combo_mult



lda obj_x
jsr SnapPlayerTowardX



  lda #SCORE_BAD     ; −10 points
  jsr SubScoreA

  inc misses

  lda #$08
  sta flash_timer
  jsr PlayMissBeep

  lda #$01
  sta pause_timer
  lda #$03
  sta flash_pal

lda misses
cmp #$03
bcc DoRespawnAfterBadCatch

; --- GAME OVER (caught bad) ---
lda game_over
bne @already_over_bad

jsr UpdateHighScore

lda #$01
sta game_over


@already_over_bad:
jmp Apply




DoRespawnAfterBadCatch:
  jsr SpawnObject
  jmp Apply

CaughtPower:


lda #SCORE_POWER
jsr AddScoreWithMultA



  lda #180
  sta power_timer       ; refresh duration every time

lda obj_x
jsr SnapPlayerTowardX

  lda misses
  beq :+
  dec misses
:
  lda #$06
  sta flash_timer
  lda #$02
  sta flash_pal
  lda #$03
  sta pause_timer

  jsr PlayPowerupBeep
  jmp RespawnOnCatch


Apply:
 
ApplyTimerCheck:
  ; ---- request ramp every RAMP_FRAMES ----
  lda frame_hi
  cmp #RAMP_FRAMES_HI
  bcc ApplyAfterRampCheck     ; hi < target_hi -> not yet
  bne ApplyDoRamp             ; hi > target_hi -> definitely time

  ; hi == target_hi, check low byte
  lda frame_lo
  cmp #RAMP_FRAMES_LO
  bcc ApplyAfterRampCheck     ; lo < target_lo -> not yet

ApplyDoRamp:
  ; reset timer
  lda #$00
  sta frame_lo
  sta frame_hi

  ; if grace lock active, skip ramp
  lda ramp_lock
  bne ApplyAfterRampCheck

  jsr MaybeIncreaseDifficulty

ApplyAfterRampCheck:
  lda game_state
  beq @title
  jmp PlayingApply
@title:
  jmp TitleApply



TitleApply:
  lda game_over
  beq :+
  jmp @skip_title
:

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

lda game_over
bne @skip_version
  ; -------------------------
  ; VERSION TEXT on TITLE: v2.3
  ; Uses sprites starting at VERSION_BASE 
  ; -------------------------

  ; Y position
  lda #TITLE_VER_Y
  sta OAM_BUF+VERSION_BASE+0
  sta OAM_BUF+VERSION_BASE+4
  sta OAM_BUF+VERSION_BASE+8
  sta OAM_BUF+VERSION_BASE+12

  ; Attributes (palette 0)
  lda #$00
  sta OAM_BUF+VERSION_BASE+2
  sta OAM_BUF+VERSION_BASE+6
  sta OAM_BUF+VERSION_BASE+10
  sta OAM_BUF+VERSION_BASE+14

  ; X positions (v 2 . 3)
  lda #TITLE_VER_X
  sta OAM_BUF+VERSION_BASE+3
  clc
  adc #$08
  sta OAM_BUF+VERSION_BASE+7
  clc
  adc #$08
  sta OAM_BUF+VERSION_BASE+11
  clc
  adc #$08
  sta OAM_BUF+VERSION_BASE+15

  ; Tiles
  lda #TILE_v
  sta OAM_BUF+VERSION_BASE+1

  lda #VERSION_MAJOR
  clc
  adc #$01              ; digit tiles start at 1
  sta OAM_BUF+VERSION_BASE+5

  lda #TILE_DOT
  sta OAM_BUF+VERSION_BASE+9

  lda #VERSION_MINOR
  clc
  adc #$01
  sta OAM_BUF+VERSION_BASE+13

@skip_version:

@skip_title:
  jmp Forever

jmp Forever


PlayingApply:

  ; hide version sprites during gameplay / game over
  lda #$FE
  sta OAM_BUF+VERSION_BASE+0
  sta OAM_BUF+VERSION_BASE+4
  sta OAM_BUF+VERSION_BASE+8
  sta OAM_BUF+VERSION_BASE+12

  
  ; Hide ALL sprites first
ldx #$00
lda #$FE
@hide_all_play:
  sta OAM_BUF,x
  inx
  inx
  inx
  inx
  bne @hide_all_play

lda game_over
beq :+

  ; ---- hide version sprites during GAME OVER ----
  lda #$FE
  sta OAM_BUF+VERSION_BASE+0
  sta OAM_BUF+VERSION_BASE+4
  sta OAM_BUF+VERSION_BASE+8
  sta OAM_BUF+VERSION_BASE+12

  ; hide falling object during game over
  lda #$FE
  sta OAM_BUF+4              ; sprite 1 Y (object)

  ; hide trail during game over (if you use one)
  sta OAM_BUF+TRAIL_BASE+0   ; trail sprite Y (adjust if your trail uses different base)
:






; ---- GAME OVER text visibility ----
lda game_over
bne :+          ; game_over != 0? continue into GAME OVER draw
  jmp @go_hide  ; game_over == 0? go hide (far jump)
:


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

lda jingle_on
beq @nh_show_solid

  lda frame_lo
  and #$10
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


; --- player sprite visibility ---
lda game_over
beq PlayerShow

; game over: hide player sprite
lda #$FE
sta OAM_BUF+0          ; player Y offscreen
jmp PlayerDone

PlayerShow:
  lda #PLAYER_Y
  sta OAM_BUF+0
  lda #$00
  sta OAM_BUF+1        ; solid tile (or whatever your normal tile is)

PlayerDone:


; --- SCORE Y (fixed) ---
lda #SCORE_Y
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

; =========================
; MULTIPLIER BADGE (x2/x3/x4)
; =========================
lda combo_mult
cmp #$02
bcc @hide_mult_play

@show_mult_play:
  lda #MULTI_Y
  sta OAM_BUF+MULTI_BASE+0
  sta OAM_BUF+MULTI_BASE+4

; ---- multiplier badge palette ----
lda combo_mult
cmp #COMBO_MAX
bne @not_max

  ; at max: flash forever
  lda frame_lo
  and #$08
  beq @pal1
  lda #$02            ; flash palette
  jmp @set_pal
@pal1:
  lda #$01            ; normal bright palette
  jmp @set_pal

@not_max:
  lda #$01            ; normal bright palette

@set_pal:
sta OAM_BUF+MULTI_BASE+2
sta OAM_BUF+MULTI_BASE+6



  lda #MULTI_X_X
  sta OAM_BUF+MULTI_BASE+3
  lda #MULTI_X_D
  sta OAM_BUF+MULTI_BASE+7

  lda #TILE_X
  sta OAM_BUF+MULTI_BASE+1

  lda combo_mult
  clc
  adc #$01              ; digit tile
  sta OAM_BUF+MULTI_BASE+5

  jmp @mult_done_play

@hide_mult_play:
  lda #$FE
  sta OAM_BUF+MULTI_BASE+0
  sta OAM_BUF+MULTI_BASE+4

@mult_done_play:



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

; paused: blink palette (no gold logic here)
lda frame_lo
lsr
lsr
lsr
lsr
lsr
and #$01
sta OAM_BUF+2
jmp AttrDone



@not_paused:

  ; gold sparkle while magnet active (overrides flash)
  lda magnet_active
  beq @do_flash

  lda frame_lo
  and #$08
  beq @gold_a
  lda #$02              ; alt gold palette
  bne @attr_set
@gold_a:
  lda #$01              ; primary gold palette
  bne @attr_set

@do_flash:
  ; Normal flash effect on player attributes
  lda flash_timer
  beq @flash_off
  dec flash_timer
  lda flash_pal
  bne @attr_set

@flash_off:
  lda #$00              ; normal palette

@attr_set:
  sta OAM_BUF+2

  ; Player tile: gold while magnet active
  lda magnet_active
  beq @tile_normal
  lda #TILE_GOLD
  bne @tile_set

@tile_normal:
  lda #TILE_SOLID
@tile_set:
  sta OAM_BUF+1

AttrDone:

; Player X
lda player_x
sta OAM_BUF+3

; Object sprite: hide on game over, otherwise show
lda game_over
beq @obj_visible
lda #$FE
sta OAM_BUF+4
jmp done_obj_play

@obj_visible:
  ldx obj_type

  ; tile
  lda ObjTileTable,x
  sta OAM_BUF+5

  ; palette/attr
  lda ObjPalTable,x
  sta OAM_BUF+6

@obj_common:
  lda obj_y
  cmp #HUD_SAFE_Y
  bcc @hide_obj_in_hud      ; if obj_y < HUD_SAFE_Y, hide it
  sta OAM_BUF+4             ; else show it
  jmp @set_obj_x

@hide_obj_in_hud:
  lda #$FE
  sta OAM_BUF+4

@set_obj_x:
  lda obj_x
  sta OAM_BUF+7

done_obj_play:


; ==============================
; OBJECT 2 RENDER
; ==============================

lda game_over
bne @obj2_hide

lda obj2_alive
beq @obj2_hide

; Y
lda obj2_y
sta OAM_BUF+OBJ2_BASE+OAM_Y

; X
lda obj2_x
sta OAM_BUF+OBJ2_BASE+OAM_X

; tile + palette from type
ldx obj2_type
lda ObjTileTable,x
sta OAM_BUF+OBJ2_BASE+OAM_T
lda ObjPalTable,x
sta OAM_BUF+OBJ2_BASE+OAM_A

jmp @obj2_done

@obj2_hide:
  lda #$FE
  sta OAM_BUF+OBJ2_BASE+OAM_Y

@obj2_done:

  ; DEBUG (end): force sprite #1 visible
  lda #$40
  sta OAM_BUF+OBJ1_BASE+OAM_Y
  lda #TILE_SOLID
  sta OAM_BUF+OBJ1_BASE+OAM_T
  lda #$01
  sta OAM_BUF+OBJ1_BASE+OAM_A
  lda #$80
  sta OAM_BUF+OBJ1_BASE+OAM_X

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

; ---- streak chirp second note ----
lda streak_chirp
beq @no_streak_chirp

  lda sfx_timer
  cmp #$03          ; halfway through
  bne @no_streak_chirp

  lda #$20          ; second, even higher note
  sta $4002
  lda #$00
  sta streak_chirp

@no_streak_chirp:


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

; ---- global frame counter (keeps UI blinking during GAME OVER) ----
  inc frame_lo
  bne :+
    inc frame_hi
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

  ; obj2_cd = OBJ2_SPAWN_DELAY + random(0..31)
SetObj2SpawnCD:
  jsr NextRNG
  lda rng
  and #$1F              ; 0..31
  clc
  adc #OBJ2_SPAWN_DELAY
  sta obj2_cd
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

PlayStreakBeep:
  lda #$01
  sta $4015

  lda #%10011111
  sta $4000
  lda #$00
  sta $4001

  lda #$28        ; first (higher) note
  sta $4002
  lda #%00010000
  sta $4003

  lda #$06
  sta sfx_timer

  lda #$01
  sta streak_chirp
  rts




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
.byte $0F,$12,$28,$12   ; pal2: entry1=blue, entry2=yellow/gold
.byte $0F,$16,$16,$16   ; pal3 red (brighter, cleaner)


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

; Tile $23: solid block, color index 1 (plane0=FF, plane1=00)
.byte $FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF
.byte $00,$00,$00,$00,$00,$00,$00,$00

; Tile $24: solid block, color index 2 (plane0=00, plane1=FF)
.byte $00,$00,$00,$00,$00,$00,$00,$00
.byte $FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF

; Tile $25: x (small)
.byte $00,$66,$3C,$18,$3C,$66,$00,$00
.byte $00,$00,$00,$00,$00,$00,$00,$00

; Tile $26: B
.byte $7C,$66,$66,$7C,$66,$66,$7C,$00
.byte $00,$00,$00,$00,$00,$00,$00,$00

; Tile $27: D (color index 2) — plane0=00, plane1=D shape
; (duplicate of Title_D ($16) but moved to plane1)
.byte $00,$00,$00,$00,$00,$00,$00,$00
.byte $7C,$66,$66,$66,$66,$66,$7C,$00

; Tile $28: G (color index 2) — plane0=00, plane1=G shape
; (duplicate of Title_G ($18) but moved to plane1)
.byte $00,$00,$00,$00,$00,$00,$00,$00
.byte $3C,$66,$60,$6E,$66,$66,$3C,$00

; Tile $29: dot (.)
.byte $00,$00,$00,$00,$00,$00,$18,$18
.byte $00,$00,$00,$00,$00,$00,$00,$00

; Tile $2A: lowercase v
.byte $00,$00,$66,$66,$66,$3C,$18,$00
.byte $00,$00,$00,$00,$00,$00,$00,$00


.res 8192-688, $00
