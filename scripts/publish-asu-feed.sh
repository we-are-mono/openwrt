#!/bin/bash
# Publish a release to the self-hosted ASU server so owut / attended-sysupgrade
# offers it. Called BY mono-update.sh at release time, and FAIL-CLOSED: the release is
# not "done" until the ASU /api/v1/revision endpoint reports the EXACT version_code we
# just built - so the ASU server can never silently drift from the published release.
# A stale/missing input -> the verify at the end fails -> set -e -> mono-update.sh's
# EXIT trap drops the release tag -> the next run retries. Drift is impossible, not
# merely unlikely.
#
# Everything shipped here comes from THIS build, so the three ASU inputs stay in lockstep:
#   1. the ImageBuilder tarball  -> rebuilt into the IB container asu builds images from
#   2. the package feed (kmods + arch userspace) -> apk resolves the release's packages
#   3. the target profiles.json  -> the /api/v1/revision endpoint reads its version_code
# (3) is the one that drifted once: the old feed-only sync shipped packages but NOT
# profiles.json, so the revision endpoint stayed stale while the IB/builds were current.
#
# Needs: the built IB tarball + profiles.json (run AFTER make target/imagebuilder/install)
# and root SSH to the ASU host (ships the feed under /srv/asu-feed and drives asu's rootless
# podman: rebuild the IB container, flush the build cache).
set -eu

# ASU host: default to the publish dest's host (root@<host>) so no IP is hardcoded here.
# Override with GROOT=user@host; MONO_PUBLISH_DEST is set by the cut's env (mono@<host>).
GROOT=${GROOT:-root@${MONO_PUBLISH_DEST##*@}}
ASU_URL=${ASU_URL:-https://sysupgrade.mono.si}
TARGET=${ASU_TARGET:-layerscape/armv8_64b}
ARCH=${ASU_ARCH:-aarch64_generic}
cd "$(dirname "$0")/.."   # -> source/
BIN=bin
TDIR="$BIN/targets/$TARGET"

TARBALL=$(ls "$TDIR"/*-imagebuilder-*.tar.zst 2>/dev/null | head -1)
[ -n "$TARBALL" ] || { echo "publish-asu: no ImageBuilder tarball under $TDIR (run: make target/imagebuilder/install)" >&2; exit 1; }
VER=$(tar --zstd -xOf "$TARBALL" --wildcards '*/repositories' 2>/dev/null | sed -n 's|.*/releases/\([^/]\+\)/.*|\1|p' | head -1)
# The revision the client compares against: the version_code baked into THIS build's
# profiles.json, which is exactly what the ASU /api/v1/revision endpoint serves back
# once we ship that profiles.json to the feed.
WANT=$(grep -oE '"version_code":"[^"]*"' "$TDIR/profiles.json" 2>/dev/null | head -1 | sed 's/.*:"//; s/"$//')
[ -n "$VER" ] && [ -n "$WANT" ] || { echo "publish-asu: could not derive version/version_code from the build" >&2; exit 1; }
DEST="/srv/asu-feed/releases/$VER"
echo "=== publish-asu: $ASU_URL <- version $VER, revision $WANT ==="

# 1. ship the IB tarball + rebuild the IB container (asu's rootless podman, uid 987).
#    asu looks the IB up as imagebuilder:<target>-v<version>; build-ib-container.sh
#    rebuilds+pushes that tag from whatever tarball is in place.
rsync -a --no-owner --no-group "$TARBALL" "$GROOT:/home/asu/mono-ib-build/$(basename "$TARBALL")"
ssh "$GROOT" bash -s <<'REMOTE'
set -e
chown asu:asu /home/asu/mono-ib-build/*-imagebuilder-*.tar.zst
su - asu -c 'export XDG_RUNTIME_DIR=/run/user/987; bash ~/mono-ib-build/build-ib-container.sh'
REMOTE

# 2 + 3. package feed (additive, no --delete so older/dropped apks stay re-installable)
#         + the target profiles.json the revision endpoint reads.
# A brand-new version dir has no parents yet, and rsync won't create multiple missing
# path levels without --mkpath - so make the tree first (idempotent for existing ones).
ssh "$GROOT" "mkdir -p '$DEST/packages/$ARCH' '$DEST/targets/$TARGET'"
rsync -a --no-owner --no-group --chmod=D755,F644 "$BIN/packages/$ARCH/" "$GROOT:$DEST/packages/$ARCH/"
rsync -a --no-owner --no-group --chmod=D755,F644 "$TDIR/packages/"      "$GROOT:$DEST/targets/$TARGET/packages/"
rsync -a --no-owner --no-group --chmod=F644      "$TDIR/profiles.json"  "$GROOT:$DEST/targets/$TARGET/profiles.json"

# 3b. The ASU server's arch package-index endpoint (/json/v1/.../<arch>-index.json)
#     discovers the per-arch feeds by reading a feeds.conf (asu util.parse_feeds_conf:
#     it takes field 2 of each line as a subdir name). The mono build's feed dir ships
#     none, so without this the arch index is EMPTY and owut reports every arch package
#     "missing to-version, cannot upgrade". The names MUST match the served subdirs
#     (base/luci/packages/routing/telephony/video); the URLs are ignored by asu.
ssh "$GROOT" "cat > '$DEST/packages/$ARCH/feeds.conf' && chmod 644 '$DEST/packages/$ARCH/feeds.conf'" <<'FEEDS'
src-git base https://git.openwrt.org/openwrt/openwrt.git
src-git packages https://git.openwrt.org/feed/packages.git
src-git luci https://git.openwrt.org/project/luci.git
src-git routing https://git.openwrt.org/feed/routing.git
src-git telephony https://git.openwrt.org/feed/telephony.git
src-git video https://github.com/openwrt/video.git
FEEDS

# 4. bust the asu build cache (redis job/result cache + the built-image store) so a
#    repeated request can't be served a pre-refresh (stale-revision) image.
ssh "$GROOT" "su - asu -c 'export XDG_RUNTIME_DIR=/run/user/987; podman exec asu-deploy_redis_1 redis-cli FLUSHALL >/dev/null; rm -rf /home/asu/public/store/*'"

# 5. VERIFY (fail-closed): ASU must now report EXACTLY the revision we built. A few
#    retries absorb front-proxy propagation; a persistent mismatch fails the release.
GOT=""
for _ in 1 2 3 4 5 6; do
	GOT=$(curl -fsS -m 20 "$ASU_URL/api/v1/revision/$VER/$TARGET" 2>/dev/null | sed 's/.*"revision":"//; s/".*//')
	[ "$GOT" = "$WANT" ] && break
	sleep 3
done
[ "$GOT" = "$WANT" ] || { echo "publish-asu: DRIFT - $ASU_URL serves revision '$GOT', but this build is '$WANT'" >&2; exit 1; }
echo "=== publish-asu: verified $ASU_URL serves $WANT ==="
