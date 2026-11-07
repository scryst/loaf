#!/bin/sh
# Claude Code hook for Loaf: `loaf-busy-hook.sh touch` (UserPromptSubmit, PreToolUse, PostToolUse) marks this session as
# working, `loaf-busy-hook.sh remove` (Stop, SessionEnd) clears it. The hook JSON arrives on stdin; only session_id is used.
# Loaf counts a session busy while its file was touched in the last 3 minutes. Always exits 0: it must never fail or slow a session.
# Shell builtins only on the touch path: it runs twice per tool call, so it starts no process beyond this shell.
d="$HOME/Library/Application Support/Loaf/busy"
input=
while IFS= read -r line || [ -n "$line" ]; do input="$input$line"; done
case "$input" in *'"session_id"'*) ;; *) exit 0 ;; esac
id=${input#*\"session_id\"}
id=${id#*\"}
id=${id%%\"*}
case "$id" in ''|*[!A-Za-z0-9_-]*) exit 0 ;; esac
case "$1" in
  touch) [ -d "$d" ] || /bin/mkdir -p "$d" 2>/dev/null; : > "$d/$id" 2>/dev/null ;;
  remove) /bin/rm -f "$d/$id" 2>/dev/null ;;
esac
exit 0
