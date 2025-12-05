# Terminal reproducible setup

## Development mode
- When running in development mode, the terminal configuration is symlinked to the Nix store.
This approach streamlines development, allowing you to apply configuration changes immediately without having to rebuild the flake.

### Standalone run
Run the `dev` app :

  ```shell
  git clone git@github.com:Runeword/terminal.git && \
  cd terminal && nix develop && dev
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

## Bundled mode
- In bundled mode, the terminal configuration is copied into the Nix store.
This ensures that both the flake and its configuration are fully isolated from your local environment.
However, any changes to the configuration require rebuilding the flake before they take effect.

### Standalone run
Run the `default` app :

  ```shell
  nix run "github:Runeword/terminal"
  ```

### Home-manager install
Install the `default` package with home-manager :

  `flake.nix`
  ```nix
  inputs.runeword-terminal.url = "github:Runeword/terminal";
  ```

  `home.nix`
  ```nix
  home.packages = [
    inputs.runeword-terminal.packages.${pkgs.system}.default
  ];
  ```
