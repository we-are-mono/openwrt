#!/bin/sh
# Rebase the mono branch onto the newest OpenWrt stable tag, rebuild,
# and stage release artifacts. Designed for cron: quiet no-op when
# already current, hard stop (nonzero, clean tree) on conflicts.
#
# No infrastructure knowledge lives here. Publishing only happens when
# the environment provides:
#   MONO_PUBLISH_DEST  rsync destination (e.g. host:/srv/openwrt)
#   MONO_PUBLISH_URL   public base URL written into latest.json
#
# Usage: scripts/mono-update.sh [--dry-run]
set -eu

cd "$(dirname "$0")/.."
BRANCH=mono
DRY_RUN=${1:-}

[ "$(git branch --show-current)" = "$BRANCH" ] || {
	echo "mono-update: not on branch $BRANCH, refusing" >&2
	exit 1
}
[ -z "$(git status --porcelain)" ] || {
	echo "mono-update: working tree not clean, refusing" >&2
	exit 1
}

git fetch --quiet origin 'refs/tags/v*:refs/tags/v*'

BASE=$(git tag --merged "$BRANCH" 'v[0-9]*' | sort -V | tail -1)
SERIES=${BASE%.*}
LATEST=$(git tag -l "${SERIES}.*" | sort -V | tail -1)

if [ "$LATEST" = "$BASE" ]; then
	echo "mono-update: up to date (base $BASE)"
	exit 0
fi

echo "mono-update: $BASE -> $LATEST"
[ "$DRY_RUN" = "--dry-run" ] && exit 0

if ! git rebase --onto "$LATEST" "$BASE" "$BRANCH"; then
	git rebase --abort
	echo "mono-update: REBASE CONFLICT rebasing onto $LATEST - resolve manually:" >&2
	echo "  git rebase --onto $LATEST $BASE $BRANCH" >&2
	exit 1
fi

# Tag before building so the image can bake its own release identity
# (mono-update-check reads it at build time). Dropped again on failure.
RELTAG="mono-$LATEST"
git tag -f "$RELTAG"

cleanup_fail() {
	git tag -d "$RELTAG" >/dev/null 2>&1 || true
	echo "mono-update: BUILD FAILED for $RELTAG" >&2
	exit 1
}

cp configs/mono_gateway-dk.seed .config
make defconfig || cleanup_fail
make -j"$(nproc)" world || cleanup_fail

OUT="releases/$RELTAG"
BINDIR=bin/targets/layerscape/armv8_64b
rm -rf "$OUT"
mkdir -p "$OUT"
cp "$BINDIR"/openwrt-layerscape-armv8_64b-mono_gateway-dk-ext4-emmc.img.gz "$OUT/"
cp "$BINDIR"/openwrt-layerscape-armv8_64b-mono_gateway-dk-ext4-sysupgrade.bin "$OUT/"
cp "$BINDIR"/openwrt-layerscape-armv8_64b-mono_gateway-dk.manifest "$OUT/"
git format-patch --quiet -o "$OUT/patches" "$LATEST..$BRANCH"
(cd "$OUT" && sha256sum *.img.gz *.bin > sha256sums)

SYSUPGRADE_SHA=$(sha256sum "$OUT"/*-sysupgrade.bin | cut -d' ' -f1)
cat > releases/latest.json <<EOF
{
	"tag": "$RELTAG",
	"date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
	"sysupgrade": "${MONO_PUBLISH_URL:-https://openwrt.mono.si}/$RELTAG/$(basename "$OUT"/*-sysupgrade.bin)",
	"sha256": "$SYSUPGRADE_SHA"
}
EOF

if [ -n "${MONO_PUBLISH_DEST:-}" ]; then
	echo "mono-update: publishing to $MONO_PUBLISH_DEST"
	rsync -a "$OUT" releases/latest.json "$MONO_PUBLISH_DEST/"
else
	echo "mono-update: MONO_PUBLISH_DEST unset, artifacts staged in $OUT only"
fi

echo "mono-update: done - $RELTAG"
