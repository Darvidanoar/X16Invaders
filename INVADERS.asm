.segment "ZEROPAGE"
; Zero Page variables ($22-$7F available)

key_last:       .res 1           ; most recent PETSCII key from GETIN ($00 = none)
frame_count:    .res 1           ; wrapping frame counter (increments each VSYNC)
rand_seed_lo:   .res 1           ; PRNG state - low byte
rand_seed_hi:   .res 1           ; PRNG state - high byte
player_x_lo:    .res 1           ; player X position, low byte  (VERA 640x480 space)
player_x_hi:    .res 1           ; player X position, high byte (bits 1-0 only)
key_flags:      .res 1           ; input flags this frame (see KEY_* constants)

;******************************************************************
.segment "ONCE"
.segment "CODE"
.org $080D

   jmp start                     ; jump to main code routine


;******************************************************************
; Includes
;******************************************************************
.include "INC\x16.inc"

;******************************************************************
; Constants
;******************************************************************

; VERA display control
VERA_SPRITE_EN  = %01000000      ; VERA_dc_video bit 6: enable sprites

; PETSCII control codes
PETSCII_WHITE   = $05            ; set text color to white
PETSCII_CLR     = $93            ; clear screen and home cursor
PETSCII_HOME    = $13            ; home cursor (no clear)
PETSCII_RETURN  = $0D            ; carriage return

; SCREEN_SET_CHARSET font numbers (call address $FF62)
CHARSET_UPPER   = 1              ; Commodore upper/graphics: $41-$5A = A-Z
CHARSET_LOWER   = 2              ; Commodore lower/upper:    $41-$5A = a-z (lowercase)

; Key codes (PETSCII)
KEY_RUN_STOP    = $03            ; RUN/STOP — exit game

; Input flag bits (key_flags)
KEY_LEFT        = %00000001
KEY_RIGHT       = %00000010
KEY_FIRE        = %00000100

; JOYSTICK_GET .A return: {B,Y,Sel,Sta,Up,Dn,Left,Right} active low
JOY_RIGHT       = %00000001     ; bit 0
JOY_LEFT        = %00000010     ; bit 1

; Player ship — all positions in VERA 640x480 coordinate space
PLAYER_Y        = 420            ; fixed Y, near bottom (479 = bottom edge)
PLAYER_X_INIT   = 312            ; starting X, centred  ((640-16)/2)
PLAYER_X_MIN    = 8              ; left  boundary (sprite left edge)
PLAYER_X_MAX    = 616            ; right boundary (640 - 16px sprite - 8px margin)
PLAYER_SPEED    = 4              ; pixels per frame

; Sprite attribute encoding helpers
SPRITE1_ATTR    = $1FC08 ; sprite 1 attribute base ($1FC00=sprite 0, reserved for KERNAL mouse)
SPR_Z_FRONT     = %00001100     ; byte 6: z-depth = %11 in bits 3-2 (in front of all layers)
SPR_16x16_PAL0  = %01010000     ; byte 7: width=1(16px), height=1(16px), palette_off=0

;******************************************************************
; start — main program entry point
;******************************************************************
start:
   sei                           ; disable interrupts during init

   ; Switch to 40-column text mode (mode 0)
   ; Carry clear = SET mode (carry set = READ mode)
   clc
   lda #$00
   jsr SCREEN_MODE

   ; Seed PRNG with hardware entropy
   jsr ENTROPY_GET
   sta rand_seed_lo
   stx rand_seed_hi

   ; Enable sprites in VERA display controller
   stz VERA_ctrl                 ; DCSEL=0, ADDRSEL=0
   lda VERA_dc_video
   ora #VERA_SPRITE_EN
   sta VERA_dc_video


   ; Clear game variables
   stz key_last
   stz key_flags
   stz frame_count

   ; Set initial player position before sprite init reads it
   jsr init_player

   cli                           ; re-enable interrupts

   ; Switch to Commodore uppercase/graphics charset: $41-$5A = A-Z
   ; Must be called AFTER SCREEN_MODE (which resets to lowercase by default)
   lda #CHARSET_UPPER
   jsr SCREEN_SET_CHARSET

   ; Clear screen and set text color
   lda #PETSCII_WHITE
   jsr CHROUT
   lda #PETSCII_CLR
   jsr CHROUT

   ; Upload sprite pixel data and configure sprite 1 attributes
   jsr init_sprites

   jsr draw_title_screen

