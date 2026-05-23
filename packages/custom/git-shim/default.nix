{ pkgs }:

pkgs.buildGoModule {
  pname = "git-shim";
  version = "0.1.0";
  src = ./.;
  vendorHash = "sha256-pbA/AlBz3cQYRTMnQ/qBPcinYOKokrBLNhkbRTq54gE=";
  ldflags = [
    "-s"
    "-w"
    "-X"
    "main.realGit=${pkgs.git}/bin/git"
  ];
  # The Go binary is built from the module name (git-shim). Rename to "git"
  # so that, when this derivation is added first to PATH in the claude
  # wrapper, real-git lookups resolve to the shim.
  postInstall = ''
    mv $out/bin/git-shim $out/bin/git
  '';
}
