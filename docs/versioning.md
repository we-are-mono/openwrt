# Versioning & branch naming

Convention for branches and release tags across Mono Technologies repositories
(OpenWrt, ASK, kernel forks, drivers, …). Most repos are coupled to either a **kernel
version** or an **OpenWrt release**; this scheme keeps them consistent without forcing the
wrong axis onto any one project.

## Principle: consistency is in the grammar, not the value

Every repo uses the same **shape** — `mono-<axis>` for a branch, `mono-<axis>-rN` for a
release — but `<axis>` is whatever that project is *naturally* versioned by. Same prefix +
same grammar → recognizable across repos; per-project axis → honest about what actually
diverges. Don't force the same *value* (`6.12`) into every name.

## Anchor each repo to its primary axis

| Repo kind | Diverges on | Branch | Release tag |
|---|---|---|---|
| kernel fork · ASK · drivers | kernel minor | `mono-6.12`, `mono-6.18` | `mono-6.12-r1` |
| **OpenWrt** | OpenWrt release line | `mono-v25.12` | `mono-v25.12.5-r50012` |

Kernel-coupled repos: a new kernel is a new port, so a new branch. OpenWrt: the axis of
divergence is the OpenWrt **release line** — the kernel just rides *inside* the image, so
it must not drive the OpenWrt name.

## OpenWrt rules

- **Branch = the minor line, not the patch.** `mono-v25.12` tracks upstream
  `openwrt-25.12`. Point releases (`.5 → .6 → .7`) are **tags on that branch** — rebase
  the branch onto the new `v25.12.x` tag and tag it; never a new branch. A **new branch**
  only on a **minor** bump (`mono-v25.12 → mono-v26.03`).
- **`-rN` = the release commit's committer epoch** — `git log -1 --format=%ct` (e.g.
  `r1755800000`). Monotonic by time, stateless (no tag lookup or counter to maintain), and
  computed identically in every repo. It feeds owut's version-code ordering, so the cut
  **MUST assert the new N exceeds the last published one** and refuse otherwise — that turns
  a clock skew or backdated commit into a *failed cut*, not a fleet-wide "downgrade" (the
  exact failure the kernel migration fixed). Never reset across point or minor bumps.
  Supersedes the old highest-tag+1 counter; the `r5001x` sequence ended at **r50012**, and
  any epoch N ≫ 50012, so the crossover is a clean forward jump (also drops the legacy
  `+50000` stamp offset).
- **One axis in the name.** `mono-v25.12`, never `mono-v25.12-6.12`. The kernel / ASK
  versions for an image live in metadata (below), not the name.

```
branch  mono-v25.12                     ← tracks openwrt-25.12
  ├ tag mono-v25.12.5-r50012            (last of the old sequential Ns)
  ├ tag mono-v25.12.6-r<epoch>          (.6 lands: rebase branch + tag; same branch)
  └ tag mono-v25.12.7-r<epoch>
branch  mono-v26.03                     ← only on a MINOR bump
  └ tag mono-v26.03.0-r<epoch>          (N = committer epoch, always larger)
```

The `v` is kept (consistent with OpenWrt's own `v25.12.5` version tags); the branch drops
the patch component (`mono-v25.12`, not `mono-v25.12.5`).

## Git identity vs OpenWrt version (they differ on purpose)

The git tag `mono-v25.12.5-rN` is the **mono release identity** — for the repo, the forge,
and the signed `latest.json` channel. Its `25.12.5` is the base v-tag the branch was rebased
onto, **not** the OpenWrt `version_number` the build reports. Because the branch tracks
`openwrt-25.12` HEAD (not a pinned tag), the build reports `version_number = 25.12-SNAPSHOT`
— the axis owut/ASU key off (its feed lives at `/srv/asu-feed/releases/25.12-SNAPSHOT`).
These are two separate namespaces on purpose; don't force the tag to match the build's
version or vice-versa. Consequence: a fielded device on a *different* OpenWrt version can't
cross to `25.12-SNAPSHOT` via `owut check` alone — that's a deliberate one-time move, not a
naming problem.

## Kernel / ASK rules

- Branch `mono-<kernel-minor>` (`mono-6.12`), tag `mono-<kernel-minor>-rN`.
- Restart `rN` at `r1` per kernel line — these ship **baked inside** the OpenWrt sysupgrade
  image, so they are not fleet-ordered and carry no monotonic constraint.
- The `6.x` vs `25.x`/`26.x` number ranges keep kernel branches unambiguous from OpenWrt
  ones under the shared `mono-` prefix.

## Cross-repo linkage

The kernel and ASK versions inside a given OpenWrt release belong in **metadata, not
names** — the release manifest (`releases/latest.json`) and/or a compatibility matrix:

> `mono-v25.12.5-r50012`  →  kernel `6.12.103`  +  ASK `mono-6.12-rN`

That is the single place to answer "what is in this image" without polluting any name.

## Tooling

`scripts/mono-update.sh` and `scripts/mono-publish-release.sh` derive the release branch
from the `mono-v*` pattern (the branch you are on / the tag being published), so a new
OpenWrt minor line needs **no script edits** — just branch `mono-v<minor>` off the previous
line and cut. The release tag is `mono-<newest merged v-tag>-r<git log -1 --format=%ct>`,
guarded so the new N must exceed the last published one.
