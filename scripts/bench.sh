#!/bin/sh
# Measures the app's CPU, idle wakeups and memory in one mode and checks them against bench/budget.json.
#
#   scripts/bench.sh <active|checking|away|listening|reading> [minutes]   (default 10 minutes)
#
# The app is launched with `--bench-mode <mode>`. Most modes hold the engine in one state; `reading`
# runs the real engine with the person idle at the desk, so the camera cycles on and off.
# checking and away are budgeted only over the seconds the camera is on (cameraOn* keys); reading
# is budgeted on its whole-run average CPU and its peak footprint.
# Writes bench/results/<date>-<mode>.json. Exits 1 on a budget breach, 2 on a regression over
# bench/baseline.json (when it has this mode). Wakeups and energy impact need powermetrics, so they are
# measured only with BENCH_POWERMETRICS=1 and passwordless sudo; otherwise they are reported as unmeasured.
set -eu

mode=${1:-}
minutes=${2:-10}
case "$mode" in
  active|checking|away|listening|reading) ;;
  *) echo "usage: scripts/bench.sh <active|checking|away|listening|reading> [minutes]" >&2; exit 64 ;;
esac

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
interval=5
seconds=$(awk -v m="$minutes" 'BEGIN { printf "%d", m * 60 }')
[ "$seconds" -ge "$interval" ] || { echo "minutes must be at least $interval s" >&2; exit 64; }

swift build -c release --product ProximityMac >/dev/null
binary=$(swift build -c release --show-bin-path)/ProximityMac
camera_probe=.build/bench-camera-in-use
if [ ! -x "$camera_probe" ] || [ bench/camera-in-use.swift -nt "$camera_probe" ]; then
  swiftc -O bench/camera-in-use.swift -o "$camera_probe"
fi

"$binary" --bench-mode "$mode" >/dev/null 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT INT TERM
# Let launch costs settle so they do not count against the steady state.
sleep 5
kill -0 "$pid" 2>/dev/null || { echo "app exited during launch" >&2; exit 1; }

samples=$(mktemp)
cpu_time() { ps -o time= -p "$pid" | tr -d ' '; }
footprint_kb() {
  footprint "$pid" 2>/dev/null | sed -n 's/.*Footprint: \([0-9.]*\) \([KMG]B\).*/\1 \2/p' | head -1 |
    awk '{ v = $1; if ($2 == "MB") v *= 1024; if ($2 == "GB") v *= 1048576; printf "%d", v }'
}

camera_out=$(mktemp)
"$camera_probe" "$seconds" > "$camera_out" &
camera_pid=$!
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
# One row per interval: wall time, CPU time, RSS KB, footprint KB, camera on (1/0) at that moment.
sample() {
  printf '%s %s %s %s %s\n' "$(now)" "$(cpu_time)" "$(ps -o rss= -p "$pid" | tr -d ' ')" \
    "$(footprint_kb)" "$("$camera_probe")" >> "$samples"
}
start_cpu=$(cpu_time); start_t=$(date +%s)
sample
elapsed=0
while [ "$elapsed" -lt "$seconds" ]; do
  sleep "$interval"
  elapsed=$((elapsed + interval))
  kill -0 "$pid" 2>/dev/null || { echo "app exited during the run" >&2; exit 1; }
  sample
done
end_cpu=$(cpu_time); end_t=$(date +%s)
wait "$camera_pid" || true
camera_on=$(cat "$camera_out")

# powermetrics tasks columns: name, pid, CPU ms/s, user%, deadlines <2ms, 2-5ms, wakeups/s (intr), pkg idle, energy impact.
wakeups=""; energy=""
if [ "${BENCH_POWERMETRICS:-0}" = 1 ] && sudo -n true 2>/dev/null; then
  line=$(sudo -n powermetrics --samplers tasks -i 10000 -n 1 --show-process-energy 2>/dev/null |
    awk -v p="$pid" '$2 == p { print; exit }')
  wakeups=$(echo "$line" | awk '{ print $7 }')
  energy=$(echo "$line" | awk '{ print $NF }')
