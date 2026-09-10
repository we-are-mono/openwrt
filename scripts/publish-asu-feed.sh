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

# 1a. MIRROR + MERGE upstream apks INTO the mono feed so the IB reads ONLY the mono groot
#     feed (http://upstream) and never a live downloads.openwrt.org. WHY the change:
#     the old model had the IB carry BOTH repos, untagged, so apk installed the HIGHEST
#     version of each package. When upstream point-updates a package mono ALSO builds
#     (e.g. the ucode family r1 -> r2 on the rolling 25.12.5 feed), stock's r2 shadowed
#     mono's r1 - but a device is pinned to the r1 it was flashed with, so asu's
#     check_manifest 500'd with "libucode version not as requested: r1 vs r2". The fix is
#     SINGLE-ORIGIN + a version UNION: the IB reads only this mono groot feed, which carries
#     mono's apks AND upstream's for every name whose versions differ, all re-signed with
#     mono's key (the IB already trusts both mono's and openwrt-25.12's keys and re-verifies
#     each apk, so mono-signing the index over mixed apks is safe). apk then picks the
#     HIGHEST available: mono wins where it is ahead or distinct (ASK, kmods, mono-*, patched
#     packages that bump their release); upstream wins where mono is merely behind (its build
#     lags the rolling 25.12.5 feed) - so a device is neither shadowed into a phantom version
#     (the libucode 500) nor downgraded off a newer package it already has. One origin, no
#     live upstream at build time, no version race. It also gives routing/telephony/video a real
#     packages.adb (they had none -> "wget error 8"), and folds the target userspace feed
#     (iptables-mod-* etc.) in the same way. Fail-closed: refuse if upstream is unreachable.
#     The mirror is a persistent, incremental cache (only new apks download); the assembled
#     feed is rebuilt each run from hardlinks (cheap) so re-runs are idempotent.
echo "publish-asu: mirroring + merging upstream apks into the mono feed (mono-authoritative)"
TOP="$PWD"
MIRROR="${ASU_MIRROR:-$TOP/../asu-upstream-mirror}"   # persistent stock-apk cache
FEEDOUT="${ASU_FEEDOUT:-$TOP/../asu-feedout}"          # assembled feed (rebuilt each run)
VER="$VER" ARCH="$ARCH" TARGET="$TARGET" BIN="$BIN" TDIR="$TDIR" \
  APK="$TOP/staging_dir/host/bin/apk" MKINDEX="$TOP/scripts/make-index-json.py" \
  KEY="$TOP/private-key.pem" MIRROR="$MIRROR" FEEDOUT="$FEEDOUT" \
  SELFTEST_LIMIT="${SELFTEST_LIMIT:-0}" python3 - <<'MERGE'
import json, os, shutil, subprocess, sys, tempfile, urllib.request
V=os.environ["VER"]; A=os.environ["ARCH"]; T=os.environ["TARGET"]
BIN=os.environ["BIN"]; TDIR=os.environ["TDIR"]; APK=os.environ["APK"]; MKINDEX=os.environ["MKINDEX"]
KEY=os.environ["KEY"]; MIRROR=os.environ["MIRROR"]; FEEDOUT=os.environ["FEEDOUT"]
LIMIT=int(os.environ.get("SELFTEST_LIMIT","0"))   # 0 = mirror the full feed; >0 caps for self-test
REL=f"https://downloads.openwrt.org/releases/{V}"
ARCHFEEDS=["base","luci","packages","routing","telephony","video"]

def adb_names(adb_path):
    # {real_pkg_name: version} from a packages.adb, via adbdump. REAL names (e.g.
    # libucode20230711) - NOT the provides names that index.json collapses to (libucode).
    # The apk FILENAME uses the real name, so downloads AND the mono-vs-stock overlap must
    # both key on it. Reading mono's pristine build packages.adb here (never regenerated in
    # place) keeps the run idempotent. Empty for feeds/paths with no packages.adb.
    if not adb_path or not os.path.exists(adb_path): return {}
    out=subprocess.run([APK,"adbdump","--format","json",adb_path],capture_output=True,text=True).stdout
    try: pkgs=json.loads(out).get("packages",[])
    except json.JSONDecodeError: return {}
    return {p["name"]: p["version"] for p in pkgs if p.get("name") and p.get("version")}

