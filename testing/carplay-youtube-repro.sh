#!/bin/bash
# Absolute macOS screen coordinates; keep the simulator window fixed.
# Usage: bash testing/carplay-youtube-repro.sh tapX tapY swipeX bottomY topY
set -euo pipefail
[[ $# == 5 ]] || { echo "usage: $0 tapX tapY swipeX bottomY topY" >&2; exit 2; }
for coordinate in "$@"; do
    [[ "$coordinate" =~ ^[0-9]+$ ]] || { echo 'Coordinates must be nonnegative integers' >&2; exit 2; }
done
script_dir="$(cd "$(dirname "$0")" && pwd)"
host="${CARSURF_HOST:-iphone-11}"
run_dir="$(mktemp -d "${TMPDIR:-/tmp}/carsurf-youtube.XXXXXX")"
echo "Artifacts: $run_dir"
exec > >(tee "$run_dir/flow.log") 2>&1
collect() {
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" \
        'set -e; /var/jb/usr/local/bin/carsurf-logs; if test -f /var/jb/Library/CarSurf/carsurf.log; then printf "\n===== relay carsurf.log =====\n"; cat /var/jb/Library/CarSurf/carsurf.log; fi'
}
finish() {
    status=$?
    trap - EXIT
    if ! collect > "$run_dir/after.log" 2> "$run_dir/collection-errors.log"; then
        echo 'Final log collection failed; see collection-errors.log'
        status=1
    fi
    diff -u "$run_dir/before.log" "$run_dir/after.log" > "$run_dir/device.diff" || true
    echo "Finished $(date -Iseconds), exit=$status; artifacts: $run_dir"
    exit "$status"
}
collect > "$run_dir/before.log"
trap finish EXIT
swiftc "$script_dir/carplay-swipe.swift" -o "$run_dir/carplay-swipe"
echo "Started $(date -Iseconds); coordinates: $*"
osascript "$script_dir/carplay-youtube.applescript" "$run_dir/carplay-swipe" "$host" "$@"
