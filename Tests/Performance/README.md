# MacPilot resource acceptance

Run these checks against the **newly built or released MacPilot process**, not
an older copy already in `/Applications`. The sampler is read-only and does not
start or stop the app.

The following five checks are the earlier Phase 1 load scenarios. Use the
Phase 2 acceptance section below for current release thresholds.

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

## Phase 2 acceptance

Use the **new release process**. Record the SHA, macOS version, hardware, PID,
feature switches, and sample CSV. For each 30-minute phase, sample every five
seconds and verify the threshold:

```sh
Tests/Performance/resource-benchmark.sh <PID> 1800 5 /absolute/path/idle.csv
Tests/Performance/verify-phase2.py /absolute/path/idle.csv --mode idle
Tests/Performance/resource-benchmark.sh <PID> 1800 5 /absolute/path/all.csv
Tests/Performance/verify-phase2.py /absolute/path/all.csv --mode all
```

`ps` reports resident set size (RSS), so record Activity Monitor physical
footprint separately if comparing to its Memory column. The validator reports
memory growth; use `--max-growth-mb` only when the test environment has an
agreed numeric limit. Read the Diagnostics menu before and after disabling
Clipboard: idle managed tasks must be fewer than five, its managed task count
must fall after shutdown, its observer count must not rise,
and the feature must disappear from the active list. The 100-cycle framework
lifecycle test runs in `ResourceLifecycleTests`.

For a two-hour Leaks recording against a released process:

```sh
xcrun xctrace record --template Leaks --attach <PID> --time-limit 2h \
  --output /absolute/path/MacPilot-Phase2-Leaks.trace
xcrun xctrace export --input /absolute/path/MacPilot-Phase2-Leaks.trace --toc
```

Inspect the Leaks instrument in Instruments and save the trace result with the
CSV. Toggle all optional features off after the recording and take a final
sample to confirm their runtime resources are released.
