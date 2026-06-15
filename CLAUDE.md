# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Nix flake that builds a reproducible Alacritty terminal, bundled with a curated set of CLI tools (zsh, tmux, bat, ripgrep, fd, starship, delta, navi, claude-code, …) each wrapped so they load their configuration from this repo's `sources/` tree.

## Common commands

Enter the dev shell first (`nix develop` — direnv will do it automatically via `.envrc`). The shell provides these helpers (defined in `devshells/terminal.nix`):

- `dev` — run Alacritty with `PERMEANCE_ROOT=$PWD/sources nix run .`. The same bundled derivation runs; each wrapper's launcher reads `$PERMEANCE_ROOT` at exec time and redirects every config lookup to the live working tree. Config edits take effect on next launch, no rebuild, no `--impure`.
- `bdl` — run Alacritty in bundled mode (`nix run .`). `$PERMEANCE_ROOT` unset, launchers fall back to the wrapper's own `$out`.
- `tools <name> [args…]` — run any bundled CLI tool from the `packages.tools` env (e.g., `tools rg foo`).
- `smoke` — run wrapper smoke tests (`nix flake check -L --keep-going -j auto`); these are the per-wrapper `passthru.tests.smoke` derivations exposed via the `checks` output.
- `h` — print the helper list.

Other useful commands:

- `nix flake check` / `nix flake show` — validate or inspect outputs.
- `nix build .#default` / `nix build .#tools` — build the terminal or the tools env.
- `nix build .#checks.x86_64-linux.<wrapper>` (e.g., `.#checks.x86_64-linux.zsh`) — build/run a single wrapper's smoke test for fast iteration.
- `lefthook run pre-commit` — run git hooks locally (hooks live in `lefthook.local.yml`, which is a symlink into the Nix store).
- `infra <args>` — OpenTofu wrapper (from `devshells/infra.nix`); always runs against `./infra` and supplies `GITHUB_TOKEN` from `gh auth token`. See `infra/README.md`.

## Architecture

`flake.nix` is the entry point. It defines four small helpers and wires them through `flake-utils.eachDefaultSystem`:

