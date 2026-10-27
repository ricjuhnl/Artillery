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
# 1.32.18 discovers Instagram's required GraphQL variables and reports API
# errors directly. Do not patch installed extractor source on each boot.
pip install --no-cache-dir --upgrade 'gallery-dl>=1.32.18'

log "Updating yt-dlp to latest..."
pip install --no-cache-dir --upgrade yt-dlp

log "Ensuring ffmpeg is installed..."
if ! command -v ffmpeg > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/*
else
  log "ffmpeg already present ($(ffmpeg -version 2>&1 | head -1))"
fi

# Remove only Artillery's run lock, not download/archive lock files.
find "$TASKS_DIR" -mindepth 2 -maxdepth 2 -type f -name lock -print -delete || true


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



# Numeric users may inherit HOME=/root or have no passwd home. XDG_CACHE_HOME
# controls gallery-dl's default cache independently of HOME/gosu's handling.
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$CONFIG_DIR/.cache}"
mkdir -p "$XDG_CACHE_HOME"
chown "$PUID:$PGID" "$XDG_CACHE_HOME"

log "Starting web app as $APP_USER_SPEC..."
# Exec gunicorn as the chosen user so it writes files with correct ownership
exec gosu "$APP_USER_SPEC" "$@"
