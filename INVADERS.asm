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

; --- Player bullet state ---
bullet_active:  .res 1           ; 0=inactive, 1=active
bullet_x_lo:    .res 1           ; bullet X low byte (VERA coords)
bullet_x_hi:    .res 1           ; bullet X high byte
bullet_y_lo:    .res 1           ; bullet Y low byte (VERA coords)
bullet_y_hi:    .res 1           ; bullet Y high byte

; --- Score ---
score_lo:       .res 1           ; score BCD byte 0 (digits 1-2)
score_mid:      .res 1           ; score BCD byte 1 (digits 3-4)
score_hi:       .res 1           ; score BCD byte 2 (digits 5-6)

; --- Scratch for 16-bit math (collision etc.) ---
zp_scratch_lo:  .res 1
zp_scratch_hi:  .res 1

; --- Explosion ---
exp_timer:      .res 1           ; frames remaining for explosion display (0=inactive)

; --- Invader bullets (3 slots, parallel arrays) ---
ibul_active:    .res 3           ; 0=inactive, 1=active (one per slot)
ibul_x_lo:      .res 3           ; X position low byte (VERA coords)
ibul_x_hi:      .res 3           ; X position high byte
ibul_y_lo:      .res 3           ; Y position low byte (VERA coords)
ibul_y_hi:      .res 3           ; Y position high byte
inv_fire_timer: .res 1           ; frames until next fire attempt

; --- Player lives & invincibility ---
lives:          .res 1           ; remaining lives (0-3)
inv_hit_timer:  .res 1           ; invincibility frames remaining after being hit (0=vulnerable)
hi_score_lo:    .res 1           ; hi-score BCD byte 0 (digits 1-2)
hi_score_mid:   .res 1           ; hi-score BCD byte 1 (digits 3-4)
hi_score_hi:    .res 1           ; hi-score BCD byte 2 (digits 5-6)

; --- Shield state ---
shield_damage:  .res 4           ; damage level per shield: 0=intact … 3=dmg3, 4=destroyed

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
SPR_8x8_PAL0    = %00000000     ; byte 7: width=0(8px),  height=0(8px),  palette_off=0

; Explosion sprite (slot 4)
VRAM_EXPLOSION     = $00440     ; explosion pixel data (128 bytes, 16x16 4bpp)
EXPLODE_SPRITE_ATTR = $1FC20    ; sprite 4 attribute base (explosion)
EXPLODE_FRAMES     = 30         ; display duration in frames (~0.5 sec at 60 Hz)

; Invader bullets (sprite slots 5-7)
VRAM_INV_BULLET    = $00420     ; invader bullet pixel data (32 bytes, 8x8 4bpp)
INV_BULLET_SPR_BASE = $1FC28    ; sprite 5 attribute base (first invader bullet)
INV_BULLET_SPEED   = 6          ; VERA pixels per frame downward (=3 game pixels)
INV_FIRE_TIMER_MIN = 10         ; minimum frames between fire attempts
INV_FIRE_TIMER_INIT = 90        ; frames before first shot

; Player lives
LIVES_INIT         = 3          ; starting lives
INV_HIT_FRAMES     = 120        ; invincibility duration after being hit (2 sec at 60 Hz)

; Shields
SHIELD_Y           = 352        ; VERA Y coordinate for all 4 shields (176 display pixels)
SHIELD_SPR_BASE    = $1FE10     ; sprite slot 66 attr ($1FC00 + 66*8); slots 8-65 in use
VRAM_SHIELD_FULL   = $00500     ; 128-byte 16x16 4bpp tile: intact
VRAM_SHIELD_DMG1   = $00580     ; 25% damaged
VRAM_SHIELD_DMG2   = $00600     ; 50% damaged
VRAM_SHIELD_DMG3   = $00680     ; 75% damaged

; Player bullet
BULLET_SPRITE_ATTR = $1FC10     ; sprite 2 attribute base (player bullet)
VRAM_BULLET     = $00400        ; player bullet pixel data (32 bytes, 8x8 4bpp)
BULLET_SPEED    = 12            ; VERA pixels per frame upward (= 6 game pixels)
BULLET_Y_INIT   = PLAYER_Y - 8 ; bullet starts just above player ship top

; Invader grid geometry (VERA 640x480 coordinate space)
INV_GRID_X_INIT   = 112         ; left-column X at start (centered: (640 - 10*40 - 16) / 2 = 112)
INV_GRID_Y_BASE   = 80          ; top-row Y, fixed base (drops added via inv_offset_y)
INV_SPACING_X     = 40          ; VERA pixels between invader column origins
INV_SPACING_Y     = 48          ; VERA pixels between invader row origins
INV_STEP_X        = 4           ; VERA pixels per march step
INV_DROP_Y        = 16          ; VERA pixels per grid drop
INV_MOVE_SPEED_INIT = 50        ; frames between march steps (initial)
INV_COUNT_INIT    = 55
INV_MOVE_SPEED_MIN = 5           ; minimum frames per march step

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
   stz bullet_active
   stz score_lo
   stz score_mid
   stz score_hi
   stz hi_score_lo
   stz hi_score_mid
   stz hi_score_hi

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
   jsr hide_all_inv_sprites     ; hide all 55 during title screen

   jsr draw_title_screen

;------------------------------------------------------------------
; title_loop — wait for SPACE; blink "PRESS SPACE TO START"
;------------------------------------------------------------------
title_loop:
   jsr wait_vsync
   inc frame_count
   jsr update_input

   lda key_last
   cmp #KEY_RUN_STOP
   bne @tl_no_exit
   jmp exit_game
@tl_no_exit:

   lda key_flags
   and #KEY_FIRE
   bne start_game

   ; blink using frame_count bit 5 (~2 Hz)
   lda frame_count
   and #$20
   bne @tl_on
@tl_off:
   lda #17
   ldy #10
   clc
   jsr PLOT
   ldx #20                      ; erase 20 chars of "PRESS SPACE TO START"
@tl_erase: lda #' '
   jsr CHROUT
   dex
   bne @tl_erase
   jmp title_loop
@tl_on:
   lda #17
   ldy #10
   clc
   jsr PLOT
   ldx #0
@tl_print: lda str_press_space, x
   beq @tl_print_done
   jsr CHROUT
   inx
   bra @tl_print
@tl_print_done:
   jmp title_loop

start_game:
   jsr update_invader_sprites   ; re-enable all 55 invaders at grid positions
   jsr init_shields             ; upload shield tiles, init damage counters, place sprites
   lda #PETSCII_CLR
   jsr CHROUT                   ; clear title text, leave sprites visible

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

   ; --- invincibility timer ---
   lda inv_hit_timer
   beq @no_inv_dec
   dec inv_hit_timer
@no_inv_dec:

   jsr move_player               ; apply movement, clamp to boundaries
   jsr update_player_sprite      ; write new X to VERA sprite 1

   ; --- fire player bullet (SPACE pressed and bullet not already active) ---
   lda key_flags
   and #KEY_FIRE
   beq @skip_fire
   lda bullet_active
   bne @skip_fire
   jsr fire_bullet
@skip_fire:

   ; --- move bullet if active ---
   lda bullet_active
   beq @skip_bullet_move
   jsr move_bullet
@skip_bullet_move:

   ; --- check player bullet vs invader collision ---
   jsr check_bullet_invader

   ; --- check player bullet vs shield collision ---
   jsr check_bullet_shields

   ; --- explosion timer ---
   jsr update_explosion

   ; --- invader bullets: move, spawn, boundary check ---
   jsr update_inv_bullets

   ; --- invader bullet vs player collision ---
   jsr check_inv_bullet_player

   ; --- invader bullet vs shield collision ---
   jsr check_invbullet_shields

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
   lda #LIVES_INIT
   sta lives
   stz inv_hit_timer
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

   ; --- upload player bullet pixel data to VRAM $00400 ---
   VERA_SET_ADDR VRAM_BULLET, 1
   ldx #0
