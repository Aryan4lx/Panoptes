#!/usr/bin/env bash
# Panoptes E2E core scan check.
#
# Generates the EICAR test string INSIDE a throwaway container on the compose
# network (it never touches the host filesystem), posts it to the API, polls
# the result, and prints a per-engine verdict table.
#
# Usage (from the repo root):
#   ENGINES="dummy clamav" scripts/e2e-core.sh
#
# Env:
#   ENGINES         space-separated engine ids that must report (default: "dummy clamav")
#   PANOPTES_TIMEOUT  poll timeout in seconds (default: 300)

set -euo pipefail

ENGINES="${ENGINES:-dummy clamav}"
TIMEOUT="${PANOPTES_TIMEOUT:-300}"

docker compose --profile e2e run --rm -T \
  -e ENGINES="$ENGINES" \
  -e PANOPTES_TIMEOUT="$TIMEOUT" \
  curl -s <<'SCRIPT'
set -eu

# EICAR test string, generated in-container only.
printf '%s' 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' > /tmp/eicar.txt

code=$(curl -s -o /tmp/resp -w '%{http_code}' \
  -F 'file=@/tmp/eicar.txt;filename=eicar.txt' \
  http://api:5000/api/queue/file)

id=$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' /tmp/resp)

# HTTP 200 = hash-dedup hit: the API returned the cached scan (complete
# results included), so there is nothing to poll - evaluate it directly.
case "$code" in
  201) poll=1; echo "queued scan $id, waiting for engines: $ENGINES (timeout ${PANOPTES_TIMEOUT}s)" ;;
  200) poll=0; echo "duplicate scan $id (cached verdict), evaluating directly"; cp /tmp/resp /tmp/results ;;
  *) echo "POST /api/queue/file failed: HTTP $code"; cat /tmp/resp; exit 1 ;;
esac

final_status() {
  # 1 = succeeded, 2 = failed, 0/absent = still queued
  sed -n "s/.*\"$1\":{\"status\":\([0-9]*\).*/\1/p" /tmp/results 2>/dev/null || true
}

threats_of() {
  sed -n "s/.*\"$1\":{\"status\":[0-9]*,\"duration\":[0-9]*,\"threats\":\(null\|\[[^]]*\]\).*/\1/p" /tmp/results 2>/dev/null || true
}

if [ "$poll" = 1 ]; then
i=0
while [ "$i" -lt "$PANOPTES_TIMEOUT" ]; do
  curl -s "http://api:5000/api/results/$id" > /tmp/results

  done_all=1
  for e in $ENGINES; do
    case "$(final_status "$e")" in
      1|2) ;;
      *) done_all=0 ;;
    esac
  done
  [ "$done_all" = "1" ] && break

  sleep 5
  i=$((i + 5))
done

curl -s "http://api:5000/api/results/$id" > /tmp/results
fi

echo
printf '%-20s %-12s %s\n' ENGINE VERDICT THREATS
printf '%-20s %-12s %s\n' ------ ------- -------

fail=0
for e in $ENGINES; do
  status=$(final_status "$e")
  [ -z "$status" ] && status=0
  threats=$(threats_of "$e")

  if [ "$status" = "1" ] && [ -n "$threats" ] && [ "$threats" != "null" ] && [ "$threats" != "[]" ]; then
    printf '%-20s %-12s %s\n' "$e" DETECTED "$threats"
  else
    case "$status" in
      1) verdict="CLEAN" ;;
      2) verdict="FAILED" ;;
      *) verdict="TIMEOUT" ;;
    esac
    printf '%-20s %-12s %s\n' "$e" "$verdict" "${threats:--}"
    fail=1
  fi
done

exit "$fail"
SCRIPT
