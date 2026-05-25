{
  pkgs,
  files,
  tests,
}:

let
  config = files.mkConfig "bash-config" [
    {
      source = ".config/bash";
      target = ".config/bash";
    }
    {
      source = ".config/shell";
      target = ".config/shell";
    }
    {
      source = ".config/readline";
      target = ".config/readline";
    }
    {
      source = ".config/direnv";
      target = ".config/direnv";
    }
  ];
  self = pkgs.symlinkJoin {
    name = "bash-with-config";
    paths = [
      pkgs.bash
      config
    ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/bash \
        --add-flags "--rcfile $out/.config/bash/.bashrc" \
        --set NIX_OUT_SHELL "$out" \
        --set INPUTRC "$out/.config/readline/inputrc" \
        --set DIRENV_CONFIG "$out/.config/direnv"
    '';
    passthru.tests.smoke = tests.smoke {
      name = "bash";
      description = "Verify bash wrapper sets NIX_OUT_SHELL correctly";
      script = ''
        nix_out=$(${self}/bin/bash -i -c 'echo $NIX_OUT_SHELL' 2>/dev/null)
        if [ "$nix_out" = "${self}" ]; then
          ok "NIX_OUT_SHELL points to wrapper"
        else
          fail "NIX_OUT_SHELL is '$nix_out', expected '${self}'"
        fi
      '';
    };
  };
in
self