@up_bullet:
   lda bullet_spr_data,x
   sta VERA_data0
   inx
   cpx #32
   bne @up_bullet

   ; --- write sprite 2 attributes (initially disabled, z-depth=0) ---
   VERA_SET_ADDR BULLET_SPRITE_ATTR, 1
   lda #$20                     ; byte 0: addr[12:5] = $00400>>5 = $20
   sta VERA_data0
   lda #$00                     ; byte 1: 4bpp, addr[16:13]=0
   sta VERA_data0
   lda #$00                     ; byte 2: X lo (arbitrary; sprite disabled)
   sta VERA_data0
   lda #$00                     ; byte 3: X hi
   sta VERA_data0
   lda #$00                     ; byte 4: Y lo
   sta VERA_data0
   lda #$00                     ; byte 5: Y hi
   sta VERA_data0
   lda #$00                     ; byte 6: z-depth=0 → disabled
   sta VERA_data0
   lda #SPR_8x8_PAL0            ; byte 7: 8x8, palette 0
   sta VERA_data0

   ; --- upload explosion pixel data to VRAM $00440 ---
   VERA_SET_ADDR VRAM_EXPLOSION, 1
   ldx #0
@up_exp:
   lda explosion_pixels,x
   sta VERA_data0
   inx
   cpx #128
   bne @up_exp

   ; --- write sprite 4 attributes (initially disabled) ---
   ; addr[12:5] = VRAM_EXPLOSION>>5 = $00440>>5 = $22
   VERA_SET_ADDR EXPLODE_SPRITE_ATTR, 1
   lda #$22                     ; byte 0: addr[12:5]
   sta VERA_data0
   lda #$00                     ; byte 1: 4bpp, addr[16:13]=0
   sta VERA_data0
   lda #$00                     ; byte 2: X lo (placeholder)
   sta VERA_data0
   lda #$00                     ; byte 3: X hi
   sta VERA_data0
   lda #$00                     ; byte 4: Y lo (placeholder)
   sta VERA_data0
   lda #$00                     ; byte 5: Y hi
   sta VERA_data0
   lda #$00                     ; byte 6: z-depth=0 → disabled
   sta VERA_data0
   lda #SPR_16x16_PAL0          ; byte 7: 16x16, palette 0
   sta VERA_data0

   stz exp_timer

   ; --- upload invader bullet pixel data to VRAM $00420 ---
   VERA_SET_ADDR VRAM_INV_BULLET, 1
   ldx #0
@up_ibul:
   lda inv_bullet_spr_data,x
   sta VERA_data0
   inx
   cpx #32
   bne @up_ibul

   ; --- init 3 invader bullet sprites (slots 5-7, base $1FC28), all disabled ---
   ; addr[12:5] = VRAM_INV_BULLET>>5 = $00420>>5 = $21
   VERA_SET_ADDR INV_BULLET_SPR_BASE, 1
   ldx #3                       ; 3 sprites
@init_ibspr:
   lda #$21                     ; byte 0: addr[12:5] = $21
   sta VERA_data0
   lda #$00
   sta VERA_data0               ; byte 1: 4bpp, bank 0
   sta VERA_data0               ; byte 2: X lo
   sta VERA_data0               ; byte 3: X hi
   sta VERA_data0               ; byte 4: Y lo
   sta VERA_data0               ; byte 5: Y hi
   sta VERA_data0               ; byte 6: z-depth=0 → disabled
   sta VERA_data0               ; byte 7: 8x8, palette 0
   dex
   bne @init_ibspr

   ; --- clear invader bullet state ---
   stz ibul_active+0
   stz ibul_active+1
   stz ibul_active+2
   lda #INV_FIRE_TIMER_INIT
   sta inv_fire_timer

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

   jsr update_invader_row

   inc zp_row
   lda zp_row
   cmp #5
   bne @row_loop

   rts

;******************************************************************
; update_invader_row — write 11 sprite attribute blocks for one row
;
;   Inputs (ZP): zp_row, zp_addr_b0, zp_row_y_lo/hi, inv_grid_x_lo/hi
;   VERA address register must already be set to the first sprite slot
;   for this row on entry (maintained by the sequential write stream).
;******************************************************************
update_invader_row:
   stz zp_col
@col_loop:
   ; --- determine z-depth from alive bitmap ---
   ; index = inv_row_base[row] + col; byte = index>>3; bit = index&7
   ldy zp_row
   lda inv_row_base,y
   clc
   adc zp_col
   tay                   ; Y = invader index
   and #$07
   tax                   ; X = bit index
   lda bit_masks,x
   pha                   ; save bit mask
   tya
   lsr
   lsr
   lsr
   tay                   ; Y = byte index into inv_alive
   pla                   ; A = bit mask
   and inv_alive,y
   beq @zdepth_off
   lda #SPR_Z_FRONT
   bra @zdepth_done
@zdepth_off:
   lda #0
@zdepth_done:
   sta zp_scratch_lo     ; save z-depth before VERA stream starts

   ; --- compute sprite X = inv_grid_x + col_x_offsets[col] ---
   ldy zp_col
   lda col_x_lo,y
   clc
   adc inv_grid_x_lo
   sta zp_x_lo
   lda col_x_hi,y
   adc inv_grid_x_hi
   sta zp_x_hi

   ; --- write 8 attribute bytes (VERA auto-increments) ---
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
   lda zp_scratch_lo
   sta VERA_data0        ; byte 6: z-depth (SPR_Z_FRONT if alive, 0 if dead)
   lda #SPR_16x16_PAL0
   sta VERA_data0        ; byte 7: 16x16, palette offset 0

   inc zp_col
   lda zp_col
   cmp #11
   bne @col_loop

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
   ; update z-depth based on inv_hit_timer:
   ;   timer = 0        → show solid (not hit)
   ;   timer = 61-120   → hidden solid (1-second respawn delay)
   ;   timer = 1-60     → flashing (invincible, visible warning)
   VERA_SET_ADDR (SPRITE1_ATTR + 6), 1
   lda inv_hit_timer
   beq @show                    ; timer=0 → show solid
   cmp #61
   bcs @hide                    ; timer>=61 → first second: fully hidden
   and #$08                     ; timer 1-60: bit 3 flips every 8 frames → ~4 Hz flash
   bne @hide
@show:
   lda #SPR_Z_FRONT
   bra @write_z
@hide:
   lda #0
@write_z:
   sta VERA_data0               ; sprite byte 6: z-depth
   rts

;******************************************************************
; fire_bullet — activate player bullet at cannon tip, update sprite
;   Bullet X centers the 8-px bullet over the 16-px player ship:
;     bullet_x = player_x + 4
;   Bullet Y starts 8 VERA pixels above the player sprite top.
;   Caller must check bullet_active == 0 before calling.
;******************************************************************
fire_bullet:
   lda player_x_lo
   clc
   adc #4
   sta bullet_x_lo
   lda player_x_hi
   adc #0
   sta bullet_x_hi

   lda #<BULLET_Y_INIT
   sta bullet_y_lo
   lda #>BULLET_Y_INIT
   sta bullet_y_hi

   lda #1
   sta bullet_active
   jsr update_bullet_sprite
   rts

;******************************************************************
; move_bullet — move bullet upward by BULLET_SPEED each frame;
;   deactivate when it reaches the top of the screen (Y underflows 0)
;******************************************************************
move_bullet:
   lda bullet_y_lo
   sec
   sbc #BULLET_SPEED
   sta bullet_y_lo
   lda bullet_y_hi
   sbc #0
   sta bullet_y_hi
   bmi @deactivate              ; 16-bit underflow past 0 → off screen

   jsr update_bullet_sprite
   rts

@deactivate:
   stz bullet_active
   jsr update_bullet_sprite     ; disables sprite (z-depth=0)
   rts

