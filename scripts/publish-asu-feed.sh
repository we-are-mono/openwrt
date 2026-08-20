#!/bin/bash
# Publish the mono package feed to the self-hosted ASU server (groot), for the
# stock+mono feed the ImageBuilder resolves against. The release version is DERIVED
# from the built ImageBuilder tarball (which carries mono's VERSION_NUMBER), so a
# mono rebase to a new 25.12.x needs no edit here - just rebuild and re-run.
#
# The `upstream` nginx on groot serves /srv/asu-feed; the IB requests
# http://upstream/releases/<VER>/... so the feed must live at that versioned path.
# Run AFTER `make target/imagebuilder/install` (needs the IB tarball to derive VER).
#   ./scripts/publish-asu-feed.sh
set -e

GROOT=${GROOT:-root@45.137.48.13}
cd "$(dirname "$0")/.."   # -> source/
BIN=bin

TARBALL=$(ls "$BIN"/targets/layerscape/armv8_64b/*-imagebuilder-*.tar.zst 2>/dev/null | head -1)
[ -n "$TARBALL" ] || { echo "ERROR: no ImageBuilder tarball under $BIN/targets (run: make target/imagebuilder/install)"; exit 1; }
VER=$(tar --zstd -xOf "$TARBALL" --wildcards '*/repositories' 2>/dev/null | sed -n 's|.*/releases/\([0-9.]\+\)/.*|\1|p' | head -1)
[ -n "$VER" ] || { echo "ERROR: could not derive version from $TARBALL"; exit 1; }

DEST="$GROOT:/srv/asu-feed/releases/$VER"
echo "=== publishing mono feed (version $VER) -> $DEST ==="
# Additive (no --delete): keeps older/dropped-package apks re-installable via ASU.
rsync -a "$BIN/packages/aarch64_generic/"                "$DEST/packages/aarch64_generic/"
rsync -a "$BIN/targets/layerscape/armv8_64b/packages/"   "$DEST/targets/layerscape/armv8_64b/packages/"
echo "=== done (version $VER) ==="
