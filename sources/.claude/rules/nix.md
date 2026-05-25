---
paths:
  - "**/*.nix"
---

# Global Claude Instructions

## Nix Code Quality Rules

When writing, reviewing, or modifying Nix code, enforce the following rules derived from nix.dev best practices, the nixpkgs coding conventions, and community-established patterns. Point out violations and suggest corrections.

---

### Language Pitfalls

- **Avoid `rec`**: Recursive attribute sets (`rec { ... }`) cause hard-to-debug infinite recursion when a name is shadowed. Use `let ... in` instead, or name the set explicitly and use qualified references (`attrset.attr`).
- **Avoid `with`**: Do not use `with` at the top of a Nix file — static analysis cannot reason about names in scope, and multiple `with` blocks make name origins ambiguous. Use `let inherit (pkgs) curl jq; in` to bring specific names into scope. Small scopes (`buildInputs = with pkgs; [ ... ]`) are tolerable but `builtins.attrValues { inherit (pkgs) curl jq; }` is safer.
- **Avoid lookup paths**: Never use `<nixpkgs>` or other angle-bracket paths in production code — they depend on `$NIX_PATH` and are not reproducible. Pin nixpkgs explicitly. Exception: `$NIX_PATH` set from version control in a central location.
- **Quote URLs**: Always quote URL strings (`"https://..."`) — RFC 45 deprecated unquoted URLs.
- **Shallow merge pitfall**: The `//` operator merges shallowly — nested attribute sets are replaced entirely, not merged. Use `lib.recursiveUpdate` when deep merging is needed.
- **Reproducible source paths**: `src = ./.;` creates store paths derived from the parent directory name, causing impurity. Use `builtins.path { path = ./.; name = "fixed-name"; }` to derive the store path from a fixed name.
- **Import purity**: When importing nixpkgs, always set `config` and `overlays` explicitly (`import nixpkgs { config = {}; overlays = []; }`) to prevent impure defaults from `~/.config/nixpkgs/`.

---

### Naming & Formatting

- **Variable names**: `lowerCamelCase` for variables and attributes (e.g., `buildInputs`, `configPath`). Never `UpperCamelCase`, never `snake_case`.
- **File names**: Lowercase with hyphens between words (e.g., `all-packages.nix`, `default.nix`). Never camelCase for file names.
- **Package names**: `pname` must not contain uppercase letters. Should match upstream name. Use hyphens as separators.
- **Attribute names**: Should match `pname`. Prefix with underscore only if `pname` starts with a digit. Use underscores for version variants (e.g., `json-c_0_9`).
- **Formatting**: Use `nixfmt-rfc-style` as the canonical formatter. Use 2 spaces per indentation level in Nix expressions. Never use tabs. Shell code embedded in Nix uses 2 spaces (project convention) — otherwise nixpkgs convention is 4 spaces for embedded shell.
- **Attribute set style**: Multi-line sets have one attribute per line. Short sets may be on one line. Align attributes within a set.
- **`meta` placement**: The `meta` attribute set should always be placed last in derivations.

---

### Data Types & Expressions

- **Attribute sets — access**: Use `attrset.attr or default` for safe access with a fallback. Use `attrset ? attr` to test existence.
- **Attribute sets — `//` operator**: Right side wins. Only use for flat merges. See shallow merge pitfall above.
- **`inherit`**: Use `inherit attr;` instead of `attr = attr;`. Use `inherit (source) attr;` instead of `attr = source.attr;`. Prefer `inherit` for clarity but don't overuse — if you're inheriting many unrelated things, question whether the scope is right.
- **Lists**: Use `[ elem1 elem2 ]` — elements are whitespace-separated, no commas. Use `++` to concatenate.
- **Strings**: Use `"double quotes"` for simple strings. Use `''multi-line''` (two single-quotes) for multi-line strings, especially embedded shell. Interpolation: `"${expr}"`. Escape `$` in multi-line strings with `''$` and `''` with `'''`.
- **Paths**: Bare paths (e.g., `./foo.nix`) are resolved relative to the file. They copy into the Nix store when evaluated — don't use bare paths for large directories without filtering. Use `builtins.path` with `filter` or `lib.fileset` / `lib.sources` to exclude unwanted files.
- **Booleans**: Use `true`/`false` (lowercase). No truthy/falsy coercion — always use explicit boolean expressions.
- **`null`**: Use `null` for optional/absent values. Check with `x == null`, not truthiness.

