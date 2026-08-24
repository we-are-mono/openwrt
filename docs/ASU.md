# Mono Gateway — OTA / Attended-Sysupgrade (ASU) Deployment

How a Mono Gateway image is cut, published, and delivered over-the-air, and how the
self-hosted Attended-Sysupgrade server that powers `owut` / LuCI one-click upgrades is
built and wired together.

> Scope: the `mono_gateway-dk` product (NXP LS1046A, target `layerscape/armv8_64b`).
> Release scheme + branch model: see [versioning.md](versioning.md). Kernel/ASK integration:
> see [ask-kernel-integration.md](ask-kernel-integration.md).
>
> Hosting is described by **role** ("the ASU host"), never by machine name or IP — those change
> when servers move. Commands use `$HOST` for the ASU host (e.g. `HOST=root@your-asu-host`).

---

## 1. The big picture

There are **two delivery paths**, both published from one release build:

| Path | Client | Purpose |
|---|---|---|
| **Attended Sysupgrade (ASU)** — `sysupgrade.mono.si` | `owut` (CLI) + `luci-app-attendedsysupgrade` | The primary path from **r10 on**. The server rebuilds an image carrying the device's exact package set and hands it back. |
| **Legacy release feed** — `openwrt.mono.si` | the retired `mono-update` client on **r9 and older** | Kept alive only so pre-r11 devices can still discover + install a first ASU-capable image (a `latest.json` manifest + signed images). Retire once no pre-r11 device remains. |

```
   build host (this workstation)                      the ASU host
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
                                                              │   Mono Gateway    │
                                                              │ owut → sysupgrade │
                                                              └──────────────────┘
```

### Version channels — release-branch, owut-driven (CORRECTED 2026-08-24)

> The earlier "rolling `-SNAPSHOT` channel" model below the fold did not survive contact
> with owut. **owut deliberately skips any version string containing `-SNAPSHOT`** when it
> builds its list of upgrade targets (efahl/owut: `if index(version, "-SNAPSHOT") >= 0
> continue`). A device baked as `25.12-SNAPSHOT` therefore gets *"version-to `25.12-SNAPSHOT`
> is not available"* and can only be moved by a manual `sysupgrade` — the whole fleet was
> un-upgradeable via owut. Only a **concrete release version** (`25.12.5`) is owut-upgradeable.

ASU serves one **version channel** per OpenWrt line, keyed by the image's baked
`version_number`, which **must be a concrete base version** (e.g. `25.12.5`), never a
`-SNAPSHOT` label. The model:

- **`version_number` is stamped to the upstream base** — the newest `v25.12.x` tag merged
  into `mono`, minus the `v` (so `25.12.5`). `mono-update.sh` appends `CONFIG_VERSION_NUMBER`
  + `CONFIG_VERSION_REPO=…/releases/<base>` right where it stamps `VERSION_CODE` (§4), from
  the `$LATEST` tag it already computes. It **auto-follows the series** (when `v25.12.6`
  merges, the stamp follows — no seed edits) and survives `make defconfig` via the seed's
  `VERSIONOPT` gate (`CONFIG_IMAGEOPT=y`/`CONFIG_VERSIONOPT=y`).
- **No `asu.toml` change is needed.** `publish-asu-feed.sh` derives the ASU path from the
  IB's `repositories` (`releases/25.12.5/`), landing under the `[branches."25.12"]` release
  branch that already exists on the server. The branch's *version list* comes from
  **upstream** (`UPSTREAM_URL` → downloads.openwrt.org): upstream says "25.12.5 exists" → owut
  offers it, while **our** IB + feed + profiles.json under `releases/25.12.5/` build the actual
  image. `/api/v1/revision/25.12.5` then returns **our** revision (was 404 before we published).

**Upgrades work on two axes, both via `owut upgrade`:**
- *Within a version* — rolling revisions under the same `25.12.5`; owut sees a newer `rN` at
  `/api/v1/revision/25.12.5` and upgrades in place.
- *Across versions* — when upstream ships `25.12.6`, the cut rebases onto it, stamps `25.12.6`,
  publishes under `releases/25.12.6/`; the `25.12` branch's list gains it, owut's computed
  `latest` becomes `25.12.6`, and it offers `25.12.5 → 25.12.6` — exactly how stock OpenWrt
  walks `24.10.4 → 24.10.5`. One release branch tracks the whole series.