;******************************************************************
; update_bullet_sprite — write bullet position and enable/disable
;   to VERA sprite 2 (bytes 2-6); byte 7 set once at init.
;   z-depth = SPR_Z_FRONT when active, 0 when inactive.
;******************************************************************
update_bullet_sprite:
   stz VERA_ctrl
   VERA_SET_ADDR (BULLET_SPRITE_ATTR + 2), 1
   lda bullet_x_lo
   sta VERA_data0               ; byte 2: X[7:0]
   lda bullet_x_hi
   and #$03
   sta VERA_data0               ; byte 3: X[9:8]
   lda bullet_y_lo
   sta VERA_data0               ; byte 4: Y[7:0]
   lda bullet_y_hi
   and #$03
   sta VERA_data0               ; byte 5: Y[9:8]
   lda bullet_active
   beq @z_off
   lda #SPR_Z_FRONT
   bra @write_z
@z_off:
   lda #$00
@write_z:
   sta VERA_data0               ; byte 6: z-depth
   rts

;******************************************************************
; check_bullet_invader — scan all 55 invaders for a hit with the player bullet
;
;   Iterates rows 0-4, columns 0-10.  Skips dead invaders.
;   For each live invader checks 16-bit AABB overlap:
;     X: bullet_x+8 > inv_x  AND  bullet_x < inv_x+16
;     Y: bullet_y+8 > inv_y  AND  bullet_y < inv_y+16
;   On hit: calls kill_invader_hit and returns immediately.
;
;   Scratch used: zp_y_base_lo/hi, zp_row_y_lo/hi, zp_x_lo/hi,
;                 zp_scratch_lo/hi, zp_row, zp_col
;******************************************************************
check_bullet_invader:
   lda bullet_active
   bne :+
   rts
:  ; precompute grid Y base = INV_GRID_Y_BASE + inv_offset_y
   lda #<INV_GRID_Y_BASE
   clc
   adc inv_offset_y
   sta zp_y_base_lo
   lda #>INV_GRID_Y_BASE
   adc #0
   sta zp_y_base_hi

   stz zp_row
@row_loop:
   ; row Y = y_base + row_y_offsets[row]
   ldy zp_row
   lda row_y_offsets,y
   clc
   adc zp_y_base_lo
   sta zp_row_y_lo
   lda #0
   adc zp_y_base_hi
   sta zp_row_y_hi

   ; --- Quick Y range check for whole row ---
   ; Need: bullet_y+8 > inv_y  AND  bullet_y < inv_y+16

   ; (1) bullet_y+8 > inv_y  →  (bullet_y+8) - inv_y > 0
   ;     result negative (bmi) means bullet above this row
   lda bullet_y_lo
   clc
   adc #8
   sta zp_scratch_lo
   lda bullet_y_hi
   adc #0
   sta zp_scratch_hi
   lda zp_scratch_lo
   sec
   sbc zp_row_y_lo
   lda zp_scratch_hi
   sbc zp_row_y_hi
   bmi @next_row         ; bullet bottom above invader top → no hit in this row

   ; (2) bullet_y < inv_y+16  →  bullet_y - (inv_y+16) < 0
   ;     result >= 0 (bpl) means bullet below this row
   lda zp_row_y_lo
   clc
   adc #16
   sta zp_scratch_lo
   lda zp_row_y_hi
   adc #0
   sta zp_scratch_hi
   lda bullet_y_lo
   sec
   sbc zp_scratch_lo
   lda bullet_y_hi
   sbc zp_scratch_hi
   bpl @next_row         ; bullet top at or below invader bottom → no hit

   ; Y overlaps this row — check each column
   jsr cbi_check_cols
   bcs @done             ; hit found; bullet already handled

@next_row:
   inc zp_row
   lda zp_row
   cmp #5
   bne @row_loop

@done:
   rts

;******************************************************************
; cbi_check_cols — column scan for check_bullet_invader
;
;   Scans all 11 columns of zp_row for an X overlap with the bullet.
;   Assumes Y overlap for this row has already been confirmed.
;   Returns: C set if hit (kill_invader_hit already called),
;            C clear if no hit.
;   Scratch used: zp_col, zp_x_lo/hi, zp_scratch_lo/hi
;******************************************************************
cbi_check_cols:
   stz zp_col
@col_loop:
   ; skip if invader is dead
   ldy zp_row
   lda inv_row_base,y
   clc
   adc zp_col
   tay                   ; Y = invader index
   and #$07
   tax
   lda bit_masks,x
   pha
   tya
   lsr
   lsr
   lsr
   tay                   ; Y = byte index into inv_alive
   pla
   and inv_alive,y
   beq @next_col         ; dead

   ; compute inv_x = inv_grid_x + col_x_offsets[col]
   ldy zp_col
   lda col_x_lo,y
   clc
   adc inv_grid_x_lo
   sta zp_x_lo
   lda col_x_hi,y
   adc inv_grid_x_hi
   sta zp_x_hi

   ; X check (1): bullet_x+8 > inv_x
   lda bullet_x_lo
   clc
   adc #8
   sta zp_scratch_lo
   lda bullet_x_hi
   adc #0
   sta zp_scratch_hi
   lda zp_scratch_lo
   sec
   sbc zp_x_lo
   lda zp_scratch_hi
   sbc zp_x_hi
   bmi @next_col         ; bullet right edge left of invader → no hit

   ; X check (2): bullet_x < inv_x+16
   lda zp_x_lo
   clc
   adc #16
   sta zp_scratch_lo
   lda zp_x_hi
   adc #0
   sta zp_scratch_hi
   lda bullet_x_lo
   sec
   sbc zp_scratch_lo
   lda bullet_x_hi
   sbc zp_scratch_hi
   bpl @next_col         ; bullet left edge at or right of invader → no hit

   ; --- HIT ---
   jsr kill_invader_hit
   sec                   ; signal hit to caller
   rts

@next_col:
   inc zp_col
   lda zp_col
   cmp #11
   bne @col_loop

   clc                   ; no hit
   rts

;******************************************************************
; kill_invader_hit — clear alive bit, deactivate bullet, update score & speed
;   Expects zp_row, zp_col to identify the hit invader.
;******************************************************************
kill_invader_hit:
   ; --- clear alive bit ---
   ldy zp_row
   lda inv_row_base,y
   clc
   adc zp_col
   tay                   ; Y = invader index
   and #$07
   tax
   lda bit_masks,x       ; bit mask for this invader
   pha
   tya
   lsr
   lsr
   lsr
   tay                   ; Y = byte index into inv_alive
   pla
   eor #$FF              ; invert → clear mask
   and inv_alive,y
   sta inv_alive,y

   ; --- start explosion at the hit invader's position ---
   ; zp_x_lo/hi and zp_row_y_lo/hi still hold the invader coords from collision detection
   jsr start_explosion

   ; --- deactivate bullet ---
   stz bullet_active
   jsr update_bullet_sprite

   ; --- decrement inv_count ---
   dec inv_count

   ; --- update inv_move_speed: proportional to remaining count ---
   ldx inv_count
   lda inv_speed_table,x
   sta inv_move_speed

   ; --- add score for this row's invader type ---
   ldy zp_row
   lda score_by_row_bcd,y
   jsr add_score
   rts

;******************************************************************
; add_score — add BCD value in A to score_lo/mid/hi
;******************************************************************
add_score:
   sed
   clc
   adc score_lo
   sta score_lo
   lda score_mid
   adc #0
   sta score_mid
   lda score_hi
   adc #0
   sta score_hi
   cld
   rts