def fetch_up(feed_url):
    # upstream {real_name: version}: fetch the feed's signed packages.adb and adbdump it
    # (same real-name basis as mono's, so overlap detection and filenames line up).
    try:
        with urllib.request.urlopen(f"{feed_url}/packages.adb", timeout=90) as r:
            data=r.read()
    except Exception as e:
        print(f"  WARN fetch {feed_url}/packages.adb: {e}", file=sys.stderr); return {}
    with tempfile.NamedTemporaryFile(suffix=".adb", delete=False) as tf:
        tf.write(data); tmp=tf.name
    try: return adb_names(tmp)
    finally:
        try: os.unlink(tmp)
        except OSError: pass

def link(src,dst):
    try: os.link(src,dst)
    except FileExistsError: pass
    except OSError: shutil.copy2(src,dst)      # cross-device fallback

def dl(url,dest):
    tmp=dest+".part"
    try:
        urllib.request.urlretrieve(url,tmp); os.replace(tmp,dest); return True
    except Exception as e:
        try: os.unlink(tmp)
        except OSError: pass
        print(f"  WARN download {url}: {e}", file=sys.stderr); return False

def build_feed(up_url, mono_dir, mirror_dir, out_dir):
    up=fetch_up(up_url)
    mono=adb_names(os.path.join(mono_dir,"packages.adb"))   # {name: version}, for version compare
    os.makedirs(mirror_dir,exist_ok=True)
    if os.path.isdir(out_dir): shutil.rmtree(out_dir)
    os.makedirs(out_dir,exist_ok=True)
    # Link mono's own apks first, then UNION in upstream's. We mirror the stock apk for any
    # name mono does NOT build, AND for any name whose upstream version DIFFERS from mono's
    # (mono's build can lag the rolling openwrt-25.12 feed). Both versions then sit in the
    # feed and apk picks the HIGHEST: mono wins where it is ahead or distinct (ASK, kmods,
    # mono-*, patched packages that bump their release), upstream wins where mono is merely
    # behind - which stops us downgrading a device that already pulled the newer one. Not
    # mono-wins-exclusive: that served mono's stale build and 38-downgraded a live device.
    if os.path.isdir(mono_dir):
        for fn in os.listdir(mono_dir):
            if fn.endswith(".apk"): link(os.path.join(mono_dir,fn), os.path.join(out_dir,fn))
    want=[(n,v) for n,v in up.items() if n not in mono or mono[n]!=v]
    if LIMIT: want=want[:LIMIT]
    stock=0
    for n,v in want:
        fn=f"{n}-{v}.apk"; cached=os.path.join(mirror_dir,fn)
        if not os.path.exists(cached) and not dl(f"{up_url}/{fn}",cached): continue
        link(cached, os.path.join(out_dir,fn)); stock+=1
    # one mono-signed packages.adb over the assembled set + a matching index.json (so owut's
    # advertised set == what the feed actually holds). --allow-untrusted: index-time only;
    # the IB re-verifies each apk against its trusted keys at build time.
    apks=[os.path.join(out_dir,f) for f in os.listdir(out_dir) if f.endswith(".apk")]
    subprocess.run([APK,"mkndx","--allow-untrusted","--sign-key",KEY,
                    "--output",os.path.join(out_dir,"packages.adb"),*apks],
                   check=True,capture_output=True,text=True)
    dump=subprocess.run([APK,"adbdump","--format","json",os.path.join(out_dir,"packages.adb")],
                        capture_output=True,text=True).stdout
    idx=subprocess.run([MKINDEX,"-f","apk","-a",A,"-"],input=dump,capture_output=True,text=True).stdout
    open(os.path.join(out_dir,"index.json"),"w").write(idx)
    return len(mono),stock,len(apks)

# Fail-closed: refuse the whole publish if upstream is broadly unreachable, so a transient
# upstream outage can't ship a gutted (mono-only) feed.
union=sum(len(fetch_up(f"{REL}/packages/{A}/{f}")) for f in ARCHFEEDS)
if union < 1000:
    print(f"publish-asu: upstream package union only {union} pkgs - refusing", file=sys.stderr); sys.exit(1)

