_: prev: {
  tmux = prev.tmux.overrideAttrs {
    version = "3.6a";
    src = prev.fetchFromGitHub {
      owner = "tmux";
      repo = "tmux";
      tag = "3.6a";
      hash = "sha256-VwOyR9YYhA/uyVRJbspNrKkJWJGYFFktwPnnwnIJ97s=";
    };
  };
}
