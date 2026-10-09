#!/bin/sh
# PostToolUse hook: check the comments of the Swift file just written or edited.
file=$(python3 -c 'import json, sys; print(json.load(sys.stdin).get("tool_input", {}).get("file_path", ""))')
case "$file" in
  *.swift) ;;
  *) exit 0 ;;
esac
cd "$CLAUDE_PROJECT_DIR" || exit 0
python3 tools/check_comments.py check --base HEAD "$file" >&2
# Status 2 hands the report on stderr back to the agent; checker errors (2) do not block.
[ $? -eq 1 ] && exit 2
exit 0