---

### Functions & Patterns

- **Function syntax**: `param: body` for single arg. `{ arg1, arg2 }: body` for attribute set destructuring. `{ arg1, arg2, ... }: body` to allow extra attributes.
- **Default values**: `{ arg1 ? default, arg2 ? default }: body`. Prefer defaults over requiring callers to pass every attribute.
- **`@` pattern**: `args@{ arg1, arg2 }: body` or `{ arg1, arg2 }@args:` to bind both the whole set and destructured names. Useful when forwarding arguments.
- **`callPackage` pattern**: The standard way to compose packages in nixpkgs. Write package functions that take dependencies as arguments; let `callPackage` supply them from the package set. Never hardcode `import <nixpkgs>` inside package definitions.
- **`lib.mkOption`**: Use in modules to declare options with `type`, `default`, and `description`. Always specify a type.
- **`lib.mkIf`**: Use for conditional configuration in modules. Combine with `lib.mkMerge` for multiple conditional blocks.
- **Pipe operator**: Use `|>` (Nix 2.19+) for chaining transformations when it improves readability: `list |> map f |> filter g`. Don't force it — nested calls are fine when short.

---

### Derivations & Packaging

- **`mkDerivation`**: Use `stdenv.mkDerivation` as the standard builder. Set `pname` and `version` separately (not `name`). Use `meta` for description, license, maintainers, platforms.
- **`meta.description`**: Short, one sentence. Capitalize first word. No leading articles ("A", "The"). No package name. No trailing period.
- **`meta.license`**: Must match upstream. Use `lib.licenses.*` values. Use `lib.licenses.unfree` if unclear.
- **`meta.maintainers`**: Required for new packages.
- **`meta.mainProgram`**: Set to the primary executable name if the package has a single or obvious main binary.
- **Build inputs**: `nativeBuildInputs` for tools needed at build time (compilers, pkg-config, cmake). `buildInputs` for libraries linked at run time. Don't conflate them.
- **Fetchers**: Use nixpkgs fetchers (`fetchurl`, `fetchFromGitHub`, etc.). Prefer `sha256` hashes. Prefer HTTPS over `git://`. Use `mirror://` URLs where available.
- **Phases**: Override specific phases (`buildPhase`, `installPhase`, etc.) rather than replacing the entire build. Use `preBuild`, `postInstall`, etc. hooks for small additions.
- **`makeWrapper` / `wrapProgram`**: Use to inject runtime dependencies (PATH, environment variables) without patching binaries. `symlinkJoin` + `makeWrapper` is the standard pattern for wrapping existing packages.
- **Version strings**: Start with a digit. Use `{version}-unstable-{YYYY-MM-DD}` for unreleased commits. Default to `0-unstable-{date}` for packages with no prior release.

---

### Modules

- **Module structure**: A module is a function `{ config, lib, pkgs, ... }: { options = { ... }; config = { ... }; }`. Always accept `...` to allow future attribute additions.
- **Option declarations**: Always use `lib.mkOption` with a `type`. Common types: `lib.types.bool`, `lib.types.str`, `lib.types.int`, `lib.types.package`, `lib.types.listOf`, `lib.types.attrsOf`, `lib.types.submodule`.
- **Option definitions**: Use `lib.mkIf config.myModule.enable { ... }` to conditionally activate configuration.
- **`enable` option**: Standard pattern — `options.myModule.enable = lib.mkEnableOption "my module";`. All config should be gated behind this.
- **Avoid `imports` with computed paths**: Module `imports` are evaluated strictly before the module system resolves options. Never compute import paths from option values.
- **`lib.mkDefault` / `lib.mkForce`**: Use `mkDefault` to set low-priority defaults that users can override. Use `mkForce` sparingly and only when necessary — it overrides everything.
- **`lib.mkMerge`**: Use to combine multiple conditional config blocks: `config = lib.mkMerge [ (lib.mkIf condA { ... }) (lib.mkIf condB { ... }) ];`.

