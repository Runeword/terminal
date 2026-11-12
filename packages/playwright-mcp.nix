{ pkgs }:

let
  bin = "${pkgs.coreutils}/bin";

  # A scratch home of the server's own: Claude's sandbox keeps the real one
  # read-only, and neither Playwright (its ms-playwright cache) nor Chromium
  # (its crash reports) starts without writable folders there. Per user, and
  # checked as theirs, since /tmp is shared. Every PLAYWRIGHT_MCP_* a plugin's
  # env carries is dropped first, so none of it can override the settings below
  # or the in-memory profile nixpkgs' own wrapper turns on.
  setup = ''
    __pw="''${TMPDIR:-/tmp}/playwright-mcp-$(${bin}/id -u)"
    ${bin}/mkdir -m 700 "$__pw" 2> /dev/null || [ -d "$__pw" ] || exit 1
    [ -O "$__pw" ] || { printf 'playwright-mcp: %s is not yours\n' "$__pw" >&2; exit 1; }
    for v in "''${!PLAYWRIGHT_MCP_@}"; do unset "$v"; done
    export HOME="$__pw/home"
    export XDG_CACHE_HOME="$HOME/.cache" XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
    export PLAYWRIGHT_MCP_OUTPUT_DIR="$__pw/output"
    ${bin}/mkdir -p "$HOME"
  '';
in
# nixpkgs' Playwright MCP, whose browsers are nixpkgs' prebuilt Playwright ones,
# so nothing compiles on either platform.
pkgs.symlinkJoin {
  name = "playwright-mcp-${pkgs.playwright-mcp.version}";
  paths = [ pkgs.playwright-mcp ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  # CAPS: testing adds the browser_verify_* tools, which record assertions, and
  # devtools adds traces and videos of a session to replay. WEBMCP: no tools
  # from the pages it visits.
  postBuild = ''
    wrapProgram $out/bin/playwright-mcp \
      --run ${pkgs.lib.escapeShellArg setup} \
      --set PLAYWRIGHT_MCP_CAPS testing,devtools \
      --set PLAYWRIGHT_MCP_WEBMCP false
  '';
}
