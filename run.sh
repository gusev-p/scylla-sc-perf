#!/usr/bin/env bash
#
# Top-level orchestrator: validate config, build what's missing, start
# scylla in the background, run the test, then stop scylla.
#
# For finer-grained control, run the individual scripts directly:
#   ./build_scylla.sh          # build/update scylla
#   ./build_cql_stress.sh      # build/update cql-stress
#   ./start_scylla.sh          # foreground scylla (separate terminal)
#   ./run_test.sh              # run a test against running scylla

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/config.sh"

complain_unset() {
    local var="$1" example="$2"
    cat >&2 <<EOF
ERROR: $var is not set in config.sh.

Open config.sh and set $var to a filesystem path of your choice. The
build script will create that directory if it doesn't exist and clone
the patched source tree into it. Pick anywhere on your machine, e.g.:

    $var=$example

EOF
    exit 1
}

[[ -n "${SCYLLA_DIR:-}"     ]] || complain_unset SCYLLA_DIR     /home/gusev-p/src/sc_perf-scylla
[[ -n "${CQL_STRESS_DIR:-}" ]] || complain_unset CQL_STRESS_DIR /home/gusev-p/src/sc_perf-cql-stress

# Always run the build scripts. They are idempotent: git fetch +
# incremental rebuild is fast when already up to date, and they ensure
# the correct branch is checked out (a stale wrong checkout would
# otherwise go undetected).
echo "==> Building scylla"
"$HERE/build_scylla.sh"
echo "==> Building cql-stress"
"$HERE/build_cql_stress.sh"

# Pre-create the run directory here so scylla.log can be placed inside
# it; export RUN_OUT so run_test.sh writes its own artifacts there too.
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_OUT="$HERE/runs/$RUN_ID"
mkdir -p "$RUN_OUT"
export RUN_OUT
echo "==> Run output: $RUN_OUT"

# Wipe any state from a previous run so every run starts from a virgin
# Scylla (empty commitlog, empty data dir, no leftover schema).
echo "==> Wiping $HERE/data"
rm -rf "$HERE/data"
mkdir -p "$HERE/data"

# Start scylla in the background. Stream its log into the run dir so it
# stays alongside the metrics/cql-stress logs.
SCYLLA_LOG="$RUN_OUT/scylla.log"
echo "==> Starting scylla (log: $SCYLLA_LOG)"
"$HERE/start_scylla.sh" > "$SCYLLA_LOG" 2>&1 &
SCYLLA_PID=$!

stop_scylla() {
    if kill -0 "$SCYLLA_PID" 2>/dev/null; then
        echo "==> Stopping scylla (pid $SCYLLA_PID)"
        kill -INT "$SCYLLA_PID" 2>/dev/null || true
        # Give it 30s to shut down cleanly.
        for _ in $(seq 1 30); do
            kill -0 "$SCYLLA_PID" 2>/dev/null || break
            sleep 1
        done
        kill -KILL "$SCYLLA_PID" 2>/dev/null || true
        wait "$SCYLLA_PID" 2>/dev/null || true
    fi
}
trap stop_scylla EXIT INT TERM

# Wait for the CQL port to accept connections (max ~120s).
echo -n "==> Waiting for scylla to accept CQL connections"
for i in $(seq 1 120); do
    if (echo > /dev/tcp/127.0.0.1/9042) 2>/dev/null; then
        echo " — ready after ${i}s"
        break
    fi
    if ! kill -0 "$SCYLLA_PID" 2>/dev/null; then
        echo
        echo "ERROR: scylla exited before becoming ready. See $SCYLLA_LOG" >&2
        exit 1
    fi
    echo -n "."
    sleep 1
done

"$HERE/run_test.sh"
