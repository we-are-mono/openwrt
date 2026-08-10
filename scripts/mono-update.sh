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
# Usage: scripts/mono-update.sh [--dry-run] [--force]
#   --force: release the current base even when already up to date
#            (first release, or re-release after local-only changes)
set -eu

cd "$(dirname "$0")/.."
BRANCH=mono
DRY_RUN=""
FORCE=""
for a in "$@"; do
	case "$a" in
	--dry-run) DRY_RUN=1 ;;
	--force) FORCE=1 ;;
	esac
done

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

# Two release triggers: a new upstream stable tag (mono-vX.Y.Z), or new
# commits on the branch since the last release of the current base -
# ASK pin bumps, package fixes - which cut a revision (mono-vX.Y.Z-rN).
if [ "$LATEST" != "$BASE" ]; then
	RELTAG="mono-$LATEST"
	echo "mono-update: $BASE -> $LATEST ($RELTAG)"
else
	LASTTAG=$(git tag -l "mono-$BASE" "mono-$BASE-r*" | sort -V | tail -1)
	if [ -n "$LASTTAG" ] && [ -z "$FORCE" ] && \
	   [ "$(git rev-parse "$LASTTAG^{commit}")" = "$(git rev-parse "$BRANCH")" ]; then
		echo "mono-update: up to date ($LASTTAG at branch head)"
		exit 0
	fi
	if [ -z "$LASTTAG" ]; then
		RELTAG="mono-$BASE"
	elif [ "$LASTTAG" = "mono-$BASE" ]; then
		RELTAG="mono-$BASE-r2"
	else
		RELTAG="mono-$BASE-r$(( ${LASTTAG##*-r} + 1 ))"
	fi
	echo "mono-update: new commits on $BASE -> $RELTAG"
fi
[ -n "$DRY_RUN" ] && exit 0

if [ "$LATEST" != "$BASE" ]; then
	if ! git rebase --onto "$LATEST" "$BASE" "$BRANCH"; then
		git rebase --abort
		echo "mono-update: REBASE CONFLICT rebasing onto $LATEST - resolve manually:" >&2
		echo "  git rebase --onto $LATEST $BASE $BRANCH" >&2
		exit 1
	fi
fi

# Tag before building so the image can bake its own release identity
# (mono-update-check reads it at build time). Dropped again on failure.
git tag -f "$RELTAG"

cleanup_fail() {
	git tag -d "$RELTAG" >/dev/null 2>&1 || true
	echo "mono-update: BUILD FAILED for $RELTAG" >&2
	exit 1
}

cp configs/mono_gateway-dk.seed .config
make defconfig || cleanup_fail
# mono-update-check bakes the release tag into /etc/mono_release at its
# build time; force it fresh or every image ships the stale identity of
# the package's first build (and auto-mode devices re-flash forever).
make package/mono/mono-update-check/clean package/mono/mono-update-check/compile || cleanup_fail
make -j"$(nproc)" world || cleanup_fail

OUT="releases/$RELTAG"
BINDIR=bin/targets/layerscape/armv8_64b
URLBASE="${MONO_PUBLISH_URL:-https://openwrt.mono.si}"
rm -rf "$OUT"
mkdir -p "$OUT"
cp "$BINDIR"/openwrt-layerscape-armv8_64b-mono_*-emmc.img.gz \
   "$BINDIR"/openwrt-layerscape-armv8_64b-mono_*-sysupgrade.bin \
   "$BINDIR"/openwrt-layerscape-armv8_64b-mono_*.manifest "$OUT/"
git format-patch --quiet -o "$OUT/patches" "$LATEST..$BRANCH"
(cd "$OUT" && sha256sum *.img.gz *.bin > sha256sums)

# One entry per built mono device, keyed by board name (device profile
# name with the first underscore as the vendor comma, matching the
# SUPPORTED_DEVICES convention).
{
	printf '{\n\t"tag": "%s",\n\t"date": "%s",\n\t"devices": {' \
		"$RELTAG" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	sep=""
	for f in "$OUT"/*-sysupgrade.bin; do
		dev=$(basename "$f")
		dev=${dev#openwrt-layerscape-armv8_64b-}
		dev=${dev%-ext4-sysupgrade.bin}
		board=$(echo "$dev" | sed 's/_/,/')
		sha=$(sha256sum "$f" | cut -d' ' -f1)
		printf '%s\n\t\t"%s": { "sysupgrade": "%s/%s/%s", "sha256": "%s" }' \
			"$sep" "$board" "$URLBASE" "$RELTAG" "$(basename "$f")" "$sha"
		sep=","
	done
	printf '\n\t}\n}\n'
} > releases/latest.json

if [ -n "${MONO_PUBLISH_DEST:-}" ]; then
	echo "mono-update: publishing to $MONO_PUBLISH_DEST"
	rsync -a "$OUT" releases/latest.json "$MONO_PUBLISH_DEST/"
else
	echo "mono-update: MONO_PUBLISH_DEST unset, artifacts staged in $OUT only"
fi

# Push the rebased branch and release tag when a 'mono' remote is
# configured (machine-local in .git/config; nothing committed here).
if git remote get-url mono >/dev/null 2>&1; then
	echo "mono-update: pushing $BRANCH and $RELTAG"
	git push --force-with-lease mono "$BRANCH"
	git push -f mono "$RELTAG"

	# Mirror the release on the forge with the flashables attached.
	# Repo derived from the remote URL; failure is reported, not fatal.
	if command -v gh >/dev/null 2>&1; then
		REPO=$(git remote get-url mono | sed -E 's#(git@[^:]+:|https://[^/]+/)##; s#\.git$##')
		gh release create "$RELTAG" --repo "$REPO" \
			--title "$RELTAG" \
			--notes "Automated release: OpenWrt $LATEST base, branch $(git rev-parse --short "$BRANCH")." \
			"$OUT"/*-sysupgrade.bin "$OUT"/*-emmc.img.gz "$OUT/sha256sums" \
			|| echo "mono-update: WARNING: GitHub release failed" >&2
	fi
fi

echo "mono-update: done - $RELTAG"
