#!/usr/bin/env bash
#
# One-shot SC perf test runner. Assumes scylla is already up
# (start_scylla.sh in another terminal, OR run.sh which starts it for you).
#
#   1. Drops + recreates keyspace1 with consistency='global' and 128
#      tablets (verified before continuing).
#   2. Starts a background Prometheus scraper that dumps every snapshot
#      into runs/<run_id>/metrics.log with `=== <UTC ts> ===` delimiters.
#   3. Runs the patched cql-stress workload in the foreground.
#   4. On exit (normal or interrupt), stops the scraper.
#
# All workload knobs (duration, threads, tablets, …) are inlined below.
# Edit them in this file if you need to change a run.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/config.sh"

# ----- Workload knobs (edit here to change a run) ----------------------
# Duration, scrape period, SMP and TABLETS live in config.sh.
DURATION="$TEST_DURATION"
THREADS=500
CONNECTIONS_PER_SHARD=28
RF=1                         # single-node local repro (SCT used RF=3).
POP_RANGE="1..402653184"     # 1st quarter of SCT's 4-loader pop space.
COL_SIZE=1024                # 1 KB single column, single-row partitions.
COL_COUNT=1
NODE=127.0.0.1
PROMETHEUS_PORT=9180
SCRAPE_TIMEOUT=3

if [[ -z "${SCYLLA_DIR:-}" ]]; then
    echo "ERROR: SCYLLA_DIR is not set in config.sh." >&2
    exit 1
fi
if [[ -z "${CQL_STRESS_DIR:-}" ]]; then
    echo "ERROR: CQL_STRESS_DIR is not set in config.sh." >&2
    exit 1
fi
CQLSH_BIN="$SCYLLA_DIR/bin/cqlsh"
CQL_STRESS_BIN="$CQL_STRESS_DIR/target/release/cql-stress-cassandra-stress"
for f in "$CQLSH_BIN" "$CQL_STRESS_BIN"; do
    [[ -x "$f" ]] || { echo "ERROR: $f not found or not executable." >&2; exit 1; }
done

# ----- Run output dir --------------------------------------------------
# If invoked from run.sh, RUN_OUT is exported and already exists.
if [[ -z "${RUN_OUT:-}" ]]; then
    RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
    RUN_OUT="$HERE/runs/$RUN_ID"
    mkdir -p "$RUN_OUT"
fi
echo "Run output: $RUN_OUT"

# ----- 1. Recreate keyspace --------------------------------------------
# Why drop every run:
#   * Without `tablets = {'enabled': true}` the keyspace is non-tablet and
#     SC rejects it ("Only eventual consistency is supported for non-tablet
#     keyspaces").
#   * cql-stress's own CREATE uses `IF NOT EXISTS`. Scylla validates
#     the schema BEFORE the existence check (replica/database.cc:1626
#     validate_new_keyspace), so `IF NOT EXISTS` does not protect us
#     from a bad CREATE — only an explicit DROP+CREATE with the right
#     options does.
#   * SC tables don't support split/merge/migrations — start every run
#     with a clean, known-size tablet map.
echo "[1/3] Recreating keyspace1 (RF=$RF, tablets=$TABLETS)…"
"$CQLSH_BIN" "$NODE" <<CQL
DROP KEYSPACE IF EXISTS keyspace1;
CREATE KEYSPACE keyspace1
  WITH replication = {'class': 'NetworkTopologyStrategy', 'replication_factor': $RF}
  AND consistency = 'global'
  AND tablets = {'enabled': true, 'initial': $TABLETS};
CQL

desc="$("$CQLSH_BIN" "$NODE" -e "DESCRIBE KEYSPACE keyspace1;")"
echo "$desc" | grep -qi "consistency = 'global'" \
    || { echo "ERROR: keyspace1 was not created with consistency='global'" >&2; exit 1; }
echo "$desc" | grep -qi "tablets = {'enabled': true" \
    || { echo "ERROR: keyspace1 was not created with tablets enabled" >&2; exit 1; }

# ----- 2. Start metrics scraper ----------------------------------------
METRICS_FILE="$RUN_OUT/metrics.log"
SCRAPE_URL="http://${NODE}:${PROMETHEUS_PORT}/metrics"
echo "[2/3] Scraper: $SCRAPE_URL every ${METRICS_INTERVAL}s -> $METRICS_FILE"

(
    while true; do
        ts=$(date -u +%Y%m%dT%H%M%SZ)
        {
            echo "=== $ts ==="
            curl -sS --max-time "$SCRAPE_TIMEOUT" "$SCRAPE_URL" \
                || echo "scrape failed: $?"
        } >> "$METRICS_FILE"
        sleep "$METRICS_INTERVAL"
    done
) &
SCRAPER_PID=$!

cleanup() {
    if kill -0 "$SCRAPER_PID" 2>/dev/null; then
        kill "$SCRAPER_PID" 2>/dev/null || true
        wait "$SCRAPER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# ----- 3. Run the load -------------------------------------------------
HDR_FILE="$RUN_OUT/hdr.hdr"
STRESS_LOG="$RUN_OUT/cql-stress.log"
echo "[3/3] Running cql-stress for $DURATION (log: $STRESS_LOG)"

# Mirrors SCT build #7 stress command (build log lines 4213-4222):
# cl=QUORUM, 1KB column, single-row partitions, threads=500,
# connectionsPerShard=28. Differences vs SCT: RF=1 single node here,
# one loader on the first disjoint pop range, configurable duration.
"$CQL_STRESS_BIN" write \
    cl=QUORUM \
    "duration=$DURATION" \
    -schema "replication(strategy=NetworkTopologyStrategy,replication_factor=$RF)" \
    -mode "connectionsPerShard=$CONNECTIONS_PER_SHARD" cql3 native \
    -rate "threads=$THREADS" \
    -col "size=FIXED($COL_SIZE) n=FIXED($COL_COUNT)" \
    -pop "seq=$POP_RANGE" \
    -node "$NODE" \
    -log "hdrfile=$HDR_FILE" interval=10s \
    2>&1 | tee "$STRESS_LOG"

echo "Done. Artifacts in $RUN_OUT"
