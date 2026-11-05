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

# McAfee engine: VirusScan Command Line for Linux64 6.0.4 eval. The old
# b2b-download.mcafee.com URL redirects to the Trellix CDN, which still
# serves the tarball but is unreachable from the region without the local proxy proxy
# (127.0.0.1:10808 on this machine; see PANOPTES_FETCH_PROXY).
TARBALL="$VENDOR/vscl-l64-604-e.tar.gz"
if [ ! -f "$TARBALL" ]; then
  echo "[fetch-vendor] downloading VSCAN Command Line 6.0.4 engine ..."
  curl -sSL --fail --retry 3 -o "$TARBALL" \
    'https://b2b-download.trellix.com/products/evaluation/vcl/l64/vscl-l64-604-e.tar.gz' \
    || curl -sSL --fail --retry 3 -x "${PANOPTES_FETCH_PROXY:-http://127.0.0.1:10808}" -o "$TARBALL" \
       'https://b2b-download.trellix.com/products/evaluation/vcl/l64/vscl-l64-604-e.tar.gz'
else
  echo "[fetch-vendor] $TARBALL already present"
fi

# ESET Server Security for Linux: the "latest" portal link serves a
# self-extracting installer; the build unpacks it with --accept-tou --no-install.
BIN="$VENDOR/efs.x86_64.bin"
if [ ! -f "$BIN" ]; then
  echo "[fetch-vendor] downloading ESET Server Security installer (~268MB) ..."
  curl -sSL --fail --retry 3 -o "$BIN" \
    'https://download.eset.com/com/eset/apps/business/efs/linux/latest/efs.x86_64.bin' \
    || curl -sSL --fail --retry 3 -x "${PANOPTES_FETCH_PROXY:-http://127.0.0.1:10808}" -o "$BIN" \
       'https://download.eset.com/com/eset/apps/business/efs/linux/latest/efs.x86_64.bin'
else
  echo "[fetch-vendor] $BIN already present"
fi