;******************************************************************
; main_loop — one iteration per video frame (60 Hz)
;******************************************************************
main_loop:
   jsr wait_vsync

   inc frame_count

   jsr update_input              ; fills key_flags (joystick) + key_last (GETIN)

   lda key_last
   cmp #KEY_RUN_STOP
   beq exit_game

   jsr move_player               ; apply movement, clamp to boundaries
   jsr update_player_sprite      ; write new X to VERA sprite 1

   jsr update_hud                ; refresh text readouts

   jmp main_loop

;------------------------------------------------------------------
exit_game:
   lda #PETSCII_CLR
   jsr CHROUT
   jmp ENTER_BASIC

;******************************************************************
; wait_vsync — busy-poll VERA_isr until VSYNC, then clear flag
;******************************************************************
wait_vsync:
   ; WAI sleeps the CPU until any IRQ fires.  The KERNAL's VSYNC IRQ
   ; handler (60 Hz) wakes us up and has already cleared VERA_isr bit 0
   ; by the time execution returns here, so polling VERA_isr would loop
   ; forever.  Just return — one WAI ≈ one frame.
   wai
   rts

;******************************************************************
; update_input — joystick + GETIN keyboard input each frame
;
;   key_flags bits set this frame:
;     KEY_LEFT  — left arrow held
;     KEY_RIGHT — right arrow held
;     KEY_FIRE  — space bar pressed
;   key_last   — raw PETSCII from GETIN (RUN/STOP etc.)
;
;   JOYSTICK_GET(0) = keyboard-as-joystick; gives smooth held-key
;   movement with no repeat delay.  GETIN handles space and RUN/STOP.
;******************************************************************
update_input:
   stz key_flags
   stz key_last

   ; --- joystick 0 = keyboard d-pad (active low: 0 = pressed) ---
   ; Byte returned: {B,Y,Sel,Sta,Up,Dn,Left,Right} bits 7–0
   lda #0
   jsr JOYSTICK_GET
   pha                           ; save — AND destroys .A

   and #JOY_RIGHT                ; bit 0: right arrow
   bne @not_right
   lda key_flags
   ora #KEY_RIGHT
   sta key_flags
@not_right:
   pla
   and #JOY_LEFT                 ; bit 1: left arrow
   bne @not_left
   lda key_flags
   ora #KEY_LEFT
   sta key_flags
@not_left:

   ; --- GETIN — discrete events: fire, RUN/STOP, arrow fallback ---
@getin_drain:
   jsr GETIN
   beq @getin_done               ; buffer empty
   sta key_last
   cmp #$9D                      ; cursor left (PETSCII)
   bne @chk_right_getin
   lda key_flags
   ora #KEY_LEFT
   sta key_flags
   bra @getin_drain
@chk_right_getin:
   cmp #$1D                      ; cursor right (PETSCII)
   bne @chk_fire_getin
   lda key_flags
   ora #KEY_RIGHT
   sta key_flags
   bra @getin_drain
@chk_fire_getin:
   cmp #$20                      ; space = fire
   bne @getin_drain
   lda key_flags
   ora #KEY_FIRE
   sta key_flags
   bra @getin_drain
@getin_done:
   rts

;******************************************************************
; init_player — set player_x to starting position
;******************************************************************
init_player:
   lda #<PLAYER_X_INIT
   sta player_x_lo
   lda #>PLAYER_X_INIT
   sta player_x_hi
   rts

