#!/bin/sh
# Rebase the mono branch onto the newest OpenWrt stable tag, rebuild,
# and stage release artifacts. Designed for cron: quiet no-op when
# already current, hard stop (nonzero, clean tree) on conflicts.
#
# Builds and stages releases/<tag>/, then releases it. When MONO_SIGN_KEY is
# set (the nightly patch-release host) it auto-signs and publishes via:
#   scripts/mono-sign-release.sh <tag>     (needs MONO_SIGN_KEY)
#   scripts/mono-publish-release.sh <tag>  (needs MONO_PUBLISH_DEST; re-verifies, refuses unsigned)
# When MONO_SIGN_KEY is unset it stages only and prints those two steps, to run
# where the key lives (a new minor, or an off-host signing setup). Publishing
# re-verifies the signatures against the fleet's baked keys, so a wrong-key run
# fails and drops the tag instead of shipping something every device rejects.
# MONO_PUBLISH_URL is the public base URL baked into latest.json.
#
# Usage: scripts/mono-update.sh [--dry-run] [--force] [--freeze-feeds]
#   --force:        release the current base even when already up to date
#                   (first release, or re-release after local-only changes)
#   --freeze-feeds: keep the existing upstream feed pins instead of refreshing them
#                   to the stable-branch HEAD - for a hotfix cut that must carry only
#                   its own change, not incidental upstream feed churn.
set -eu

cd "$(dirname "$0")/.."
BRANCH=$(git branch --show-current)
DRY_RUN=""
FORCE=""
FREEZE_FEEDS=""
for a in "$@"; do
	case "$a" in
	--dry-run) DRY_RUN=1 ;;
	--force) FORCE=1 ;;
	--freeze-feeds) FREEZE_FEEDS=1 ;;
	esac
done

case "$BRANCH" in
	mono-v*) ;;
	*)	echo "mono-update: not on a mono-v* release branch (on '$BRANCH'), refusing" >&2
		exit 1 ;;
esac
[ -z "$(git status --porcelain)" ] || {
	echo "mono-update: working tree not clean, refusing" >&2
	exit 1
}

# The downstream ASK patch copies (fmc/fmlib/libnfnetlink) must match their
# pinned shas - and the ASK masters when a checkout is on disk - so a re-synced
# but unpinned (or hand-edited) patch can never ship silently. Fail before we
# tag or build. See scripts/check-ask-patch-sync.sh.
scripts/check-ask-patch-sync.sh

git fetch --quiet origin 'refs/tags/v*:refs/tags/v*'

# Deliberately tracks only the current minor series (v25.12.x patch
# releases). A new minor or major (kernel/vendor bump, new ASK base) is a
# manual, eyes-open migration - it is never followed unattended.
BASE=$(git tag --merged "$BRANCH" 'v[0-9]*' | sort -V | tail -1)
SERIES=${BASE%.*}
LATEST=$(git tag -l "${SERIES}.*" | sort -V | tail -1)

# Every release is mono-vX.Y.Z-rN, numbered from r1. Two triggers: a new
# upstream stable tag (fresh base, counter restarts at r1), or new commits
# on the branch since the last release of the current base (next rN) -
# ASK pin bumps, package fixes.
if [ "$LATEST" != "$BASE" ]; then
	echo "mono-update: $BASE -> $LATEST"
else
	LASTTAG=$(git tag -l "mono-$BASE-r*" | sed 's/.*-r//' | sort -n | tail -1)
	if [ -n "$LASTTAG" ] && [ -z "$FORCE" ] && \
	   [ "$(git rev-parse "mono-$BASE-r$LASTTAG^{commit}")" = "$(git rev-parse "$BRANCH")" ]; then
		echo "mono-update: up to date (mono-$BASE-r$LASTTAG at branch head)"
		exit 0
	fi
fi

