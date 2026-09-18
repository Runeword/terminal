{ pkgs }:

pkgs.buildGoModule {
  pname = "claude-seccomp-bpf";
  version = "0.1.0";
  src = ./.;
  vendorHash = "sha256-ZJSOzYK+Uq6WrGPUKhTuNDT109VMRtOsy1OVdOUMb/E=";
  # cgo: libseccomp-golang binds the system libseccomp via pkg-config.
  nativeBuildInputs = [ pkgs.pkg-config ];
  buildInputs = [ pkgs.libseccomp ];
  ldflags = [
    "-s"
    "-w"
  ];
}
