# MacPilot resource acceptance

Run these checks against the **newly built or released MacPilot process**, not
an older copy already in `/Applications`. The sampler is read-only and does not
start or stop the app.

1. Idle: turn off optional features, wait for launch work to settle, then run
   `Tests/Performance/resource-benchmark.sh <PID> 600 5 <absolute-output.csv>`.
   Target: average CPU below 0.1%, peak resident memory below 80 MB.
2. All features: enable the intended feature set, run the sampler for 1,800
   seconds, and check average CPU below 3% with no sustained RSS rise.
3. Long run: sample for 86,400 seconds while using Clipboard normally. Check
   the RSS graph and the final RSS change for sustained growth.
4. Window load: open 100 real windows across several apps, invoke Option-Tab,
   and verify the list appears within 300 ms, UI remains responsive, and the
   first preview work begins after the 100 ms dwell. Inspect WindowSwitcher
   performance logs for capture counts and latency.
5. Clipboard load: perform 10,000 copies with a mix of text and images. Check
   resident memory, `~/Library/Application Support/MacPilot/Clipboard`, and
   that deleted history content files are removed. Pinned items may outlive
   30 days but the 2 GB total content ceiling still applies.

The CSV columns are timestamp, process CPU percentage, and resident MB. Use
Activity Monitor or Instruments for GPU and allocations; `ps` cannot measure
those. Always note hardware, macOS version, enabled features, and the exact
build SHA alongside results.
