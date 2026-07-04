#!/usr/bin/env bash
# Stop a background Local AI Studio install (GUI or Terminal).
set -euo pipefail

PID_FILE="/tmp/local-ai-installer.pid"

kill_tree() {
  local pid="$1" sig="$2" child
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    kill_tree "$child" "$sig"
  done
  kill "-$sig" "$pid" 2>/dev/null || true
}

try_stop() {
  local pid="$1" sig="$2"
  kill_tree "$pid" "$sig"
}

collect_pids() {
  local pid
  if [[ -f "$PID_FILE" ]]; then
    read -r pid <"$PID_FILE" || true
    if [[ -n "${pid:-}" ]]; then
      echo "$pid"
    fi
  fi
  pgrep -f "install-local-ai\\.sh" 2>/dev/null || true
  pgrep -f "caffeinate.*install-local-ai" 2>/dev/null || true
}

stopped=0
seen="|"
while IFS= read -r pid; do
  [[ -z "$pid" ]] && continue
  case "$seen" in *"|${pid}|"*) continue ;; esac
  seen="${seen}${pid}|"
  if kill -0 "$pid" 2>/dev/null; then
    if [[ "$stopped" -eq 0 ]]; then
      echo "Stopping Local AI Studio install…"
    fi
    echo "  → SIGTERM PID $pid"
    try_stop "$pid" TERM
    stopped=1
  fi
done < <(collect_pids | sort -u)

if [[ "$stopped" -eq 0 ]]; then
  echo "No background install found (nothing in $PID_FILE, no install-local-ai.sh process)."
  exit 0
fi

sleep 2

while IFS= read -r pid; do
  [[ -z "$pid" ]] && continue
  if kill -0 "$pid" 2>/dev/null; then
    echo "  → SIGKILL PID $pid"
    try_stop "$pid" KILL
  fi
done < <(collect_pids | sort -u)

rm -f "$PID_FILE" 2>/dev/null || true
echo "Install stopped. Progress on your SSD is saved — click INSTALL again to resume."