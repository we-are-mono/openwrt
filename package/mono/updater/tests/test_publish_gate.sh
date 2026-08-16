#!/bin/bash
# Regression test for the publish gate: mono-publish-release.sh must refuse
# unless the signatures VALIDATE against the fleet's baked public keys - not
# merely exist. Guards against a wrong/rotated signing key or a stale
# latest.json.sig silently shipping a release every device would reject.
#
# Requires a built host usign; skips cleanly otherwise. Run from anywhere.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../../.." && pwd)
USIGN="$REPO/staging_dir/host/bin/usign"
[ -x "$USIGN" ] || { echo "SKIP: host usign not built ($USIGN)"; exit 0; }
fails=0

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts" "$T/package/mono/updater/files" "$T/releases/mono-v25.12.5-r7"
cp "$REPO/scripts/mono-sign-release.sh" "$REPO/scripts/mono-publish-release.sh" "$T/scripts/"

# fleet keys (what devices bake) and an unrelated "wrong" key
"$USIGN" -G -s "$T/fleet.sec" -p "$T/package/mono/updater/files/mono-release.pub" -c fleet >/dev/null
"$USIGN" -G -s "$T/rot.sec"   -p "$T/package/mono/updater/files/mono-rotation.pub" -c rot >/dev/null
"$USIGN" -G -s "$T/wrong.sec" -p "$T/wrong.pub" -c wrong >/dev/null

printf 'deadbeef  img-sysupgrade.bin\n' > "$T/releases/mono-v25.12.5-r7/sha256sums"
manifest() { cat > "$T/releases/latest.json" <<EOF
{ "format_version": 1, "tag": "mono-v25.12.5-r7", "date": "2026-01-01T00:00:00Z",
  "devices": { "mono,gateway-dk": { "sysupgrade": "https://x/i.bin", "sha256": "deadbeef" } } }
EOF
}
sign()    { "$USIGN" -S -m "$T/releases/mono-v25.12.5-r7/sha256sums" -s "$1" -x "$T/releases/mono-v25.12.5-r7/sha256sums.sig"
            "$USIGN" -S -m "$T/releases/latest.json" -s "$1" -x "$T/releases/latest.json.sig"; }
publish() { ( cd "$T" && MONO_USIGN="$USIGN" sh scripts/mono-publish-release.sh mono-v25.12.5-r7 ) >/dev/null 2>&1; }
ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1"; fails=$((fails+1)); }

# 1. signed with the fleet release key -> verifies -> publishes (no dest, exits 0)
manifest; sign "$T/fleet.sec"
publish && ok "fleet-key signed release publishes" || bad "fleet-key signed release publishes"

# 2. signed with the rotation key (also baked) -> accepted
manifest; sign "$T/rot.sec"
publish && ok "rotation-key signed release publishes" || bad "rotation-key signed release publishes"

# 3. signed with a WRONG key -> valid-looking .sig, must REFUSE (F1)
manifest; sign "$T/wrong.sec"
publish && bad "wrong-key release REFUSED" || ok "wrong-key release REFUSED"

# 4. stale/mismatched latest.json.sig: sign, then mutate latest.json bytes (F2)
manifest; sign "$T/fleet.sec"
sed -i 's/2026-01-01/2026-02-02/' "$T/releases/latest.json"   # sig no longer matches content
publish && bad "mismatched latest.json.sig REFUSED" || ok "mismatched latest.json.sig REFUSED"

# 5. missing signature -> refuse
manifest; sign "$T/fleet.sec"; rm -f "$T/releases/latest.json.sig"
publish && bad "missing signature REFUSED" || ok "missing signature REFUSED"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
