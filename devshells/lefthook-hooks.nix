# The lefthook hooks this repository enables. The dev shell installs them as
# its git hooks (lefthook.nix); claude's PATH carries the format hooks' tools,
# for claude-format, which runs this repository's formatters after each edit
# (wrappers/claude.nix).
{
  format-go.enable = true;
  lint-go.enable = true;
  format-nix.enable = true;
  lint-nix.enable = true;
  format-shell.enable = true;
  lint-shell.enable = true;
  format-toml.enable = true;
  format-yaml.enable = true;
  security-gitleaks.enable = true;
  auto-commit.enable = true;
}
