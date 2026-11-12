#!/usr/bin/env bash
# Panoptes operations helper - one entry point for the everyday jobs.
# Running it with no arguments prints this help.
#
# Usage: scripts/panoptes.sh <command> [args]
#
# Commands
#   up [engines...]              start core services + engine containers (default: all)
#   update-dbs [engines...]      rebuild engine images with fresh signature databases
#                                and recreate their containers (default: all engines)
#   set-key eset <KEYCODE>       store the ESET keycode in .env and rebuild eset-scanner
#   kes-freeze <kesl-bases.tar>  import a fresh KES bases export and rebuild kes-scanner
#   defender-freeze <engine.tgz> import a fresh Defender engine export and rebuild
#   fetch                        download vendor installers (host-side, fetch-vendor.sh)
#   e2e [engines...]             end-to-end test: EICAR through every engine (900s timeout)
#   status                       container status overview
#   help                         this text
#
# Engines: dummy clamav windows-defender drweb kes eset escan mcafee padvish
#
# Examples
#   scripts/panoptes.sh up clamav drweb kes          # start only these engines
#   scripts/panoptes.sh update-dbs clamav mcafee     # refresh just these two
#   scripts/panoptes.sh set-key eset XXXXX-XXXXX-... # activate ESET
#   scripts/panoptes.sh e2e                          # prove every engine detects EICAR
#
# Restricted networks (set before update-dbs if apt/CDN downloads fail):
#   export PANOPTES_DEBIAN_MIRROR=https://mirror.yandex.ru
#   export PANOPTES_DEBIAN_SECURITY_MIRROR=https://mirror.yandex.ru
#   export PANOPTES_BUILD_PROXY=http://host.docker.internal:10808
#   export PANOPTES_FETCH_PROXY=http://127.0.0.1:10808

set -uo pipefail
cd "$(dirname "$0")/.."

ALL_ENGINES="dummy clamav windows-defender drweb kes eset escan mcafee padvish"
DB_ENGINES="clamav windows-defender drweb kes eset escan mcafee padvish"
ENV_FILE=".env"
VENDOR="MalwareMultiScan.Backends/Dockerfiles/vendor"

#---- output helpers ---------------------------------------------------------

if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_HI=$'\033[36m'; C_WARN=$'\033[33m'; C_0=$'\033[0m'
else
  C_OK=""; C_BAD=""; C_HI=""; C_WARN=""; C_0=""
fi

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$C_OK" "$C_0" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_WARN" "$C_0" "$*"; }
hint() { printf '%s      hint:%s %s\n' "$C_HI" "$C_0" "$*"; }
fail() { printf '%s[FAILED]%s %s\n' "$C_BAD" "$C_0" "$*"; }

#die <message> <hint...> - print failure + remediation, stop.
die() {
  local msg="$1"; shift
  fail "$msg"
  local h
  for h in "$@"; do hint "$h"; done
  exit 1
}

usage() { grep '^# ' "$0" | sed 's/^# \?//'; exit "${1:-0}"; }

#---- plumbing ---------------------------------------------------------------

profile_flags() {
  local flags=""
  for e in "$@"; do flags="$flags --profile $e"; done
  echo "$flags"
}

#build_and_up <engine>... - build + recreate each engine independently.
#one-engine-failing never stops the rest; failures are collected in FAILED[].
FAILED=()

build_and_up() {
  for e in "$@"; do
    local svc="${e}-scanner"
    say "${C_HI}==> ${e}: building image${C_0}"
    if ! docker compose --profile "$e" build "$svc"; then
      FAILED+=("$e (build)")
      fail "$e: image build failed - other engines continue"
      hint "$e: check the build log above; missing vendor file -> scripts/panoptes.sh fetch"
      hint "$e: apt/CDN timeouts on restricted networks -> export PANOPTES_DEBIAN_MIRROR / PANOPTES_BUILD_PROXY (see help)"
      continue
    fi
    say "${C_HI}==> ${e}: (re)creating container${C_0}"
    if ! docker compose --profile "$e" up -d --force-recreate "$svc"; then
      FAILED+=("$e (start)")
      fail "$e: container failed to start - other engines continue"
      hint "$e: docker compose --profile $e logs $svc | tail -50"
      continue
    fi
    ok "$e: up to date"
  done
}

finish() {
  if [ "${#FAILED[@]}" -gt 0 ]; then
    say
    fail "${#FAILED[@]} step(s) failed: ${FAILED[*]}"
    hint "everything else above was completed; fix the listed items and re-run - re-running is safe"
    exit 1
  fi
}

