# Panoptes Architecture

How the system works end to end: components, request lifecycle, per-engine internals, database
update semantics, and offline behavior. This document answers "what happens when I submit a
sample", "when do signatures update", and "what needs internet".

## Components

```
                      +----------------------------------------------------------+
                      |                       docker host                         |
                      |                                                          |
  Browser ----HTTP--> |  +-----+   queue/poll   +-----+   Hangfire job   +-----------+
  (Nuxt UI)           |  | API | ------------> | API | ---------------> |  Redis    |
                      |  +-----+               +-----+    (queues)       +-----------+
                      |     |  ^                     |      results job      ^
                      |     |  | poll results        | enqueues one job      | Hangfire
                      |     |  |                     | per engine queue      | worker picks
                      |     |  |                     v                       | its own queue
                      |     |  |              +-----------+                   |
                      |     |  |              |  MongoDB  |                   v
                      |     |  |              | (results  |          +------------------+
                      |     |  |              |  + GridFS |          | scanner container|
                      |     |  |              +-----------+          |  (one per AV)    |
                      |     |  |                     ^               |  clamav / drweb /|
                      |     |  |  GET download URL   |               |  kes / eset /... |
                      |     |  +---------------------+---------------+                  |
                      |     |          each scanner downloads the sample        | runs AV CLI
                      |     |          into its own container temp dir          | as process,
                      |     v                                                  | parses output
                      |  +--------+  service registry + health  +----------+    +-------+
                      |  | Consul | <-------------------------- | scanners |    | scan  |
                      |  +--------+    (BackendId metadata)      +----------+    | result|
                      +----------------------------------------------------------+   +---+---+
                                                                                         |
                                                              POST /api/scan-result/report
                                                              (default queue -> API)
```

| Component | Image | Role |
|-----------|-------|------|
| **UI** | `panoptes-ui` (Nuxt 14 / node) | Submit files/URLs, poll results. Talks only to the API. |
| **API** | `panoptes-api` (.NET 8) | HTTP endpoints, sample storage, job fan-out, result aggregation, callbacks. |
| **Redis** | `redis:6` | Hangfire storage. Every job lives here; queues are named per engine. |
| **MongoDB** | `mongo:4` | Two things: `ScanResults` collection (verdicts) + GridFS bucket (uploaded files). |
| **Consul** | `consul:1.8` | Service discovery. Each scanner registers as service `scanner` with `BackendId` metadata; the API asks Consul which engines are currently alive. |
| **Scanner containers** | `panoptes-scanner-<engine>` | One container per antivirus. Runs the AV's command-line scanner as a local process and reports verdicts back. |

Source projects (single solution, .NET 8):

- `MalwareMultiScan.Api` - web host + controllers + jobs
- `MalwareMultiScan.Scanner` - worker host (runs inside every scanner container)
- `MalwareMultiScan.Backends` - one class per AV + process-runner plumbing
- `MalwareMultiScan.Shared` - Hangfire/Consul wiring, message contracts
- `MalwareMultiScan.Tests` - unit tests (backends, controllers)

## Request lifecycle

### File scan

1. User drops a file in the UI. Browser POSTs `multipart/form-data` to the API at
   `POST /api/queue/file` (`QueueController.ScanFile`). Body size is unlimited
   (`Kestrel MaxRequestBodySize = long.MaxValue`).
2. API creates a `ScanResult` document in Mongo (just an id + empty `Results` map) and stores
   the file bytes in **GridFS**.
3. API builds a **download URL** for the stored file (`GET /api/download/{gridfsId}` - same
   host, so every container can fetch it over the compose network).
4. API asks **Consul** for healthy services of type `scanner` and collects the distinct
   `BackendId` values (`ScanResultService.QueueUrlScan`). For each engine it:
   - writes `Results[engineId] = { Status: Queued }` into the Mongo document,
   - enqueues one Hangfire job on the queue named after that engine
     (`new EnqueuedState(engineId)`).
   The job payload (`ScanQueueMessage`) is just `{ resultId, downloadUrl }`.
5. Every scanner container runs a Hangfire **server subscribed to exactly one queue** - its own
   engine name (`AddHangfire(config, BACKEND_ID)`). The matching container picks the job up.
