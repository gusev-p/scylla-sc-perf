#!/usr/bin/env bash
#
# Clone (if missing) and build the patched Scylla source tree at
# $SCYLLA_DIR. After this script the binary lives at
# $SCYLLA_DIR/build/dev/scylla.
#
# The repo and branch are hard-coded — the user only chooses the on-disk
# location via SCYLLA_DIR in config.sh.
#
# Build prerequisites: see https://github.com/scylladb/scylladb/blob/master/HACKING.md
# (notably ./tools/toolchain/dbuild on x86_64 Linux, or `./install-dependencies.sh`).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/config.sh"

REPO_HTTPS="https://github.com/gusev-p/scylla.git"
REPO_SSH="git@github.com:gusev-p/scylla.git"
REPO_REMOTE_NAME="sc-perf"
BRANCH="sc_perf"

if [[ -z "${SCYLLA_DIR:-}" ]]; then
    echo "ERROR: SCYLLA_DIR is not set in config.sh." >&2
    exit 1
fi

if [[ ! -e "$SCYLLA_DIR" ]]; then
    echo "Cloning $REPO_HTTPS @ $BRANCH -> $SCYLLA_DIR"
    mkdir -p "$(dirname "$SCYLLA_DIR")"
    git clone --branch "$BRANCH" --recurse-submodules "$REPO_HTTPS" "$SCYLLA_DIR"
elif [[ -d "$SCYLLA_DIR/.git" ]]; then
    # Find any existing remote pointing at the patched fork (HTTPS or SSH).
    remote_name="$(git -C "$SCYLLA_DIR" remote -v \
        | awk -v https="$REPO_HTTPS" -v ssh="$REPO_SSH" \
              '$2==https || $2==ssh {print $1; exit}')"
    if [[ -z "$remote_name" ]]; then
        echo "Adding remote '$REPO_REMOTE_NAME' -> $REPO_HTTPS in $SCYLLA_DIR"
        git -C "$SCYLLA_DIR" remote add "$REPO_REMOTE_NAME" "$REPO_HTTPS"
        remote_name="$REPO_REMOTE_NAME"
    fi
    # Skip fetch/checkout when already up to date — both saves time and
    # avoids touching .git/HEAD, which downstream build systems may use
    # as a rebuild trigger.
    remote_sha="$(git -C "$SCYLLA_DIR" ls-remote "$remote_name" "refs/heads/$BRANCH" | awk '{print $1}')"
    head_branch="$(git -C "$SCYLLA_DIR" rev-parse --abbrev-ref HEAD)"
    head_sha="$(git -C "$SCYLLA_DIR" rev-parse HEAD)"
    if [[ "$head_branch" == "$BRANCH" && -n "$remote_sha" && "$head_sha" == "$remote_sha" ]]; then
        echo "$SCYLLA_DIR already on $BRANCH @ $head_sha — skipping fetch/checkout"
    else
        echo "Updating $SCYLLA_DIR from remote '$remote_name'"
        git -C "$SCYLLA_DIR" fetch "$remote_name" "$BRANCH"
        git -C "$SCYLLA_DIR" checkout "$BRANCH"
        git -C "$SCYLLA_DIR" merge --ff-only "$remote_name/$BRANCH" || true
        git -C "$SCYLLA_DIR" submodule update --init --recursive
    fi
else
    echo "ERROR: $SCYLLA_DIR exists but is not a git repository." >&2
    echo "       Either delete it or pick a different SCYLLA_DIR in config.sh." >&2
    exit 1
fi

cd "$SCYLLA_DIR"
git log --oneline -1

./configure.py --disable-dist --mode "$SCYLLA_BUILD_MODE" --verbose --cflags="-g" --compiler-cache sccache --with scylla
ninja -j"$(nproc)" "build/$SCYLLA_BUILD_MODE/scylla"

ls -lh "$SCYLLA_DIR/build/$SCYLLA_BUILD_MODE/scylla"
