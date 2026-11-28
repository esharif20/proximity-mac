# 5. Monitors Off: external displays dark, built-in on

## Status
Accepted (product owner, 2026-11-28). Refines ADR 0001.

## Context
Sleeping every display with `pmset displaysleepnow` lets macOS apply its own lock delay, so the person had to use Touch ID on return. In a dim room the camera also sees almost nothing once every screen is dark. The product owner said the MacBook screen may stay on, as long as the monitors are off when they are away.

## Decision
- Default `keepBuiltInOn`: on Screens Off, every external display gets a black full-screen window above everything and a zero gamma table. Black OLED pixels are unlit, so there is no burn-in. The built-in shows the Away screen. A display-sleep assertion is held while Away, so macOS never sleeps the displays.
- Every way out restores the displays: Screens On, the toggle off, quitting, a crash (macOS restores gamma and removes windows when the process exits), and displays being plugged in or out.
- With `keepBuiltInOn` off, Screens Off is the old `pmset displaysleepnow`.
- In a dim room, when the camera sees motion while Away, the Away screen glows for about 2 s to light the face, then dims again.

## Consequences
- LCD monitors keep their backlight on while black. That doesn't cause burn-in, but it costs some power.
- The built-in display stays on all night, showing dark content.
