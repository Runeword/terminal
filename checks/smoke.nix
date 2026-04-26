{
  pkgs,
  wrappers,
}:

let
  # Helper to create a smoke test derivation for a wrapper.
  # Tests should produce no errors on success. Use `fail` to record a failure
  # and continue; the script exits non-zero at the end if any failures occurred.
  mkSmoke =
    {
      name,
      description,
      script,
    }:
    pkgs.runCommand "smoke-${name}"
      {
        meta.description = description;
      }
      ''
        failed=0

        fail() {
          echo "  FAIL: $1"
          failed=1
        }

        ok() {
          echo "  OK: $1"
        }

        echo "Testing ${name}..."
        ${script}

        if [ "$failed" -ne 0 ]; then
          echo ""
          echo "Smoke test for ${name} failed!"
          exit 1
        fi

        touch $out
      '';

in
{
  zsh = mkSmoke {
    name = "zsh";
    description = "Verify zsh wrapper loads its config without errors";
    script = ''
      # ZDOTDIR points at wrapper config
      zdotdir=$(${wrappers.zsh}/bin/zsh -c 'echo $ZDOTDIR')
      if [ "$zdotdir" = "${wrappers.zsh}/.config/zsh" ]; then
        ok "ZDOTDIR points to wrapper config"
      else
        fail "ZDOTDIR is '$zdotdir', expected '${wrappers.zsh}/.config/zsh'"
      fi

      # Sourcing .zshrc must not produce errors. Set HOME to a writable dir
      # since the Nix sandbox sets HOME=/homeless-shelter.
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"
      err=$(${wrappers.zsh}/bin/zsh -i -c 'exit 0' 2>&1 >/dev/null)
      if [ -z "$err" ]; then
        ok ".zshrc sources without errors"
      else
        fail ".zshrc produced errors:"
        echo "$err" | sed 's/^/    /'
      fi
    '';
  };

  bash = mkSmoke {
    name = "bash";
    description = "Verify bash wrapper sets NIX_OUT_SHELL correctly";
    script = ''
      nix_out=$(${wrappers.bash}/bin/bash -i -c 'echo $NIX_OUT_SHELL' 2>/dev/null)
      if [ "$nix_out" = "${wrappers.bash}" ]; then
        ok "NIX_OUT_SHELL points to wrapper"
      else
        fail "NIX_OUT_SHELL is '$nix_out', expected '${wrappers.bash}'"
      fi
    '';
  };

  bat = mkSmoke {
    name = "bat";
    description = "Verify bat finds its config file";
    script = ''
      bat_config=$(${wrappers.bat}/bin/bat --config-file 2>/dev/null)
      case "$bat_config" in
        ${wrappers.bat}/*)
          ok "config file points to wrapper ($bat_config)" ;;
        *)
          fail "config file is '$bat_config', expected path under '${wrappers.bat}/'" ;;
      esac
    '';
  };

  starship = mkSmoke {
    name = "starship";
    description = "Verify starship loads its config and generates a prompt";
    script = ''
      if ${wrappers.starship}/bin/starship prompt > /dev/null 2>&1; then
        ok "prompt generates successfully"
      else
        fail "prompt generation failed"
      fi
    '';
  };

  tmux = mkSmoke {
    name = "tmux";
    description = "Verify tmux config syntax is valid and uses the zsh wrapper";
    script = ''
      if ${wrappers.tmux}/bin/tmux -f ${wrappers.tmux}/.config/tmux/tmux.conf start-server \; kill-server 2>/dev/null; then
        ok "config syntax valid"
      else
        fail "config syntax error"
      fi

      tmux_shell=$(${wrappers.tmux}/bin/tmux -f ${wrappers.tmux}/.config/tmux/tmux.conf start-server \; show-option -gv default-shell \; kill-server 2>/dev/null)
      if [ "$tmux_shell" = "${wrappers.zsh}/bin/zsh" ]; then
        ok "default-shell is zsh wrapper"
      else
        fail "default-shell is '$tmux_shell', expected '${wrappers.zsh}/bin/zsh'"
      fi
    '';
  };

  ripgrep = mkSmoke {
    name = "ripgrep";
    description = "Verify ripgrep respects the shared ignore file";
    script = ''
      mkdir -p $TMPDIR/rg-test/node_modules
      echo "secret" > $TMPDIR/rg-test/node_modules/file.txt
      echo "visible" > $TMPDIR/rg-test/visible.txt

      rg_output=$(${wrappers.ripgrep}/bin/rg --files $TMPDIR/rg-test 2>/dev/null)
      echo "  files found:"
      echo "$rg_output" | sed 's/^/    /'

      if echo "$rg_output" | grep -q "node_modules"; then
        fail "node_modules not ignored"
      else
        ok "node_modules ignored"
      fi

      if echo "$rg_output" | grep -q "visible.txt"; then
        ok "visible files found"
      else
        fail "visible files not found"
      fi
    '';
  };

  fd = mkSmoke {
    name = "fd";
    description = "Verify fd respects the shared ignore file";
    script = ''
      mkdir -p $TMPDIR/fd-test/node_modules
      echo "secret" > $TMPDIR/fd-test/node_modules/file.txt
      echo "visible" > $TMPDIR/fd-test/visible.txt

      fd_output=$(${wrappers.fd}/bin/fd . $TMPDIR/fd-test 2>/dev/null)
      echo "  files found:"
      echo "$fd_output" | sed 's/^/    /'

      if echo "$fd_output" | grep -q "node_modules"; then
        fail "node_modules not ignored"
      else
        ok "node_modules ignored"
      fi
    '';
  };

  delta = mkSmoke {
    name = "delta";
    description = "Verify delta runs with its config";
    script = ''
      if echo "" | ${wrappers.delta}/bin/delta > /dev/null 2>&1; then
        ok "runs with config"
      else
        fail "failed to run with config"
      fi
    '';
  };

  navi = mkSmoke {
    name = "navi";
    description = "Verify navi loads its config";
    script = ''
      # navi info config shows the active config path; fails on bad config
      if ${wrappers.navi}/bin/navi info config-path > /dev/null 2>&1; then
        ok "config loads"
      else
        fail "config failed to load"
      fi
    '';
  };

  nvim-fzf = mkSmoke {
    name = "nvim-fzf";
    description = "Verify nvim-fzf launches headless with its config";
    script = ''
      # Launch nvim headless, run a no-op, then quit. This loads init.lua.
      if NVIM_FZF_ARGS="" ${wrappers.nvim-fzf}/bin/.nvim-fzf-inner --headless +qa > /dev/null 2>&1; then
        ok "launches with config"
      else
        fail "failed to launch with config"
      fi
    '';
  };

  claude = mkSmoke {
    name = "claude";
    description = "Verify claude runs with its config";
    script = ''
      if ${wrappers.claude}/bin/claude --version > /dev/null 2>&1; then
        ok "runs successfully"
      else
        fail "failed to run"
      fi
    '';
  };
}
