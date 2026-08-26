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
# Override with ASU_HOST=user@host. MONO_PUBLISH_DEST is the cut's rsync dest
# (mono@<host>:<path>); strip the user (##*@) and the :<path> (%%:*) to get the bare host.
_asu_h=${MONO_PUBLISH_DEST##*@}; ASU_HOST=${ASU_HOST:-root@${_asu_h%%:*}}
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
rsync -a --no-owner --no-group "$TARBALL" "$ASU_HOST:/home/asu/mono-ib-build/$(basename "$TARBALL")"
ssh "$ASU_HOST" bash -s <<'REMOTE'
set -e
chown asu:asu /home/asu/mono-ib-build/*-imagebuilder-*.tar.zst
su - asu -c 'export XDG_RUNTIME_DIR=/run/user/987; bash ~/mono-ib-build/build-ib-container.sh'
REMOTE

# 2 + 3. package feed (additive, no --delete so older/dropped apks stay re-installable)
#         + the target profiles.json the revision endpoint reads.
# A brand-new version dir has no parents yet, and rsync won't create multiple missing
# path levels without --mkpath - so make the tree first (idempotent for existing ones).
ssh "$ASU_HOST" "mkdir -p '$DEST/packages/$ARCH' '$DEST/targets/$TARGET'"
rsync -a --no-owner --no-group --chmod=D755,F644 "$BIN/packages/$ARCH/" "$ASU_HOST:$DEST/packages/$ARCH/"
rsync -a --no-owner --no-group --chmod=D755,F644 "$TDIR/packages/"      "$ASU_HOST:$DEST/targets/$TARGET/packages/"
rsync -a --no-owner --no-group --chmod=F644      "$TDIR/profiles.json"  "$ASU_HOST:$DEST/targets/$TARGET/profiles.json"

# 3b. The ASU server's arch package-index endpoint (/json/v1/.../<arch>-index.json)
#     discovers the per-arch feeds by reading a feeds.conf (asu util.parse_feeds_conf:
#     it takes field 2 of each line as a subdir name). The mono build's feed dir ships
#     none, so without this the arch index is EMPTY and owut reports every arch package
#     "missing to-version, cannot upgrade". The names MUST match the served subdirs
#     (base/luci/packages/routing/telephony/video); the URLs are ignored by asu.
ssh "$ASU_HOST" "cat > '$DEST/packages/$ARCH/feeds.conf' && chmod 644 '$DEST/packages/$ARCH/feeds.conf'" <<'FEEDS'
src-git base https://git.openwrt.org/openwrt/openwrt.git
src-git packages https://git.openwrt.org/feed/packages.git
src-git luci https://git.openwrt.org/project/luci.git
src-git routing https://git.openwrt.org/feed/routing.git
src-git telephony https://git.openwrt.org/feed/telephony.git
src-git video https://github.com/openwrt/video.git
FEEDS

# 3b2. The overview's branch->targets map (which owut reads to know a version supports THIS
#      device's target) comes from asu reload_targets fetching `<version>/.targets.json`
#      (asu util.reload_targets). Without it the branch's `targets` is {} and owut refuses
#      the ENTIRE version: "version-to <ver> is not available, pick one from above" (empty
#      list). asu caches it in-process, so a missing file only bites after a server
#      restart/flush - write it every publish so it can never silently go stale.
ssh "$ASU_HOST" "cat > '$DEST/.targets.json' && chmod 644 '$DEST/.targets.json'" <<TARGETS
{"$TARGET": "$ARCH"}
TARGETS

# 3c. Advertise the FULL upstream package set, not just the ~400 Mono-built packages,
#     so owut/attended-sysupgrade can `-a` (add) and PRESERVE *any* upstream package
#     across a rebuild - not only what Mono builds. owut's "available in target version"
#     set is asu's synthesized arch index (/json/v1/<rel>/packages/<arch>-index.json),
#     which asu builds by unioning the per-feed index.json files under our feed dir
#     (settings.upstream_url = the internal http://upstream = /srv/asu-feed). A package
#     absent there is "missing to-version, cannot upgrade" client-side, even though the
#     IB could build it. So fold upstream's per-feed index.json into ours.
#     INDEX-ONLY: we do NOT mirror .apks - the ImageBuilder still fetches the real apks
#     from its appended downloads.openwrt.org feeds at build time (a build with an
#     upstream-only package resolves + builds fine), so this only advertises availability.
#     Precedence is upstream-wins on overlap, which within a frozen release equals
#     highest-version-wins (Mono never exceeds upstream), so the advertised version
#     matches exactly what the IB installs - no phantom out-of-date/downgrade from owut.
#     Fail-closed: if the upstream index can't be fetched, refuse (don't ship a feed that
#     silently can't resolve upstream packages); set -e -> the release tag is dropped.
echo "publish-asu: folding upstream package index into the feed (owut availability)"
ssh "$ASU_HOST" "VER='$VER' ARCH='$ARCH' python3 -" <<'MERGE'
import json, os, sys, urllib.request
V = os.environ["VER"]; A = os.environ["ARCH"]
UP = f"https://downloads.openwrt.org/releases/{V}/packages/{A}"
BASE = f"/srv/asu-feed/releases/{V}/packages/{A}"
FEEDS = ["base", "luci", "packages", "routing", "telephony", "video"]

def fetch(url):
    try:
        with urllib.request.urlopen(url, timeout=90) as r:
            return json.load(r).get("packages", {})
    except Exception as e:
        print(f"  WARN fetch {url}: {e}", file=sys.stderr)
        return {}

# Fetch everything first; only touch the feed if upstream actually answered, so a
# transient upstream outage fails the release instead of shipping a gutted index.
up = {f: fetch(f"{UP}/{f}/index.json") for f in FEEDS}
up_total = sum(len(v) for v in up.values())
if up_total < 1000:   # a healthy union is ~9800; <1000 means upstream broadly failed
    print(f"publish-asu: upstream index fetch returned only {up_total} pkgs - refusing", file=sys.stderr)
    sys.exit(1)

before = after = 0
for f in FEEDS:
    d = f"{BASE}/{f}"; os.makedirs(d, exist_ok=True); lp = f"{d}/index.json"
    mono = {}
    if os.path.exists(lp):
        try: mono = json.load(open(lp)).get("packages", {})
        except Exception: mono = {}
    merged = {**mono, **up[f]}   # upstream-wins == highest-wins (verified)
    json.dump({"version": 2, "architecture": A, "packages": merged}, open(lp, "w"))
    os.chmod(lp, 0o644)
    before += len(mono); after += len(merged)
print(f"  advertised packages: {before} (Mono) -> {after} (Mono + upstream)")
MERGE

# 4. bust the asu build cache (redis job/result cache + the built-image store) so a
#    repeated request can't be served a pre-refresh (stale-revision) image.
ssh "$ASU_HOST" "su - asu -c 'export XDG_RUNTIME_DIR=/run/user/987; podman exec asu-deploy_redis_1 redis-cli FLUSHALL >/dev/null; rm -rf /home/asu/public/store/*'"

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

# 6. VERIFY (fail-closed): the synthesized arch index must now advertise the upstream
#    union (not just Mono's ~400), or owut still can't add/preserve upstream packages.
#    This is the index owut fetches for its availability set; assert it's the full set.
NPKG=$(curl -fsS -m 25 "$ASU_URL/json/v1/releases/$VER/packages/${ARCH}-index.json" 2>/dev/null \
	| python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)
[ "${NPKG:-0}" -gt 1000 ] || {
	echo "publish-asu: arch index advertises only ${NPKG:-0} packages (upstream fold missing?) - refusing" >&2; exit 1; }
echo "=== publish-asu: arch index advertises $NPKG packages (Mono + upstream) ==="

# 7. VERIFY (fail-closed): owut refuses a whole version whose branch has empty `targets`
#    (the .targets.json from 3b2) - "version-to <ver> is not available, pick one from
#    above". Assert the overview lists OUR target under OUR version's branch.
OVOK=no
for _ in 1 2 3 4; do
	OVOK=$(curl -fsS -m 25 "$ASU_URL/json/v1/overview.json" 2>/dev/null \
		| VER="$VER" TGT="$TARGET" python3 -c 'import sys,json,os
d=json.load(sys.stdin); b=d.get("branches",d); V=os.environ["VER"]; T=os.environ["TGT"]
print("ok" if any(V in x.get("versions",[]) and T in (x.get("targets") or {}) for x in b.values()) else "no")' 2>/dev/null || echo no)
	[ "$OVOK" = ok ] && break
	sleep 3
done
[ "$OVOK" = ok ] || {
	echo "publish-asu: overview lists no '$TARGET' under '$VER' (.targets.json missing) - owut would refuse the version - refusing" >&2; exit 1; }
echo "=== publish-asu: verified owut can resolve $VER for $TARGET ==="
