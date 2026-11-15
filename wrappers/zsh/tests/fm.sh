# shellcheck shell=bash disable=SC2016
# A template: Nix fills in each @…@ with a store path from this topic's row
# in ../default.nix before the check runs this file.
# SC2016 is off: the single-quoted code is for the zsh under test to expand.
#
# fm.sh and its scripts: __open_file, __open_recent, and Shift+Tab's
# search (fm_rg.sh, fm_preview.sh).

# __open_file hands the editor its picks after --: nvim runs a +cmd
# argument, so a file named "+so x.vim" would source x.vim.
mkdir -p "$HOME/pick" "$HOME/stub" && : >"$HOME/pick/+so x.vim"
printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' >"$HOME/stub/ed" && chmod +x "$HOME/stub/ed"
pick='. @zsh@/.config/shell/functions/fm.sh
  fd() { printf "+so x.vim\0"; }
  fzf() { tr "\0" "\n"; }
  __open_file'
if [ "$(cd "$HOME/pick" && EDITOR=$HOME/stub/ed @zsh@/bin/zsh -f -c "$pick")" = "$(printf -- '--\n+so x.vim')" ]; then
  ok "__open_file hands the editor its picks after --"
else
  fail "__open_file hands the editor its picks where an option goes"
fi

# __open_recent offers nvim's oldfiles newest first, read from the
# viminfofile the nvim config keeps under $XDG_CACHE_HOME: a stand-in
# nvim answers for that file only, a stand-in fzf picks the first line.
touch "$HOME/a" "$HOME/b"
recent='. @zsh@/.config/shell/functions/fm.sh
  nvim() {
    if [ "$1 $2 $3" = "-es -i $XDG_CACHE_HOME/nvim/viminfo" ]; then
      printf "1: %s\n2: %s\n" "$HOME/b" "$HOME/a" > "${4#+redir! > }"
    else
      printf "%s\n" "$*"
    fi
  }
  fzf() { head -n 1; }
  __open_recent'
if [ "$(XDG_CACHE_HOME=$HOME/cache @zsh@/bin/zsh -f -c "$recent")" = "$HOME/b" ]; then
  ok "__open_recent offers nvim's recent files newest first"
else
  fail "__open_recent does not offer nvim's recent files newest first"
fi

# Shift+Tab's search (fm_rg.sh) lists dotfiles too, as the rows fm.sh's
# binds read: a header per file, then each match; fields 2-4 are path,
# line, H|M. It skips .git, even with a plain rg like this one.
mkdir -p "$HOME/rg/.hidden" "$HOME/rg/.git" && printf 'x\nhello world\n' | tee "$HOME/rg/.git/config" >"$HOME/rg/.hidden/a.txt"
rgrows() { (cd "$1" && PATH=@ripgrep@/bin:@fmQuery@/bin:$PATH sh @zsh@/.config/shell/scripts/fm_rg.sh 'hel wor' | cut -f2-4); }
if [ "$(rgrows "$HOME/rg")" = "$(printf '.hidden/a.txt\t2\tH\n.hidden/a.txt\t2\tM')" ]; then
  ok "Shift+Tab's search lists a dotfile's match under its header, with its path and line, and skips .git"
else
  fail "Shift+Tab's search does not list a dotfile's match as header and match rows, or lists .git"
fi

# In $HOME it also skips $HOME's own big trees (fm_home.ignore), whose
# patterns rg anchors at its working directory: anywhere else they
# would hide a project's own go/pkg.
mkdir -p "$HOME/go/pkg" "$HOME/rg/go/pkg" && printf 'hello world\n' | tee "$HOME/go/pkg/c.txt" >"$HOME/rg/go/pkg/b.txt"
if rgrows "$HOME/rg" | cut -f1 | grep -qx go/pkg/b.txt && ! rgrows "$HOME" | cut -f1 | grep -qx go/pkg/c.txt; then
  ok "Shift+Tab's search skips \$HOME's own go/pkg in \$HOME only, not a project's"
else
  fail "Shift+Tab's search lists \$HOME's own go/pkg in \$HOME, or skips a project's"
fi

# Its preview strips a file's escape sequences (an OSC 8 link here), so
# nothing in a searched file can drive the terminal through fzf.
printf 'x \033]8;;http://e.x\033\\link\033]8;;\033\\ y\n' >"$HOME/esc.txt"
if FZF_PREVIEW_LINES=10 sh @zsh@/.config/shell/scripts/fm_preview.sh "$HOME/esc.txt" 1 "" | grep -q "$(printf '\033]')"; then
  fail "the search preview passes a file's escape sequences to fzf"
else
  ok "the search preview strips a file's escape sequences"
fi

# It never puts the previewed file in tree-sitter's working directory,
# where a tree-sitter.json is read as a grammar's: a stand-in
# tree-sitter says whether it finds one there.
mkdir -p "$HOME/ts/bin" && printf '{}\n' >"$HOME/ts/tree-sitter.json"
printf '#!/bin/sh\n[ -e tree-sitter.json ] && echo GRAMMAR\nexit 0\n' >"$HOME/ts/bin/tree-sitter" && chmod +x "$HOME/ts/bin/tree-sitter"
if FZF_PREVIEW_LINES=10 PATH="$HOME/ts/bin:$PATH" sh @zsh@/.config/shell/scripts/fm_preview.sh "$HOME/ts/tree-sitter.json" 1 "" | grep -q GRAMMAR; then
  fail "the search preview puts a tree-sitter.json in tree-sitter's working directory"
else
  ok "the search preview keeps the previewed file out of tree-sitter's working directory"
fi

# The search binds nothing to y either, so that y types into its query:
# a stand-in fzf says whether it was handed a binding for y.
rgy='. @zsh@/.config/shell/functions/fm.sh
  fzf() { case "$*" in *"--bind y:"* | *",y:"*) echo y >&2 ;; *) echo none >&2 ;; esac; return 130; }
  __ripgrep'
if [ "$(@zsh@/bin/zsh -f -c "$rgy" 2>&1)" = none ]; then
  ok "Shift+Tab's search binds nothing to y, which types into its query"
else
  fail "Shift+Tab's search binds y, which then does not type into its query"
fi

# Several picks open as a quickfix list set from them as they are (nvim
# -q would read them back through 'errorformat', which misreads many
# lines), with absolute paths; a picked header stands for its file's
# first match, another file's match picked or not. A runtime dir that
# is set but missing gives way to TMPDIR.
mkdir -p "$HOME/qf"
rgqf='. @zsh@/.config/shell/functions/fm.sh
  fzf() { printf "b.txt\tb.txt\t2\tH\n  3:x\tc.txt\t3\tM\n"; }
  __ripgrep'
if [ "$(cd "$HOME/qf" && XDG_RUNTIME_DIR=$HOME/missing @zsh@/bin/zsh -f -c "$rgqf")" = "nvim -c 'call setqflist([{\"filename\": \"$HOME/qf/b.txt\", \"lnum\": 2}, {\"filename\": \"$HOME/qf/c.txt\", \"lnum\": 3}])' -c cfirst" ]; then
  ok "Shift+Tab's search opens several picks, a header among them, as a quickfix list with absolute paths"
else
  fail "Shift+Tab's search does not open several picks as a quickfix list set from them, with absolute paths"
fi
