#!/bin/sh
# Refresh the upstream OpenWrt feed pins in feeds.conf.default to the current HEAD
# of the matching stable branch, then sync the feed checkouts.
#
# WHY: upstream pins feeds.conf.default to each RELEASE TAG's feed state (e.g.
# v25.12.5 == 2026-06-29), which then freezes while the stable BRANCH keeps getting
# maintenance backports. Devices pull those via `apk upgrade` from the live branch
# feed, so they drift AHEAD of a mono release built from the frozen tag pins -> owut
# sees dozens of "downgrades" and refuses to upgrade. Re-pointing the pins at the
# branch HEAD keeps the release feed level with what devices actually run.
#
# STILL PINNED (reproducible): this resolves to a specific commit, and mono-update.sh
# records the exact resolved pins in releases/<tag>/feeds.lock. feeds.conf.default is a
# TRACKED UPSTREAM file - mono-update.sh edits it transiently for the build and its EXIT
# trap restores it (same pattern as the `version` file), so upstream's copy is never
# patched here (no rebase friction).
#
# Usage: scripts/mono-refresh-feed-pins.sh [stable-branch]   (default: openwrt-25.12)
# Env:   MONO_FREEZE_FEEDS=1  keep existing pins, skip the re-resolve. For a HOTFIX cut
#        that must carry ONLY its own change, not weeks of incidental feed churn.
#
# Only upstream feeds (git.openwrt.org / github.com/openwrt) are re-pinned; any local
# or in-tree feed is left untouched. A feed whose remote is unreachable keeps its
# current pin (warn, don't fail) so a network blip doesn't wedge a cut.
set -eu

cd "$(dirname "$0")/.."
CONF=feeds.conf.default
BRANCH="${1:-${MONO_FEED_BRANCH:-openwrt-25.12}}"
[ -f "$CONF" ] || { echo "refresh-feeds: $CONF missing" >&2; exit 1; }

if [ -n "${MONO_FREEZE_FEEDS:-}" ]; then
	echo "refresh-feeds: FREEZE - keeping existing pins (branch $BRANCH not queried)"
else
	# Snapshot the upstream pinned lines up front - the loop edits CONF as it goes.
	pinned=$(grep -E '^src-git[[:space:]].*(git\.openwrt\.org|github\.com/openwrt).*\^[0-9a-f]+' "$CONF" || true)
	if [ -z "$pinned" ]; then
		echo "refresh-feeds: no upstream ^-pinned feeds in $CONF"
	else
		echo "refresh-feeds: tracking branch $BRANCH"
		printf '%s\n' "$pinned" | while IFS= read -r line; do
			name=$(printf '%s\n' "$line" | awk '{print $2}')
			urlpin=$(printf '%s\n' "$line" | awk '{print $3}')
			url=${urlpin%^*}
			old=${urlpin##*^}
			new=$(git ls-remote "$url" "refs/heads/$BRANCH" 2>/dev/null | awk 'NR==1{print $1}')
			if [ -z "$new" ]; then
				echo "  WARN  $name: '$BRANCH' unreachable, keeping $old"
			elif [ "$new" = "$old" ]; then
				echo "  ok    $name: already current ($old)"
			else
				# Anchor on the exact old hash so only this feed's line changes.
				sed -i "s|\\^$old|^$new|" "$CONF"
				echo "  bump  $name: $old -> $new"
			fi
		done
	fi
fi

# Sync the feed checkouts to the (possibly new) pins. Only feeds listed in
# feeds.conf.default are touched; local/in-tree package dirs are unaffected.
echo "refresh-feeds: syncing feed checkouts"
./scripts/feeds update -a
./scripts/feeds install -a