# Next release number: the release commit's committer epoch - git log -1 --format=%ct.
# Monotonic by time, stateless (no counter to carry forward), one scheme across every repo.
# The real N is read from the FINAL (post-rebase) HEAD just before tagging; here we preview
# it from the current HEAD for --dry-run. LASTN = highest published N across ALL releases
# (any base) - the fleet-ordering floor the guard below enforces. (Supersedes the old
# highest-tag+1 counter and its +50000 stamp offset; any epoch N is far above the r5001x
# tail, so the crossover is a clean forward jump.)
LASTN=$(git tag -l 'mono-v*-r*' | sed 's/.*-r//' | grep -E '^[0-9]+$' | sort -n | tail -1); LASTN=${LASTN:-0}
echo "mono-update: release mono-$LATEST-r$(git log -1 --format=%ct "$BRANCH")"
[ -n "$DRY_RUN" ] && exit 0

if [ "$LATEST" != "$BASE" ]; then
	if ! git rebase --onto "$LATEST" "$BASE" "$BRANCH"; then
		git rebase --abort
		echo "mono-update: REBASE CONFLICT rebasing onto $LATEST - resolve manually:" >&2
		echo "  git rebase --onto $LATEST $BASE $BRANCH" >&2
		exit 1
	fi
fi

# Final release number from the (possibly rebased) HEAD's committer epoch, guarded so it
# can only move forward: if the clock skewed or a commit was backdated at or below the last
# published N, refuse the cut rather than ship the fleet a version-code "downgrade".
RN=$(git log -1 --format=%ct)
if [ "$RN" -le "$LASTN" ]; then
	echo "mono-update: REFUSING - committer epoch r$RN <= last published r$LASTN (clock/history moved backwards)" >&2
	exit 1
fi
RELTAG="mono-$LATEST-r$RN"
echo "mono-update: cutting $RELTAG"

# Tag before building so the release is a fixed point in git history; the feed
# dir + latest.json are named from it. Dropped again on failure.
git tag -f "$RELTAG"

# From here on ANY nonzero exit - build, staging, sign, or publish - removes
# the tag, so the next run recomputes this same revision and retries instead
# of seeing a tag at branch head and skipping. Without this a failed publish
# would leave the tag and wedge the release. set -e turns a failed command
# into an exit, which fires the trap.
on_exit() {
	rc=$?
	# `version` is a TRACKED upstream file (getver reads it FIRST; normally holds
	# r33051-...). We overwrite it with this release's REVCODE for the build, so
	# restore the committed content on every exit - otherwise the tree stays dirty
	# (`D version`) and the next run's clean-tree check refuses. Restore, don't delete.
	git checkout -- version 2>/dev/null || rm -f version
	# feeds.conf.default is a TRACKED upstream file that the feed-pin refresh below
	# rewrites transiently for the build; restore upstream's pins so the tree is clean
	# for the next run (this release's real pins are recorded in $OUT/feeds.lock).
	git checkout -- feeds.conf.default 2>/dev/null || true
	[ "$rc" -eq 0 ] && return 0
	git tag -d "$RELTAG" >/dev/null 2>&1 || true
	echo "mono-update: FAILED ($RELTAG, rc=$rc) - tag dropped, will retry next run" >&2
}
trap on_exit EXIT

# Refresh the upstream feed pins to the current stable-branch HEAD so the release feed
# tracks what devices apk-pull. Without this a device that ran `apk upgrade` drifts
# ahead of the frozen release-tag pins and owut refuses the upgrade on dozens of
# "downgrades". feeds.conf.default is edited transiently (the EXIT trap restores it);
# the exact resolved pins are recorded in $OUT/feeds.lock below. --freeze-feeds keeps
# the existing pins for a hotfix that must carry only its own change.
[ -n "$FREEZE_FEEDS" ] && export MONO_FREEZE_FEEDS=1
scripts/mono-refresh-feed-pins.sh "openwrt-$SERIES"

BINDIR=bin/targets/layerscape/armv8_64b

# Release builds must not inherit anything from previous runs: bin/targets is
# never cleaned by make, and its profiles.json merge-preserves entries across
# builds (version_code tracks the upstream base, not mono commits). Without
# this purge, an artifact retired from IMAGES - e.g. sysupgrade-legacy.bin
# after its sunset - would be resurrected into the NEW signed release from
# the stale binary plus the preserved metadata entry, and the fleet cohort
# that reads it would flash the PREVIOUS release under the new tag.
rm -rf "$BINDIR"

