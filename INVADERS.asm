.segment "ZEROPAGE"
; Zero Page variables ($22-$7F available)

key_last:       .res 1           ; most recent PETSCII key from GETIN ($00 = none)
frame_count:    .res 1           ; wrapping frame counter (increments each VSYNC)
rand_seed_lo:   .res 1           ; PRNG state - low byte
rand_seed_hi:   .res 1           ; PRNG state - high byte
player_x_lo:    .res 1           ; player X position, low byte  (VERA 640x480 space)
player_x_hi:    .res 1           ; player X position, high byte (bits 1-0 only)
key_flags:      .res 1           ; input flags this frame (see KEY_* constants)

; --- Invader grid state ---
inv_grid_x_lo:  .res 1           ; invader grid left-column X, low byte (VERA coords)
inv_grid_x_hi:  .res 1           ; invader grid left-column X, high byte
inv_offset_y:   .res 1           ; cumulative Y drop applied to grid (VERA pixels)
inv_direction:  .res 1           ; 0 = moving right, 1 = moving left
inv_alive:      .res 7           ; 55-bit alive bitmap; bit N = invader N alive
inv_count:      .res 1           ; number of invaders still alive
inv_move_timer: .res 1           ; frames until next march step
inv_move_speed: .res 1           ; frames per march step (decreases as invaders die)
inv_drop_flag:  .res 1           ; 1 = drop grid on next step instead of marching
inv_anim_frame: .res 1           ; animation frame index: 0 or 1

; --- Scratch for invader sprite update loop ---
zp_row:         .res 1
zp_col:         .res 1
zp_x_lo:        .res 1
zp_x_hi:        .res 1
zp_y_base_lo:   .res 1           ; grid Y base + cumulative drop
zp_y_base_hi:   .res 1
zp_row_y_lo:    .res 1           ; row Y = y_base + row spacing offset
zp_row_y_hi:    .res 1
zp_addr_b0:     .res 1           ; VERA sprite data addr[12:5] for current row+frame

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

; Invader grid geometry (VERA 640x480 coordinate space)
INV_GRID_X_INIT   = 112         ; left-column X at start (centered: (640 - 10*40 - 16) / 2 = 112)
INV_GRID_Y_BASE   = 80          ; top-row Y, fixed base (drops added via inv_offset_y)
INV_SPACING_X     = 40          ; VERA pixels between invader column origins
INV_SPACING_Y     = 48          ; VERA pixels between invader row origins
INV_STEP_X        = 4           ; VERA pixels per march step
INV_DROP_Y        = 16          ; VERA pixels per grid drop
INV_MOVE_SPEED_INIT = 50        ; frames between march steps (initial)
INV_COUNT_INIT    = 55

; Grid boundary: when grid_x reaches these values, reverse and drop
; Rightmost invader base X = grid_x + 10*INV_SPACING_X (=400). Right wall = 624 (640-16px).
; So right limit = 624 - 400 - 16 = 208
INV_X_RIGHT_LIM   = 208
INV_X_LEFT_LIM    = 16          ; leftmost sprite at x=grid_x must stay >= 16

; VRAM addresses for invader sprite pixel data (128 bytes each, 16x16 4bpp)
VRAM_INV_A_F0   = $00100        ; Type A (crab,   bottom rows 3-4), frame 0
VRAM_INV_A_F1   = $00180        ; Type A frame 1
VRAM_INV_B_F0   = $00200        ; Type B (octopus, middle rows 1-2), frame 0
VRAM_INV_B_F1   = $00280        ; Type B frame 1
VRAM_INV_C_F0   = $00300        ; Type C (squid,   top row 0), frame 0
VRAM_INV_C_F1   = $00380        ; Type C frame 1

