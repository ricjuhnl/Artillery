#!/bin/sh
# Rebuild the Artillery fork and swap the container in place.
set -e
cd "$(dirname "$0")"
git pull --ff-only
docker build -t artillery:fork .
docker stop artillery 2>/dev/null || true
docker rm artillery
docker run -d --name artillery \
  --restart unless-stopped \
  --label "net.unraid.docker.icon=https://raw.githubusercontent.com/ObviousViking/Artillery/refs/heads/main/logo.png" \
  --label "net.unraid.docker.webui=http://[IP]:[PORT:80]/" \
  -p 8088:80 \
  -e PUID=99 -e PGID=100 -e TZ=Europe/Berlin \
  -e ARTILLERY_STREAM_SLEEP=3 \
  -v /mnt/user/appdata/artillery:/config \
  -v /mnt/user/artillery/downloads:/downloads \
  -v /mnt/user/artillery/tasks:/tasks \
  artillery:fork
echo "done — artillery is running the fork"
