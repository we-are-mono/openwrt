# ASK ↔ mainline kernel integration

How the NXP **ASK** hardware-offload stack is brought into OpenWrt's **stock mainline
kernel** (currently 6.12.103) for the Mono Gateway (NXP LS1046A, target
`layerscape/armv8_64b`, profile `mono_gateway-dk`).

This replaces the older model of git-cloning NXP's whole vendor kernel. The base is now
OpenWrt's own kernel; ASK is layered on top. This document is about the **glue** — the
files that make the stock kernel aware of, and integrated with, the ASK payload.

---

## TL;DR — the model

```
stock mainline kernel  +  NXP SDK drivers (as files/)  +  ASK hooks (as patches-6.12/)
        └── untouched          └── overlay payload            └── the integration
```

There are two kinds of content in `target/linux/layerscape/`:

- **Payload** — the NXP DPAA/FMan/QBMan SDK drivers and the ASK offload code themselves.
- **Glue** — the handful of files that wire that payload into the stock kernel's build
  system, device tree, config, and network subsystems.

Everything is assembled reproducibly by one script from pinned upstream commits.

---

## Build-time assembly order

Order matters — OpenWrt copies `files/` **before** applying patches (see
`include/quilt.mk`), so patches land on the overlaid SDK.

1. **Extract** stock mainline — `dl/linux-6.12.103.tar.xz` (the real kernel.org tarball).
2. **Overlay** `target/linux/layerscape/files/` over the source (SDK drivers + DPAA dts).
3. **Patch** `target/linux/layerscape/patches-6.12/*` in numeric order.
4. **Build** with `target/linux/layerscape/armv8_64b/config-6.12` (SDK-not-mainline DPAA,
   `CPE_FAST_PATH` on/off).

---

## The payload (context, not glue)

Vendored into `target/linux/layerscape/files/` (~227 files), pinned to the NXP SDK commit:

- `files/drivers/net/ethernet/freescale/sdk_dpaa/` — DPAA Ethernet driver.
- `files/drivers/net/ethernet/freescale/sdk_fman/` — Frame Manager driver + microcode glue.
- `files/drivers/staging/fsl_qbman/` — Queue Manager / Buffer Manager (QBMan).
- `files/include/…` — SDK headers (`fsl_bman`/`fsl_qman`/`fsl_usdpaa`, `uapi/linux/fmd/`).
- `files/arch/arm64/boot/dts/freescale/*.dtsi` — 16 DPAA device-tree fragments (see below).

The SDK is near kernel-version-invariant, so vendoring it once at a pin is cheap to carry
forward; NXP maintains it upstream, we copy.

---

## The glue, by layer