---

### Flakes

- **`flake.nix` should be thin**: Most Nix code should live in separate files imported by `flake.nix`. Don't put complex logic directly in the flake.
- **`flake.lock`**: Always commit it. This is what makes the build reproducible. Never `.gitignore` it.
- **Inputs**: Pin all inputs. Use `follows` to deduplicate shared inputs (e.g., `nixpkgs.follows` in downstream inputs).
- **Outputs structure**: `packages.<system>.<name>`, `apps.<system>.<name>`, `devShells.<system>.<name>`, `overlays.<name>`, `nixosModules.<name>`. Use `eachSystem` or `flake-utils`/`flake-parts` to reduce per-system boilerplate.
- **`self`**: The flake's own outputs. Use `self.packages.${system}` to reference sibling outputs. Don't use `self` during evaluation of the thing it refers to (infinite recursion).
- **Pure evaluation**: Flakes evaluate in pure mode by default — no access to `$NIX_PATH`, environment variables, or impure builtins. Don't rely on any.

---

### Overlays

- **Signature**: `final: prev: { ... }`. `prev` is nixpkgs before this overlay. `final` is the fixed point after all overlays.
- **Overriding existing packages**: Always use `prev` when redefining an existing attribute — using `final` causes infinite recursion (the attribute references itself).
- **Referencing dependencies**: Use `final` to reference packages that the overridden package depends on — this ensures downstream overrides are respected.
- **Rule of thumb**: Use `prev` to access the thing you're overriding. Use `final` for everything else. If in doubt, `prev` is safer.
- **Don't use `rec`**: In overlay return sets, `rec { ... }` bypasses the overlay mechanism. Packages defined with `rec` won't see overrides from later overlays. Use `final` references instead.
- **Preserve nested attributes**: When extending nested sets, use `//` to merge: `lib = prev.lib or {} // { newFn = ...; }`. For extensible scopes, use `prev.lib.extend` or `overrideScope`.
- **Don't parameterize overlays**: `{ boost }: final: prev: { ... }` locks in a dependency and breaks composability. Define symbols within the overlay instead.
- **No impure global overlays**: Don't rely on `~/.config/nixpkgs/overlays/` — it's an impurity that breaks reproducibility across machines.
- **Avoid extra nixpkgs imports**: Don't `import` different nixpkgs versions inside overlays — it pulls in all dependencies and breaks cross-compilation. Use `prev.callPackage` with the package function instead.

---

### Reproducibility & Hygiene

- **Filter sources**: Never pass unfiltered source trees to derivations — build artifacts, `.git/`, editor files, etc. cause unnecessary rebuilds. Use `lib.fileset`, `lib.sources.cleanSource`, or `builtins.path` with a `filter`.
- **Don't use `builtins.currentSystem`**: It's an impurity. Accept `system` as a parameter or use flake's per-system output structure.
- **IFD (Import From Derivation)**: Avoid in nixpkgs — it requires building during evaluation, which blocks parallel evaluation and breaks `nix-env -qa`. Acceptable in personal flakes when the tradeoff is understood.
- **Pinning**: Pin all external inputs (nixpkgs, flake inputs). Use `flake.lock` for flakes. For legacy Nix, use `niv` or `npins` or a pinned `fetchTarball`.

---

### Tooling & Linting

- **Formatter**: `nixfmt` (RFC style) is the official nixpkgs formatter. Run on all Nix files.
- **Linting**: Use `statix` to catch anti-patterns (unused `let` bindings, empty `inherit`, redundant patterns). Use `deadnix` to find dead code and unused function arguments.
- **Language server**: `nil` or `nixd` for editor integration (go-to-definition, diagnostics, completion).
- **Building**: Use `nix build`, `nix develop`, `nix run`. Use `nix flake check` to validate flake outputs. Use `nix flake show` to inspect output structure.
- **Debugging**: Use `nix repl` to interactively explore expressions. Use `builtins.trace` for printf-style debugging (remove before committing). Use `nix eval` for quick expression evaluation.
