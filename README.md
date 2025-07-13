### Terminal

#### Standalone run

* Development mode :
  ```shell
  git clone git@github.com:Runeword/terminal.git && \
  cd terminal && TERM_CONFIG_DIR="$PWD/config" nix run .#dev --impure
  ```

#### Home Manager

* Development mode :

  `flake.nix`
  ```nix
  inputs.runeword-terminal.url = "github:Runeword/terminal";
  ```

  `home.nix`
  ```nix
  home.packages = [
    (inputs.runeword-terminal.packages.${pkgs.system}.dev.options { configPath = "${config.home.homeDirectory}/terminal/config"; })
  ];
  ```
