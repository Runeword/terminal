{
  pkgs,
  # Path the shim exec's after the allowlist check. Defaults to raw nixpkgs git
  # for standalone use; callers (notably wrappers/claude.nix) can override with
  # the wrapped git so config (excludesFile, pager, includes) is consistent
  # whether git is invoked inside or outside a claude session.
  realGit ? "${pkgs.git}/bin/git",
}:

pkgs.buildGoModule {
  pname = "git-shim";
  version = "0.1.0";
  src = ./.;
  vendorHash = "sha256-pbA/AlBz3cQYRTMnQ/qBPcinYOKokrBLNhkbRTq54gE=";
  ldflags = [
    "-s"
    "-w"
    "-X"
    "main.realGit=${realGit}"
  ];
  # The Go binary is built from the module name (git-shim). Rename to "git"
  # so that, when this derivation is added first to PATH in the claude
  # wrapper, real-git lookups resolve to the shim.
  postInstall = ''
    mv $out/bin/git-shim $out/bin/git
  '';
}
