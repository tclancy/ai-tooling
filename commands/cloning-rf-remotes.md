---
name: cloning-rf-remotes
description: Reverse-engineer a 433/315 MHz OOK remote (fan, outlet, garage, doorbell) with an RTL-SDR and replay it from a microcontroller — coordinated capture, replay-before-you-trust verification, and the interference-vs-range failure split.
---

Follow the instructions in the `cloning-rf-remotes` skill
(skills/cloning-rf-remotes/SKILL.md in this toolkit) for the device below.

Target: $ARGUMENTS

If no target was given, ask for:

1. the device and how many physical units/remotes there are,
2. the band (433 MHz is the common default; 315 MHz for many US devices), and
3. what hardware is on hand — RTL-SDR model, and the transmitter
   (microcontroller + TX module) if replay is in scope this session.
