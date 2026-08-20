# Mono Gateway — OTA / Attended-Sysupgrade (ASU) Deployment

How a Mono Gateway image is cut, published, and delivered over-the-air, and how the
self-hosted Attended-Sysupgrade server that powers `owut` / LuCI one-click upgrades is
built and wired together.

> Scope: the `mono_gateway-dk` product (NXP LS1046A, target `layerscape/armv8_64b`).
> Everything here is current as of the **r10** cutover to ASU.

---

## 1. The big picture

There are **two delivery channels**, both published from one release build:

| Channel | URL | Client | Purpose |
|---|---|---|---|
| **Attended Sysupgrade (ASU)** | `https://sysupgrade.mono.si` | `owut` (CLI) + `luci-app-attendedsysupgrade` | The primary path from **r10 on**. The server rebuilds an image carrying the device's exact package set and hands it back. |
| **Legacy release feed** | `https://openwrt.mono.si` | the retired `mono-update` client on **r9 and older** | Kept alive so pre-r10 devices can still discover + install r10 (a `latest.json` manifest + signed images). Retire once the fleet is on r10. |

```
   build host (this workstation)                      groot (45.137.48.13)
   ┌──────────────────────────┐                       ┌──────────────────────────────────────────┐
   │ mono/openwrt @ branch     │  rsync + ssh          │ nginx (sysupgrade.mono.si, openwrt.mono.si)│
   │  scripts/mono-update.sh   │──────────────────────▶│  /srv/asu-feed   (mono package feed)        │
   │   → build world + IB      │  git push + gh release│  /srv/openwrt    (legacy release channel)   │
   │   → sign → publish        │──────▶ github         │  asu (rootless podman): server/worker/redis │
   │   → ASU refresh (verify)  │                       │   + upstream nginx + local registry + IB   │
   └──────────────────────────┘                       └──────────────────────────────────────────┘
                                                                        ▲  owut / LuCI
                                                                        │  https
                                                              ┌──────────────────┐
                                                              │ Mono Gateway (r10)│
                                                              │ owut → sysupgrade │
                                                              └──────────────────┘
```

---

## 2. Hosts, users, access

**groot** — `45.137.48.13`, Debian 13, on the tailnet. Replaced the old `rocket` box.

| User | Role | SSH from build host |
|---|---|---|
| `root` | infra / feed publish (`/srv/*`), drives the `asu` stack | key ✅ |
| `asu` | runs the ASU stack (uid **987**, rootless podman, `loginctl enable-linger`) | no direct key — reach via `root` → `su - asu -c '…'` |
| `mono` | publish user for the legacy channel (`/srv/openwrt`) | key ✅ |
| `tzaman` | admin (in `sudo`, **password required**) | key ✅ |

The **build host** additionally holds: the usign signing key (`~/Mono/Gateway/openwrt/mono-release.sec`), GitHub push rights to `git@github.com:we-are-mono/openwrt.git`, and `gh` auth.

Reference clone of the ASU server source: **`~/Mono/Gateway/asu`** (github.com/openwrt/asu). Read the
*image's own* source when in doubt — the published `docker.io/openwrt/asu:latest` drifts from `main`.

---

## 3. The release / cut pipeline  (`scripts/mono-update.sh`, on the `mono` branch)

Releases are cut **only from the `mono` branch** (the script refuses otherwise). Feature work
lives on other branches (`mono-docker`, …) and must land on `mono` first.

Run it (on the build host) with the infra env sourced:

```sh
cd ~/Mono/Gateway/openwrt/source
set -a; . ~/Mono/Gateway/openwrt/mono-nightly.env; set +a   # MONO_SIGN_KEY, MONO_PUBLISH_DEST=mono@groot, MONO_PUBLISH_URL
scripts/mono-update.sh
```

Steps, in order:

1. **Guards** — on `mono`, clean tree, `scripts/check-ask-patch-sync.sh` (ASK patch copies match their pins).
2. **Numbering** — `RN = (highest existing mono-vX.Y.Z-rN) + 1`; `RELTAG = mono-vX.Y.Z-rN`.
3. **Rebase** onto the newest upstream stable tag (no-op within a minor series).
4. **Tag** `RELTAG` (dropped again by the EXIT trap on any later failure → next run retries the same rN).
5. **Stamp** the revision (see §4) — writes a `version` file + appends `CONFIG_VERSION_CODE` to `.config`.
6. **Build** inside the pinned nix FHS (`nix run . -- -c '…'`): `make defconfig && make world && make target/imagebuilder/clean && make target/imagebuilder/install`.
7. **Stage** `releases/<tag>/` — images, `kmods/`, `patches/`, and `latest.json` (legacy manifest).
8. **Publish** (only when `MONO_SIGN_KEY` is set):
   - `mono-sign-release.sh` — usign-signs `sha256sums` + `latest.json`.
   - `mono-publish-release.sh` — rsync `releases/<tag>/` + `latest.json` to `mono@groot:/srv/openwrt`, then `git push --force-with-lease mono` + `git push -f` the tag + a `gh release`.
   - **`publish-asu-feed.sh`** — refresh the ASU server **and verify it (fail-closed)**; see §6.
9. **EXIT trap** — on any nonzero exit: drop the tag + `git checkout -- version` (the version file is tracked; see §4).

A release is **not "done"** unless the ASU verify passes — so the ASU server can never silently
drift from the published release (that guarantee is the whole point of folding the refresh into the cut).

---

## 4. The release number & revision stamp  (why `r50010`)

`owut` decides "is there a newer build?" by parsing two `rNNNNN-hash` version strings and comparing
the numeric part (`parse_rev_code = /^r(\d+)-([[:xdigit:]]+)$/`):

- **`%R` — `REVISION`** → the device's `/etc/openwrt_release` `DISTRIB_REVISION` = owut's **"from"**.
  Set via a **`version`** file at the tree root (`scripts/getver.sh` reads it *first*, before git).
- **`%C` — `VERSION_CODE`** → the server/IB `version_code` (in `profiles.json`) = owut's **"to"**.
  Set via **`CONFIG_VERSION_CODE`** (independent of `%R`; `version.mk` falls back to a hardcoded
  constant, never to `%R`, so both must be set).

**The release number is 50000-based**, so the **git tag and the `version_code` are the same number** —
`mono-v25.12.5-r50010` and `r50010-<hash>`. One number everywhere; nothing to reconcile.

- The **`50000` base** clears the **pre-stamp getver constant `r33051-f5dae5ece4`** that *every* old
  build reports. A bare counter (r10 → rev-num 10) would parse *below* 33051 and owut would call the
  release a **`DOWNGRADE`** — no pre-stamp device (the r9 fleet) would take the upgrade. 50000 gives
  ~17k of headroom over the current OpenWrt revision.
- The numbering bridges the legacy `r1..r9` tags into the base once (r9 → `r50010`), then just
  increments (`r50010 → r50011 → …`), staying monotonic. The stamp keeps getver's `rNNNNN-hash` shape.

Gotchas:
- `CONFIG_VERSION_CODE` is dropped by `make defconfig` **unless** the seed enables the
  `IMAGEOPT → VERSIONOPT` gate (it does). That gate defaults `VERSION_FILENAMES=y` (renames the
  artifacts) — the seed forces it **off**.
- **`version` is a TRACKED upstream file** (holds `r33051-…`). The cut overwrites it for the build,
  and the EXIT trap **restores** it (`git checkout -- version`) — a bare `rm` would dirty the tree and
  break the next run's clean-check.

**Re-cutting the same number** (to fold a fix into an unshipped release): delete the local tag
(`git tag -d mono-v25.12.5-r50010` → the number recomputes), then re-run the cut; the publish
force-updates the remote tag + gh release. Safe as long as no device has taken that release yet.

---

## 5. The ASU server on groot  (aparcar/asu, rootless podman as `asu`)

Deploy dir **`/home/asu/asu-deploy/`** — `podman-compose.yml`, `asu.env`, `asu.toml`.
Drive podman as `asu`: `ssh root@groot "su - asu -c 'export XDG_RUNTIME_DIR=/run/user/987; podman …'"`.

Containers (`podman ps`):

