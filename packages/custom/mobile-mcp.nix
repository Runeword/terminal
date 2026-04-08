{ pkgs }:

pkgs.buildNpmPackage rec {
  pname = "mobile-mcp";
  version = "0.0.51";

  src = pkgs.fetchFromGitHub {
    owner = "mobile-next";
    repo = "mobile-mcp";
    rev = version;
    hash = "sha256-A8Z6k6oWvQsJSdEfroEdWQ/454H1hIbqLUs06aE1mXE=";
  };

  npmDepsHash = "sha256-E0BLwtoenlDimMOeKEfx2HerfOy8VpcK8+Tu0uiueJY=";

  nodejs = pkgs.nodejs_22;

  buildPhase = ''
    runHook preBuild
    npx tsc
    chmod +x lib/index.js
    runHook postBuild
  '';

  nativeBuildInputs = [ pkgs.makeWrapper ];

  postInstall = ''
    wrapProgram $out/bin/mcp-server-mobile \
      --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.android-tools ]}
  '';

  meta = {
    description = "MCP server for mobile device automation via ADB and WebDriverAgent";
    homepage = "https://github.com/mobile-next/mobile-mcp";
    license = pkgs.lib.licenses.asl20;
  };
}