;******************************************************************
; init_sprites — upload pixel data + write sprite 1 attributes
;
;   Sprite 0 ($1FC00) is reserved by the KERNAL mouse cursor —
;   we disable it and keep clear of $1FC00.
;
;   Sprite 1 ($1FC08) = player ship
;   Pixel data at VRAM $00080 (128 bytes, 16x16 4bpp)
;   Address encoding:  addr[12:5] = $00080>>5 = $04  → byte 0 = $04
;                      4bpp, addr[16:13] = 0          → byte 1 = $00
;******************************************************************
init_sprites:
   stz VERA_ctrl

   ; --- set palette entry 1 = white (R=$F,G=$F,B=$F) ---
   ; VERA palette entry N is 2 bytes at VRAM_palette + N*2
   ; Byte 0: [7:4]=Green [3:0]=Blue   Byte 1: [3:0]=Red
   VERA_SET_ADDR (VRAM_palette + 2), 1   ; entry 1 (player white)
   lda #$FF                               ; G=$F, B=$F
   sta VERA_data0
   lda #$0F                               ; R=$F
   sta VERA_data0

   ; --- disable sprite 0 (KERNAL mouse cursor) ---
   VERA_SET_ADDR (VRAM_sprattr + 6), 1   ; sprite 0 byte 6 = z-depth
   lda #$00                               ; z-depth=0 → disabled
   sta VERA_data0

   ; --- upload player sprite pixel data to VRAM $00080 ---
   VERA_SET_ADDR $00080, 1
   ldx #0
@upload:
   lda player_spr_data,x
   sta VERA_data0
   inx
   cpx #128
   bne @upload

   ; --- write sprite 1 attribute bytes ---
   VERA_SET_ADDR SPRITE1_ATTR, 1
   lda #$04
   sta VERA_data0               ; byte 0: addr[12:5] = $00080>>5 = $04
   lda #$00
   sta VERA_data0               ; byte 1: 4bpp, addr[16:13] = 0
   lda player_x_lo
   sta VERA_data0               ; byte 2: X[7:0]
   lda player_x_hi
   and #$03
   sta VERA_data0               ; byte 3: X[9:8]
   lda #<PLAYER_Y
   sta VERA_data0               ; byte 4: Y[7:0]
   lda #>PLAYER_Y
   and #$03
   sta VERA_data0               ; byte 5: Y[9:8]
   lda #SPR_Z_FRONT
   sta VERA_data0               ; byte 6: z-depth=3, no collision, no flip
   lda #SPR_16x16_PAL0
   sta VERA_data0               ; byte 7: palette 0, 16x16
   rts

;******************************************************************
; move_player — apply key_flags movement and clamp to screen edges
;******************************************************************
move_player:
   lda key_flags

   ; --- move left ---
   and #KEY_LEFT
   beq @check_right
   lda player_x_lo
   sec
   sbc #PLAYER_SPEED
   sta player_x_lo
   bcs @clamp_left              ; no borrow → hi unchanged
   dec player_x_hi
@clamp_left:
   ; Clamp: if hi went negative ($FF) or (hi=0 AND lo < min) → set to min
   lda player_x_hi
   bmi @set_min                 ; $80–$FF = underflowed
   bne @check_right             ; hi > 0 → still above minimum
   lda player_x_lo
   cmp #PLAYER_X_MIN
   bcs @check_right             ; lo >= min → ok
@set_min:
   lda #<PLAYER_X_MIN
   sta player_x_lo
   lda #>PLAYER_X_MIN
   sta player_x_hi

   ; --- move right ---
@check_right:
   lda key_flags
   and #KEY_RIGHT
   beq @move_done
   lda player_x_lo
   clc
   adc #PLAYER_SPEED
   sta player_x_lo
   bcc @clamp_right             ; no carry → hi unchanged
   inc player_x_hi
