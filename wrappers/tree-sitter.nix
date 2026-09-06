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
#   * The CLI does NOT load a grammar's prebuilt `parser` object from a
#     `parser-directories` grammar dir -- there it wants grammar *source*
#     (`src/grammar.json`) and would rebuild (needs a runtime `cc`). What it DOES
#     honour is `TREE_SITTER_LIBDIR`: a flat dir of `<name>.so` it dlopen's
#     directly. nixpkgs' `builtGrammars.<attr>/parser` is exactly such a prebuilt
#     `.so` and is ABI-compatible (grammars declare ABI 13-15; the 0.26.11 runtime
#     accepts 13-15), so we install those verbatim -- no compiler at build or run.
#
#   * The "needs recompile?" check only fires if the `.so` is missing or a source
#     file's mtime is strictly newer than the `.so`. Every Nix store file shares
#     mtime=1, so the check is always false: it never shells out to `cc`. This is
#     why `TREE_SITTER_LIBDIR` must be `--set` (not `--set-default`) to our store
#     libdir -- unset, it defaults to ~/.cache/tree-sitter/lib (a cold tmpfs in the
#     claude sandbox) where the `.so` is absent and every session would recompile.
#
#   * Language is auto-detected from the filename via each grammar's generated
#     `tree-sitter.json` (`scope` + `file-types`); the `.so` to load is named by
#     that grammar's `src/grammar.json` "name" (the parser's `tree_sitter_<name>`
#     symbol, derived here with `nm` rather than hardcoded). `TREE_SITTER_DIR`
#     points the CLI at the generated `config.json` (parser-directories + theme).
#
# The theme lives in sources/.config/tree-sitter/theme.json (mirroring the muted
# palette of sources/.config/bat/themes/monochrome.tmTheme, so the preview keeps
# its look -- tree-sitter's win here is structural accuracy, not louder colour).
# In dev mode $PERMEANCE_ROOT points at the working sources/ tree, so the launcher
# below re-reads that file each launch and synthesises the CLI config: colour edits
# take effect on the next preview with no rebuild. The copy read at build time is
# the fallback (bundled mode, or before the file exists). Languages with no grammar
# (or that ship no highlights) aren't detected; the preview falls back to `bat`.

