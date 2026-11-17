#!/usr/bin/env bash
# Panoptes operations helper - one entry point for the everyday jobs.
# Running it with no arguments prints this help.
#
# Usage: scripts/panoptes.sh <command> [args]
#
# Every command prints what it is doing as it runs. Exit code is 0 only when
# every step succeeded; failures list the broken items plus a hint each, and
# never abort the remaining engines - re-running after a fix is always safe.
#
# ----------------------------------------------------------------------------
# up [engines...] - bring the whole stack online
#   WHEN:  after a server reboot, a fresh clone/deploy, or when containers
#          are missing or stopped (status shows fewer rows than expected).
#   WHAT:  1. starts the core services (redis, mongodb, consul, api, ui)
#          2. builds each requested engine image if its inputs changed
#             (needs vendor/ installers on disk - run fetch first on a new box)
#          3. (re)creates each engine container with the built image
#   ENGINES default: all of them. One engine failing build/start never stops
#   the others; a summary of failures is printed at the end.
#   RESULT: UI on :8888, verdicts via API - verify with e2e below.
#
# update-dbs [engines...] - refresh signature databases into running containers
#   WHEN:  engines shows a stale DB AGE (mcafee/padvish/escan drift, clamav
#          freshclam broken, yara rules updated), or e2e flags TIMEOUT/CLEAN
#          for one engine, or you just fetched new vendor signatures.
#   WHAT:  rebuilds each engine image (the build re-downloads/installs current
#          signature packs - ClamAV CVDs, McAfee DATs, Padvish bundle, KES
#          frozen bases, eScan/YARA packs) and force-recreates its container.
#          Default: every engine that carries databases. Core is untouched.
#   NOTE:  engines whose DB is deliberately frozen (windows-defender) change
#          nothing; kes picks up whatever vendor/kesl-bases.tar holds - run
#          kes-freeze first for a fresh license + newest bases.
#
# set-key eset <KEYCODE> - activate or replace the ESET license
#   WHEN:  first-time ESET activation, a keycode renewal, or engines shows
#          eset "no keycode".
#   WHAT:  writes PANOPTES_ESET_KEY into .env (chmod 600), rebuilds the
#          eset-scanner image so the key is applied at first start, and
#          recreates the container. Only 'eset' is accepted here; the other
#          engines get their licenses through vendor exports (kes-freeze,
#          drweb's self-managed demo key).
#
# kes-freeze - refresh the Kaspersky trial license + frozen databases
#   WHEN:  MONTHLY, before the trial lapses - engines shows
#          "frozen trial expires YYYY-MM-DD"; count ~25 days back and put a
#          reminder in your calendar. Also after a failed update-dbs kes.
#   WHAT:  runs scripts/kes-freeze.sh: spins up a disposable freezer
#          container, activates a brand-new 31-day trial, transplants the
#          previous frozen bases, updates them online, verifies EICAR
#          detection, then exports everything to vendor/kesl-bases.tar.
#          The old tar is kept until the new one passes verification - safe
#          to re-run. Kaspersky CDN must be reachable (or use a proxy env).
#   THEN:  apply it to the live engine: scripts/panoptes.sh update-dbs kes
#
# defender-freeze <engine.tgz> - import a new Defender engine export
#   WHEN:  rarely - the Defender pack is deliberately pinned to the 2021
#          engine that pairs with the loadlibrary loader (newer packs crash
#          it). Only run this if you exported a known-good engine tgz.
#   WHAT:  copies the given tgz to vendor/defender-engine.tgz, rebuilds the
#          windows-defender image and recreates its container.
#
# fetch - download vendor installers to vendor/
#   WHEN:  on a new machine or fresh clone before the first build (vendor/
#          missing or empty), or after fetch-vendor.sh gained new downloads.
#   WHAT:  runs scripts/fetch-vendor.sh: downloads engine installers and
#          signature packs (KES deb, Trellix/McAfee tarball, Padvish run +
#          signature bundle, YARA Forge rules zip, Dr.Web run, eScan deb)
#          into MalwareMultiScan.Backends/Dockerfiles/vendor/. Skips files
#          that already exist. CDNs that block the server: export
#          PANOPTES_FETCH_PROXY=http://127.0.0.1:10808 and re-run.
#
# e2e [engines...] - prove every engine actually detects malware
#   WHEN:  after any deploy, update-dbs, license change, or whenever you
#          want proof the platform works end to end.
#   WHAT:  generates a real EICAR test file inside a throwaway curl
#          container, submits it through the API exactly like the UI does,
#          waits for every engine's verdict, and prints a table:
#          DETECTED = engine flagged EICAR (pass); CLEAN/FAILED/TIMEOUT
#          (default 900s per engine) = fail, exit code 1. Override the
#          timeout: PANOPTES_TIMEOUT=300 scripts/panoptes.sh e2e.
#   NOTE:  identical files are deduped server-side; e2e salts its sample so
#          every run scans fresh.
#
# status - quick container overview
#   WHEN:  "is anything down?" - the 5-second check.
#   WHAT:  docker compose ps across every profile: container, state, ports.
#          For signature/license health use engines below.
#
# engines - per-engine signature age / update / license health report
#   WHEN:  deciding whether DBs are stale or a license is about to expire;
#          run it weekly, or before/after update-dbs and kes-freeze.
#   WHAT:  one row per engine: STATE (container running), DB-DATE, AGE in
#          days, UPDATES (how that engine refreshes) and LICENSE (days left,
#          or the refresh recipe). Reads live containers - no rebuild.
#
# help - print this text (also: no args, -h, --help; unknown commands)
#
# Engines: dummy clamav windows-defender drweb kes eset escan mcafee padvish yara-forge
#   dummy is a pipeline validator (no real AV); eset needs a keycode via
#   set-key; windows-defender is a pinned legacy engine (see defender-freeze).
#
# Examples
#   scripts/panoptes.sh up clamav drweb kes          # start only these engines
#   scripts/panoptes.sh update-dbs clamav mcafee     # refresh just these two
#   scripts/panoptes.sh set-key eset XXXXX-XXXXX-... # activate ESET
#   scripts/panoptes.sh kes-freeze                   # monthly KES ritual
#   scripts/panoptes.sh update-dbs kes               # ...then apply it
#   scripts/panoptes.sh e2e                          # prove every engine detects EICAR
#
# Restricted networks (set before update-dbs/fetch if apt/CDN downloads fail):
#   export PANOPTES_DEBIAN_MIRROR=https://mirror.yandex.ru
#   export PANOPTES_DEBIAN_SECURITY_MIRROR=https://mirror.yandex.ru
#   export PANOPTES_BUILD_PROXY=http://host.docker.internal:10808
#   export PANOPTES_FETCH_PROXY=http://127.0.0.1:10808
set -uo pipefail
cd "$(dirname "$0")/.."

