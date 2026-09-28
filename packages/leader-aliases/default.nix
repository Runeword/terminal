{ pkgs }:

pkgs.buildGoModule {
  pname = "leader-aliases";
  version = "0.1.0";
  src = ./.;
  vendorHash = "sha256-pbA/AlBz3cQYRTMnQ/qBPcinYOKokrBLNhkbRTq54gE=";
}
