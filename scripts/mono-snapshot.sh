#!/bin/sh
# Build HEAD as the branch snapshot (<series>-SNAPSHOT, e.g. 25.12-SNAPSHOT) and
# publish it to the self-hosted ASU server: the channel for experimental builds,
# next to the stable mono-vX.Y.Z-rN releases. A device opts in once with
#   owut upgrade -V 25.12-SNAPSHOT
# and owut then keeps it there on a plain `owut upgrade` (an installed -SNAPSHOT
# version stays on its snapshot); `owut upgrade -V 25.12 --force` goes back to stable.
#
# Unlike mono-update.sh: no git tag, no signed openwrt.mono.si release and no
# latest.json. The legacy mono-update clients poll latest.json and must never be
# offered a snapshot, so ASU (owut) is the only way in.
#
# Needs MONO_PUBLISH_DEST (or ASU_HOST) for publish-asu-feed.sh, as for a release.
#
# Usage: scripts/mono-snapshot.sh [--dry-run]
set -eu

cd "$(dirname "$0")/.."
DRY_RUN=""
[ "${1:-}" = --dry-run ] && DRY_RUN=1

[ -z "$(git status --porcelain)" ] || {
	echo "mono-snapshot: working tree not clean, refusing" >&2
	exit 1
}
# Testers report against the revision; it must map to a commit anyone can fetch.
[ -n "$(git branch -r --contains HEAD)" ] || {
	echo "mono-snapshot: HEAD is not pushed, refusing" >&2
	exit 1
}
if grep -q '^ASK_SOURCE_URL:=file://' package/ask/ask-version.mk; then
	echo "mono-snapshot: ASK is pinned to a local file:// repo, refusing" >&2
	exit 1
fi
scripts/mono-sync-ask-kernel.sh --check

git fetch --quiet origin 'refs/tags/v*:refs/tags/v*'
BASE=$(git tag --merged HEAD 'v[0-9]*' | sort -V | tail -1)
SERIES=${BASE%.*}
SERIES=${SERIES#v}
VNUM="$SERIES-SNAPSHOT"
# Same revision scheme as mono-update.sh (committer epoch + short hash), so owut
# orders snapshots and releases on one scale.
REVCODE="r$(git log -1 --format=%ct)-$(git rev-parse --short HEAD)"
echo "mono-snapshot: $VNUM $REVCODE (base $BASE)"
[ -n "$DRY_RUN" ] && exit 0

# `version` and feeds.conf.default are tracked upstream files edited for the build
# only; restore them on every exit (see mono-update.sh).
on_exit() {
	git checkout -- version 2>/dev/null || rm -f version
	git checkout -- feeds.conf.default 2>/dev/null || true
}
trap on_exit EXIT

scripts/mono-refresh-feed-pins.sh "openwrt-$SERIES"

BINDIR=bin/targets/layerscape/armv8_64b
rm -rf "$BINDIR"
cp configs/mono_gateway-dk.seed .config
echo "$REVCODE" > version
echo "CONFIG_VERSION_CODE=\"$REVCODE\"" >> .config
echo "CONFIG_VERSION_NUMBER=\"$VNUM\"" >> .config
# The ImageBuilder's repositories follow VERSION_REPO, and publish-asu-feed.sh places
# the ASU feed under the version it reads there: releases/<series>-SNAPSHOT/.
echo "CONFIG_VERSION_REPO=\"https://downloads.openwrt.org/releases/$VNUM\"" >> .config

# Same build as mono-update.sh: world + an ImageBuilder from the same tree state.
nix run . -- -c 'set -e
	make defconfig
	khash=$(grep -E "^CONFIG_(PACKAGE_kmod-|KERNEL_|LINUX_|TARGET_)" .config | sha256sum | cut -d" " -f1)
	if [ "$khash" != "$(cat .mono-kbuild.sha 2>/dev/null)" ]; then
		echo "mono-snapshot: kernel config changed since last build -> make target/linux/clean"
		make target/linux/clean
	fi
	make -j"$(nproc)" world
	make target/imagebuilder/clean
	make target/imagebuilder/install
	echo "$khash" > .mono-kbuild.sha'

scripts/publish-asu-feed.sh
echo "mono-snapshot: done - $VNUM $REVCODE published to ASU"
