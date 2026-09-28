{ pkgs }:

let
  unwrapped = pkgs.buildNpmPackage rec {
    pname = "firefox-devtools-mcp";
    version = "0.9.1";

    src = pkgs.fetchFromGitHub {
      owner = "mozilla";
      repo = "firefox-devtools-mcp";
      rev = version;
      hash = "sha256-Az4okHS6XOuKhJ3wkQNRy7ZUyfnqy7NJGq/dPNS9Zs0=";
    };

    npmDepsHash = "sha256-xRmflTT/XFxONzrzcyZa1n9rMdqZ2NAmhMPksNBOEa0=";

    nodejs = pkgs.nodejs_22;

    buildPhase = ''
      runHook preBuild
      npx tsup
      runHook postBuild
    '';

    meta = {
      description = "MCP server for Firefox DevTools automation via WebDriver BiDi";
      homepage = "https://github.com/mozilla/firefox-devtools-mcp";
      license = pkgs.lib.licenses.mit;
    };
  };
in
pkgs.symlinkJoin {
  name = "firefox-devtools-mcp-${unwrapped.version}";
  paths = [ unwrapped ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    wrapProgram $out/bin/firefox-devtools-mcp \
      --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.geckodriver ]}
  '';
}
