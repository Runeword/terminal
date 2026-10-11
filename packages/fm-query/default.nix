{ pkgs }:

pkgs.buildGoModule {
  pname = "fm-query";
  version = "0.2.0";
  src = ./.;
  # Stdlib only — no dependency vendoring required.
  vendorHash = null;
  # TestPrefilterIsNecessary runs each prefilter through rg, as fm_rg.sh does.
  nativeCheckInputs = [ pkgs.ripgrep ];
}
