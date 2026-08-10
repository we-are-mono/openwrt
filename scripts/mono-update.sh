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

# Next revision of the release base: highest existing -rN plus one.
LAST=$(git tag -l "mono-$LATEST-r*" | sed 's/.*-r//' | sort -n | tail -1)
RELTAG="mono-$LATEST-r$(( ${LAST:-0} + 1 ))"
echo "mono-update: release $RELTAG"
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

# From here on ANY nonzero exit - build, artifact staging, publish, push -
# removes the tag, so the next run recomputes this same revision and
# retries instead of seeing a tag at branch head and skipping. Without
# this a failed rsync would leave the tag and wedge the release. set -e
# turns a failed command into an exit, which fires the trap.
on_exit() {
	rc=$?
	[ "$rc" -eq 0 ] && return 0
	git tag -d "$RELTAG" >/dev/null 2>&1 || true
	echo "mono-update: FAILED ($RELTAG, rc=$rc) - tag dropped, will retry next run" >&2
}
trap on_exit EXIT

cp configs/mono_gateway-dk.seed .config
make defconfig
# mono-update-check bakes the release tag into /etc/mono_release at its
# build time; force it fresh or every image ships the stale identity of
# the package's first build (and auto-mode devices re-flash forever).
make package/mono/mono-update-check/clean package/mono/mono-update-check/compile
make -j"$(nproc)" world

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

# Sign the hash list. This - not the sha in latest.json - is the trust
# anchor devices verify against the baked public key before flashing.
USIGN=staging_dir/host/bin/usign
if [ -n "${MONO_SIGN_KEY:-}" ] && [ -x "$USIGN" ]; then
	"$USIGN" -S -m "$OUT/sha256sums" -s "$MONO_SIGN_KEY" -x "$OUT/sha256sums.sig"
	echo "mono-update: signed sha256sums"
else
	echo "mono-update: WARNING: unsigned release (set MONO_SIGN_KEY); auto-update devices will refuse it" >&2
fi

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

# latest.json: board keys come from the image metadata (profiles.json),
# not filename string-surgery, so a device that finds no image for its
# board fails visibly rather than from a silent naming drift.
python3 - "$RELTAG" "$URLBASE" "$OUT" "$BINDIR/profiles.json" \
	> releases/latest.json <<'PY'
import json, sys, os, hashlib, datetime
reltag, urlbase, out, profiles = sys.argv[1:5]
prof = json.load(open(profiles)).get("profiles", {})
devices = {}
for name, p in prof.items():
    boards = p.get("supported_devices") or []
    img = next((im["name"] for im in p.get("images", [])
                if im.get("name", "").endswith("sysupgrade.bin")
                and os.path.exists(os.path.join(out, im["name"]))), None)
    if not boards or not img:
        continue
    h = hashlib.sha256(open(os.path.join(out, img), "rb").read()).hexdigest()
    devices[boards[0]] = {"sysupgrade": f"{urlbase}/{reltag}/{img}", "sha256": h}
json.dump({"tag": reltag,
           "date": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
           "devices": devices}, sys.stdout, indent=2)
PY

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
			"$OUT"/*-sysupgrade.bin "$OUT"/*-emmc.img.gz \
			"$OUT/sha256sums" "$OUT"/sha256sums.sig "$OUT/flash-mono-gateway.sh" \
			|| echo "mono-update: WARNING: GitHub release failed" >&2
	fi
fi

echo "mono-update: done - $RELTAG"
