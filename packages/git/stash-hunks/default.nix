{ pkgs }:

pkgs.buildGoModule {
  pname = "git-stash-hunks";
  version = "0.1.0";
  src = ./.;
  # Stdlib only — no dependency vendoring required.
  vendorHash = null;
  # The round-trip test drives a real repo, so git must be on the check PATH.
  nativeCheckInputs = [ pkgs.git ];
}
