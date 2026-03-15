# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Runeword Terminal is a reproducible terminal environment built with Nix flakes. It wraps Alacritty with a fully configured shell ecosystem (Zsh, Tmux, Starship, and 40+ CLI tools) into a single deployable unit. It supports Linux and macOS.

## Development Commands

Enter the dev shell first: `nix develop`

From within the dev shell:
- `dev` — Run Alacritty in development mode (symlinks config for live reload)
- `bdl` — Run Alacritty in bundled mode (config copied into Nix store, requires rebuild)
- `h` — Show help

Building and running directly:
- `nix build` — Build the bundled terminal package
- `nix run .` — Run bundled mode
- `TERMINAL_CONFIG_DIR="$PWD/config" nix run .#dev --impure` — Run dev mode without dev shell

## Formatting and Linting

Pre-commit hooks via lefthook (remote config from github:Runeword/lefthook):
- **Nix**: `nixfmt-rfc-style` (nixfmt with RFC style)
- **Shell**: `shfmt` (2-space indent per .editorconfig)
- **TOML**: `taplo`
- **Shell analysis**: `shellcheck`, `shellharden` (available in dev shell)

All formatters are available in the dev shell. Run them manually:
- `nixfmt <file.nix>`
- `shfmt -w <file.sh>`
- `taplo fmt <file.toml>`

## Architecture

### Two Deployment Modes

The flake produces a wrapped Alacritty terminal with all tools on its PATH:

1. **Development mode** (`apps.dev`): `configPath` is read from `$TERMINAL_CONFIG_DIR` env var at build time. Config files are symlinked, so edits take effect immediately without rebuild.
2. **Bundled mode** (`apps.default`/`packages.default`): `configPath` points to `./config` in the Nix store. Fully isolated but requires `nix build` after config changes.

There's also a Home Manager module (`homeManagerModules.default`) for integration into NixOS/home-manager configurations.

### Build Pipeline

`flake.nix` is the entry point. The build flow:

1. **`flake.nix`** calls `mkTerminal` which imports `wrappers/alacritty.nix`
2. **`wrappers/alacritty.nix`** wraps Alacritty with fonts, shell (Zsh), and a combined `tools` PATH
3. **`tools`** = `packages/` (raw CLI tools) + `wrappers/` (config-wrapped tools like zsh, tmux, bat, delta, ripgrep, fd, starship, navi)
4. Each **wrapper** (e.g., `wrappers/zsh.nix`) uses `pkgs.symlinkJoin` + `pkgs.makeWrapper` to inject config paths and env vars into the tool
5. **`lib/files.nix`** provides `sync`/`link`/`copy` helpers that decide whether to symlink (dev mode) or copy (bundled mode) config files based on whether `rootPath` starts with `/nix/store`

### Key Directories

- **`config/`** — All dotfiles and shell configuration (zsh, bash, tmux, alacritty, starship, shell aliases/functions/variables)
- **`config/shell/`** — Shared shell config loaded by both zsh and bash: `aliases.sh`, `variables.sh`, `xdg.sh`, and `functions/` directory with per-topic function files (git.sh, tmux.sh, nix.sh, fm.sh, etc.)
- **`wrappers/`** — Nix expressions that wrap each tool with its config. Each `.nix` file follows the same pattern: symlinkJoin + makeWrapper
- **`packages/`** — Package lists split into `commons.nix` (cross-platform), `linux.nix`, and `darwin.nix`
- **`overlays/`** — Nixpkgs overlays for pinning specific packages to older/newer nixpkgs versions
- **`modules/terminal.nix`** — Home Manager module exposing `programs.terminal.enable` and `programs.terminal.configPath`
- **`lib/files.nix`** — File sync utilities that bridge dev/bundled modes

### Shell Configuration Loading Order

Zsh (`config/zsh/.zshrc`) loads in this order:
1. XDG base directory setup (`shell/xdg.sh`)
2. Environment variables (`shell/variables.sh`)
3. Shell aliases (`shell/aliases.sh`)
4. All function files from `shell/functions/`
5. Zsh plugins (autosuggestions)
6. Starship prompt init
7. Direnv hook

### Conventions

- Nix files use `nixfmt-rfc-style` formatting
- Shell scripts must be POSIX-compliant
- Shell scripts use 2-space indentation
- Shell functions are prefixed with `__` (e.g., `__git_add`, `__tmux_kill`)
- Shell function files are organized by topic in `config/shell/functions/`
- Multiple nixpkgs inputs (unstable, 24.05, 25.11) are used via overlays to pin specific package versions
