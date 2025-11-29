# Terminal reproducible setup

## Development mode

### Standalone run
Run the `dev` app :
  ```shell
  git clone git@github.com:Runeword/terminal.git && \
  cd terminal && TERM_CONFIG_DIR="$PWD/config" nix run .#dev --impure
  ```

### Home-manager install
Install the `dev` package with home-manager :
  `flake.nix`
  ```nix
  inputs.runeword-terminal.url = "github:Runeword/terminal";
  ```

  `home.nix`
  ```nix
  home.packages = [
    (inputs.runeword-terminal.packages.${pkgs.stdenv.hostPlatform.system}.dev.options { configPath = "${config.home.homeDirectory}/terminal/config"; })
  ];
  ```

<!-- ## Bundled mode -->

<!-- ### Standalone run -->
<!-- Run the `default` app : -->
<!-- ```shell -->
<!-- nix run "github:Runeword/terminal" -->
<!-- ``` -->

<!-- ### Home-manager install -->
<!-- Install the `default` package with home-manager : -->
<!-- `flake.nix` -->
<!-- ```nix -->
<!-- inputs.runeword-neovim.url = "github:Runeword/terminal"; -->
<!-- ``` -->

<!-- `home.nix` -->
<!-- ```nix -->
<!-- home.packages = [ -->
<!--   (inputs.runeword-terminal.packages.${pkgs.system}.default -->
<!-- ]; -->
<!-- ``` -->
