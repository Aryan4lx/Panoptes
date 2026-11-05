# scripts/fetch-vendor.sh - fetch vendor installers the Docker build cannot reach.
# Run on the HOST before building kes: containers on this network get 403 from
# products.s.kaspersky-labs.com (Docker-VM routing anomaly), the host does not.
#
# KES bases: on a network that reaches Kaspersky (e.g. the work ESXi), run
#   docker compose --profile kes up -d
#   docker compose exec kes-scanner tar cC /var/opt/kaspersky kesl > MalwareMultiScan.Backends/Dockerfiles/vendor/kesl-bases.tar
# and copy the tarball next to this script - the image build imports it, so
# the engine ships with frozen databases + its license state.
set -e
cd "$(dirname "$0")/.."
VENDOR=MalwareMultiScan.Backends/Dockerfiles/vendor
mkdir -p "$VENDOR"

DEB="$VENDOR/kesl_10.1.1-6421_amd64.deb"
if [ ! -f "$DEB" ]; then
  echo "[fetch-vendor] downloading kesl 10.1.1-6421 ..."
  curl -L --fail --retry 3 -o "$DEB" \
    'https://products.s.kaspersky-labs.com/endpoints/keslinux10/10.1.1.6421/multilanguage-10.1.1.6421/babce9ef/kesl_10.1.1-6421_amd64.deb'
else
  echo "[fetch-vendor] $DEB already present"
fi

if [ -f "$VENDOR/kesl-bases.tar" ]; then
  echo "[fetch-vendor] kesl-bases.tar present - the build will bake frozen bases in"
else
  echo "[fetch-vendor] NOTE: no kesl-bases.tar - KES will build WITHOUT virus databases."
  echo "               Export them from a Kaspersky-reachable machine (see header)."
fi
