#!/bin/bash
# Runs the committed harness (accuracy, latency, burst, cold, the engine idle twice, the shipping
# app twice) and writes aggregates only to bench/results/<date>-<chip>.json, with the acceptance
# checks. Every number here moves with load, so the load average is recorded before and after
# each step and stored next to its result. Never touches owner images or the real camera.
#   IDLE_SECONDS=600 LOCKED_SECONDS=300 APP_SECONDS=300 BURSTS=5 scripts/bench.sh
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
lfw="${LFW:-bench/data/lfw_funneled}"
[[ -d "$lfw" ]] || { echo "LFW funneled not found at $lfw; run bench/lfw.sh" >&2; exit 1; }
swift build -c release --product facelock-bench >/dev/null
bin=.build/release/facelock-bench
app="${APP:-build/FaceLock.app}"
out=bench/out
mkdir -p "$out" bench/results
rm -f "$out"/*.json

step() {
  local name=$1
  shift
  local before after
  before=$(sysctl -n vm.loadavg | tr -d '{}' | xargs)
  "$@" > "$out/$name.json"
  after=$(sysctl -n vm.loadavg | tr -d '{}' | xargs)
  printf '{"before": "%s", "after": "%s"}\n' "$before" "$after" > "$out/$name.load.json"
}

step plan $bin plan
step accuracy $bin accuracy --lfw "$lfw"
step latency $bin latency --lfw "$lfw"
step burst $bin burst --idle 30 --bursts "${BURSTS:-5}"
step cold $bin cold
step idle_present $bin idle --seconds "${IDLE_SECONDS:-600}" --state present
step idle_present_2 $bin idle --seconds "${IDLE_SECONDS:-600}" --state present
step idle_locked $bin idle --seconds "${LOCKED_SECONDS:-300}" --state locked
if [[ -x "$app/Contents/MacOS/FaceLock" ]]; then
  step app $bin app --app "$app" --seconds "${APP_SECONDS:-300}"
  step app_2 $bin app --app "$app" --seconds "${APP_SECONDS:-300}"
else
  echo "no $app; run scripts/build-app.sh to measure the app too" >&2
fi

chip=$(sysctl -n machdep.cpu.brand_string | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/-$//')
dest="bench/results/$(date +%F)-$chip.json"
/usr/bin/python3 -I - "$out" "$dest" <<'PY'
import json, platform, subprocess, sys
from pathlib import Path
out, dest = Path(sys.argv[1]), Path(sys.argv[2])
names = [p.stem for p in sorted(out.glob("*.json")) if not p.stem.endswith(".load")]
r = {k: json.loads((out / f"{k}.json").read_text()) for k in names}
for k in names:
    load = out / f"{k}.load.json"
    if load.exists() and isinstance(r[k], dict):
        r[k]["load_average"] = json.loads(load.read_text())
# N2 (decision spec, 2026-10-18): the numbers the README may quote once these hold.
n2 = {"impostor_max": 0.3330, "impostor_p99": 0.2227, "impostor_p999": 0.2798, "genuine_p5": 0.7234, "genuine_p1": 0.6880}
top3 = r["accuracy"]["top3"]
camera_p95 = r["latency"]["runtime_frame"]["total_ms"]["p95"]
lfw_p95 = r["latency"]["manifest"]["total_ms"]["p95"]
idle = [r[k]["cpu_percent_of_core"] for k in ("idle_present", "idle_present_2")]
apps = [r[k] for k in ("app", "app_2") if k in r]
a = {
    "accuracy_within_0.002_of_N2": all(abs(top3[k] - v) <= 0.002 for k, v in n2.items()),
    "accuracy_deltas": {k: round(top3[k] - v, 4) for k, v in n2.items()},
    # The 2.5 ms p95 target is for the app's own camera path, at whatever load the run saw.
    "latency_p95_ms_camera_path": camera_p95, "latency_p95_ms_lfw": lfw_p95,
    "latency_p95_le_2.5ms": camera_p95 <= 2.5, "latency_load_average": r["latency"]["load_average"],
    "engine_idle_cpu_percent_runs": idle, "engine_idle_le_0.05pct": all(x <= 0.05 for x in idle),
    "engine_idle_load_average": [r[k]["load_average"] for k in ("idle_present", "idle_present_2")],
    "adaptation_replay_pass": r["accuracy"]["adaptation_replay"]["pass"],
    "floor_matches_committed": r["accuracy"]["floor_matches_committed"],
}
if apps:
    a.update({
        "app_cpu_percent_runs": [x["cpu_percent_of_core"] for x in apps],
        "app_idle_le_0.05pct": all(x["cpu_percent_of_core"] <= 0.05 for x in apps),
        "app_per_check_cpu_ms_runs": [x["per_check_cpu_ms"] for x in apps],
        "app_per_check_le_10ms": all(x["per_check_cpu_ms"] <= 10 for x in apps),
        "app_per_check_cpu_energy_mj_runs": [x["per_check_cpu_energy_mj"] for x in apps],
        "app_per_check_le_15mj": all(x["per_check_cpu_energy_mj"] <= 15 for x in apps),
        "app_load_average": [x["load_average"] for x in apps],
    })
else:
    a["app_idle_le_0.05pct"] = None
r["acceptance"] = a
swap = subprocess.run(["sysctl", "-n", "vm.swapusage"], capture_output=True, text=True).stdout.strip()
r["machine"] = {"chip": subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip(),
                "macos": platform.mac_ver()[0], "swap_at_end": swap}
dest.write_text(json.dumps(r, indent=1, sort_keys=True) + "\n")
print(json.dumps(r["acceptance"], indent=1))
print("wrote", dest)
PY
