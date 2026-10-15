#!/bin/bash
# code-guard terraform pack: PostToolUse(Edit|Write). Run terraform fmt on an edited .tf / .tfvars file.
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
pack_on terraform || exit 0
command -v jq >/dev/null || exit 0
f="$(jq -r '.tool_response.filePath // .tool_input.file_path // ""')"
case "$f" in
  *.tf|*.tfvars) command -v terraform >/dev/null && terraform fmt "$f" >/dev/null ;;
esac
exit 0
