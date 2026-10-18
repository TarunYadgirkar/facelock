#!/bin/bash
# Runs the committed harness (accuracy, latency, burst, cold, idle) and writes aggregates only to
# bench/results/<date>-<chip>.json, with the README acceptance checks. Never touches owner images.
#   IDLE_SECONDS=600 LOCKED_SECONDS=300 BURSTS=5 scripts/bench.sh
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
lfw="${LFW:-bench/data/lfw_funneled}"
[[ -d "$lfw" ]] || { echo "LFW funneled not found at $lfw; run bench/lfw.sh" >&2; exit 1; }
swift build -c release --product facelock-bench >/dev/null
bin=.build/release/facelock-bench
out=bench/out
mkdir -p "$out" bench/results

$bin plan > "$out/plan.json"
$bin accuracy --lfw "$lfw" > "$out/accuracy.json"
$bin latency --lfw "$lfw" > "$out/latency.json"
$bin burst --idle 30 --bursts "${BURSTS:-5}" > "$out/burst.json"
$bin cold > "$out/cold.json"
$bin idle --seconds "${IDLE_SECONDS:-600}" --state present > "$out/idle_present.json"
$bin idle --seconds "${LOCKED_SECONDS:-300}" --state locked > "$out/idle_locked.json"

chip=$(sysctl -n machdep.cpu.brand_string | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/-$//')
dest="bench/results/$(date +%F)-$chip.json"
/usr/bin/python3 -I - "$out" "$dest" <<'EOF'
import json, platform, subprocess, sys
from pathlib import Path
out, dest = Path(sys.argv[1]), Path(sys.argv[2])
r = {k: json.loads((out / f"{k}.json").read_text()) for k in
     ("plan", "accuracy", "latency", "burst", "cold", "idle_present", "idle_locked")}
# N2 (decision spec, 2026-10-18): the numbers the README may quote once these hold.
n2 = {"impostor_max": 0.3330, "impostor_p99": 0.2227, "impostor_p999": 0.2798, "genuine_p5": 0.7234, "genuine_p1": 0.6880}
top3 = r["accuracy"]["top3"]
accuracy_ok = all(abs(top3[k] - v) <= 0.002 for k, v in n2.items())
p95 = max(r["latency"]["runtime_frame"]["total_ms"]["p95"], r["latency"]["manifest"]["total_ms"]["p95"])
idle = r["idle_present"]["cpu_percent_of_core"]
r["acceptance"] = {
    "accuracy_within_0.002_of_N2": accuracy_ok, "accuracy_deltas": {k: round(top3[k] - v, 4) for k, v in n2.items()},
    "latency_p95_ms": p95, "latency_p95_le_2.5ms": p95 <= 2.5,
    "idle_present_cpu_percent": idle, "idle_le_0.05pct": idle <= 0.05,
    "adaptation_replay_pass": r["accuracy"]["adaptation_replay"]["pass"],
    "floor_matches_committed": r["accuracy"]["floor_matches_committed"],
}
r["machine"] = {"chip": subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip(),
                "macos": platform.mac_ver()[0],
                "load_average": subprocess.run(["sysctl", "-n", "vm.loadavg"], capture_output=True, text=True).stdout.strip()}
dest.write_text(json.dumps(r, indent=1, sort_keys=True) + "\n")
print(json.dumps(r["acceptance"], indent=1))
print("wrote", dest)
EOF
