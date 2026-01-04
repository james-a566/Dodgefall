; main.s — Step 0.5 (ca65)
; Boots, loads palette, defines a visible CHR tile, and shows 1 sprite via OAM DMA in NMI.
; Target: NROM-128 (16KB PRG @ $C000, 8KB CHR)

PRG_BANKS = 1
CHR_BANKS = 1

OAM_BUF   = $0200   ; conventional OAM shadow buffer page (256 bytes at $0200-$02FF)

; =========================
; iNES HEADER (16 bytes)
; =========================
.segment "HEADER"
  .byte 'N','E','S',$1A
  .byte PRG_BANKS
  .byte CHR_BANKS
  .byte $01          ; flags 6: vertical mirroring, mapper 0
  .byte $00          ; flags 7: mapper 0
  .byte $00          ; PRG-RAM size (0 => "default", fine for now)
  .byte $00
  .byte $00
  .byte $00,$00,$00,$00,$00

; =========================
; CODE (PRG ROM)
; =========================
.segment "CODE"

Reset:
  sei
  cld
  ldx #$40
  stx $4017          ; disable APU frame IRQ
  ldx #$FF
  txs                ; stack = $01FF
  inx                ; X = 0

  stx $2000          ; NMI off
  stx $2001          ; rendering off
  stx $4010          ; DMC IRQs off

; ---- wait for vblank (PPU ready) ----
@vblank1:
  bit $2002
  bpl @vblank1

; ---- clear RAM ($0000-$07FF) ----
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

; ---- wait for vblank again (safe for PPU writes) ----
@vblank2:
  bit $2002
  bpl @vblank2

; ---- load palette to $3F00-$3F1F ----
  lda $2002          ; reset PPU address latch
  lda #$3F
  sta $2006
  lda #$00
  sta $2006

  ldx #$00
@pal:
  lda PaletteData,x
  sta $2007
  inx
  cpx #$20
  bne @pal

; ---- initialize ONE sprite in OAM shadow buffer ----
  ; Sprite 0 layout in OAM:
  ; byte0 Y, byte1 tile, byte2 attributes, byte3 X
  lda #$70
  sta OAM_BUF+0      ; Y
  lda #$00
  sta OAM_BUF+1      ; tile index 0 (our solid tile in CHR)
  lda #$00
  sta OAM_BUF+2      ; attributes: palette 0, no flip, in front of bg
  lda #$78
  sta OAM_BUF+3      ; X

  ; Hide all other sprites (good hygiene)
  ldx #$04
@hide:
  lda #$FE           ; Y=$FE hides a sprite
  sta OAM_BUF,x
  inx
  bne @hide

; ---- enable NMI + rendering ----
  lda #%10000000     ; PPUCTRL: enable NMI (bit 7)
  sta $2000
  lda #%00011110     ; PPUMASK: show bg+sprites, no left clipping
  sta $2001

Forever:
  jmp Forever

; =========================
; NMI / IRQ
; =========================
NMI:
  ; preserve registers (good habit)
  pha
  txa
  pha
  tya
  pha

  ; OAM DMA: copies 256 bytes from $0200-$02FF to PPU OAM
  lda #$00
  sta $2003          ; OAMADDR = 0
  lda #$02
  sta $4014          ; OAMDMA from page $02xx (i.e., $0200)

  pla
  tay
  pla
  tax
  pla
  rti

IRQ:
  rti

; =========================
; DATA
; =========================
PaletteData:
  ; 32 bytes total: 16 bg + 16 sprite
  ; universal background color first ($0F = black)
  .byte $0F,$01,$21,$31,  $0F,$06,$16,$26,  $0F,$09,$19,$29,  $0F,$0C,$1C,$2C
  .byte $0F,$00,$10,$20,  $0F,$06,$16,$26,  $0F,$09,$19,$29,  $0F,$0C,$1C,$2C

; =========================
; VECTORS (placed at $FFFA-$FFFF by linker config)
; =========================
.segment "VECTORS"
  .word NMI
  .word Reset
  .word IRQ

; =========================
; CHR ROM (8KB)
; =========================
.segment "CHARS"
  ; Tile 0: solid 8x8 block (color index 3 of the chosen sprite palette)
  ; Each tile = 16 bytes: 8 bytes plane 0, 8 bytes plane 1.
  .byte $FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF   ; plane 0
  .byte $FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF   ; plane 1

  ; Fill the remaining CHR (8192 - 16 bytes)
  .res 8192-16, $00
