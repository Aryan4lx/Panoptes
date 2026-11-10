#!/usr/bin/env bash
# Panoptes operations helper - one entry point for the everyday jobs:
#   ./scripts/panoptes.sh up [engines...]        start core + engines (default: all)
#   ./scripts/panoptes.sh update-dbs [engines..] rebuild engine images (fresh signature
#                                                databases) and recreate their containers
#   ./scripts/panoptes.sh set-key eset <KEY>     store the ESET keycode in .env and rebuild
#   ./scripts/panoptes.sh kes-freeze <tar>       import a fresh KES bases export and rebuild
#   ./scripts/panoptes.sh defender-freeze <tgz>  import a fresh Defender engine export and rebuild
#   ./scripts/panoptes.sh fetch                  run fetch-vendor.sh (host-side downloads)
#   ./scripts/panoptes.sh e2e [engines...]       end-to-end test (default: all engines, 900s)
#   ./scripts/panoptes.sh status                 container status overview
set -euo pipefail
cd "$(dirname "$0")/.."

ALL_ENGINES="dummy clamav windows-defender drweb kes eset escan mcafee padvish"
DB_ENGINES="clamav windows-defender drweb kes eset escan mcafee padvish"
ENV_FILE=".env"
VENDOR="MalwareMultiScan.Backends/Dockerfiles/vendor"

profile_flags() {
  local flags=""
  for e in "$@"; do flags="$flags --profile $e"; done
  echo "$flags"
}

build_and_up() { # build_and_up <engine> [<engine>...]
  local flags services
  flags=$(profile_flags dummy "$@")   # dummy profile is always on for pipeline validation
  services=""
  for e in "$@"; do services="$services ${e}-scanner"; done
  # shellcheck disable=SC2086
  docker compose $flags build $services
  # shellcheck disable=SC2086
  docker compose $flags up -d --force-recreate $services
}

upsert_env() { # upsert_env KEY VALUE
  touch "$ENV_FILE"
  if grep -q "^$1=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"
  else
    echo "$1=$2" >> "$ENV_FILE"
  fi
}

import_vendor() { # import_vendor <src> <vendor-name>
  local src="$1" name="$2"
  [ -f "$src" ] || { echo "not found: $src" >&2; exit 1; }
  mkdir -p "$VENDOR"
  cp -f "$src" "$VENDOR/$name"
  echo "imported $src -> $VENDOR/$name"
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  up)
    engines="${1:-$ALL_ENGINES}"
    # shellcheck disable=SC2086
    docker compose $(profile_flags $engines) up -d
    ;;
  update-dbs)
    engines="${*:-$DB_ENGINES}"
    echo "Rebuilding signature databases for: $engines"
    # restricted networks: export PANOPTES_DEBIAN_MIRROR / PANOPTES_DEBIAN_SECURITY_MIRROR
    # (https://mirror.yandex.ru) and PANOPTES_BUILD_PROXY (http://host.docker.internal:10808)
    # before calling; mcafee needs PANOPTES_BUILD_PROXY unless vendor/mcafee-uvscan.tgz exists.
    build_and_up $engines
    ;;
  set-key)
    product="${1:-}"; key="${2:-}"
    [ "$product" = "eset" ] || { echo "usage: panoptes.sh set-key eset <KEYCODE>" >&2; exit 1; }
    [ -n "$key" ] || { echo "empty keycode" >&2; exit 1; }
    upsert_env PANOPTES_ESET_KEY "$key"
    chmod 600 "$ENV_FILE" 2>/dev/null || true
    echo "key stored in $ENV_FILE - rebuilding eset-scanner"
    build_and_up eset
    ;;
  kes-freeze)
    import_vendor "${1:?usage: panoptes.sh kes-freeze <kesl-bases.tar>}" kesl-bases.tar
    build_and_up kes
    ;;
  defender-freeze)
    import_vendor "${1:?usage: panoptes.sh defender-freeze <defender-engine.tgz>}" defender-engine.tgz
    build_and_up windows-defender
    ;;
  fetch)
    bash scripts/fetch-vendor.sh
    ;;
  e2e)
    engines="${*:-$ALL_ENGINES}"
    export ENGINES="$engines"
    export PANOPTES_TIMEOUT="${PANOPTES_TIMEOUT:-900}"
    bash scripts/e2e-core.sh
    ;;
  status)
    # shellcheck disable=SC2086
    docker compose $(profile_flags $ALL_ENGINES) ps
    ;;
  help|*)
    grep '^#   ' scripts/panoptes.sh | sed 's/^#   //'
    ;;
esac