6. Inside the scanner container, `ScanBackgroundJob.Process`:
   - starts a cancellation timer of `MAX_SCANNING_TIME` seconds (900 in compose; per-scan hard
     timeout - a slow engine scan does not block other submissions beyond this),
   - `AbstractScanBackend.ScanAsync(Uri)` downloads the sample from the API download URL into a
     **temp file inside that container** (each engine scans its own private copy),
   - calls the engine-specific scan: spawn the AV command-line process over the temp file,
   - parses threats from stdout with the backend's regex, maps exit codes,
   - on success: `Status=Succeeded` + threat names; on timeout/process death: `Status=Failed`;
     on timeout specifically the job reports `Failed` (from the outside a timed-out engine shows
     as TIMEOUT in the UI).
7. Scanner enqueues `ScanResultJob.Report(resultId, backendId, message)` on the **`default`
   queue**, which the API's Hangfire server consumes:
   - updates `Results[backendId]` in Mongo,
   - if the original request carried a `callbackUrl`, POSTs the verdict there (5 s timeout).
8. UI polls `GET /api/results/{id}` and renders the per-engine table. The Mongo document stays
   forever - every scan is part of the history (data for the future history page).

### URL scan

`POST /api/queue/url` (form field `url`). No upload - the API fans out a job whose download URL
is the submitted URL itself. Each scanner container then fetches that URL directly over the
network and scans the bytes. Verdicts flow back identically.

### Concurrency model

- Hangfire queues isolate engines: a stuck McAfee scan never delays ClamAV.
- `WORKER_COUNT=2` per scanner container = two parallel scans per engine.
- The API can enqueue jobs for engines that are momentarily down - the job waits in Redis until
  the scanner reconnects, or expires by Hangfire defaults if the engine never comes back.

## Per-engine internals

All real engines follow one pattern (`AbstractLocalProcessScanBackend`):
**spawn CLI process -> parse regex captures named `threat` from stdout -> map exit code**.
Config per engine:

| Engine | Process invoked | Verdict source | Exit-code semantics |
|--------|-----------------|----------------|---------------------|
| dummy | none (pipeline validator) | always returns `Malware.Dummy.Result` | n/a |
| clamav | `clamscan <file>` | `<file>: <Threat> FOUND` | 0 clean, 1 infected |
| windows-defender | `/opt/mpclient <file>` (loadlibrary) | `Threat <Name> identified` | 0 clean, 2 infected |
| drweb | `drweb-ctl scan <file>` | `Known virus <Threat>` | 0 ok, 119 engine-not-ready (entrypoint retries) |
| kes | `kesl-scan <file>` (wrapper around `kesl-control --scan-file`) | `DetectName: <Threat>` | 0 clean, non-zero handled |
| eset | `/opt/eset/efs/sbin/cls <file>` | `threat="<Threat>"` | 0 clean, 1 infected |
| mcafee | `uvscan --analyse <file>` | `Found: <Threat>` | 0 clean, 13 infected; **slow cold start** (~5 min DAT load) hence the 900 s timeout and 1 GB RAM limit |
| escan | eScan CLI (`escan` package) | `Infected: <Threat>` | per CLI |
| padvish | `padvishctl scan <file>` | `<file> : Malware Detected (N%) - <Threat>` | **always 0** - detection judged from output only (`ThrowOnNonZeroExitCode=false`) |

Where the signature databases live and how big they are:

| Engine | DB location in container | Size |
|--------|--------------------------|------|
| clamav | `/var/lib/clamav/*.cvd` (main/daily/bytecode) | ~300 MB |
| windows-defender | `/opt/engine/*` (mpengine + vdm files) | ~98 MB |
| drweb | `/var/opt/drweb.com/*` (bases) | ~500 MB |
| kes | kesl internal store, imported from `vendor/kesl-bases.tar` | ~1 GB |
| eset | `/var/lib/eset/efs/...` modules | ~600 MB |
| mcafee | `/usr/local/uvscan/*.dat` | ~130 MB |
| escan | eScan install dir | ~250 MB |
| padvish | `/etc/apav/apav_*.dat` (imported from `vendor/padvish-db.tar`) | ~400 MB, 6M+ signatures |

## Database updates: when and how (build-time vs runtime)

There are exactly **two update moments**, and neither is periodic while containers run:

1. **Image build time** (`docker compose build`): Dockerfiles either download fresh bases from
   the vendor CDN (needs internet, some via proxy) or import vendored files from `vendor/`
   (works offline). The database is **frozen into the image**.
