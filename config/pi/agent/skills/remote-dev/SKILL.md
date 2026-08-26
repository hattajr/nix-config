---
name: remote-dev
description: "Set up or run the `make dev` workflow for a project developed on a remote Linux box with a Mac client — SSH -R tunnel via devtunnel, ephemeral service containers via testcontainers with Ryuk cleanup, and a thin dev.py launcher. Use when asked to run dev / run make dev, or to set up local dev tooling on a remote box."
---

The user builds on a remote Linux box and browses/tests from a Mac laptop. `make dev` must always give: a working tunnel to the laptop, ephemeral backing services (Postgres/S3/etc.), and clean teardown on Ctrl-C — no matter how the process dies.

## Running an existing project

If `Makefile` already has a `dev:` target, just run `make dev`. Do not re-scaffold. Only step in if it's broken (see Troubleshooting).

## Scaffolding a new project

### 1. Makefile `dev` target

Orchestration only — no tunnel or container logic belongs here beyond calling out to `devtunnel`.

```make
dev:        ## run hot-reload dev server (ephemeral postgres) + devtunnel to laptop
	@command -v devtunnel >/dev/null || { echo "devtunnel not found on PATH"; exit 1; }
	@APP_PORT=$$(grep '^APP_PORT=' .env.dev | cut -d= -f2 | tr -d ' '); \
	devtunnel $$APP_PORT $$APP_PORT mbp & \
	TUNNEL_PID=$$!; \
	trap 'pkill -TERM -P $$TUNNEL_PID 2>/dev/null; kill -TERM $$TUNNEL_PID 2>/dev/null' EXIT INT TERM; \
	uv run --env-file .env.dev dev.py
```

- `devtunnel <local-port> <remote-port> <ssh-host>` is already solved (reconnect-on-drop, preflight, non-interactive SSH) — never reimplement its retry/preflight logic inline.
- The `trap` only needs to kill the tunnel; `dev.py` owns its own container cleanup (see below).

### 2. `dev.py` launcher

This is a launcher, not the app. Keep it to: start containers → export resolved env vars → (optional) seed → run app.

- Start each needed service with `testcontainers` (`testcontainers.postgres.PostgresContainer`, `testcontainers.localstack.LocalStackContainer`, etc.). Ryuk cleans these up automatically even on `kill -9` or a dropped SSH session — never add manual `docker rm`/`atexit` cleanup on top of it.
- Use `with container:` (nest with `contextlib.ExitStack` for multiple services) so teardown runs even if the app raises during startup.
- After the container is up, override the relevant env vars (`RDB_HOST`, `RDB_PORT`, ...) in `os.environ` *before* starting the app — this in-process env override is the reason this needs to be Python and not bash; a Makefile can't cleanly inject a dynamically-assigned container port into the app's own process env.
- Only add schema/seed functions (`_create_schema`, `_seed_*`) if the user describes actual dev data needs. Don't scaffold empty seed hooks — YAGNI.
- Wrap the app's `run()` call in `try/except KeyboardInterrupt: pass` so Ctrl-C exits quietly instead of a traceback.

### 3. Before scaffolding, confirm scope

Ask (don't assume) which ephemeral services the project needs — Postgres only? + S3/LocalStack? something else? — and add the matching `uv add testcontainers[...]` extra.

## Troubleshooting

- Tunnel not reachable from the Mac → run `devtunnel --help`, not this skill; it documents the two-channel model (control vs. page-fetch) and the exact preflight/verify steps.
- Container leaks after a crash → should not happen with Ryuk; if it does, check Ryuk's own container is running (`docker ps | grep ryuk`) rather than adding manual cleanup.

## Non-goals

- Don't embed devtunnel's reconnect/preflight logic into the Makefile.
- Don't switch to `docker-compose` for backing services unless the user explicitly prefers it — it loses Ryuk's crash-safe cleanup and the dynamic port/env injection `testcontainers` gives for free.
