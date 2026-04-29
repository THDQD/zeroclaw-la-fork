#!/usr/bin/env bash
# release-fork.sh — produce one fork release.
#
# Assumes sync-from-upstream.sh has been run and exited 0. Builds the
# binary in a pinned docker image, packages, tags, publishes to GitHub
# Releases, and pushes the docker image to GHCR.
#
# Exit codes (matches sync-from-upstream.sh contract):
#   0   released (or up-to-date for --status)
#   30  cargo test failed
#   40  precondition failure
#   1   uncategorized error

set -euo pipefail

EX_OK=0
EX_CARGO_TEST=30
EX_PRECONDITION=40

# Configuration.
ORIGIN_REMOTE="origin"
MASTER_BRANCH="master"
RELEASE_BRANCH="lifeatlas-master"
FORK_REPO="THDQD/zeroclaw-la-fork"
GHCR_REPO="ghcr.io/thdqd/zeroclaw-la-fork"  # GHCR requires lowercase
BUILDER_IMAGE="zeroclaw-builder:rust1.93"
TARGET_TRIPLE="x86_64-unknown-linux-gnu"

# Cargo features for fork builds. Adjust as the fork's needs evolve.
LIFEATLAS_RELEASE_FEATURES="agent-runtime"

# Flags.
DRY_RUN=0
STATUS_ONLY=0
BUMP_MAJOR=0
INTERACTIVE=0
FEATURES_OVERRIDE=""

usage() {
    cat <<'USAGE'
release-fork.sh — produce one LifeAtlas fork release.

Usage: scripts/release-fork.sh [flags]

Flags:
  --dry-run            Print what each phase would do; make no changes.
  --status             Report release-readiness state and exit.
  --bump-major         Increment the LA MAJOR version, reset MINOR to 1.
  --features <list>    Override LIFEATLAS_RELEASE_FEATURES for this build.
  --interactive        Re-enable optional confirmation prompts.
  --help               Print this help.

Exit codes:
  0   released
  30  cargo_test_failed
  40  precondition_failure
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --status) STATUS_ONLY=1 ;;
        --bump-major) BUMP_MAJOR=1 ;;
        --features) shift; FEATURES_OVERRIDE="$1" ;;
        --interactive) INTERACTIVE=1 ;;
        --help|-h) usage; exit "$EX_OK" ;;
        *) echo "unknown flag: $1" >&2; usage >&2; exit "$EX_PRECONDITION" ;;
    esac
    shift
done

log() { echo "[release-fork] $*" >&2; }
phase() { echo "" >&2; echo "[phase $1/$2] $3" >&2; }
fail() {
    local code="$1"; shift
    echo "ERROR: $*" >&2
    case "$code" in
        "$EX_CARGO_TEST") emit_status "cargo_test_failed" ;;
        "$EX_PRECONDITION") emit_status "precondition_failure" ;;
        *) emit_status "error" ;;
    esac
    exit "$code"
}
emit_status() { echo "STATUS: $1"; }

# ─── Phase 1: Preflight ─────────────────────────────────────────────────
phase 1 13 "preflight"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    fail "$EX_PRECONDITION" "not a git repository"
fi

CURRENT_BRANCH=$(git symbolic-ref --short HEAD)
if [ "$CURRENT_BRANCH" != "$RELEASE_BRANCH" ]; then
    fail "$EX_PRECONDITION" "must be on $RELEASE_BRANCH (currently on $CURRENT_BRANCH)"
fi

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    fail "$EX_PRECONDITION" "working tree has uncommitted changes"
fi

if [ -f "$(git rev-parse --git-dir)/MERGE_HEAD" ]; then
    fail "$EX_PRECONDITION" "merge in progress; finish or abort it first"
fi

# Required tools.
for tool in cargo docker gh jq tar sha256sum; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        fail "$EX_PRECONDITION" "required tool '$tool' not on PATH"
    fi
done

if ! gh auth status >/dev/null 2>&1; then
    fail "$EX_PRECONDITION" "gh is not authenticated; run 'gh auth login'"
fi
if ! gh auth status 2>&1 | grep -q 'write:packages'; then
    fail "$EX_PRECONDITION" "gh token lacks 'write:packages' scope; run 'gh auth refresh -s write:packages'"
fi
if [ -z "$(gh auth token 2>/dev/null || true)" ]; then
    fail "$EX_PRECONDITION" "gh auth token returned empty; re-run 'gh auth login'"
fi