tm=ts=ta=0
for f in ARCHFEEDS:
    m,s,a=build_feed(f"{REL}/packages/{A}/{f}", f"{BIN}/packages/{A}/{f}",
                     f"{MIRROR}/packages/{A}/{f}", f"{FEEDOUT}/packages/{A}/{f}")
    print(f"  {f:9s}: mono={m} +stock={s} = {a}"); tm+=m; ts+=s; ta+=a
# target userspace + kmods feed, same treatment (brings iptables-mod-* etc. under mono).
m,s,a=build_feed(f"{REL}/targets/{T}/packages", f"{TDIR}/packages",
                 f"{MIRROR}/targets/{T}/packages", f"{FEEDOUT}/targets/{T}/packages")
print(f"  target   : mono={m} +stock={s} = {a}"); tm+=m; ts+=s; ta+=a
print(f"  feed assembled: {tm} mono + {ts} stock = {ta} apks (mono-authoritative, mono-signed)")
MERGE

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
# Ship the ASSEMBLED, mono-authoritative feed (mono apks + mirrored stock apks + the
# mono-signed packages.adb/index.json built in 1a), NOT raw bin/ - that is what makes the
# groot feed self-contained so the IB needs no live downloads.openwrt.org. Additive (no
# --delete) so older apks a deployed device still pins stay re-installable.
ssh "$ASU_HOST" "mkdir -p '$DEST/packages/$ARCH' '$DEST/targets/$TARGET/packages'"
rsync -a --no-owner --no-group --chmod=D755,F644 "$FEEDOUT/packages/$ARCH/"          "$ASU_HOST:$DEST/packages/$ARCH/"
rsync -a --no-owner --no-group --chmod=D755,F644 "$FEEDOUT/targets/$TARGET/packages/" "$ASU_HOST:$DEST/targets/$TARGET/packages/"
rsync -a --no-owner --no-group --chmod=F644      "$TDIR/profiles.json"                "$ASU_HOST:$DEST/targets/$TARGET/profiles.json"

# 3b. The ASU server's arch package-index endpoint (/json/v1/.../<arch>-index.json)
#     discovers the per-arch feeds by reading a feeds.conf (asu util.parse_feeds_conf:
#     it takes field 2 of each line as a subdir name). The mono build's feed dir ships
#     none, so without this the arch index is EMPTY and owut reports every arch package
#     "missing to-version, cannot upgrade". The names MUST match the served subdirs
#     (base/luci/packages/routing/telephony/video); the URLs are ignored by asu. We also
#     PRESERVE any extra src-git line already in the file (e.g. a separately-deployed verso
#     feed added by the deploy-verso flow) so a rewrite never drops it - keeping this script
#     decoupled from those products: it names none of them, it just never clobbers them.
ssh "$ASU_HOST" bash -s "$DEST/packages/$ARCH/feeds.conf" <<'FEEDS'
F="$1"
extra=$(grep '^src-git ' "$F" 2>/dev/null | grep -vE '^src-git (base|packages|luci|routing|telephony|video) ' || true)
{ cat <<'STD'
src-git base https://git.openwrt.org/openwrt/openwrt.git
src-git packages https://git.openwrt.org/feed/packages.git
src-git luci https://git.openwrt.org/project/luci.git
src-git routing https://git.openwrt.org/feed/routing.git
src-git telephony https://git.openwrt.org/feed/telephony.git
src-git video https://github.com/openwrt/video.git
STD
[ -n "$extra" ] && printf '%s\n' "$extra"; } > "$F"
chmod 644 "$F"
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

# 3c. (The FULL package set is advertised to owut - so it can `-a`/preserve any upstream
#      package across a rebuild - because step 1a now MIRRORS every upstream apk mono does
#      not build INTO the served feed and regenerates each index.json from the assembled
#      packages.adb. owut's "available in target version" set is asu's synthesized arch
#      index (/json/v1/<rel>/packages/<arch>-index.json), which asu unions from the per-feed
#      index.json under our served feed dir (settings.upstream_url = http://upstream =
#      /srv/asu-feed) - so shipping the assembled index.json via the rsync IS what populates
#      it, and it now equals the apks the IB can actually install (all local, mono-signed).
#      The IB no longer carries any downloads.openwrt.org feed - see mono-ib-build/
#      Containerfile - so there is a single origin and stock can never shadow mono again.)

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
