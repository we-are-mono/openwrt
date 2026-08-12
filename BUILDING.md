# Building the Mono Gateway image

The build runs inside a pinned **Nix FHS environment** (`flake.nix`) so the host
toolchain is byte-identical on every machine — there is no `apt install` list to
drift, and a build is reproducible across machines and over time.

## Prerequisites

- **Nix with flakes** — [Determinate Nix](https://determinate.systems/nix)
  (flakes on by default), or upstream Nix with
  `experimental-features = nix-command flakes`.
- **Unprivileged user namespaces** — enabled by default on stock Debian/Ubuntu
  kernels; the FHS env uses `bubblewrap`, which needs them. (Some hardened or
  corp-locked kernels disable them.)

Nothing else. All build dependencies (gcc, make, bison, flex, …) come from the
flake, pinned by `flake.lock`.

## Interactive

```sh
nix develop            # drops you into the FHS shell: gcc, make, bison … on PATH
make menuconfig
make -j"$(nproc)" world
```

## Scripted / CI / nightly

**Do not** use `nix develop --command …` or `nix-shell --run …` — the env's
`shellHook` `exec`s into the FHS shell, so the `--command`/`--run` payload never
runs and the invocation hangs. Use `nix run`, which enters the FHS env directly:

```sh
nix run . -- -c 'make -j"$(nproc)" world'
```

The nightly (`scripts/mono-update.sh`) builds this way. Only the `make` steps run
inside the env; git, publishing and release signing stay on the host.

## The pin

`flake.lock` pins `nixpkgs` to an exact revision — that is what makes builds
reproducible. Update it deliberately:

```sh
nix flake update       # bump nixpkgs; then rebuild + test before committing the lock
```

Note: Nix only sees **git-tracked** files, so `flake.nix`/`flake.lock` (and any
new source) must be `git add`ed before `nix run`/`nix develop` will pick them up.