# Verify repo-level Actions are disabled (the failsafe that prevents
# upstream workflows from firing on the fork).
ACTIONS_ENABLED=$(gh api "/repos/$FORK_REPO/actions/permissions" --jq '.enabled' 2>/dev/null || echo "unknown")
if [ "$ACTIONS_ENABLED" != "false" ]; then
    fail "$EX_PRECONDITION" \
        "GitHub Actions on $FORK_REPO must be disabled at repo level (got: '$ACTIONS_ENABLED'). \
Settings -> Actions -> 'Disable actions'."
fi

# Builder image must already exist locally.
if ! docker image inspect "$BUILDER_IMAGE" >/dev/null 2>&1; then
    fail "$EX_PRECONDITION" \
        "builder image '$BUILDER_IMAGE' not found. Run: docker build -f Dockerfile.builder -t $BUILDER_IMAGE ."
fi

# lifeatlas-master must be at-or-ahead of master.
git fetch "$ORIGIN_REMOTE" --quiet
if ! git merge-base --is-ancestor "$MASTER_BRANCH" "$RELEASE_BRANCH"; then
    fail "$EX_PRECONDITION" "$RELEASE_BRANCH is not at or ahead of $MASTER_BRANCH; run sync-from-upstream.sh first"
fi

# ─── Phase 2: Compute new version ───────────────────────────────────────
phase 2 13 "compute new version"

CURRENT_VERSION=$(sed -n 's/^version = "\([^"]*\)"$/\1/p' Cargo.toml | head -1)
log "current Cargo.toml version: $CURRENT_VERSION"

# Decompose <base>-la.<MAJOR>.<MINOR>.
BASE=$(echo "$CURRENT_VERSION" | sed -n 's/^\([0-9]*\.[0-9]*\.[0-9]*\)-la\.[0-9]*\.[0-9]*$/\1/p')
MAJOR=$(echo "$CURRENT_VERSION" | sed -n 's/^[0-9]*\.[0-9]*\.[0-9]*-la\.\([0-9]*\)\.[0-9]*$/\1/p')
MINOR=$(echo "$CURRENT_VERSION" | sed -n 's/^[0-9]*\.[0-9]*\.[0-9]*-la\.[0-9]*\.\([0-9]*\)$/\1/p')

if [ -z "$BASE" ] || [ -z "$MAJOR" ] || [ -z "$MINOR" ]; then
    fail "$EX_PRECONDITION" "Cargo.toml version '$CURRENT_VERSION' is not in <base>-la.<MAJOR>.<MINOR> form"
fi

if [ "$BUMP_MAJOR" -eq 1 ]; then
    NEW_MAJOR=$((MAJOR + 1))
    NEW_MINOR=1
    log "--bump-major: MAJOR $MAJOR -> $NEW_MAJOR; MINOR reset to 1"
else
    NEW_MAJOR="$MAJOR"
    NEW_MINOR=$((MINOR + 1))
    log "MINOR $MINOR -> $NEW_MINOR"
fi

NEW_VERSION="${BASE}-la.${NEW_MAJOR}.${NEW_MINOR}"
NEW_TAG="v${NEW_VERSION}"
log "new version: $NEW_VERSION (tag: $NEW_TAG)"

# Refuse if the tag already exists (locally or on origin).
if git rev-parse -q --verify "refs/tags/$NEW_TAG" >/dev/null 2>&1; then
    fail "$EX_PRECONDITION" "tag $NEW_TAG already exists locally"
fi
if git ls-remote --exit-code --tags "$ORIGIN_REMOTE" "refs/tags/$NEW_TAG" >/dev/null 2>&1; then
    fail "$EX_PRECONDITION" "tag $NEW_TAG already exists on $ORIGIN_REMOTE"
fi

if [ "$STATUS_ONLY" -eq 1 ]; then
    emit_status "ready_to_release_as_$NEW_VERSION"
    exit "$EX_OK"
fi

# ─── Phase 3: Bump version in repo ──────────────────────────────────────
phase 3 13 "bump version in repo"

PHASE3_COMMITTED=0
if [ "$DRY_RUN" -eq 1 ]; then
    log "(dry-run) would: sed Cargo.toml; cargo check --workspace --exclude zeroclaw-desktop; git commit"