**Fleet migration (one-time):** devices still baked as `25.12-SNAPSHOT` can't owut off it, so
each needs **one manual `sysupgrade`** onto a `25.12.5` build (§8 has the raw commands); after
that `owut upgrade` carries them forward. Then retire the old channel: delete
`[branches."25.12-SNAPSHOT"]` from `asu.toml` and its `releases/25.12-SNAPSHOT/` feed dir.
Also update [versioning.md](versioning.md), which still describes the retired `-SNAPSHOT` model.

---

## 2. Hosts, users, access

**The ASU host** — a Debian server on the tailnet that runs the ASU stack and serves both
`sysupgrade.mono.si` (ASU) and `openwrt.mono.si` (legacy feed).

| User | Role | SSH from build host |
|---|---|---|
| `root` | infra / feed publish (`/srv/*`), drives the `asu` stack | key ✅ |
| `asu` | runs the ASU stack (uid **987**, rootless podman, `loginctl enable-linger`) | no direct key — reach via `root` → `su - asu -c '…'` |
| `mono` | publish user for the legacy channel (`/srv/openwrt`) | key ✅ |
| admin | interactive admin (in `sudo`, **password required**) | key ✅ |

The **build host** additionally holds: the usign signing key
(`~/Mono/Gateway/openwrt/mono-release.sec`), GitHub push rights to the `we-are-mono/openwrt`
remote, and `gh` auth.

Reference clone of the ASU server source: **`~/Mono/Gateway/asu`** (github.com/openwrt/asu). Read the
*image's own* source when in doubt — the published `docker.io/openwrt/asu:latest` drifts from `main`.

---

## 3. The release / cut pipeline  (`scripts/mono-update.sh`)

Releases are cut **only from the `mono` branch** (the script refuses otherwise). Feature work
lives on other branches and must land on `mono` first.

Run it (on the build host) with the infra env sourced:

```sh
cd ~/Mono/Gateway/openwrt/source
set -a; . ~/Mono/Gateway/openwrt/mono-nightly.env; set +a   # MONO_SIGN_KEY, MONO_PUBLISH_DEST=mono@$HOST, MONO_PUBLISH_URL
scripts/mono-update.sh
```

Steps, in order:

