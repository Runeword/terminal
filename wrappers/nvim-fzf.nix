{
  pkgs,
  files,
  tests,
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

  config = files.mkConfig "nvim-fzf-config" [
    {
      source = ".config/nvim-fzf/init.lua";
      target = ".config/nvim-fzf/init.lua";
    }
  ];

  self = pkgs.symlinkJoin {
    name = "nvim-fzf";
    paths = [
      pkgs.neovim-unwrapped
      config
    ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      mv $out/bin/nvim $out/bin/.nvim-fzf-wrapped
      makeWrapper $out/bin/.nvim-fzf-wrapped $out/bin/.nvim-fzf-inner \
        --add-flags "--clean" \
        --add-flags "-u $out/.config/nvim-fzf/init.lua" \
        --set NVIM_FZF_PACK_PATH "${plugins}" \
        --prefix PATH : "${
          pkgs.lib.makeBinPath [
            pkgs.fzf
            pkgs.fd
            pkgs.ripgrep
          ]
        }"

      cat > $out/bin/nvim-fzf <<EOF
      #!/bin/sh
      export NVIM_FZF_ARGS="\$*"
      exec $out/bin/.nvim-fzf-inner
      EOF
      chmod +x $out/bin/nvim-fzf
    '';
    passthru.tests.smoke = tests.smoke {
      name = "nvim-fzf";
      description = "Verify nvim-fzf launches headless with its config";
      script = ''
        # Launch nvim headless, run a no-op, then quit. This loads init.lua.
        if NVIM_FZF_ARGS="" ${self}/bin/.nvim-fzf-inner --headless +qa > /dev/null 2>&1; then
          ok "launches with config"
        else
          fail "failed to launch with config"
        fi
      '';
    };
  };
in
self