@clamp_right:
   ; Clamp: if hi > max_hi, OR (hi == max_hi AND lo > max_lo) → set to max
   lda player_x_hi
   cmp #>PLAYER_X_MAX
   bcc @move_done               ; hi < max_hi → definitely ok
   bne @set_max                 ; hi > max_hi → over limit
   lda player_x_lo
   cmp #<PLAYER_X_MAX
   bcc @move_done               ; lo < max_lo when hi == max_hi → ok
   beq @move_done               ; lo == max_lo → exactly at max, ok
@set_max:
   lda #<PLAYER_X_MAX
   sta player_x_lo
   lda #>PLAYER_X_MAX
   sta player_x_hi

@move_done:
   rts

;******************************************************************
; update_player_sprite — write current X position to sprite 1 in VERA
;   Only X needs updating (Y is fixed)
;******************************************************************
update_player_sprite:
   stz VERA_ctrl
   VERA_SET_ADDR (SPRITE1_ATTR + 2), 1
   lda player_x_lo
   sta VERA_data0               ; sprite byte 2: X[7:0]
   lda player_x_hi
   and #$03
   sta VERA_data0               ; sprite byte 3: X[9:8]
   rts

;******************************************************************
; draw_title_screen — print static Phase 1 info to screen
;   Called once at startup; static text stays until screen cleared
;******************************************************************
draw_title_screen:
   ; Row 2, col 14: "X16 INVADERS"
   lda #2
   ldy #14
   clc
   jsr PLOT
   ldx #0
@lp1: lda str_title,x
   beq @lp1_done
   jsr CHROUT
   inx
   bra @lp1
@lp1_done:

   ; Row 4, col 10: "PHASE 1 - FOUNDATION"
   lda #4
   ldy #10
   clc
   jsr PLOT
   ldx #0
@lp2: lda str_subtitle,x
   beq @lp2_done
   jsr CHROUT
   inx
   bra @lp2
@lp2_done:

   ; Row 8, col 2: status lines
   lda #8
   ldy #2
   clc
   jsr PLOT
   ldx #0
@lp3: lda str_status_vsync,x
   beq @lp3_done
   jsr CHROUT
   inx
   bra @lp3
@lp3_done:

   lda #10
   ldy #2
   clc
   jsr PLOT
   ldx #0
@lp4: lda str_status_kbd,x
   beq @lp4_done
   jsr CHROUT
   inx
   bra @lp4
@lp4_done:

   lda #12
   ldy #2
   clc
   jsr PLOT
   ldx #0
@lp5: lda str_status_spr,x
   beq @lp5_done
   jsr CHROUT
   inx
   bra @lp5
@lp5_done:

   ; Row 15, col 2: exit hint
   lda #15
   ldy #2
   clc
   jsr PLOT
   ldx #0
@lp6: lda str_exit_hint,x
   beq @lp6_done
   jsr CHROUT
   inx
   bra @lp6
@lp6_done:

   rts

;******************************************************************
; update_hud — rewrite dynamic values each frame
;   Overwrites fixed screen positions; no full redraw needed
;******************************************************************
update_hud:
   ; Frame counter at row 19, col 2
   lda #19
   ldy #2
   clc
   jsr PLOT
   ldx #0
@fc_lbl: lda str_frame_lbl,x
   beq @fc_val
   jsr CHROUT
   inx
   bra @fc_lbl
@fc_val:
   lda frame_count
   jsr print_hex_byte

   ; Last key at row 21, col 2
   lda #21
   ldy #2
   clc
   jsr PLOT
   ldx #0
@kl_lbl: lda str_key_lbl,x
   beq @kl_val
   jsr CHROUT
   inx
   bra @kl_lbl
@kl_val:
   lda key_last
   jsr print_hex_byte
   lda #' '
   jsr CHROUT                    ; erase stale digit if value shrank

   rts

