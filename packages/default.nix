{ pkgs, claudeSandbox }:
import ./commons.nix { inherit pkgs; }
++ import ./custom.nix { inherit pkgs; }
# github:Runeword/claude-sandbox: on Linux the launcher claude.bash starts
# claude through and the helpers it runs by bare name, on macOS the credential
# launcher. On the host PATH, where claude.bash and the launcher look for them.
++ [ claudeSandbox.default ]
++ (
  if pkgs.stdenv.hostPlatform.isDarwin then
    import ./darwin.nix { inherit pkgs; }
  else
    import ./linux.nix { inherit pkgs; }
)
