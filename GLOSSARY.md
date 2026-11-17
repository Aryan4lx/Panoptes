# Panoptes Glossary

Vocabulary for the Panoptes domain. Use these terms consistently in issues, code, tests, and discussion. Terms the project deliberately avoids are marked **avoid**.

## Core concepts

- **Engine** - one antivirus product integrated as a scanner (ClamAV, Windows Defender, Dr.Web, KES, eScan, McAfee, Padvish, ESET, YARA Forge, dummy). Not "scanner service" or "AV". **avoid:** "backend" for the container; "backend" is reserved for code.
- **Scanner (container)** - the per-engine Docker container that runs the vendor's scan CLI against a sample file. Registers itself in Consul with a `BackendId`.
- **Scanner backend** - the C# class (`AbstractScanBackend` subclass) that knows how to invoke one engine's CLI and parse its output. **avoid:** calling the container a "backend".
- **Scan result** - the MongoDB document (`ScanResults` collection) holding one sample's verdicts from all engines, its GridFS file id, and per-engine status/threats/duration.
- **Verdict / threat** - a detection string returned by an engine (e.g. `EICAR-Test-File`). A result is "detected" when any engine returned >= 1 threat.
- **Sample** - the file (or URL content) under scan. Stored in GridFS. **avoid:** "artifact", "payload".
- **Queue** - a Redis list, one per engine id, drained by Hangfire workers inside each scanner container.
- **Dedup** - hash-based sample reuse: re-submitting an identical file returns the previous scan result instead of rescanning (keyed by MD5/SHA256).
- **Rescan** - re-dispatching a single engine against an existing scan result (`POST /api/results/{id}/rescan/{engine}`).

## Operations vocabulary

- **kes-freeze** - the monthly procedure (`scripts/kes-freeze.sh`) that refreshes the Kaspersky trial license inside a disposable container and exports frozen signature bases (`kesl-bases.tar`).
- **update-dbs** - `scripts/panoptes.sh update-dbs <engine>`: refetch vendor signatures and rebuild that engine's image.
- **engines** - `scripts/panoptes.sh engines`: live table of per-engine container state, DB date/age, update method, and license.
- **Frozen (DB)** - signatures baked into the image at build time with no runtime updater (KES, McAfee, Padvish, eScan, Defender by design).
- **EICAR** - the standard antivirus test file; used by `scripts/e2e-core.sh` and unit tests as the positive detection sample.

## Avoid list

- "backend" for containers (use **scanner container**); "backend" means the C# class.
- "Virus Total clone" in user-facing text; the product is **Panoptes**.
