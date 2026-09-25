#!/bin/bash
set -euo pipefail

if (( $# < 2 || $# > 4 )); then
    echo "Usage: $0 <MacPilot PID> <duration seconds> [interval seconds] [output CSV]" >&2
    exit 2
fi

benchmark_pid=$1
benchmark_duration=$2
benchmark_interval=${3:-5}
benchmark_output=${4:-"$PWD/macpilot-resource-benchmark.csv"}

for value in "$benchmark_pid" "$benchmark_duration" "$benchmark_interval"; do
    [[ "$value" =~ ^[0-9]+$ ]] || { echo "PID, duration and interval must be integers" >&2; exit 2; }
done
(( benchmark_duration > 0 && benchmark_interval > 0 )) || exit 2
ps -p "$benchmark_pid" -o pid= | awk 'NF { found = 1 } END { exit !found }' \
    || { echo "Process is not running" >&2; exit 1; }

echo "timestamp,cpu_percent,rss_mb" > "$benchmark_output"
benchmark_started=$SECONDS
while (( SECONDS - benchmark_started < benchmark_duration )); do
    benchmark_sample=$(ps -p "$benchmark_pid" -o %cpu=,rss= | awk 'NF == 2 { printf "%.3f,%.3f", $1, $2 / 1024 }')
    [[ -n "$benchmark_sample" ]] || { echo "Process exited during benchmark" >&2; exit 1; }
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$benchmark_sample" >> "$benchmark_output"
    sleep "$benchmark_interval"
done

awk -F, 'NR > 1 {
    samples++
    cpu_sum += $2
    if ($2 > cpu_peak) cpu_peak = $2
    if (samples == 1) first_rss = $3
    last_rss = $3
    if ($3 > rss_peak) rss_peak = $3
} END {
    if (samples == 0) exit 1
    printf "Samples: %d\nAverage CPU: %.3f%%\nPeak CPU: %.3f%%\nPeak RSS: %.1f MB\nRSS change: %+.1f MB\n", samples, cpu_sum / samples, cpu_peak, rss_peak, last_rss - first_rss
}' "$benchmark_output"
echo "CSV: $benchmark_output"
