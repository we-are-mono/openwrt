#!/bin/sh
# usage: run.sh [--no-patches]
#
# Build and run the host test for the cdx source-MAC fix.
#
# Extracts the two tx-info builders from cdx/devman.c of the pinned ASK
# source (dl/ask-$ASK_VERSION.tar.xz), applies the patches under
# package/ask/ask-modules/patches unless --no-patches is given, compiles
# test.c against the extracted text, and runs it.
#
# Exit codes: 0 all scenarios pass, 1 at least one scenario fails,
# 2 setup or compile failure.
set -e

testdir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$testdir/../../../../.." && pwd)
[ -d "$root/package" ] || { echo "run.sh: repo root (directory above package/) not found"; exit 2; }

ASK_VERSION=$(sed -n 's/^ASK_VERSION:=//p' "$root/package/ask/ask-version.mk" | head -n 1)
[ -n "$ASK_VERSION" ] || { echo "run.sh: ASK_VERSION not found in ask-version.mk"; exit 2; }
tarball="$root/dl/ask-$ASK_VERSION.tar.xz"
[ -f "$tarball" ] || { echo "run.sh: missing $tarball"; exit 2; }

tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT

# The archive has the single top-level directory ask-$ASK_VERSION/.
xzcat "$tarball" | tar -C "$tmp" --strip-components=1 -x \
	"ask-$ASK_VERSION/cdx/devman.c" "ask-$ASK_VERSION/cdx/portdefs.h"

if [ "${1:-}" != "--no-patches" ]; then
	# No patches directory (or no *.patch in it) means no fixes: apply
	# nothing, fail nothing.
	for p in "$root"/package/ask/ask-modules/patches/*.patch; do
		[ -e "$p" ] || continue
		( cd "$tmp" && patch -p1 -s < "$p" ) \
			|| { echo "run.sh: applying $p failed"; exit 2; }
	done
fi

# Carve out the verbatim pieces test.c needs. Patterns, not fixed line
# numbers, so the extraction survives line shifts made by the patches.
devman="$tmp/cdx/devman.c"
awk '/^#define NULL_MAC_ADDR/ {print}' "$devman" > "$tmp/null_mac.inc"
# Empty when a patch has removed the registration copy; test.c tolerates
# the empty file.
awk '/memcpy\(eth_info->mac_addr, device->perm_addr, ETH_ALEN\);/ {print}' "$devman" > "$tmp/reg_line.inc"
awk '/^int dpa_get_out_tx_info_by_itf_id/ {p=1} p {print} p && /^}$/ {exit}' "$devman" > "$tmp/fn_ipsec.inc"
awk '/^int dpa_get_tx_info_by_itf\(/ {p=1} p {print} p && /^}$/ {exit}' "$devman" > "$tmp/fn_flow.inc"
for f in null_mac.inc fn_ipsec.inc fn_flow.inc; do
	[ -s "$tmp/$f" ] || { echo "run.sh: extraction of $f from devman.c came out empty"; exit 2; }
done

CC_BIN=${CC:-gcc}
command -v "$CC_BIN" >/dev/null 2>&1 || { echo "run.sh: no compiler '$CC_BIN' found; set CC"; exit 2; }
# -Wno-unused-but-set-variable: the pinned flow function sets a variable
# qosmark and never reads it; the kernel build disables that warning too.
# The function text is kept verbatim instead.
"$CC_BIN" -Wall -Werror -Wno-unused-but-set-variable \
	-I"$tmp" -I"$testdir" -o "$tmp/t" "$testdir/test.c" \
	|| { echo "run.sh: compile failed"; exit 2; }

rc=0
"$tmp/t" || rc=$?
exit "$rc"
