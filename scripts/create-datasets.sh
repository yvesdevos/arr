#!/usr/bin/env bash
# Create the ZFS datasets and folders the arr stack needs, on TrueNAS 25.10.
#
# Run as root on the NAS from the stack directory (where .env lives):
#   sudo ./scripts/create-datasets.sh [--tune-media]
#
# What it does:
#   * creates ${APPS_DATASET} and one child dataset per service on the SSD pool
#       - atime=off, compression=lz4, recordsize=64K (SQLite friendly)
#   * creates ${MEDIA_SUBDIRS} as plain folders inside ${MEDIA_DATASET}
#     (folders, not datasets, so hardlinks between downloads/ and movies/ work)
#   * chowns new datasets/folders to PUID:PGID
#   * with --tune-media: sets atime=off, recordsize=1M on the media dataset
#     (safe, only affects newly written blocks). Never touches existing files.
#
# Datasets are created through the TrueNAS middleware (midclt) so the UI
# sees them. Re-running is safe; existing datasets/folders are skipped.
set -euo pipefail

SERVICES="radarr sonarr prowlarr transmission plex seerr profilarr newtarr dozzle"

cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo "No .env found. Copy .env.example to .env first." >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }
command -v midclt >/dev/null || { echo "midclt not found; is this TrueNAS?" >&2; exit 1; }

# shellcheck disable=SC1091
set -a; source .env; set +a
# .env values may reference other vars (APPS_DATASET=${SSD_POOL}/apps/arr).
APPS_DATASET=$(eval echo "$APPS_DATASET")
MEDIA_DATASET=$(eval echo "$MEDIA_DATASET")

TUNE_MEDIA=0
[[ "${1:-}" == "--tune-media" ]] && TUNE_MEDIA=1

dataset_exists() { midclt call pool.dataset.query "[[\"id\",\"=\",\"$1\"]]" | grep -q '"id"'; }

# create_dataset <name> <json-extra-props>
create_dataset() {
  local name=$1 extra=$2
  if dataset_exists "$name"; then
    echo "  exists   $name"
  else
    echo "  creating $name"
    midclt call pool.dataset.create \
      "{\"name\":\"$name\",\"type\":\"FILESYSTEM\",\"atime\":\"OFF\",\"compression\":\"LZ4\",$extra}" >/dev/null
  fi
}

echo "==> Media dataset ${MEDIA_DATASET}"
dataset_exists "$MEDIA_DATASET" || { echo "Media dataset $MEDIA_DATASET does not exist. Fix MEDIA_DATASET in .env." >&2; exit 1; }
if [[ $TUNE_MEDIA -eq 1 ]]; then
  echo "  tuning atime=off recordsize=1M"
  midclt call pool.dataset.update "$MEDIA_DATASET" '{"atime":"OFF","recordsize":"1M"}' >/dev/null
fi
for sub in $MEDIA_SUBDIRS; do
  d="/mnt/${MEDIA_DATASET}/${sub}"
  if [[ -d "$d" ]]; then
    echo "  exists   $d"
  else
    echo "  mkdir    $d"
    mkdir -p "$d"
    chown "$PUID:$PGID" "$d"
    chmod 775 "$d"
  fi
done

echo "==> App config datasets under ${APPS_DATASET}"
# Parent: walks intermediate datasets (e.g. ssd/apps) too.
IFS=/ read -r -a parts <<<"$APPS_DATASET"
acc=""
for p in "${parts[@]}"; do
  acc="${acc:+$acc/}$p"
  [[ "$acc" == "${parts[0]}" ]] && continue   # pool itself
  create_dataset "$acc" '"recordsize":"64K"'
done
chown "$PUID:$PGID" "/mnt/${APPS_DATASET}"

for svc in $SERVICES; do
  create_dataset "${APPS_DATASET}/${svc}" '"recordsize":"64K"'
  chown -R "$PUID:$PGID" "/mnt/${APPS_DATASET}/${svc}"
  chmod 775 "/mnt/${APPS_DATASET}/${svc}"
done

echo
echo "Done. Stack directory: /mnt/${APPS_DATASET}"
echo "Next: stop the old apps, then run scripts/migrate-volumes.sh"
