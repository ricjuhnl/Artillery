# AGENTS.md

This file provides guidance to the AI agent when working with code in this repository.

## Project Overview

Artillery is a Flask web UI for [gallery-dl](https://github.com/mikf/gallery-dl): create cron-scheduled download tasks, one-off downloads, a media wall dashboard, config editor, OAuth flows, and fullscreen image kiosks. It's a LAN app (no auth by design) deployed in Docker on Unraid.

The entire backend is a single file: `app.py` (~3000 lines). There are no tests, no linter, and no CI beyond the Docker Hub publish workflow (`.github/workflows/docker-publish.yml`, tags `year.month.build`).

## Commands

```bash
# Local development (Flask dev server on :5000)
pip install -r requirements.txt
export TASKS_DIR=/tmp/tasks CONFIG_DIR=/tmp/config DOWNLOADS_DIR=/tmp/downloads
python app.py

# Production (what the container does)
# entrypoint.sh -> gunicorn -b 0.0.0.0:80 --workers 1 --worker-class gthread --threads 16 app:app
```

There is no test suite; verify changes by running the dev server and exercising the UI.

## Architecture

### File-based state (no DB for tasks)

All task state lives as plain files, not a database:

- **Tasks** live in `$TASKS_DIR/<slug>/` where slug = `slugify(name)` (lowercase alphanumerics + hyphens):
  - `name.txt`, `urls.txt` (one URL/line), `command.txt` (gallery-dl command, default `gallery-dl --input-file urls.txt`), `cron.txt` (5-field cron), `timeout.txt`, `last_run.txt`, `last_error.txt`
  - Sentinel files: `lock` (running), `paused` (skip cron; manual runs still allowed), `error` (last run failed), `stopped`, `pid`
  - `run_history.jsonl` (last 100 runs via `_record_run`), optional `archive.sqlite` / `cookies.txt` / `oauth_site.txt`
  - `logs.txt` — rotated to an archived file by `_rotate_logs` on each run
- **Config**: `$CONFIG_DIR/gallery-dl.conf` (shared by all tasks via `GALLERY_DL_CONFIG` env), plus settings files: `gallery-dl.artillery.conf` (Artillery-managed hotleak pacing config, regenerated — never hand-edit), `task_concurrent_max.txt`, `mediawall_enabled.txt`, `mediawall_scan_cron.txt`, `mediawall.notify`, `.secret_key`, `oauth_cache/<site>.sqlite3`, `one_time_download.{log,pid,stop}`
- **Kiosks**: `$CONFIG_DIR/kiosks/<kslug>/settings.json` + `images/`
- **Media wall cache**: `$CONFIG_DIR/media_wall/` (hashed copies of recent downloads)

Use the `read_text()` / `write_text()` helpers (UTF-8, `error="replace"` fallback for corrupted logs). Slugs are validated with `is_valid_slug()` (`^[a-z0-9][a-z0-9-]*$`) at the top of every `<slug>` route — keep doing this to block path traversal.

### Stream (m3u8/DASH) support

- gallery-dl has no extractor for raw `.m3u8`/`.mpd` URLs ("Unsupported URL", exit 64). Artillery detects such URLs (and known video pages) and routes them to **yt-dlp** instead:
  - **One-time downloads** (`run_one_time_download`): resolves the URL, then runs `yt-dlp` (see below) if it's a stream.
  - **Tasks** (`/tasks` POST): if the URLs are stream URLs/video pages and the command is the default gallery-dl one, a yt-dlp command is auto-generated. Hand-written commands are left alone (a warning is flashed if gallery-dl is used with stream URLs).
  - **Run time** (`run_task_background`): for `yt-dlp ... --batch-file urls.txt` commands (a hand-written `--input-file urls.txt` is matched too), every URL line is re-resolved into `.resolved_urls.txt` (deleted after the run) — needed because signed stream URLs expire within minutes, so scheduled tasks must fetch a fresh one each run. A video page passed as a positional argument is resolved too.
- **hotleak.vip video pages** (`/<model>/video/<id>`): the signed m3u8 is embedded obfuscated in a `data-video` attribute, decoded client-side as `base64decode(src[16:-16][::-1])` — reimplemented in `_decode_hotleak_src()` / `_resolve_hotleak_video_page()`. If the site changes its obfuscation, only those two helpers break.
- **Pacing / 429 protection** — hotleak's CDN rate-limits per IP, so every request path is paced:
  - **Standalone yt-dlp** (raw stream URLs / hotleak video pages): browser User-Agent + Referer, `--sleep-requests`, plus `ARTILLERY_STREAM_EXTRA_ARGS`. Override via env (below).
  - **gallery-dl tasks that contain hotleak URLs** (creator pages, video posts — gallery-dl has a native `hotleak` extractor and downloads the videos with an *embedded* yt-dlp module, which never sees CLI flags). Artillery writes a small managed config `$CONFIG_DIR/gallery-dl.artillery.conf` (`_ensure_stream_pacing_config()`, regenerated at boot and before each run — don't edit it by hand) and appends it to every gallery-dl command at run time with `-c` (`_append_stream_pacing_config()`, so pre-existing tasks are fixed without re-editing). It sets `extractor.hotleak.*` sleep/retry/429-backoff for gallery-dl's own requests and `extractor.hotleak.ytdl.raw-options` for the embedded yt-dlp (per-manifest sleep, randomized per-video sleep `ARTILLERY_STREAM_VIDEO_SLEEP`, native HLS, fragment retries, browser UA/Referer).
  - **Artillery's own page fetches** (`_fetch_url_text`): paced per origin (`_throttle_host`, ARTILLERY_STREAM_SLEEP) and retried with backoff on 429/5xx honoring `Retry-After` / `X-RateLimit-Reset`.
  - **Unresolvable video pages are dropped**, not handed to yt-dlp (its generic extractor would refetch the page 5× and burn through the rate limit). If *nothing* is left to download the run is skipped with a log line and retried next cron tick.
  - **Runs on the same rate-limited origin are serialized** (`_acquire_origin_locks` / per-origin locks): two tasks downloading from hotleak.vip at once double the request rate and trip the limiter even with per-request pacing. Other sites run in parallel as before.

### Scheduling — APScheduler inside the web process

- `scheduler.py` is a **dead stub** (kept for reference only). Scheduling is the APScheduler `BackgroundScheduler` (`_bg_scheduler`) started at import time in `app.py`.
- Jobs load from `cron.txt` at boot (`_load_all_schedules`); task create/edit/delete calls `_reschedule_task` / `_unschedule_task`.
- **Critical: gunicorn must run with `--workers 1`** (see Dockerfile CMD). The scheduler is in-memory and in-process; multiple workers would fire every job N times.
- Cron triggers are parsed with APScheduler `CronTrigger`; UI-side next-run display uses `croniter`.
- Scheduled trigger → `_run_scheduled_task` → atomic `lock` creation (`O_CREAT|O_EXCL`) → daemon thread `run_task_background`.

### Task execution

`run_task_background(task_folder)`:
1. Acquires a concurrency slot (`_acquire_task_slot` — condition variable, max `TASK_CONCURRENT_MAX`, default 5, persisted in `task_concurrent_max.txt`).
2. Rotates logs, clears error sentinel, reads `command.txt`.
3. Runs `shlex.split(command)` via `subprocess.Popen` with cwd = task folder, `GALLERY_DL_CONFIG` env set, stdout/stderr appended to `logs.txt`; writes `pid` file; honors per-task timeout (default `TASK_TIMEOUT_SECONDS`, 0 = none) by killing the process. For gallery-dl commands the hotleak pacing config is appended via `-c` at run time, and runs on the same rate-limited origin are serialized (see Stream section above).
4. Records the run in `run_history.jsonl` (serialized by `_HISTORY_LOCK`), touches `error`/`last_error.txt` on failure, and in `finally` releases the slot and removes `lock`/`pid`.
5. Post-run cleanup invalidates task caches and calls `touch_mediawall_notify()` (triggers the media wall refresh).

One-time downloads (`run_one_time_download`) are a separate single global runner with its own log/pid/stop files in `$CONFIG_DIR`.

### Media wall

Background thread `_media_wall_scan_worker` (started at boot) fires on a cron expression (`mediawall_scan_cron.txt`, default `*/1 * * * *`). On fire it tails each task's `logs.txt` (and falls back to walking `$DOWNLOADS_DIR`) for media paths (`.jpg .jpeg .png .gif .webp`, plus video if `MEDIA_WALL_CACHE_VIDEOS=1`), samples up to `MEDIA_WALL_COPY_LIMIT` (100) files, and copies them into `$CONFIG_DIR/media_wall/` as sha1-hashed filenames. `MEDIA_WALL_REFRESH_LOCK` prevents concurrent refreshes; `MEDIA_WALL_MIN_REFRESH_SECONDS` throttles them. Frontend refreshes via polling or optional SSE (`/mediawall/events`, `MEDIA_WALL_SSE=1`) keyed off `mediawall.notify` mtime.

### OAuth

`/oauth` + `/api/oauth/*` run `gallery-dl oauth:<site>` as a subprocess for: deviantart, reddit, tumblr, flickr, mastodon, pixiv. The token cache is shared at `$CONFIG_DIR/oauth_cache/<site>.sqlite3` (legacy per-task caches are migrated on load). **Pixiv is special**: its redirect URI isn't localhost, so gallery-dl reads the code from stdin — Artillery handles that via the paste endpoint instead of the local `:6414` listener.

### Web layer

- Flask + Jinja2 (`templates/`), Bootstrap 5, single `static/style.css`. No login; CSRF via Flask-WTF with `WTF_CSRF_TIME_LIMIT = None` (tabs are left open all day; don't "fix" this back to a timed limit).
- Every response gets `Connection: close` (`_no_keepalive`) to dodge gunicorn misparsing stale pooled sockets from backgrounded tabs.
- Main routes: `/` (media wall dashboard), `/tasks` (GET list / POST create), `/tasks/<slug>/action` (POST run/pause/resume/delete/stop/edit), `/tasks/<slug>/logs` (JSON, polled every 1s by the output viewer), `/tasks/<slug>/logs/stream` (SSE), `/config` (gallery-dl.conf editor + backup/restore + update check), `/one-time*`, `/oauth*`, `/kiosks*` (manage) and `/kiosk/<kslug>` (fullscreen display), `/mediawall/*`, `/api/*` (disk, queue, tasks, config/tools update checks), `/healthz`.
- Task listing is cached (`_TASK_LIST_CACHE`, 2s TTL) with per-slug entries keyed on file mtimes; call `_invalidate_task_cache()` / `_TASK_CACHE.pop(slug)` after mutations.

## Conventions

- Helpers are `_`-prefixed functions near the top of `app.py`; routes are decorated functions appended below. Keep new code in `app.py` — the project is intentionally a single-file app.
- State = files + sentinel files; prefer touching/removing sentinels over introducing a database for task state.
- Long work runs in daemon threads (`threading.Thread(..., daemon=True)`); never block the request path on a download.
- Log output goes to `logs.txt` with a `==== Run at <iso> ====` header and trailing status line ("Task finished successfully." / "Task stopped." / "Task timed out..." / "Task exited with code N.") — the media wall and recent-downloads parsing depend on log lines containing paths under `$DOWNLOADS_DIR`.
- Timezone: `TZ` env var drives all scheduling and displayed timestamps; `_utcnow()` is ISO-8601 UTC.

## Key environment variables

- `TASKS_DIR` / `CONFIG_DIR` / `DOWNLOADS_DIR` — mounts (default `/tasks`, `/config`, `/downloads`)
- `TZ`, `PUID`, `PGID`, `CHOWN_DOWNLOADS` — Unraid-style ownership (handled in `entrypoint.sh`)
- `SECRET_KEY` — else a persistent one is generated at `$CONFIG_DIR/.secret_key`
- `TASK_CONCURRENT_MAX` (default 5), `TASK_TIMEOUT_SECONDS` (default 0 = none)
- `MEDIA_WALL_*` — `ENABLED` (1), `SCAN_CRON` (`*/1 * * * *`), `COPY_LIMIT` (100), `CACHE_VIDEOS` (0), `MIN_REFRESH_SECONDS` (300), `SSE` (0), `ITEMS` (45), `LOG_TAIL_LINES` (2000)
- `ARTILLERY_STREAM_UA` (browser Chrome UA), `ARTILLERY_STREAM_SLEEP` (1 s between stream HTTP requests, 0 = off — also paces Artillery's own resolution page fetches), `ARTILLERY_STREAM_EXTRA_ARGS` (extra shlex-split yt-dlp args for stream downloads), `ARTILLERY_STREAM_VIDEO_SLEEP` (5 s randomized pause before each hotleak video in gallery-dl's embedded yt-dlp, 0 = off)
- `ARTILLERY_LOG_LEVEL`, `ARTILLERY_DEBUG_REQUESTS`, `ARTILLERY_DEBUG_FS`, `ARTILLERY_HANG_DUMP_SECONDS` (faulthandler thread dump)
- `GALLERYDL_DEFAULT_CONFIG_URL` — bootstrap config source in `entrypoint.sh`

## Deployment notes

- `entrypoint.sh` runs as root, chowns the mount dirs to PUID/PGID, upgrades gallery-dl + yt-dlp via pip, ensures ffmpeg, deletes stale `*lock*` files in `/tasks`, then `gosu`'s down to run gunicorn.
- `Dockerfile` (python:3.12-slim + gosu) pins the production command: **one gthread worker, 16 threads, port 80** — see the single-worker warning above.
- Releases are tagged `year.month.build` (build resets monthly) by the docker-publish workflow; `main` publishes.