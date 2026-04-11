.segment "ZEROPAGE"
; Zero Page variables ($22-$7F available)

key_last:       .res 1           ; most recent key polled this frame ($00 = none)
frame_count:    .res 1           ; wrapping frame counter (increments each VSYNC)
rand_seed_lo:   .res 1           ; PRNG state - low byte
rand_seed_hi:   .res 1           ; PRNG state - high byte

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
   stz frame_count

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

   jsr draw_title_screen

;******************************************************************
; main_loop — one iteration per video frame (60 Hz)
;******************************************************************
main_loop:
   jsr wait_vsync

   inc frame_count

   jsr read_keyboard             ; fills key_last

   lda key_last
   cmp #KEY_RUN_STOP
   beq exit_game

   jsr update_hud                ; refresh dynamic readouts

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
@poll:
   lda VERA_isr
   and #$01                      ; bit 0 = VSYNC interrupt
   beq @poll
   lda #$01
   sta VERA_isr                  ; write 1 to clear VSYNC bit only
   rts

;******************************************************************
; read_keyboard — drain GETIN buffer; key_last = last key seen
;   key_last = $00 means no key was pressed this frame
;******************************************************************
read_keyboard:
   stz key_last                  ; clear before each frame's poll
@drain:
   jsr GETIN
   beq @done                     ; Z=1 → buffer empty
   sta key_last
   bra @drain                    ; keep draining buffer
@done:
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
   .byte "PHASE 1 - FOUNDATION", 0
str_status_vsync:
   .byte "VSYNC : OK (60HZ POLLING)", 0
str_status_kbd:
   .byte "KEYBOARD: GETIN DRAIN LOOP", 0
str_status_spr:
   .byte "SPRITES : ENABLED", 0
str_exit_hint:
   .byte "PRESS RUN/STOP TO EXIT", 0
str_frame_lbl:
   .byte "FRAME   : $", 0
str_key_lbl:
   .byte "LAST KEY: $", 0

;******************************************************************
