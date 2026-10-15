#!/usr/bin/env bash
# Render the compose file with .env applied and check it parses.
# Prints the fully resolved YAML so you can eyeball paths and ports.
#   ./scripts/validate.sh
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo "No .env found." >&2; exit 1; }
docker compose --env-file .env -f docker-compose.yml config
