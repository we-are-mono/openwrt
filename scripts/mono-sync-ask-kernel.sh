#!/bin/sh
# Vendor the kernel-side ASK inputs for the OpenWrt-first build, as a matched set:
#   1. the NXP DPAA/FMan/QBMan SDK driver source  -> target/linux/layerscape/files/
#      plus the SDK-flavour DPAA device tree the board .dts transitively needs:
#      the SoC base (fsl-ls1046a.dtsi, fsl-ls1046-post.dtsi, qoriq-{q,b}man-portals),
#      the FMan port defs (qoriq-fman3-0*.dtsi), and the SDK-only fragments
#      (qoriq-{qman,bman}-portals-sdk.dtsi, qoriq-dpaa-eth.dtsi). mainline ships
#      same-named files but with mainline FMan/DPAA bindings the NXP SDK drivers
#      cannot probe, so the whole DPAA dts base is vendored to shadow mainline's.
#   2. ASK's kernel patch series (010-101 hooks)   -> target/linux/layerscape/patches-6.12/
# OpenWrt's FILES_DIR overlay + normal patch flow then apply them onto OpenWrt's OWN
# kernel -- no git-cloned vendor kernel, no custom Kernel/Prepare.
#
# ASK's patches are developed against a SPECIFIC NXP SDK kernel, so the two travel as
# one coherent set from a single sync (they cannot skew relative to each other).
#
# --check: don't write anything; fetch the pinned upstreams and DIFF them against the
# committed tree, exiting nonzero on any drift. This is the drift guard -- the cut runs
# it so a release can never ship a vendored file/patch that diverged from its pin. Same
# code path as the sync, so "check" can't disagree with what "sync" would produce.
#
# TODO: single-pin this. ASK already records the NXP kernel it targets, in
#   meta-ask/recipes-kernel/linux/linux-ask_6.12.bb  (SRCREV = <ref>). Ideally this
#   script fetches ASK@ASK_VERSION and READS that SRCREV, so ASK_VERSION is the ONE
#   pin and NXP_SDK_REF can never drift from what ASK was built against. For now
#   NXP_SDK_REF is a second explicit pin, kept in sync with that recipe by hand.
#
# Fetches are blobless+sparse+shallow from the public repos (seconds, a few MB, no
# full clone), so any maintainer/CI reproduces the identical tree.
#
# Usage: scripts/mono-sync-ask-kernel.sh [--check]
set -eu

cd "$(dirname "$0")/.."

MODE=sync
[ "${1:-}" = "--check" ] && MODE=check

# --- pins (keep the two in sync; see TODO above) ---
ASK_URL="https://github.com/we-are-mono/ASK.git"
ASK_VERSION="613e047556436cfed1b139cddb6371935128ec0b"
NXP_URL="https://github.com/nxp-qoriq/linux.git"
NXP_SDK_REF="df24f9428e38740256a410b983003a478e72a7c0"   # == ASK linux-ask_6.12.bb SRCREV (tag lf-6.12.49-2.2.0)

# Bucket-B ASK hooks that mono FORWARD-PORTS to OpenWrt's kernel version. ASK's
# originals target the older NXP kernel (they fail to apply to 6.12.103), so the
# sync must NEITHER re-copy NOR clean these -- doing so clobbers the re-anchored
# mono versions. They are mono-maintained and excluded from the verbatim drift-guard.
# (Re-derive on a kernel bump via the quilt push-f/refresh loop; see the handoff.)
MONO_FWD=" 020-ask-bridge-hooks.patch 040-ask-xfrm-ipsec-offload.patch 070-ask-ppp-hooks.patch "

FILES="target/linux/layerscape/files"
PATCHES="target/linux/layerscape/patches-6.12"
ASK_MANIFEST="$PATCHES/.ask-kernel-patches"   # provenance + list of synced ASK patches, for clean re-sync / check

DRIFT=0

