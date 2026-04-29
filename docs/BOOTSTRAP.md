# Bootstrap contract — `THDQD/zeroclaw-la-fork` images

This document describes what the LifeAtlas-flavored `zeroclaw` docker image expects from its container host (typically `claw-auth-proxy`).

## Image references

- Pinned by tag: `ghcr.io/thdqd/zeroclaw-la-fork:v<base>-la.<MAJOR>.<MINOR>`. First published release: `:v0.7.3-la.1.1`.
- Pinned by digest (strictest — byte-identical across pulls, resists tag-rewrite): `ghcr.io/thdqd/zeroclaw-la-fork@sha256:<digest>`. Resolve a tag to its digest with `docker manifest inspect ghcr.io/thdqd/zeroclaw-la-fork:v0.7.3-la.1.1`.
- Floating: `ghcr.io/thdqd/zeroclaw-la-fork:latest` (always points at the most recent release; **do not use** for production fleet, pin instead).

## Container expectations

### Volumes

The image expects `/zeroclaw-data` to be a volume mount. Without this, all state (workspace, memory, sessions, config) is lost on container recreation. The `/zeroclaw-data` directory must contain (or be writable to create):

- `/zeroclaw-data/.zeroclaw/config.toml` — runtime configuration (the image ships a sensible default; the proxy should overlay user-specific values via env-var overrides or a mounted file).
- `/zeroclaw-data/workspace/` — agent workspace.
- `/zeroclaw-data/web/dist/` — web dashboard assets (baked in by the image build; can be left as-is).

### Environment variables

The image is sensitive to the standard `ZEROCLAW_*` env vars (see `crates/zeroclaw-config/src/schema.rs`). Notably for LifeAtlas:

- `ZEROCLAW_CHANNELS_LIFEATLAS_ENABLED=true`
- `ZEROCLAW_CHANNELS_LIFEATLAS_WEBHOOK_URL=http://proxy:8000/zeroclaw/push`
- `ZEROCLAW_CHANNELS_LIFEATLAS_AUTH_TOKEN=<bearer-token>`

The proxy provisions these per-container.

### Network

- Inbound on port 42617 (default — `EXPOSE 42617` in the image):
  - `GET /health` — readiness/liveness probe; returns 200 when the agent is up. Use this for container readiness gates rather than parsing logs.
  - `GET /ws/chat` — WebSocket endpoint for chat traffic from the proxy.
  - Other endpoints under `/` and `/api/*` (sessions, cron, memory, channels, web dashboard) — see the gateway crate for the full surface.
- Outbound:
  - HTTPS to `api.github.com` (for `zeroclaw update` — fetches new release tarballs from `https://api.github.com/repos/THDQD/zeroclaw-la-fork/releases/latest`). The update repo is baked into the binary at compile time via `option_env!`; runtime overrides are not supported.
  - HTTPS to whatever LLM provider is configured (e.g., `api.anthropic.com`, `api.openai.com`, `openrouter.ai`).

## Bootstrap flow (one-time per container)

For each existing upstream-shaped container being migrated:

1. Stop the container.
2. Recreate from `ghcr.io/thdqd/zeroclaw-la-fork:v<pinned-tag>` with the same `/zeroclaw-data` volume.
3. Start. The patched binary now queries `https://api.github.com/repos/THDQD/zeroclaw-la-fork/releases/latest` for future updates.
4. Validate: `docker exec <container> zeroclaw --version` shows the LA suffix; the LifeAtlas channel functions end-to-end with the proxy webhook.

## Steady state

After bootstrap, containers self-update via `zeroclaw update` against the fork's GitHub releases. No further proxy involvement is needed for binary updates. The web dashboard (`web/dist`) is only refreshed when the container is recreated from a newer image.

## Release cadence

The fork merges upstream master roughly weekly and publishes a new tag `v<base>-la.<MAJOR>.<MINOR>`:

- **MINOR** increments on every release; resets to 1 on a MAJOR bump.
- **MAJOR** increments manually when the fork crosses a LifeAtlas epoch (rare).
- **base** (the `0.7.3` part) advances when upstream cuts a new patch/minor and the fork's sync script rolls forward.

Containers can pick up new releases two ways:

1. **In-place self-update** (built-in CLI): the running binary fetches the latest fork tag via `zeroclaw update`. Triggered manually or by a cron inside the container. Updates only the binary, not `web/dist`.
2. **Image recreation** (proxy-driven, recommended for fleet ops): the proxy stops the container and recreates it from a newer image tag. Required to refresh the bundled `web/dist` assets and to keep proxy-managed config aligned.

For predictable rollouts, pin to a specific tag and bump on the proxy's own schedule rather than relying on `:latest` or in-place updates.

## Pinning policy

Pin to a specific tag (or digest) for production. Do not use `:latest`. A bad release published to `:latest` would otherwise propagate to every fresh container.
