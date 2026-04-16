# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Nix flake that builds a reproducible Alacritty terminal, bundled with a curated set of CLI tools (zsh, tmux, bat, ripgrep, fd, starship, delta, navi, claude-code, …) each wrapped so they load their configuration from this repo's `config/` tree.

## Common commands

Enter the dev shell first (`nix develop` — direnv will do it automatically via `.envrc`). The shell provides these helpers (defined in `devshells/terminal.nix`):

- `dev` — run Alacritty with configs **symlinked** from the working tree (`nix run .#dev --impure`, uses `TERMINAL_CONFIG_DIR=$PWD/config`). Config edits take effect immediately, no rebuild.
- `bdl` — run Alacritty in **bundled** mode (`nix run .`). Config is copied into the Nix store; changes require a rebuild.
- `tools <name> [args…]` — run any bundled CLI tool from the `packages.tools` env (e.g., `tools rg foo`).
- `h` — print the helper list.

Other useful commands:

- `nix flake check` / `nix flake show` — validate or inspect outputs.
- `nix build .#default` / `nix build .#tools` — build the terminal or the tools env.
- `lefthook run pre-commit` — run git hooks locally (hooks live in `lefthook.local.yml`, which is a symlink into the Nix store).

## Architecture

`flake.nix` is the entry point. It defines two small helpers and wires them through `flake-utils.eachDefaultSystem`:

- `mkTools pkgs configPath` = `import ./packages` ++ `import ./wrappers` — the full set of derivations.
- `mkTerminal pkgs configPath` = `import ./wrappers/alacritty.nix` with those tools on `PATH`.

Outputs:

- `packages.default` — the wrapped Alacritty (see `wrappers/alacritty.nix`: `runCommand` + `makeWrapper`, preserves the process name `alacritty`, injects `FONTCONFIG_FILE` on Linux, points `--config-file` at the synced config).
- `packages.tools` — a `buildEnv` of every tool, dispatched by a tiny shell script `tools <name>`.
- `apps.default` / `apps.dev` — `nix run` targets for bundled / dev mode (dev reads `TERMINAL_CONFIG_DIR` via `--impure`).
- `lib.mkTerminal` / `lib.mkTools` — reusable builders for downstream flakes.
- `homeManagerModules.default` — home-manager integration (see `modules/terminal.nix`, options under `programs.terminal`).

### The `files.sync` abstraction (`lib/files.nix`)

`files.sync sourceStr targetStr` is the central dev/bundled mode switch:

- If `rootPath` (the `configPath`) is **not** under `/nix/store`, it emits a **symlink** into the live config dir (dev mode).
- If it **is** under `/nix/store`, it **copies** (bundled mode).

Every wrapper in `wrappers/*.nix` uses this to drop configuration into its output, which is what makes `dev` vs `bdl` work without duplicating derivation logic.

`files.runtimeLink` is a variant used by the Claude wrapper to create symlinks into `$XDG_CONFIG_HOME` at runtime rather than build time (so settings.json can be mutable at runtime).

### Packages vs wrappers

- `packages/` — plain derivations we expose as-is. `default.nix` fans out to `commons.nix`, `custom/`, and one of `linux.nix` / `darwin.nix` based on `stdenv.isDarwin`.
- `wrappers/` — derivations that take an existing upstream package (e.g., `pkgs.alacritty`, `pkgs.claude-code`) and wrap it with `makeWrapper` / `symlinkJoin` + `wrapProgram` to inject config paths, PATH entries, env vars. `wrappers/default.nix` builds `zsh`, `tmux`, and `claude` with shared handles (tmux depends on zsh; claude gets its own tool sub-env).

### Overlays (`overlays/default.nix`)

Two overlays are applied: one pins `awscli2` to nixpkgs-24.05 and `tmux` to nixpkgs-25.11; the other overrides `firebase-tools` to build against Node 20. Both follow the `final: prev:` convention — `prev` is used when redefining existing attributes.

### Config tree (`config/`)

Per-tool configuration (alacritty, zsh, bash, tmux, bat, starship, delta, direnv, ignore, navi, nvim-fzf, readline, ripgrep, shell). Each wrapper references its subdirectory via `files.sync`. `config/claude/` holds Claude Code settings, hooks, and rules.

## Conventions

- **Follow the Nix rules in `config/claude/rules/nix.md`.** That file is auto-loaded into Claude's context and spells out the project's Nix style (no `rec`, no `with` at top level, `lowerCamelCase`, hyphenated filenames, `nixfmt-rfc-style`, 2-space indent, `meta` last, `lib.mkOption` with explicit types, `callPackage` pattern, `prev` vs `final` in overlays, etc.). Treat violations as bugs.
- `flake.nix` stays thin — real logic lives in `packages/`, `wrappers/`, `lib/`, `modules/`, `overlays/`, `devshells/`.
- `flake.lock` is committed. Never gitignore it.
- `README.md` is **regenerated daily** by `.github/workflows/docs.yml` (GPT-4.1 via `actions/ai-inference` reads `CLAUDE.md` + `flake.nix` with the prompt in `scripts/docs-prompt.txt`). Don't hand-edit README.md — edit this file or the flake and let CI rewrite it.