2. **Container start** (entrypoint scripts): best-effort refresh attempt, never fatal:
   - clamav: `freshclam` (direct internet; falls back to vendored CVDs),
   - drweb: update + demo-license heal loop (every 5 min re-checks license, refetches if gone),
   - kes: `kesl-control --update` with 900 s cap (`UPDATE_EXECUTE=no` at build),
   - eset: `eset-update.sh` at start (needs a valid license),
   - mcafee: `mcafee-update.sh` (DAT chain on download.nai.com, usually needs proxy),
   - escan/padvish/defender: no runtime update - frozen at build.

**While a container is running, nothing updates.** Signature freshness therefore = "whenever
the image was last built (plus whatever the start hook managed)". To refresh databases you
rebuild: `docker compose --profile <engine> build <engine>-scanner` and recreate the container.
The operational script automates exactly this.

## Network requirements per engine (runtime)

| Engine | Scan without internet | Needs internet for | Why |
|--------|----------------------|--------------------|-----|
| dummy | yes | nothing | no-op |
| clamav | yes | updates only | DB baked in |
| windows-defender | yes | nothing at runtime | engine tar is frozen (see below) |
| drweb | yes (scanning is local) | license heal (`--GetDemo`) + updates | demo license expiry; with a bought key + offline license file it is fully offline-capable |
| kes | yes | updates only | bases + license are frozen in the image |
| eset | yes during trial/bought license | updates; activation at build | cls refuses updates without license, scans with baked modules |
| mcafee | yes (after first DAT load) | updates only | DAT baked in |
| escan | yes | updates only | DB baked in |
| padvish | yes | updates only (import new apbundle or licensed channel) | DB baked in |

The API itself needs no outbound internet for file scans. **URL scans are the one feature that
always needs network**: the scanner containers fetch the submitted URL directly.

### Fully air-gapped operation

Works, with caveats:

- build images once on a connected machine (or `docker save` / `docker load` them over),
- vendored paths (`vendor/*.tar`, CVDs, eScan deb, Padvish bundle, Defender engine tar, McAfee
  bundle, KES bases) already cover every engine - this is how the VM build survives blocked
  CDNs,
- entrypoint update attempts fail gracefully (best-effort by design) and engines run on baked
  databases,
- URL scanning is unavailable (nothing to fetch from); file uploads work fully,
- Dr.Web is the only engine that will *degrade* over time offline (demo license heals need
  internet); with a purchased license key file baked/mounted it is offline-stable,
- internal traffic (API/Redis/Mongo/Consul/download URLs) never leaves the compose network.

## The Windows Defender engine, specifically

This engine is unlike the others. Microsoft does not ship Defender for Linux, so Panoptes uses
**loadlibrary** (taviso/v-p-b): a POSIX shim that loads the *real* `mpengine.dll` (the Windows
Defender engine) into a Linux process and calls its scan entry point.

- The loader is rebuilt from a **pinned commit** (taviso `c40033b`, `-march=native` stripped).
- The engine files (`mpengine.dll`, `.vdm` signature files, dated **2021-05-16**) come from the
  frozen export `vendor/defender-engine.tgz` - they are the last known-good pair with this
  loader version.
- **Why frozen:** newer Defender engine packs require internal APIs the public loader does not
  implement (verified empirically: 2026 packs crash the loader). Updating the engine = exporting
  a new engine dir from a Windows box + loader work. Until then this engine detects with
  **2021-era signatures** - treat it as a bonus engine, not a source of truth.
- It never touches the network at runtime.

## Known operational facts

- `MAX_SCANNING_TIME=900` (env, all scanners) is the per-scan hard timeout; McAfee's cold DAT
  load takes ~5 min, hence the value. Warm scans are seconds.
- KES trial license inside the frozen bases expires **2026-11-18**; either re-export a fresh
  bases tar from a licensed install or buy the real license (see `docs/LICENSES.md`).
- Dr.Web demo licenses are IP-throttled and expire after ~30 days; the entrypoint heal loop
  refetches automatically while internet is available.
- ESET activation happens at image build (`PANOPTES_ESET_KEY` build arg from `.env`); a wrong
  key fails the build.
- Scan history lives in Mongo `ScanResults` indefinitely (no TTL) - the UI history feature can
  be built directly on it.
