#!/usr/bin/env bash
# sync-from-upstream.sh — bring fork up to date with upstream master
# and prepare lifeatlas-master for release.
#
# Exit codes (stable contract; agents and humans both rely on these):
#   0   success, ready for release
#   10  merge conflict, human resolution required
#   20  workflow files changed in upstream sync
#   30  cargo check failed after merge
#   40  precondition failure
#   1   uncategorized error
#
# Output channels:
#   stderr — all human-readable progress with [phase N/M] headers
#   stdout — a single STATUS: <state> line at exit

set -euo pipefail

# Exit code constants (use `exit "$EX_<NAME>"`).
EX_OK=0
EX_MERGE_CONFLICT=10
EX_WORKFLOW_CHANGES=20
EX_CARGO_CHECK=30
EX_PRECONDITION=40

# Configuration: branches, remotes, and where workflow files live.
ORIGIN_REMOTE="origin"
UPSTREAM_REMOTE="upstream"
MASTER_BRANCH="master"
RELEASE_BRANCH="lifeatlas-master"
WORKFLOWS_DIR=".github/workflows"

# Flags.
DRY_RUN=0
STATUS_ONLY=0
ACK_WORKFLOW_CHANGES=0
INTERACTIVE=0

usage() {
    cat <<'USAGE'
sync-from-upstream.sh — sync fork master from upstream and prepare lifeatlas-master.

Usage: scripts/sync-from-upstream.sh [flags]

Flags:
  --dry-run               Print what each phase would do; make no changes.
  --status                Report current state and exit; no fetches or changes.
  --ack-workflow-changes  Proceed past the workflow-audit phase after a human
                          confirmed the diff is benign.
  --interactive           Re-enable optional confirmation prompts (off by default).
  --help                  Print this help.

Exit codes:
  0   ready_to_release / master_up_to_date
  10  merge_conflict (repo left mid-merge; resolve and re-run)
  20  workflow_changes_detected (re-run with --ack-workflow-changes)
  30  cargo_check_failed
  40  precondition_failure
USAGE
}

# Parse flags.
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --status) STATUS_ONLY=1 ;;
        --ack-workflow-changes) ACK_WORKFLOW_CHANGES=1 ;;
        --interactive) INTERACTIVE=1 ;;
        --help|-h) usage; exit "$EX_OK" ;;
        *) echo "unknown flag: $1" >&2; usage >&2; exit "$EX_PRECONDITION" ;;
    esac
    shift
done

# Helpers (all output to stderr; STATUS line goes to stdout via emit_status).
log() { echo "[sync-from-upstream] $*" >&2; }
phase() { echo "" >&2; echo "[phase $1/$2] $3" >&2; }
fail() {
    local code="$1"; shift
    echo "ERROR: $*" >&2
    emit_status "$1"
    exit "$code"
}
emit_status() { echo "STATUS: $1"; }

# ─── Phase 1: Preflight ─────────────────────────────────────────────────
phase 1 8 "preflight"

# Confirm we're inside a git repo with the expected remotes.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    fail "$EX_PRECONDITION" "not a git repository"
fi
if ! git remote get-url "$ORIGIN_REMOTE" >/dev/null 2>&1; then
    fail "$EX_PRECONDITION" "remote '$ORIGIN_REMOTE' is not configured"
fi
if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
    fail "$EX_PRECONDITION" "remote '$UPSTREAM_REMOTE' is not configured"
fi

# Working tree must be clean (untracked files are OK; modified/staged are not).
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    fail "$EX_PRECONDITION" "working tree has uncommitted changes; commit or stash first"
fi

# Detect mid-merge state — if present, skip phases 2-5 and resume at phase 6.
RESUMING_MID_MERGE=0
if [ -f "$(git rev-parse --git-dir)/MERGE_HEAD" ]; then
    log "detected mid-merge on $(git symbolic-ref --short HEAD) — resuming"
    RESUMING_MID_MERGE=1
fi

# --status: report state and exit.
if [ "$STATUS_ONLY" -eq 1 ]; then
    if [ "$RESUMING_MID_MERGE" -eq 1 ]; then
        emit_status "mid_merge"
    else
        emit_status "clean"
    fi
    exit "$EX_OK"
fi

# ─── Phase 2: Fetch ─────────────────────────────────────────────────────
phase 2 8 "fetch"

if [ "$DRY_RUN" -eq 1 ]; then
    log "(dry-run) would: git fetch $UPSTREAM_REMOTE $MASTER_BRANCH --no-tags"
    log "(dry-run) would: git fetch $ORIGIN_REMOTE --no-tags"
elif [ "$RESUMING_MID_MERGE" -eq 0 ]; then
    git fetch "$UPSTREAM_REMOTE" "$MASTER_BRANCH" --no-tags
    git fetch "$ORIGIN_REMOTE" --no-tags
