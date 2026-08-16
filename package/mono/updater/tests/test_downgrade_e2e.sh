#!/bin/bash
# End-to-end regression test for the signed-manifest update path. Uses real
# usign signatures to prove the client:
#   - on --install, flashes a genuine, newer, release-signed release;
#   - REFUSES a forged high tag signed by an untrusted key;
#   - REFUSES a replayed genuine-but-older release (anti-rollback floor);
#   - REFUSES a post-rollback walk-up (durable floor survives current reset);
#   - REFUSES a tampered image (hash mismatch under a genuine manifest);
#   - on --check, reports availability WITHOUT emitting an unverified
#     'sysupgrade <url>' and WITHOUT flashing.
# Plus a static packaging-consistency check for the anti-rollback floor file.
#
# Requires a built host usign (staging_dir/host/bin/usign) and python3; skips
# cleanly if usign has not been built yet. Run from anywhere.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../../.." && pwd)         # .../source
PKG="$REPO/package/mono/updater"
CLIENT="$PKG/files/mono-update"
USIGN="$REPO/staging_dir/host/bin/usign"
fails=0

echo "== packaging consistency (anti-rollback floor survives sysupgrade) =="
# The floor's durability rests on three files agreeing on one path. A refactor
# that changes one and not the others silently destroys anti-rollback.
FLOOR_PATH=$(sed -n 's/^FLOORFILE=//p' "$CLIENT" | head -1)
if [ "$FLOOR_PATH" = "/etc/mono-update.state" ]; then echo "ok   client FLOORFILE=$FLOOR_PATH"
else echo "FAIL client FLOORFILE='$FLOOR_PATH' != /etc/mono-update.state"; fails=$((fails+1)); fi
if grep -q '^/etc/mono-update.state$' "$PKG/files/mono-update.keep"; then echo "ok   keep.d lists the floor file"
else echo "FAIL keep.d does not list /etc/mono-update.state"; fails=$((fails+1)); fi
if grep -q 'keep.d/mono-update' "$PKG/Makefile"; then echo "ok   Makefile installs the keep.d entry"
else echo "FAIL Makefile does not install keep.d/mono-update"; fails=$((fails+1)); fi

[ -x "$USIGN" ] || { echo "SKIP e2e: host usign not built ($USIGN)"; [ "$fails" -eq 0 ] && exit 0 || exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP e2e: python3 not available"; [ "$fails" -eq 0 ] && exit 0 || exit 1; }

S=$(mktemp -d)
trap 'rm -rf "$S"' EXIT
mkdir -p "$S"/bin "$S"/etc/mono-keys "$S"/lib "$S"/tmp "$S"/srv
SRV="$S/srv"

"$USIGN" -G -s "$S/release.sec"  -p "$S/release.pub"  -c release  >/dev/null
"$USIGN" -G -s "$S/attacker.sec" -p "$S/attacker.pub" -c attacker >/dev/null
cp "$S/release.pub" "$S/etc/mono-keys/mono-release.pub"

cat > "$S/lib/functions.sh" <<'EOF'
board_name() { echo "mono,gateway-dk"; }
EOF
cat > "$S/bin/uci" <<EOF
#!/bin/sh
case "\$*" in
  *check.url*)  echo "\${UCI_URL:-file://$SRV}";;
  *check.mode*) echo "\${UCI_MODE:-auto}";;
esac
EOF
printf '#!/bin/sh\nexit 0\n' > "$S/bin/logger"
cat > "$S/bin/sysupgrade" <<EOF
#!/bin/sh
sha256sum "\$1" | cut -d' ' -f1 > "$S/FLASHED"
echo "SYSUPGRADE \$1"
EOF
cat > "$S/bin/jsonfilter" <<'EOF'
#!/usr/bin/env python3
import sys, json, re
expr = sys.argv[sys.argv.index("-e")+1]
data = json.load(sys.stdin)
m = re.match(r"@\.devices\['([^']+)'\]\.(\w+)$", expr)
v = (data.get("devices", {}).get(m.group(1), {}).get(m.group(2), "")
     if m else data.get(expr[2:], ""))
if v not in ("", None):
    print(v)
