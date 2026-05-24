{ pkgs }:

[
  (pkgs.buildGoModule {
    pname = "git-branches";
    version = "0.1.0";
    src = ./git-branches;
    vendorHash = "sha256-uqVw/+79vkCQCF4QdP5LIo8CWdUoXRDaWFhYwr5QbT4=";
  })
]
