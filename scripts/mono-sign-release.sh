#!/bin/sh
# Sign a staged Mono release. Runs where the signing key lives - ideally NOT
# the build/publish host, so a compromise of that host is not also a signing
# compromise. Given a release tag it usign-signs both the per-release hash
# list and the latest.json manifest that devices verify before flashing.
#
# Requires MONO_SIGN_KEY (path to the usign secret key). usign is taken from
# the OpenWrt host tree by default; override with MONO_USIGN if signing on a
# host without a build tree.
#
# Usage: scripts/mono-sign-release.sh <mono-vX.Y.Z-rN>
set -eu

cd "$(dirname "$0")/.."
RELTAG=${1:?usage: mono-sign-release.sh <mono-vX.Y.Z-rN>}
: "${MONO_SIGN_KEY:?set MONO_SIGN_KEY to the usign secret key path}"
USIGN=${MONO_USIGN:-staging_dir/host/bin/usign}
[ -x "$USIGN" ] || command -v "$USIGN" >/dev/null 2>&1 || {
	echo "mono-sign: usign not found ($USIGN); set MONO_USIGN" >&2; exit 1; }

OUT="releases/$RELTAG"
[ -f "$OUT/sha256sums" ]     || { echo "mono-sign: $OUT/sha256sums not found - stage the release first" >&2; exit 1; }
[ -f releases/latest.json ]  || { echo "mono-sign: releases/latest.json not found - stage the release first" >&2; exit 1; }

# The manifest must actually describe this release, or we'd sign a stale one.
json_tag=$(sed -n 's/.*"tag": *"\([^"]*\)".*/\1/p' releases/latest.json | head -1)
[ "$json_tag" = "$RELTAG" ] || {
	echo "mono-sign: latest.json tag '$json_tag' != $RELTAG - stale manifest, refusing" >&2; exit 1; }

"$USIGN" -S -m "$OUT/sha256sums"    -s "$MONO_SIGN_KEY" -x "$OUT/sha256sums.sig"
"$USIGN" -S -m releases/latest.json -s "$MONO_SIGN_KEY" -x releases/latest.json.sig
echo "mono-sign: signed $RELTAG (sha256sums + latest.json)"
