#!/bin/sh

# Respect the XDG Base Directory Specification to reduce clutter in the home directory

export XDG_DATA_DIRS="/usr/local/share:/usr/share:/var/lib/flatpak/exports/share:${HOME}/.local/share/flatpak/exports/share:$XDG_DATA_DIRS"
export XDG_CONFIG_DIRS="/etc/xdg"
export XDG_CACHE_HOME="${HOME}/.cache"
export XDG_CONFIG_HOME="${HOME}/.config"
export XDG_DATA_HOME="${HOME}/.local/share"
export XDG_STATE_HOME="${HOME}/.local/state"
export XDG_BIN_HOME="${HOME}/.local/bin"

mkdir -p "${XDG_DATA_HOME}/cargo"
export CARGO_HOME="${XDG_DATA_HOME}/cargo"

mkdir -p "${XDG_CONFIG_HOME}/docker"
export DOCKER_CONFIG="${XDG_CONFIG_HOME}/docker"

mkdir -p "${XDG_DATA_HOME}/go"
export GOPATH="${XDG_DATA_HOME}/go"

mkdir -p "${XDG_CACHE_HOME}/npm"
export NPM_CONFIG_CACHE="${XDG_CACHE_HOME}/npm"

mkdir -p "${XDG_CONFIG_HOME}/npm"
export NPM_CONFIG_USERCONFIG="${XDG_CONFIG_HOME}/npm/npmrc"

mkdir -p "${XDG_CONFIG_HOME}/npm/config"
export NPM_CONFIG_INIT_MODULE="${XDG_CONFIG_HOME}/npm/config/npm-init.js"

mkdir -p "$XDG_DATA_HOME"
export NODE_REPL_HISTORY="${XDG_DATA_HOME}/node_repl_history"

mkdir -p "${XDG_CONFIG_HOME}/aws"
export AWS_CONFIG_FILE="${XDG_CONFIG_HOME}/aws/config"

mkdir -p "${XDG_CONFIG_HOME}/notmuch"
export NOTMUCH_CONFIG="${XDG_CONFIG_HOME}/notmuch/config"

mkdir -p "${XDG_CONFIG_HOME}/gnupg"
export GNUPGHOME="${XDG_CONFIG_HOME}/gnupg"

mkdir -p "${XDG_DATA_HOME}/pyenv"
export PYENV_ROOT="${XDG_DATA_HOME}/pyenv"

mkdir -p "${XDG_CONFIG_HOME}/readline"
export INPUTRC="${XDG_CONFIG_HOME}/readline/inputrc"

mkdir -p "${XDG_CONFIG_HOME}/atac"
export ATAC_KEY_BINDINGS="${XDG_CONFIG_HOME}/atac/vim_key_bindings.toml"
export ATAC_THEME="${XDG_CONFIG_HOME}/atac/theme.toml"

mkdir -p "${XDG_CONFIG_HOME}/nixos"
export NIXOS_CONFIG="${XDG_CONFIG_HOME}/nixos/configuration.nix"

mkdir -p "${XDG_DATA_HOME}/password-store"
export PASSWORD_STORE_DIR="${XDG_DATA_HOME}/password-store"

mkdir -p "${XDG_DATA_HOME}/android"
export ANDROID_USER_HOME="${XDG_DATA_HOME}/android"

mkdir -p "${XDG_DATA_HOME}/android/sdk"
export ANDROID_HOME="${XDG_DATA_HOME}/android/sdk"

mkdir -p "${XDG_STATE_HOME}/bash"
export HISTFILE="${XDG_STATE_HOME}/bash/history"

mkdir -p "${XDG_CONFIG_HOME}/gtk-2.0"
export GTK2_RC_FILES="${XDG_CONFIG_HOME}/gtk-2.0/gtkrc"

mkdir -p "${XDG_STATE_HOME}/less"
export LESSHISTFILE="${XDG_STATE_HOME}/less/history"

mkdir -p "$XDG_CACHE_HOME"
export ICEAUTHORITY="${XDG_CACHE_HOME}/ICEauthority"

mkdir -p "${XDG_CACHE_HOME}/X11"
export XCOMPOSECACHE="${XDG_CACHE_HOME}/X11/xcompose"

mkdir -p "${XDG_DATA_HOME}/minikube"
export MINIKUBE_HOME="${XDG_DATA_HOME}/minikube"

mkdir -p "${XDG_CONFIG_HOME}/java"
export _JAVA_OPTIONS="-Djava.util.prefs.userRoot=${XDG_CONFIG_HOME}/java"

mkdir -p "${XDG_CONFIG_HOME}/kube"
export KUBECONFIG="$XDG_CONFIG_HOME/kube/config"

mkdir -p "${XDG_CONFIG_HOME}/helm"
export HELM_CONFIG_HOME="$XDG_CONFIG_HOME/helm"
