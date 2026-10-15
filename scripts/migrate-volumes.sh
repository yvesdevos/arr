#!/usr/bin/env bash
# Copy the OLD app config volumes into the new per-service datasets.
#
#   sudo ./scripts/migrate-volumes.sh            # dry run, shows what would copy
#   sudo ./scripts/migrate-volumes.sh --run      # actually copy
#
# Reads OLD_<SERVICE>_CONFIG from .env. Empty = skipped.
# STOP THE OLD APPS FIRST (Apps > app > Stop) or SQLite databases will be
# copied mid-write and Radarr/Sonarr will come up corrupted.
#
# The old volumes are left untouched; delete the old apps from the UI once
# the new stack has been verified.
set -euo pipefail

cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo "No .env found." >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }
command -v rsync >/dev/null || { echo "rsync not found." >&2; exit 1; }

# shellcheck disable=SC1091
set -a; source .env; set +a
APPS_DATASET=$(eval echo "$APPS_DATASET")

RUN=0
[[ "${1:-}" == "--run" ]] && RUN=1
RSYNC_FLAGS=(-aHAX --info=progress2 --delete)
[[ $RUN -eq 1 ]] || RSYNC_FLAGS+=(--dry-run)

# Refuse to run while any old container is still up.
running=$(docker ps --format '{{.Names}}' | grep -Ei 'radarr|sonarr|prowlarr|plex|transmission' || true)
if [[ -n "$running" ]]; then
  echo "These containers are still running; stop the old apps first:" >&2
  echo "$running" >&2
  exit 1
fi

migrate() {
  local svc=$1 src=$2
  local dst="/mnt/${APPS_DATASET}/${svc}"
  if [[ -z "$src" ]]; then echo "==> $svc: skipped (no OLD_*_CONFIG)"; return; fi
  if [[ ! -d "$src" ]]; then echo "==> $svc: source $src not found, skipping" >&2; return; fi
  echo "==> $svc: $src -> $dst"
  rsync "${RSYNC_FLAGS[@]}" "$src/" "$dst/"
  if [[ $RUN -eq 1 ]]; then
    chown -R "$PUID:$PGID" "$dst"
  fi
}

migrate radarr       "${OLD_RADARR_CONFIG:-}"
migrate sonarr       "${OLD_SONARR_CONFIG:-}"
migrate prowlarr     "${OLD_PROWLARR_CONFIG:-}"
migrate plex         "${OLD_PLEX_CONFIG:-}"
migrate transmission "${OLD_TRANSMISSION_CONFIG:-}"

echo
if [[ $RUN -eq 1 ]]; then
  echo "Copy complete. Review README.md 'After migrating' before starting the stack."
else
  echo "Dry run only. Re-run with --run to copy."
fi
