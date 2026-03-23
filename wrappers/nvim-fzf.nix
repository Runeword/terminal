{ pkgs, files }:

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
in

pkgs.symlinkJoin {
  name = "nvim-fzf";
  paths = [ pkgs.neovim-unwrapped ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${files.sync "nvim-fzf/init.lua" ".config/nvim-fzf/init.lua"}

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
}