; Sprite addr[12:5] byte values for each type/frame (= VRAM_addr >> 5)
;   VRAM $00100>>5=$08  $00180>>5=$0C  $00200>>5=$10  $00280>>5=$14  $00300>>5=$18  $00380>>5=$1C
INV_ATTR_BASE   = $1FC58        ; sprite slot 11 = first invader ($1FC00 + 11*8)
INV_SPRITE_SLOT = 11            ; first invader sprite slot index

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

   ; Upload invader sprite data, set palette, init grid state, place sprites
   jsr init_invaders

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

   ; --- Invader march timer ---
   dec inv_move_timer
   bne @skip_inv_step
   jsr step_invaders             ; move grid, check bounds, update sprites
   lda inv_move_speed
   sta inv_move_timer
@skip_inv_step:

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

   ; --- set palette entries 1-4 ---
   ; VERA palette entry N is 2 bytes at VRAM_palette + N*2
   ; Byte 0: [7:4]=Green [3:0]=Blue   Byte 1: [3:0]=Red (bits 7-4 unused)
   VERA_SET_ADDR (VRAM_palette + 2), 1   ; entry 1 (player white); stride=1 auto-advances
   lda #$FF                               ; G=$F, B=$F
   sta VERA_data0
   lda #$0F                               ; R=$F  → white
   sta VERA_data0
   ; entry 2 = cyan  (R=0, G=$F, B=$F)
   lda #$FF                               ; G=$F, B=$F
   sta VERA_data0
   lda #$00                               ; R=$0
   sta VERA_data0
   ; entry 3 = magenta (R=$F, G=0, B=$F)
   lda #$0F                               ; G=$0, B=$F
   sta VERA_data0
   lda #$0F                               ; R=$F
   sta VERA_data0
   ; entry 4 = green  (R=0, G=$F, B=0)
   lda #$F0                               ; G=$F, B=$0
   sta VERA_data0
   lda #$00                               ; R=$0
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
; init_invaders — upload invader pixel data, init grid state, place sprites
;******************************************************************
init_invaders:
   stz VERA_ctrl

   ; --- upload Type A frame 0 → VRAM $00100 ---
   VERA_SET_ADDR VRAM_INV_A_F0, 1
   ldx #128
@up_af0: lda inv_a_spr_f0-128,x
   sta VERA_data0
   inx
   bne @up_af0

   ; --- upload Type A frame 1 → VRAM $00180 ---
   VERA_SET_ADDR VRAM_INV_A_F1, 1
   ldx #128
@up_af1: lda inv_a_spr_f1-128,x
   sta VERA_data0
   inx
   bne @up_af1

   ; --- upload Type B frame 0 → VRAM $00200 ---
   VERA_SET_ADDR VRAM_INV_B_F0, 1
   ldx #128
@up_bf0: lda inv_b_spr_f0-128,x
   sta VERA_data0
   inx
   bne @up_bf0

   ; --- upload Type B frame 1 → VRAM $00280 ---
   VERA_SET_ADDR VRAM_INV_B_F1, 1
   ldx #128
@up_bf1: lda inv_b_spr_f1-128,x
   sta VERA_data0
   inx
   bne @up_bf1

   ; --- upload Type C frame 0 → VRAM $00300 ---
   VERA_SET_ADDR VRAM_INV_C_F0, 1
   ldx #128
@up_cf0: lda inv_c_spr_f0-128,x
   sta VERA_data0
   inx
   bne @up_cf0

   ; --- upload Type C frame 1 → VRAM $00380 ---
   VERA_SET_ADDR VRAM_INV_C_F1, 1
   ldx #128
@up_cf1: lda inv_c_spr_f1-128,x
   sta VERA_data0
   inx
   bne @up_cf1

   ; --- initialize zero-page grid variables ---
   lda #<INV_GRID_X_INIT
   sta inv_grid_x_lo
   lda #>INV_GRID_X_INIT
   sta inv_grid_x_hi
   stz inv_offset_y
   stz inv_direction
   stz inv_anim_frame
   stz inv_drop_flag

   ; all 55 invaders alive: bytes 0-5 = $FF, byte 6 = $7F (55 bits)
   lda #$FF
   sta inv_alive+0
   sta inv_alive+1
   sta inv_alive+2
   sta inv_alive+3
   sta inv_alive+4
   sta inv_alive+5
   lda #$7F
   sta inv_alive+6

   lda #INV_COUNT_INIT
   sta inv_count
   lda #INV_MOVE_SPEED_INIT
   sta inv_move_speed
   sta inv_move_timer

   ; --- write initial sprite attributes for all 55 invaders ---
   jsr update_invader_sprites
   rts

