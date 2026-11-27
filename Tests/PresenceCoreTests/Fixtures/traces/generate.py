# synthetic
# Regenerate with: python3 generate.py .
# Writes synthetic presence traces. Numbers only.
import json, random, sys, os
out = sys.argv[1]

def obs(person, d=None):
    o = {"source": "camera", "person": person}
    if d is not None: o["distanceCm"] = round(d, 1)
    return {"observation": {"_0": o}}

def write(name, lines, truth):
    with open(os.path.join(out, name + ".jsonl"), "w") as f:
        f.write("# synthetic\n")
        for t, e in lines: f.write(json.dumps({"t": round(t, 2), "event": e}, separators=(",", ":")) + "\n")
    with open(os.path.join(out, name + ".truth.jsonl"), "w") as f:
        f.write("# synthetic\n")
        for t, a in truth: f.write(json.dumps({"t": t, "atDesk": a}) + "\n")

def run(name, seconds, inputs, see, truth, extra=()):
    """inputs: seconds with keyboard input; see(t) -> observation event; extra: (t, event)."""
    rng = random.Random(name)
    lines, last = [], 0.0
    extra = dict(extra)
    for s in range(seconds + 1):
        t = float(s)
        if s in inputs: last = t
        lines.append((t, {"idle": {"seconds": t - last}}))
        lines.append((t + 0.5, see(t, rng)))
        if s in extra: lines.append((t + 0.7, extra[s]))
    write(name, lines, truth)

every = lambda a, b, step: set(range(a, b, step))

# Reading: long pauses at the desk, face about 60 cm, a few missed frames.
run("reading", 600, every(0, 600, 75),
    lambda t, r: obs(False) if r.random() < 0.08 else obs(True, r.gauss(62, 4)), [(0, True)])
# Leaning back for a video: no input, face near the edge of the desk radius, looking away at times.
run("video", 900, {0},
    lambda t, r: obs(False) if r.random() < 0.1 else obs(True, r.gauss(100, 8)), [(0, True)])
# Walking to bed: input until 20 s, walks off at 25 s, then far or unseen.
run("walk_to_bed", 300, every(0, 21, 4),
    lambda t, r: obs(True, 60) if t < 25 else obs(True, 150 + (t - 25) * 40) if t < 32
    else (obs(True, r.gauss(380, 20)) if r.random() < 0.3 else obs(False)), [(0, True), (25, False)])
# Someone walking behind a person sitting still: the far body sometimes wins the frame.
run("walk_behind", 600, every(0, 600, 90),
    lambda t, r: obs(True, r.gauss(230, 30)) if 100 <= t % 200 < 110 else obs(True, r.gauss(65, 4)), [(0, True)])
# Coming back: leaves at 15 s, back in frame at 200 s, types at 203 s.
run("coming_back", 300, every(0, 15, 5) | {203, 210},
    lambda t, r: obs(True, 60) if t < 15 or t >= 200 else obs(False), [(0, True), (15, False), (200, True)])
# Voice hold from bed: leaves at 10 s, asks to keep it on for 5 minutes at 150 s, stays in bed.
run("voice_hold_from_bed", 700, every(0, 10, 3),
    lambda t, r: obs(True, 60) if t < 10 else obs(True, r.gauss(350, 20)) if r.random() < 0.3 else obs(False),
    [(0, True), (10, False)], extra=[(150, {"command": {"_0": {"hold": {"minutes": 5}}}})])
