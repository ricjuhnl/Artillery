#!/bin/sh
set -e

cat <<'BANNER' >&2
 ###  ####  ##### ##### #     #     ##### ####  #   #
#   # #   #   #     #   #     #     #     #   #  # #
##### ####    #     #   #     #     ####  ####    #
#   # #  #    #     #   #     #     #     #  #    #
#   # #   #   #   ##### ##### ##### ##### #   #   #
                scheduled media downloader
BANNER

log() {
  printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

# Unraid-style PUID / PGID
PUID="${PUID:-0}"
PGID="${PGID:-0}"
CHOWN_DOWNLOADS="${CHOWN_DOWNLOADS:-0}"

# Ensure directories exist (Unraid maps these)
: "${TASKS_DIR:=/tasks}"
: "${CONFIG_DIR:=/config}"
: "${DOWNLOADS_DIR:=/downloads}"


mkdir -p "$TASKS_DIR" "$CONFIG_DIR" "$DOWNLOADS_DIR"

# Ensure media wall cache is writable (non-critical cache)
mkdir -p "$CONFIG_DIR/media_wall"
chmod 777 "$CONFIG_DIR/media_wall" 2>/dev/null || true

# Bootstrap a default gallery-dl.conf on first run, so a brand-new install
# has something sane to edit instead of failing every task until someone
# remembers to hit "Reset" on the Config page. Only runs when there's no
# config file at all yet — never touches one that already exists, even an
# empty one (an intentionally-cleared config is still a choice).
GALLERYDL_DEFAULT_CONFIG_URL="${GALLERYDL_DEFAULT_CONFIG_URL:-https://raw.githubusercontent.com/mikf/gallery-dl/master/docs/gallery-dl.conf}"
CONFIG_FILE="$CONFIG_DIR/gallery-dl.conf"
if [ ! -f "$CONFIG_FILE" ]; then
  log "No gallery-dl.conf found — downloading default config from GitHub..."
  if wget -q -O "$CONFIG_FILE.tmp" "$GALLERYDL_DEFAULT_CONFIG_URL"; then
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    log "Default gallery-dl config installed at $CONFIG_FILE"
  else
    rm -f "$CONFIG_FILE.tmp"
    log "WARNING: could not download default config from $GALLERYDL_DEFAULT_CONFIG_URL — starting without one (use Config > Reset in the UI to retry)."
  fi
fi

#######################
chown -R "$PUID:$PGID" "$TASKS_DIR" "$CONFIG_DIR" 2>/dev/null || true
chmod -R 775 "$TASKS_DIR" "$CONFIG_DIR" 2>/dev/null || true  # ADD THIS



log "Updating gallery-dl to latest..."
pip install --no-cache-dir --upgrade gallery-dl

# Workaround for gallery-dl 1.32.x: Instagram now requires the
# __relay_internal__pv__PolarisProfileRingsGradientEnabledrelayprovider
# variable in PolarisProfilePageContentQuery, but _user_by_id_impl() sends a
# hardcoded variable set without it. Every user lookup then fails with
# "missing_required_variable_value" (a 200 body without 'data'), which
# gallery-dl reports as "Requested user could not be found".
# Insert the missing variable into the installed copy until upstream ships
# the fix. Idempotent: skipped once the flag is present (already patched
# this boot, or fixed upstream).
python3 - <<'PYEOF' || log "WARNING: gallery-dl instagram.py patch step failed (non-fatal)"
import pathlib, re
try:
    import gallery_dl
except ImportError:
    raise SystemExit(0)
path = pathlib.Path(gallery_dl.__file__).parent / "extractor" / "instagram.py"
src = path.read_text()
flag = "PolarisProfileRingsGradientEnabledrelayprovider"
if flag in src:
    raise SystemExit(0)
pattern = re.compile(
    r'(_user_by_id_impl\(self, user_id\):.*?)'
    r'("PolarisShortDramaEnabledrelayprovider":\s*True,)(\n)( +\})',
    re.S)
patched, n = pattern.subn(
    r'\1\2\3            "__relay_internal__pv__"\n'
    r'            "PolarisProfileRingsGradientEnabledrelayprovider": False,\n\4',
    src, count=1)
if n:
    path.write_text(patched)
    print("Patched gallery-dl instagram.py (PolarisProfileRingsGradient variable)")
else:
    print("WARNING: gallery-dl instagram.py layout changed, patch not applied")
PYEOF

log "Updating yt-dlp to latest..."
pip install --no-cache-dir --upgrade yt-dlp

log "Ensuring ffmpeg is installed..."
if ! command -v ffmpeg > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/*
else
  log "ffmpeg already present ($(ffmpeg -version 2>&1 | head -1))"
fi

# remove stale lock files from previous container run
find /tasks -maxdepth 2 -type f -iname "*lock*" -print -delete || true


# Decide how we run things: as root or as numeric uid:gid
if [ "$PUID" != "0" ] && [ "$PGID" != "0" ]; then
  APP_USER_SPEC="$PUID:$PGID"
  log "Using PUID=$PUID PGID=$PGID for ownership and processes"

  # Own the mapped directories (best effort)
  chown -R "$PUID:$PGID" "$TASKS_DIR" "$CONFIG_DIR" 2>/dev/null || true
  if [ "$CHOWN_DOWNLOADS" = "1" ]; then
    log "Chowning downloads (may be slow on large libraries)..."
    chown -R "$PUID:$PGID" "$DOWNLOADS_DIR" 2>/dev/null || true
  else
    log "Skipping downloads chown (set CHOWN_DOWNLOADS=1 to enable)"
  fi
else
  APP_USER_SPEC="root"
  log "PUID/PGID not set (or zero), running as root."
fi

# Scheduling is handled by APScheduler running inside the web process.




#######################
UMASK="${UMASK:-002}"
umask "$UMASK"



# Tools run as the app user (e.g. gallery-dl) resolve ~ for their caches.
# Non-root users have no HOME set in this image, so they fall back to an
# unwritable /.cache. Default HOME to the writable config mount; an explicit
# HOME from the environment still wins.
export HOME="${HOME:-$CONFIG_DIR}"

log "Starting web app as $APP_USER_SPEC..."
# Exec gunicorn as the chosen user so it writes files with correct ownership
exec gosu "$APP_USER_SPEC" "$@"