| Container | Image | Role |
|---|---|---|
| `asu-deploy_server_1` | `docker.io/openwrt/asu:latest` | FastAPI (`uv run uvicorn asu.main:app`), listens **127.0.0.1:8000** |
| `asu-deploy_worker_1` | `docker.io/openwrt/asu:latest` | `rq` worker — runs the ImageBuilder in a per-build container on the `asu-build` network |
| `asu-deploy_redis_1` | `redis/redis-stack-server` | job queue + result/metadata cache |
| `asu-deploy_upstream_1` | `nginx:alpine` | serves `/srv/asu-feed` **internally** as `http://upstream` (joined to both compose + `asu-build` nets, alias `upstream`) |
| `registry` | `registry:2` (TLS) | local image registry `localhost:5000` holding the IB container |

`asu.env` essentials: `upstream_url = http://upstream` (see §7 for why this is internal-only),
`BASE_CONTAINER = localhost:5000/imagebuilder`, `PUBLIC_PATH = /home/asu/public/`, `REDIS_URL`.
`asu.toml`: `[branches."25.12"] path = "releases/{version}"` (mono reports plain `VERSION_NUMBER=25.12.5`).

**Build cache / store:** `/home/asu/public/store/<request_hash>/` — cached built images. Redis caches
job/metadata. Both are flushed on every feed refresh (see §6) so a repeated request can't be served a
stale image.

### The ImageBuilder container  (`/home/asu/mono-ib-build/`)

`build-ib-container.sh` wraps the mono IB tarball into an asu-compatible container:
- Derives `TGT` + `VER` from the tarball's `repositories`, tags it **`localhost:5000/imagebuilder:<target>-v<VERSION_NUMBER>`** (e.g. `layerscape-armv8_64b-v25.12.5`) — asu looks the IB up by that exact tag.
- `Containerfile`: Debian **trixie** base (glibc ≥ the nix-FHS host tools), user `buildbot`, IB unpacked at `/builder`; rewrites the IB's `repositories` `downloads.openwrt.org → http://upstream` **and appends the stock userspace feeds** (base/luci/packages/routing/telephony) pointing at `downloads.openwrt.org`, so a build resolves **mono packages internally + any of the ~9000 stock packages from upstream**. No stock *kmod* feed (wrong vermagic).

The IB tag is keyed by `VERSION_NUMBER` (25.12.5), **not** the revision — so a re-cut with a new
`version_code` overwrites the same tag. `make target/imagebuilder/install` must be preceded by
`make target/imagebuilder/clean` (it reuses a stale build_dir `.config` otherwise).

### The front nginx  (`/etc/nginx/sites-available/sysupgrade.mono.si`)

Public HTTPS (LE cert) in front of the asu app:

```nginx
# CORS — luci-app-attendedsysupgrade is a BROWSER client; its cross-origin API call
# hangs the "Searching" modal without these (§7.4). owut (router-side) is unaffected.
add_header Access-Control-Allow-Origin  "*" always;            # `always` so it rides the 301
add_header Access-Control-Allow-Methods "POST, GET, OPTIONS" always;
add_header Access-Control-Allow-Headers  "*" always;
add_header Access-Control-Expose-Headers "Authorization" always;
if ($request_method = OPTIONS) { return 204; }                 # preflight for POST /api/v1/build

location /store/    { alias /home/asu/public/store/; }         # built images (uvicorn does NOT serve these)
location /releases/ { root  /srv/asu-feed; }                    # the mono package feed, served PUBLICLY (§7)
location = /json/v1/overview.json {                             # rewrite the internal feed host for clients (§7)
    proxy_pass http://127.0.0.1:8000;
    proxy_set_header Accept-Encoding "";
    sub_filter_types application/json; sub_filter_once off;
    sub_filter "http://upstream" "https://sysupgrade.mono.si";
}
location /          { proxy_pass http://127.0.0.1:8000; }        # the asu API + /json
```

> These nginx edits and `openwrt.mono.si`'s vhost are **groot-local, not in git**. Recreate on a
> groot rebuild. Backups: `*.bak-*` next to the config.

---

## 6. The ASU feed & its refresh  (`scripts/publish-asu-feed.sh`)

The feed lives at **`/srv/asu-feed/releases/<VER>/`** and is the union the ASU server resolves against:

```
releases/25.12.5/
├── packages/aarch64_generic/
│   ├── feeds.conf                         ← REQUIRED (§7.2); lists base/luci/packages/routing/telephony/video
│   └── {base,luci,packages,…}/index.json  ← per-feed v2 index (mono-built packages)
└── targets/layerscape/armv8_64b/
    ├── profiles.json                      ← carries version_code (the revision endpoint reads this)
    ├── index.json                         ← target/kmod package index
    └── packages/*.apk                     ← target + kmod .apks
```

