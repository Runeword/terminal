# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Nix flake that builds a reproducible Alacritty terminal, bundled with a curated set of CLI tools (zsh, tmux, bat, ripgrep, fd, starship, delta, navi, claude-code, …) each wrapped so they load their configuration from this repo's `sources/` tree.

## Common commands

Enter the dev shell first (`nix develop` — direnv will do it automatically via `.envrc`). The shell provides these helpers (defined in `devshells/terminal.nix`):

- `dev` — run Alacritty with `PERMEANCE_ROOT=<repo-root>/sources nix run <repo-root>` (works from any subdirectory). The same bundled derivation runs; each wrapper's launcher reads `$PERMEANCE_ROOT` at exec time and redirects every config lookup to the live working tree. Config edits take effect on next launch, no rebuild, no `--impure`.
- `bdl` — run Alacritty in bundled mode (`nix run .`). `$PERMEANCE_ROOT` unset, launchers fall back to the wrapper's own `$out`.
- `tools <name> [args…]` — run any bundled CLI tool from the `packages.tools` env (e.g., `tools rg foo`).
- `smoke` — run wrapper smoke tests (`nix flake check -L --keep-going -j auto`); these are the per-wrapper `passthru.tests.smoke` derivations exposed via the `checks` output.
- `watch [cmd]` — re-run a command on every `.nix` write via watchexec (default: the `smoke` flake check).
- `h` — print the helper list.

Other useful commands:

- `nix flake check` / `nix flake show` — validate or inspect outputs.
- `nix build .#default` / `nix build .#tools` — build the terminal or the tools env.
- `nix build .#checks.x86_64-linux.<wrapper>` (e.g., `.#checks.x86_64-linux.zsh`) — build/run a single wrapper's smoke test for fast iteration.
- `lefthook run pre-commit` — run git hooks locally. `lefthook.yml` extends `lefthook-generated.yml` (a committed file rendered by the lefthook flake input: per-language format/lint jobs, gitleaks, auto-commit) and adds a `pre-push` job that runs the full flake check when pushed files touch `flake.*`, `lib/`, `wrappers/`, `packages/`, or `overlays/`. Not a dry run: the `auto-commit` job commits whatever is staged.
- `infra <args>` — OpenTofu wrapper (from `devshells/infra.nix`); always runs against `./infra` and supplies `GITHUB_TOKEN` from `gh auth token`. See `infra/README.md`.

## Architecture

`flake.nix` is the entry point. It defines five small helpers and wires them through `flake-utils.lib.eachSystem` (the default systems minus x86_64-darwin, which nixpkgs unstable no longer supports):

