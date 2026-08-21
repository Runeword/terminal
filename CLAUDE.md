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
- `packages.firefox-mcp` / `packages.mobile-mcp` — standalone MCP server packages from `packages/custom/`, kept as Nix derivations because each also needs a sidecar binary on PATH (geckodriver, adb). The other three MCP servers are **not** Nix-packaged: `nix-mcp`, `aws-api-mcp`, and `google-workspace-mcp` are launched via `uvx` (pinned version, fetched from PyPI at run time) straight from their plugin `.mcp.json`, exactly as `figma-mcp` is launched via `npx`; the `uv`/`nodejs`/`python312` runtimes they need sit on claude's PATH (see `wrappers/claude.nix`). The other `packages/custom/` entries are Go binaries with no flake output of their own: `packages/custom/default.nix` puts `git-branches`, `claude-session-status`, `claude-context`, and `fm-query` (the fzf-query compiler shared by `sources/`'s `fm_rg.sh` and `fm_preview.sh`) into the tools env (so they're on PATH inside the terminal), while `claude-statusline`, `claude-docs-guard`, `git-allowlist-hook`, and `git-shim` are consumed only inside the `claude` wrapper (see below).
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
  - **The `claude` wrapper** (`wrappers/claude.nix`) carries the most wiring: it passes `--settings $PERMEANCE_ROOT/.claude/settings.json`, puts formatters/LSPs, the Nix-packaged MCP servers (firefox-mcp, mobile-mcp) plus the runtimes (uv/uvx, nodejs, python312) that launch the other MCP servers from their plugin `.mcp.json`, and the custom Go binaries on claude's PATH (the `sources/.claude/settings.json` hooks and statusline invoke them by bare name — `claude-session-status`, `claude-docs-guard`, `git-allowlist-hook`, `claude-format`, `claude-statusline`), and prefixes `git-shim` — a binary named `git` that enforces `sources/.claude/git-allowlist.toml` before exec'ing the wrapped git — onto claude's PATH only, so claude's whole process tree gets allowlisted git while the interactive shell keeps the ordinary wrapped git.
- Each wrapper attaches a `passthru.tests.smoke` derivation built via `permeance.tests.mkSmoke` (from the `permeance` flake input). The harness exposes `ok` / `fail` shell helpers and an isolated `$HOME` (the Nix sandbox sets `HOME=/homeless-shelter`, which breaks tools that touch XDG paths). Each smoke test verifies **behaviourally** that the bundled config loads correctly — invoke the wrapper and observe. The runtime `$PERMEANCE_ROOT` override can't be exercised inside the sandbox (no live working tree is reachable there), so it isn't tested.

### The claude sandbox (`sources/.config/shell/scripts/claude-sandbox.bash`)

On Linux, `__claude` (in `sources/.config/shell/functions/claude.bash`) never runs `claude` directly — it prefixes the launcher above, which re-execs into an unprivileged bubblewrap namespace. **The gate fails closed**: a missing `bwrap` or a non-executable launcher aborts with a message rather than starting an unsandboxed claude, and `CLAUDE_SANDBOX=0` is the explicit escape hatch, not a fallback. Claude Code's own `/sandbox` is not used here because its Linux seccomp filter blocks `socket(AF_UNIX, …)`, which severs the nix-daemon socket; it also only ever wrapped Bash, while this wraps the whole process tree — file tools, hooks, and MCP servers alike.

What that means when working in this repo:

- **`sources/` is read-only inside a sandboxed session.** It is `--ro-bind`ed on top of the writable cwd, because the shell sources it on every launch — a write fails with `EROFS`. The normal way to change it from inside the sandbox is the scratch-copy workflow below; `CLAUDE_SANDBOX_UNLOCK_SOURCES=1 __claude` (the `cu` alias) and a plain terminal remain the escape hatches, and `cu` is still the only route for `.claude/git-allowlist.toml`, which the git-shim re-reads on every git call. That flag lifts this one lock and nothing else: it binds `$PERMEANCE_TREE` read-write *explicitly*, so it works from any cwd, not only from the project that happens to contain the tree. `$PWD/.direnv`, `$PWD/.git/{hooks,config}`, `lefthook*.yml`, and direnv's `source_url` CAS are host-executed too, and stay re-pinned read-only unconditionally — a session editing shell config is never editing those, so no flag should trade them away together. (Cost: `git config`/`git remote` writes are refused inside the sandbox; reads, staging, and checkout are unaffected.) In bundled mode `$PERMEANCE_TREE` resolves to the wrapper's store path, so the flag has nothing to unlock and says so.
- **The cwd is the writable region**, so the launcher refuses to start from `$HOME`, an ancestor of it, an XDG root, or inside a tree the desktop session executes at login. `--check-cwd` runs exactly that gate and exits, which is how `claude.bash` reports a refusal from the calling shell (a `tmux new-window` pane clears on death).
- **`~/.cache/nix` is a private tmpfs inside the sandbox**, so nix's eval/fetcher caches start cold each session and cannot be poisoned for the host. `~/.ssh` is replaced by a sanitized copy (config, its `Include`s, `known_hosts`, and one `.pub` per `IdentityFile`); auth still works through the re-bound agent socket, but no private key enters the namespace.
- **The network is deliberately not isolated** — bwrap offers no domain filtering — so this is a boundary against filesystem damage and credential reads, not against exfiltration. Nor is the nix-daemon socket: if the launching user is in nix's `trusted-users`, that socket is a root-equivalent hole and the launcher says so at startup.
- macOS gets Claude Code's built-in Seatbelt sandbox instead (bubblewrap is Linux-only, and Seatbelt can allow the nix-daemon socket by path). It is expressed as `sources/.claude/settings.darwin.json`, merged into the provisioned profile by `__claude_provision_darwin_sandbox`.

The header comment in the launcher is the authoritative description of the boundary, including what it deliberately does *not* cover.

#### Editing `sources/` from inside a sandboxed session

Do **not** hand-author patches for `sources/`. A hand-written diff can't be re-read (after handing it over, `sources/` on disk is unchanged, so the next `Read` returns pre-patch content and turn-2 edits are generated against stale state), can't be linted, and is a *prediction* about line numbers and context that is only validated when the user runs `git apply`. Work in a scratch copy instead, and hand over a generated diff:

1. Copy `cp -a sources/. "$SCRATCH/sources-edit/"` (`$SCRATCH` = the session scratchpad). Re-copy before **each** handover if `sources/` may have changed since the last copy — the user applied an earlier turn's patch, or a linter/auto-commit ran. A copy taken once at the start of a multi-turn task goes stale, and applying from it can revert or delete whatever `sources/` gained meanwhile.
2. Edit `$SCRATCH/sources-edit/…` with the normal Edit/Write tools. Once the copy exists, read from the scratch tree rather than `sources/`, so re-reads reflect the edits.
3. Validate in place: `bash -n` and `shellcheck` for shell files, `nix-instantiate --parse` for `.nix`. All three work inside the sandbox. `smoke` / `nix flake check` build from `./sources`, not the scratch tree, so they only mean anything *after* the user applies.
4. Hand over, with absolute paths filled in, to run in a plain terminal — review, then apply **only the files you changed**:

   ```
   git diff --no-index sources/ <scratch>/sources-edit/     # review, delta-rendered
   cp <scratch>/sources-edit/<path> sources/<path>          # apply, one line per changed file
   ```

   Never `rsync -a --delete <scratch>/sources-edit/ sources/`. A whole-tree mirror from the scratch is drift-blind: anything `sources/` gained since the copy (plugin dirs, an earlier applied patch, linter output) is silently deleted or reverted, and the "read the diff first" habit does not reliably catch it — it didn't. Per-file `cp` touches nothing else. `sources/` is git-tracked and committed, so `git status` / `git diff` review the result and `git checkout -- sources` undoes a bad apply; if a change genuinely removes a file, `rm` it explicitly. For automatic drift detection — a conflict instead of a silent overwrite when `sources/` moved under a file you edited — apply a *generated* patch (not hand-authored, so in bounds) with `git apply --3way` instead of `cp`.

The copy is safe because everything in the tree is resolved by the host through the absolute `$PERMEANCE_TREE` path, so a copy at any other path is never sourced, and `sources/` itself contains no `.envrc`, `lefthook*`, or `flake.nix`. This is also why a `git worktree` is **not** a substitute: a worktree reproduces `lefthook.yml`, `.envrc`, and `flake.nix` at paths none of the launcher's relocks cover (they pin `$PWD/lefthook.yml`, `$PWD/.git/config`, `$PWD/.direnv` by exact path), so running `lefthook` or `cd`-ing into it on the host would execute sandbox-written content.

Only `sources/` needs this. The rest of the repo — `CLAUDE.md`, `flake.nix`, `wrappers/`, `packages/`, `lib/`, `devshells/`, `modules/`, `overlays/`, `infra/` — is directly writable. `.git/config`, `.git/hooks`, and `lefthook*.yml` are refused unconditionally and no workflow lifts them.

### Overlays (`overlays/default.nix`)

Two overlays are applied (composed in `overlays/default.nix`): `channel-pins.nix` pins `awscli2` to the `nixpkgs-24-05` input; `tmux.nix` source-pins `tmux` to 3.6a via `overrideAttrs` + `fetchFromGitHub` (so we don't carry another nixpkgs input just to freeze that version).

### Sources tree (`sources/`)

The `sources/` tree mirrors what the wrapped tools see under `$HOME`: `sources/.config/` for XDG-style configs (alacritty, zsh, bash, tmux, bat, git, starship, delta, direnv, ignore, navi, nvim-fzf, readline, ripgrep, shell) and `sources/.claude/` for Claude Code settings, hooks, rules, MCP plugin manifests (`plugins/`), and `git-allowlist.toml`. Each wrapper passes target paths to `files.mkConfig`, which symlinks `sources/<target>` to `$out/<target>`.

### Infrastructure (`infra/`)

OpenTofu config managing GitHub repository settings (visibility, Actions permissions, branch protection, security analysis, Actions secrets) via the `integrations/github` provider. State is local (`*.tfstate` gitignored) — bootstrap is import-based, not greenfield apply, since the repository already exists. The `infra` devshell helper runs `tofu` against this directory; see `infra/README.md` for the import sequence.

### CI (`.github/workflows/`)

`ci.yml` runs `nix flake check -L --keep-going` on ubuntu + macos, using the `runeword-terminal` cachix cache and a `PERMEANCE_TOKEN` secret to fetch the private `permeance` input. The matrix fans into a stable-named `check` aggregate job — that name is the required-status context in branch protection (managed by `infra/`), so don't rename it. `dependabot-auto-merge.yml` enables auto-merge (squash) on non-major Dependabot PRs; branch protection's required check gates the actual merge.

## Testing

New code ships with the test its layer uses, and `smoke` (`nix flake check -L --keep-going -j auto`) must pass before a change is done — a change without its test is not finished. `smoke` builds every `checks.*` derivation; the terminal's smoke test alone pulls every tool in via `makeBinPath tools` (see `wrappers/alacritty.nix`), so the whole graph — wrappers, terminal, and each custom binary's `go test` — is exercised transitively. Match the mechanism to what you added:

- **A wrapper (`wrappers/*.nix`), new or changed** — attach `passthru.tests.smoke = permeance.tests.mkSmoke { name; description; script; }`. Presence is enforced: `lib/tests-unit.nix`'s `testAllWrappersHaveSmoke` fails the `unit-tests` check if any wrapper lacks one. Test **behaviourally** — invoke the wrapped binary and assert on an observable effect of the bundled config, not that a file exists — using the `ok`/`fail` helpers and isolated `$HOME` the harness provides (see `wrappers/fd.nix`: the bundled ignore hides `node_modules`; `wrappers/git.nix`: bundled global-config keys load). When a tool has no sandbox-friendly config probe (needs auth/network), a binary-executes check is the documented fallback (`wrappers/claude.nix`). Rewiring a wrapper's config means updating its smoke test to assert the new behaviour.

- **A Go binary (`packages/custom/<name>/`)** — add `main_test.go` beside `main.go`. `pkgs.buildGoModule` runs `go test` in its check phase, so the test runs on every build with no extra flake wiring — the binary is a build dependency of the wrappers/terminal that the checks build. Follow the table-driven, stdlib-`testing` style in `git-shim`, `git-allowlist-hook`, `claude-docs-guard`, `claude-session-status`, `claude-context`, and `fm-query`. (`git-branches`, `claude-statusline`, and `nvim-fzf-tree` ship none today — add one when you touch their logic.)

- **A pure-eval invariant or `lib/` helper** — add a `test*` attribute (`{ expr = …; expected = …; }`) to `lib/tests-unit.nix`; `pkgs.lib.runTests` runs it at eval time and `checks.unit-tests` fails the build (emitting the JSON failure list) on mismatch. Use this for structural facts about the flake, not for behaviour that needs a running binary.

- **Shell or config under `sources/`** — no unit harness covers it directly; validate syntax (`bash -n` and `shellcheck` for shell, `nix-instantiate --parse` for `.nix`) and, when the change has an observable effect, extend the owning wrapper's smoke test to assert it (the config is loaded behaviourally through that wrapper — e.g. a zsh change is exercised by `wrappers/zsh.nix`'s test).

Iterate on one check with `nix build .#checks.<system>.<name>` (e.g. `.#checks.x86_64-linux.fd`) before the full `smoke` run.

## Conventions

- `flake.nix` stays thin — real logic lives in `packages/`, `wrappers/`, `lib/`, `modules/`, `overlays/`, `devshells/`.
- New code ships with the test its layer uses, and `smoke` must pass before the change is done — see **Testing** above for which mechanism each layer uses.
