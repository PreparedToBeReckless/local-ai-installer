#!/usr/bin/env bash
# 100% native Mac installer — no Python, no Accessibility prompts, text always visible
set -euo pipefail

RES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$RES/install-local-ai.sh"
source "$RES/lib/size-estimates.sh" 2>/dev/null || true

pick_tier() {
  osascript <<'AS'
set t to choose from list ¬
  {"STARTER — ~80 GB SSD, ~6 GB Mac internal", ¬
   "STANDARD — ~150 GB SSD — Recommended for M4 16GB", ¬
   "PRO — ~200 GB SSD, full photo editing", ¬
   "ULTIMATE — ~280 GB SSD, complete catalog"} ¬
  with title "Local AI Studio — Step 1 of 3" ¬
  with prompt "Choose your install package:" ¬
  default items {"STANDARD — ~150 GB SSD — Recommended for M4 16GB"}
if t is false then return ""
set s to item 1 of t
if s contains "STARTER" then return "starter"
if s contains "STANDARD" then return "standard"
if s contains "PRO" then return "pro"
if s contains "ULTIMATE" then return "ultimate"
return ""
AS
}

pick_drive() {
  local labels="" vol free
  while IFS= read -r vol; do
    case "$vol" in
      Macintosh\ HD|Macintosh\ HD\ *|Preboot|Recovery|Update|VM|Data) continue ;;
    esac
    [[ -d "/Volumes/$vol" ]] || continue
    free=$(df -g "/Volumes/$vol" 2>/dev/null | awk 'NR==2 {print $4}')
    labels+="\"$vol ($free GB free)\", "
  done < <(ls /Volumes 2>/dev/null)

  if [[ -z "$labels" ]]; then
    osascript -e 'display alert "No SSD Found" message "Plug in your external SSD and try again."' 2>/dev/null
    return 1
  fi

  labels="${labels%, }"
  local choice
  choice=$(osascript -e "choose from list {$labels} with title \"Local AI Studio — Step 2 of 3\" with prompt \"Select external SSD:\"" 2>/dev/null || true)
  if [[ -z "$choice" || "$choice" == "false" ]]; then
    choice=$(osascript -e 'POSIX path of (choose folder with prompt "Select external SSD or folder:")' 2>/dev/null || true)
    [[ -n "$choice" ]] && { echo "$choice"; return 0; }
    return 1
  fi
  echo "/Volumes/${choice%% (*}"
}

main() {
  [[ -x "$INSTALLER" ]] || {
    osascript -e 'display alert "Error" message "install-local-ai.sh missing."' 2>/dev/null
    exit 1
  }

  osascript -e 'display alert "Local AI Studio" message "Welcome! This installer uses native Mac dialogs (no Python).\n\nYou will pick:\n1) Install package\n2) External SSD\n3) Confirm, then Terminal opens for downloads."' 2>/dev/null || true

  local tier ssd ext int
  tier=$(pick_tier)
  [[ -n "$tier" ]] || exit 0

  ssd=$(pick_drive) || exit 0

  ext=$(tier_external_gb "$tier" 2>/dev/null || echo 150)
  int=$(tier_internal_typical_gb "$tier" 2>/dev/null || echo 6)

  osascript -e "display alert \"Confirm Install\" message \"Package: ${tier^^}\nSSD: ${ssd}\n\n~${ext} GB on external drive\n~${int} GB on Mac internal\n\nTerminal opens next for progress.\"" 2>/dev/null || true

  local cmd="bash $(printf '%q' "$INSTALLER") --tier $(printf '%q' "$tier") --ssd $(printf '%q' "$ssd") --no-gui"
  osascript -e "tell application \"Terminal\" to activate" -e "tell application \"Terminal\" to do script \"$cmd\"" 2>/dev/null \
    || osascript -e "do shell script \"$cmd\"" 2>/dev/null
}

main "$@"