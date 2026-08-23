#!/usr/bin/env python3
"""Emit the release latest.json manifest that devices poll to self-update.

Reads this build's profiles.json (image metadata) plus the staged release dir,
and writes one JSON object to stdout:

    {"format_version": 1, "tag": <reltag>, "date": <iso8601>,
     "devices": {<board>: {"sysupgrade": <url>, "sha256": <hex>}}}

Per board, "sysupgrade"/"sha256" point at the gzip sysupgrade image - the only
format built. (Pre-gzip devices once needed an uncompressed -legacy image
advertised under a separate key; that image is retired, so the manifest is
gz-only. A device that predates gzip support is past support by definition.)

Image names in profiles.json carry the build prefix (mono-<epoch>-<sha>-...);
mono-update.sh stages them under stripped names (layerscape-armv8_64b-...), so
we match on the metadata suffix but resolve existence + the published URL
against the stripped name - never trusting filename surgery to find an image.

Usage: mono-latest-json.py <reltag> <urlbase> <out-dir> <profiles.json>
"""
import json, sys, os, re, hashlib, datetime

reltag, urlbase, out, profiles = sys.argv[1:5]
prof = json.load(open(profiles)).get("profiles", {})


def pick(p, suffix):
    """Name of p's image ending in suffix, as staged on disk, or None.

    profiles.json holds the build-name; mono-update.sh staged the file under
    its prefix-stripped name, so map to that form and confirm it exists.
    """
    for im in p.get("images", []):
        name = im.get("name", "")
        if not name.endswith(suffix):
            continue
        staged = re.sub(r"^.*(layerscape-armv8_64b-)", r"\1", name)
        if os.path.exists(os.path.join(out, staged)):
            return staged
    return None


def sha(img):
    return hashlib.sha256(open(os.path.join(out, img), "rb").read()).hexdigest()


devices = {}
for name, p in prof.items():
    boards = p.get("supported_devices") or []
    img = pick(p, "sysupgrade.bin")
    if not boards or not img:
        continue
    devices[boards[0]] = {"sysupgrade": f"{urlbase}/{reltag}/{img}",
                          "sha256": sha(img)}

# format_version lets the client reject a manifest shape it doesn't understand.
json.dump({"format_version": 1,
           "tag": reltag,
           "date": datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "devices": devices}, sys.stdout, indent=2)
sys.stdout.write("\n")
