# Setup window: layout and motion

The first-run walkthrough. It should feel like a calm computer-vision demo: the camera's view is the
subject, and everything else is quiet chrome around it.

## Layout

One fixed window, 900 x 580 pt, dark appearance, full-size content (no title bar strip).

```
+---------------------------------------------------+------------------+
| HUD (top-left, glass capsule)                     |  o o o o o o o o |  step dots
|                                                   |                  |
|            STAGE                                  |  Title           |
|  camera view with the vision drawn on top,        |  One line why.   |
|  or the camera plus a room map side by side       |                  |
|  (steps 3 and 5)                                  |  step controls   |
|                                                   |                  |
|                                                   |  [Back] [Next]   |
+---------------------------------------------------+------------------+
```

- **Stage** (left, fills the rest): the live camera image, aspect-fill, with a soft vignette so the
  overlays read. Steps 1 and 8 show a still, dimmed stage behind a centred card instead.
- **Panel** (right, 300 pt): a Liquid Glass surface (`glassEffect`, macOS 26) over the stage. It holds
  the step dots, the title, one short line, the step's controls, and Back / Continue at the bottom.
  Controls sit next to what they change: the radius slider is under the map, not in the panel.
- **HUD** (stage, top-left): "15 fps  ·  8.2 ms  ·  CPU 3%" in caption monospaced digits, secondary
  colour, inside a small glass capsule. It never moves and never animates.
- **Type**: title `.title2` semibold with slightly tight tracking; body `.body` secondary; numbers in
  monospaced digits so they don't jitter as they change.
- **Colour**: one accent (system accent) for the things that are "yours": your dot, the desk arc, the
  enrol ring, the tick. Overlay strokes are white at 70 to 90 % opacity. "Not counted" uses secondary
  white, never red: being outside the radius is not an error.

## Overlays (stage)

Drawn in one `Canvas` per frame from `LabFrame`, mirrored like a selfie view.

- Face: landmark points (1.5 pt dots), a corner-bracket box (four L corners, not a full rectangle)
  with the distance in cm above the top-left corner.
- Head pose: a three-axis gizmo at the nose, short (about 40 pt), X/Y/Z in three tints of white.
- Hands: joint dots joined by 1 pt bones, only when hands are up.
- Body: a faint dashed box at 25 % opacity.
- Gaze (step 4): a ray from between the eyes along the head's yaw and pitch; three targets (left,
  centre, right) light up with the accent when the ray hits them.

## Room map (steps 3 and 5)

A top-down square beside the camera view. The desk and screen sit at the bottom centre. The desk
radius is a glowing arc (accent, a soft outer blur). Your dot sits at `distanceCm` along
`horizontalAngleDeg`. Inside the arc the label under the map says "Counted"; outside, "Not counted".
A slider under the map adjusts the radius, 40 to 300 cm.

## Motion

Setup is seen once or twice, so it can carry a little more motion than the menu, but every motion has
a job.

| What | Motion | Why |
| --- | --- | --- |
| Step change | Panel content slides 12 pt and fades; forward comes in from the right, Back from the left. Spring, damping 1.0, response 0.35. | Spatial consistency: Back returns the way you came. Interruptible if you click quickly. |
| Stage change (camera to camera + map) | The map slides in from the right edge of the stage with the same spring; the camera view resizes with it. | Says the map is an addition to the same view, not a new screen. |
| Overlays | None. They track the frame 1:1. | Feedback must follow the face; easing would make it lag. |
| Your dot on the map | A short spring (damping 1.0, response 0.2) toward each new position. | Smooths sensor noise without visible lag. |
| Counted / Not counted | Cross-fade, 150 ms ease-out. | A state change, not a movement. |
| Enrol ring | Trim follows each sample, spring damping 1.0, response 0.3. | Progress, never jumps backwards. |
| Command tick | Scale 0.9 to 1 with fade, 200 ms ease-out. | Completion feedback. Never from scale 0. |
| Button press | System glass button press feedback. | Response on press. |

**Reduce Motion**: no slides or springs. Step changes and the map arrival become a 200 ms cross-fade;
the dot and ring jump to their values; the tick fades in without scaling. **Reduce Transparency**:
the panel and HUD use a solid dark background instead of glass.

## Steps and copy

1. Welcome. "Proximity Mac turns your screens off when you leave and back on when you return."
   Camera: "To see if you're at your desk." Microphone: "To hear 'Screen, wake up'." Privacy: "Nothing
   from the camera is saved." Button: Allow and continue.
2. Sit normally. Calibrates for 3 s with a thin progress line under the title. "Calibrated" when done.
3. Lean back, then stand behind your chair. The map tracks the farthest counted position; the radius
   becomes that plus 20 cm, adjustable with the slider.
4. Look at each monitor. Targets light up; "Still counted" stays on while you look away.
5. Go to your bed. "Not counted" outside the arc; if you would count, "Shrink the radius to N cm".
6. Only wake for me (optional). Enrol ring, then two toggles. Skip keeps both off.
7. Say "Screen, wake up". A live waveform, the words as heard, a tick when the Command parses.
8. Done. A card with the room map, the radius, and "Stored: 6 numbers" or "+ Face signature in
   Keychain".

Closing the window at any step marks Setup done. "Run Setup…" in the menu opens it again.

## Camera use

Only one camera session at a time: Setup calls `Coordinator.setLabRunning(true)` before
`VisionLab.start` and `false` after `stop`. The voice step starts the microphone only while it is
showing. No frame, sound or transcript is written anywhere.