;******************************************************************
; print_hex_byte — print .A as two uppercase hex digits via CHROUT
;******************************************************************
print_hex_byte:
   pha
   lsr                           ; shift high nibble down
   lsr
   lsr
   lsr
   jsr print_hex_nybble
   pla
   and #$0F                      ; isolate low nibble
   jsr print_hex_nybble
   rts

; print_hex_nybble — print lower 4 bits of .A as one hex digit
;   Relies on carry state from CMP to select digit vs. letter range
print_hex_nybble:
   cmp #10
   bcc @digit                    ; carry clear → 0-9
   adc #($41 - 10 - 1)          ; A-F: 'A'=65; carry set adds 1
   jsr CHROUT
   rts
@digit:
   adc #$30                      ; 0-9: '0'=48; carry clear adds 0
   jsr CHROUT
   rts

;******************************************************************
; String data — null-terminated, PETSCII uppercase
;******************************************************************
str_title:
   .byte "X16 INVADERS", 0
str_subtitle:
   .byte "PHASE 2 - PLAYER SHIP", 0
str_status_vsync:
   .byte "VSYNC : WAI (60HZ IRQ)", 0
str_status_kbd:
   .byte "KEYBOARD: JOYSTICK + GETIN", 0
str_status_spr:
   .byte "SPRITES : ENABLED", 0
str_exit_hint:
   .byte "PRESS RUN/STOP TO EXIT", 0
str_frame_lbl:
   .byte "FRAME   : $", 0
str_key_lbl:
   .byte "LAST KEY: $", 0

;******************************************************************
; player_spr_data — 16x16 4bpp sprite, 128 bytes
;
;   Color 0 = transparent, Color 1 = white (default palette index 1)
;   Design: classic upward-pointing triangular ship with engine notches
;
;   Each byte encodes 2 pixels: high nibble = left, low nibble = right
;   Columns: 0123456789ABCDEF
;
;   Row  0:  .......1........   cannon tip
;   Row  1:  .......11.......
;   Row  2:  ......111.......
;   Row  3:  ......111.......
;   Row  4:  .....11111......
;   Row  5:  .....1111111....
;   Row  6:  ...111111111....
;   Row  7:  ..11111111111...
;   Row  8:  .1111111111111..
;   Row  9:  1111111111111111   full base
;   Row 10:  1111111111111111
;   Row 11:  1111111111111111
;   Row 12:  11..11111111..11   engine notches
;   Row 13:  11..11111111..11
;   Row 14:  ................
;   Row 15:  ................
;******************************************************************
player_spr_data:
   ; row 0
   .byte $00,$00,$00,$01,$00,$00,$00,$00
   ; row 1
   .byte $00,$00,$00,$01,$10,$00,$00,$00
   ; row 2
   .byte $00,$00,$00,$11,$10,$00,$00,$00
   ; row 3
   .byte $00,$00,$00,$11,$10,$00,$00,$00
   ; row 4
   .byte $00,$00,$01,$11,$11,$00,$00,$00
   ; row 5
   .byte $00,$00,$01,$11,$11,$11,$00,$00
   ; row 6
   .byte $00,$01,$11,$11,$11,$11,$00,$00
   ; row 7
   .byte $00,$11,$11,$11,$11,$11,$10,$00
   ; row 8
   .byte $01,$11,$11,$11,$11,$11,$11,$00
   ; row 9
   .byte $11,$11,$11,$11,$11,$11,$11,$11
   ; row 10
   .byte $11,$11,$11,$11,$11,$11,$11,$11
   ; row 11
   .byte $11,$11,$11,$11,$11,$11,$11,$11
   ; row 12  (engine notches: cols 2-3 and 12-13 transparent)
   .byte $11,$00,$11,$11,$11,$11,$00,$11
   ; row 13
   .byte $11,$00,$11,$11,$11,$11,$00,$11
   ; row 14
   .byte $00,$00,$00,$00,$00,$00,$00,$00
   ; row 15
   .byte $00,$00,$00,$00,$00,$00,$00,$00

;******************************************************************