EOF
ln -s "$USIGN" "$S/bin/usign"
chmod +x "$S"/bin/* 2>/dev/null

sed -e "s|/lib/functions.sh|$S/lib/functions.sh|" \
    -e "s|/etc/mono_release|$S/etc/mono_release|" \
    -e "s|KEYDIR=/etc/mono-keys|KEYDIR=$S/etc/mono-keys|" \
    -e "s|FLOORFILE=/etc/mono-update.state|FLOORFILE=$S/etc/mono-update.state|" \
    -e "s|/tmp/mono-update|$S/tmp/mono-update|g" \
    "$CLIENT" > "$S/client.sh"

mkdir -p "$SRV/r3" "$SRV/r4" "$SRV/r5"
printf 'IMAGE-R3' > "$SRV/r3/img-sysupgrade.bin"
printf 'IMAGE-R4' > "$SRV/r4/img-sysupgrade.bin"
printf 'IMAGE-R5' > "$SRV/r5/img-sysupgrade.bin"
h() { sha256sum "$1" | cut -d' ' -f1; }
make_manifest() {  # out tag dir imghash
	cat > "$1" <<EOF
{ "format_version": 1, "tag": "$2", "date": "2026-01-01T00:00:00Z",
  "devices": { "mono,gateway-dk": {
    "sysupgrade": "file://$SRV/$3/img-sysupgrade.bin", "sha256": "$4" } } }
EOF
}
make_manifest "$S/m_r5.json"  mono-v25.12.5-r5 r5 "$(h "$SRV/r5/img-sysupgrade.bin")"
make_manifest "$S/m_r4.json"  mono-v25.12.5-r4 r4 "$(h "$SRV/r4/img-sysupgrade.bin")"
make_manifest "$S/m_r3.json"  mono-v25.12.5-r3 r3 "$(h "$SRV/r3/img-sysupgrade.bin")"
make_manifest "$S/m_bad.json" mono-v99.99.99   r3 "$(h "$SRV/r3/img-sysupgrade.bin")"
for m in r5 r4 r3; do "$USIGN" -S -m "$S/m_$m.json" -s "$S/release.sec"  -x "$S/m_$m.json.sig"; done
"$USIGN" -S -m "$S/m_bad.json" -s "$S/attacker.sec" -x "$S/m_bad.json.sig"

publish() { cp "$S/$1" "$SRV/latest.json"; cp "$S/$1.sig" "$SRV/latest.json.sig"; }
run() {  # current floor action(--check|--install) -> sets $out, $got(flash|refuse)
	echo "$1" > "$S/etc/mono_release"
	rm -f "$S/FLASHED" "$S/etc/mono-update.state"
	[ -n "$2" ] && printf '%s\n' "$2" > "$S/etc/mono-update.state"
	out=$(cd "$S" && PATH="$S/bin:$PATH" sh "$S/client.sh" "$3" 2>&1)
	[ -f "$S/FLASHED" ] && got=flash || got=refuse
}
scenario() {  # name expect current floor reason  manifest
	publish "$6"; run "$3" "$4" --install
	if [ "$got" != "$2" ] || ! echo "$out" | grep -q "$5"; then
		echo "FAIL [$1] got=$got want=$2 reason=/$5/"; echo "  $out"; fails=$((fails+1))
	else echo "ok   [$1] $got ($5)"; fi
}

echo "== end-to-end (real usign) =="
scenario genuine-upgrade      flash  mono-v25.12.5-r3 ""                       SYSUPGRADE             m_r5.json
scenario forged-tag-bad-key   refuse mono-v25.12.5-r3 ""                       "signature FAILED"     m_bad.json
scenario replay-old-signed    refuse mono-v25.12.5-r5 "floor=mono-v25.12.5-r5" "older than floor" m_r3.json
scenario floor-walk-up        refuse mono-v25.12.5-r3 "floor=mono-v25.12.5-r5" "older than floor" m_r4.json

# image tamper: genuine signed r5 manifest, but the served bytes are swapped
publish m_r5.json
printf 'TAMPERED' > "$SRV/r5/img-sysupgrade.bin"
run mono-v25.12.5-r3 "" --install
if [ "$got" = refuse ] && echo "$out" | grep -q "hash mismatch"; then echo "ok   [image-tamper] refuse (hash mismatch)"
else echo "FAIL [image-tamper] got=$got: $out"; fails=$((fails+1)); fi
printf 'IMAGE-R5' > "$SRV/r5/img-sysupgrade.bin"   # restore

# --check: a genuine newer release must NOT flash and must NOT print a raw
# 'sysupgrade <url>' (which would skip verification).
publish m_r5.json
run mono-v25.12.5-r3 "" --check
if [ "$got" = refuse ] && ! echo "$out" | grep -q "file://" && echo "$out" | grep -q -- "--install"; then
	echo "ok   [check-no-raw-flash] refuse, steers to --install"
else echo "FAIL [check-no-raw-flash] got=$got: $out"; fails=$((fails+1)); fi

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
