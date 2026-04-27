{ pkgs }:

pkgs.buildNpmPackage rec {
  pname = "mobile-mcp";
  version = "0.0.52";

  src = pkgs.fetchFromGitHub {
    owner = "mobile-next";
    repo = "mobile-mcp";
    rev = version;
    hash = "sha256-m1nIk7y3Zs0bMBNrNlrsNlPsJShy6bW5/5W0cqd06Do=";
  };

  npmDepsHash = "sha256-YcHd1dnG1kuT9gU830B01p93LO/Zt74a9iKwYgOEDds=";

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
