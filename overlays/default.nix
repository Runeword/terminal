{ pkgs-24-05, pkgs-25-11 }:
[
  (final: prev: {
    awscli2 = pkgs-24-05.awscli2;
    tmux = pkgs-25-11.tmux;
  })
  (final: prev: {
    firebase-tools = prev.firebase-tools.override {
      buildNpmPackage = prev.buildNpmPackage.override {
        nodejs = prev.nodejs_20;
      };
    };
  })
]
