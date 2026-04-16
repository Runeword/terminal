# Runeword Terminal: A Reproducible Nix-Flakes Terminal Environment

This project provides a fully reproducible terminal environment, built with Nix flakes. It wraps the Alacritty terminal emulator with a comprehensive shell ecosystem, including Zsh, Tmux, Starship, and over 40 essential CLI tools, into a single, deployable unit. Designed for both Linux and macOS, it ensures a consistent and efficient development experience across different machines.

## Quick Start

To get started with the Runeword Terminal, you have a few options depending on whether you prefer a development setup with live config reloading or a fully isolated bundled mode.

### 1. Development Mode

In development mode, your local configuration files are symlinked into the Nix store. This allows for immediate application of changes without requiring a full flake rebuild.

**Standalone Run:**

```shell
# Clone the repository
git clone git@github.com:Runeword/terminal.git && cd terminal

# Enter the development shell
nix develop

# Run Alacritty in development mode
dev
```

**Home Manager Integration:**

Add the flake input to your `flake.nix`:

```nix
# flake.nix
inputs.runeword-terminal.url = "github:Runeword/terminal";
```

Then, enable the module in your `home.nix` and point it to your local config:

```nix
# home.nix
imports = [
  inputs.runeword-terminal.homeManagerModules.default
];

programs.terminal.enable = true;
programs.terminal.configPath = "${config.home.homeDirectory}/terminal/config"; # Replace with your config path
```

### 2. Bundled Mode

In bundled mode, the terminal configuration is copied directly into the Nix store. This provides maximum isolation and reproducibility, but any changes to the configuration require a `nix build` before they take effect.

**Standalone Run:**

```shell
# Run Alacritty directly from the flake
nix run "github:Runeword/terminal"
```

**Home Manager Integration:**

Add the flake input to your `flake.nix`:

```nix
# flake.nix
inputs.runeword-terminal.url = "github:Runeword/terminal";
```

Then, enable the module in your `home.nix` (without specifying `configPath`):

```nix
# home.nix
imports = [
  inputs.runeword-terminal.homeManagerModules.default
];

programs.terminal.enable = true;
# No configPath specified, so it uses the bundled config
```

### Useful Commands within `nix develop`

Once you're in the `nix develop` shell:

*   `dev`: Run Alacritty in development mode (symlinks config for live reload).
*   `bdl`: Run Alacritty in bundled mode (config copied into Nix store, requires rebuild).
*   `tools <name>`: Run a binary from the bundled `tools` package (e.g., `tools yazi`).
*   `h`: Display a quick help message for these commands.

## Architecture Overview

The project is structured as a Nix flake, providing a declarative and reproducible way to manage the terminal environment.

### Deployment Modes: Dev vs. Bundled

The core idea revolves around two deployment strategies:

1.  **Development Mode (`apps.dev` / `lib.mkTerminal { configPath = ... }`)**: This mode is optimized for active development of the terminal configuration. When `configPath` is explicitly set (typically to a local path like `$PWD/config`), configuration files are *symlinked* into the Nix store. This means any changes you make to your local config files (e.g., in `config/alacritty/alacritty.toml`) are immediately reflected when you restart the `dev` environment, without needing a `nix build`. It uses an `--impure` build for flexibility during development.

2.  **Bundled Mode (`apps.default` / `packages.default` / `lib.mkTerminal {}`)**: This mode ensures complete isolation and reproducibility. When `configPath` is not specified, the project defaults to using the `config/` directory within its own source. In this scenario, configuration files are *copied* into the Nix store. Any modifications require a `nix build` (or re-entering `nix develop` and running `bdl`) to incorporate changes into the deployed environment. This is ideal for production deployments or when you want a completely frozen setup.

### Build Pipeline

The `flake.nix` acts as the entry point, orchestrating the build process:

1.  **`flake.nix`**: Defines `mkTools` and `mkTerminal` helper functions. `mkTools` assembles the core CLI utilities and wrapped tools. `mkTerminal` then takes these tools and wraps Alacritty itself, ensuring all utilities are available on Alacritty's `$PATH`.
2.  **`wrappers/alacritty.nix`**: This key wrapper takes the configured shell (Zsh), fonts, and the combined `tools` package, integrating them into the Alacritty executable.
3.  **`tools`**: This is a meta-package comprised of:
    *   **Raw CLI tools**: Defined in `packages/` (e.g., `yazi`, `git`, `awscli2`).
    *   **Config-wrapped tools**: Defined in `wrappers/` (e.g., `zsh`, `tmux`, `bat`). Each wrapper injects specific configurations and environment variables.
4.  **Individual Wrappers (`wrappers/*.nix`)**: Each wrapper typically uses `pkgs.symlinkJoin` and `pkgs.makeWrapper` to package the base tool along with its configuration files and necessary environment variables.
5.  **`lib/files.nix`**: Provides `sync`, `link`, and `copy` helpers that intelligently decide whether to symlink (development mode) or copy (bundled mode) configuration files, based on whether the `rootPath` is already in the Nix store.