else
    log "skipping fetch (resuming mid-merge)"
fi

# ─── Phase 3: Fast-forward master mirror ────────────────────────────────
phase 3 8 "fast-forward master mirror"

if [ "$RESUMING_MID_MERGE" -eq 1 ]; then
    log "skipping master FF (resuming mid-merge)"
else
    LOCAL_MASTER=$(git rev-parse "$MASTER_BRANCH")
    UPSTREAM_MASTER=$(git rev-parse "$UPSTREAM_REMOTE/$MASTER_BRANCH")
    ORIGIN_MASTER=$(git rev-parse "$ORIGIN_REMOTE/$MASTER_BRANCH")

    if [ "$LOCAL_MASTER" = "$UPSTREAM_MASTER" ] \
       && [ "$ORIGIN_MASTER" = "$UPSTREAM_MASTER" ]; then
        log "master is already in sync with upstream and origin"
    else
        # Detect divergence (local master ahead of upstream — should never happen).
        if ! git merge-base --is-ancestor "$LOCAL_MASTER" "$UPSTREAM_MASTER"; then
            fail "$EX_PRECONDITION" \
                "local $MASTER_BRANCH has commits upstream/$MASTER_BRANCH does not — investigate manually"
        fi

        # Fast-forward local master if behind.
        if [ "$LOCAL_MASTER" != "$UPSTREAM_MASTER" ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                log "(dry-run) would: git checkout $MASTER_BRANCH && git merge --ff-only $UPSTREAM_REMOTE/$MASTER_BRANCH"
            else
                git checkout "$MASTER_BRANCH"
                git merge --ff-only "$UPSTREAM_REMOTE/$MASTER_BRANCH"
            fi
        fi

        # Push to origin only if origin/master is also behind.
        if [ "$ORIGIN_MASTER" != "$UPSTREAM_MASTER" ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                log "(dry-run) would: git push $ORIGIN_REMOTE $MASTER_BRANCH"
            else
                git push "$ORIGIN_REMOTE" "$MASTER_BRANCH"
            fi
        else
            log "origin/$MASTER_BRANCH is already at upstream tip (e.g., GitHub Sync Fork was used) — skipping push"
        fi
    fi

    OLD_MASTER_TIP="$LOCAL_MASTER"  # remember for workflow audit
    NEW_MASTER_TIP=$(git rev-parse "$MASTER_BRANCH")
fi

# ─── Phase 4: Workflow audit ────────────────────────────────────────────
phase 4 8 "workflow audit"

if [ "$RESUMING_MID_MERGE" -eq 1 ]; then
    log "skipping workflow audit (resuming mid-merge)"
elif [ "$OLD_MASTER_TIP" = "$NEW_MASTER_TIP" ]; then
    log "no changes to master tip — workflow audit not needed"
else
    WORKFLOW_DIFF=$(git diff --name-only "$OLD_MASTER_TIP" "$NEW_MASTER_TIP" -- "$WORKFLOWS_DIR" || true)
    if [ -n "$WORKFLOW_DIFF" ]; then
        if [ "$ACK_WORKFLOW_CHANGES" -eq 1 ]; then
            log "workflow changes acknowledged via --ack-workflow-changes:"
            echo "$WORKFLOW_DIFF" | sed 's/^/  /' >&2
        else
            log "workflow files changed in upstream sync:"
            echo "$WORKFLOW_DIFF" | sed 's/^/  /' >&2
            log "audit these changes for new push-triggered triggers,"
            log "then re-run with --ack-workflow-changes to proceed."
            emit_status "workflow_changes_detected"
            exit "$EX_WORKFLOW_CHANGES"
        fi
    else
        log "no workflow file changes in this sync"
    fi
fi

# ─── Phase 5: Merge master into lifeatlas-master ────────────────────────
phase 5 8 "merge master into $RELEASE_BRANCH"

if [ "$RESUMING_MID_MERGE" -eq 1 ]; then
    log "merge already in progress on $(git symbolic-ref --short HEAD) — assuming user resolved conflicts and committed; verifying..."
    if [ -f "$(git rev-parse --git-dir)/MERGE_HEAD" ]; then
        # Still mid-merge — user hasn't finished.
        fail "$EX_MERGE_CONFLICT" "merge still in progress; resolve conflicts and \`git commit\` before re-running"
    fi
    log "merge appears complete; continuing"
else
    if [ "$DRY_RUN" -eq 1 ]; then
        log "(dry-run) would: git checkout $RELEASE_BRANCH && git merge $MASTER_BRANCH"
    else
        git checkout "$RELEASE_BRANCH"
        if ! git merge --no-edit "$MASTER_BRANCH"; then
            log "merge produced conflicts. Files needing resolution:"
            git status --porcelain | grep '^UU\|^AA\|^DD' | sed 's/^/  /' >&2
            log "Resolve manually, then 'git commit' the merge and re-run this script."
            emit_status "merge_conflict"
            exit "$EX_MERGE_CONFLICT"
        fi
    fi
fi

# ─── Phase 6: Reconcile Cargo.toml base version ─────────────────────────
phase 6 8 "reconcile Cargo.toml base version"

# Parse the upstream base from master's Cargo.toml (e.g., "0.7.4").
UPSTREAM_BASE=$(git show "$MASTER_BRANCH:Cargo.toml" | sed -n 's/^version = "\([0-9]*\.[0-9]*\.[0-9]*\)"$/\1/p' | head -1)
if [ -z "$UPSTREAM_BASE" ]; then
    fail "$EX_PRECONDITION" "could not parse upstream base version from $MASTER_BRANCH:Cargo.toml"
fi

# Parse the current lifeatlas-master version (e.g., "0.7.3-la.1.5").
CURRENT_LA_VERSION=$(sed -n 's/^version = "\([^"]*\)"$/\1/p' Cargo.toml | head -1)
if [ -z "$CURRENT_LA_VERSION" ]; then
    fail "$EX_PRECONDITION" "could not parse current Cargo.toml version on $RELEASE_BRANCH"
fi

# Decompose the LA version: <base>-la.<MAJOR>.<MINOR>
CURRENT_BASE=$(echo "$CURRENT_LA_VERSION" | sed -n 's/^\([0-9]*\.[0-9]*\.[0-9]*\)-la\.[0-9]*\.[0-9]*$/\1/p')
LA_SUFFIX=$(echo "$CURRENT_LA_VERSION" | sed -n 's/^[0-9]*\.[0-9]*\.[0-9]*\(-la\.[0-9]*\.[0-9]*\)$/\1/p')

if [ -z "$CURRENT_BASE" ] || [ -z "$LA_SUFFIX" ]; then
    fail "$EX_PRECONDITION" "Cargo.toml version '$CURRENT_LA_VERSION' is not in <base>-la.<MAJOR>.<MINOR> form"
fi

if [ "$CURRENT_BASE" = "$UPSTREAM_BASE" ]; then
    log "Cargo.toml base version unchanged ($UPSTREAM_BASE)"
else
    NEW_LA_VERSION="${UPSTREAM_BASE}${LA_SUFFIX}"
    log "upstream base bumped: $CURRENT_BASE -> $UPSTREAM_BASE; setting Cargo.toml to $NEW_LA_VERSION"
    if [ "$DRY_RUN" -eq 1 ]; then
        log "(dry-run) would: rewrite Cargo.toml versions to $NEW_LA_VERSION and commit"
    else
        # Replace every occurrence of the previous version with the new one.
        # Same sed mechanics as Task 3 step 2.
        sed -i "s/version = \"${CURRENT_LA_VERSION}\"/version = \"${NEW_LA_VERSION}\"/g" Cargo.toml
        cargo check --workspace 2>&1 | tail -5 >&2 || \
            fail "$EX_CARGO_CHECK" "cargo check failed after Cargo.toml version reconciliation"
        git add Cargo.toml Cargo.lock
        git commit -m "chore(release): reconcile Cargo.toml base to ${UPSTREAM_BASE} after upstream sync"
    fi
fi

# ─── Phase 7: Sanity check (cargo check) ────────────────────────────────
phase 7 8 "cargo check"

if [ "$DRY_RUN" -eq 1 ]; then
    log "(dry-run) would: cargo check --all-targets --locked"
else
    if ! cargo check --all-targets --locked 2>&1 | tail -10 >&2; then
        emit_status "cargo_check_failed"
        exit "$EX_CARGO_CHECK"
    fi
fi

# ─── Phase 8: Report ────────────────────────────────────────────────────
phase 8 8 "report"

log "----- patches still on $RELEASE_BRANCH (vs $MASTER_BRANCH) -----"
git log "$MASTER_BRANCH..$RELEASE_BRANCH" --oneline >&2 || true

if [ "${OLD_MASTER_TIP:-}" != "${NEW_MASTER_TIP:-}" ] && [ -n "${OLD_MASTER_TIP:-}" ]; then
    log "----- upstream changes pulled in this sync -----"
    git log "${OLD_MASTER_TIP}..${NEW_MASTER_TIP}" --oneline >&2 || true
fi

log ""
log "Ready to release. Run scripts/release-fork.sh (or --bump-major for an LA epoch bump)."

emit_status "ready_to_release"
exit "$EX_OK"
