{ pkgs }:

pkgs.buildGoModule {
  pname = "git-allowlist-hook";
  version = "0.1.0";
  src = ./.;
  vendorHash = "sha256-PTDoBIcjAOkc3PbCv7DC9MFZasXiVxixTMtb5I9YFCc=";
}
