#!/bin/sh
# Vendor the kernel-side ASK inputs for the OpenWrt-first build, as a matched set:
#   1. the NXP DPAA/FMan/QBMan SDK driver source  -> target/linux/layerscape/files/
#      plus the SDK-flavour DPAA device tree the board .dts transitively needs:
#      the SoC base (fsl-ls1046a.dtsi, fsl-ls1046-post.dtsi, qoriq-{q,b}man-portals),
#      the FMan port defs (qoriq-fman3-0*.dtsi), and the SDK-only fragments
#      (qoriq-{qman,bman}-portals-sdk.dtsi, qoriq-dpaa-eth.dtsi). mainline ships
#      same-named files but with mainline FMan/DPAA bindings the NXP SDK drivers
#      cannot probe, so the whole DPAA dts base is vendored to shadow mainline's.
#   2. ASK's kernel patch series (010-110)        -> target/linux/layerscape/patches-6.12/
#   3. ASK's canonical board DTS (mono-gateway-dk.dts) -> files/.../freescale/
# OpenWrt's FILES_DIR overlay + normal patch flow then apply them onto OpenWrt's OWN
# kernel -- no git-cloned vendor kernel, no custom Kernel/Prepare.
#
# ASK is the SINGLE pin. ASK's patches are developed against a specific NXP SDK
# overlay, and ASK records that overlay in a format-neutral pin file
# (pins/nxp-sdk-srcrev.inc, one line: NXP_SDK_SRCREV = "<sha>"). This script
# fetches ASK@ASK_VERSION and READS that ref, so the SDK ref can never drift from
# what ASK was built against -- ASK_VERSION is the only pin to bump.
#
# --check: don't write anything; fetch the pinned upstreams and DIFF them against the
# committed tree, exiting nonzero on any drift. This is the drift guard -- the cut runs
# it so a release can never ship a vendored file/patch/DTS that diverged from its pin.
# Same code path as the sync, so "check" can't disagree with what "sync" would produce.
#
# ASK may be a file:// LOCAL repo (while it is not yet on github, or to test in-repo
# changes); the NXP SDK is always fetched from github. Remote fetches are
# blobless+sparse+shallow (seconds, a few MB); the file:// path exports the committed
# tree with git-archive (no partial-clone / SHA-want limits of the file:// transport).
#
# Usage: scripts/mono-sync-ask-kernel.sh [--check]
set -eu

cd "$(dirname "$0")/.."

MODE=sync
[ "${1:-}" = "--check" ] && MODE=check

# --- pins ---
# ASK is the single authoritative pin. The NXP SDK ref is READ from ASK's recipe
# (NXP_SDK_SRCREV) below, never hand-maintained here.
ASK_URL="https://github.com/we-are-mono/ASK.git"
ASK_VERSION="29ccc4e198c6cf0044a3ea87b7c4bffeb23ff6f1"
NXP_URL="https://github.com/nxp-qoriq/linux.git"
ASK_SDK_PIN="pins/nxp-sdk-srcrev.inc"   # ASK's format-neutral NXP SDK SRCREV pin

# ASK hooks mono must FORWARD-PORT because OpenWrt is not stock mainline: 070 re-anchors
# onto OpenWrt's generic backport 622-v6.18-ppp-remove-rwlock-usage (write_unlock_bh ->
# spin_unlock in ppp_connect_channel). ASK's verbatim 070 targets stock 6.12.103 (rwlock)
# and won't apply here. The sync must NEITHER re-copy NOR clean these mono-owned versions;
# they carry no ASK-verbatim drift guard (git tracks them). Re-derive on a kernel bump via
# the quilt push-f/refresh loop. (020/040 still sync verbatim -- OpenWrt patches neither.)
MONO_FWD=" 070-ask-ppp-hooks.patch "

FILES="target/linux/layerscape/files"
PATCHES="target/linux/layerscape/patches-6.12"
ASK_MANIFEST="$PATCHES/.ask-kernel-patches"   # provenance + list of synced ASK patches, for clean re-sync / check
BOARD_DTS="arch/arm64/boot/dts/freescale/mono-gateway-dk.dts"   # ASK-owned canonical board DTS

DRIFT=0

# Fetch <paths...> at <ref> from <url> into <tmp>. Remote: blobless+sparse+shallow.
# file:// LOCAL repo: git-archive the committed tree at <ref> (avoids the file://
# transport's partial-clone / allowAnySHA1InWant limitations).
sparse_fetch() {  # url ref tmp path...
	_url=$1; _ref=$2; _tmp=$3; shift 3
	case "$_url" in
	file://*)
		_repo=${_url#file://}
		git -C "$_repo" archive "$_ref" "$@" | tar -x -C "$_tmp"
		;;
	*)
		git -C "$_tmp" init -q
		git -C "$_tmp" remote add origin "$_url"
		git -C "$_tmp" sparse-checkout init --cone
		git -C "$_tmp" sparse-checkout set "$@"
		git -C "$_tmp" fetch -q --depth 1 --filter=blob:none origin "$_ref"
		git -C "$_tmp" checkout -q FETCH_HEAD
		;;
	esac
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

# ===== 1. Fetch ASK (single pin): patch series + board DTS + the kernel recipe =====
echo "sync-ask-kernel [$MODE]: fetching ASK @ $ASK_VERSION"
sparse_fetch "$ASK_URL" "$ASK_VERSION" "$ATMP" patches/kernel dts pins

# The single-pin source of truth: read the NXP SDK overlay ref from ASK's pin file.
NXP_SDK_REF=$(sed -n 's/^NXP_SDK_SRCREV *= *"\([0-9a-fA-F]\{40\}\)".*/\1/p' "$ATMP/$ASK_SDK_PIN" | head -1)
[ -n "$NXP_SDK_REF" ] || { echo "  ERROR: could not read NXP_SDK_SRCREV from ASK $ASK_SDK_PIN" >&2; exit 1; }
echo "sync-ask-kernel [$MODE]: ASK pins NXP SDK @ $NXP_SDK_REF"

# ===== 2. NXP SDK driver source -> files/ =====
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
# mono-gateway-dk.dts (ASK-owned, synced separately below) pulls them in.
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

# ===== 3. ASK kernel patch series -> patches-6.12/ =====
# In sync mode, drop patches ASK has since removed before re-copying (from the manifest).
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

# ===== 4. ASK canonical board DTS -> files/ (guarded via install_item's diff) =====
install_item "$ATMP/dts/mono-gateway-dk.dts" "$FILES/$BOARD_DTS" "board DTS $BOARD_DTS"

if [ "$MODE" = check ]; then
	[ "$DRIFT" = 0 ] && echo "sync-ask-kernel: OK -- tree matches ASK@$ASK_VERSION + NXP@$NXP_SDK_REF" \
		|| { echo "sync-ask-kernel: DRIFT detected -- run scripts/mono-sync-ask-kernel.sh to refresh" >&2; exit 1; }
else
	echo "sync-ask-kernel: done -- $(find "$FILES" -type f ! -name '.nxp-sdk-ref' | wc -l) SDK/DTS files + $(echo $fetched | wc -w) ASK kernel patches"
fi