- `mkPkgs system` — imports this flake's pinned `nixpkgs` (with the `nixpkgs-24-05` overlay applied). Always used so wrapper builds are reproducible against `flake.lock`, regardless of what `pkgs` a consumer's flake might bring.
- `mkPermeance pkgs` = `inputs.permeance.lib pkgs` — the launcher helper from the [permeance](https://github.com/Runeword/permeance) flake input, threaded into each wrapper.
- `mkWrappers pkgs configPath` = `import ./wrappers` with `permeance` passed in — attrset of wrapper derivations (used as a handle so wrappers can depend on each other, e.g. tmux ← zsh ← claude).
- `mkTools pkgs wrappers` = `import ./packages` ++ `attrValues wrappers` — the full set of derivations.
- `mkTerminal pkgs configPath tools` = `import ./wrappers/alacritty.nix` with those tools on `PATH` and `permeance` passed in.

Outputs:

- `packages.default` — the wrapped Alacritty (see `wrappers/alacritty.nix`: `runCommand` + a permeance launcher built via `permeance.installLauncher`. The launcher preserves the process name `alacritty` via `exec -a "$0"`, injects `FONTCONFIG_FILE` on Linux, and passes `--config-file` resolved from `$PERMEANCE_ROOT/.config/alacritty/alacritty.toml`).
- `packages.tools` — a `buildEnv` of every tool. `pathsToLink = [ "/bin" ]` to avoid config-file collisions between wrappers (e.g. `fd` and `ripgrep` both ship a `.config/ignore`). The devshell `tools` helper runs binaries from it via `nix shell .#tools --command`.
- `packages.firefox-mcp` / `packages.mobile-mcp` / `packages.aws-api-mcp` / `packages.google-workspace-mcp` — standalone MCP server packages from `packages/custom/`. The other `packages/custom/` entries are Go binaries with no flake output of their own: `packages/custom/default.nix` puts `git-branches` and `claude-session-status` into the tools env (so they're on PATH inside the terminal), while `claude-statusline`, `claude-docs-guard`, `git-allowlist-hook`, and `git-shim` are consumed only inside the `claude` wrapper (see below).
- `apps.default` — `nix run` target. One derivation, bundled by default; set `PERMEANCE_ROOT=$PWD/sources` to redirect every wrapper's config lookups to the live working tree. No `apps.dev`, no `--impure`.
- `checks.<wrapper>` — each wrapper's `passthru.tests.smoke` derivation, plus `checks.alacritty` for the terminal itself, run by `nix flake check`.
- `checks.unit-tests` — runs `lib/tests-unit.nix` invariants (e.g. "every wrapper has a smoke test", asserted separately for the terminal since it isn't in the wrappers attrset) via `pkgs.lib.runTests` at flake-evaluation time. On failure, the derivation build emits the JSON failure list on stderr and exits 1 (failure is scoped to this check; unrelated flake outputs are unaffected). Failures are also exposed via `passthru.failures` for `nix eval` introspection.
- `lib.mkTerminal` / `lib.mkTools` — reusable builders for downstream flakes. Both take `{ system, configPath ? ./sources }` (not `pkgs`); they call `mkPkgs system` internally so consumers can't accidentally pull stale versions of version-sensitive tools through their own `nixpkgs` lock.
- `homeModules.default` — home-manager integration (see `modules/terminal.nix`, options under `programs.terminal`). Setting `programs.terminal.configPath` wraps alacritty with `--set-default PERMEANCE_ROOT` and exports the same value via `home.sessionVariables`, so WM-launched and shell-launched tools both see the live tree; runtime `PERMEANCE_ROOT=… alacritty` still wins.

`devShells.default` is composed via `inputsFrom` from five sub-shells: `devshells/terminal.nix` (the `dev`/`bdl`/`tools`/`smoke`/`watch`/`h` helpers above), `devshells/languages.nix`, `devshells/infra.nix` (the `infra` wrapper), `claude.devShells.${system}.ast-grep` (from the `claude` flake input), and `devshells/lefthook.nix`.

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
  - **Built wrappers** (`wrappers/default.nix`): `zsh`, `claude`, `git`, `tmux`, `bat`, `fd`, `ripgrep`, `bash`, `starship`, `delta`, `navi`, `nvim-fzf`.
  - **Cross-wrapper deps**: `git` is passed into `claude`; `claude` into `zsh`; `zsh` into `tmux`. That's why `mkWrappers` returns an attrset rather than a list.
  - **The `claude` wrapper** (`wrappers/claude.nix`) carries the most wiring: it passes `--settings $PERMEANCE_ROOT/.claude/settings.json`, puts formatters/LSPs, the MCP server packages, and the custom Go binaries on claude's PATH (the `sources/.claude/settings.json` hooks and statusline invoke them by bare name — `claude-session-status`, `claude-docs-guard`, `git-allowlist-hook`, `claude-format`, `claude-statusline`), and prefixes `git-shim` — a binary named `git` that enforces `sources/.claude/git-allowlist.toml` before exec'ing the wrapped git — onto claude's PATH only, so claude's whole process tree gets allowlisted git while the interactive shell keeps the ordinary wrapped git.
- Each wrapper attaches a `passthru.tests.smoke` derivation built via `permeance.tests.mkSmoke` (from the `permeance` flake input). The harness exposes `ok` / `fail` shell helpers and an isolated `$HOME` (the Nix sandbox sets `HOME=/homeless-shelter`, which breaks tools that touch XDG paths). Each smoke test verifies **behaviourally** that the bundled config loads correctly — invoke the wrapper and observe. The runtime `$PERMEANCE_ROOT` override can't be exercised inside the sandbox (no live working tree is reachable there), so it isn't tested.

### Overlays (`overlays/default.nix`)

Two overlays are applied (composed in `overlays/default.nix`): `channel-pins.nix` pins `awscli2` to the `nixpkgs-24-05` input; `tmux.nix` source-pins `tmux` to 3.6a via `overrideAttrs` + `fetchFromGitHub` (so we don't carry another nixpkgs input just to freeze that version).

### Sources tree (`sources/`)

The `sources/` tree mirrors what the wrapped tools see under `$HOME`: `sources/.config/` for XDG-style configs (alacritty, zsh, bash, tmux, bat, git, starship, delta, direnv, ignore, navi, nvim-fzf, readline, ripgrep, shell) and `sources/.claude/` for Claude Code settings, hooks, rules, MCP plugin manifests (`plugins/`), and `git-allowlist.toml`. Each wrapper passes target paths to `files.mkConfig`, which symlinks `sources/<target>` to `$out/<target>`.

### Infrastructure (`infra/`)

OpenTofu config managing GitHub repository settings (visibility, Actions permissions, branch protection, security analysis, Actions secrets) via the `integrations/github` provider. State is local (`*.tfstate` gitignored) — bootstrap is import-based, not greenfield apply, since the repository already exists. The `infra` devshell helper runs `tofu` against this directory; see `infra/README.md` for the import sequence.

### CI (`.github/workflows/`)

`ci.yml` runs `nix flake check -L --keep-going` on ubuntu + macos, using the `runeword-terminal` cachix cache and a `PERMEANCE_TOKEN` secret to fetch the private `permeance` input. The matrix fans into a stable-named `check` aggregate job — that name is the required-status context in branch protection (managed by `infra/`), so don't rename it. `dependabot-auto-merge.yml` enables auto-merge (squash) on non-major Dependabot PRs; branch protection's required check gates the actual merge.

## Conventions

- `flake.nix` stays thin — real logic lives in `packages/`, `wrappers/`, `lib/`, `modules/`, `overlays/`, `devshells/`.
