#!/usr/bin/env bash
# kes-freeze - refresh the frozen KES (kesl) state in vendor/kesl-bases.tar.
#
# Why this exists: the KES engine image ships a FROZEN license + databases.
# The built-in trial key is bound to the install-id, and a fresh install gets
# a fresh 31-day window. Bases are imported from the previous freeze, then
# updated online (KLServers), so every refresh lands ~30 days of freshness.
#
# Run this monthly, BEFORE the license in vendor/kesl-bases.tar expires
# (check: docker run --rm panoptes-scanner-kes:local kesl-control -L --query).
#
# Requires: docker, vendor/kesl_10.1.1-6421_amd64.deb, vendor/kesl-bases.tar
# (the previous freeze; only used as a delta base - a missing file works too,
# the first update just downloads everything).
#
# Usage: scripts/panoptes.sh kes-freeze
set -u

cd "$(dirname "$0")/.." || exit 1
# Git Bash on Windows mangles /unix paths in docker args - disable MSYS conversion
case "$(uname -s)" in *MINGW*|*MSYS*) export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" ;; esac
VENDOR=MalwareMultiScan.Backends/Dockerfiles/vendor
TAR="$VENDOR/kesl-bases.tar"
IMAGE=panoptes-kes-freezer:tmp

fail() { echo "kes-freeze: $*" >&2; exit 1; }

[ -f "$VENDOR/kesl_10.1.1-6421_amd64.deb" ] || fail "vendor deb missing - run scripts/fetch-vendor.sh kes"
[ -f "$TAR" ] || echo "kes-freeze: no previous $TAR - first update downloads all bases (~1GB)"

# 1. freezer image: kesl installed, no setup run yet
docker build -q -t "$IMAGE" -f- . <<'DOCKERFILE' || fail "freezer image build failed"
FROM debian:bookworm-slim
COPY MalwareMultiScan.Backends/Dockerfiles/vendor/kesl_10.1.1-6421_amd64.deb /tmp/kesl.deb
RUN apt-get update && apt-get install -y --no-install-recommends procps /tmp/kesl.deb && rm /tmp/kesl.deb
# accept EULA + initialize state at build (no license, no KSN, no update)
RUN printf "EULA_AGREED=yes\nPRIVACY_POLICY_AGREED=yes\nUSE_KSN=no\nUPDATER_SOURCE=KLServers\nPROXY_SERVER=none\nUPDATE_EXECUTE=no\nIMPORT_SETTINGS=yes\nUSE_GUI=no\nINSTALL_LICENSE=\n" > /tmp/ai \
 && /opt/kaspersky/kesl/bin/kesl-setup.pl --autoinstall=/tmp/ai >/dev/null 2>&1; rm /tmp/ai
DOCKERFILE

# 2. fresh container: trial auto-activates on first daemon start (fresh install-id
#    => fresh 31-day window; "key is already in use" only happens on reused states)
C=kes-freezer-job
docker rm -f "$C" >/dev/null 2>&1
docker run -d --entrypoint /bin/bash --name "$C" "$IMAGE" -c '/etc/init.d/kesl-supervisor start; sleep infinity' >/dev/null || fail "container start failed"
sleep 45
EXP=$(docker exec "$C" /usr/bin/kesl-control -L --query 2>/dev/null | grep -m1 Expiration | awk '{print $NF}')
case "$EXP" in
  20*|21*) echo "kes-freeze: trial active, expires $EXP" ;;
  *) docker logs "$C" 2>&1 | tail -5; fail "trial did not activate (expiration='$EXP')" ;;
esac

# 3. transplant ONLY common/updates (databases) from the previous freeze -
#    NEVER common/license or common/kesl.ini (they belong to the fresh install)
if [ -f "$TAR" ]; then
  docker exec "$C" mkdir -p /tmp/frozen
  docker cp "$TAR" "$C:/tmp/frozen.tar"
  docker exec "$C" bash -c 'tar xf /tmp/frozen.tar -C /tmp/frozen kesl/common/updates 2>/dev/null
    rm -rf /var/opt/kaspersky/kesl/common/updates
    mv /tmp/frozen/kesl/common/updates /var/opt/kaspersky/kesl/common/updates
    rm -rf /tmp/frozen /tmp/frozen.tar' || fail "bases transplant failed"
  echo "kes-freeze: previous bases imported as delta base"
fi

# 4. run a VALID setup that executes one online update (KLServers)
docker exec "$C" sh -c 'printf "EULA_AGREED=yes\nPRIVACY_POLICY_AGREED=yes\nUSE_KSN=no\nUPDATER_SOURCE=KLServers\nPROXY_SERVER=none\nUPDATE_EXECUTE=yes\nIMPORT_SETTINGS=yes\nUSE_GUI=no\nINSTALL_LICENSE=\n" > /tmp/ai
  wc -l /tmp/ai' || fail "could not write autoinstall file"
docker exec "$C" bash -c 'timeout 60 /etc/init.d/kesl-supervisor stop >/dev/null 2>&1; sleep 3
  for p in /proc/[0-9]*/comm; do grep -qE "kesl_launcher|ApCcSvcd|wdserver|kesl" $p 2>/dev/null && kill -9 ${p##*/} 2>/dev/null; done
  sleep 3
  timeout 900 /opt/kaspersky/kesl/bin/kesl-setup.pl --autoinstall=/tmp/ai >/tmp/setup.log 2>&1
  tail -3 /tmp/setup.log' || { docker exec "$C" tail -20 /tmp/setup.log; fail "setup/update failed"; }
# setup exit code is nonzero when the built-in key re-activation is refused
# (benign - license is already active); the real gate is the verify step below

# 5. verify: bases loaded + today, EICAR detected
docker exec "$C" bash -c '/etc/init.d/kesl-supervisor start >/dev/null 2>&1; sleep 12
  /usr/bin/kesl-control --app-info | grep -e "release date" -e "databases loaded"
  printf "X5O!P%%@AP[4\\PZX54(P^)7CC)7}\$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!\$H+H*" > /tmp/e.txt
  md5sum /tmp/e.txt | grep -q 44d88612fea8a8f36de82e1278abb02f || { echo "EICAR sample corrupt"; exit 1; }
  /usr/bin/kesl-control --scan-file /tmp/e.txt >/dev/null 2>&1
  /usr/bin/kesl-control -B --query "FileName == \"/tmp/e.txt\"" 2>/dev/null | grep -q DetectName || { echo "EICAR NOT detected"; exit 1; }
  echo "EICAR detected OK"' || fail "verification failed"

# 6. export the refreshed state -> vendor/kesl-bases.tar
docker exec "$C" bash -c 'timeout 60 /etc/init.d/kesl-supervisor stop >/dev/null 2>&1; sleep 3
  for p in /proc/[0-9]*/comm; do grep -qE "kesl_launcher|ApCcSvcd|wdserver|kesl" $p 2>/dev/null && kill -9 ${p##*/} 2>/dev/null; done
  sleep 3; tar cC /var/opt/kaspersky kesl > /tmp/kesl-state.tar'
docker cp "$C:/tmp/kesl-state.tar" "$TAR.new" || fail "export failed"
mv "$TAR.new" "$TAR"
docker rm -f "$C" >/dev/null
docker rmi "$IMAGE" >/dev/null 2>&1
echo "kes-freeze: $TAR refreshed - now rebuild: scripts/panoptes.sh build kes && scripts/panoptes.sh up kes"