- `mkPkgs system` — imports this flake's pinned `nixpkgs` (with the `nixpkgs-24-05` overlay applied). Always used so wrapper builds are reproducible against `flake.lock`, regardless of what `pkgs` a consumer's flake might bring.
- `mkPermeance pkgs` = `inputs.permeance.lib pkgs` — the launcher helper from the [permeance](https://github.com/Runeword/permeance) flake input, threaded into each wrapper.
- `mkWrappers pkgs configPath` = `import ./wrappers` with `permeance` passed in — attrset of wrapper derivations (used as a handle so wrappers can depend on each other, e.g. tmux ← zsh ← claude).
- `mkTools pkgs configPath wrappers` = `import ./packages` ++ `attrValues wrappers` — the full set of derivations.
- `mkTerminal pkgs configPath tools` = `import ./wrappers/alacritty.nix` with those tools on `PATH` and `permeance` passed in.

Outputs:

- `packages.default` — the wrapped Alacritty (see `wrappers/alacritty.nix`: `runCommand` + a permeance launcher built via `permeance.installLauncher`. The launcher preserves the process name `alacritty` via `exec -a "$0"`, injects `FONTCONFIG_FILE` on Linux, and passes `--config-file` resolved from `$PERMEANCE_ROOT/.config/alacritty/alacritty.toml`).
- `packages.tools` — a `buildEnv` of every tool. `pathsToLink = [ "/bin" ]` to avoid config-file collisions between wrappers (e.g. `fd` and `ripgrep` both ship a `.config/ignore`). The devshell `tools` helper runs binaries from it via `nix shell .#tools --command`.
- `packages.firefox-mcp` / `packages.mobile-mcp` — standalone MCP server packages from `packages/custom/`. Other `packages/custom/` entries (`claude-statusline`, `claude-docs-guard`, `git-allowlist-hook`, `git-branches`) are Go binaries built and consumed internally by the `claude` wrapper / `sources/.claude/settings.json` hooks — not exposed as flake outputs.
- `apps.default` — `nix run` target. One derivation, bundled by default; set `PERMEANCE_ROOT=$PWD/sources` to redirect every wrapper's config lookups to the live working tree. No `apps.dev`, no `--impure`.
- `checks.<wrapper>` — each wrapper's `passthru.tests.smoke` derivation, run by `nix flake check`.
- `checks.unit-tests` — runs `lib/tests-unit.nix` invariants (e.g. "every wrapper has a smoke test") via `pkgs.lib.runTests` at flake-evaluation time. On failure, the derivation build emits the JSON failure list on stderr and exits 1 (failure is scoped to this check; unrelated flake outputs are unaffected). Failures are also exposed via `passthru.failures` for `nix eval` introspection.
- `lib.mkTerminal` / `lib.mkTools` — reusable builders for downstream flakes. Both take `{ system, configPath ? ./sources }` (not `pkgs`); they call `mkPkgs system` internally so consumers can't accidentally pull stale versions of version-sensitive tools through their own `nixpkgs` lock.
- `homeModules.default` — home-manager integration (see `modules/terminal.nix`, options under `programs.terminal`).

`devShells.default` is composed via `inputsFrom` from five sub-shells: `devshells/terminal.nix` (the `dev`/`bdl`/`tools`/`smoke`/`h` helpers above), `devshells/languages.nix`, `devshells/infra.nix` (the `infra` wrapper), `claude.devShells.${system}.ast-grep` (from the `claude` flake input), and `devshells/lefthook.nix`.

### `lib/files.nix` (local) + `permeance` (flake input)

Two namespaces, paired to implement the **permeance** pattern (build-time bundled tree + runtime override knob):

`files.mkConfig name entries` (in `lib/files.nix`, this repo) returns a `pkgs.linkFarm` derivation that symlinks each entry's `source` (relative to `rootPath`, or absolute) at `target` under `$out`. Wrappers add this derivation to their `symlinkJoin` `paths`, which carries the bundled configs into the wrapper's `$out`. `rootPath` must be a Nix path literal (`./sources`); sub-paths interpolate as proper store references and propagate into downstream closures. The bundled tree is the only thing baked into the derivation.

`permeance.mkLauncher args` (from the `permeance` flake input — see `~/permeance` / `github:Runeword/permeance`) returns a shell-script string that resolves its own bundled root at exec time by canonicalising `BASH_SOURCE[0]` (via pinned `coreutils/bin/readlink -f`) and stripping `/bin/<name>` into the local `$__permeance_out`. `$PERMEANCE_ROOT` defaults to that value and overrides cleanly when set in the environment. The launcher is fully self-contained — no install-time placeholder substitution — so caller-supplied data can never collide with a sentinel.

Args:
- `realBin` — absolute path / `@OUT@`-prefixed / bare relative name (composed with `$__permeance_out/bin/`)
- `configEnv` (`{ ENV = "rel/path"; }`) — exported as `"$PERMEANCE_ROOT/rel/path"`
- `staticEnv` — literal values; `@OUT@` rewrites to runtime `$__permeance_out`; `@@OUT@@` escapes to a literal `@OUT@`
- `defaultEnv` — `--set-default` semantics: assign only if unset (empty counts as set)
- `pathPrefix` — dirs prefixed onto `PATH`
- `flags` — `$PERMEANCE_ROOT` and `@OUT@` stay expandable, everything else is shell-escaped
- `unsetEnv` — names to `unset` before exec

`permeance.installLauncher` wraps `mkLauncher` with the common postBuild pattern (materialize via `pkgs.writeTextFile` with build-time shellcheck, optionally rename the upstream binary to `.${binName}-real`, install via `install -m755`). Two modes: omit `realBin` for rewrap (used by `symlinkJoin` wrappers), pass an absolute path for fresh-wrap (used by alacritty's `runCommand`).

Setting `PERMEANCE_ROOT=/path/to/sources` at launch redirects every wrapper's config var/flag to the live tree — no rebuild, no `--impure`. The flake is always pure (no `getEnv`); the dev/bundled switch lives entirely at exec time. The launcher itself validates `$PERMEANCE_ROOT` at startup: must be absolute, must point at an existing directory.

This pattern is the inverse of NixOS impermanence: same trick (symlink at a Nix path opens onto a non-store path with different durability rules), opposite goal. Impermanence escapes ephemeral-root volatility by pointing at a persistent disk; permeance escapes store immutability by pointing at the editable working tree. Unit tests for the launcher renderer live in the `permeance` repo; this flake's `checks.unit-tests` only asserts wrapper-level invariants (e.g. "every wrapper has a smoke test").

### Packages vs wrappers

- `packages/` — plain derivations we expose as-is. `default.nix` fans out to `commons.nix`, `custom/`, and one of `linux.nix` / `darwin.nix` based on `stdenv.isDarwin`.
- `wrappers/` — derivations that wrap an upstream package (e.g., `pkgs.alacritty`, `pkgs.claude-code`) with a permeance launcher built via `permeance.installLauncher`. The upstream binary is renamed to `.foo-real` (or wrapped via `makeWrapper` into `.foo-inner` for wrappers with bundled static flags like nvim-fzf); the launcher resolves config paths from `$PERMEANCE_ROOT` at exec time and `exec -a "$0"` into the inner.
  - **Built wrappers** (`wrappers/default.nix`): `zsh`, `claude`, `tmux`, `bat`, `fd`, `ripgrep`, `bash`, `starship`, `delta`, `navi`, `nvim-fzf`.
  - **Cross-wrapper deps**: `claude` is passed into `zsh`; `zsh` is passed into `tmux`. That's why `mkWrappers` returns an attrset rather than a list.
- Each wrapper attaches a `passthru.tests.smoke` derivation built via `lib/tests.nix`. The harness exposes `ok` / `fail` shell helpers and an isolated `$HOME` (the Nix sandbox sets `HOME=/homeless-shelter`, which breaks tools that touch XDG paths). Each smoke test verifies:
  1. **Behavioural** — the bundled config loads correctly (invoke the wrapper, observe).
  2. **Structural** — the rendered launcher contains the `$PERMEANCE_ROOT/...` resolution pattern (grep). The runtime override can't be exercised behaviorally inside the sandbox because no live working tree is reachable from there.

### Overlays (`overlays/default.nix`)

Three overlays are applied: one pins `awscli2` to nixpkgs-24.05; one source-pins `tmux` to 3.6a via `overrideAttrs` + `fetchFromGitHub` (so we don't carry a second nixpkgs input just to freeze the version); the third overrides `firebase-tools` to build against Node 20. All follow the `final: prev:` convention — `prev` is used when redefining existing attributes.

### Sources tree (`sources/`)

The `sources/` tree mirrors what the wrapped tools see under `$HOME`: `sources/.config/` for XDG-style configs (alacritty, zsh, bash, tmux, bat, starship, delta, direnv, ignore, navi, nvim-fzf, readline, ripgrep, shell) and `sources/.claude/` for Claude Code settings, hooks, and rules. Each wrapper passes target paths to `files.mkConfig`, which symlinks `sources/<target>` to `$out/<target>`.

### Infrastructure (`infra/`)

OpenTofu config managing GitHub repository settings (visibility, Actions permissions, branch protection, security analysis) via the `integrations/github` provider. State is local (`*.tfstate` gitignored) — bootstrap is import-based, not greenfield apply, since the repository already exists. The `tf` devshell helper runs `tofu` against this directory; see `infra/README.md` for the import sequence.

## Conventions

- `flake.nix` stays thin — real logic lives in `packages/`, `wrappers/`, `lib/`, `modules/`, `overlays/`, `devshells/`.
