# T9 spike: KVRT (Kaspersky Virus Removal Tool for Linux) - status: PARKED

Tested locally, Docker (vendor/kvrt.run 24.0.6.0, 164MB, self-extracting).

## What works

- Download: `https://devbuilds.s.kaspersky-labs.com/kvrt_linux/latest/kvrt.run` - reachable
  from the deployment network without a proxy (host curl 200).
- Extraction: `./kvrt.run --target <dir>` unpacks `bin/` + `kvrt_runner.sh` (Makeself 2.5.0).
- CLI dependencies: the app is Qt-based; the bundle ships almost everything but misses
  `libXau.so.6` (apt `libxau6`). With it, console flags start fine (aspnet:8.0 base).
- Flags confirmed in binary: `-accepteula -silent -dontencrypt -customonly -custom <dir>
  -d <repdir> -details -proxyconfig <cfg> -ksnstate -lang -lowscanpriority -processlevel
  -exclude -excludelist -allvolumes -trace -tracelevel -tadconfig -adinsilent`
  (`--help` refuses to run without a real X display - read flags from `strings` instead).

## Why it is parked

The updater is unreachable from every available network path:

1. **Direct (deployment network IP)**: `edge.geo.kaspersky.com` (the update edge) kills the
   TLS handshake for this network's IP range (curl exit 000 in ~0.3s, connection reset).
   Verified from both the host and containers. Other Kaspersky hosts ARE reachable direct:
   `devbuilds.s.kaspersky-labs.com` (206) and `products.s.kaspersky-labs.com` (kesl download)
   work fine - only the update edge refuses this region.
2. **Via the upstream proxy tunnel**: Kaspersky 403-forbids the tunnel's datacenter exit IP.
   Container traffic is transparently routed through the tunnel while it is connected.

The updater retries forever in both cases (25+ min, no scan starts, shipped bases 161MB
never used as fallback). Hard-failing the updater (iptables REJECT on the 4 edge IPs)
deadlocks kvrt instead.

## Unlock path (if we revisit)

None available from this network: the update edge refuses both the real IP and every
datacenter exit we have. Re-test only if Kaspersky starts serving this region or a
Kaspersky-served proxy exit becomes available. Shipped kvrt.run kept in `vendor/` (157MB).

Engine count is unaffected: clamav, defender, drweb, kes, escan, mcafee, padvish, yara = 8
real engines already deployed (+ ESET pending keycode = 9).
