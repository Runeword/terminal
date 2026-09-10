{
  pkgs,
  permeance,
  configPath,
}:

# A `tree-sitter` CLI wrapped so `tree-sitter highlight <file>` renders ANSI,
# tree-sitter-accurate syntax colour with ZERO runtime compilation. Consumed by
# the interactive search preview (sources/.config/shell/scripts/fm_preview.sh),
# which replaced its `bat` highlighter with this.
#
# Why this shape (established empirically against this pin, tree-sitter 0.26.11):
#
#   * The CLI won't use a grammar dir's prebuilt parser -- given a parser-directory
#     it insists on grammar *source* (`src/grammar.json` + `parser.c`) and would
#     rebuild (needs a runtime `cc`). Its one escape hatch is `TREE_SITTER_LIBDIR`:
#     a flat dir of `<name>.<so|dylib>` it dlopens directly (the extension is the
#     host's -- `.so` on Linux, `.dylib` on macOS). nixpkgs' `builtGrammars.<attr>/parser`
#     is exactly such a prebuilt object (ELF on Linux, Mach-O on macOS; ABI 13-15,
#     which the 0.26.11 runtime accepts), so we point LIBDIR at those under the host's
#     extension and compile nothing, at build or run.
#
#   * It still requires `src/grammar.json` + `parser.c` to exist per grammar, so we
#     drop in a 2-line stub. Its "recompile?" check only fires when a source file's
#     mtime is newer than the `.so`; store files are all mtime=1 and the stubs are
#     stamped epoch-0, so it never shells out to `cc`. (LIBDIR must be `--set`, not
#     `--set-default`: unset it defaults to a ~/.cache path that's a cold tmpfs in
#     the claude sandbox, where the `.so` is absent and every session would recompile.)
#
#   * Everything else the CLI needs -- filename->language detection and the highlight
#     queries -- the grammar *source* already ships (`tree-sitter.json` + `queries/`),
#     so we read detection metadata from it and symlink its queries straight in
#     rather than re-emitting them; the parser's exported symbol name (which the CLI
#     dlopens by) is read from the object with the host's `nm`. `TREE_SITTER_DIR`
#     points the CLI at the generated `config.json` (parser-directories + theme).
#
# The theme lives in sources/.config/tree-sitter/theme.json (mirroring the user's
# Neovim nightfly colorscheme, resolved capture-by-capture, so the preview matches
# the editor; highlight queries come from each grammar's own queries/). In dev mode
# $PERMEANCE_ROOT points at the working sources/ tree, so the launcher below re-reads
# that file each launch and synthesises the CLI config: colour edits take effect on
# the next preview with no rebuild. The copy read at build time is the fallback
# (bundled mode, or before the file exists). Languages with no grammar (or that ship
# no highlights) aren't detected; the preview falls back to `bat`.

