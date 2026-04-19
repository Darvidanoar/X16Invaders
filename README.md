# X16 Invaders

For this project I am using Claude (Anthropic's AI) to write a version of Space Invaders for the [Commander X16](https://www.commanderx16.com/) modern retro computer.

## About the Project

We are writing 6502 assembly language, targeting the Commander X16.  The aim is to learn how to more effectively use Claude Code, and hopefully end up with some well commented sample code that I can refer to in the future.

I decided to start this project by asking Claude to write a plan before we start coding.  This plan is stored in **plan.txt**.

## Thoughts

1. Starting with a plan is definitely the way to go.  I had a few failed attempts at having Claude write the whole thing in one go and it failed miserably, very quickly maxing out my five hour quota.  The plan claude came up with is broken down into small phases, with each new phase building on the last.  This is much the same way I would usually code.

2. When things aren't working, it pays to put the emulator in debug mode and find out where the issue really is.
I spent a lot of time trying to get claude to fix an issue where the player character movement was not working.  This turned out to be that the code was stuck in a loop waiting for a vsync and not even making it to the player movement part of the code.

3. While breaking down the work into phases has worked well, Phase 4 turned out to be a little abitious. After a couple of attempts resulting in my usage maxing out, I ended up asking claude to build each item, one at a time.  Some of the steps seemed quite challenging to me, so this made sense to do each item in phase 4 individually.  Usage for the two sessions this ran across seemed much lower.  However, when I tallied up the usage (29% + 71%), it was exactly 100% (with some bug fixing included).

4. Overall, the game seems to work very well.  However, having scanned various parts of the code, there seem to be several instances where the code simply jumps out of a subroutine without ever executing an rts.  More close examination of the code is required to confirm this.

---

![X16Invaders](/Invaders.png)