;******************************************************************
; step_invaders — one march step: move or drop grid, toggle anim frame
;   Called when inv_move_timer reaches 0.
;   Updates inv_grid_x / inv_offset_y, sets inv_drop_flag as needed,
;   then refreshes all VERA sprite positions.
;******************************************************************
step_invaders:
   ; toggle animation frame
   lda inv_anim_frame
   eor #1
   sta inv_anim_frame

   ; if drop flag is set: drop grid this step, skip march
   lda inv_drop_flag
   beq @do_march
   stz inv_drop_flag
   lda inv_offset_y
   clc
   adc #INV_DROP_Y
   sta inv_offset_y
   bra @sprites_done

@do_march:
   lda inv_direction
   bne @march_left

   ; --- march right ---
   lda inv_grid_x_lo
   clc
   adc #INV_STEP_X
   sta inv_grid_x_lo
   bcc @chk_right
   inc inv_grid_x_hi
@chk_right:
   ; hit right if grid_x > INV_X_RIGHT_LIM (208, fits in 1 byte, hi always 0)
   lda inv_grid_x_hi
   bne @clamp_right          ; hi > 0 → definitely over limit
   lda inv_grid_x_lo
   cmp #INV_X_RIGHT_LIM + 1  ; C set if lo > limit
   bcc @sprites_done
@clamp_right:
   lda #<INV_X_RIGHT_LIM
   sta inv_grid_x_lo
   lda #>INV_X_RIGHT_LIM
   sta inv_grid_x_hi
   lda #1
   sta inv_direction
   sta inv_drop_flag
   bra @sprites_done

   ; --- march left ---
@march_left:
   lda inv_grid_x_lo
   sec
   sbc #INV_STEP_X
   sta inv_grid_x_lo
   bcs @chk_left             ; no borrow
   dec inv_grid_x_hi
@chk_left:
   ; hit left if hi went negative OR lo < INV_X_LEFT_LIM
   lda inv_grid_x_hi
   bmi @clamp_left
   lda inv_grid_x_lo
   cmp #INV_X_LEFT_LIM
   bcs @sprites_done         ; lo >= left limit → ok
@clamp_left:
   lda #<INV_X_LEFT_LIM
   sta inv_grid_x_lo
   lda #>INV_X_LEFT_LIM
   sta inv_grid_x_hi
   stz inv_direction
   lda #1
   sta inv_drop_flag

@sprites_done:
   jsr update_invader_sprites
   rts

;******************************************************************
; update_invader_sprites — write all 55 invader sprite attributes to VERA
;
;   VERA sprite slots 11-65 hold the 55 invaders.
;   Attributes base: $1FC58 ($1FC00 + 11*8).
;   With stride=1 the VERA address auto-increments, so we set it
;   once and write all 440 bytes sequentially.
;
;   Byte layout per sprite:
;     0: data addr[12:5]   (encodes VRAM pixel data address + frame)
;     1: $00               (4bpp, addr[16:13]=0)
;     2: X[7:0]
;     3: X[9:8]
;     4: Y[7:0]
;     5: Y[9:8]
;     6: z-depth/collision
;     7: palette / size
;
;   Invader index i = row*11 + col; alive bit i in inv_alive bitmap.
;   For Phase 3 all invaders are alive; alive check will be added Phase 4.
;******************************************************************
update_invader_sprites:
   stz VERA_ctrl
   lda #$11              ; stride=1, VRAM bank bit=1 (addr $1Fxxxx)
   sta VERA_addr_bank
   lda #$FC
   sta VERA_addr_high
   lda #$58
   sta VERA_addr_low     ; VERA now at $1FC58, auto-increments by 1

   ; precompute grid Y base = INV_GRID_Y_BASE + inv_offset_y
   lda #<INV_GRID_Y_BASE
   clc
   adc inv_offset_y
   sta zp_y_base_lo
   lda #>INV_GRID_Y_BASE
   adc #0
   sta zp_y_base_hi

   stz zp_row
