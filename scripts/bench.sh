#!/bin/sh
# Measures the app's CPU, idle wakeups and memory in one mode and checks them against bench/budget.json.
#
#   scripts/bench.sh <active|checking|away|listening> [minutes]   (default 10 minutes)
#
# The app is launched with `--bench-mode <mode>`, which holds the engine in that mode. Until the app
# understands the flag, this measures the bare app, which is still a valid floor for "active".
# Writes bench/results/<date>-<mode>.json. Exits 1 on a budget breach, 2 on a regression over
# bench/baseline.json (when it has this mode). Set BENCH_POWERMETRICS=1 to add energy impact (sudo).
set -eu

mode=${1:-}
minutes=${2:-10}
case "$mode" in
  active|checking|away|listening) ;;
  *) echo "usage: scripts/bench.sh <active|checking|away|listening> [minutes]" >&2; exit 64 ;;
esac

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
interval=5
seconds=$(awk -v m="$minutes" 'BEGIN { printf "%d", m * 60 }')
[ "$seconds" -ge "$interval" ] || { echo "minutes must be at least $interval s" >&2; exit 64; }

swift build -c release --product ProximityMac >/dev/null
binary=$(swift build -c release --show-bin-path)/ProximityMac

"$binary" --bench-mode "$mode" >/dev/null 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT INT TERM
# Let launch costs settle so they do not count against the steady state.
sleep 5
kill -0 "$pid" 2>/dev/null || { echo "app exited during launch" >&2; exit 1; }

samples=$(mktemp)
cpu_time() { ps -o time= -p "$pid" | tr -d ' '; }
idle_wakeups() { top -l 1 -pid "$pid" -stats idlew | tail -1 | tr -d ' '; }
footprint_kb() {
  footprint "$pid" 2>/dev/null | sed -n 's/.*Footprint: \([0-9.]*\) \([KMG]B\).*/\1 \2/p' | head -1 |
    awk '{ v = $1; if ($2 == "MB") v *= 1024; if ($2 == "GB") v *= 1048576; printf "%d", v }'
}

start_cpu=$(cpu_time); start_wake=$(idle_wakeups); start_t=$(date +%s)
elapsed=0
while [ "$elapsed" -lt "$seconds" ]; do
  sleep "$interval"
  elapsed=$((elapsed + interval))
  kill -0 "$pid" 2>/dev/null || { echo "app exited during the run" >&2; exit 1; }
  printf '%s %s\n' "$(ps -o rss= -p "$pid" | tr -d ' ')" "$(footprint_kb)" >> "$samples"
done
end_cpu=$(cpu_time); end_wake=$(idle_wakeups); end_t=$(date +%s)

energy=""
if [ "${BENCH_POWERMETRICS:-0}" = 1 ] && sudo -n true 2>/dev/null; then
  energy=$(sudo -n powermetrics --samplers tasks -i 5000 -n 1 --show-process-energy 2>/dev/null |
    awk -v p="$pid" '$2 == p { print $(NF); exit }')
fi

mkdir -p bench/results
out="bench/results/$(date +%Y-%m-%d-%H%M%S)-$mode.json"
python3 - "$mode" "$minutes" "$samples" "$out" "$start_cpu" "$end_cpu" "$start_wake" "$end_wake" \
  "$start_t" "$end_t" "$energy" <<'PY'
import json, sys
mode, minutes, samples, out, c0, c1, w0, w1, t0, t1, energy = sys.argv[1:]

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
rss = [int(r[0]) for r in rows]
foot = [int(r[1]) for r in rows if len(r) > 1]
mem_kb = foot if foot else rss
result = {
    "mode": mode,
    "minutes": float(minutes),
    "cpuPercent": round((cpu_seconds(c1) - cpu_seconds(c0)) / wall * 100, 3),
    "wakeupsPerSecond": round((int(w1) - int(w0)) / wall, 3),
    "memoryMB": round(sum(mem_kb) / len(mem_kb) / 1024, 2),
    "peakRssMB": round(max(rss) / 1024, 2),
    "memorySource": "footprint" if foot else "rss",
}
if energy:
    result["energyImpact"] = float(energy)
json.dump(result, open(out, "w"), indent=2)

budget = json.load(open("bench/budget.json"))
limits = budget["modes"][mode]
status = 0
print(f"{mode}: {result['cpuPercent']}% CPU, {result['wakeupsPerSecond']} wakeups/s, {result['memoryMB']} MB ({out})")
for key, limit in limits.items():
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
        if key in result and base > 0 and result[key] > base * (1 + tolerance):
            print(f"REGRESSION {key}: {result[key]} vs baseline {base}")
            status = 2
print("PASS" if status == 0 else "FAIL")
sys.exit(status)
PY