let
  inherit (pkgs) lib;

  ts = pkgs.tree-sitter; # 0.26.11 on this pin
  bg = ts.builtGrammars;

  # Grammar-dir languages. `scope` + `fileTypes` drive extension detection;
  # `queries` (optional) selects a non-default query-composition strategy for the
  # split/inheriting grammars. Everything here is confirmed present in
  # `builtGrammars` on this pin. `.so` names are derived from the parser symbol at
  # build time, so attr spelling only has to match the `builtGrammars` attr.
  langs = {
    bash = {
      scope = "source.bash";
      fileTypes = [
        "sh"
        "bash"
      ];
    };
    c = {
      scope = "source.c";
      fileTypes = [
        "c"
        "h"
      ];
    };
    cmake = {
      scope = "source.cmake";
      fileTypes = [
        "cmake"
        "CMakeLists.txt"
      ];
    };
    css = {
      scope = "source.css";
      fileTypes = [ "css" ];
    };
    csv = {
      scope = "source.csv";
      fileTypes = [ "csv" ];
    };
    diff = {
      scope = "source.diff";
      fileTypes = [
        "diff"
        "patch"
      ];
    };
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
    "git-config" = {
      scope = "source.git-config";
      fileTypes = [
        "gitconfig"
        ".gitconfig"
      ];
    };
    "git-rebase" = {
      scope = "source.git-rebase";
      fileTypes = [ "git-rebase-todo" ];
    };
    gitattributes = {
      scope = "source.gitattributes";
      fileTypes = [
        "gitattributes"
        ".gitattributes"
      ];
    };
    gitcommit = {
      scope = "text.gitcommit";
      fileTypes = [
        "COMMIT_EDITMSG"
        "MERGE_MSG"
      ];
    };
    gitignore = {
      scope = "source.gitignore";
      fileTypes = [
        "gitignore"
        ".gitignore"
      ];
    };
    go = {
      scope = "source.go";
      fileTypes = [ "go" ];
    };
    gomod = {
      scope = "source.gomod";
      fileTypes = [ "go.mod" ];
    };
    html = {
      scope = "text.html.basic";
      fileTypes = [
        "html"
        "htm"
      ];
    };
    ini = {
      scope = "source.ini";
      fileTypes = [ "ini" ];
    };
    javascript = {
      scope = "source.js";
      fileTypes = [
        "js"
        "mjs"
        "cjs"
        "jsx"
      ];
    };
    json = {
      scope = "source.json";
      fileTypes = [ "json" ];
    };
    json5 = {
      scope = "source.json5";
      fileTypes = [ "json5" ];
    };
    lua = {
      scope = "source.lua";
      fileTypes = [ "lua" ];
    };
    make = {
      scope = "source.make";
      fileTypes = [
        "Makefile"
        "makefile"
        "mk"
      ];
    };
    markdown = {
      scope = "text.markdown";
      fileTypes = [
        "md"
        "markdown"
      ];
      queries = "markdown";
    };
    nix = {
      scope = "source.nix";
      fileTypes = [ "nix" ];
    };
    python = {
      scope = "source.python";
      fileTypes = [
        "py"
        "pyi"
      ];
    };
    rust = {
      scope = "source.rust";
      fileTypes = [ "rs" ];
    };
    sql = {
      scope = "source.sql";
      fileTypes = [ "sql" ];
    };
    toml = {
      scope = "source.toml";
      fileTypes = [ "toml" ];
    };
    typescript = {
      scope = "source.ts";
      fileTypes = [
        "ts"
        "mts"
        "cts"
      ];
      queries = "typescript";
    };
    tsx = {
      scope = "source.tsx";
      fileTypes = [ "tsx" ];
      queries = "tsx";
    };
    vim = {
      scope = "source.viml";
      fileTypes = [ "vim" ];
    };
    xml = {
      scope = "text.xml";
      fileTypes = [
        "xml"
        "svg"
        "xsd"
        "xsl"
      ];
    };
    yaml = {
      scope = "source.yaml";
      fileTypes = [
        "yaml"
        "yml"
      ];
    };
    zig = {
      scope = "source.zig";
      fileTypes = [ "zig" ];
    };
  };

  # Injection-only parsers: installed into the libdir so markdown's fenced/inline
  # injections can parse, but with no grammar dir / file-type of their own.
  extraLibs = [ "markdown-inline" ];

  # Minimal bootstrap fallback -- the full, canonical theme lives in
  # sources/.config/tree-sitter/theme.json. This is used only when that file is
  # absent at build (e.g. before it is first applied); once it exists, readFile
  # below wins. Kept to the core captures so the wrapper still renders something
  # sensible in that window. Colours are truecolor (the CLI emits 24-bit RGB).
  defaultTheme = {
    keyword = "#adb4cc";
    string = "#9792a8";
    comment = {
      color = "#6d8ca8";
      italic = true;
    };
    function = "#d48679";
    type = "#b3b39a";
    number = "#96966e";
  };

  # sources/.config/tree-sitter/theme.json is the source of truth: read here for the
  # baked default (readFile ties the build to its content) and re-read live by the
  # launcher in dev mode. Guarded so the wrapper still builds before the file exists.
  themeFile = configPath + "/.config/tree-sitter/theme.json";
  baseThemeJSON =
    if builtins.pathExists themeFile then builtins.readFile themeFile else builtins.toJSON defaultTheme;

  parserOf = attr: "${bg."tree-sitter-${attr}"}/parser";
  srcOf = attr: bg."tree-sitter-${attr}".src;

  langsJSON = pkgs.writeText "ts-langs.json" (
    builtins.toJSON (
      lib.mapAttrs (_: m: {
        inherit (m) scope;
        "file-types" = m.fileTypes;
        queries = m.queries or "auto";
      }) langs
    )
  );

  # Build-time assembly. Reads store paths from the environment (so they enter the
  # closure) and lays out the exact tree the CLI consumes. No compiler is invoked:
  # `nm` only reads each prebuilt `.so`'s exported symbol to name it.
  bundle =
    pkgs.runCommand "tree-sitter-bundle"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.binutils # nm
        ];
        inherit langsJSON;
        theme = baseThemeJSON;
        jsSrc = srcOf "javascript";
        parsers = lib.concatMapStringsSep " " (a: "${a}=${parserOf a}") (lib.attrNames langs ++ extraLibs);
        srcs = lib.concatMapStringsSep " " (a: "${a}=${srcOf a}") (lib.attrNames langs);
      }
      ''
        mkdir -p $out/grammars $out/libdir $out/tsdir
        python3 - <<'PY'
        import os, json, shutil, subprocess

        out = os.environ["out"]
        langs = json.load(open(os.environ["langsJSON"]))
        parsers = dict(x.split("=", 1) for x in os.environ["parsers"].split())
        srcs = dict(x.split("=", 1) for x in os.environ["srcs"].split())
        jsq = os.path.join(os.environ["jsSrc"], "queries")
        theme = json.loads(os.environ["theme"])

        def name_of(parser):
            # The loader dlopens libdir/<name>.so and calls tree_sitter_<name>(),
            # so <name> must be the parser's real exported symbol -- derive it
            # rather than guess from the attr (git-config -> git_config, etc.).
            syms = subprocess.check_output(["nm", "-D", "--defined-only", parser]).decode()
            for line in syms.splitlines():
                if "tree_sitter_" in line:
                    return line.split("tree_sitter_")[1].strip()
            raise SystemExit("no tree_sitter_* symbol in " + parser)

        def write(p, data):
            os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p, "w").write(data)

        def first(paths):
            for p in paths:
                if p and os.path.exists(p):
                    return p
            return None

        def cat(paths):
            s = ""
            for p in paths:
                if p and os.path.exists(p):
                    s += open(p).read() + "\n"
            return s

        # Install every prebuilt parser (grammar-dir langs + injection-only) as
        # <name>.so. name_of also gives each grammar dir its src/grammar.json name.
        names = {}
        for attr, parser in parsers.items():
            nm = name_of(parser)
            names[attr] = nm
            shutil.copy(parser, f"{out}/libdir/{nm}.so")

        for attr, m in langs.items():
            nm = names[attr]
            src = srcs[attr]
            gd = f"{out}/grammars/tree-sitter-{attr}"
            # Stubs: grammar.json supplies the name (first 3 lines are regex-scanned
            # for it); parser.c only has to exist (mtime check, never read).
            write(f"{gd}/src/grammar.json", json.dumps({"name": nm}))
            write(f"{gd}/src/parser.c", "")

            kind = m.get("queries", "auto")
            hl = []
            inj = None
            loc = None
            if kind == "typescript":
                # ts's own highlights extend javascript's; the upstream tree-sitter.json
                # points at node_modules that don't exist in the src, so compose the
                # base by hand instead of inheriting.
                hl = [f"{jsq}/highlights.scm", f"{src}/queries/highlights.scm"]
                inj = f"{jsq}/injections.scm"
                loc = f"{jsq}/locals.scm"
            elif kind == "tsx":
                hl = [f"{jsq}/highlights.scm", f"{jsq}/highlights-jsx.scm", f"{src}/queries/highlights.scm"]
                inj = f"{jsq}/injections.scm"
                loc = f"{jsq}/locals.scm"
            elif kind == "markdown":
                sub = f"{src}/tree-sitter-markdown/queries"
                hl = [f"{sub}/highlights.scm"]
                inj = f"{sub}/injections.scm"
            else:
                # auto: queries live directly under queries/ or in a name subdir
                # (e.g. xml -> queries/xml, vim -> queries/vim). Resolve each file
                # from whichever exists; a missing file just drops that query.
                sub = first([f"{src}/queries/{nm}", f"{src}/queries/{attr}"])
                cands = lambda f: [f"{src}/queries/{f}"] + ([f"{sub}/{f}"] if sub else [])
                hlp = first(cands("highlights.scm"))
                hl = [hlp] if hlp else []
                inj = first(cands("injections.scm"))
                loc = first(cands("locals.scm"))

            g = {"name": nm, "scope": m["scope"], "file-types": m["file-types"]}
            hlc = cat(hl)
            # tree-sitter.json may only reference query files that exist, or the CLI
            # errors -- so add each key only when we actually wrote the file.
            if hlc.strip():
                write(f"{gd}/queries/highlights.scm", hlc)
                g["highlights"] = ["queries/highlights.scm"]
            if inj and os.path.exists(inj):
                shutil.copy(inj, f"{gd}/queries/injections.scm")
                g["injections"] = ["queries/injections.scm"]
            if loc and os.path.exists(loc):
                shutil.copy(loc, f"{gd}/queries/locals.scm")
                g["locals"] = ["queries/locals.scm"]
            write(f"{gd}/tree-sitter.json", json.dumps({"grammars": [g], "metadata": {"version": "0.0.1"}}))

        write(f"{out}/tsdir/config.json", json.dumps({
            "parser-directories": [f"{out}/grammars"],
            "theme": theme,
        }))
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
