# Spike: what the camera costs in checking and away

GH-25 asked to bring `checking` (budget 2% CPU, 60 MB) and `away` (1.5%, 60 MB) inside budget. Every number below
was measured on the person's Mac (built-in camera, 640x480 at its 15 fps floor), with `scripts/bench.sh <mode> 2` on a
release build unless marked "bare". "Bare" is a small program that runs only an `AVCaptureSession` with an empty
frame callback: no Vision, no app, no UI.

## Bench, one step at a time

| Step | checking CPU | checking footprint | away CPU | away footprint |
| ---- | ------------ | ------------------ | -------- | -------------- |
| Before (PR #24) | 6.98% | 136.9 MB | 5.48% | 133.8 MB |
| Face rectangles rev 3, bodies only when no face, one reused handler | 5.61% | 134.3 MB | not run | not run |
| Smallest format (640x480), slowest frame rate (15 fps on this camera) | 6.40% | 141.7 MB | 5.33% | 140.2 MB |
| Camera's native pixel format (420v) instead of the 2vuy default | 4.11% | 121.4 MB | 3.71% | 120.3 MB |

The format and frame-rate step changed nothing here because the session already ran at 640x480, and the built-in
camera cannot go below 15 fps. It matters on cameras that go lower: the external camera on the dock goes down to 1 fps.

## Bare session

| Variant | CPU | Frames/s |
| ------- | --- | -------- |
| Default output (2vuy) | 4.25% | 16.5 |
| Native output (420v) | 2.90% | 16.0 |
| 420v scaled to 320x240 | 4.28% | 16.1 |
| Running, video connection disabled (no frames delivered) | 3.86% | 0 |
| Stopped | 0.00% | 0 |

Bare footprint while running: 110 MB (43 MB malloc, about 44 MB graphics, IOSurface and capture buffers).

## Stopping the session between samples

Bare, start, wait for N frames, stop, then sleep to the next sample:

| Interval | Frames per cycle | CPU |
| -------- | ---------------- | --- |
| 1 s | 3 | 34.1% |
| 2 s | 3 | 21.0% |
| 1 s | 1 | 12.0% |

Each start and stop costs far more than leaving the session running (about 0.1 to 0.3 CPU seconds a cycle), so
`watching` keeps the session running. First frames after a restart were not dark (luma stayed about 127), so
warm-up frames were not the cost.

## What dominates

- CPU: the running capture session itself, about 2.9% at its best on this camera, before any Vision work. Vision on
  one frame a second adds about 1%. Neither `checking` (2%) nor `away` (1.5%) can be met with the camera on all the
  time, and stopping between samples costs more.
- Memory: the capture stack, 110 MB with no Vision and no app. The 60 MB budget cannot be met while the camera runs.

## Owner recognition (GH-36)

With an owner signature set, a close face on a sampled frame is checked on that frame and the next two (about
130 ms at 15 fps). Each frame adds a face landmarks request on the face already found, an aligned 112x112 crop and
one SFace prediction. Measured on the person's Mac, release build, 100 runs:

| Step | Median | p90 |
| ---- | ------ | --- |
| Face landmarks on one face, 640x480 | 3.4 ms | 3.7 ms |
| SFace prediction, 112x112 | 1.4 ms | 1.9 ms |
| First prediction after load (once) | 26 ms | |
| Model load (once, on the first check) | 1030 ms | |

So one check is about 5 ms a frame, about 15 ms for a sample that matches on all three frames, and 5 ms when the
first frame misses. At one sample every 1 to 2 s that is at most about 1.5% of one core while a face is at the desk, and
nothing at all with nobody there or with no signature set (no model load, no landmarks request).

The landmarks and prediction steps were timed separately on synthetic buffers, since nobody was in front of the
camera during the run; the crop is a small Core Image render not counted above.

`scripts/bench.sh away 2` with this change and nobody at the desk: 4.25% CPU, 124 MB, PASS, the same as before,
since no face means no check runs. `--bench-mode` cannot set a signature, so the bench does not cover a check
running at the desk.

## Motion gate (GH-46)

While watching and checking, a 40x30 luma grid is taken from the 420v Y plane about 8 times a second and compared
with the previous grid. Vision runs at once when enough cells change (at most 4 passes a second) and on the old 1 per
2 s (watching) or 1 per 1 s (checking) when nothing moves. Measured on the person's Mac, release build:

| Step | Value |
| ---- | ----- |
| Frames delivered in `--bench-mode away` | about 30 per second (not the 15 fps floor noted above) |
| Locking a frame and sampling the grid | 0.32 ms on average |
| Motion frames over 37 s with the person at the desk | 17 of 1147 |
| `scripts/bench.sh away 2`, grid on every frame | 5.02% camera-on CPU, 128 MB, FAIL (budget 5%) |
| `scripts/bench.sh away 2`, grid 8 times a second | 4.87% camera-on CPU, 130 MB, PASS |

Most of the grid's cost is locking the frame's pixel buffer, not the 4800 reads, which is why it is throttled instead
of taken on every frame.

## Person segmentation (GH-55)

Presence no longer depends on the face. When no face is found, `VNGeneratePersonSegmentationRequest` (`.fast`,
OneComponent8 mask) runs first on every pass in Checking and Watching. The share of the frame covered by person pixels
gives the distance, `60 cm * sqrt(0.30 / share)` until Setup calibrates it: 15% reads as 85 cm, 2% as 230 cm. A mask
whose lowest person pixel is above 80% of the frame height is not someone seated at the desk, so it reads as 150 cm
or more. Under 0.5% is noise, and the body pose, body box and hand passes run as before. Body and hand pose stay on
motion passes only: segmentation already sees someone still at the desk looking down at a phone.

Each request alone on a 640x480 420v frame, release build, 40 runs after one warm-up:

| Request | Time per pass |
| ------- | ------------- |
| Face rectangles rev 3 | 12.3 ms |
| Person segmentation, `.fast` | 7.1 ms |
| Upper body box | 12.3 ms |
| Body pose | 10.6 ms |
| Hand pose (2 hands) | 12.4 ms |

Running body and hand pose on every Checking pass, as first planned, adds about 23 ms a second in an empty room;
that is why they stayed on motion passes.

`scripts/bench.sh <mode> 2`, with the person at the desk and moving, so motion passes ran up to 4 times a second:

| Build | checking camera-on | away camera-on |
| ----- | ------------------ | -------------- |
| Segmentation, pose and hands on every Checking pass | 6.96% CPU, 151.5 MB, FAIL | 3.86% CPU, 134.8 MB, PASS |
| Segmentation, pose and hands on motion passes | 8.65% CPU, 132.8 MB, FAIL | 4.48% CPU, 133.3 MB, PASS |
| Same, segmentation switched off | 9.14% CPU, 127.6 MB, FAIL | not run |

Checking is over its 5% budget with or without segmentation, and the result depends on how much the scene moves.
Segmentation adds about 5 MB. The breach comes from motion passes at up to 4 a second while Checking, each costing at
least the face pass, not from this change.

After that, Checking stopped adding passes for motion: it runs once a second, and motion seen since the last pass only
makes that pass a `.motion` one (body and hand pose too). Watching keeps its motion passes for a quick wake.

| Build | checking camera-on |
| ----- | ------------------ |
| Checking passes once a second only | 10.56% CPU, 151.5 MB, FAIL |
| `main` at 30752b6, without this lane | 11.57% CPU, 135.5 MB, FAIL |

The baseline (bench/baseline.json) is 4.81%. `main` alone is now over twice that in the same room, so the rise came
from something outside this lane and needs its own look.
