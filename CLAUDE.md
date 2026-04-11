# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

Assemble
```bash
cl65 -t cx16 -o INVADERS.PRG -l INVADERS.LIST INVADERS.asm
```

Run in emulator:
```bash
x16emu -prg INVADERS.PRG -run
```

## Architecture

Single-file 6502 assembly program targeting the Commander X16 computer. Produces a `.prg` loadable from BASIC.
Use the @template.asm file as a guide to styling the code for the ca65 assembler

**Memory layout:**
- `$080D` — machine code entry point (`main`)

## Workflow

After every code change, commit with a clean, descriptive commit message and push to GitHub so there is always a saved version to revert to if needed.
