#!/usr/bin/env bash
set -euo pipefail

CONTEXT_FILE=".repomix-output.txt"
OUTPUT_FILE="README.md"

if [[ ! -f "$CONTEXT_FILE" ]]; then
  echo "Error: $CONTEXT_FILE not found. Run repomix first."
  exit 1
fi

if [[ -z "${GOOGLE_API_KEY:-}" ]]; then
  echo "Error: GOOGLE_API_KEY not set"
  exit 1
fi

PROMPT="You are documenting a Nix flakes project. Generate a comprehensive README.md that includes:

1. Project overview (what it does, why it exists)
2. Quick start (nix run, nix develop)
3. Architecture overview (flake structure, key directories)
4. Configuration (dev vs bundled mode)
5. Available tools and wrappers
6. Customization guide

Use the repository context provided. Be concise but thorough. Output only the markdown content, no explanations."

CONTEXT=$(cat "$CONTEXT_FILE")

# Build JSON payload to temp file to avoid arg length limits
PAYLOAD_FILE=$(mktemp)
trap 'rm -f "$PAYLOAD_FILE"' EXIT

jq -n --arg prompt "$PROMPT" \
  '{
    contents: [
      { role: "user", parts: [{ text: $prompt }] },
      { role: "user", parts: [{ text: "" }] }
    ]
  }' >"$PAYLOAD_FILE"

# Inject context from file (avoids shell arg limits)
jq --slurpfile ctx <(jq -Rs . "$CONTEXT_FILE") \
  '.contents[1].parts[0].text = $ctx[0]' "$PAYLOAD_FILE" >"$PAYLOAD_FILE.tmp" &&
  mv "$PAYLOAD_FILE.tmp" "$PAYLOAD_FILE"

RESPONSE=$(curl -s "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$GOOGLE_API_KEY" \
  -H "Content-Type: application/json" \
  -d "@$PAYLOAD_FILE")

echo "$RESPONSE" | jq -r '.candidates[0].content.parts[0].text' >"$OUTPUT_FILE"

echo "Generated $OUTPUT_FILE"
