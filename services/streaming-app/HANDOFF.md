# Handoff — continuing streaming-app dev on another machine

Written 2026-09-03 so a fresh Claude Code session (or you) can pick this up
cold on a different machine without re-deriving context.

## What's running

`services/streaming-app/` is a self-hosted fork of
[xalonious/streaming-app](https://github.com/xalonious/streaming-app)
(Express backend + React frontend), built from source via
`backend.Dockerfile` / `frontend.Dockerfile` (multi-stage, pinned to a commit
SHA, `git clone` + build inside the image — see `ARG STREAMING_APP_REF`).
Playback source is [vidking.net](https://www.vidking.net) embeds. Routed by
Traefik at `movies.home.meshwa.space` / `movies.homeserver.com`. It's up and
healthy as of this writing.

Feature roadmap / what's built vs. not: see `TODO.md` in this same directory.

## Immediate ask: player needs optimization + UI rework

This was the trigger for this handoff — not yet scoped or started. No code
changes made yet toward it. Worth looking at first:
- `frontend/src/pages/PlayerPage.tsx` (or wherever the vidking `<iframe>` is
  mounted) — likely candidate for perf/UX issues.
- vidking's postMessage API (`PLAYER_EVENT`, `MEDIA_DATA`) is documented at
  https://www.vidking.net/#documentation — not yet wired up to anything
  (no continue-watching / progress tracking exists yet, it's TODO #1).
- No specifics on what's laggy/ugly were given yet — get that from the user
  before guessing at fixes.

## Env vars you need (NOT in git — shared/.env is gitignored)

Copy `shared/.env` from the original machine by hand (scp or similar) before
`docker compose up` will work here. Relevant keys for this service:
- `STREAMING_APP_TMDB_API_KEY` — user's real TMDB v3 API key
- `STREAMING_APP_STREAM_SOURCE=https://www.vidking.net`
- A large comment block right above/below those two documents drop-in
  fallback player sources if vidking ever goes down (2embed.stream is the
  best drop-in; vidsrc mirrors need per-title testing; vidlink/autoembed/
  smashystream need code changes to `streamService.ts`'s URL builder since
  their path shapes differ).

## Other loose ends from the same work session (lower priority, FYI)

- **TMDB `ECONNRESET`**: intermittent connection resets seen while testing
  the backend against TMDB's API. Investigated at length (keep-alive
  agent, IPv6/Happy Eyeballs, etc.) — no root cause found, a speculative fix
  was tried and reverted because it didn't help. Current theory: TMDB/
  CloudFront-side flakiness, possibly worsened by rapid-fire test requests.
  Unconfirmed whether it still happens under normal browser use — ask the
  user if it's recurred.
- **Docker log rotation**: `shared/daemon.json.example` has `log-driver`/
  `log-opts` added, but the *live* `/etc/docker/daemon.json` on the original
  server does **not** have it yet — needs `sudo` to edit +
  `systemctl restart docker`, was left for the user to run themselves.
- **Kiwix**: was crash-looping on empty data (unrelated to this repo's
  history — a previous machine's data never carried over). Mirror URL is now
  `KIWIX_MIRROR_URL` in `shared/.env` (was hardcoded, moved per user request
  after Kiwix silently changed domains). Currently mid-download of the
  `devdocs` category (`services/kiwix/data/*.zim`, some `.tmp` in progress) —
  not blocking, just don't be surprised by partial files there.
- **WUD auto-update**: fixed — `wud.watch.digest=true` added to all
  floating-tag services so WUD can actually see updates;
  `wud.watch=false` added to vpn/dns/traefik (confirmed applied to the live
  containers) since those only update via the new idle-gated
  `scripts/idle-critical-update.sh` (cron at 3am nightly), never WUD's
  immediate-apply cycle.
- **Vercel DNS**: root-caused an earlier "Server Not Found" over Tailscale to
  a stale A record for `*.home.meshwa.space`. Diagnosis was given to the
  user; never confirmed whether they actually updated the Vercel record.
- Legacy root `Makefile` — still present alongside `./lab`, never resolved
  whether to delete it.

## How this got here

Originally developed interactively with Claude Code on the homelab server
itself. Moved to this machine per user request (wanted a real browser on the
dev machine to test UI changes, rather than developing on a headless server).
No conversation history carried over — this file is the bridge. The
session that wrote this is at:
https://claude.ai/code/session_01GHjbfnGXfVRGa2U2MpYJ5F