cp configs/mono_gateway-dk.seed .config

# Stamp this release's revision into BOTH version fields so owut (the ASU client)
# detects every update - including ASK-only or kernel-only ones, whose package
# versions are sha-based and non-monotonic (owut would otherwise see no change):
#   %R  REVISION    -> device /etc/openwrt_release DISTRIB_REVISION (owut's "from")  <- version file
#   %C  VERSION_CODE-> server/IB version_code                       (owut's "to")    <- CONFIG_VERSION_CODE
# Value r<RN>-<shorthash>, where RN is the 50000-based release number (identical to the git
# tag - one number everywhere). The 50000 base clears the pre-stamp getver constant
# (r33051-f5dae5ece4) that EVERY old build reports, so owut sees a stamped release as NEWER
# than any pre-stamp device (a bare counter like r10 would parse BELOW 33051 and owut would
# call it a DOWNGRADE). Monotonic; keeps getver's rNNNNN-hash shape so parse_rev_code
# (/^r(\d+)-([[:xdigit:]]+)$/) accepts it. CONFIG_VERSION_CODE survives `make defconfig` via
# the seed's IMAGEOPT->VERSIONOPT gate. `version` is a TRACKED upstream file; the EXIT trap
# restores its committed content (git checkout) so the tree stays clean for the next run.
REVCODE="r$RN-$(git rev-parse --short HEAD)"
echo "$REVCODE" > version
echo "CONFIG_VERSION_CODE=\"$REVCODE\"" >> .config
echo "mono-update: stamping revision $REVCODE"

# Build inside the pinned Nix FHS env (flake.nix) so the toolchain is identical
# on every machine. Use `nix run` -- NOT `nix develop -c` / `nix-shell --run`,
# which hang on the env's shellHook exec. git, publish and signing stay on the
# host (their tools are not in the flake's package set).
#
# Build the ImageBuilder in the SAME tree state (target/imagebuilder/clean first -
# install reuses a stale IB build_dir .config, so the REVCODE/branding change would
# not otherwise reach it): ASU builds the fleet's upgrade images from this IB, so it
# must carry the same REVCODE (its version_code is what owut reads as the "to" target).
nix run . -- -c 'set -e
	make defconfig
	make -j"$(nproc)" world
	make target/imagebuilder/clean
	make target/imagebuilder/install'

