# Panoptes - Engine Licensing Guide

Which license to buy for each antivirus engine, at exactly which SKU, what it costs, and
whether trials can be reused. Prices checked 2026-11; **reseller quotes vary by region - treat
listed numbers as reference points, not fixed tags.** Purchase decisions at the bottom.

## Summary table

| Engine | Exact product to buy | Price reference (USD, 1 year) | Trial without paying | the deployment region purchase channel |
|--------|----------------------|-------------------------------|----------------------|-----------------------|
| ClamAV | nothing - free software (GPLv2) | $0 | n/a | n/a |
| Windows Defender (loadlibrary) | no purchasable license exists for this use | n/a | n/a | n/a |
| Dr.Web | Dr.Web Enterprise Security Suite - **Server Security Suite (for Unix)** component, per seat/server | ~$15-40 /seat/yr (business tier, partner quote) | yes - 30-day demo, auto-refetched by our entrypoint (proven working) | Intl: partner/reseller; RU store needs RU payment |
| Kaspersky (KES) | **Kaspersky Endpoint Security for Business - Select** (includes KES for Linux) | ~$50-60 /node/yr for the 10-14 node band (street price; official price = partner quote) | yes - 30-day trial keys from a Kaspersky business portal account | Kaspersky CDN/download is reachable from the deployment region; license purchase via partner. the deployment region status: Kaspersky returned to the regional market in 2024, but government agencies were warned off it - private use is your call |
| ESET | **ESET Server Security for Linux** (business line, sold in seat packs, 4-seat minimum) | ~$125 (4 seats, 1 yr) to ~$2,170 (large packs); ~$217 /10 seats street reference | yes - 30-day business trial keycode (portal account), renewable by new registrations | download.eset.com reachable from the deployment region; buy key via ESET store/intl reseller |
| McAfee / Trellix | Trellix **VirusScan Command Line Scanner (CLS)** - per-system annual license | quote-only (enterprise vendor, no public pricing) | 30-day eval historically available | **No legal the deployment region channel** (US company). Treat as an eval-only bonus engine; do not plan purchases |
| eScan | **eScan Corporate Edition (Hybrid)** - per user/seat, annual | ~$13-24 /user/yr (India list ~Rs 1,700-2,000; intl resellers ~EUR 13) | 30-day trial | Indian vendor, sells through resellers incl. regional channels; escanav.com / mwti.net reachable from the deployment region |
| Padvish | AmnPardaz **Padvish Corporate / سازمانی** (per seat, annual; consumer line = پادویش خانگی) | consumer ref: ~15,000,000 rial / 5 users / yr; corporate = quote | trial via vendor (Rgc registration file) | **Easiest of all**: regional vendor, padvish.com + resellers (ayco.ir), rial payment, update server is in the deployment region |

## Details and gotchas per engine

### ClamAV - free forever
GPLv2. Commercial use allowed, no license file, no activation. `freshclam` database updates are
free. Nothing to buy, ever.

### Windows Defender via loadlibrary - not purchasable
The loadlibrary trick runs Microsoft's `mpengine.dll` on Linux. Microsoft licenses Defender for
Windows/Windows Server endpoints only - there is no SKU that legalizes engine use this way, and
no support contract. The engine pack Panoptes pins (2021-05) is research-grade. If you ever need
a *licensed* Microsoft engine, the correct product is **Microsoft Defender for Endpoint on
Windows Server** (per-server subscription) with the scan happening on a Windows node - not in
this container. Keep this engine as a best-effort bonus.

### Dr.Web
- **Compliant product:** Dr.Web Enterprise Security Suite (business line) - the component for
  file servers / Unix is what covers a Linux scan host. A **Security Space** home license is
  technically the wrong product for a service (home-use EULA) even though it covers Linux.
- One key file covers the seat; our container takes any valid `drweb32.key`.
- Pricing is partner-based; RU list prices exist (estore.drweb.ru, dynamic). Reference street
  prices for business seats land around **$15-40/seat/year** depending on volume and region.
- **Trial behavior (proven in this deployment):** the demo license (`drweb-ctl license
  --GetDemo`) lasts ~30 days and is IP-throttled, but our entrypoint heals it automatically and
  re-fetch worked repeatedly. Dr.Web allows issuing new demos; for production, buy the key.

### Kaspersky (KES)
- **Exact SKU:** Kaspersky Endpoint Security for Business **Select** is the entry tier that
  includes KES for Linux (version 10.x/11.x we run). **Advanced** adds EDR/encryption - not
  needed here.
- Sold in seat bands (10-14, 15-19, 20-24, ...). Street reference for the 10-14 band is about
  **$50-60/node/year**; official price comes only via partners (kaspersky.com has no cart).
- Minimum purchase classically 10 nodes.
- **Trial behavior:** 30-day trial keys from a My Kaspersky business account; renewable with new
  registrations. Our frozen bases import carries a trial that **expires 2026-11-18** - either
  re-freeze from a fresh trial or buy Select.
