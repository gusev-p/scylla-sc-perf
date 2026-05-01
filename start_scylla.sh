#!/usr/bin/env bash
#
# Start the local single-node Scylla used by run_test.sh.
# Foreground process — Ctrl-C to stop.
# All state is written under ./data (set by workdir in scylla.yaml).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/config.sh"

if [[ -z "${SCYLLA_DIR:-}" ]]; then
    echo "ERROR: SCYLLA_DIR is not set in config.sh." >&2
    exit 1
fi

SCYLLA_BIN="$SCYLLA_DIR/build/$SCYLLA_BUILD_MODE/scylla"
if [[ ! -x "$SCYLLA_BIN" ]]; then
    echo "ERROR: $SCYLLA_BIN not found. Run ./build_scylla.sh first." >&2
    exit 1
fi

cd "$HERE"
mkdir -p data

# Flags from SCT enable_experimental_sc.yaml. --developer-mode 1 disables
# iotune/cgroup checks for non-tuned dev boxes; it does NOT change AIO or
# the IO scheduler. --smp comes from config.sh.
exec "$SCYLLA_BIN" \
    --options-file "$HERE/scylla.yaml" \
    --developer-mode 1 \
    --smp "$SMP" \
    --memory "$MEMORY" \
    --unsafe-bypass-fsync 0 \
    --blocked-reactor-notify-ms 50 \
    --abort-on-lsa-bad-alloc 1 \
    --abort-on-seastar-bad-alloc \
    --abort-on-internal-error 0 \
    --abort-on-ebadf 1 \
    --logger-log-level raft=info \
    --kernel-page-cache 0
