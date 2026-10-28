{ pkgs }:

let
  # Qwen3.5 2B instruct (Apache-2.0), Q4_K_M, at the GGUF repo's revision of
  # 2026-03-02: the smallest model that named all 6 sample sessions well on a
  # laptop CPU (the 0.8B copied the prompt's examples). 1.3 GB.
  model = pkgs.fetchurl {
    url = "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/f6d5376be1edb4d416d56da11e5397a961aca8ae/Qwen3.5-2B-Q4_K_M.gguf";
    hash = "sha256-qvQsi3w8qyvz1pw1UEjUoO6Zc9SPFscxwFIO6RRpkiM=";
  };
in
pkgs.buildGoModule {
  pname = "tmux-session-name";
  version = "0.4.0";
  src = ./.;
  vendorHash = null;
  ldflags = [
    "-X main.llamaCompletion=${pkgs.llama-cpp}/bin/llama-completion"
    "-X main.modelPath=${model}"
  ];
}
