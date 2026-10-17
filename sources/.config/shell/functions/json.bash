#!/bin/bash

# Converts the JSON in the clipboard to a JSON string, then prints and copies it
__json_to_string() {
  __paste | jq '@json' | tee >(__copy)
}

# Converts the JSON string in the clipboard back to JSON, then prints and
# copies it
__json_from_string() {
  __paste | jq '.' | tee >(__copy)
}

# Pretty-prints the JSON, or the JSON string, in the clipboard
__json_pretty() {
  __paste | jq --raw-output '.' | jq --color-output '.'
}