| Layer | File(s) | What it glues |
|---|---|---|
| **Assembler** | `scripts/mono-sync-ask-kernel.sh` | Fetches the pristine NXP SDK + ASK patches from upstream and lays them into `files/` + `patches-6.12/`. `--check` diffs the tree vs the pins (drift guard). The whole integration is reproducible from this one script. |
| **Structural** ⭐ | `patches-6.12/705-layerscape-wire-ask-sdk-drivers.patch` | **The keystone.** Adds `source`/`obj-` lines to the stock `freescale/{Kconfig,Makefile}` and `staging/{Kconfig,Makefile}` so kbuild descends into the overlaid SDK subdirs. Without it the vendored SDK is code the build never sees. |
| **Build-config** | `armv8_64b/config-6.12` | Selects `FSL_SDK_DPA/BMAN/QMAN/FMAN/DPAA_ETH=y` and turns stock `FSL_DPAA/FSL_FMAN/FSL_DPAA_ETH=n` — builds the **SDK** datapath, not mainline's. Also carries the ASK offload symbols (see master switch). |
| **Device-tree** | vendored `files/…/dts/freescale/*.dtsi` (16) + `patches-6.12/301-…build-mono-gateway-dk.patch` | The SDK drivers need **SDK-flavoured** DPAA/FMan bindings; the vendored `.dtsi` *shadow* mainline's same-named files (whose mainline bindings the SDK can't probe). `301` adds `dtb-y` for the board DTS. Vendoring the whole DPAA dts base is what fixed the FMan-port `-EIO` / `oh_port` NULL-deref. |
| **Functional** ⭐ | `patches-6.12/010` + Bucket-B (`020` bridge, `030` v4/v6 fwd, `040` xfrm/IPsec, `050` conntrack, `060` qosmark, `070` ppp, `080` wext, `093` netlink, `097` xfrm dst) | `010` declares the master `CONFIG_CPE_FAST_PATH` in `net/Kconfig`; the rest splice `#ifdef CONFIG_CPE_FAST_PATH` hook-points into the stock **bridge / xfrm / netfilter / ppp** code that call the ASK offload engine. This is where ASK actually enters the network stack. |
| **Compat shims** | `patches-6.12/710–713` | Bridge stock↔SDK/ASK API gaps (things NXP's vendor kernel had that mainline lacks). See list below. |
| **SDK fixes (Bucket-A)** | `patches-6.12/010, 090–101` | Patch the *vendored SDK itself*. Ride with `files/`, effectively kernel-version-invariant. |

### The keystone, in full (`705`)

```
--- freescale/Kconfig
+source "drivers/net/ethernet/freescale/sdk_fman/Kconfig"
+source "drivers/net/ethernet/freescale/sdk_dpaa/Kconfig"
--- freescale/Makefile
+obj-$(if $(CONFIG_FSL_SDK_FMAN),y)     += sdk_fman/
+obj-$(if $(CONFIG_FSL_SDK_DPAA_ETH),y) += sdk_dpaa/
--- staging/Kconfig
+source "drivers/staging/fsl_qbman/Kconfig"
--- staging/Makefile
+obj-$(CONFIG_FSL_SDK_DPA)              += fsl_qbman/
```

---

## The master switch: `CONFIG_CPE_FAST_PATH`

Declared by patch `010` in `net/Kconfig` (`depends on ARCH_LAYERSCAPE && NETFILTER`,
`select NF_CONNTRACK`). **Every Bucket-B hook is `#ifdef`'d on it**, and the offload
symbols depend on it:

- `INET_IPSEC_OFFLOAD`, `INET6_IPSEC_OFFLOAD` — `depends on … && CPE_FAST_PATH`
- `NETFILTER_XT_QOSMARK`, `NETFILTER_XT_QOSCONNMARK` — `depends on CPE_FAST_PATH`

So flipping `CONFIG_CPE_FAST_PATH` in `config-6.12` is exactly the SDK-only ↔ full-ASK
toggle:

- `=n` → the SDK DPAA datapath builds and runs, but all ASK offload hooks compile **out**
  (slow-path DPAA Ethernet only). Useful for validating the SDK/boot on mainline in isolation.
- `=y` → the Bucket-B hooks compile **in**; add the offload symbols (`=y`) and the ASK
  userspace packages, and the hardware fast path is live.

---

## Patch inventory (`patches-6.12/`)

**ASK — Bucket A (SDK driver fixes, ride with `files/`):**
`010` (fman/dpaa ehash — also declares CPE_FAST_PATH + straddles net/core), `090`–`101`.

**ASK — Bucket B (hooks into stock kernel subsystems, the per-kernel re-derivation surface):**
`020` bridge · `030` ipv4/ipv6 forwarding · `040` xfrm/IPsec offload (heavyweight) ·
`050` conntrack · `060` netfilter qosmark · `070` ppp · `080` wext ndo_do_ioctl restore ·
`093` netlink L2FLOW cb-mutex · `097` xfrm trans-queue dst refcount.

**Mono glue (this integration):**
`301` board `dtb-y` · `705` SDK kbuild wiring · `710` SDK build-compat (ioremap_cache_ns +
pgprot_cached_ns → plain cacheable, export `phylink_interface_max_speed`, restore
`skb_recycle`) · `711` `sdk_dpaa` `__maybe_unused` · `712` swphy 10G fixed-link ·
`713` export `rtmsg_ifinfo` for the ASK PPP hook.

**Not ASK — stock layerscape platform patches (leave as-is):**
`302`–`305`, `400`, `701`–`703`, `900` (LS1012A dts, PPFE, SPI-NOR, 2.5G SGMII…).

---

## The userspace boundary

The kmods `cdx` / `fci` / `auto_bridge` and the `cmm` daemon are **not** in the kernel —
they build out-of-tree as packages (`package/ask/…`) against the compiled kernel, and talk
to the in-kernel hooks over the **FCI netlink ABI** and `/dev/cdx_ctrl`. They are pinned
separately (`package/ask/ask-version.mk`) but must come from the same ASK commit as the
kernel patches (kmod vermagic + cmm↔cdx ABI move in lockstep).

---

## Reproducing / re-pinning

`scripts/mono-sync-ask-kernel.sh` carries two pins:

- `NXP_SDK_REF` — the NXP `linux` commit the SDK + DPAA dts are vendored from.
- `ASK_VERSION` — the ASK repo commit the `patches/kernel/*` are vendored from (kept in
  sync with `package/ask/ask-version.mk`, which pins the userspace/kmods to the same commit).

Run it to re-vendor after bumping a pin; `--check` fails on drift. Bucket-B forward-ports
that diverge from upstream ASK are excluded from the sync (`MONO_FWD`) so a re-sync doesn't
clobber them.
