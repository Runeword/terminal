# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Runeword Terminal is a reproducible terminal environment built with Nix flakes. It wraps Alacritty with a fully configured shell ecosystem (Zsh, Tmux, Starship, and 40+ CLI tools) into a single deployable unit. It supports Linux and macOS.

## Development Commands

Enter the dev shell first: `nix develop`

From within the dev shell:
- `dev` — Run Alacritty in development mode (symlinks config for live reload)
- `bdl` — Run Alacritty in bundled mode (config copied into Nix store, requires rebuild)
- `tools <name>` — Run a binary from the tools package
- `h` — Show help

Building and running directly:
- `nix build` — Build the bundled terminal package
- `nix run .` — Run bundled mode
- `TERMINAL_CONFIG_DIR="$PWD/config" nix run .#dev --impure` — Run dev mode without dev shell

## Formatting and Linting

Pre-commit hooks via lefthook (remote config from github:Runeword/lefthook):
- **Nix**: `nixfmt-rfc-style` (nixfmt with RFC style)
- **Shell**: `shfmt` (2-space indent per .editorconfig)
- **Go**: go formatting and linting
- **TOML**: `taplo`
- **YAML**: yaml formatting
- **Shell analysis**: `shellcheck`, `shellharden` (available in dev shell)
- **Commit messages**: auto-msg module

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

1. **`flake.nix`** defines `mkTools` (packages + wrappers) and `mkTerminal` (imports `wrappers/alacritty.nix` with tools on PATH)
2. **`wrappers/alacritty.nix`** wraps Alacritty with fonts, shell (Zsh), and the combined `tools` PATH
3. **`tools`** = `packages/` (raw CLI tools + custom packages) + `wrappers/` (config-wrapped tools)
4. Each **wrapper** (e.g., `wrappers/zsh.nix`) uses `pkgs.symlinkJoin` + `pkgs.makeWrapper` to inject config paths and env vars into the tool
5. **`lib/files.nix`** provides `sync`/`link`/`copy` helpers that decide whether to symlink (dev mode) or copy (bundled mode) config files based on whether `rootPath` starts with `/nix/store`

Flake outputs also expose `lib.mkTerminal` and `lib.mkTools` for external consumers, and `packages.tools` for running individual tools via `nix run .#tools`.

### Key Directories

- **`config/`** — All dotfiles and shell configuration (alacritty, bash, bat, claude, delta, direnv, ignore, navi, nvim-fzf, readline, ripgrep, shell, starship, tmux, zsh)
- **`config/shell/`** — Shared shell config loaded by both zsh and bash: `aliases.sh`, `variables.sh`, `xdg.sh`, and `functions/` directory with per-topic function files (git.sh, tmux.sh, nix.sh, fm.sh, etc.)
- **`wrappers/`** — Nix expressions that wrap each tool with its config: zsh, tmux, bat, fd, ripgrep, bash, starship, delta, navi, nvim-fzf, claude. Each `.nix` file follows the same pattern: symlinkJoin + makeWrapper
- **`packages/`** — Package lists split into `commons.nix` (cross-platform), `linux.nix`, `darwin.nix`, and `custom/` (custom-built packages like firefox-mcp and git-branches)
- **`devshells/`** — Development shell definitions: `terminal.nix` (dev/bdl/tools commands), `languages.nix` (Go), `lefthook.nix` (formatting/linting hooks)
- **`overlays/`** — Nixpkgs overlays pinning specific packages to other nixpkgs versions (awscli2 to 24.05, tmux to 25.11) and overriding firebase-tools build config
- **`modules/terminal.nix`** — Home Manager module exposing `programs.terminal.enable` and `programs.terminal.configPath`
- **`lib/files.nix`** — File sync utilities that bridge dev/bundled modes

### Shell Configuration Loading Order

Zsh (`config/zsh/.zshrc`) loads in this order:
1. Deferred compinit setup (loaded on first tab press or after 1s background timer)
2. Key mappings (KEYS associative array)
3. Zsh plugins (from `$NIX_OUT_SHELL/.config/zsh/plugins/`)
4. Zsh hooks (precmd for newline before prompt)
5. XDG base directory setup (`shell/xdg.sh`)
6. Environment variables (`shell/variables.sh`)
7. History config, dircolors, autosuggestions
8. Word style, completion setup, keybindings
9. Shell aliases (`shell/aliases.sh`)
10. NVM (Node Version Manager)
11. Shell functions (all files from `shell/functions/`)
12. Custom widgets and key bindings (tab handler, leader aliases, fzf)
13. Starship prompt init (cached)
14. Direnv hook (cached)
15. Deferred plugins (navi, zoxide, fzf — loaded on first precmd)

### Conventions

- Nix files use `nixfmt-rfc-style` formatting
- Shell scripts use 2-space indentation
- Shell functions are prefixed with `__` (e.g., `__git_add`, `__tmux_kill`)
- Shell function files are organized by topic in `config/shell/functions/`
- Multiple nixpkgs inputs (unstable, 24.05, 25.11) are used via overlays to pin specific package versions