@row_loop:
   ; compute row Y: zp_row_y = zp_y_base + row_y_offsets[row]
   ldy zp_row
   lda row_y_offsets,y
   clc
   adc zp_y_base_lo
   sta zp_row_y_lo
   lda #0
   adc zp_y_base_hi
   sta zp_row_y_hi

   ; select addr byte0 based on row type and animation frame
   ldy zp_row
   lda inv_anim_frame
   beq @use_f0
   lda inv_addr_b0_f1,y
   bra @got_b0
@use_f0:
   lda inv_addr_b0_f0,y
@got_b0:
   sta zp_addr_b0

   stz zp_col
@col_loop:
   ; compute sprite X = inv_grid_x + col_x_offsets[col]
   ldy zp_col
   lda col_x_lo,y
   clc
   adc inv_grid_x_lo
   sta zp_x_lo
   lda col_x_hi,y
   adc inv_grid_x_hi
   sta zp_x_hi

   ; write 8 attribute bytes (VERA auto-increments)
   lda zp_addr_b0
   sta VERA_data0        ; byte 0: data addr[12:5]
   stz VERA_data0        ; byte 1: 4bpp, addr[16:13]=0
   lda zp_x_lo
   sta VERA_data0        ; byte 2: X[7:0]
   lda zp_x_hi
   and #$03
   sta VERA_data0        ; byte 3: X[9:8]
   lda zp_row_y_lo
   sta VERA_data0        ; byte 4: Y[7:0]
   lda zp_row_y_hi
   and #$03
   sta VERA_data0        ; byte 5: Y[9:8]
   lda #SPR_Z_FRONT
   sta VERA_data0        ; byte 6: z-depth=3 (in front of all layers)
   lda #SPR_16x16_PAL0
   sta VERA_data0        ; byte 7: 16x16, palette offset 0

   inc zp_col
   lda zp_col
   cmp #11
   bne @col_loop

   inc zp_row
   lda zp_row
   cmp #5
   bne @row_loop

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
   .byte "PHASE 3 - INVADER GRID", 0
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
   .byte $00,$00,$00,$00,$00,$00,$00,$00
   ; row 1
   .byte $00,$00,$00,$01,$10,$00,$00,$00
   ; row 2
   .byte $00,$00,$00,$01,$10,$00,$00,$00
   ; row 3
   .byte $00,$00,$00,$01,$10,$00,$00,$00
   ; row 4
   .byte $00,$00,$01,$11,$11,$10,$00,$00
   ; row 5
   .byte $00,$00,$11,$11,$11,$11,$00,$00
   ; row 6
   .byte $00,$01,$11,$11,$11,$11,$10,$00
   ; row 7
   .byte $00,$01,$11,$11,$11,$11,$10,$00
   ; row 8
   .byte $01,$11,$11,$11,$11,$11,$11,$10
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
; Lookup tables for update_invader_sprites
;
;   inv_addr_b0_f0/f1 — sprite data addr[12:5] for row 0-4, each frame
;     Row 0 = Type C (squid),   VRAM $00300/$00380 → $18/$1C
;     Rows 1-2 = Type B (octo), VRAM $00200/$00280 → $10/$14
;     Rows 3-4 = Type A (crab), VRAM $00100/$00180 → $08/$0C
;
;   col_x_lo/hi — column X offset = col * INV_SPACING_X (=40), columns 0-10
;   row_y_offsets — row Y offset = row * INV_SPACING_Y (=48), rows 0-4
;******************************************************************
inv_addr_b0_f0: .byte $18, $10, $10, $08, $08   ; rows 0-4, frame 0
inv_addr_b0_f1: .byte $1C, $14, $14, $0C, $0C   ; rows 0-4, frame 1

