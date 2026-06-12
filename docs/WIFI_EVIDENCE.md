---
title: WiFi Evidence Dossier
layout: default
description: "Complete evidence record for the M.2 Key-E RTL8822CE PCIe link-training failure: every experiment, result, and the final verdict."
nav_order: 40
---

# M.2 Key-E WiFi Failure: Complete Evidence Dossier

Status: **CLOSED: board-side hardware fault confirmed.** Last updated 2026-06-11.
Verdict in one paragraph: the kernel, image, and firmware are exonerated. The
stock NVIDIA kernel fails identically, the board's QSPI is bit-identical to
stock, the PCIe PHY bank is healthy (Metis trains and runs on lanes 4 to 7 of
the same UPHY bank), the original card works in another Jetson, and a second
identical card is also silent in this slot. One physical board is at fault.
Everything below is from direct experiments on this board or verified records.

## 1. The symptom, precisely

```
tegra194-pcie 14100000.pcie: Phy link never came up
```

- Controller C1 (`pcie@14100000`, PCI domain 0001), the M.2 Key-E slot, UPHY
  HSIO lane 3 (`p2u_hsio_3`, DT node `phy@3e30000`).
- Fires twice per boot, ~20 s apart (two LTSSM wait windows at our
  `LINK_WAIT_MAX_RETRIES=200`; stock 10 gives ~1 s windows, same outcome).
- 100% reproducible on every boot ever captured for this project. The root
  port `0001:00:00.0 [10de:229e]` is created, finds no device, and is removed.
- The DLFE retry branch in `tegra_pcie_dw_start_link` never fires, meaning
  the LTSSM never reaches state 0x11: this is a pure receiver-detect failure.
  Electrically, nothing answers on the lane.

## 2. Experiment log (chronological, all on this board unless noted)

| # | Experiment | Result |
|---|---|---|
| 1 | `LINK_WAIT_MAX_RETRIES` 10 to 50 to 100 to 200 | no change |
| 2 | `pcie_aspm=off`, vendor driver, re-probe, bus rescan | no change |
| 3 | DT compare of C1 node vs working controllers | identical structure |
| 4 | STOCK NVIDIA kernel boot (full `lspci -nnk` captured): Metis, NVMe, Ethernet present | no 0001 device, same message |
| 5 | `vpcie3v3-supply` added to C1 (DT): regulator consumer registers, rail at 3300 mV | no change |
| 6 | Driver unbind/rebind retrain, minutes after boot, rail stable | no change |
| 7 | Full slot power cycle (both consumers of the shared rail unbound, rail dropped, re-probe) | no change |
| 8 | Camera DT overlay disabled for one boot (GPIO-collision theory) | no change |
| 9 | Physical reseat of the card (owner) | no change |
| 10 | True cold boot, all power removed 15 minutes (owner) | no change |
| 11 | Clean stock-parity RT kernel, explicit `RTW88/8822CE` config, 25/25 config gate | no change |
| 12 | **Original card moved to another Jetson running a stock image (owner)** | **card WORKS** |
| 13 | **Second identical RTL8822CE in this board** | **still silent** (live `lspci` confirmed) |
| 14 | NVIDIA's pristine PREBUILT binary DTB booted via extlinux `FDT` A/B | no change |
| 15 | **Board's QSPI content compared against pristine stock R36.4.3** | **bit-identical**, firmware state exonerated |

## 3. Layer-by-layer exoneration (with the evidence)

- **Drivers**: irrelevant until enumeration; both `rtw88_8822ce` (in-kernel)
  and the vendor `rtl8822ce` load cleanly on demand; the card simply is not
  on the bus for them to bind. Kernel config verified live:
  `CONFIG_WLAN_VENDOR_REALTEK=y`, `CONFIG_RTW88=m`, `CONFIG_RTW88_PCI=m`,
  `CONFIG_RTW88_8822C=m`, `CONFIG_RTW88_8822CE=m`, cfg80211/mac80211 present.
- **Kernel binary/config**: failure identical under three kernels: bone-stock
  NVIDIA (experiment 4), the original custom RT build, and the clean
  stock-parity RT build (experiment 11). An exhaustive semantic diff of our
  config against the pristine defconfig (extracted fresh from the BSP
  tarball) contains zero lane-relevant deltas; the only PCIe-touching ones
  (`PCIEASPM`, DPC/AER, built-in vs module) act post-link-up or only shift
  probe timing, and the timing class is excluded by experiments 6 and 7.