# blobless + sparse (cone) + shallow fetch of <paths...> at <ref> into <tmp>.
sparse_fetch() {  # url ref tmp path...
	_url=$1; _ref=$2; _tmp=$3; shift 3
	git -C "$_tmp" init -q
	git -C "$_tmp" remote add origin "$_url"
	git -C "$_tmp" sparse-checkout init --cone
	git -C "$_tmp" sparse-checkout set "$@"
	git -C "$_tmp" fetch -q --depth 1 --filter=blob:none origin "$_ref"
	git -C "$_tmp" checkout -q FETCH_HEAD
}

# sync: install <src> at <dest>. check: diff instead, flag DRIFT. Handles dir or file.
install_item() {  # src dest label
	_src=$1; _dest=$2; _label=$3
	if [ "$MODE" = check ]; then
		if [ -d "$_src" ]; then
			{ [ -d "$_dest" ] && diff -rq "$_src" "$_dest" >/dev/null 2>&1; } || { echo "  DRIFT: $_label"; DRIFT=1; }
		else
			{ [ -f "$_dest" ] && diff -q "$_src" "$_dest" >/dev/null 2>&1; } || { echo "  DRIFT: $_label"; DRIFT=1; }
		fi
	else
		if [ -d "$_src" ]; then mkdir -p "$_dest"; rsync -a --delete "$_src/" "$_dest/"
		else mkdir -p "$(dirname "$_dest")"; cp -a "$_src" "$_dest"; fi
	fi
}

KTMP="$(mktemp -d)"; ATMP="$(mktemp -d)"
trap 'rm -rf "$KTMP" "$ATMP"' EXIT

# ===== 1. NXP SDK driver source -> files/ =====
SDK_SPARSE="drivers/net/ethernet/freescale/sdk_dpaa
drivers/net/ethernet/freescale/sdk_fman
drivers/staging/fsl_qbman
include/uapi/linux/fmd
include/linux
arch/arm64/boot/dts/freescale"
# PRISTINE NXP only. ASK-added files (e.g. include/linux/fsl_oh_port.h, from patch
# 010-ask-fman-dpaa-ehash) arrive with the patch series below, never from here.
# The dts includes are the SDK-flavour DPAA device tree: the 3 SDK-only fragments
# (portals-sdk, dpaa-eth) PLUS the SoC base + FMan port defs (fsl-ls1046a/-post,
# qoriq-{q,b}man-portals, qoriq-fman3-0*). mainline's same-named files carry
# mainline FMan/DPAA bindings the NXP SDK drivers can't probe (fman-port -EIO,
# oh_port NULL-deref), so the whole base is vendored to shadow them. The board
# mono-gateway-dk.dts (mono's own, committed under files/) pulls them in.
SDK_PATHS="drivers/net/ethernet/freescale/sdk_dpaa
drivers/net/ethernet/freescale/sdk_fman
drivers/staging/fsl_qbman
include/uapi/linux/fmd
include/linux/fsl_bman.h
include/linux/fsl_qman.h
include/linux/fsl_usdpaa.h
arch/arm64/boot/dts/freescale/qoriq-qman-portals-sdk.dtsi
arch/arm64/boot/dts/freescale/qoriq-bman-portals-sdk.dtsi
arch/arm64/boot/dts/freescale/qoriq-dpaa-eth.dtsi
arch/arm64/boot/dts/freescale/fsl-ls1046a.dtsi
arch/arm64/boot/dts/freescale/fsl-ls1046-post.dtsi
arch/arm64/boot/dts/freescale/qoriq-qman-portals.dtsi
arch/arm64/boot/dts/freescale/qoriq-bman-portals.dtsi
arch/arm64/boot/dts/freescale/qoriq-fman3-0.dtsi
arch/arm64/boot/dts/freescale/qoriq-fman3-0-1g-0.dtsi
arch/arm64/boot/dts/freescale/qoriq-fman3-0-1g-1.dtsi
arch/arm64/boot/dts/freescale/qoriq-fman3-0-1g-2.dtsi
arch/arm64/boot/dts/freescale/qoriq-fman3-0-1g-3.dtsi
arch/arm64/boot/dts/freescale/qoriq-fman3-0-1g-4.dtsi
arch/arm64/boot/dts/freescale/qoriq-fman3-0-1g-5.dtsi
arch/arm64/boot/dts/freescale/qoriq-fman3-0-10g-0.dtsi
arch/arm64/boot/dts/freescale/qoriq-fman3-0-10g-1.dtsi"