col_x_lo:       .byte   0, 40, 80,120,160,200,240, 24, 64,104,144
col_x_hi:       .byte   0,  0,  0,  0,  0,  0,  0,  1,  1,  1,  1

row_y_offsets:  .byte   0, 48, 96,144,192          ; rows 0-4

;******************************************************************
; Invader sprite pixel data — 16x16 4bpp, 128 bytes each
; Each byte encodes 2 pixels: high nibble = left pixel, low nibble = right
; Color 0 = transparent
;
; Type A (crab,   rows 3-4): color 4 = green
; Type B (octopus, rows 1-2): color 3 = magenta
; Type C (squid,  row 0):    color 2 = cyan
;
; Design key (16 pixels wide):
;   .  = 0 (transparent)
;   A/B/C = color 4/3/2 for each type
;******************************************************************

;------------------------------------------------------------------
; Type A — crab, green (color 4), frame 0 (legs spread)
;
;   0: ................
;   1: 4...4......4...4   claw tips
;   2: .4............4.
;   3: .4444444444444.   body top
;   4: 44.44.4444.44.44  eye gaps
;   5: 4444444444444444
;   6: .44444444444444.
;   7: 4..4........4..4  legs spread
;   8: 4...........4...
;   9-15: ..............
;------------------------------------------------------------------
inv_a_spr_f0:
   .byte $00,$00,$00,$00,$00,$00,$00,$00  ; row 0
   .byte $40,$00,$40,$00,$00,$04,$00,$04  ; row 1
   .byte $04,$00,$00,$00,$00,$00,$04,$00  ; row 2
   .byte $04,$44,$44,$44,$44,$44,$44,$40  ; row 3
   .byte $44,$04,$40,$44,$44,$04,$40,$44  ; row 4
   .byte $44,$04,$40,$44,$44,$04,$40,$44  ; row 5
   .byte $44,$04,$40,$44,$44,$04,$40,$44  ; row 6
   .byte $44,$44,$44,$44,$44,$44,$44,$44  ; row 7
   .byte $44,$44,$44,$44,$44,$44,$44,$44  ; row 8
   .byte $04,$44,$44,$44,$44,$44,$44,$40  ; row 9
   .byte $04,$44,$44,$44,$44,$44,$44,$40  ; row 10
   .byte $40,$04,$00,$00,$00,$00,$40,$04  ; row 11
   .byte $40,$04,$00,$00,$00,$00,$40,$04  ; row 12
   .byte $40,$00,$00,$00,$00,$00,$00,$04  ; row 13
   .byte $40,$00,$00,$00,$00,$00,$00,$04  ; row 14
   .byte $00,$00,$00,$00,$00,$00,$00,$00  ; row 15

;------------------------------------------------------------------
; Type A — crab, green (color 4), frame 1 (legs tucked)
;
;   rows 0-6: same as frame 0
;   7: .4..........4.  legs tucked inward
;   8: ..4..........4..
;------------------------------------------------------------------
inv_a_spr_f1:
   .byte $00,$00,$00,$00,$00,$00,$00,$00  ; row 0
   .byte $40,$00,$40,$00,$00,$04,$00,$04  ; row 1  (same)
   .byte $04,$00,$00,$00,$00,$00,$04,$00  ; row 2  (same)
   .byte $04,$44,$44,$44,$44,$44,$44,$40  ; row 3  (same)
   .byte $44,$04,$40,$44,$44,$04,$40,$44  ; row 4  (same)
   .byte $44,$04,$40,$44,$44,$04,$40,$44  ; row 5  (same)
   .byte $44,$04,$40,$44,$44,$04,$40,$44  ; row 6  (same)
   .byte $44,$44,$44,$44,$44,$44,$44,$44  ; row 7  legs tucked
   .byte $44,$44,$44,$44,$44,$44,$44,$44  ; row 8
   .byte $04,$44,$44,$44,$44,$44,$44,$40  ; row 9
   .byte $04,$44,$44,$44,$44,$44,$44,$40  ; row 10
   .byte $04,$00,$04,$00,$00,$40,$00,$40  ; row 11
   .byte $04,$00,$04,$00,$00,$40,$00,$40  ; row 12
   .byte $00,$40,$00,$00,$00,$00,$04,$00  ; row 13
   .byte $00,$40,$00,$00,$00,$00,$04,$00  ; row 14
   .byte $00,$00,$00,$00,$00,$00,$00,$00  ; row 15