- the deployment region: Kaspersky resumed official presence in 2024; the download CDN is reachable from the deployment region
  without proxy (verified). Buying through an regional partner is possible; government use is
  warned against - private/company use is the owner's call.

### ESET
- **Exact SKU:** ESET **Server Security for Linux** (business line, replaces the older "ESET
  File Security" name; our image installs `efs.x86_64.bin` which is exactly this product).
- Sold in seat packs starting at 4 seats for 1-3 years. Reference pricing: **~$125 for
  4 seats / 1 year** (US reseller), scaling to ~$2,170 for very large packs; ~$21/seat at 10
  seats. Final price = ESET partner quote.
- Activation: one keycode activates N seats on the server (`/opt/eset/efs/bin/lic --key`).
- **Trial behavior:** ESET business trial = 30-day keycode via a free business portal account;
  renewable by registering new accounts. Our build accepts any valid keycode at build time.
- the deployment region: ESET download servers are reachable from the deployment region (verified); purchase needs an
  international payment card (sanctions limitation - see "Paying from the deployment region" below).

### McAfee / Trellix
- **Exact SKU:** Trellix VirusScan **Command Line Scanner** (the `uvscan` tool we ship),
  licensed per system, annual. No public price list - enterprise sales quote only.
- **Sanctions reality:** Trellix is a US company; there is no sanctioned purchase channel from
  the deployment region. Realistically this engine stays on the 30-day eval or the vendored 2026 DAT files.
- Verdict: **do not budget for it**; keep it as a bonus engine.

### eScan (Microworld)
- **Exact SKU:** eScan **Corporate Edition (Hybrid)** - per-user licensing, annual
  subscriptions; there is also a Total Security Suite tier (more features, not needed).
- Public India list pricing is about **Rs 1,700-2,000 / user / year (~$13-24)**; international
  resellers advertise around **EUR 13/user/year**. Volume discounts from the 25-user band.
- **Trial behavior:** 30-day trial keys from their site; renewable.
- the deployment region: Microworld is Indian (no sanctions problem) and has reseller channels reaching the deployment region;
  download servers are reachable from the deployment region directly (verified).

### Padvish (AmnPardaz) - the "buy this first" engine
- **Exact SKU:** Padvish **سازمانی (Corporate)** per-seat annual for servers; consumer line
  (خانگی) exists but a scanning service should use the corporate tier.
- Public consumer reference: **~15,000,000 rial / 5 users / year**; corporate pricing is a
  quote from the vendor (padvish.com) or resellers (ayco.ir).
- **Trial behavior:** vendor issues a trial registration file; renewable on request.
- the deployment region: it is an regional vendor - rial payment, local support, and the signature update server
  (`update.amnpardaz.com`) is inside the deployment region and fast (verified 200 OK direct). This is the
  cheapest, most maintainable paid engine for this deployment.

## Trial-reuse reality check (one place, honest)

| Engine | Can you keep running on free trials indefinitely? |
|--------|---------------------------------------------------|
| ClamAV | n/a - already free |
| Defender | n/a - nothing to license |
| Dr.Web | **Yes in practice** - demos are re-issuable and our heal loop automates them; expect occasional throttling. Buy when stability matters. |
| KES | Short-term yes (new 30-day keys), but each re-freeze means re-exporting bases; friction grows. Buy Select. |
| ESET | Yes for testing (new portal accounts give 30-day keys); ESET has fraud protection, so automated churn is risky. Buy for production. |
| McAfee | Historically yes via re-registered evals; sanctions risk makes this moot. |
| eScan | Yes, 30-day trials renewable; cheap enough to just buy. |
| Padvish | Trial by vendor request; renewals are informal. Buy corporate seats - it is the cheapest. |

## Paying from the deployment region (practical note)

International card payments (Visa/Mastercard direct) are blocked by sanctions. Working routes:
1. **Padvish + eScan** - payable in rial / through regional resellers (no foreign card needed).
2. **Kaspersky / Dr.Web** - via resellers active in the deployment region (both vendors have regional presence).
3. **ESET** - needs an international card or a third-party purchasing service; the trial keycode
   path avoids payment entirely for the first month.
4. **Trellix** - no legal channel; skip.

## Recommended purchase list (opinionated)

1. **Padvish Corporate** - cheapest, local, fully supported pipeline already in Panoptes.
2. **Kaspersky KES Select** (10-node band minimum) - strongest multi-platform detection.
3. **ESET Server Security for Linux** (4-seat pack) - good Linux detection, easy key.
4. **eScan Corporate** - optional 4th paid engine.
5. Dr.Web - decide after demo stability: buy Server Security Suite seats, or keep demo-healing.
6. McAfee/Defender - keep as best-effort, spend nothing.
