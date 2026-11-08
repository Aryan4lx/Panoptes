# Builds MalwareMultiScan.Backends/Dockerfiles/vendor/padvish-db.tar
# (signature database for the Padvish engine image).
#
# Sources (all the deployment region-only or local-only - never reachable from the build
# container, which is why this script exists):
#   1. Offline bundle   https://update.amnpardaz.com/latest/signature.apbundle
#      -> becomes /etc/apav/apav_003.dat in the image (the daemon parses
#         the bundle format directly as the main signature store).
#   2. Windows Padvish install (user machine) -> the smaller companion
#      databases apav_001.dat, apav_002.dat and apav_004_* / 015 / 020 /
#      030.dat (url/phishing/whitelist/heuristic tables).
#
# Usage:  pwsh scripts/fetch-padvish-db.ps1
#         powershell -File scripts/fetch-padvish-db.ps1

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$vendorDir = Join-Path $root 'MalwareMultiScan.Backends\Dockerfiles\vendor'
New-Item -ItemType Directory -Force -Path $vendorDir | Out-Null

$proxy = $env:PANOPTES_FETCH_PROXY
$bundleUrl = 'https://update.amnpardaz.com/latest/signature.apbundle'
$bundlePath = Join-Path $env:TEMP 'signature.apbundle'
$windowsDir = 'C:\Program Files (x86)\Padvish AV'
$tarPath = Join-Path $vendorDir 'padvish-db.tar'

function Invoke-Fetch($url, $outPath) {
    Write-Host "Fetching $url"
    if ($proxy) {
        curl.exe -fL --retry 5 --retry-delay 5 -C - -x $proxy -o $outPath $url
    }
    else {
        curl.exe -fL --retry 5 --retry-delay 5 -C - -o $outPath $url
    }
    if ($LASTEXITCODE -ne 0) { throw "Download failed: $url" }
}

# 1. offline signature bundle
if (-not (Test-Path $bundlePath)) {
    Invoke-Fetch $bundleUrl $bundlePath
}
else {
    Write-Host "Reusing existing $bundlePath"
}

# 2. companion databases from a local Windows Padvish install
if (-not (Test-Path $windowsDir)) {
    throw "Padvish Windows install not found at '$windowsDir'. Install Padvish, update it, then re-run."
}

Write-Host "Collecting companion databases from $windowsDir"

$staging = Join-Path $env:TEMP 'padvish-db-staging'
if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
New-Item -ItemType Directory -Force -Path $staging | Out-Null

Copy-Item (Join-Path $windowsDir 'apav_001.dat') $staging
Copy-Item (Join-Path $windowsDir 'apav_002.dat') $staging
Get-ChildItem $windowsDir -Filter 'apav_004_*.dat' | ForEach-Object { Copy-Item $_.FullName $staging }
foreach ($name in @('apav_015.dat', 'apav_020.dat', 'apav_030.dat')) {
    $src = Join-Path $windowsDir $name
    if (Test-Path $src) { Copy-Item $src $staging }
}

# 3. bundle becomes the main store, companions sit alongside
Copy-Item $bundlePath (Join-Path $staging 'apav_003.dat')

Write-Host "Packing $tarPath"
if (Test-Path $tarPath) { Remove-Item -Force $tarPath }
tar -cf $tarPath -C $staging .
if ($LASTEXITCODE -ne 0) { throw 'tar failed' }

Remove-Item -Recurse -Force $staging

Write-Host "Done: $tarPath ($((Get-Item $tarPath).Length) bytes)"