`publish-asu-feed.sh` is the **complete** refresh (run by the cut, fail-closed). It, in one shot:

1. rsyncs the **IB tarball** to `/home/asu/mono-ib-build/` and rebuilds the IB container (`build-ib-container.sh`).
2. rsyncs the **package feed** + the **`profiles.json`** + writes the **`feeds.conf`**.
3. flushes the asu build cache (`redis FLUSHALL` + `rm -rf public/store/*`).
4. **verifies** `GET /api/v1/revision/<VER>/<target>` returns the exact `version_code` just built —
   mismatch → `exit 1` → the cut's trap drops the tag. (Env overrides: `GROOT`, `ASU_URL`.)

Everything shipped comes from the *same* build, so the IB, the feed indexes, and `profiles.json` can
never drift from each other.

---

## 7. Client (owut) resolution — and the three fixes that made it work

owut's path when you run `owut check` / click "Search" in LuCI:

1. Read `uci get attendedsysupgrade.server.url` (baked to `https://sysupgrade.mono.si` by the
   `mono-asu-config` package's `52-mono-asu-server`).
2. `GET /api/v1/overview` → read **`upstream_url`**.
3. `GET <upstream_url>/releases/<VER>/targets/<t>/<st>/profiles.json` — the target's default packages + `version_code`.
4. `GET <server>/json/v1/…/<arch>-index.json` and `…/targets/<t>/index.json` — the package indexes (the
   server builds these by parsing `upstream_url`'s feeds via `feeds.conf`, per `asu/util.py`).
5. Compare device `%R` vs target `%C`, resolve every installed package to a "to-version".
6. If newer + resolvable → `POST /api/v1/build` → server builds via the IB → owut downloads from
   `/store/<hash>/…` + `sysupgrade`.

Four deployment bugs; all are fixed (7.1–7.3 broke **every** device; 7.4 broke only the LuCI/browser path — `owut` was fine):

### 7.1 `upstream_url` was internal → "Searching" spun forever
`asu.env` set `upstream_url = http://upstream` (the server's *internal* container host). owut read that
from the overview and tried to fetch `profiles.json` from an unresolvable URL. Rootless podman **cannot
hairpin** to groot's own public IP, so we do **not** flip `upstream_url`. Instead the front nginx (a)
serves the feed publicly at `/releases/` and (b) `sub_filter`s **only the overview response**
`http://upstream → https://sysupgrade.mono.si`. The server keeps using `http://upstream` internally
(no hairpin, no restart).

### 7.2 Arch package index came back empty → "N packages missing to-version, cannot upgrade"
The server's `<arch>-index.json` endpoint discovers feeds by reading **`<arch>/feeds.conf`**
(`asu/util.py parse_feeds_conf`: field-2 of each line is a feed subdir name). The mono build ships the
per-feed `index.json` files but **no `feeds.conf`**, so `parse_feeds_conf` returned `[]` → 0 packages →
every arch package "missing". Fix: `publish-asu-feed.sh` writes a `feeds.conf` whose names
(`base luci packages routing telephony video`) match the served subdirs. (Arch index went 0 → 417.)

### 7.3 Stamp looked like a downgrade → §4 (50000 base).

### 7.4 LuCI "Searching" hung forever while `owut` worked → missing CORS
`luci-app-attendedsysupgrade` runs **in the browser**: `overview.js` does a client-side
`request.get(<server>/api/v1/overview)` — a **cross-origin** call from the router's LuCI
origin (e.g. `http://192.168.1.1`) to `sysupgrade.mono.si`. The front nginx sent **no CORS
headers**, so the browser blocked it; and because `/api/v1/overview` is a **301** to
`/json/v1/overview.json`, the browser refused to even follow a cross-origin redirect that
lacks CORS. The app's `L.resolveDefault(...)` then resolves to `null` and `!response.ok`
throws, so the "Searching for an available sysupgrade" modal **spins forever** instead of
erroring. `owut` (router-side CLI, no same-origin policy) was unaffected — exactly why the
CLI worked but the LuCI button hung. Fix: the front nginx now sends the same CORS headers
upstream `sysupgrade.openwrt.org` sends — `Access-Control-Allow-Origin: *`, `-Methods POST,
GET, OPTIONS`, `-Headers *`, `-Expose-Headers Authorization` — with **`always`** (so they
ride the 301) plus an `OPTIONS → 204` preflight for `POST /api/v1/build`. Verified
end-to-end in a browser. See the §5 nginx block. **groot-local, not in git** — recreate on
a groot rebuild.

---

## 8. Troubleshooting

Fast diagnostics (from anywhere):

```sh
# What does the server advertise / serve?
curl -s https://sysupgrade.mono.si/api/v1/overview | grep -o '"upstream_url":"[^"]*"'   # must be https://sysupgrade.mono.si
curl -s https://sysupgrade.mono.si/api/v1/revision/25.12.5/layerscape/armv8_64b          # must be the CURRENT version_code
curl -s "https://sysupgrade.mono.si/json/v1/releases/25.12.5/packages/aarch64_generic-index.json" \
  | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))'   # flat {name:version} dict; must be hundreds, not 0
curl -sI https://sysupgrade.mono.si/releases/25.12.5/targets/layerscape/armv8_64b/profiles.json  # 200

# On the device (the ground truth — LuCI's spinner hides the error):
owut check            # or `owut check -v`
uci get attendedsysupgrade.server.url
```

| Symptom | Likely cause | Check |
|---|---|---|
| LuCI "Searching" spins forever | wrong `server.url`, or overview advertises `http://upstream` | `uci get …server.url`; overview `upstream_url` (§7.1) |
| LuCI "Searching" spins but `owut` works | missing CORS on the front nginx (browser-only) | overview response carries `Access-Control-Allow-Origin` (§7.4) |
| `owut … DOWNGRADE` | stamp below the getver constant | revision endpoint value; §4 (50000 base) |
| `N packages missing to-version` | arch index empty | the `<arch>-index.json` count; `feeds.conf` present (§7.2) |
| `Image not found: …imagebuilder:…` on build | IB container not (re)built for this version | `build-ib-container.sh`; registry catalog |
| revision endpoint stale after a publish | `profiles.json` not refreshed / caches | re-run `publish-asu-feed.sh`; it flushes redis + store |

Server-side (as `asu`): `podman logs asu-deploy_server_1`, `podman exec asu-deploy_redis_1 redis-cli FLUSHALL`,
`podman images | grep imagebuilder`.

---

## 9. Key files

**In this repo (`mono`/openwrt):**
- `scripts/mono-update.sh` — the release/cut pipeline (stamp, build, sign, publish, ASU refresh).
- `scripts/publish-asu-feed.sh` — the complete, fail-closed ASU refresh (IB + feed + profiles.json + feeds.conf + verify).
- `scripts/mono-sign-release.sh`, `scripts/mono-publish-release.sh` — legacy-channel sign + publish.
- `configs/mono_gateway-dk.seed` — the build config (branding gate for the stamp, package selection).
- `target/linux/layerscape/image/armv8_64b.mk` — `DEVICE_PACKAGES` (what's baked; what owut preserves).
- `package/mono/asu-config/` — bakes `attendedsysupgrade.server.url = https://sysupgrade.mono.si`.
- `include/version.mk`, `scripts/getver.sh`, `version` — the `%R`/`%C` machinery.

**On groot (not in git — recreate on rebuild):**
- `/etc/nginx/sites-available/sysupgrade.mono.si` — the front nginx (`/releases/`, overview rewrite, `/store/`, `/`).
- `/home/asu/asu-deploy/` — `podman-compose.yml`, `asu.env`, `asu.toml`.
- `/home/asu/mono-ib-build/` — `Containerfile`, `build-ib-container.sh`, the IB tarball.
- `/srv/asu-feed/` — the ASU package feed. `/srv/openwrt/` — the legacy release channel.

**On the build host (infra, uncommitted):**
- `~/Mono/Gateway/openwrt/mono-nightly.env` — `MONO_SIGN_KEY`, `MONO_PUBLISH_DEST=mono@groot`, `MONO_PUBLISH_URL`.
- `~/Mono/Gateway/openwrt/mono-release.sec` — the usign signing key (guard it).
- `~/Mono/Gateway/asu/` — reference clone of the ASU server source.
