# T9 spike: KVRT (Kaspersky Virus Removal Tool for Linux) - status: PARKED

Tested 2026-11-13, local Docker (vendor/kvrt.run 24.0.6.0, 164MB, self-extracting).

## What works

- Download: `https://devbuilds.s.kaspersky-labs.com/kvrt_linux/latest/kvrt.run` - direct from
  the deployment region, no proxy needed (host curl 200).
- Extraction: `./kvrt.run --target <dir>` unpacks `bin/` + `kvrt_runner.sh` (Makeself 2.5.0).
- CLI dependencies: the app is Qt-based; the bundle ships almost everything but misses
  `libXau.so.6` (apt `libxau6`). With it, console flags start fine (aspnet:8.0 base).
- Flags confirmed in binary: `-accepteula -silent -dontencrypt -customonly -custom <dir>
  -d <repdir> -details -proxyconfig <cfg> -ksnstate -lang -lowscanpriority -processlevel
  -exclude -excludelist -allvolumes -trace -tracelevel -tadconfig -adinsilent`
  (`--help` refuses to run without a real X display - read flags from `strings` instead).

## Why it is parked

The base updater blocks automation. Two failure modes, both dead ends:

1. **Updater reachable but blocked** (default container traffic): Docker Desktop traffic is
   transparently routed through proxy TUN to the exit node ([removed-ip]). Kaspersky's edge
   (edge.geo.kaspersky.com) 403-forbids that datacenter IP. Updater retries forever
   (15+ min, network traffic, no scan starts). Note: the HOST reaches Kaspersky fine from the
   real regional IP ([removed-ip]) - the block is exit-node-specific.
2. **Updater hard-failed** (iptables REJECT on the 4 edge IPs): kvrt deadlocks
   (`futex_do_wait` on its updater thread), no scan, no log, no timeout.

Shipped bases exist (161MB, build date Oct 2025) but kvrt never falls back to them while the
updater is failing.

## Unlock path (if we revisit)

Ask the user to add a DIRECT routing rule for `*.kaspersky-labs.com` / `edge.geo.kaspersky.com`
in proxyN (host traffic already works direct). Then the updater should succeed and the scan
would run - still unproven; needs one clean re-test. Shipped kvrt.run kept in `vendor/`.

Engine count is unaffected: clamav, defender, drweb, kes, escan, mcafee, padvish, yara = 8
real engines already deployed (+ ESET pending keycode = 9).
