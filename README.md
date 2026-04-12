# X16 Invaders

For this project I am using Claude (Anthropic's AI) to write a version of Space Invaders for the [Commander X16](https://www.commanderx16.com/) modern retro computer.

## About the Project

We are writing 6502 assembly language, targeting the Commander X16.  The aim is to learn how to more effectively use Claude Code, and hopefully end up with some well commented sample code that I can refer to in the future.

I decided to start this project by asking Claude to write a plan before starting to write any code.  This plan is stored to in **plan.txt**.

## Thoughts so far

1. Starting with a plan is definitely the way to go.  I had a few failed attempts at having Claude write the whole thing in one go and it failed miserably, maxing out my five hour quota.  The plan claude came up with is broken down into small phases, with each new phase building on the last.  This is much the same way I would usually code.

2. When things aren't working, it pays to put the emulator in debug mode and find out where the issue really is.
I spent a lot of time on the player character movement not working, which turned out to be that the code was stuck in a loop waiting for a vsync.