fi

mkdir -p bench/results
out="bench/results/$(date +%Y-%m-%d-%H%M%S)-$mode.json"
python3 - "$mode" "$minutes" "$samples" "$out" "$start_cpu" "$end_cpu" "$wakeups" "$camera_on" \
  "$start_t" "$end_t" "$energy" <<'PY'
import json, sys
mode, minutes, samples, out, c0, c1, wakeups, camera_on, t0, t1, energy = sys.argv[1:]

def cpu_seconds(s):
    # ps prints [[dd-]hh:]mm:ss.cc
    days, _, s = s.rpartition("-")
    parts = [float(p) for p in s.split(":")]
    total = 0.0
    for p in parts:
        total = total * 60 + p
    return total + (int(days) * 86400 if days else 0)

wall = max(1, int(t1) - int(t0))
rows = [line.split() for line in open(samples) if line.strip()]
rows = [r for r in rows if len(r) == 5]
rss = [int(r[2]) for r in rows]
foot = [int(r[3]) for r in rows if r[3].isdigit() and int(r[3]) > 0]
mem_kb = foot if len(foot) == len(rows) else rss

# Intervals where the camera was on at both ends count as camera-on time.
on_cpu = on_wall = 0.0
on_mem = []
for a, b in zip(rows, rows[1:]):
    if a[4] == "1" and b[4] == "1":
        on_wall += float(b[0]) - float(a[0])
        on_cpu += cpu_seconds(b[1]) - cpu_seconds(a[1])
        on_mem.append(int(b[3]) if mem_kb is foot else int(b[2]))
result = {
    "mode": mode,
    "minutes": float(minutes),
    "cpuPercent": round((cpu_seconds(c1) - cpu_seconds(c0)) / wall * 100, 3),
    "wakeupsPerSecond": float(wakeups) if wakeups else None,
    "memoryMB": round(sum(mem_kb) / len(mem_kb) / 1024, 2),
    "rssMB": round(sum(rss) / len(rss) / 1024, 2),
    "cameraOnSeconds": int(camera_on or 0),
    "cameraOnCpuPercent": round(on_cpu / on_wall * 100, 3) if on_wall else None,
    "cameraOnMemoryMB": round(sum(on_mem) / len(on_mem) / 1024, 2) if on_mem else None,
    "peakMemoryMB": round(max(mem_kb) / 1024, 2),
    "peakRssMB": round(max(rss) / 1024, 2),
    "memorySource": "footprint" if foot else "rss",
}
if energy:
    result["energyImpact"] = float(energy)
json.dump(result, open(out, "w"), indent=2)

budget = json.load(open("bench/budget.json"))
limits = budget["modes"][mode]
status = 0
wake = "unmeasured" if result["wakeupsPerSecond"] is None else result["wakeupsPerSecond"]
print(f"{mode}: {result['cpuPercent']}% CPU, wakeups/s {wake}, {result['memoryMB']} MB footprint, "
      f"{result['rssMB']} MB RSS, peak {result['peakMemoryMB']} MB, camera on {result['cameraOnSeconds']} s of {wall}, "
      f"camera-on {result['cameraOnCpuPercent']}% CPU / {result['cameraOnMemoryMB']} MB ({out})")
for key, limit in limits.items():
    if result.get(key) is None:
        print(f"UNMEASURED {key}")
        continue
    if result[key] > limit:
        print(f"BREACH {key}: {result[key]} > {limit}")
        status = 1
try:
    baseline = json.load(open("bench/baseline.json"))["modes"].get(mode)
except FileNotFoundError:
    baseline = None
if baseline and status == 0:
    tolerance = budget.get("regressionTolerance", 0.2)
    for key, base in baseline.items():
        if result.get(key) is not None and base and base > 0 and result[key] > base * (1 + tolerance):
            print(f"REGRESSION {key}: {result[key]} vs baseline {base}")
            status = 2
print("PASS" if status == 0 else "FAIL")
sys.exit(status)
PY
