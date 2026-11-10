# Panoptes - Signature Database Platform Coverage

**Question:** do these engines only detect Linux malware, because they run on Linux?

**Short answer: No.** Engines scan *files*, not operating systems. Their signature databases are
cross-platform and are, in fact, dominated by **Windows** malware signatures, with smaller
Linux/ELF and Android sections plus platform-agnostic hash databases. Running the engine on a
Linux host does not limit what it can detect in a submitted file.

## ClamAV - measured directly (2026-11-10, from our image)

Extracted the shipped databases (`sigtool` + tar of the CVD payloads) and counted signatures by
platform prefix:

| Database | Signatures | Windows-targeted | Unix/Linux/ELF | Android |
|----------|-----------|------------------|----------------|---------|
| main.cvd v63 | 3,287,027 | ~12,806/20,425 of `.hdb` (63%) + 92,105/101,587 of `.ndb` (91%) + 34,457/38,721 of `.ldb` (89%) | ~3,450 lines + platform-agnostic `.mdb` MD5 set (166 MB) | 12 |
| daily.cvd v28176 | 355,854 | 263,252/273,571 of `.ldb` (96%) + 184/323 of `.ndb` (57%) | ~6,143 `.ldb` lines | 0 |
| (both) | - | plus 77 MB of `.hsb` SHA-1/SHA-256 hash DBs - these match malware **of any platform** by hash | | |

Read: roughly **9 out of 10 named signatures are Windows threats**, several thousand are
Linux/Unix/ELF-specific, and millions of hash signatures are platform-independent (script,
document and archive malware included - Pdf/Doc/Html/Js sections). A Windows PE dropped into
Panoptes gets the same treatment it would get on Windows ClamAV.

Reproduce:

```sh
docker run --rm --entrypoint sh panoptes-scanner-clamav:local -c '
  mkdir -p /tmp/x && cd /tmp/x
  tail -c +513 /var/lib/clamav/main.cvd | tar xzf -
  tail -c +513 /var/lib/clamav/daily.cvd | tar xzf -
  for f in *.hdb *.ndb *.ldb; do echo "$f $(grep -c "Win\|W32" $f) win / $(grep -ci "unix\|linux\|elf" $f) unix"; done'
```

## Windows Defender (loadlibrary) - Windows engine by construction

This engine **is** Windows Defender's `mpengine.dll` running on Linux. Its whole signature set
(2021-05 pack, `vendor/defender-engine.tgz`) is Microsoft Windows malware definitions - PE,
macros, scripts. It is the strongest Windows-malware detector in the stack (frozen at 2021
signatures - see `docs/ARCHITECTURE.md`). It will not meaningfully detect Linux ELF malware.

## Vendor-documented coverage (VM engines, pending hands-on re-check)

| Engine | Claimed platform coverage | Notes |
|--------|---------------------------|-------|
| Kaspersky KES | Windows, Linux/Unix, macOS, Android, plus multiplatform hashes/scripts | Kaspersky bases are cross-platform; KES on Linux scans whatever file you hand it |
| Dr.Web | Windows, Linux, macOS, Android + script/document | bases list shows separate platform sections |
| ESET (Server Security for Linux) | Windows, Linux, macOS, Android + archive/script unpacking | the Linux product shares the ESET detection cloud and multi-platform signature sets |
| McAfee (uvscan) DATs | DOS, Windows, Unix/Linux, macOS, Android, JVM, Office macros | DAT readme documents multi-platform coverage |
| eScan | Windows, Linux, Android + document/script | Microworld engine |
| Padvish | Windows, Linux, Android | vendor claims; `padvishctl sigcount` = 6M+ signatures, DB shipped via apbundle |

A hands-on verification pass (listing each vendor's base metadata, e.g. `drweb-ctl base`,
`kesl-control --app-info`) can be attached here from a running deployment. It is expected to
confirm the vendor claims - none of these vendors ship "Linux-only" databases.

## Proven multi-engine detection

End-to-end tests already show all 8 engines detecting EICAR (a platform-agnostic test pattern),
and the full URL-scan flow detects it in every engine too. For platform-specific confidence the
next step (optional) is scanning 3-5 real, well-known Win32 samples from a controlled corpus
(e.g. MalwareBazaar) through the stack - files are never executed, only scanned, so this is
safe inside the containers.

## Practical guidance

- For **Windows malware triage** (most common submitted files): Defender (frozen 2021) +
  ClamAV + KES + ESET give the strongest layered coverage.
- For **Linux/ELF malware**: ClamAV has explicit ELF signatures; KES/ESET/Dr.Web additionally
  market Linux-specific detection. Expect lower absolute coverage than for Windows malware -
  that mirrors the whole industry, not a limitation of running on Linux.
- Stale-database caveats remain per engine as documented in `docs/ARCHITECTURE.md`
  (Defender frozen 2021, KES trial bases frozen, others update at build/start).
