#!/usr/bin/env bash
#
# Clone (if missing) and build the patched cql-stress source tree at
# $CQL_STRESS_DIR. After this script the binary lives at
# $CQL_STRESS_DIR/target/release/cql-stress-cassandra-stress.
#
# The repo and branch are hard-coded — the user only chooses the on-disk
# location via CQL_STRESS_DIR in config.sh.
#
# The branch ships these patches on top of upstream cql-stress:
#   * RaftLeaderPolicy load balancer — routes every write to the Raft
#     leader's specific shard via system.tablets + /raft/leader_host.
#   * Auto-create SC keyspace with `consistency='global'` AND
#     `tablets={'enabled':true, 'initial':128}` — required because Scylla
#     validates the schema BEFORE the IF NOT EXISTS short-circuit.
#   * Wait for shard-aware pool warmup before workload start.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/config.sh"

REPO_HTTPS="https://github.com/gusev-p/cql-stress.git"
REPO_SSH="git@github.com:gusev-p/cql-stress.git"
REPO_REMOTE_NAME="sc-perf"
BRANCH="sc_perf"

if [[ -z "${CQL_STRESS_DIR:-}" ]]; then
    echo "ERROR: CQL_STRESS_DIR is not set in config.sh." >&2
    exit 1
fi

if [[ ! -e "$CQL_STRESS_DIR" ]]; then
    echo "Cloning $REPO_HTTPS @ $BRANCH -> $CQL_STRESS_DIR"
    mkdir -p "$(dirname "$CQL_STRESS_DIR")"
    git clone --branch "$BRANCH" "$REPO_HTTPS" "$CQL_STRESS_DIR"
elif [[ -d "$CQL_STRESS_DIR/.git" ]]; then
    remote_name="$(git -C "$CQL_STRESS_DIR" remote -v \
        | awk -v https="$REPO_HTTPS" -v ssh="$REPO_SSH" \
              '$2==https || $2==ssh {print $1; exit}')"
    if [[ -z "$remote_name" ]]; then
        echo "Adding remote '$REPO_REMOTE_NAME' -> $REPO_HTTPS in $CQL_STRESS_DIR"
        git -C "$CQL_STRESS_DIR" remote add "$REPO_REMOTE_NAME" "$REPO_HTTPS"
        remote_name="$REPO_REMOTE_NAME"
    fi
    # cql-stress's build.rs does `cargo:rerun-if-changed=.git/HEAD`, so any
    # `git fetch` / `git checkout` that bumps refs forces a full rebuild
    # of the cql-stress crate (~20 s). Probe the remote first and only
    # touch the local repo if something actually moved.
    remote_sha="$(git -C "$CQL_STRESS_DIR" ls-remote "$remote_name" "refs/heads/$BRANCH" | awk '{print $1}')"
    head_branch="$(git -C "$CQL_STRESS_DIR" rev-parse --abbrev-ref HEAD)"
    head_sha="$(git -C "$CQL_STRESS_DIR" rev-parse HEAD)"
    if [[ "$head_branch" == "$BRANCH" && -n "$remote_sha" && "$head_sha" == "$remote_sha" ]]; then
        echo "$CQL_STRESS_DIR already on $BRANCH @ $head_sha — skipping fetch/checkout"
    else
        echo "Updating $CQL_STRESS_DIR from remote '$remote_name'"
        git -C "$CQL_STRESS_DIR" fetch "$remote_name" "$BRANCH"
        git -C "$CQL_STRESS_DIR" checkout "$BRANCH"
        git -C "$CQL_STRESS_DIR" merge --ff-only "$remote_name/$BRANCH" || true
    fi
else
    echo "ERROR: $CQL_STRESS_DIR exists but is not a git repository." >&2
    echo "       Either delete it or pick a different CQL_STRESS_DIR in" >&2
    echo "       config.sh." >&2
    exit 1
fi

cd "$CQL_STRESS_DIR"
git log --oneline -1

cargo build --release --bin cql-stress-cassandra-stress
ls -lh "$CQL_STRESS_DIR/target/release/cql-stress-cassandra-stress"
