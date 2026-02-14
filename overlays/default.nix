{ pkgs-24-05 }:
[
  (final: prev: { awscli2 = pkgs-24-05.awscli2; })
  (final: prev: {
    firebase-tools = prev.firebase-tools.override {
      buildNpmPackage = prev.buildNpmPackage.override {
        nodejs = prev.nodejs_20;
      };
    };
  })
]
