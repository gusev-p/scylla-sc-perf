# sc_perf

Single-node local harness for running cql-stress workloads against a
patched Scylla build with strongly-consistent tables, scraping
Prometheus metrics throughout the run.

## Quick start

```bash
git clone https://github.com/gusev-p/scylla-sc-perf
cd scylla-sc-perf
$EDITOR config.sh         # set SCYLLA_DIR and CQL_STRESS_DIR
./run.sh                  # builds, starts scylla, runs the test, stops scylla
```

`run.sh` will refuse to start until the two paths in `config.sh` are
filled in. They are filesystem paths of your choice where this harness
will git-clone the patched Scylla and cql-stress source trees and build
them. Nothing outside those two directories is ever touched.

## Output

Every run writes to `runs/<UTC-timestamp>/`:

- `metrics.log` — full `/metrics` Prometheus dump appended on every
  scrape (default: once per second), each snapshot prefixed with a
  `=== <UTC ts> ===` line for easy `grep`/`awk`. Scrape interval and
  test duration are configured via `METRICS_INTERVAL` and
  `TEST_DURATION` in `config.sh`.
- `scylla.log` — Scylla's own stdout/stderr for the run.
- `cql-stress.log` — full cql-stress stdout/stderr.
- `hdr.hdr` — HDR latency histogram from cql-stress.

## Analysing metrics

`metrics.log` is plain text — one full Prometheus `/metrics` snapshot
per scrape, separated by `=== <UTC ts> ===` headers. Any tool that
reads text works: `grep`/`awk`, a quick Python script, or just feed
the file to Claude (or any other LLM) and ask it to plot/aggregate
whatever metric you care about, in whatever direction the
investigation takes you.

A small built-in helper for the metrics this harness was originally
built around:

```bash
./metrics_table.py <shard> [run-dir]
```

Prints a per-scrape table for `scylla_commitlog_flush`,
`scylla_reactor_aio_retries`, and `scylla_reactor_io_threaded_fallbacks`
(summed across `reason` labels) for the given shard, with cumulative
counter values plus per-second rates over each bucket. `run-dir`
defaults to the most recent `runs/*` directory.

## Finer-grained control

`run.sh` is just glue. To iterate (e.g. start scylla once and run
multiple tests against it), use the underlying scripts directly:

```bash
./build_scylla.sh          # build/update scylla in $SCYLLA_DIR
./build_cql_stress.sh      # build/update cql-stress in $CQL_STRESS_DIR
./start_scylla.sh          # foreground scylla (run in its own terminal)
./run_test.sh              # one test against the running scylla
```

Workload knobs (duration, threads, tablets, …) are inlined at the top
of `run_test.sh`. Scylla flags are inlined in `start_scylla.sh`. Edit
in place to change a run.
