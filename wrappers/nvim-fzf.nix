{
  pkgs,
  files,
  permeance,
}:

let
  plugins = pkgs.vimUtils.packDir {
    nvim-fzf = {
      start = [
        pkgs.vimPlugins.nightfly
        (pkgs.vimPlugins.nvim-treesitter.withPlugins (p: [
          p.bash
          p.c
          p.cmake
          p.comment
          p.css
          p.csv
          p.diff
          p.dockerfile
          p.fish
          p.git_config
          p.git_rebase
          p.gitattributes
          p.gitcommit
          p.gitignore
          p.go
          p.gomod
          p.gosum
          p.html
          p.ini
          p.javascript
          p.json
          p.json5
          p.jsdoc
          p.lua
          p.make
          p.markdown
          p.markdown_inline
          p.nix
          p.python
          p.regex
          p.rust
          p.sql
          p.ssh_config
          p.toml
          p.tsx
          p.typescript
          p.vim
          p.vimdoc
          p.xml
          p.yaml
          p.zig
        ]))
      ];
    };
  };

  config = files.mkConfig "nvim-fzf-config" [ ".config/nvim-fzf/init.lua" ];

  self = pkgs.symlinkJoin {
    name = "nvim-fzf";
    paths = [
      pkgs.neovim-unwrapped
      config
    ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      mv $out/bin/nvim $out/bin/.nvim-fzf-wrapped

      # Inner: makeWrapper handles the bundled bits (PATH, plugin pack dir,
      # --clean). The -u flag is owned by the outer launcher so init.lua can
      # be redirected by PERMEANCE_ROOT.
      makeWrapper $out/bin/.nvim-fzf-wrapped $out/bin/.nvim-fzf-inner \
        --add-flags "--clean" \
        --set NVIM_FZF_PACK_PATH "${plugins}" \
        --prefix PATH : "${
          pkgs.lib.makeBinPath [
            pkgs.fzf
            pkgs.fd
            pkgs.ripgrep
          ]
        }"

      # nvim-fzf captures CLI args into NVIM_FZF_ARGS for init.lua to read,
      # then execs nvim with only -u (no positional args). preExecLines does
      # the $* capture; forwardArgs=false drops "$@" from the exec line.
      ${permeance.installLauncher {
        binName = "nvim-fzf";
        realBin = "@OUT@/bin/.nvim-fzf-inner";
        flags = [
          "-u"
          "$PERMEANCE_ROOT/.config/nvim-fzf/init.lua"
        ];
        preExecLines = [ ''export NVIM_FZF_ARGS="$*"'' ];
        forwardArgs = false;
      }}
    '';
    passthru.tests.smoke = permeance.tests.mkSmoke {
      name = "nvim-fzf";
      description = "Verify nvim-fzf launches headless with init.lua";
      script = ''
        # Smoke: call .nvim-fzf-inner with explicit -u (the outer launcher owns
        # -u now, so the inner needs it spelled out for the headless probe).
        if NVIM_FZF_ARGS="" ${self}/bin/.nvim-fzf-inner -u ${self}/.config/nvim-fzf/init.lua --headless +qa > /dev/null 2>&1; then
          ok "launches with bundled init.lua"
        else
          fail "failed to launch with init.lua"
        fi
      '';
    };
  };
in
self
