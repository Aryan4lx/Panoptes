# Architecture Decision Records

Decisions for the Panoptes repo. Files are named `NNNN-short-title.md`.

Key decisions already made (pre-ADR era, documented in docs/ARCHITECTURE.md and docs/superpowers/specs/):

- .NET 8 LTS migration (from upstream's .NET Core 3.1); local `panoptes-scanner-base` image instead of the upstream Docker Hub base.
- Engine signature pinning: Windows Defender pinned to the 2021 mpengine cab (newer engines crash loadlibrary); KES pinned to kesl 10.1 with frozen monthly bases via `kes-freeze`.
- Hash-based sample dedup at upload (gridfs + md5/sha256 reuse).
- ClamAV DB freshness via an in-container freshclam daemon; Dr.Web relies on its own configd scheduler + a demo-license heal loop in the entrypoint.

Write new decisions as ADRs here when a choice is (a) not obvious from the code, (b) likely to be revisited, or (c) constrains future work.