echo "sync-ask-kernel [$MODE]: fetching NXP SDK @ $NXP_SDK_REF"
# shellcheck disable=SC2086
sparse_fetch "$NXP_URL" "$NXP_SDK_REF" "$KTMP" $SDK_SPARSE
for p in $SDK_PATHS; do
	[ -e "$KTMP/$p" ] || { echo "  MISSING in NXP source: $p (ASK-added files come from the patch series)" >&2; exit 1; }
	install_item "$KTMP/$p" "$FILES/$p" "SDK $p"
done
if [ "$MODE" = check ]; then
	[ "$(cat "$FILES/.nxp-sdk-ref" 2>/dev/null || true)" = "$NXP_SDK_REF" ] || { echo "  DRIFT: $FILES/.nxp-sdk-ref != $NXP_SDK_REF"; DRIFT=1; }
else
	printf '%s\n' "$NXP_SDK_REF" > "$FILES/.nxp-sdk-ref"
fi

# ===== 2. ASK kernel patch series -> patches-6.12/ =====
echo "sync-ask-kernel [$MODE]: fetching ASK kernel patches @ $ASK_VERSION"
sparse_fetch "$ASK_URL" "$ASK_VERSION" "$ATMP" patches/kernel

# In sync mode, drop patches ASK has since removed before re-copying.
if [ "$MODE" = sync ] && [ -f "$ASK_MANIFEST" ]; then
	while IFS= read -r old; do
		case "$old" in ''|\#*) continue ;; esac
		case "$MONO_FWD" in *" $old "*) continue ;; esac   # never clean a mono forward-port
		rm -f "$PATCHES/$old"
	done < "$ASK_MANIFEST"
fi

fetched=""
for f in "$ATMP"/patches/kernel/*.patch; do
	b=$(basename "$f")
	case "$b" in 999-*) continue ;; esac   # legacy 5.4 monolith, never applied
	case "$MONO_FWD" in *" $b "*) [ "$MODE" = sync ] && echo "  keeping mono forward-port (not synced): $b"; continue ;; esac
	fetched="$fetched $b"
	install_item "$f" "$PATCHES/$b" "ASK patch $b"
done

if [ "$MODE" = check ]; then
	# Manifest must pin THIS ASK_VERSION and list exactly the fetched set (catch stale
	# patches that would otherwise linger in the tree).
	grep -q "@ $ASK_VERSION\$" "$ASK_MANIFEST" 2>/dev/null || { echo "  DRIFT: $ASK_MANIFEST not synced from $ASK_VERSION"; DRIFT=1; }
	if [ -f "$ASK_MANIFEST" ]; then
		while IFS= read -r m; do
			case "$m" in ''|\#*) continue ;; esac
			case " $fetched " in *" $m "*) ;; *) echo "  DRIFT: committed ASK patch $m not in ASK@$ASK_VERSION"; DRIFT=1 ;; esac
		done < "$ASK_MANIFEST"
	fi
else
	{ echo "# ASK kernel patches synced from $ASK_URL @ $ASK_VERSION"
	  for b in $fetched; do echo "$b"; done; } > "$ASK_MANIFEST"
fi

if [ "$MODE" = check ]; then
	[ "$DRIFT" = 0 ] && echo "sync-ask-kernel: OK -- tree matches ASK@$ASK_VERSION + NXP@$NXP_SDK_REF" \
		|| { echo "sync-ask-kernel: DRIFT detected -- run scripts/mono-sync-ask-kernel.sh to refresh" >&2; exit 1; }
else
	echo "sync-ask-kernel: done -- $(find "$FILES" -type f ! -name '.nxp-sdk-ref' | wc -l) SDK files + $(echo $fetched | wc -w) ASK kernel patches"
fi
