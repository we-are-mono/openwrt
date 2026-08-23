# Versioning & branch naming

Convention for branches and release tags across Mono Technologies repositories
(OpenWrt, ASK, kernel forks, drivers, …). Most repos are coupled to either a **kernel
version** or an **OpenWrt release**; this scheme keeps them consistent without forcing the
wrong axis onto any one project.

## Principle: consistency is in the grammar, not the value

Every repo shares the `mono-` prefix and the `…-rN` release grammar, but the branch shape
follows how the project actually evolves. A **ported** repo (kernel fork · ASK · drivers) is
re-based per kernel line, so its branch carries the axis: `mono-<axis>` (`mono-6.12`). A
**rolling** repo (OpenWrt) advances one long-lived trunk in place, so its branch is bare
`mono` and the version lives in the *tag*. Same prefix + same tag grammar → recognizable
across repos; per-project branch shape → honest about what actually diverges. Don't force the
same *value* (`6.12`) into every name.

## Anchor each repo to its primary axis

| Repo kind | Diverges on | Branch | Release tag |
|---|---|---|---|
| kernel fork · ASK · drivers | kernel minor | `mono-6.12`, `mono-6.18` | `mono-6.12-r1` |
| **OpenWrt** | OpenWrt release line | `mono` (single rolling trunk) | `mono-v25.12.5-r<epoch>` |

Kernel-coupled repos: a new kernel is a new port, so a new branch. OpenWrt: the release line
it tracks advances *in place* on one `mono` trunk — the kernel just rides *inside* the image,
so it never drives a branch name, and the OpenWrt base line is recorded in the tag, not the
branch.

## OpenWrt rules

- **One rolling trunk: `mono`.** It tracks whichever upstream `openwrt-<line>` we've adopted
  (today `openwrt-25.12`). Point releases (`.5 → .6 → .7`) are **tags on `mono`** — rebase
  `mono` onto the new `v25.12.x` tag and tag it; never a new branch.
- **Minor/major bumps happen in place.** Moving to a new upstream line (`25.12 → 26.03`) is a
  deliberate, eyes-open migration done **on `mono`** — never followed unattended. We do
  **not** pre-create per-line branches. Only if we ever actually need to keep patching a
  superseded line do we branch `mono-v25.12` off **at that moment** to archive it; per-minor
  branches are an on-demand escape hatch, not the default.
- **`-rN` = the release commit's committer epoch** — `git log -1 --format=%ct` (e.g.
  `r1755800000`). Monotonic by time, stateless (no tag lookup or counter to maintain), and
  computed identically in every repo. It feeds owut's version-code ordering, so the cut
  **MUST assert the new N exceeds the last published one** and refuse otherwise — that turns
  a clock skew or backdated commit into a *failed cut*, not a fleet-wide "downgrade" (the
  exact failure the kernel migration fixed). Never reset across point or minor bumps.
  Supersedes the old highest-tag+1 counter; the `r5001x` sequence ended at **r50012**, and
  any epoch N ≫ 50012, so the crossover is a clean forward jump (also drops the legacy
  `+50000` stamp offset).
- **The version lives in the tag, not the branch.** The branch is bare `mono`; the OpenWrt
  base line rides in the release tag `mono-v<base>-rN` and the image metadata, never in the
  branch name.

```
branch  mono                            ← the single rolling trunk (tracks openwrt-25.12 today)
  ├ tag mono-v25.12.5-r50012            (last of the old sequential Ns)
  ├ tag mono-v25.12.6-r<epoch>          (.6 lands: rebase mono + tag)
  ├ tag mono-v25.12.7-r<epoch>
  └ tag mono-v26.03.0-r<epoch>          (26.03 migration: same trunk, base rides in the tag)
(branch mono-v25.12                      ← created ONLY on demand, to keep patching an old line)
```

The tag keeps the `v` (consistent with OpenWrt's own `v25.12.5` tags) and the full
`base.patch` the trunk was rebased onto; the branch itself carries no version at all.

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

`scripts/mono-update.sh` and `scripts/mono-publish-release.sh` operate on the `mono` trunk;
the release tag's base comes from the newest upstream `v*` tag **merged into the branch**
(`mono-<that tag>-r<git log -1 --format=%ct>`), independent of the branch name and guarded so
the new N must exceed the last published one. A minor migration therefore needs **no script
edits** — it happens on `mono`, and the new base flows in from the merged upstream tag.