let
  inherit (pkgs) lib;

  ts = pkgs.tree-sitter; # 0.26.11 on this pin
  bg = ts.builtGrammars;

  # Per-object-format knobs. The CLI dlopens `<name>.so` (Linux/ELF) or
  # `<name>.dylib` (macOS/Mach-O) from TREE_SITTER_LIBDIR, so the libdir symlink is
  # named with the host extension. The exported symbol is read with the host's nm:
  # GNU `nm -D` reads the ELF `.dynsym`; llvm-nm reads the Mach-O symbol table (where
  # the symbol carries a leading `_`, stripped in name_of below). Both are given by
  # full path so the object format and tool never mismatch. The `else` branches stay
  # unforced off-platform (lazy `if`), so Linux builds pull in no llvm.
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  dylibExt = if isDarwin then "dylib" else "so";
  nmCmd = if isDarwin then "${pkgs.llvmPackages.llvm}/bin/llvm-nm" else "${pkgs.binutils}/bin/nm";
  nmArgs = if isDarwin then "--defined-only --extern-only" else "-D --defined-only";

  # Grammars to bundle (all confirmed present in `builtGrammars` on this pin).
  # Detection (scope + file-types) comes from each grammar's own tree-sitter.json;
  # `overrides` below supplies it only for grammars that ship none, or ship wrong
  # metadata. A grammar with no highlights query, or that fails to load, is dropped
  # at build time (-> that file type falls back to `bat`).
  grammars = [
    "bash"
    "c"
    "cmake"
    "css"
    "diff"
    "dockerfile"
    "fish"
    "git-config"
    "git-rebase"
    "gitattributes"
    "gitcommit"
    "go"
    "gomod"
    "html"
    "ini"
    "javascript"
    "json"
    "json5"
    "lua"
    "make"
    "nix"
    "python"
    "rust"
    "sql"
    "toml"
    "tsx"
    "typescript"
    "yaml"
    "zig"
  ];

  # Only the exceptions to what each grammar's own tree-sitter.json provides.
  # dockerfile/fish/gomod ship none; tsx's mislabels it as `.ts` (which would also
  # collide with typescript, whose entry omits `.mts`/`.cts`). The `.so` symbol name
  # is read from the parser with `nm`, so it is never listed here.
  overrides = {
    dockerfile = {
      scope = "source.dockerfile";
      fileTypes = [
        "dockerfile"
        "Dockerfile"
      ];
    };
    fish = {
      scope = "source.fish";
      fileTypes = [ "fish" ];
    };
    gomod = {
      scope = "source.gomod";
      fileTypes = [ "go.mod" ];
    };
    tsx = {
      scope = "source.tsx";
      fileTypes = [ "tsx" ];
    };
    typescript.fileTypes = [
      "ts"
      "mts"
      "cts"
    ];
  };

  # Minimal bootstrap fallback -- the full, canonical theme lives in
  # sources/.config/tree-sitter/theme.json. This is used only when that file is
  # absent at build (e.g. before it is first applied); once it exists, readFile
  # below wins. Kept to the core captures so the wrapper still renders something
  # sensible in that window. Colours are truecolor (the CLI emits 24-bit RGB).
  defaultTheme = {
    keyword = {
      color = "#c792ea";
      italic = true;
      bold = true;
    };
    string = {
      color = "#ecc48d";
      italic = true;
    };
    comment = "#7c8f8f";
    function = {
      color = "#82aaff";
      italic = true;
    };
    type = "#21c7a8";
    number = "#f78c6c";
  };

  # sources/.config/tree-sitter/theme.json is the source of truth: read here for the
  # baked default (readFile ties the build to its content) and re-read live by the
  # launcher in dev mode. Guarded so the wrapper still builds before the file exists.
  themeFile = configPath + "/.config/tree-sitter/theme.json";
  baseThemeJSON =
    if builtins.pathExists themeFile then builtins.readFile themeFile else builtins.toJSON defaultTheme;

  # Build-time assembly. One grammar dir per language, each reusing the grammar
  # source's own tree-sitter.json metadata + queries (symlinked), plus a stub src/
  # and the parser `.so` in the libdir. No compiler, no query rewriting.
  bundle =
    pkgs.runCommand "tree-sitter-bundle"
      {
        nativeBuildInputs = [
          pkgs.python3
          ts # `highlight --scope` to validate each grammar loads at build time
        ];
        theme = baseThemeJSON;
        parsers = lib.concatMapStringsSep " " (a: "${a}=${bg."tree-sitter-${a}"}/parser") grammars;
        srcs = lib.concatMapStringsSep " " (a: "${a}=${bg."tree-sitter-${a}".src}") grammars;
        overrides = builtins.toJSON overrides;
        # nm binary + flags + libdir extension for the host object format (see let-block).
        inherit nmCmd nmArgs dylibExt;
      }
      ''
        mkdir -p $out/grammars $out/libdir $out/tsdir
        python3 - <<'PY'
        import os, json, shutil, subprocess

        out = os.environ["out"]
        parsers = dict(x.split("=", 1) for x in os.environ["parsers"].split())
        srcs = dict(x.split("=", 1) for x in os.environ["srcs"].split())
        overrides = json.loads(os.environ["overrides"])
        theme = json.loads(os.environ["theme"])
        nm = [os.environ["nmCmd"], *os.environ["nmArgs"].split()]
        dylib_ext = os.environ["dylibExt"]

        def name_of(parser):
            # The CLI dlopens libdir/<name>.<dylib_ext> and calls tree_sitter_<name>(),
            # so <name> must be the parser's real exported symbol (git-config's is
            # git_config, etc.) -- read it rather than guess from the attr. nm prints
            # one symbol per line, symbol in the last field, with a leading `_` on
            # Mach-O (stripped here). Among all tree_sitter_* symbols the language
            # entrypoint is the shortest: a grammar with an external scanner also
            # exports strictly longer tree_sitter_<name>_external_scanner_* symbols,
            # which must not shadow it (so pick by length, not nm's line order).
            syms = subprocess.check_output(nm + [parser]).decode()
            cands = []
            for line in syms.splitlines():
                parts = line.split()
                if parts and parts[-1].lstrip("_").startswith("tree_sitter_"):
                    cands.append(parts[-1].lstrip("_")[len("tree_sitter_"):])
            if not cands:
                raise SystemExit("no tree_sitter_* symbol in " + parser)
            return min(cands, key=len)

        def meta(attr, src):
            # scope + file-types: an override if given, else the grammar's own
            # tree-sitter.json (absent for a few grammars -> they need an override).
            m = dict(overrides.get(attr, {}))
            tj = f"{src}/tree-sitter.json"
            if os.path.exists(tj):
                g = json.load(open(tj))["grammars"][0]
                m.setdefault("scope", g.get("scope"))
                m.setdefault("fileTypes", g.get("file-types", []))
            return m

        def build(attr):
            name = name_of(parsers[attr])
            m = meta(attr, srcs[attr])
            qdir = f"{srcs[attr]}/queries"
            qtypes = [q for q in ("highlights", "injections", "locals")
                      if os.path.exists(f"{qdir}/{q}.scm")]
            if not (m.get("scope") and m.get("fileTypes")) or "highlights" not in qtypes:
                return None
            gd = f"{out}/grammars/tree-sitter-{attr}"
            os.makedirs(f"{gd}/src")
            os.symlink(qdir, f"{gd}/queries")  # reuse the grammar's own queries verbatim
            # The CLI insists a src/ exists; stamp epoch-0 so its mtime never trips the
            # "recompile?" check (the real .so comes from the libdir -- see header).
            open(f"{gd}/src/grammar.json", "w").write(json.dumps({"name": name}))
            open(f"{gd}/src/parser.c", "w").write("")
            os.utime(f"{gd}/src/grammar.json", (0, 0))
            os.utime(f"{gd}/src/parser.c", (0, 0))
            g = {"name": name, "scope": m["scope"], "file-types": m["fileTypes"]}
            g.update({q: f"queries/{q}.scm" for q in qtypes})
            open(f"{gd}/tree-sitter.json", "w").write(
                json.dumps({"grammars": [g], "metadata": {"version": "0.0.1"}})
            )
            os.symlink(parsers[attr], f"{out}/libdir/{name}.{dylib_ext}")
            return {"name": name, "scope": m["scope"]}

        built = {attr: build(attr) for attr in srcs}

        open(f"{out}/tsdir/config.json", "w").write(json.dumps({
            "parser-directories": [f"{out}/grammars"],
            "theme": theme,
        }))

        # Validate each grammar loads against this exact CLI + pinned parser (a
        # prebuilt query can reference a node type the pinned grammar lacks); drop any
        # that don't so the file type falls back to bat instead of erroring.
        tmp = os.environ["TMPDIR"]
        cenv = dict(
            os.environ,
            HOME=tmp,
            XDG_CACHE_HOME=f"{tmp}/cache",
            TREE_SITTER_LIBDIR=f"{out}/libdir",
            TREE_SITTER_DIR=f"{out}/tsdir",
        )
        os.makedirs(cenv["XDG_CACHE_HOME"], exist_ok=True)
        open(f"{tmp}/probe", "w").write("x\n")

        def loads_ok(scope):
            r = subprocess.run(
                ["tree-sitter", "highlight", "--scope", scope, f"{tmp}/probe"],
                env=cenv,
                capture_output=True,
            )
            return b"Error" not in r.stderr

        dropped = []
        for attr in srcs:
            m = built[attr]
            if m is None:
                dropped.append(attr)
                continue
            if not loads_ok(m["scope"]):
                shutil.rmtree(f"{out}/grammars/tree-sitter-{attr}", ignore_errors=True)
                os.remove(f"{out}/libdir/{m['name']}.{dylib_ext}")
                dropped.append(attr)
        print("grammars active:", sorted(a for a in srcs if a not in dropped))
        print("dropped:", sorted(dropped))
        PY
      '';

  # The wrapped binary. TREE_SITTER_LIBDIR (baked; must be set, see header) makes the
  # CLI dlopen the prebuilt parsers. For the theme: in dev mode $PERMEANCE_ROOT points
  # at the working sources/ tree, so re-read .config/tree-sitter/theme.json there and
  # synthesise config.json (parser-directories is a store path, so it can't live in
  # the static sources file) -- colour edits then need no rebuild. Otherwise fall back
  # to the config baked into the bundle.
  launcher = pkgs.writeShellApplication {
    name = "tree-sitter";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      export TREE_SITTER_LIBDIR=${bundle}/libdir

      theme="''${PERMEANCE_ROOT:-}/.config/tree-sitter/theme.json"
      if [ -n "''${PERMEANCE_ROOT:-}" ] && [ -f "$theme" ]; then
        dir="''${XDG_CACHE_HOME:-''${HOME:-/tmp}/.cache}/fm-tree-sitter"
        mkdir -p "$dir" 2>/dev/null || dir="$(mktemp -d)"
        tmp="$(mktemp "$dir/config.XXXXXX")"
        {
          printf '{"parser-directories":["%s"],"theme":' "${bundle}/grammars"
          cat "$theme"
          printf '}\n'
        } >"$tmp"
        mv -f "$tmp" "$dir/config.json"
        export TREE_SITTER_DIR="$dir"
      else
        export TREE_SITTER_DIR=${bundle}/tsdir
      fi

      exec ${ts}/bin/tree-sitter "$@"
    '';
  };

  self =
    pkgs.runCommand "tree-sitter"
      {
        passthru.tests.smoke = permeance.tests.mkSmoke {
          name = "tree-sitter";
          description = "Verify the wrapped tree-sitter highlights via the baked libdir";
          script = ''
            sample="$TMPDIR/sample.nix"
            printf 'let x = { a = "hi"; }; in x.a\n' > "$sample"
            if ${self}/bin/tree-sitter highlight "$sample" 2>/dev/null | grep -q $'\033\['; then
              ok "nix sample highlighted with ANSI (prebuilt libdir loaded, no cc)"
            else
              fail "no ANSI in tree-sitter highlight output (libdir/TREE_SITTER_DIR wiring?)"
            fi

            # A second, unrelated grammar proves the multi-language libdir wiring.
            gosample="$TMPDIR/sample.go"
            printf 'package main\nfunc main() { _ = 1 }\n' > "$gosample"
            if ${self}/bin/tree-sitter highlight "$gosample" 2>/dev/null | grep -q $'\033\['; then
              ok "go sample highlighted with ANSI"
            else
              fail "go sample not highlighted"
            fi
          '';
        };
      }
      ''
        mkdir -p $out/bin
        ln -s ${launcher}/bin/tree-sitter $out/bin/tree-sitter
      '';
in
self
