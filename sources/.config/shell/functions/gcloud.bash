#!/bin/bash

# Adds a version to the secret named $1. The value is read without echo and
# reaches gcloud on stdin, so it never shows on the command line or in the
# shell history.
__gcloud_secret_set() {
  local value
  printf 'value: ' >&2
  IFS= read -rs value || return
  echo >&2
  printf %s "$value" | gcloud secrets versions add "$1" --data-file=-
}
