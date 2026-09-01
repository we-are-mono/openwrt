#!/bin/sh
# Publish an already-signed, staged Mono release: rsync the artifacts and the
# signed latest.json to MONO_PUBLISH_DEST, then push the branch + tag and
# mirror on the forge. REFUSES unless both usign signatures are present, so an
# unsigned or tampered staging directory can never reach the fleet.
#
# Env: MONO_PUBLISH_DEST (rsync destination). A 'mono' git remote enables the
# branch/tag push and the gh forge mirror.
#
# Usage: scripts/mono-publish-release.sh <mono-vX.Y.Z-rN>
set -eu

cd "$(dirname "$0")/.."
RELTAG=${1:?usage: mono-publish-release.sh <mono-vX.Y.Z-rN>}
# The trunk to push. One 'mono' trunk by default; set MONO_PUBLISH_BRANCH to
# push an on-demand archive line (mono-v25.12) instead. The base version rides
# in $RELTAG regardless of branch name.
BRANCH=${MONO_PUBLISH_BRANCH:-mono}
OUT="releases/$RELTAG"

[ -d "$OUT" ]                   || { echo "mono-publish: $OUT not staged - build it first" >&2; exit 1; }
[ -f releases/latest.json ]     || { echo "mono-publish: releases/latest.json missing - stage the release first" >&2; exit 1; }
[ -f "$OUT/sha256sums.sig" ]    || { echo "mono-publish: $OUT/sha256sums.sig missing - run scripts/mono-sign-release.sh $RELTAG" >&2; exit 1; }
[ -f releases/latest.json.sig ] || { echo "mono-publish: releases/latest.json.sig missing - run scripts/mono-sign-release.sh $RELTAG" >&2; exit 1; }

# Verify the signatures actually VALIDATE against the keys the fleet bakes into
# every image - not merely that a .sig file exists. A wrong or rotated signing
# key, or a stale latest.json.sig left from a prior release, yields a
# valid-looking file that every device would reject; catch it here, before it
# ships, instead of freezing the fleet. Accept if ANY baked key verifies (the
# rotation key is trusted alongside the release key).
USIGN=${MONO_USIGN:-staging_dir/host/bin/usign}
[ -x "$USIGN" ] || command -v "$USIGN" >/dev/null 2>&1 || {
	echo "mono-publish: usign not found ($USIGN); set MONO_USIGN" >&2; exit 1; }
KEYS="scripts/release-keys/mono-release.pub scripts/release-keys/mono-rotation.pub"
verify() {  # <message> <sig>: true if any baked key validates it
	for k in $KEYS; do
		[ -f "$k" ] || continue
		"$USIGN" -V -q -m "$1" -x "$2" -p "$k" 2>/dev/null && return 0
	done
	return 1
}
verify "$OUT/sha256sums"    "$OUT/sha256sums.sig"    || {
	echo "mono-publish: $OUT/sha256sums.sig fails to verify against the fleet's baked keys (wrong signing key?) - refusing" >&2; exit 1; }
verify releases/latest.json releases/latest.json.sig || {
	echo "mono-publish: releases/latest.json.sig fails to verify (wrong key or stale sig?) - refusing" >&2; exit 1; }

# latest.json must describe THIS release (guards against a stale manifest from
# a later staging run being shipped with an older release's signature).
json_tag=$(sed -n 's/.*"tag": *"\([^"]*\)".*/\1/p' releases/latest.json | head -1)
[ "$json_tag" = "$RELTAG" ] || {
	echo "mono-publish: latest.json tag '$json_tag' != $RELTAG - refusing" >&2; exit 1; }

if [ -n "${MONO_PUBLISH_DEST:-}" ]; then
	echo "mono-publish: publishing to $MONO_PUBLISH_DEST"
	# Two-phase publish so the live manifest never points at images that have
	# not landed yet: rsync the release dir to COMPLETION first, then flip
	# latest.json(+.sig) in a separate step. rsync renames each file into
	# place atomically, so the manifest swap itself is atomic too.
	# --no-owner/--no-group/--chmod: land a deterministic 755/644 owned by
	# whoever we publish as, instead of preserving the build tree's uid (1000)
	# and group-write umask (which left orphaned 775/664 dirs on the server).
	# Don't serve patches/ (git format-patch output): it's redundant with the forge
	# (branch + tag on GitHub) and nothing references it (not in sha256sums, latest.json,
	# or the gh release), so exclude it from the published dir.
	rsync -a --no-owner --no-group --chmod=D755,F644 --exclude=patches "$OUT" "$MONO_PUBLISH_DEST/"
	rsync -a --no-owner --no-group --chmod=D755,F644 releases/latest.json releases/latest.json.sig "$MONO_PUBLISH_DEST/"
else
	echo "mono-publish: MONO_PUBLISH_DEST unset, nothing rsynced" >&2
fi

# Push the rebased branch and release tag when a 'mono' remote is configured
# (machine-local in .git/config; nothing committed here).
if git remote get-url mono >/dev/null 2>&1; then
	echo "mono-publish: pushing $BRANCH and $RELTAG"
	git push --force-with-lease mono "$BRANCH"
	git push -f mono "$RELTAG"

	# Mirror the release on the forge with the flashables + signed manifest
	# attached. Repo derived from the remote URL; failure is reported, not fatal.
	if command -v gh >/dev/null 2>&1; then
		REPO=$(git remote get-url mono | sed -E 's#(git@[^:]+:|https://[^/]+/)##; s#\.git$##')
		# Release body: use the notes drafted for this release
		# (releases/<tag>/RELEASE_NOTES.md) if present, else a boilerplate
		# fallback. This body becomes the GitHub release description AND is what
		# the Discord announcement workflow (.github/workflows/discord-release.yml)
		# posts, so fill it in at stage time to control both.
		NOTES_FILE="$OUT/RELEASE_NOTES.md"
		if [ ! -f "$NOTES_FILE" ]; then
			NOTES_FILE=$(mktemp)
			echo "Automated release: $RELTAG." > "$NOTES_FILE"
		fi
		gh release create "$RELTAG" --repo "$REPO" \
			--title "$RELTAG" \
			--notes-file "$NOTES_FILE" \
			"$OUT"/*-sysupgrade*.bin "$OUT"/*-emmc.img.gz \
			"$OUT/sha256sums" "$OUT/sha256sums.sig" \
			releases/latest.json releases/latest.json.sig \
			|| echo "mono-publish: WARNING: GitHub release failed" >&2
	fi
fi

echo "mono-publish: published $RELTAG"