;------------------------------------------------------------------
; Type B — octopus, magenta (color 3), frame 0 (tentacles out-wide)
;
;   0: ................
;   1: ..333333333333..  dome top
;   2: .3333333333333.
;   3: 33.333333333.33   bumps
;   4: 3.33.33333.33.3   eye row
;   5: 3333333333333333
;   6: .3333333333333.
;   7: 3..3...33...3..3  tentacles
;   8: 3...........3
;------------------------------------------------------------------
inv_b_spr_f0:
   .byte $00,$00,$00,$00,$00,$00,$00,$00  ; row 0
   .byte $00,$33,$33,$33,$33,$33,$33,$00  ; row 1
   .byte $03,$33,$33,$33,$33,$33,$33,$30  ; row 2
   .byte $33,$03,$33,$33,$33,$33,$30,$33  ; row 3
   .byte $33,$03,$33,$33,$33,$33,$30,$33  ; row 4
   .byte $30,$33,$30,$33,$33,$30,$33,$03  ; row 5 eye row
   .byte $30,$33,$30,$33,$33,$30,$33,$03  ; row 6 eye row
   .byte $33,$33,$33,$33,$33,$33,$33,$33  ; row 7
   .byte $33,$33,$33,$33,$33,$33,$33,$33  ; row 8
   .byte $03,$33,$33,$33,$33,$33,$33,$30  ; row 9
   .byte $03,$33,$33,$33,$33,$33,$33,$30  ; row 10
   .byte $30,$03,$00,$03,$30,$00,$30,$03  ; row 11
   .byte $30,$03,$00,$30,$03,$00,$30,$03  ; row 12
   .byte $30,$00,$00,$00,$00,$00,$00,$03  ; row 13
   .byte $30,$00,$00,$00,$00,$00,$00,$03  ; row 14
   .byte $00,$00,$00,$00,$00,$00,$00,$00  ; row 15

;------------------------------------------------------------------
; Type B — octopus, magenta (color 3), frame 1 (tentacles angled in)
;
;   rows 0-6: same as frame 0
;   7: .3..3.....3..3.   tentacles angled in
;   8: .3...........3.
;------------------------------------------------------------------
inv_b_spr_f1:
   .byte $00,$00,$00,$00,$00,$00,$00,$00  ; row 0
   .byte $00,$33,$33,$33,$33,$33,$33,$00  ; row 1  (same)
   .byte $03,$33,$33,$33,$33,$33,$33,$30  ; row 2  (same)
   .byte $33,$03,$33,$33,$33,$33,$30,$33  ; row 3  (same)
   .byte $33,$03,$33,$33,$33,$33,$30,$33  ; row 4  (same)
   .byte $30,$33,$03,$33,$33,$03,$33,$03  ; row 5  (same)
   .byte $30,$33,$03,$33,$33,$03,$33,$03  ; row 6  (same)
   .byte $33,$33,$33,$33,$33,$33,$33,$33  ; row 7  tentacles in
   .byte $33,$33,$33,$33,$33,$33,$33,$33  ; row 8
   .byte $03,$33,$33,$33,$33,$33,$33,$30  ; row 9
   .byte $03,$33,$33,$33,$33,$33,$33,$30  ; row 10
   .byte $03,$00,$30,$03,$00,$30,$03,$00  ; row 11
   .byte $00,$30,$30,$03,$00,$30,$03,$00  ; row 12
   .byte $03,$00,$00,$00,$00,$00,$00,$30  ; row 13
   .byte $03,$00,$00,$00,$00,$00,$00,$30  ; row 14
   .byte $00,$00,$00,$00,$00,$00,$00,$00  ; row 15