ALL_ENGINES="dummy clamav windows-defender drweb kes eset escan mcafee padvish yara-forge"
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
    if ! bash scripts/kes-freeze.sh; then
      FAILED+=("kes-freeze")
      fail "KES state refresh failed"
      hint "update step needs KLServers reachable; from blocked networks export PANOPTES_BUILD_PROXY / use a mirror"
      hint "the old tar is untouched until the new one is verified - safe to re-run"
      exit 1
    fi
    ok "kesl-bases.tar refreshed (fresh 31-day trial + current databases)"
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
  engines)
    require_compose
    engines="${*:-$ALL_ENGINES}"
    printf '%-17s %-5s %-11s %-5s %s\n' ENGINE STATE DB-DATE AGE UPDATES/LICENSE
    printf '%-17s %-5s %-11s %-5s %s\n' ------ ----- --------- --- ---------------
    age_of() { # ISO-ish date string -> "Nd"
      local t
      t=$(date -d "$1" +%s 2>/dev/null) || { printf '?'; return; }
      printf '%dd' $(( ($(date +%s) - t) / 86400 ))
    }
    # shellcheck disable=SC2086
    for e in $engines; do
      c="panoptes-$e-scanner-1"
      if [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" != "true" ]; then
        printf '%-17s %-5s %-11s %-5s %s\n' "$e" DOWN - - -
        continue
      fi
      db=""; extra=""
      case "$e" in
        dummy) db="n/a"; extra="simulated engine" ;;
        clamav)
          db=$(docker exec "$c" clamscan --version 2>/dev/null | sed -n 's|.*/[0-9]*/\(.*\)|\1|p')
          db=$(date -d "${db:-x}" '+%Y-%m-%d' 2>/dev/null) || db="?"
          if docker exec "$c" sh -c 'ps aux 2>/dev/null | grep -q "[f]reshclam"'; then
            extra="freshclam daemon active (daily)"
          else
            extra="freshclam NOT running"
          fi
          ;;
        drweb)
          bi=$(docker exec "$c" drweb-ctl baseinfo 2>/dev/null)
          db=$(printf '%s' "$bi" | sed -n 's/.*timestamp: \(.*\)/\1/p' | head -1)
          db=$(printf '%s' "$db" | sed -e 's/-Jan-/-01-/' -e 's/-Feb-/-02-/' -e 's/-Mar-/-03-/' -e 's/-Apr-/-04-/' -e 's/-May-/-05-/' -e 's/-Jun-/-06-/' -e 's/-Jul-/-07-/' -e 's/-Aug-/-08-/' -e 's/-Sep-/-09-/' -e 's/-Oct-/-10-/' -e 's/-Nov-/-11-/' -e 's/-Dec-/-12-/')
          db=${db:0:10}
          upd=$(printf '%s' "$bi" | sed -n 's/.*successful update: \(.*\)/\1/p' | head -1)
          lic=$(docker exec "$c" drweb-ctl license 2>/dev/null | sed -n 's/.*expires \(.*\) (\([0-9]*\) days left).*/\2d left (\1)/p' | head -1)
          extra="auto: ${upd:-?} | demo: ${lic:-NONE}"
          ;;
        kes)
          ai=$(docker exec "$c" kesl-control --app-info 2>/dev/null)
          db=$(printf '%s' "$ai" | sed -n 's/.*Last release date of databases:[[:space:]]*\([0-9-]*\).*/\1/p' | head -1)
          lic=$(printf '%s' "$ai" | sed -n 's/.*License expiration date:[[:space:]]*\([0-9-]*\).*/\1/p' | head -1)
          extra="frozen trial expires ${lic:-?} (renew: scripts/panoptes.sh kes-freeze)"
          ;;
        mcafee)
          db=$(docker exec "$c" /usr/local/uvscan/uvscan --version 2>/dev/null | sed -n 's/.*created \(.*\)/\1/p' | head -1)
          db=$(date -d "${db:-x}" '+%Y-%m-%d' 2>/dev/null) || db="?"
          extra="baked at build (refresh: scripts/panoptes.sh update-dbs mcafee)"
          ;;
        padvish)
          db=$(docker exec "$c" /opt/padvish/bin/padvishctl dbver 2>/dev/null | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
          extra="baked at build (refresh: scripts/panoptes.sh update-dbs padvish)"
          ;;
        escan)
          db=$(docker exec "$c" stat -c '%y' /opt/MicroWorld/etc/escandet.dat 2>/dev/null | cut -c1-10)
          extra="no runtime updater (refresh: scripts/panoptes.sh update-dbs escan)"
          ;;
        windows-defender)
          db=$(docker exec "$c" stat -c '%y' /opt/engine/mpengine.dll 2>/dev/null | cut -c1-10)
          extra="pinned pack (2021 engine pairs with the loader; newer packs crash it)"
          ;;
        yara-forge)
          db=$(docker exec "$c" stat -c '%y' /opt/rules/yara-rules-core.yar 2>/dev/null | cut -c1-10)
          extra="static rule pack (refresh: fetch vendor + update-dbs yara-forge)"
          ;;
        eset)
          db="n/a"
          if grep -q '^PANOPTES_ESET_KEY=' "$ENV_FILE" 2>/dev/null; then
            extra="key configured"
          else
            extra="no keycode (scripts/panoptes.sh set-key eset <KEY>)"
          fi
          ;;
        *) db="?"; extra="unknown engine" ;;
      esac
      a=$(age_of "$db"); [ "$db" = "n/a" ] && a="-"
      printf '%-17s %-5s %-11s %-5s %s\n' "$e" UP "${db:-?}" "$a" "$extra"
    done
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