;******************************************************************
; start_explosion — position sprite 4 at the hit invader and start timer
;
;   Inputs: zp_x_lo/hi     — invader X (VERA coords)
;           zp_row_y_lo/hi — invader Y (VERA coords)
;   Sets exp_timer = EXPLODE_FRAMES and enables sprite 4.
;******************************************************************
start_explosion:
   stz VERA_ctrl
   VERA_SET_ADDR (EXPLODE_SPRITE_ATTR + 2), 1  ; start at byte 2 (X lo)
   lda zp_x_lo
   sta VERA_data0               ; byte 2: X[7:0]
   lda zp_x_hi
   and #$03
   sta VERA_data0               ; byte 3: X[9:8]
   lda zp_row_y_lo
   sta VERA_data0               ; byte 4: Y[7:0]
   lda zp_row_y_hi
   and #$03
   sta VERA_data0               ; byte 5: Y[9:8]
   lda #SPR_Z_FRONT
   sta VERA_data0               ; byte 6: z-depth=3 → enabled, in front
   lda #EXPLODE_FRAMES
   sta exp_timer
   rts

;******************************************************************
; update_explosion — decrement exp_timer; disable sprite when it hits 0
;******************************************************************
update_explosion:
   lda exp_timer
   beq @inactive
   dec exp_timer
   bne @inactive
   ; timer just expired — disable sprite 4
   stz VERA_ctrl
   VERA_SET_ADDR (EXPLODE_SPRITE_ATTR + 6), 1  ; byte 6 = z-depth
   lda #$00
   sta VERA_data0               ; z-depth=0 → disabled
@inactive:
   rts

;******************************************************************
; prng — 16-bit Galois LFSR, feedback polynomial $B400
;   Updates rand_seed_lo/hi; returns pseudo-random byte in A.
;******************************************************************
prng:
   lsr rand_seed_hi          ; shift 16-bit state right; carry = old hi[0]
   ror rand_seed_lo          ; lo[7] = old hi[0]; carry = old lo[0] (feedback bit)
   bcc @done                 ; feedback bit=0: no XOR
   lda rand_seed_hi
   eor #$B4                  ; XOR hi byte with feedback poly ($B400 >> 8)
   sta rand_seed_hi
@done:
   lda rand_seed_lo
   rts

;******************************************************************
; update_inv_bullets — fire timer, move active bullets, boundary check,
;   update VERA sprites for all 3 invader bullet slots.
;******************************************************************
update_inv_bullets:
   ; --- fire timer ---
   dec inv_fire_timer
   bne @move_loop
   ; reset timer = max(inv_move_speed, INV_FIRE_TIMER_MIN)
   lda inv_move_speed
   cmp #INV_FIRE_TIMER_MIN
   bcs @set_timer
   lda #INV_FIRE_TIMER_MIN
@set_timer:
   sta inv_fire_timer
   jsr try_fire_inv_bullet

@move_loop:
   ldx #0
@slot_loop:
   lda ibul_active,x
   beq @update_spr           ; inactive: just hide sprite

   ; move bullet down by INV_BULLET_SPEED
   lda ibul_y_lo,x
   clc
   adc #INV_BULLET_SPEED
   sta ibul_y_lo,x
   lda ibul_y_hi,x
   adc #0
   sta ibul_y_hi,x

   ; boundary: deactivate if Y >= 480 ($01E0)
   cmp #>480                 ; A = new hi byte; compare with 1
   bcc @update_spr           ; hi < 1: still on screen
   bne @deactivate           ; hi > 1: off screen
   lda ibul_y_lo,x
   cmp #<480                 ; compare lo with $E0
   bcc @update_spr           ; lo < $E0: still on screen
@deactivate:
   stz ibul_active,x

@update_spr:
   jsr update_inv_bullet_sprite   ; preserves X
   inx
   cpx #3
   bne @slot_loop
   rts

;******************************************************************
; update_inv_bullet_sprite — write VERA sprite attrs bytes 2-6 for slot X
;   X = slot index (0-2).  Preserves X.
;******************************************************************
update_inv_bullet_sprite:
   stx zp_scratch_lo              ; preserve slot index
   stz VERA_ctrl
   lda #$11                       ; stride=1, bank bit=1
   sta VERA_addr_bank
   lda #$FC
   sta VERA_addr_high
   lda ibul_spr_lo,x
   clc
   adc #2                         ; point to byte 2 (X position)
   sta VERA_addr_low
   lda ibul_x_lo,x
   sta VERA_data0                 ; byte 2: X lo
   lda ibul_x_hi,x
   and #$03
   sta VERA_data0                 ; byte 3: X hi
   lda ibul_y_lo,x
   sta VERA_data0                 ; byte 4: Y lo
   lda ibul_y_hi,x
   and #$03
   sta VERA_data0                 ; byte 5: Y hi
   lda ibul_active,x
   beq @disabled
   lda #SPR_Z_FRONT
   bra @write_z
@disabled:
   lda #0
@write_z:
   sta VERA_data0                 ; byte 6: z-depth
   ldx zp_scratch_lo
   rts

;******************************************************************
; try_fire_inv_bullet — find a free slot and spawn a bullet from the
;   bottommost live invader in a randomly chosen column.
;   Returns immediately if all slots busy or chosen column is empty.
;   Scratch used: zp_row, zp_col, zp_scratch_lo (slot index)
;******************************************************************
try_fire_inv_bullet:
   ; find a free bullet slot
   ldx #0
@find_slot:
   lda ibul_active,x
   beq @slot_found
   inx
   cpx #3
   bne @find_slot
   rts                            ; all slots busy

@slot_found:
   stx zp_scratch_lo              ; save free slot index

   ; pick a random column 0-10
   jsr prng
   and #$0F                       ; 0-15
   cmp #11
   bcc @col_ok
   sec
   sbc #11                        ; wrap 11-15 → 0-4 (slight bias, acceptable)
@col_ok:
   sta zp_col

   ; scan rows 4 down to 0 for bottommost live invader in this column
   lda #4
   sta zp_row
@row_scan:
   ldy zp_row
   lda inv_row_base,y
   clc
   adc zp_col
   tay                            ; Y = invader index
   and #$07
   tax                            ; X = bit position
   lda bit_masks,x
   pha
   tya
   lsr
   lsr
   lsr
   tay                            ; Y = byte index into inv_alive
   pla
   and inv_alive,y
   bne @found_invader
   lda zp_row
   beq @no_invader                ; checked row 0, nothing alive
   dec zp_row
   bra @row_scan

@no_invader:
   rts                            ; column empty, skip fire

@found_invader:
   ldx zp_scratch_lo              ; restore free slot index
   lda #1
   sta ibul_active,x

   ; spawn X = inv_grid_x + col_x_offsets[col]  (16-bit, matching update_invader_sprites)
   ldy zp_col
   lda col_x_lo,y
   clc
   adc inv_grid_x_lo
   sta ibul_x_lo,x
   lda col_x_hi,y
   adc inv_grid_x_hi
   sta ibul_x_hi,x
   ; add +4 as a separate 16-bit step to centre the 8px bullet in the 16px invader
   lda ibul_x_lo,x
   clc
   adc #4
   sta ibul_x_lo,x
   lda ibul_x_hi,x
   adc #0
   sta ibul_x_hi,x

   ; spawn Y: compute y_base first (same two-step pattern as update_invader_sprites)
   ; step 1: y_base = INV_GRID_Y_BASE + inv_offset_y  (16-bit)
   lda #<INV_GRID_Y_BASE
   clc
   adc inv_offset_y
   sta zp_y_base_lo
   lda #>INV_GRID_Y_BASE
   adc #0
   sta zp_y_base_hi
   ; step 2: spawn_y = y_base + row_y_offsets[row]
   ldy zp_row
   lda row_y_offsets,y
   clc
   adc zp_y_base_lo
   sta ibul_y_lo,x
   lda #0
   adc zp_y_base_hi
   sta ibul_y_hi,x
   ; step 3: +16 to place bullet at the bottom edge of the 16px invader
   lda ibul_y_lo,x
   clc
   adc #16
   sta ibul_y_lo,x
   lda ibul_y_hi,x
   adc #0
   sta ibul_y_hi,x

   rts

