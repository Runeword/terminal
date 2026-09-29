#!/bin/bash

# fzf layout shared by the aws pickers (mirrors git.bash) — array form so values
# with spaces or quotes round-trip through "${arr[@]}" without re-parsing.
_AWS_FZF=(
  --reverse --no-separator --keep-right
  --border none
  --cycle
  --height 70%
  --info=inline:
  --header-first
  '--prompt=  '
  --wrap-sign=
  --scheme=path
)

# Pick an AWS profile with fzf and start an SSO login for it. On success,
# export AWS_PROFILE so the chosen profile stays active in the current shell.
__aws_login() {
  local profiles selected
  profiles=$(aws configure list-profiles) || return 1
  [ "$profiles" = "" ] && return 1

  selected=$(echo "$profiles" | fzf "${_AWS_FZF[@]}") || return 0
  [ "$selected" = "" ] && return 1

  aws sso login --profile "$selected" && export AWS_PROFILE="$selected"
}

__aws_role_policies() {
  aws iam list-attached-role-policies --role-name "$(aws sts get-caller-identity --query "Arn" --output text | cut -d'/' -f2)"
}

# Pick a Lambda with fzf and emit a ready-to-run invoke command — the leader
# alias fills it onto the prompt for you to complete. Replace the Payload
# placeholder before running; the command prints the decoded Tail log and
# discards the response body.
__aws_lambda_invoke() {
  local selected
  selected=$(aws lambda list-functions | jq -r '.Functions[].FunctionName' | fzf "${_AWS_FZF[@]}") || return 0
  [ "$selected" = "" ] && return 1

  echo "aws lambda invoke --cli-read-timeout 0 --function-name \"$selected\" --cli-binary-format raw-in-base64-out --payload Payload --log-type Tail --query 'LogResult' --output text /dev/null | base64 --decode"
}
