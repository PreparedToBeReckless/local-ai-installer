#!/usr/bin/env bash
# Native macOS fallback installer — no Python required (brand-new Mac friendly)
set -euo pipefail

RES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$RES/install-local-ai.sh"
[[ -x "$INSTALLER" ]] || INSTALLER="$(dirname "$RES")/install-local-ai.sh"

source "$RES/lib/size-estimates.sh" 2>/dev/null || true

pick_tier() {
  osascript <<'AS' 2>/dev/null || true
set t to choose from list ¬
  {"STARTER — ~80 GB on SSD, ~6 GB internal", ¬
   "STANDARD — ~150 GB SSD — Recommended", ¬
   "PRO — ~200 GB SSD, full editing", ¬
   "ULTIMATE — ~280 GB SSD, complete catalog"} ¬
  with title "Local AI Studio" ¬
  with prompt "Choose install package:" ¬
  default items {"STANDARD — ~150 GB SSD — Recommended"}
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
  local vol free labels="" script
  while IFS= read -r vol; do
    case "$vol" in
      Macintosh\ HD|Macintosh\ HD\ *|Preboot|Recovery|Update|VM|Data) continue ;;
    esac
    [[ -d "/Volumes/$vol" ]] || continue
    free=$(df -g "/Volumes/$vol" 2>/dev/null | awk 'NR==2 {print $4}')
    labels+="\"$vol ($free GB free)\", "
  done < <(ls /Volumes 2>/dev/null)

  if [[ -z "$labels" ]]; then
    osascript -e 'display alert "No External Drive" message "Plug in your SSD, then run the installer again."' 2>/dev/null
    return 1
  fi

  labels="${labels%, }"
  script="choose from list {$labels} with title \"Local AI Studio\" with prompt \"Select external SSD:\""
  local choice
  choice=$(osascript -e "$script" 2>/dev/null || true)
  [[ -n "$choice" && "$choice" != "false" ]] || return 1
  echo "/Volumes/${choice%% (*}"
}

main() {
  [[ -x "$INSTALLER" ]] || {
    osascript -e 'display alert "Error" message "install-local-ai.sh not found."' 2>/dev/null
    exit 1
  }

  osascript -e 'display alert "Native Installer Mode" message "Using built-in Mac dialogs (no Python needed).\n\nYou will see tier + drive pickers, then Terminal for download progress."' 2>/dev/null || true

  local tier ssd
  tier=$(pick_tier)
  [[ -n "$tier" ]] || exit 0

  ssd=$(pick_drive) || exit 0

  local ext int
  ext=$(tier_external_gb "$tier" 2>/dev/null || echo "?")
  int=$(tier_internal_typical_gb "$tier" 2>/dev/null || echo "6")

  osascript -e "display alert \"Ready to Install\" message \"Tier: ${tier^^}\nSSD: ${ssd}\n\n~${ext} GB on external drive\n~${int} GB on Mac internal (Homebrew, Ollama, Docker)\n\nTerminal will open for downloads.\"" 2>/dev/null || true

  local cmd="bash $(printf '%q' "$INSTALLER") --tier $(printf '%q' "$tier") --ssd $(printf '%q' "$ssd") --no-gui"
  osascript -e "tell application \"Terminal\" to do script \"$cmd\"" 2>/dev/null \
    || { echo "Run manually: $cmd"; read -r -p "Press Enter..." _; }
}

main "$@"