;******************************************************************
; check_inv_bullet_player — AABB test each active invader bullet vs. player
;
;   Player rect: (player_x, PLAYER_Y) to (player_x+15, PLAYER_Y+15), 16x16
;   Bullet rect: (ibul_x,   ibul_y)   to (ibul_x+7,   ibul_y+7),     8x8
;
;   On hit: bullet deactivated, jsr player_hit called, loop continues
;   (remaining bullets checked — at most one hit landing per frame).
;   Scratch: zp_scratch_lo/hi, X (slot index)
;******************************************************************
check_inv_bullet_player:
   ldx #0
@slot_loop:
   lda ibul_active,x
   beq @next_slot

   ; --- Y check 1: (bullet_y + 8) > PLAYER_Y  →  bullet_y + 8 - PLAYER_Y > 0 ---
   lda ibul_y_lo,x
   clc
   adc #8
   sta zp_scratch_lo
   lda ibul_y_hi,x
   adc #0
   sta zp_scratch_hi
   lda zp_scratch_lo
   sec
   sbc #<PLAYER_Y
   lda zp_scratch_hi
   sbc #>PLAYER_Y
   bmi @next_slot            ; bullet bottom above player top → no hit

   ; --- Y check 2: bullet_y < PLAYER_Y + 16 → bullet_y - (PLAYER_Y+16) < 0 ---
   lda ibul_y_lo,x
   sec
   sbc #<(PLAYER_Y+16)
   lda ibul_y_hi,x
   sbc #>(PLAYER_Y+16)
   bpl @next_slot            ; bullet top at or below player bottom → no hit

   ; --- X check 1: (bullet_x + 8) > player_x ---
   lda ibul_x_lo,x
   clc
   adc #8
   sta zp_scratch_lo
   lda ibul_x_hi,x
   adc #0
   sta zp_scratch_hi
   lda zp_scratch_lo
   sec
   sbc player_x_lo
   lda zp_scratch_hi
   sbc player_x_hi
   bmi @next_slot            ; bullet right edge left of player → no hit

   ; --- X check 2: bullet_x < player_x + 16 ---
   lda player_x_lo
   clc
   adc #16
   sta zp_scratch_lo
   lda player_x_hi
   adc #0
   sta zp_scratch_hi
   lda ibul_x_lo,x
   sec
   sbc zp_scratch_lo
   lda ibul_x_hi,x
   sbc zp_scratch_hi
   bpl @next_slot            ; bullet left edge at or right of player → no hit

   ; --- HIT ---
   stz ibul_active,x         ; deactivate this bullet
   jsr update_inv_bullet_sprite
   jsr player_hit

@next_slot:
   inx
   cpx #3
   bne @slot_loop
   rts

;******************************************************************
; player_hit — handle a bullet-player collision:
;   explosion at player position, decrement lives, respawn, invincibility
;******************************************************************
player_hit:
   ; start explosion at player position
   lda player_x_lo
   sta zp_x_lo
   lda player_x_hi
   sta zp_x_hi
   lda #<PLAYER_Y
   sta zp_row_y_lo
   lda #>PLAYER_Y
   sta zp_row_y_hi
   jsr start_explosion

   ; decrement lives
   dec lives
   beq @game_over            ; lives hit 0 → end game (Phase 6 will handle this properly)

   ; grant invincibility and re-centre the ship
   lda #INV_HIT_FRAMES
   sta inv_hit_timer
   lda #<PLAYER_X_INIT
   sta player_x_lo
   lda #>PLAYER_X_INIT
   sta player_x_hi
   rts

@game_over:
   jmp exit_game             ; placeholder: Phase 6 will show a game-over screen

;******************************************************************
; draw_title_screen — paint the title screen; called once before title_loop
;
;   Layout (40-col text, VERA Y=row*16):
;     Row  1, col 14: "X16 INVADERS"      (12 chars, centred)
;     Row  3, col 16: "HI-SCORE"          (8 chars, centred)
;     Row  4, col 17: 000000              (6-digit BCD hi-score)
;     Row  5, col  5: "?UFO? = ??? PTS"
;     Row  7, col  9: "= 30 PTS"          + Type C sprite at X=96,Y=112
;     Row 10, col  9: "= 20 PTS"          + Type B sprite at X=96,Y=160
;     Row 13, col  9: "= 10 PTS"          + Type A sprite at X=96,Y=208
;     Row 17, col 10: (PRESS SPACE TO START — blinked by title_loop)
;     Row 19, col 12: "RUN/STOP TO QUIT"
;******************************************************************
draw_title_screen:
   ; Row 1, col 14: "X16 INVADERS"
   lda #1
   ldy #14
   clc
   jsr PLOT
   ldx #0
@lp1: lda str_title_main, x
   beq @lp1_done
   jsr CHROUT
   inx
   bra @lp1
@lp1_done:

   ; Row 3, col 16: "HI-SCORE"
   lda #3
   ldy #16
   clc
   jsr PLOT
   ldx #0
@lp2: lda str_hi_score_lbl, x
   beq @lp2_done
   jsr CHROUT
   inx
   bra @lp2
@lp2_done:

   ; Row 4, col 17: hi-score 6 BCD digits (000000 at start)
   lda #4
   ldy #17
   clc
   jsr PLOT
   lda hi_score_hi
   jsr print_hex_byte
   lda hi_score_mid
   jsr print_hex_byte
   lda hi_score_lo
   jsr print_hex_byte

   ; Row 5, col 5: "?UFO? = ??? PTS"
   lda #5
   ldy #5
   clc
   jsr PLOT
   ldx #0
@lp3: lda str_ufo_score, x
   beq @lp3_done
   jsr CHROUT
   inx
   bra @lp3
@lp3_done:

   ; Sample invader sprites (Types C, B, A) + score labels
   jsr show_title_sprites

   ; Row 19, col 12: "RUN/STOP TO QUIT"
   lda #19
   ldy #12
   clc
   jsr PLOT
   ldx #0
@lp4: lda str_run_stop_hint, x
   beq @lp4_done
   jsr CHROUT
   inx
   bra @lp4
@lp4_done:

   rts

;******************************************************************
; show_title_sprites — enable one sprite of each type at fixed
;   title-screen positions and print score labels beside them.
;
;   In VERA 640x480 space, 1 text row/col = 16 VERA pixels.
;   Sprites: X=96 (col 6), score labels at col 9.
;   Sprite 11 (Type C): Y=112 → text row 7,  "= 30 PTS"
;   Sprite 22 (Type B): Y=160 → text row 10, "= 20 PTS"
;   Sprite 44 (Type A): Y=208 → text row 13, "= 10 PTS"
;******************************************************************
show_title_sprites:
   stz VERA_ctrl
   ; --- sprite 11 (Type C, squid/cyan): attr $1FC00+11*8=$1FC58 ---
   ; addr[12:5] = VRAM_INV_C_F0>>5 = $00300>>5 = $18
   lda #$11               ; stride=1, bank=1
   sta VERA_addr_bank
   lda #$FC
   sta VERA_addr_high
   lda #$58               ; low byte of $1FC58
   sta VERA_addr_low
   lda #$18               ; byte 0: data addr[12:5]
   sta VERA_data0
   lda #$00               ; byte 1: 4bpp, addr[16:13]=0
   sta VERA_data0
   lda #96                ; byte 2: X lo
   sta VERA_data0
   lda #0                 ; byte 3: X hi
   sta VERA_data0
   lda #112               ; byte 4: Y lo (row 7: 7*16=112)
   sta VERA_data0
   lda #0                 ; byte 5: Y hi
   sta VERA_data0
   lda #SPR_Z_FRONT       ; byte 6: z-depth=3
   sta VERA_data0
   lda #SPR_16x16_PAL0    ; byte 7: 16x16, palette 0
   sta VERA_data0

   lda #7
   ldy #9
   clc
   jsr PLOT
   ldx #0
@lp_c: lda str_score_c, x
   beq @lp_c_done
   jsr CHROUT
   inx
   bra @lp_c