Flake outputs also expose `lib.mkTerminal` and `lib.mkTools` for external consumers, and `packages.tools` for running individual tools via `nix run .#tools`.

### Key Directories

*   **`config/`**: Contains all dotfiles and configurations for individual tools (Alacritty, Bash, Bat, Claude, Delta, Direnv, Navi, Nvim-fzf, Readline, Ripgrep, Starship, Tmux, Zsh) and shared shell scripts.
*   **`config/shell/`**: Houses shared shell configuration (`aliases.sh`, `variables.sh`, `xdg.sh`) and a `functions/` directory, organizing common shell functions by topic (e.g., `git.sh`, `tmux.sh`, `nix.sh`, `fm.sh`).
*   **`wrappers/`**: Nix expressions that wrap each tool with its specific configuration and environment variables. This is where the magic of integrating configuration with binaries happens.
*   **`packages/`**: Defines lists of software packages. This is split into `commons.nix` (cross-platform essentials), `linux.nix` and `darwin.nix` (OS-specific tools), and `custom/` (for custom-built packages like `firefox-mcp` and `git-branches`).
*   **`devshells/`**: Nix development shell definitions, including `terminal.nix` (providing `dev`, `bdl`, `tools` commands), `languages.nix` (for Go development), and `lefthook.nix` (for Git pre-commit hooks).
*   **`overlays/`**: Nixpkgs overlays used to pin specific package versions (e.g., `awscli2` from `nixpkgs-24-05`, `tmux` from `nixpkgs-25-11`) or override their build configurations (e.g., `firebase-tools`).
*   **`modules/terminal.nix`**: The Home Manager module that integrates this flake into Home Manager configurations, providing `programs.terminal.enable` and `programs.terminal.configPath` options.
*   **`lib/files.nix`**: Contains utility functions for managing file synchronization (`sync`, `link`, `copy`), crucial for the development/bundled mode distinction.

### Shell Configuration Loading Order (Zsh)

The Zsh configuration, defined in `config/zsh/.zshrc`, loads in a specific sequence to ensure correct setup:

1.  **Deferred Compinit**: Loaded on the first tab press or after a 1-second background timer for faster startup.
2.  **Key Mappings**: Defines an associative array of common key sequences.
3.  **Zsh Plugins**: Sources plugins from `$NIX_OUT_SHELL/.config/zsh/plugins/`.
4.  **Zsh Hooks**: Sets up `precmd` hooks, notably for adding a newline before the prompt.
5.  **XDG Base Directory Setup**: Initializes environment variables according to the XDG Base Directory Specification (`shell/xdg.sh`), with directory creation backgrounded.
6.  **Environment Variables**: Sources general environment variables from `shell/variables.sh`.
7.  **History & Dircolors**: Configures Zsh history and loads cached `dircolors` output.
8.  **Word Style & Completion**: Sets up word parsing and completion behavior.
9.  **Shell Aliases**: Loads shared aliases from `shell/aliases.sh`.
10. **NVM (Node Version Manager)**: Initializes NVM.
11. **Shell Functions**: Sources all function files from `shell/functions/`.
12. **Custom Widgets & Key Bindings**: Defines and binds custom Zsh widgets (e.g., tab handler, leader aliases, fzf integration).
13. **Starship Prompt**: Initializes the Starship prompt (cached for performance).
14. **Direnv Hook**: Initializes the Direnv hook (cached).
15. **Deferred Plugins**: Loads non-critical plugins like `navi`, `zoxide`, and `fzf` key bindings after the first prompt, further optimizing startup.

### Conventions

*   Nix files adhere to `nixfmt-rfc-style` formatting.
*   Shell scripts use 2-space indentation.
*   Shell functions are prefixed with `__` (e.g., `__git_add`, `__tmux_kill`).
*   Shell function files are organized by topic within `config/shell/functions/`.
*   Multiple Nixpkgs inputs (unstable, 24.05, 25.11) are utilized via overlays to precisely pin specific package versions.

## Available Tools and Wrappers

The terminal environment comes pre-equipped with a robust set of tools and custom wrappers:

### Core CLI Utilities

A wide range of essential CLI tools are included:

*   **File Management**: `yazi` (TUI file manager), `fd`, `ripgrep`, `zoxide`, `gomi` (trash bin).
*   **System Info & Monitoring**: `htop`, `btop`, `procs`, `fastfetch`, `hwinfo`, `dmidecode`, `ncdu`, `erdtree`.
*   **Git Enhancements**: `git`, `lazygit` (TUI), `gitleaks`, `onefetch`, `lefthook` (hooks manager), `git-absorb`, `zsh-forgit`.
*   **Cloud & Development**: `awscli2`, `google-cloud-sdk`, `firebase-tools`, `ngrok`, `cursor-cli`, `gemini-cli-bin`, `ast-grep`, `sqlite`.
*   **Networking & Connectivity**: `sshs`, `qrcp`, `lazydocker`, `docker-compose`.
*   **Archiving**: `ouch`, `unzip`.
*   **Nix-specific**: `nix-prefetch-docker`, `nix-search-tv`, `nix-init`, `cachix`, `devenv`, `direnv`.
*   **Misc**: `fzf`, `jq`, `wget`, `tree`, `glow`, `chezmoi`, `pass`, `httrack`, `bitwarden-cli`, `gh`, `asciinema`, `lux`.