- **Device tree**: failure identical under our compiled DTB and NVIDIA's
  untouched prebuilt binary (experiment 14). The P2U driver source is
  byte-identical to pristine and contains nothing lane-3-specific.
- **Boot firmware inputs**: ODMDATA is the stock devkit value, and NVIDIA's
  R36.4 documentation confirms `hsio-uphy-config-0` maps HSIO lane 3 to
  "PCIe x1 (C1), RP" (the correct value for Key-E WiFi). The live BPMP DTB
  (dumped from the running device) carries exactly that stock UPHY config.
  The MB1 BCT pinmux and uphy-lane files we flash are byte-identical to the
  pristine BSP archive; PEX_L1 pins (PK2/PK3) are configured stock.
- **Lane bank health**: the Metis NPU trains and runs on HSIO lanes 4 to 7,
  the same UPHY bank and PLL as the WiFi's lane 3. The bank works.
- **USB3 lane theft**: excluded; `usb3-2`/`usb3-3` padctl lanes are disabled
  in the live DT, and the enabled USB3 ports own their stock lanes.
- **rfkill / W_DISABLE / GPIO hold**: no rfkill DT node exists, no
  wifi-related GPIO is claimed, PEX_L1 pins are unclaimed by GPIO. The
  card's Bluetooth half (USB pins, separate on-card power domain) enumerates
  and works, proving slot power delivery.
- **The card itself**: exonerated by experiment 12 (works in another Jetson).

## 4. The contradiction, resolved

Experiment 12 proves the original card good. Experiment 13 shows a second
identical card silent on this board. The owner had additionally reported a
test in which an identical card worked "in the board"; the exact conditions
of that test (which physical board, booting which image) were unrecorded and
conflicted with experiment 13. The live `lspci`-captured experiment 13 is
the controlling record. Card good, board silent: the fault is on the board.

## 5. The discriminators, and how the case closed

1. **Firmware state (QSPI): CLOSED.** This was the last untested layer.
   Every flash of this project wrote the module's QSPI from stock R36.4.3
   inputs, and the board's QSPI content was later verified bit-identical to
   pristine stock (experiment 15). With firmware state exonerated and the
   card proven good (experiment 12), a board-level electrical fault on the
   C1 lane is the only layer left standing.
2. **Gen1 clamp** (`max-link-speed = <1>;` on the C1 node). A documented
   Orin case of intermittent "Phy link never came up" (AQC113 NIC on C4) was
   definitively fixed by this clamp. Never tried here; our failure signature
   (no receiver detect at all, not a training-completion failure) predicted
   it would not help, and the closed verdict makes it moot.
3. **LTSSM register read** (`APPL_DEBUG` at `0x141000D0`, bits 8:3) to pin
   the exact stuck state (Detect vs Polling). Requires a trivial kernel
   module because the hardened kernel ships `CONFIG_DEVMEM=n`. Never run;
   it would only refine the diagnosis, not change the verdict.

## 6. External references

- Previously-working Key-E WiFi, same message, NVIDIA diagnosis: RMA
  (hardware): forums.developer.nvidia.com threads 368012 and 336640.
- LTSSM register diagnostic method on this exact controller:
  forums.developer.nvidia.com thread 365010.
- Gen1-clamp resolved case (AQC113 on C4, rel-35/36):
  `max-link-speed = <1>;` fixed enumeration across ~700 reboots.
- rtw88/RTL8822CE D3cold lockup (config space inaccessible until true cold
  power removal): github.com/lwfinger/rtw88 issues 82 and 33. Excluded here
  by experiment 10.
- JetPack 5-to-6 WiFi regressions surveyed: all are driver/firmware level
  with the card still present in `lspci`; none produce this message.

## 7. Ready-to-go recovery (for a healthy slot or replacement board)

Drivers built and staged (in-kernel rtw88 family and the vendor
`rtl8822ce.ko`), NetworkManager profile for the target SSID staged with
autoconnect, and boot-time autoload deliberately disabled until a clean
probe is proven (`sudo modprobe rtl8822ce` for the supervised first load;
re-bake with `WIFI_AUTOLOAD=1` to make autoload permanent). See
[TROUBLESHOOTING](TROUBLESHOOTING.html) F-9 and F-10.

## 8. Operational cost of the dead link

The dead C1 link costs ~40 s of kernel boot time per boot (two link-wait
windows at `LINK_WAIT_MAX_RETRIES=200`). To reclaim the time, either lower
the retry count or set the C1 node `status = "disabled"`; both are one-line
changes in the pipeline.
