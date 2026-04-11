.segment "ZEROPAGE"
; The KERNAL and BASIC reserve all the addresses from $0080-$00FF. 
; Locations $00 and $01 determine which banks of RAM and ROM are  
; visible in high memory, and locations $02 through $21 are the
; pseudoregisters used by some of the new KERNAL calls
; (r0 = $02+$03, r1 = $04+$05, etc)
; So we have $22 through $7f to do with as we please, which is 
; where .segment "ZEROPAGE" variables are stored.

; Add any Zero Page variable definitions here



;******************************************************************
.segment "ONCE"
.segment "CODE"
.org $080D

   jmp start  ; jump to the main code routine


; Add any variable definitions here

; Add any includes here
.include "INC\x16.inc"  ; Standard X16 variables and macros

;******************************************************************
; main code routine starts here
start:




;******************************************************************