else
    # Idempotent skip: Cargo.toml may already be at $NEW_VERSION on rerun
    # after a partial failure in a later phase.
    EXISTING_VERSION=$(sed -n 's/^version = "\([^"]*\)"$/\1/p' Cargo.toml | head -1)
    if [ "$EXISTING_VERSION" = "$NEW_VERSION" ]; then
        log "Cargo.toml already at $NEW_VERSION; skipping bump commit (rerun)"
    else
        sed -i "s/version = \"${CURRENT_VERSION}\"/version = \"${NEW_VERSION}\"/g" Cargo.toml
        cargo check --workspace --exclude zeroclaw-desktop 2>&1 | tail -5 >&2 || \
            fail "$EX_CARGO_TEST" "cargo check failed after version bump"
        git add Cargo.toml Cargo.lock
        git commit -m "chore(release): $NEW_TAG"
        PHASE3_COMMITTED=1
    fi
fi

# ─── Phase 4: Run tests in pinned builder image ─────────────────────────
phase 4 13 "cargo test in $BUILDER_IMAGE"

if [ "$DRY_RUN" -eq 1 ]; then
    log "(dry-run) would: docker run ... cargo test --workspace --release --locked"
else
    # Skip the `live` test binary (requires LLM provider credentials per
    # Cargo.toml line ~384). Run lib + bins + the three integration test
    # binaries explicitly.
    if ! docker run --rm \
            -u "$(id -u):$(id -g)" \
            -v "$PWD:/work" \
            -w /work \
            "$BUILDER_IMAGE" \
            sh -c 'cargo test --workspace --exclude zeroclaw-desktop --release --locked --lib --bins \
                && cargo test --release --locked --test component \
                && cargo test --release --locked --test integration \
                && cargo test --release --locked --test system' 2>&1 | tail -30 >&2; then
        log "tests failed"
        if [ "${PHASE3_COMMITTED:-0}" -eq 1 ]; then
            log "rolling back version-bump commit"
            git reset --hard HEAD^
        else
            log "no version-bump commit to roll back (was idempotent skip)"
        fi
        emit_status "cargo_test_failed"
        exit "$EX_CARGO_TEST"
    fi
fi

# ─── Phase 5: Build release binary ──────────────────────────────────────
phase 5 13 "build release binary"

EFFECTIVE_FEATURES="${FEATURES_OVERRIDE:-$LIFEATLAS_RELEASE_FEATURES}"
log "features: $EFFECTIVE_FEATURES"

if [ "$DRY_RUN" -eq 1 ]; then
    log "(dry-run) would: docker run ... ZEROCLAW_UPDATE_REPO=$FORK_REPO cargo build --release --target $TARGET_TRIPLE"
else
    docker run --rm \
        -u "$(id -u):$(id -g)" \
        -v "$PWD:/work" \
        -w /work \
        -e "ZEROCLAW_UPDATE_REPO=$FORK_REPO" \
        "$BUILDER_IMAGE" \
        cargo build --release --target "$TARGET_TRIPLE" --locked --features "$EFFECTIVE_FEATURES"

    BINARY_PATH="target/$TARGET_TRIPLE/release/zeroclaw"
    if [ ! -f "$BINARY_PATH" ]; then
        fail 1 "expected binary $BINARY_PATH not found after cargo build"
    fi

    # Verify --version reports the new version.
    BINARY_VERSION=$("$BINARY_PATH" --version 2>&1)
    if ! echo "$BINARY_VERSION" | grep -qF "$NEW_VERSION"; then
        fail 1 "binary --version output '$BINARY_VERSION' does not contain $NEW_VERSION"
    fi
    log "binary --version: $BINARY_VERSION"

    # Verify the option_env! propagated by checking the embedded URL.
    if ! strings "$BINARY_PATH" | grep -qF "$FORK_REPO"; then
        fail 1 "ZEROCLAW_UPDATE_REPO did not propagate to the binary; aborting"
    fi
    log "verified ZEROCLAW_UPDATE_REPO=$FORK_REPO is embedded in the binary"
fi

# ─── Phase 6: Build web dashboard ───────────────────────────────────────
phase 6 13 "build web dashboard"

if [ "$DRY_RUN" -eq 1 ]; then
    log "(dry-run) would: docker run ... npm ci && npm run build (in /work/web)"
else
    docker run --rm \
        -u "$(id -u):$(id -g)" \
        -v "$PWD:/work" \
        -w /work/web \
        "$BUILDER_IMAGE" \
        sh -c 'rm -rf dist && npm ci && npm run build' 2>&1 | tail -10 >&2

    if [ ! -d web/dist ]; then
        fail 1 "expected web/dist/ not found after npm run build"
    fi
fi

# ─── Phase 7: Package tarball ───────────────────────────────────────────
phase 7 13 "package tarball"