1. **Guards** — on `mono`, clean tree, `scripts/check-ask-patch-sync.sh` (ASK patch copies match their pins).
2. **Numbering** — `RN = git log -1 --format=%ct` (the release commit's committer epoch), guarded to exceed the last published N; `RELTAG = mono-vX.Y.Z-rN` (see §4).
3. **Rebase** onto the newest upstream stable tag *within the current minor* (no-op if already current; a new minor/major is a deliberate manual retarget, never followed unattended).
4. **Tag** `RELTAG` (dropped again by the EXIT trap on any later failure → next run recomputes the same rN).
5. **Stamp** the revision (see §4) — writes a `version` file + appends `CONFIG_VERSION_CODE` to `.config`.
6. **Build** inside the pinned nix FHS (`nix run . -- -c '…'`): `make defconfig && make world && make target/imagebuilder/clean && make target/imagebuilder/install`.
7. **Stage** `releases/<tag>/` — images, `kmods/`, `patches/`, and `latest.json` (legacy manifest).
8. **Publish** (only when `MONO_SIGN_KEY` is set):
   - `mono-sign-release.sh` — usign-signs `sha256sums` + `latest.json`.
   - `mono-publish-release.sh` — rsync `releases/<tag>/` + `latest.json` to `mono@$HOST:/srv/openwrt`, then `git push --force-with-lease mono` + `git push -f` the tag + a `gh release`.
   - **`publish-asu-feed.sh`** — refresh the ASU server **and verify it (fail-closed)**; see §6.
9. **EXIT trap** — on any nonzero exit: drop the tag + `git checkout -- version` (the version file is tracked; see §4).

A release is **not "done"** unless the ASU verify passes — so the ASU server can never silently
drift from the published release (that guarantee is the whole point of folding the refresh into the cut).

---

## 4. The release number & revision stamp  (committer-epoch `rN`)

`owut` decides "is there a newer build?" by parsing two `rNNNNN-hash` version strings and comparing
the numeric part (`parse_rev_code = /^r(\d+)-([[:xdigit:]]+)$/`):

- **`%R` — `REVISION`** → the device's `/etc/openwrt_release` `DISTRIB_REVISION` = owut's **"from"**.
  Set via a **`version`** file at the tree root (`scripts/getver.sh` reads it *first*, before git).
- **`%C` — `VERSION_CODE`** → the server/IB `version_code` (in `profiles.json`) = owut's **"to"**.
  Set via **`CONFIG_VERSION_CODE`** (independent of `%R`; `version.mk` falls back to a hardcoded
  constant, never to `%R`, so both must be set).

**`N` = the release commit's committer epoch** (`git log -1 --format=%ct`, e.g. `r1787450154`) —
monotonic by time, stateless (no counter to carry). The git tag and the `version_code` carry the
**same N** — `mono-v25.12.5-r1787450154` and `r1787450154-<hash>`. One number everywhere; nothing
to reconcile. The cut **MUST assert the new N exceeds the last published one** and refuse otherwise,
turning a clock skew or backdated commit into a *failed cut* rather than a fleet-wide "downgrade".

Any epoch N (~1.78×10⁹) sits far above both the legacy getver constant `r33051-f5dae5ece4` that old
builds report *and* the retired sequential tail (`r5001x`, which ended at `r50012`), so the crossover
was a clean one-way forward jump — no device ever sees a downgrade. (This supersedes the old
highest-tag+1 counter and its `+50000` stamp offset.) Full scheme: [versioning.md](versioning.md).

> Note: the cut stamps **both** `CONFIG_VERSION_CODE` (the epoch `%R`) **and** `CONFIG_VERSION_NUMBER`
> (the channel label). The label is **not** taken from `include/version.mk`'s `25.12-SNAPSHOT` fallback
> and is **not** hardcoded in the seed — `mono-update.sh` stamps it to the concrete base version
> `25.12.5` (from `$LATEST`, §1), because owut refuses any `-SNAPSHOT` label (§7.5). The seed supplies
> only the `IMAGEOPT → VERSIONOPT` gate that lets both stamps survive `make defconfig`.

Gotchas:
- `CONFIG_VERSION_CODE` is dropped by `make defconfig` **unless** the seed enables the
  `IMAGEOPT → VERSIONOPT` gate (it does). That gate defaults `VERSION_FILENAMES=y` (renames the
  artifacts) — the seed forces it **off**.
- **`version` is a TRACKED upstream file** (holds `r33051-…`). The cut overwrites it for the build,
  and the EXIT trap **restores** it (`git checkout -- version`) — a bare `rm` would dirty the tree and
  break the next run's clean-check.

**Re-cutting the same number** (to fold a fix into an unshipped release): delete the local tag
(`git tag -d mono-v25.12.5-r<N>`), then re-run; with HEAD unchanged the epoch recomputes to the same
N, and the publish force-updates the remote tag + gh release. Safe as long as no device has taken
that release yet.

---

## 5. The ASU server  (aparcar/asu, rootless podman as `asu`)

Deploy dir **`/home/asu/asu-deploy/`** — `podman-compose.yml`, `asu.env`, `asu.toml`.
Drive podman as `asu`: `ssh $HOST "su - asu -c 'export XDG_RUNTIME_DIR=/run/user/987; podman …'"`.

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
`asu.toml`: `[branches."25.12"] path = "releases/{version}"` maps the branch of the reported
`VERSION_NUMBER=25.12.5` (branch `25.12`) to `releases/25.12.5/`. Each additional LTS line
(`[branches."26.03"]`, …) needs its own entry, or the revision endpoint returns HTTP 400
"Unsupported version". The `25.12` branch itself needs **no** change to gain `25.12.6` — its
version list comes from upstream (§1).

**Build cache / store:** `/home/asu/public/store/<request_hash>/` — cached built images. Redis caches
job/metadata. Both are flushed on every feed refresh (see §6) so a repeated request can't be served a
stale image.

### The ImageBuilder container  (`/home/asu/mono-ib-build/`)

`build-ib-container.sh` wraps the mono IB tarball into an asu-compatible container:
- Derives `TGT` + `VER` from the tarball's `repositories` and tags it
  **`localhost:5000/imagebuilder:<target>-<branch-tag>`**. asu derives `<branch-tag>` itself
  (`asu/util.py`): a `d.d.d` release → `v<version>`; a SNAPSHOT branch → `openwrt-<minor>`. So a
  `25.12.5` build is tagged **`layerscape-armv8_64b-v25.12.5`** — asu looks the IB up by that exact
  tag. (This `v<version>` form is another reason the label must be concrete, not `-SNAPSHOT`.)
- `Containerfile`: Debian **trixie** base (glibc ≥ the nix-FHS host tools), user `buildbot`, IB unpacked at `/builder`; rewrites the IB's `repositories` `downloads.openwrt.org → http://upstream` **and appends the stock userspace feeds** (base/luci/packages/routing/telephony) pointing at `downloads.openwrt.org`, so a build resolves **mono packages internally + any of the ~9000 stock packages from upstream**. No stock *kmod* feed (wrong vermagic).

The IB tag is keyed by the **version** (`v25.12.5`), **not** the revision `version_code` — so every
re-cut/revision of `25.12.5` overwrites the same `v25.12.5` tag, and only a base bump (`25.12.6`)
mints a new one. `make target/imagebuilder/install` must be preceded by `make target/imagebuilder/clean`
(it reuses a stale build_dir `.config` otherwise).

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

> These nginx edits and `openwrt.mono.si`'s vhost are **host-local, not in git**. Recreate on a
> host rebuild. Backups: `*.bak-*` next to the config.

---

## 6. The ASU feed & its refresh  (`scripts/publish-asu-feed.sh`)

The feed lives at **`/srv/asu-feed/releases/<VER>/`** (`VER` = the reported `version_number`, e.g.
`25.12.5`) and is the union the ASU server resolves against:

```
releases/25.12.5/
├── packages/aarch64_generic/
│   ├── feeds.conf                         ← REQUIRED (§7.2); lists base/luci/packages/routing/telephony/video
│   └── {base,luci,packages,…}/index.json  ← per-feed v2 index: Mono-built ∪ upstream (§7.7)
└── targets/layerscape/armv8_64b/
    ├── profiles.json                      ← carries version_code (the revision endpoint reads this)
    ├── index.json                         ← target/kmod package index
    └── packages/*.apk                     ← target + kmod .apks
```

`publish-asu-feed.sh` is the **complete** refresh (run by the cut, fail-closed). It, in one shot:

1. rsyncs the **IB tarball** to `/home/asu/mono-ib-build/` and rebuilds the IB container (`build-ib-container.sh`).
2. rsyncs the **package feed** + the **`profiles.json`** + writes the **`feeds.conf`**.
3. **folds the upstream package index into the feed** (§7.7) so owut can resolve ANY upstream
   package, not just the ~400 Mono builds — index-only (no apks), upstream-wins, and fail-closed
   if upstream is unreachable (`exit 1` rather than ship a feed that can't resolve upstream).
4. flushes the asu build cache (`redis FLUSHALL` + `rm -rf public/store/*`).
5. **verifies** `GET /api/v1/revision/<VER>/<target>` returns the exact `version_code` just built
   **and** that the arch index now advertises the full union (`>1000` packages) — either mismatch →
   `exit 1` → the cut's trap drops the tag. (The target host + server URL are env-overridable.)

Everything shipped comes from the *same* build, so the IB, the feed indexes, and `profiles.json` can
never drift from each other. (This is also the machinery a channel **carry-forward** reuses at LTS
end-of-life — §1: publish one build into a second channel's dir + tag its IB under that channel.)

---

## 7. Client (owut) resolution — and the fixes that made it work

owut's path when you run `owut check` / click "Search" in LuCI:

1. Read `uci get attendedsysupgrade.server.url` (baked to `https://sysupgrade.mono.si` by the
   `mono-asu-config` package's `52-mono-asu-server`).
2. `GET /api/v1/overview` (301 → `/json/v1/overview.json`) → read **`upstream_url`**.
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
hairpin** to the host's own public IP, so we do **not** flip `upstream_url`. Instead the front nginx (a)
serves the feed publicly at `/releases/` and (b) `sub_filter`s **only the overview response**
`http://upstream → https://sysupgrade.mono.si`. The server keeps using `http://upstream` internally
(no hairpin, no restart).

### 7.2 Arch package index came back empty → "N packages missing to-version, cannot upgrade"
The server's `<arch>-index.json` endpoint discovers feeds by reading **`<arch>/feeds.conf`**
(`asu/util.py parse_feeds_conf`: field-2 of each line is a feed subdir name). The mono build ships the
per-feed `index.json` files but **no `feeds.conf`**, so `parse_feeds_conf` returned `[]` → 0 packages →
every arch package "missing". Fix: `publish-asu-feed.sh` writes a `feeds.conf` whose names
(`base luci packages routing telephony video`) match the served subdirs. (Arch index went 0 → 417.)

### 7.3 Stamp looked like a downgrade → §4.
Fixed once the release number moved above the getver constant; the committer-epoch N keeps it there
permanently (§4).

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
end-to-end in a browser. See the §5 nginx block. **host-local, not in git** — recreate on
a host rebuild.

### 7.5 `owut` refused the whole fleet → the channel was `-SNAPSHOT` (2026-08-24)
`owut check` returned *"version-to `25.12-SNAPSHOT` is not available — pick one from above"*,
offering only the empty `25.12` release branch (`25.12.5`, which 404s — we published nothing
there). Root cause: owut computes each branch's offerable version by **skipping any version
string containing `-SNAPSHOT`** (efahl/owut `collect_overview()`: `if index(version,
"-SNAPSHOT") >= 0 continue`), so a `25.12-SNAPSHOT` device has a null `latest` and no upgrade
target — the whole fleet could only manual-dd. Fix: stamp the build as a **concrete base
version** (`25.12.5`) and publish under `releases/25.12.5/`; see "Version channels" in §1 and
`mono-update.sh`'s `CONFIG_VERSION_NUMBER` stamp (§4). Verified: `owut check` on a `25.12.5`
device shows `Version-to 25.12.5 rN` → "safe to proceed."

### 7.6 Installing extra packages & kmods — a rebuild, not `apk add`
There is **no device-side kmod feed** (the `mono-update` `92-mono-feeds` hook was retired with
that package). Kmods are vermagic-locked and the base image is lean, so a device gains one by
having ASU **rebuild the image** with it (the build API takes a `packages` list):

```sh
owut upgrade -a kmod-veth              # a single kmod
owut upgrade -a luci-app-dockerman     # an app — its kmod deps (veth, br-netfilter, fs-btrfs, …) come along
```

`owut --add`/`-a` per package (LuCI: System → Attended Sysupgrade → package list). owut validates
availability against the feed's advertised index — which now carries the **full upstream set**, not
just Mono's (§7.7, the fix that makes "install anything" actually work) — ASU pulls Mono packages +
kmods from **our** feed and stock userspace from upstream, and the device flashes an image with it
**installed**, so it persists across every future `owut upgrade`. We also ship the common-router
kmods as `=m` in the seed (feed-only, zero base bloat — containers/WWAN/exFAT/bonding/tunnels/
netfilter), so they resolve from *our* feed at the correct vermagic. **Not** a device-side `apk add`
feed: on our A/B image model an `apk`-installed package lives only in the current rootfs slot and is
**wiped on the next sysupgrade**; the rebuild path bakes it into the image, which is the whole point.

### 7.7 Making `owut` resolve ANY upstream package — fold the upstream index (2026-08-24)
`owut upgrade -a btop` (or preserving any `apk add`ed upstream package) failed with *"N packages
missing to-version, cannot upgrade"* even though the ImageBuilder could build it. Root cause: owut's
"available in target version" set is **only** what our ASU server advertises — the two indexes it
fetches (efahl/owut): `<sysupgrade>/json/v1/<rel>/packages/<arch>-index.json` (arch userspace) and
`…/targets/<target>/index.json` (target + kmods). asu **synthesizes** the arch one by unioning the
per-feed `index.json` files under our feed dir (`settings.upstream_url` = the internal
`http://upstream` = `/srv/asu-feed`, *not* downloads.openwrt.org). We only ever shipped Mono's ~400
built packages there, so upstream's other ~9,400 were invisible → owut refused them. **No owut flag
bypasses this** (`--add` always validates; `--force` only covers downgrades/no-changes; a missing
preserved package can only be dropped with an explicit `--remove`).

Fix (`publish-asu-feed.sh` step 3, §6): fold upstream's per-feed `index.json` into ours, so the
synthesized arch index advertises the **union** (~400 → ~9,800). **Index-only** — we do *not* mirror
`.apk`s: the IB still fetches the real apks from its appended `downloads.openwrt.org` feeds at build
time (verified: a build with the upstream-only `btop` resolves + compiles clean), and the device
gets the finished *image*, never individual apks, so on-device `apk add` (which reaches upstream
directly) was always fine — only owut's rebuild path went through the gapped feed. **Precedence is
upstream-wins on overlap**, which within a frozen release equals highest-version-wins (measured: Mono
never exceeds upstream on any of the 373 overlaps), so the advertised version equals exactly what the
IB installs — no phantom out-of-date/downgrade. Fail-closed: if upstream can't be fetched, the cut
refuses rather than ship a feed that silently can't resolve upstream packages. The kmod (target)
index needs no fold — kmods are ours, at our vermagic. Verified end-to-end: `owut upgrade -a
kmod-veth` on a device with `btop` installed → `0 missing`, builds, preserves both.

---

## 8. Troubleshooting

Fast diagnostics (from anywhere):

```sh
# What does the server advertise / serve?  (VER = the device's channel, e.g. 25.12.5 — a
# concrete release branch, NOT 25.12-SNAPSHOT: owut skips any -SNAPSHOT version. See §7.5.)
curl -s https://sysupgrade.mono.si/api/v1/overview | grep -o '"upstream_url":"[^"]*"'   # must be https://sysupgrade.mono.si
curl -s https://sysupgrade.mono.si/api/v1/revision/25.12.5/layerscape/armv8_64b   # must be the CURRENT version_code
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
| `owut … DOWNGRADE` | stamp below the getver constant | revision endpoint value; §4 |
| `N packages missing to-version` (every pkg) | arch index empty | the `<arch>-index.json` count; `feeds.conf` present (§7.2) |
| `… missing to-version` for an **upstream** pkg (btop, nano, …) | upstream fold didn't run — feed advertises only Mono's ~400 | `<arch>-index.json` count should be ~9,800 not ~400; re-run `publish-asu-feed.sh` (§7.7) |
| revision endpoint → 400 "Unsupported version" | no `[branches."<name>"]` for the device's channel | add the branch to `asu.toml` (§5) |
| `Image not found: …imagebuilder:…` on build | IB container not (re)built for this branch tag | `build-ib-container.sh`; registry catalog |
| revision endpoint stale after a publish | `profiles.json` not refreshed / caches | re-run `publish-asu-feed.sh`; it flushes redis + store |

Server-side (as `asu`): `podman logs asu-deploy_server_1`, `podman exec asu-deploy_redis_1 redis-cli FLUSHALL`,
`podman images | grep imagebuilder`.

---

## 9. Key files

**In this repo (`mono`/openwrt):**
- `scripts/mono-update.sh` — the release/cut pipeline (stamp, build, sign, publish, ASU refresh).
- `scripts/publish-asu-feed.sh` — the complete, fail-closed ASU refresh (IB + feed + profiles.json + feeds.conf + verify).
- `scripts/mono-latest-json.py` — generates the legacy-channel `latest.json` manifest.
- `scripts/mono-sign-release.sh`, `scripts/mono-publish-release.sh` — legacy-channel sign + publish.
- `configs/mono_gateway-dk.seed` — the build config (package selection, and the `CONFIG_IMAGEOPT=y`/`CONFIG_VERSIONOPT=y` gate that lets `mono-update.sh`'s `CONFIG_VERSION_NUMBER`/`CONFIG_VERSION_REPO` stamp survive `make defconfig`). The version value is **not** hardcoded here — it's stamped dynamically from `$LATEST` in `mono-update.sh`.
- `target/linux/layerscape/image/armv8_64b.mk` — `DEVICE_PACKAGES` (what's baked; what owut preserves).
- `package/mono/asu-config/` — bakes `attendedsysupgrade.server.url = https://sysupgrade.mono.si`.
- `include/version.mk`, `scripts/getver.sh`, `version` — the `%R`/`%C` machinery.

**On the ASU host (not in git — recreate on rebuild):**
- `/etc/nginx/sites-available/sysupgrade.mono.si` — the front nginx (`/releases/`, overview rewrite, `/store/`, `/`).
- `/home/asu/asu-deploy/` — `podman-compose.yml`, `asu.env`, `asu.toml`.
- `/home/asu/mono-ib-build/` — `Containerfile`, `build-ib-container.sh`, the IB tarball.
- `/srv/asu-feed/` — the ASU package feed. `/srv/openwrt/` — the legacy release channel.

**On the build host (infra, uncommitted):**
- `~/Mono/Gateway/openwrt/mono-nightly.env` — `MONO_SIGN_KEY`, `MONO_PUBLISH_DEST=mono@$HOST`, `MONO_PUBLISH_URL`.
- `~/Mono/Gateway/openwrt/mono-release.sec` — the usign signing key (guard it).
- `~/Mono/Gateway/asu/` — reference clone of the ASU server source.
