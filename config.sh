# sc_perf configuration. Sourced by every script in this folder.
#
# EDIT THIS FILE BEFORE THE FIRST RUN.
#
# You only need to fill in two filesystem paths. The build scripts will
# git-clone the patched Scylla and cql-stress source trees into them
# (branches sc_perf of https://github.com/gusev-p/scylla and
# https://github.com/gusev-p/cql-stress respectively) and build the
# binaries there. Nothing outside these directories is ever touched.

# REQUIRED. Filesystem path where this harness will clone the patched
# Scylla source tree it needs (https://github.com/gusev-p/scylla, branch
# sc_perf). Pick any path you like — if it doesn't exist, the build
# script will create it and clone into it. The harness will only ever
# touch this directory.
# Example: /home/gusev-p/src/sc_perf-scylla
SCYLLA_DIR=

# REQUIRED. Filesystem path where this harness will clone the patched
# cql-stress source tree (https://github.com/gusev-p/cql-stress, branch
# sc_perf). Same idea — pick any path; the build script will create it
# and clone into it.
# Example: /home/gusev-p/src/sc_perf-cql-stress
CQL_STRESS_DIR=

# Scylla build mode passed to ./configure.py (dev / release / debug /
# sanitize / coverage). The harness builds and runs
# $SCYLLA_DIR/build/$SCYLLA_BUILD_MODE/scylla.
SCYLLA_BUILD_MODE=dev

# Length of one test run, in any format cql-stress accepts (e.g. 10s,
# 3m, 30m). The default is intentionally short — the symptoms we look
# at (commitlog_flush / aio_retries / io_threaded_fallbacks rates)
# stabilize within a few seconds, so 10s is enough for a quick repro.
TEST_DURATION=10s

# Prometheus scrape period, in seconds. Each scrape appends a full
# /metrics dump to runs/<id>/metrics.log. Smaller = finer time
# resolution and bigger log file.
METRICS_INTERVAL=1

# Number of shards (Seastar reactors) Scylla runs with. The repro is
# easy to trigger even at very low shard counts, so the default is
# kept small to make runs cheap. Bump this if you want to mirror a
# bigger deployment (SCT i4i.4xlarge uses ~14).
SMP=2

# Initial tablet count for keyspace1. Scylla rounds this up to the next
# power of two and SC tables can never split/merge, so the value here
# is the actual fixed tablet count for the run. Aim for a few tablets
# per shard.
TABLETS=16

# Memory budget passed to Scylla via --memory (e.g. 2G, 8G, 16G).
# Bigger isn't necessarily better — anything that lets the workload
# fit comfortably is fine for this single-node repro.
MEMORY=8G
