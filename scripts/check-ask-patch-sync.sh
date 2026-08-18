#!/bin/sh
# Guard the downstream ASK patch copies in this tree against silent drift.
#
# fmc and fmlib are fetched from nxp-qoriq upstream and libnfnetlink is the
# stock OpenWrt package, so the ASK extensions reach those sources only through
# downstream patch COPIES under package/*/patches/. Their masters live in the
# ASK repo (patches/{fmc,fmlib,libnfnetlink/<ver>}/). This check:
#
#   Level 1 (always, both build modes): every copy matches the blessed sha
#     pinned in package/ask/ask-patch-sync.sha256. Needs only this tree.
#   Level 2 (only when a local ASK checkout is on disk): each ASK master also
#     matches, catching a master edited without re-syncing the copy here.
#     Skipped with a note under the remote github pin / CI (no ASK checkout).
#
# Fails loudly (nonzero) on any mismatch; never writes anything. The ASK
# checkout dir is $ASK_DIR, else ../../ASK relative to the repo root.
set -eu

cd "$(dirname "$0")/.."
MANIFEST=package/ask/ask-patch-sync.sha256
[ -f "$MANIFEST" ] || { echo "check-ask-patch-sync: $MANIFEST missing" >&2; exit 1; }

# --- Level 1: copies match the pinned manifest (comment / blank-line tolerant) ---
if ! grep -vE '^[[:space:]]*(#|$)' "$MANIFEST" | sha256sum -c - >/dev/null 2>&1; then
	echo "check-ask-patch-sync: FAIL (Level 1) - a tracked ASK patch copy does not" >&2
	echo "  match its pinned sha in $MANIFEST. Either an edit landed here without" >&2
	echo "  updating the manifest, or a re-sync from the ASK masters is incomplete." >&2
	echo "  Inspect: grep -vE '^[[:space:]]*(#|\$)' $MANIFEST | sha256sum -c -" >&2
	exit 1
fi
echo "check-ask-patch-sync: Level 1 OK - copies match $MANIFEST"

# --- Level 2: masters match, only when a local ASK checkout is present ---
ASK=${ASK_DIR:-../../ASK}
if [ ! -d "$ASK/patches" ]; then
	echo "check-ask-patch-sync: Level 2 skipped - no ASK checkout at '$ASK' (set ASK_DIR to enable)"
	exit 0
fi

# libnfnetlink's master is version-scoped; track the package's PKG_VERSION.
LNV=$(sed -n 's/^PKG_VERSION:=//p' package/libs/libnfnetlink/Makefile 2>/dev/null | head -1)
for map in \
	"package/ask/fmc/patches/100-mono-ask-extensions.patch|patches/fmc/01-mono-ask-extensions.patch" \
	"package/ask/fmlib/patches/100-mono-ask-extensions.patch|patches/fmlib/01-mono-ask-extensions.patch" \
	"package/libs/libnfnetlink/patches/900-nxp-ask-nonblocking-heap-buffer.patch|patches/libnfnetlink/${LNV}/01-nxp-ask-nonblocking-heap-buffer.patch"; do
	copy=${map%%|*}
	master="$ASK/${map#*|}"
	if [ ! -f "$master" ]; then
		echo "check-ask-patch-sync: FAIL (Level 2) - ASK master not found: $master" >&2
		echo "  (libnfnetlink master path tracks PKG_VERSION=$LNV; bump lockstep on upgrade)" >&2
		exit 1
	fi
	cs=$(sha256sum "$copy"   | cut -d' ' -f1)
	ms=$(sha256sum "$master" | cut -d' ' -f1)
	if [ "$cs" != "$ms" ]; then
		echo "check-ask-patch-sync: FAIL (Level 2) - copy has drifted from ASK master:" >&2
		echo "    copy   $cs  $copy" >&2
		echo "    master $ms  $master" >&2
		echo "  Re-sync the copy and update $MANIFEST in the SAME commit (lockstep)." >&2
		exit 1
	fi
done
echo "check-ask-patch-sync: Level 2 OK - 3 masters match at $ASK"