@lp_c_done:

   ; --- sprite 22 (Type B, octopus/magenta): attr $1FC00+22*8=$1FCB0 ---
   ; addr[12:5] = VRAM_INV_B_F0>>5 = $00200>>5 = $10
   lda #$11
   sta VERA_addr_bank
   lda #$FC
   sta VERA_addr_high
   lda #$B0               ; low byte of $1FCB0
   sta VERA_addr_low
   lda #$10               ; byte 0: addr[12:5]
   sta VERA_data0
   lda #$00
   sta VERA_data0
   lda #96                ; X
   sta VERA_data0
   lda #0
   sta VERA_data0
   lda #160               ; Y (row 10: 10*16=160)
   sta VERA_data0
   lda #0
   sta VERA_data0
   lda #SPR_Z_FRONT
   sta VERA_data0
   lda #SPR_16x16_PAL0
   sta VERA_data0

   lda #10
   ldy #9
   clc
   jsr PLOT
   ldx #0
@lp_b: lda str_score_b, x
   beq @lp_b_done
   jsr CHROUT
   inx
   bra @lp_b
@lp_b_done:

   ; --- sprite 44 (Type A, crab/green): attr $1FC00+44*8=$1FD60 ---
   ; addr[12:5] = VRAM_INV_A_F0>>5 = $00100>>5 = $08
   lda #$11
   sta VERA_addr_bank
   lda #$FD               ; high byte of $1FD60
   sta VERA_addr_high
   lda #$60               ; low byte of $1FD60
   sta VERA_addr_low
   lda #$08               ; byte 0: addr[12:5]
   sta VERA_data0
   lda #$00
   sta VERA_data0
   lda #96                ; X
   sta VERA_data0
   lda #0
   sta VERA_data0
   lda #208               ; Y (row 13: 13*16=208)
   sta VERA_data0
   lda #0
   sta VERA_data0
   lda #SPR_Z_FRONT
   sta VERA_data0
   lda #SPR_16x16_PAL0
   sta VERA_data0

   lda #13
   ldy #9
   clc
   jsr PLOT
   ldx #0
@lp_a: lda str_score_a, x
   beq @lp_a_done
   jsr CHROUT
   inx
   bra @lp_a
@lp_a_done:

   rts

;******************************************************************
; hide_all_inv_sprites — set z-depth=0 for all 55 invader sprites
;   Uses VERA stride=8 to write only byte 6 (z-depth) of each block.
;   First invader sprite byte 6: $1FC00 + 11*8 + 6 = $1FC5E
;******************************************************************
hide_all_inv_sprites:
   stz VERA_ctrl
   lda #$41               ; stride=8 (code $4 in high nibble), bank=1
   sta VERA_addr_bank
   lda #$FC
   sta VERA_addr_high
   lda #$5E               ; low byte of $1FC5E  ($1FC58+6)
   sta VERA_addr_low
   lda #0                 ; z-depth=0 → disabled
   ldx #55
@loop:
   sta VERA_data0         ; writes byte 6; addr auto-advances by 8
   dex
   bne @loop
   rts

;******************************************************************
; init_shields — upload 4 damage tiles, set palette entry 7 to dark
;   green, init shield_damage counters, write sprite attributes for
;   all 4 shields (slots 66–69, base $1FE10).
;
;   Sprite positions: X = shield_x_lo/hi[n], Y = SHIELD_Y (352)
;   Each shield sprite: 16x16, palette 0 (entry 7 = dark green).
;******************************************************************
init_shields:
   stz VERA_ctrl

   ; --- palette entry 7 → dark green (R=0, G=$A, B=0) ---
   ; Palette byte 0: G[3:0] B[3:0] = $A0;  byte 1: R[3:0] = $00
   VERA_SET_ADDR (VRAM_palette + 14), 1   ; entry 7 = offset 14 bytes
   lda #$A0
   sta VERA_data0
   lda #$00
   sta VERA_data0

   ; --- upload shield_tile_full → $00500 ---
   VERA_SET_ADDR VRAM_SHIELD_FULL, 1
   ldx #128
@up_s0: lda shield_tile_full - 128, x
   sta VERA_data0
   inx
   bne @up_s0

   ; --- upload shield_tile_dmg1 → $00580 ---
   VERA_SET_ADDR VRAM_SHIELD_DMG1, 1
   ldx #128
@up_s1: lda shield_tile_dmg1 - 128, x
   sta VERA_data0
   inx
   bne @up_s1

   ; --- upload shield_tile_dmg2 → $00600 ---
   VERA_SET_ADDR VRAM_SHIELD_DMG2, 1
   ldx #128
@up_s2: lda shield_tile_dmg2 - 128, x
   sta VERA_data0
   inx
   bne @up_s2

   ; --- upload shield_tile_dmg3 → $00680 ---
   VERA_SET_ADDR VRAM_SHIELD_DMG3, 1
   ldx #128
@up_s3: lda shield_tile_dmg3 - 128, x
   sta VERA_data0
   inx
   bne @up_s3

   ; --- reset damage counters ---
   stz shield_damage+0
   stz shield_damage+1
   stz shield_damage+2
   stz shield_damage+3

   ; --- write sprite attributes for 4 shields (sequential VERA write) ---
   ; Slots 66–69: $1FE10, $1FE18, $1FE20, $1FE28  (high=$FE, bank=1)
   lda #$11               ; stride=1, bank=1
   sta VERA_addr_bank
   lda #$FE
   sta VERA_addr_high
   lda #$10               ; low byte of $1FE10
   sta VERA_addr_low

   ldx #0
@spr_init:
   lda #$28               ; byte 0: addr[12:5] = VRAM_SHIELD_FULL>>5 = $00500>>5
   sta VERA_data0
   lda #$00               ; byte 1: 4bpp, addr[16:13]=0
   sta VERA_data0
   lda shield_x_lo, x     ; byte 2: X lo
   sta VERA_data0
   lda shield_x_hi, x     ; byte 3: X hi
   sta VERA_data0
   lda #<SHIELD_Y         ; byte 4: Y lo
   sta VERA_data0
   lda #>SHIELD_Y         ; byte 5: Y hi
   sta VERA_data0
   lda #SPR_Z_FRONT       ; byte 6: z-depth=3 (in front of all layers)
   sta VERA_data0
   lda #SPR_16x16_PAL0    ; byte 7: 16x16, palette 0
   sta VERA_data0
   inx
   cpx #4
   bne @spr_init

   rts

;******************************************************************
; update_shield_sprite — write new data-addr byte to shield sprite N
;   Input:  X = shield index (0–3)
;           shield_damage[X] = current damage level (1–3)
;   Writes sprite byte 0 (addr[12:5]) using shield_addr_b0 lookup.
;   VERA addr for byte 0 of sprite N: $1FE10 + N*8
;******************************************************************
update_shield_sprite:
   stz VERA_ctrl
   lda #$11               ; stride=1, bank=1
   sta VERA_addr_bank
   lda #$FE
   sta VERA_addr_high
   txa                    ; A = shield index
   asl                    ; ×2
   asl                    ; ×4
   asl                    ; ×8
   clc
   adc #$10               ; + low byte of $1FE10
   sta VERA_addr_low
   ldy shield_damage, x   ; Y = damage level (1-3)
   lda shield_addr_b0, y  ; addr[12:5] for this tile
   sta VERA_data0
   rts

;******************************************************************
; hide_shield_sprite — disable sprite for shield N (z-depth=0)
;   Input: X = shield index (0–3)
;   Writes sprite byte 6 at $1FE10 + N*8 + 6 = $1FE16 + N*8
;******************************************************************
hide_shield_sprite:
   stz VERA_ctrl
   lda #$11
   sta VERA_addr_bank
   lda #$FE
   sta VERA_addr_high
   txa
   asl
   asl
   asl
   clc
   adc #$16               ; low($1FE10) + 6 = $16, + N*8
   sta VERA_addr_low
   lda #0                 ; z-depth=0 → sprite disabled
   sta VERA_data0
   rts

