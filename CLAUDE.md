# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Nix flake that builds a reproducible Alacritty terminal, bundled with a curated set of CLI tools (zsh, tmux, bat, ripgrep, fd, starship, delta, navi, claude-code, …) each wrapped so they load their configuration from this repo's `config/` tree.

## Common commands

Enter the dev shell first (`nix develop` — direnv will do it automatically via `.envrc`). The shell provides these helpers (defined in `devshells/terminal.nix`):

- `dev` — run Alacritty with configs **symlinked** from the working tree (`nix run .#dev --impure`, uses `TERMINAL_CONFIG_DIR=$PWD/config`). Config edits take effect immediately, no rebuild.
- `bdl` — run Alacritty in **bundled** mode (`nix run .`). Config is copied into the Nix store; changes require a rebuild.
- `tools <name> [args…]` — run any bundled CLI tool from the `packages.tools` env (e.g., `tools rg foo`).
- `smoke` — run wrapper smoke tests (`nix flake check -L --keep-going -j auto`); these are the per-wrapper `passthru.tests.smoke` derivations exposed via the `checks` output.
- `h` — print the helper list.

Other useful commands:

- `nix flake check` / `nix flake show` — validate or inspect outputs.
- `nix build .#default` / `nix build .#tools` — build the terminal or the tools env.
- `lefthook run pre-commit` — run git hooks locally (hooks live in `lefthook.local.yml`, which is a symlink into the Nix store).

## Architecture

`flake.nix` is the entry point. It defines three small helpers and wires them through `flake-utils.eachDefaultSystem`:

- `mkWrappers pkgs configPath` = `import ./wrappers` — attrset of wrapper derivations (used as a handle so wrappers can depend on each other, e.g. tmux ← zsh ← claude).
- `mkTools pkgs configPath wrappers` = `import ./packages` ++ `attrValues wrappers` — the full set of derivations.
- `mkTerminal pkgs configPath tools` = `import ./wrappers/alacritty.nix` with those tools on `PATH`.

Outputs:

- `packages.default` — the wrapped Alacritty (see `wrappers/alacritty.nix`: `runCommand` + `makeWrapper`, preserves the process name `alacritty`, injects `FONTCONFIG_FILE` on Linux, points `--config-file` at the synced config).
- `packages.tools` — a `buildEnv` of every tool, dispatched by a tiny shell script `tools <name>`. `pathsToLink = [ "/bin" ]` to avoid config-file collisions between wrappers (e.g. `fd` and `ripgrep` both ship a `.config/ignore`).
- `packages.firefox-mcp` / `packages.mobile-mcp` — standalone MCP server packages from `packages/custom/`.
- `apps.default` / `apps.dev` — `nix run` targets for bundled / dev mode. `apps.dev` is conditionally added only when `TERMINAL_CONFIG_DIR` is set (via `getEnv` + `--impure`), so `nix flake check` stays clean in pure mode.
- `checks.<wrapper>` — each wrapper's `passthru.tests.smoke` derivation, run by `nix flake check`.
- `lib.mkTerminal` / `lib.mkTools` — reusable builders for downstream flakes.
- `homeModules.default` — home-manager integration (see `modules/terminal.nix`, options under `programs.terminal`).

`devShells.default` is composed via `inputsFrom` from four sub-shells: `devshells/terminal.nix` (the `dev`/`bdl`/`tools`/`smoke`/`h` helpers above), `devshells/languages.nix`, `claude.devShells.${system}.ast-grep` (from the `claude` flake input), and `devshells/lefthook.nix`.

### The `files.mkConfig` abstraction (`lib/files.nix`)

`files.mkConfig name entries` returns a `pkgs.linkFarm` derivation that symlinks each entry's `source` (relative to `rootPath`, or absolute) at `target` under `$out`. Wrappers add this derivation to their `symlinkJoin` `paths`, which carries the configs into the wrapper's `$out` tree.

`rootPath` is the dev/bundled mode switch:

- A **Nix path** (`./config`) — bundled mode. Sub-paths are interpolated as proper store references and propagate into downstream closures.
- A **string** (`$TERMINAL_CONFIG_DIR`) — dev mode. Symlinks point at the live filesystem and `--impure` is required.

### Packages vs wrappers

- `packages/` — plain derivations we expose as-is. `default.nix` fans out to `commons.nix`, `custom/`, and one of `linux.nix` / `darwin.nix` based on `stdenv.isDarwin`.
- `wrappers/` — derivations that take an existing upstream package (e.g., `pkgs.alacritty`, `pkgs.claude-code`) and wrap it with `makeWrapper` / `symlinkJoin` + `wrapProgram` to inject config paths, PATH entries, env vars. `wrappers/default.nix` builds: `zsh`, `claude`, `tmux`, `bat`, `fd`, `ripgrep`, `bash`, `starship`, `delta`, `navi`, `nvim-fzf`. Wrappers can depend on each other (claude is passed into zsh; zsh is passed into tmux) — that is why `mkWrappers` returns an attrset rather than a list.
- Each wrapper attaches a `passthru.tests.smoke` derivation built via `lib/tests.nix`. The harness exposes `ok` / `fail` shell helpers and an isolated `$HOME` (the Nix sandbox sets `HOME=/homeless-shelter`, which breaks tools that touch XDG paths). Smoke tests run with no network and only see the wrapper's own store output — dev-mode symlinks to a working tree are unreachable inside the sandbox.

### Overlays (`overlays/default.nix`)

Two overlays are applied: one pins `awscli2` to nixpkgs-24.05 and `tmux` to nixpkgs-25.11; the other overrides `firebase-tools` to build against Node 20. Both follow the `final: prev:` convention — `prev` is used when redefining existing attributes.

### Config tree (`config/`)

Per-tool configuration (alacritty, zsh, bash, tmux, bat, starship, delta, direnv, ignore, navi, nvim-fzf, readline, ripgrep, shell). Each wrapper references its subdirectory via `files.mkConfig`. `config/claude/` holds Claude Code settings, hooks, and rules.

## Conventions

- `flake.nix` stays thin — real logic lives in `packages/`, `wrappers/`, `lib/`, `modules/`, `overlays/`, `devshells/`.
