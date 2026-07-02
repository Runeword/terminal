{ pkgs }:

let
  inherit (pkgs) python3Packages lib;
  version = "1.22.0";
in
python3Packages.buildPythonApplication {
  pname = "workspace-mcp";
  inherit version;
  pyproject = true;

  # Published on PyPI as `workspace-mcp`. The sdist is self-contained: it bundles
  # `core/tool_tiers.yaml` (the tool-tier registry loaded at runtime) as
  # package-data, so no extra data files need fetching.
  src = python3Packages.fetchPypi {
    pname = "workspace_mcp";
    inherit version;
    hash = "sha256-Vvm7a2Kb2BalOlNfagr9c6PoIY60WruYofRw24qeEhA=";
  };

  build-system = [ python3Packages.setuptools ];

  # Upstream pins bleeding-edge lower bounds; this nixpkgs sits a few patch/minor
  # releases behind on four deps. The fastmcp API surface the server imports
  # (fastmcp.FastMCP, server.auth.providers.google.GoogleProvider,
  # server.auth.jwt_issuer.derive_jwt_key, server.dependencies.get_context) all
  # exist in 3.2.4, so the >=3.4.2 pin is conservative rather than a hard
  # requirement — the pythonImportsCheck below constructs the server object to
  # confirm. The others are patch/minor drift with no relevant API change.
  pythonRelaxDeps = [
    "fastmcp" # have 3.2.4, pin >=3.4.2
    "urllib3" # have 2.6.3, pin >=2.7.0
    "cryptography" # have 48.0.0, pin >=48.0.1
    "pypdf" # have 6.13.2, pin >=6.13.3
    "defusedxml" # have 0.8.0rc2 (prerelease), pin >=0.7.1
  ];

  dependencies = builtins.attrValues {
    inherit (python3Packages)
      fastapi
      fastmcp
      google-api-python-client
      google-auth-httplib2
      google-auth-oauthlib
      httpx
      urllib3
      py-key-value-aio
      pyjwt
      python-dotenv
      pyyaml
      cryptography
      defusedxml
      pypdf
      pytz
      markdown-it-py
      ;
  };

  # Flat top-level layout (main.py + core/, auth/, g* service packages; no
  # namespace package). `import main` is cheap — it defers heavy imports into a
  # function. `import core.server` constructs the SecureFastMCP(FastMCP) server
  # object at module load, exercising fastmcp 3.2.4 compatibility at build time.
  pythonImportsCheck = [
    "main"
    "core.server"
  ];

  meta = {
    description = "MCP server exposing Google Workspace (Gmail, Drive, Calendar, Docs, Sheets, …) as tools";
    homepage = "https://github.com/taylorwilsdon/google_workspace_mcp";
    license = lib.licenses.mit;
    mainProgram = "workspace-mcp";
  };
}
