#!/bin/sh

# Respect the XDG Base Directory Specification to reduce clutter in the home directory

export XDG_DATA_DIRS="/usr/local/share:/usr/share:/var/lib/flatpak/exports/share:${HOME}/.local/share/flatpak/exports/share:$XDG_DATA_DIRS"
export XDG_CONFIG_DIRS="/etc/xdg"
export XDG_CACHE_HOME="${HOME}/.cache"
export XDG_CONFIG_HOME="${HOME}/.config"
export XDG_DATA_HOME="${HOME}/.local/share"
export XDG_STATE_HOME="${HOME}/.local/state"
export XDG_BIN_HOME="${HOME}/.local/bin"

# Create directories in background for faster startup (silenced)
{
  mkdir -p \
    "${XDG_DATA_HOME}/cargo" \
    "${XDG_CONFIG_HOME}/docker" \
    "${XDG_DATA_HOME}/go" \
    "${XDG_CACHE_HOME}/npm" \
    "${XDG_CONFIG_HOME}/npm" \
    "${XDG_CONFIG_HOME}/npm/config" \
    "$XDG_DATA_HOME" \
    "${XDG_CONFIG_HOME}/aws" \
    "${XDG_CONFIG_HOME}/notmuch" \
    "${XDG_CONFIG_HOME}/gnupg" \
    "${XDG_DATA_HOME}/pyenv" \
    "${XDG_CONFIG_HOME}/atac" \
    "${XDG_CONFIG_HOME}/nixos" \
    "${XDG_DATA_HOME}/password-store" \
    "${XDG_DATA_HOME}/android" \
    "${XDG_DATA_HOME}/android/sdk" \
    "${XDG_STATE_HOME}/bash" \
    "${XDG_CONFIG_HOME}/gtk-2.0" \
    "${XDG_STATE_HOME}/less" \
    "$XDG_CACHE_HOME" \
    "${XDG_CACHE_HOME}/X11" \
    "${XDG_DATA_HOME}/minikube" \
    "${XDG_CONFIG_HOME}/java" \
    "${XDG_CONFIG_HOME}/kube" \
    "${XDG_CONFIG_HOME}/helm"
} >/dev/null 2>&1 &!


export CARGO_HOME="${XDG_DATA_HOME}/cargo"
export DOCKER_CONFIG="${XDG_CONFIG_HOME}/docker"
export GOPATH="${XDG_DATA_HOME}/go"
export NPM_CONFIG_CACHE="${XDG_CACHE_HOME}/npm"
export NPM_CONFIG_USERCONFIG="${XDG_CONFIG_HOME}/npm/npmrc"
export NPM_CONFIG_INIT_MODULE="${XDG_CONFIG_HOME}/npm/config/npm-init.js"
export NODE_REPL_HISTORY="${XDG_DATA_HOME}/node_repl_history"
export AWS_CONFIG_FILE="${XDG_CONFIG_HOME}/aws/config"
export NOTMUCH_CONFIG="${XDG_CONFIG_HOME}/notmuch/config"
export GNUPGHOME="${XDG_CONFIG_HOME}/gnupg"
export PYENV_ROOT="${XDG_DATA_HOME}/pyenv"
export ATAC_KEY_BINDINGS="${XDG_CONFIG_HOME}/atac/vim_key_bindings.toml"
export ATAC_THEME="${XDG_CONFIG_HOME}/atac/theme.toml"
export NIXOS_CONFIG="${XDG_CONFIG_HOME}/nixos/configuration.nix"
export PASSWORD_STORE_DIR="${XDG_DATA_HOME}/password-store"
export ANDROID_USER_HOME="${XDG_DATA_HOME}/android"
export ANDROID_HOME="${XDG_DATA_HOME}/android/sdk"
export HISTFILE="${XDG_STATE_HOME}/bash/history"
export GTK2_RC_FILES="${XDG_CONFIG_HOME}/gtk-2.0/gtkrc"
export LESSHISTFILE="${XDG_STATE_HOME}/less/history"
export ICEAUTHORITY="${XDG_CACHE_HOME}/ICEauthority"
export XCOMPOSECACHE="${XDG_CACHE_HOME}/X11/xcompose"
export MINIKUBE_HOME="${XDG_DATA_HOME}/minikube"
export _JAVA_OPTIONS="-Djava.util.prefs.userRoot=${XDG_CONFIG_HOME}/java"
export KUBECONFIG="$XDG_CONFIG_HOME/kube/config"
export HELM_CONFIG_HOME="$XDG_CONFIG_HOME/helm"