ASSET_NAME="zeroclaw-${TARGET_TRIPLE}.tar.gz"
SHA_FILE="SHA256SUMS"

if [ "$DRY_RUN" -eq 1 ]; then
    log "(dry-run) would: produce $ASSET_NAME and $SHA_FILE in repo root"
else
    rm -rf staging "$ASSET_NAME" "$SHA_FILE"
    mkdir -p staging/web
    cp "target/$TARGET_TRIPLE/release/zeroclaw" staging/
    cp -r web/dist staging/web/dist
    ( cd staging && tar czf "../$ASSET_NAME" zeroclaw web/dist )
    sha256sum "$ASSET_NAME" > "$SHA_FILE"
    log "produced $ASSET_NAME ($(du -h "$ASSET_NAME" | awk '{print $1}'))"
    cat "$SHA_FILE" >&2
fi

# ─── Phase 8: Generate release notes ────────────────────────────────────
phase 8 13 "generate release notes"

NOTES_FILE="release-notes.md"

if [ "$DRY_RUN" -eq 1 ]; then
    log "(dry-run) would: write $NOTES_FILE from CHANGELOG-next.md or git log"
else
    if [ -f CHANGELOG-next.md ]; then
        log "using CHANGELOG-next.md as release notes"
        cp CHANGELOG-next.md "$NOTES_FILE"
    else
        # Find the previous fork tag to bound the log range.
        PREV_TAG=$(git tag -l 'v*-la.*' --sort=-v:refname | head -1 || true)
        if [ -n "$PREV_TAG" ]; then
            RANGE="${PREV_TAG}..HEAD"
        else
            RANGE="HEAD"
        fi
        {
            echo "## Changes since ${PREV_TAG:-fork inception}"
            echo
            git log "$RANGE" --pretty='format:- %s' --no-merges \
                | { grep -iE '^- feat(\(|:)' || true; } \
                | sed 's/ (#[0-9]*)$//' \
                | sort -uf
            echo
            echo
            echo "_Built from \`${BASE}\` upstream base; LA \`${NEW_MAJOR}.${NEW_MINOR}\`._"
        } > "$NOTES_FILE"
        log "wrote $NOTES_FILE"
    fi
fi

# ─── Phase 9: Tag and push ──────────────────────────────────────────────
phase 9 13 "tag and push"

if [ "$DRY_RUN" -eq 1 ]; then
    log "(dry-run) would: git tag -a $NEW_TAG; git push $ORIGIN_REMOTE $RELEASE_BRANCH; git push $ORIGIN_REMOTE $NEW_TAG"
else
    # Idempotency: skip if tag already exists at HEAD (re-running after partial failure).
    if git rev-parse -q --verify "refs/tags/$NEW_TAG" >/dev/null 2>&1; then
        EXISTING_TAG_COMMIT=$(git rev-parse "$NEW_TAG^{commit}")
        HEAD_COMMIT=$(git rev-parse HEAD)
        if [ "$EXISTING_TAG_COMMIT" != "$HEAD_COMMIT" ]; then
            fail 1 "tag $NEW_TAG exists but does not point at HEAD; manual cleanup required"
        fi
        log "tag $NEW_TAG already exists at HEAD; skipping tag step"
    else
        git tag -a "$NEW_TAG" -m "Release $NEW_TAG"
    fi
    git push "$ORIGIN_REMOTE" "$RELEASE_BRANCH"
    git push "$ORIGIN_REMOTE" "$NEW_TAG"
fi

# ─── Phase 10: gh release create ────────────────────────────────────────
phase 10 13 "gh release create"

if [ "$DRY_RUN" -eq 1 ]; then
    log "(dry-run) would: gh release create $NEW_TAG $ASSET_NAME $SHA_FILE --repo $FORK_REPO --latest"
else
    # Idempotency: if the release already exists at this tag, skip creation.
    if gh release view "$NEW_TAG" --repo "$FORK_REPO" >/dev/null 2>&1; then
        log "release $NEW_TAG already exists; skipping create"
    else
        gh release create "$NEW_TAG" "$ASSET_NAME" "$SHA_FILE" \
            --repo "$FORK_REPO" \
            --title "$NEW_TAG" \
            --notes-file "$NOTES_FILE" \
            --latest
    fi
fi

# ─── Phase 11: Build and push docker image to GHCR ──────────────────────
phase 11 13 "docker build and push to GHCR"

if [ "$DRY_RUN" -eq 1 ]; then
    log "(dry-run) would: docker build -f Dockerfile.ci ...; docker push $GHCR_REPO:$NEW_TAG and :latest"
