{ pkgs }:

let
  inherit (pkgs) python3Packages lib;
  version = "1.3.46";
in
python3Packages.buildPythonApplication {
  pname = "aws-api-mcp-server";
  inherit version;
  pyproject = true;

  # The awslabs/mcp monorepo doesn't tag per-package, so build from the published
  # PyPI sdist. It's self-contained: it bundles the agent-script registry
  # (*.script.md) and the api_metadata.json / aws_api_customization.json the server
  # loads at runtime via importlib.resources / python-frontmatter.
  src = python3Packages.fetchPypi {
    pname = "awslabs_aws_api_mcp_server";
    inherit version;
    hash = "sha256-GpNuUnNU/Br9FIaz4hS9FGNmb6gkd8cDV/kHhDGW2N8=";
  };

  build-system = [ python3Packages.hatchling ];

  # Upstream pins `awscli == 1.45.36`; this nixpkgs ships 1.44.21. The exact pin
  # is stricter than the call_aws surface needs, so relax it to the packaged
  # version (the smoke test exercises the binary to confirm it still runs).
  pythonRelaxDeps = [ "awscli" ];

  dependencies =
    builtins.attrValues {
      inherit (python3Packages)
        mcp
        fastmcp
        pydantic
        boto3
        botocore
        awscrt
        python-json-logger
        setuptools
        lxml
        loguru
        importlib-resources
        requests
        python-frontmatter
        ;
    }
    ++ [
      # awscli v1 isn't in python3Packages here (only the top-level app), but the
      # server imports `awscli.clidriver`. toPythonModule re-exposes the app's
      # bundled module on PYTHONPATH so it resolves as a normal dependency.
      (python3Packages.toPythonModule pkgs.awscli)
    ];

  pythonImportsCheck = [ "awslabs.aws_api_mcp_server" ];

  meta = {
    description = "MCP server exposing AWS API and CLI operations as tools";
    homepage = "https://github.com/awslabs/mcp/tree/main/src/aws-api-mcp-server";
    license = lib.licenses.asl20;
    mainProgram = "awslabs.aws-api-mcp-server";
  };
}
