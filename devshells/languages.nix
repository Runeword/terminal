{ pkgs }:
let
  inherit (pkgs) lib stdenv;
in
pkgs.mkShell {
  buildInputs = [
    pkgs.go
  ]
  # libseccomp for the claude-seccomp-bpf cgo build. golangci-lint's typecheck
  # compiles the package, so lint-go needs the same libs the Nix build declares
  # (packages/custom/claude-seccomp-bpf/default.nix). Linux-only — the flake also
  # targets aarch64-darwin, where this package isn't built.
  ++ lib.optionals stdenv.hostPlatform.isLinux [ pkgs.libseccomp ];
  # pkg-config resolves libseccomp's cflags/libs during cgo compilation; without it
  # on PATH, lint-go fails with `exec: "pkg-config": executable file not found`.
  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [ pkgs.pkg-config ];
}