### Wrapped Tools

Many of the core tools are wrapped with their configurations:

*   **`alacritty`**: The terminal emulator itself, configured for appearance, fonts, and keybindings (see `config/alacritty/alacritty.toml`).
*   **`zsh`**: Configured with aliases, functions, plugins (like `discard-keys`, `zsh-autosuggestions`), and prompt settings via Starship (see `config/zsh/.zshrc`, `config/shell/`).
*   **`bash`**: Configured with a subset of shared shell settings and functions for Bash users (see `config/bash/.bashrc`).
*   **`tmux`**: Configured for session management, keybindings, and plugins like `tmux-resurrect` (see `config/tmux/tmux.conf`).
*   **`starship`**: Provides a customized, fast, and minimal shell prompt (see `config/starship.toml`).
*   **`bat`**: A `cat` clone with syntax highlighting and Git integration, using a custom theme (`config/bat/`).
*   **`delta`**: A viewer for Git diffs, with enhanced syntax highlighting (see `config/delta/config`).
*   **`fd`**: A faster and user-friendly alternative to `find`, respecting a shared ignore file (`config/ignore`).
*   **`ripgrep` (`rg`)**: A line-oriented search tool, faster than `grep`, also respecting the shared ignore file (`config/ripgrep/ripgreprc`).
*   **`navi`**: An interactive cheat sheet tool, pre-populated with common commands (see `config/navi/`).
*   **`nvim-fzf`**: A specialized Neovim setup optimized for FZF-based file navigation and previewing.
*   **`claude`**: An AI assistant CLI, pre-configured with rules, hooks for formatting, and status line integration (see `config/claude/`). This also includes MCP (Mobile Control Protocol) plugins for Firefox and mobile device automation, and LSP (Language Server Protocol) plugins for Nix and TypeScript.

### Custom Packages

The `packages/custom/` directory contains custom-built Go programs:

*   **`claude-statusline`**: A Go program used by the Claude wrapper to generate status line information.
*   **`git-branches`**: A Go program providing enhanced FZF-powered Git branch and worktree management.
*   **`firefox-mcp`**: A Mozilla-developed MCP server for Firefox DevTools automation.
*   **`mobile-mcp`**: An MCP server for mobile device automation via ADB and WebDriverAgent.

## Customization Guide

Customizing your Runeword Terminal environment is straightforward, especially when using the development mode.

### 1. Modifying Configuration Files

The primary way to customize is by directly editing the files in the `config/` directory of this repository.

*   **Development Mode**: If you're running Alacritty in `dev` mode (either standalone via `nix develop && dev` or through Home Manager with `configPath` pointing to your local `config/` directory), any changes you make to these files will take effect immediately upon restarting Alacritty (or the specific wrapped tool, if it's a daemon).

*   **Bundled Mode**: If you're using the bundled mode (either `nix run .` or Home Manager without `configPath`), you'll need to rebuild the flake after making changes for them to be applied.

    ```bash
    # After modifying files in config/
    nix build .
    # Or, if in a dev shell:
    bdl # to run the new bundled version
    ```

### 2. Customizing Shell Functions and Aliases

*   **Shell Functions**: Add or modify files within `config/shell/functions/`. These are automatically sourced by both Zsh and Bash.
*   **Aliases**: Edit `config/shell/aliases.sh`. For advanced fuzzy-searchable aliases, you can also modify `config/shell/functions/leader-aliases`.

### 3. Adding/Removing Packages

You can easily extend or pare down the list of included packages.

*   **For all systems**: Edit `packages/commons.nix`.
*   **For Linux-specific tools**: Edit `packages/linux.nix`.
*   **For macOS-specific tools**: Edit `packages/darwin.nix`.
*   **For custom-built Go programs**: Add new Nix derivations to `packages/custom/`.

After modifying package lists, remember to rebuild or re-enter the development environment.

### 4. Customizing Wrappers

If you need to change how a specific tool is wrapped (e.g., adding a new environment variable or command-line flag), modify the corresponding `.nix` file in the `wrappers/` directory.

### 5. Home Manager Integration

If you integrate this flake as a Home Manager module:

*   You can set `programs.terminal.enable = true;` to enable the bundled configuration.
*   To manage the configuration yourself (recommended for customization), set `programs.terminal.configPath = "/path/to/your/local/terminal/config";` to symlink your local `config/` directory. This allows you to keep your dotfiles in source control and easily manage them.