upsert_env() { #upsert_env KEY VALUE
  touch "$ENV_FILE"
  # escape sed metacharacters (keys/values could otherwise contain & | \)
  local k esc
  k=$(printf '%s' "$1" | sed 's/[&|\\]/\\&/g')
  esc=$(printf '%s' "$2" | sed 's/[&|\\]/\\&/g')
  if grep -q "^$k=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^$k=.*|$k=$esc|" "$ENV_FILE"
  else
    echo "$1=$2" >> "$ENV_FILE"
  fi
}

import_vendor() { #import_vendor <src> <vendor-name> <engine>
  local src="$1" name="$2" engine="$3"
  [ -f "$src" ] || die "not found: $src" \
    "pass the path to the export file, e.g. scripts/panoptes.sh kes-freeze ~/kesl-bases.tar" \
    "export recipes live in scripts/fetch-vendor.sh"
  mkdir -p "$VENDOR"
  cp -f "$src" "$VENDOR/$name"
  ok "imported $src -> $VENDOR/$name"
  build_and_up "$engine"
}

require_compose() {
  docker info >/dev/null 2>&1 || die "Docker engine is not running" \
    "start Docker Desktop / 'systemctl start docker' and re-run"
}

#---- commands ---------------------------------------------------------------

cmd="${1:-help}"
shift || true

case "$cmd" in
  up)
    require_compose
    engines="${*:-$ALL_ENGINES}"
    say "Starting core services..."
    if ! docker compose up -d; then
      FAILED+=("core")
      fail "core services failed to start"
      hint "docker compose logs api | tail -50 - engines need the core (redis/mongo/consul)"
    fi
    # shellcheck disable=SC2086
    build_and_up $engines
    finish
    ok "done - UI on :8888, engine status: scripts/panoptes.sh status"
    ;;
  update-dbs)
    require_compose
    engines="${*:-$DB_ENGINES}"
    say "Rebuilding signature databases for: $engines"
    build_and_up $engines
    finish
    ok "done"
    ;;
  set-key)
    product="${1:-}"; key="${2:-}"
    [ "$product" = "eset" ] || die "set-key supports 'eset' (usage: panoptes.sh set-key eset <KEYCODE>)" \
      "other engines license at build via vendor exports (kes-freeze / defender-freeze)"
    [ -n "$key" ] || die "empty keycode" \
      "usage: panoptes.sh set-key eset XXXXX-XXXXX-XXXXX-XXXXX-XXXXX"
    upsert_env PANOPTES_ESET_KEY "$key"
    chmod 600 "$ENV_FILE" 2>/dev/null || true
    ok "key stored in $ENV_FILE - rebuilding eset-scanner"
    require_compose
    build_and_up eset
    finish
    ;;
  kes-freeze)
    [ -n "${1:-}" ] || usage 1
    require_compose
    import_vendor "$1" kesl-bases.tar kes
    finish
    ;;
  defender-freeze)
    [ -n "${1:-}" ] || usage 1
    require_compose
    import_vendor "$1" defender-engine.tgz windows-defender
    finish
    ;;
  fetch)
    if ! bash scripts/fetch-vendor.sh; then
      FAILED+=("fetch")
      fail "fetch-vendor.sh failed"
      hint "vendor CDNs unreachable -> export PANOPTES_FETCH_PROXY=http://127.0.0.1:10808 and re-run"
      hint "some downloads can also be done by hand - see scripts/fetch-vendor.sh header"
      exit 1
    fi
    ok "vendor downloads complete"
    ;;
  e2e)
    require_compose
    engines="${*:-$ALL_ENGINES}"
    export ENGINES="$engines"
    export PANOPTES_TIMEOUT="${PANOPTES_TIMEOUT:-900}"
    if ! bash scripts/e2e-core.sh; then
      FAILED+=("e2e")
      fail "end-to-end test reported failures above"
      hint "TIMEOUT rows usually mean the engine container is down or its DB is stale"
      hint "inspect: docker compose --profile <engine> logs <engine>-scanner | tail -50"
      hint "repair:  scripts/panoptes.sh update-dbs <engine>"
      exit 1
    fi
    ;;
  status)
    # shellcheck disable=SC2086
    docker compose $(profile_flags $ALL_ENGINES) ps
    ;;
  help|-h|--help)
    usage 0
    ;;
  *)
    say "Unknown command: $cmd"
    say
    usage 1
    ;;
esac