OUT="releases/$RELTAG"
URLBASE="${MONO_PUBLISH_URL:-https://openwrt.mono.si}"
rm -rf "$OUT"
mkdir -p "$OUT"
# Prefix-agnostic (openwrt-/mono-/...): the image prefix comes from VERSION_DIST,
# which the seed sets to "Mono" (artifacts are mono-*). rm -rf "$BINDIR" above means
# only THIS build's files are present, so the leading * cannot catch strays.
# Stage under simplified names: strip the version prefix (mono-<epoch>-<sha>-)
# so published files are just layerscape-armv8_64b-mono_gateway-dk-*. The strip
# is mirrored into the latest.json builder below (pick()), which resolves
# profiles.json's build-names against these staged names.
for f in "$BINDIR"/*-layerscape-armv8_64b-mono_*-ext4-emmc.img.gz \
         "$BINDIR"/*-layerscape-armv8_64b-mono_*-ext4-sysupgrade.bin \
         "$BINDIR"/*-layerscape-armv8_64b-mono_*.manifest; do
	cp "$f" "$OUT/$(basename "$f" | sed -E 's/^.*(layerscape-armv8_64b-)/\1/')"
done

# Per-release kmod feed: kernel modules are vermagic-locked to this build, so
# devices cannot get them from the official OpenWrt repo. The device's
# 92-mono-feeds points apk at <url>/<tag>/kmods/. luci + packages come from the
# official feed; we ship only what it cannot - the signed target/kmod packages.
mkdir -p "$OUT/kmods"
cp "$BINDIR"/packages/packages.adb "$BINDIR"/packages/*.apk "$OUT/kmods/"
git format-patch --quiet -o "$OUT/patches" "$LATEST..$BRANCH"
# Record the exact feed pins this build used. feeds.conf.default is restored to
# upstream's tag pins by the EXIT trap, so the release's real feed state is captured
# here (reproduce with: apply these pins, `./scripts/feeds update`, rebuild).
grep -E '^src-' feeds.conf.default > "$OUT/feeds.lock"
(cd "$OUT" && sha256sum *.img.gz *.bin > sha256sums)

# NOTE: this script no longer signs. Signing happens on the key host via
# scripts/mono-sign-release.sh, and publishing (scripts/mono-publish-release.sh)
# refuses to run without the signatures. Keeping the key off the build/publish
# host means a compromise of this host is not also a signing compromise.

# A real flashing tool, shipped with the release (not a two-step dd in prose).
cat > "$OUT/flash-mono-gateway.sh" <<'FLASH'
#!/bin/sh
# Flash a Mono Gateway eMMC image from recovery Linux, leaving the boot
# firmware (4 KiB-32 MiB) intact. Usage: flash-mono-gateway.sh <emmc.img.gz> [dev]
set -e
IMG="$1"; DEV="${2:-/dev/mmcblk0}"
[ -f "$IMG" ] || { echo "usage: $0 <...-emmc.img.gz> [/dev/mmcblkN]"; exit 1; }
case "$IMG" in *.gz) feed(){ gunzip -c "$IMG"; };; *) feed(){ cat "$IMG"; };; esac
echo "GPT (first 4 KiB)...";     feed | dd of="$DEV" bs=512 count=8 conv=fsync
echo "System (from 32 MiB)..."; feed | dd of="$DEV" bs=1M skip=32 seek=32 conv=fsync
sync; echo "Done - set DIP to eMMC and reboot."
FLASH
chmod +x "$OUT/flash-mono-gateway.sh"

# latest.json: the manifest devices poll to self-update. Board keys come from
# the image metadata (profiles.json), not filename string-surgery, so a device
# that finds no image for its board fails visibly rather than from silent
# naming drift. Format + rationale live in scripts/mono-latest-json.py.
scripts/mono-latest-json.py "$RELTAG" "$URLBASE" "$OUT" "$BINDIR/profiles.json" \
	> releases/latest.json

# Release it. On the nightly patch-release host the signing key is present, so
# sign + publish run automatically. mono-publish-release.sh re-verifies both
# signatures against the fleet's baked keys before shipping, so a wrong or
# rotated key fails here (set -e -> trap drops the tag -> retry + alert) rather
# than pushing a release every device would reject. Without the key on this
# host, stage only and print the two steps to run where the key lives.
if [ -n "${MONO_SIGN_KEY:-}" ]; then
	scripts/mono-sign-release.sh "$RELTAG"
	scripts/mono-publish-release.sh "$RELTAG"
	# Refresh the self-hosted ASU server (owut / attended-sysupgrade) to THIS build,
	# then VERIFY it serves the matching revision. Fail-closed: a mismatch (a stale IB,
	# feed, or profiles.json) exits nonzero, set -e fires the EXIT trap, and the tag is
	# dropped - so a published release can never silently drift from what ASU offers.
	scripts/publish-asu-feed.sh
	echo "mono-update: done - $RELTAG (published + ASU refreshed)"
else
	cat >&2 <<EOF
mono-update: staged $RELTAG (MONO_SIGN_KEY not set, not published). To release it:
  1. scripts/mono-sign-release.sh $RELTAG      # on the signing host (needs MONO_SIGN_KEY)
  2. scripts/mono-publish-release.sh $RELTAG   # rsync + push; re-verifies, refuses unsigned
  3. scripts/publish-asu-feed.sh               # refresh + verify the ASU server (owut)
EOF
	echo "mono-update: done - $RELTAG (staged, not published)"
fi