;******************************************************************
; damage_shield — increment damage counter for shield X and update
;   sprite (or disable it when counter reaches 4 = destroyed).
;   Input:  X = shield index (0–3)
;   Clobbers: A, Y, VERA registers.  Preserves X.
;******************************************************************
damage_shield:
   inc shield_damage, x
   lda shield_damage, x
   cmp #4
   beq @destroy
   bcs @done              ; already at 4 (safety guard)
   jsr update_shield_sprite
   rts
@destroy:
   jsr hide_shield_sprite
@done:
   rts

;******************************************************************
; check_bullet_shields — test active player bullet vs all 4 shields
;
;   Overlap condition (AABB, all values VERA 16-bit):
;     X: bullet_x+8 > shield_x  AND  bullet_x < shield_x+16
;     Y: bullet_y+8 > SHIELD_Y  AND  bullet_y < SHIELD_Y+16
;
;   On hit: calls damage_shield, deactivates bullet, returns.
;   Scratch used: zp_scratch_lo/hi.  Preserves nothing.
;******************************************************************
check_bullet_shields:
   lda bullet_active
   beq @done

   ; --- Y quick check (same band for all shields) ---
   ; (1) bullet_y+8 > SHIELD_Y
   lda bullet_y_lo
   clc
   adc #8
   sta zp_scratch_lo
   lda bullet_y_hi
   adc #0
   sta zp_scratch_hi
   lda zp_scratch_lo
   sec
   sbc #<SHIELD_Y
   lda zp_scratch_hi
   sbc #>SHIELD_Y
   bmi @done              ; bullet bottom above shield top

   ; (2) bullet_y < SHIELD_Y+16
   lda bullet_y_lo
   sec
   sbc #<(SHIELD_Y + 16)
   lda bullet_y_hi
   sbc #>(SHIELD_Y + 16)
   bpl @done              ; bullet top at or below shield bottom

   ; --- Y overlaps: scan each shield ---
   ldx #0
@sld_loop:
   lda shield_damage, x
   cmp #4
   beq @next_sld          ; destroyed, skip

   ; X check (1): bullet_x+8 > shield_x[x]
   lda bullet_x_lo
   clc
   adc #8
   sta zp_scratch_lo
   lda bullet_x_hi
   adc #0
   sta zp_scratch_hi
   lda zp_scratch_lo
   sec
   sbc shield_x_lo, x
   lda zp_scratch_hi
   sbc shield_x_hi, x
   bmi @next_sld

   ; X check (2): bullet_x < shield_x[x]+16
   lda shield_x_lo, x
   clc
   adc #16
   sta zp_scratch_lo
   lda shield_x_hi, x
   adc #0
   sta zp_scratch_hi
   lda bullet_x_lo
   sec
   sbc zp_scratch_lo
   lda bullet_x_hi
   sbc zp_scratch_hi
   bpl @next_sld

   ; --- HIT ---
   jsr damage_shield      ; X = shield index
   stz bullet_active
   jsr update_bullet_sprite
   rts

@next_sld:
   inx
   cpx #4
   bne @sld_loop
@done:
   rts

;******************************************************************
; check_invbullet_shields — test each active invader bullet vs all
;   4 shields.  Same AABB logic as check_bullet_shields but loops
;   over 3 bullet slots (ibul_active / ibul_x / ibul_y arrays).
;
;   Scratch: zp_scratch_lo/hi, zp_row (bullet slot index),
;            zp_col (shield index during inner scan).
;******************************************************************
check_invbullet_shields:
   ldx #0                 ; outer loop: invader bullet slot
@ibul_loop:
   stx zp_row             ; save slot before any branch
   lda ibul_active, x
   beq @next_ibul

   ; --- Y quick check ---
   ; (1) ibul_y+8 > SHIELD_Y
   lda ibul_y_lo, x
   clc
   adc #8
   sta zp_scratch_lo
   lda ibul_y_hi, x
   adc #0
   sta zp_scratch_hi
   lda zp_scratch_lo
   sec
   sbc #<SHIELD_Y
   lda zp_scratch_hi
   sbc #>SHIELD_Y
   bmi @next_ibul

   ; (2) ibul_y < SHIELD_Y+16
   ldx zp_row
   lda ibul_y_lo, x
   sec
   sbc #<(SHIELD_Y + 16)
   lda ibul_y_hi, x
   sbc #>(SHIELD_Y + 16)
   bpl @next_ibul

   ; --- Y overlaps: scan shields with Y register ---
   ldy #0
@sld_scan:
   lda shield_damage, y
   cmp #4
   beq @next_sld_y        ; destroyed

   ; X check (1): ibul_x+8 > shield_x[y]
   ldx zp_row
   lda ibul_x_lo, x
   clc
   adc #8
   sta zp_scratch_lo
   lda ibul_x_hi, x
   adc #0
   sta zp_scratch_hi
   lda zp_scratch_lo
   sec
   sbc shield_x_lo, y
   lda zp_scratch_hi
   sbc shield_x_hi, y
   bmi @next_sld_y

   ; X check (2): ibul_x < shield_x[y]+16
   lda shield_x_lo, y
   clc
   adc #16
   sta zp_scratch_lo
   lda shield_x_hi, y
   adc #0
   sta zp_scratch_hi
   ldx zp_row
   lda ibul_x_lo, x
   sec
   sbc zp_scratch_lo
   lda ibul_x_hi, x
   sbc zp_scratch_hi
   bpl @next_sld_y

   ; --- HIT ---
   tya                    ; shield index → A → X for damage_shield
   tax
   jsr damage_shield
   ldx zp_row             ; restore bullet slot
   stz ibul_active, x
   jsr update_inv_bullet_sprite
   ldx zp_row
   bra @next_ibul         ; done with this bullet

@next_sld_y:
   iny
   cpy #4
   bne @sld_scan

@next_ibul:
   ldx zp_row
   inx
   cpx #3
   beq @cis_done
   jmp @ibul_loop
@cis_done:
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
str_title_main:
   .byte "X16 INVADERS", 0
str_hi_score_lbl:
   .byte "HI-SCORE", 0
str_ufo_score:
   .byte "?UFO? = ??? PTS", 0
str_score_c:
   .byte "= 30 PTS", 0
str_score_b:
   .byte "= 20 PTS", 0
str_score_a:
   .byte "= 10 PTS", 0
str_press_space:
   .byte "PRESS SPACE TO START", 0
str_run_stop_hint:
   .byte "RUN/STOP TO QUIT", 0
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
; bullet_spr_data — 8x8 4bpp, 32 bytes
;
;   Color 0 = transparent, Color 1 = white
;   Design: 2-pixel-wide vertical bar, centered in 8px columns 3-4
;
;   Each byte encodes 2 pixels: high nibble = left, low nibble = right
;   Columns:  0 1 | 2 3 | 4 5 | 6 7
;   Pattern:  . . | . 1 | 1 . | . .   → $00 $01 $10 $00
;   All 8 rows identical.
;******************************************************************
bullet_spr_data:
   .byte $00,$01,$10,$00  ; row 0
   .byte $00,$01,$10,$00  ; row 1
   .byte $00,$01,$10,$00  ; row 2
   .byte $00,$01,$10,$00  ; row 3
   .byte $00,$01,$10,$00  ; row 4
   .byte $00,$01,$10,$00  ; row 5
   .byte $00,$01,$10,$00  ; row 6
   .byte $00,$01,$10,$00  ; row 7

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

; row * 11 base index into inv_alive bitmap (rows 0-4)
inv_row_base:   .byte   0, 11, 22, 33, 44

; single-bit masks for bits 0-7
bit_masks:      .byte   1,  2,  4,  8, 16, 32, 64,128

; BCD score per invader row (row 0=Type C, rows 1-2=Type B, rows 3-4=Type A)
score_by_row_bcd: .byte $30, $20, $20, $10, $10