;------------------------------------------------------------------
; Type C — squid, cyan (color 2), frame 0 (antennae out)
;
;   0: ...2.......2...   antenna tips
;   1: ..22........22..
;   2: ..222222222222..
;   3: .2222222222222.
;   4: 2222222222222222
;   5: 2.22.222222.22.2  eye row
;   6: 2222222222222222
;   7: .2.2.......2.2.   bottom fringe
;   8: 2...........2
;------------------------------------------------------------------
inv_c_spr_f0:
   .byte $00,$00,$02,$00,$00,$20,$00,$00  ; row 0
   .byte $00,$00,$22,$00,$00,$22,$00,$00  ; row 1
   .byte $00,$00,$22,$22,$22,$22,$00,$00  ; row 2
   .byte $00,$02,$20,$22,$20,$22,$20,$00  ; row 3
   .byte $00,$22,$20,$22,$20,$22,$22,$00  ; row 4
   .byte $00,$22,$22,$22,$22,$22,$22,$00  ; row 5 eye row
   .byte $00,$22,$22,$22,$22,$22,$22,$00  ; row 6
   .byte $00,$20,$22,$02,$20,$22,$02,$00  ; row 7
   .byte $00,$20,$22,$02,$20,$22,$02,$00  ; row 8
   .byte $00,$22,$22,$22,$22,$22,$22,$00  ; row 9
   .byte $00,$22,$22,$22,$22,$22,$22,$00  ; row 10
   .byte $00,$02,$02,$00,$00,$20,$20,$00  ; row 11
   .byte $00,$02,$02,$00,$00,$20,$20,$00  ; row 12
   .byte $00,$20,$00,$00,$00,$00,$02,$00  ; row 13
   .byte $00,$02,$00,$00,$00,$00,$20,$00  ; row 14
   .byte $00,$00,$00,$00,$00,$00,$00,$00  ; row 15

;------------------------------------------------------------------
; Type C — squid, cyan (color 2), frame 1 (antennae pulled inward)
;
;   row 0: .....2.2.2.....   antennae closer to centre
;   row 1: ....22....22....
;   rows 2-8: same as frame 0
;------------------------------------------------------------------
inv_c_spr_f1:
   .byte $00,$02,$00,$00,$00,$00,$20,$00  ; row 0  antennae in
   .byte $00,$00,$22,$00,$00,$22,$00,$00  ; row 1
   .byte $00,$00,$22,$22,$22,$22,$00,$00  ; row 2  (same)
   .byte $00,$02,$22,$02,$22,$02,$20,$00  ; row 3  (same)
   .byte $00,$22,$22,$02,$22,$02,$22,$00  ; row 4  (same)
   .byte $00,$22,$22,$22,$22,$22,$22,$00  ; row 5  (same)
   .byte $00,$22,$22,$22,$22,$22,$22,$00  ; row 6  (same)
   .byte $00,$20,$22,$02,$20,$22,$02,$00  ; row 7  (same)
   .byte $00,$20,$22,$02,$20,$22,$02,$00  ; row 8  (same)
   .byte $00,$22,$22,$22,$22,$22,$22,$00  ; row 9
   .byte $00,$22,$22,$22,$22,$22,$22,$00  ; row 10
   .byte $00,$02,$02,$00,$00,$20,$20,$00  ; row 11
   .byte $00,$02,$02,$00,$00,$20,$20,$00  ; row 12
   .byte $00,$20,$00,$00,$00,$00,$02,$00  ; row 13
   .byte $00,$20,$00,$00,$00,$00,$02,$00  ; row 14
   .byte $00,$00,$00,$00,$00,$00,$00,$00  ; row 15

;******************************************************************