else
    # GHCR auth (uses gh's token; safe to re-run).
    GH_TOKEN_VALUE=$(gh auth token)
    echo "$GH_TOKEN_VALUE" | docker login ghcr.io -u thdqd --password-stdin >/dev/null

    # Prepare a docker-context dir that mirrors what upstream's CI assembles
    # for Dockerfile.ci: pre-built binaries under bin/amd64/zeroclaw plus web/dist
    # plus a default config.
    # Dockerfile.ci expects this exact layout (see Dockerfile.ci:8-20):
    #   bin/${TARGETARCH}/zeroclaw           — the binary
    #   bin/${TARGETARCH}/web/dist           — web dashboard
    #   zeroclaw-data/.zeroclaw/config.toml  — default runtime config
    # For x86_64-unknown-linux-gnu the corresponding TARGETARCH is "amd64".
    DOCKER_CTX=$(mktemp -d)
    trap 'rm -rf "$DOCKER_CTX"' EXIT

    mkdir -p "$DOCKER_CTX/bin/amd64/web"
    cp "target/$TARGET_TRIPLE/release/zeroclaw" "$DOCKER_CTX/bin/amd64/zeroclaw"
    cp -r web/dist "$DOCKER_CTX/bin/amd64/web/dist"

    mkdir -p "$DOCKER_CTX/zeroclaw-data/.zeroclaw" "$DOCKER_CTX/zeroclaw-data/workspace"
    printf '%s\n' \
        'workspace_dir = "/zeroclaw-data/workspace"' \
        'config_path = "/zeroclaw-data/.zeroclaw/config.toml"' \
        'api_key = ""' \
        'default_provider = "openrouter"' \
        'default_model = "anthropic/claude-sonnet-4-20250514"' \
        'default_temperature = 0.7' \
        '' \
        '[gateway]' \
        'port = 42617' \
        'host = "[::]"' \
        'allow_public_bind = true' \
        'web_dist_dir = "/zeroclaw-data/web/dist"' \
        > "$DOCKER_CTX/zeroclaw-data/.zeroclaw/config.toml"

    cp Dockerfile.ci "$DOCKER_CTX/Dockerfile"

    docker build \
        --platform linux/amd64 \
        --build-arg TARGETARCH=amd64 \
        -f "$DOCKER_CTX/Dockerfile" \
        -t "$GHCR_REPO:$NEW_TAG" \
        -t "$GHCR_REPO:latest" \
        "$DOCKER_CTX"

    docker push "$GHCR_REPO:$NEW_TAG"
    docker push "$GHCR_REPO:latest"

    log "pushed $GHCR_REPO:$NEW_TAG and :latest"
fi

# ─── Phase 12: Smoke verification ───────────────────────────────────────
phase 12 13 "smoke verification"

if [ "$DRY_RUN" -eq 1 ]; then
    log "(dry-run) would: docker run --rm $GHCR_REPO:$NEW_TAG --version; gh api releases/latest"
else
    # Pull the just-pushed image (force pull, no cache) and verify --version.
    docker pull "$GHCR_REPO:$NEW_TAG" >/dev/null
    IMAGE_VERSION=$(docker run --rm "$GHCR_REPO:$NEW_TAG" --version 2>&1)
    if ! echo "$IMAGE_VERSION" | grep -qF "$NEW_VERSION"; then
        fail 1 "GHCR image --version '$IMAGE_VERSION' does not contain $NEW_VERSION"
    fi
    log "GHCR image reports: $IMAGE_VERSION"

    # Verify GH releases API reports the new release as latest.
    LATEST_TAG=$(gh api "/repos/$FORK_REPO/releases/latest" --jq '.tag_name')
    if [ "$LATEST_TAG" != "$NEW_TAG" ]; then
        fail 1 "GH releases latest is '$LATEST_TAG', expected '$NEW_TAG'"
    fi
    log "GH releases /latest = $LATEST_TAG"
fi

# ─── Phase 13: Report ───────────────────────────────────────────────────
phase 13 13 "report"

log ""
log "======================================================================"
log "  Released $NEW_TAG"
log "  GH release: https://github.com/$FORK_REPO/releases/tag/$NEW_TAG"
log "  GHCR image: $GHCR_REPO:$NEW_TAG"
log "  Asset:      $ASSET_NAME"
if [ -f "$SHA_FILE" ]; then
    log "  Checksum:   $(awk '{print $1}' "$SHA_FILE")"
fi
log "======================================================================"

emit_status "released"
exit "$EX_OK"