; March speed (frames/step) indexed by remaining invader count (0-55).
; Formula: floor(5 + n*45/55) — speed=5 at 0-1 alive, speed=50 at 55 alive.
inv_speed_table:
   .byte  5,  5,  6,  7,  8,  9,  9, 10, 11, 12, 13, 14   ; n=0-11
   .byte 14, 15, 16, 17, 18, 18, 19, 20, 21, 22, 23, 23   ; n=12-23
   .byte 24, 25, 26, 27, 27, 28, 29, 30, 31, 32, 32, 33   ; n=24-35
   .byte 34, 35, 36, 36, 37, 38, 39, 40, 41, 41, 42, 43   ; n=36-47
   .byte 44, 45, 45, 46, 47, 48, 49, 50                   ; n=48-55

; VERA sprite-attribute low-byte for each invader bullet slot (0-2)
; Sprite 5=$1FC28, 6=$1FC30, 7=$1FC38 — high byte always $FC
ibul_spr_lo:    .byte $28, $30, $38

; Shield X positions (4 shields evenly spread across play field, VERA coords)
; Display pixels: 40, 120, 200, 280  (every 80 display px / 160 VERA px)
shield_x_lo:    .byte <80,  <240, <400, <560
shield_x_hi:    .byte >80,  >240, >400, >560

; Shield sprite data addr[12:5] for each damage level (0=full … 3=dmg3)
; VRAM_SHIELD_FULL=$00500>>5=$28  DMG1=$00580>>5=$2C  DMG2=$00600>>5=$30  DMG3=$00680>>5=$34
shield_addr_b0: .byte $28, $2C, $30, $34

;******************************************************************
; Invader bullet sprite pixel data — 8x8 4bpp, 32 bytes
; Zigzag pattern, colour 1 (white).  Each byte = 2 pixels (hi=left, lo=right).
;******************************************************************
inv_bullet_spr_data:
   .byte $00,$10,$00,$00   ; row 0: . . 1 . | . . . .
   .byte $00,$10,$00,$00   ; row 1
   .byte $00,$01,$00,$00   ; row 2: . . . 1 | . . . .
   .byte $00,$01,$00,$00   ; row 3
   .byte $00,$10,$00,$00   ; row 4
   .byte $00,$10,$00,$00   ; row 5
   .byte $00,$01,$00,$00   ; row 6
   .byte $00,$01,$00,$00   ; row 7

;******************************************************************
; Explosion sprite pixel data — 16x16 4bpp, 128 bytes
; Color 1 = white (bright core), Color 6 = yellow (burst), 0 = transparent
; Starburst pattern, symmetric about centre.
;******************************************************************
; Color indices: 1=white (core), 7=yellow (burst, KERNAL default palette entry 7)
explosion_pixels:
   .byte $00,$00,$07,$00,$00,$70,$00,$00   ; row  0
   .byte $00,$07,$00,$07,$70,$00,$70,$00   ; row  1
   .byte $00,$70,$07,$00,$00,$70,$07,$00   ; row  2
   .byte $07,$00,$00,$77,$77,$00,$00,$70   ; row  3
   .byte $00,$00,$77,$71,$17,$77,$00,$00   ; row  4
   .byte $70,$70,$71,$11,$11,$17,$07,$07   ; row  5
   .byte $00,$07,$71,$11,$11,$17,$70,$00   ; row  6
   .byte $07,$77,$71,$11,$11,$17,$77,$70   ; row  7
   .byte $07,$77,$71,$11,$11,$17,$77,$70   ; row  8
   .byte $00,$07,$71,$11,$11,$17,$70,$00   ; row  9
   .byte $70,$70,$71,$11,$11,$17,$07,$07   ; row 10
   .byte $00,$00,$77,$71,$17,$77,$00,$00   ; row 11
   .byte $07,$00,$00,$77,$77,$00,$00,$70   ; row 12
   .byte $00,$70,$07,$00,$00,$70,$07,$00   ; row 13
   .byte $00,$07,$00,$07,$70,$00,$70,$00   ; row 14
   .byte $00,$00,$07,$00,$00,$70,$00,$00   ; row 15

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
; Shield sprite pixel data — 16x16 4bpp, 128 bytes each
;
;   Color 0 = transparent, Color 7 = dark green (palette entry 7,
;   set to dark green by init_shields).
;   Each byte encodes 2 pixels: high nibble = left, low nibble = right.
;
;   Damage progression: each level erodes 4 more rows from the top,
;   replacing solid color-7 pixels with a 2-pixel checkerboard of
;   color 7 and transparent.  Rows not yet eroded remain solid.
;
;   Checker A (odd bits lit):  $70 $07 $70 $07 $70 $07 $70 $07
;   Checker B (even bits lit): $07 $70 $07 $70 $07 $70 $07 $70
;   Solid row:                 $77 $77 $77 $77 $77 $77 $77 $77
;
;   shield_tile_full:  0  eroded rows (all 16 solid)
;   shield_tile_dmg1:  4  eroded rows (rows 0–3  checker, 4–15 solid)
;   shield_tile_dmg2:  8  eroded rows (rows 0–7  checker, 8–15 solid)
;   shield_tile_dmg3: 12  eroded rows (rows 0–11 checker, 12–15 solid)
;******************************************************************

shield_tile_full:
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row  0
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row  1
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row  2
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row  3
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row  4
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row  5
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row  6
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row  7
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row  8
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row  9
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row 10
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row 11
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row 12
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row 13
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row 14
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row 15

shield_tile_dmg1:
   .byte $70,$07,$70,$07,$70,$07,$70,$07  ; row  0  checker A
   .byte $07,$70,$07,$70,$07,$70,$07,$70  ; row  1  checker B
   .byte $70,$07,$70,$07,$70,$07,$70,$07  ; row  2  checker A
   .byte $07,$70,$07,$70,$07,$70,$07,$70  ; row  3  checker B
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row  4  solid
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row  5
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row  6
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row  7
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row  8
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row  9
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row 10
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row 11
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row 12
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row 13
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row 14
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row 15

shield_tile_dmg2:
   .byte $70,$07,$70,$07,$70,$07,$70,$07  ; row  0  checker A
   .byte $07,$70,$07,$70,$07,$70,$07,$70  ; row  1  checker B
   .byte $70,$07,$70,$07,$70,$07,$70,$07  ; row  2
   .byte $07,$70,$07,$70,$07,$70,$07,$70  ; row  3
   .byte $70,$07,$70,$07,$70,$07,$70,$07  ; row  4  checker A
   .byte $07,$70,$07,$70,$07,$70,$07,$70  ; row  5  checker B
   .byte $70,$07,$70,$07,$70,$07,$70,$07  ; row  6
   .byte $07,$70,$07,$70,$07,$70,$07,$70  ; row  7
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row  8  solid
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row  9
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row 10
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row 11
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row 12
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row 13
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row 14
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row 15

shield_tile_dmg3:
   .byte $70,$07,$70,$07,$70,$07,$70,$07  ; row  0  checker A
   .byte $07,$70,$07,$70,$07,$70,$07,$70  ; row  1  checker B
   .byte $70,$07,$70,$07,$70,$07,$70,$07  ; row  2
   .byte $07,$70,$07,$70,$07,$70,$07,$70  ; row  3
   .byte $70,$07,$70,$07,$70,$07,$70,$07  ; row  4
   .byte $07,$70,$07,$70,$07,$70,$07,$70  ; row  5
   .byte $70,$07,$70,$07,$70,$07,$70,$07  ; row  6
   .byte $07,$70,$07,$70,$07,$70,$07,$70  ; row  7
   .byte $70,$07,$70,$07,$70,$07,$70,$07  ; row  8
   .byte $07,$70,$07,$70,$07,$70,$07,$70  ; row  9
   .byte $70,$07,$70,$07,$70,$07,$70,$07  ; row 10
   .byte $07,$70,$07,$70,$07,$70,$07,$70  ; row 11
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row 12  solid
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row 13
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row 14
   .byte $77,$77,$77,$77,$77,$77,$77,$77  ; row 15

;******************************************************************
