#!/usr/bin/env bash
# Free RAM for AI — quit background apps, keep Finder. Safe curated list only.
set -euo pipefail

warn() { echo "⚠ $*" >&2; }
ok() { echo "✓ $*"; }

confirm_free_ram() {
  osascript <<'APPLESCRIPT' 2>/dev/null || echo "Cancel"
set dlg to display alert "Free RAM for AI?" message "Quits browsers, Docker, chat/creative apps, menu-bar helpers, and any running ComfyUI/Ollama/WebUI.

Keeps Finder. Does not quit System Settings or the installer.

Then open ONE shortcut: ComfyUI, DiffusionBee, or LM Studio." buttons {"Cancel", "Free RAM"} default button "Free RAM"
return button returned of dlg
APPLESCRIPT
}

memory_free_mb() {
  # Available RAM-ish from vm_stat (approximate on Apple Silicon).
  local page_size pages_free
  page_size=$(vm_stat 2>/dev/null | awk '/page size of/ {print $8}' | tr -d '.')
  pages_free=$(vm_stat 2>/dev/null | awk '/Pages free/ {print $3}' | tr -d '.')
  [[ -n "$page_size" && -n "$pages_free" ]] || return 1
  echo $(( pages_free * page_size / 1024 / 1024 ))
}

quit_app() {
  local app="$1"
  osascript -e "tell application \"$app\" to quit" 2>/dev/null && ok "Quit $app" || true
}

quit_bundle() {
  local bid="$1" label="${2:-$1}"
  osascript -e "tell application id \"$bid\" to quit" 2>/dev/null && ok "Quit $label" || true
}

stop_local_ai_services() {
  # ComfyUI on :8188
  local pid
  pid=$(lsof -ti :8188 2>/dev/null | head -1)
  if [[ -n "$pid" ]]; then
    kill "$pid" 2>/dev/null || true
    ok "Stopped ComfyUI (pid $pid)"
  fi

  # Ollama serve
  if pgrep -x ollama &>/dev/null; then
    pkill -x ollama 2>/dev/null || true
    ok "Stopped Ollama"
  fi

  # Open WebUI container + Docker (big RAM on 16GB Macs)
  if command -v docker &>/dev/null; then
    docker stop open-webui &>/dev/null && ok "Stopped Open WebUI container" || true
  fi
  quit_app "Docker"
  quit_app "Docker Desktop"
}

quit_background_apps() {
  # Browsers & web shells
  local app
  for app in \
    "Google Chrome" "Chromium" "Safari" "Firefox" "Arc" \
    "Microsoft Edge" "Brave Browser" "Opera" "Vivaldi" \
    "AI Studio Web"; do
    quit_app "$app"
  done

  # AI / creative (restart fresh from shortcuts after this script)
  for app in \
    "LM Studio" "DiffusionBee" "Draw Things" \
    "Automatic1111" "InvokeAI" "Msty" "GPT4All"; do
    quit_app "$app"
  done

  # Chat & meetings
  for app in \
    "Slack" "Discord" "Microsoft Teams" "Zoom" "Skype" \
    "Telegram" "WhatsApp" "Signal" "FaceTime"; do
    quit_app "$app"
  done

  # Media
  for app in \
    "Spotify" "Music" "TV" "Podcasts" "VLC" "IINA" "QuickTime Player"; do
    quit_app "$app"
  done

  # Productivity / notes
  for app in \
    "Notion" "Obsidian" "Evernote" "Bear" "Todoist" "Things3" "Microsoft Outlook" \
    "Mail" "Calendar" "Reminders" "Notes"; do
    quit_app "$app"
  done

  # Dev tools (often huge RAM) — skip Terminal/iTerm so .command shortcuts can finish
  for app in \
    "Cursor" "Visual Studio Code" "Code" "Xcode" \
    "GitHub Desktop" "Sourcetree" "Postman" "Insomnia"; do
    quit_app "$app"
  done

  # Adobe / creative cloud
  for app in \
    "Adobe Photoshop" "Adobe Lightroom" "Adobe Premiere Pro" \
    "Adobe Creative Cloud" "Affinity Photo" "Affinity Designer" "Final Cut Pro" \
    "Logic Pro" "Pixelmator Pro"; do
    quit_app "$app"
  done

  # Games & launchers
  for app in "Steam" "Epic Games Launcher" "Battle.net"; do
    quit_app "$app"
  done

  # Menu-bar / background helpers (bundle ID — works when app has no main window)
  quit_bundle "com.spotify.client" "Spotify"
  quit_bundle "com.dropbox.client" "Dropbox"
  quit_bundle "com.google.GoogleDrive" "Google Drive"
  quit_bundle "com.microsoft.OneDrive" "OneDrive"
  quit_bundle "com.1password.1password" "1Password"
  quit_bundle "com.bitwarden.desktop" "Bitwarden"
  quit_bundle "com.runningwithcrayons.Alfred" "Alfred"
  quit_bundle "com.raycast.macos" "Raycast"
  quit_bundle "com.bjango.istatmenus" "iStat Menus"
  quit_bundle "com.objective-see.lulu" "LuLu"
  quit_bundle "com.macpaw.CleanMyMac4" "CleanMyMac"
  quit_bundle "com.adobe.AdobeCreativeCloud" "Adobe Creative Cloud"
  quit_bundle "com.elgato.CameraHub" "Elgato Camera Hub"
  quit_bundle "com.logi.ghub" "Logi G Hub"
  quit_bundle "com.nordvpn.macos" "NordVPN"
  quit_bundle "com.tinyspeck.slackmacgap" "Slack"
  quit_bundle "com.hnc.Discord" "Discord"
  quit_bundle "com.openai.chat" "ChatGPT"
  quit_bundle "com.anthropic.claudefordesktop" "Claude"
}

main() {
  [[ "$(confirm_free_ram)" == "Free RAM" ]] || { echo "Cancelled."; exit 0; }

  local before after
  before=$(memory_free_mb 2>/dev/null || echo "?")

  echo ""
  echo "═══ Freeing RAM for AI ═══"
  stop_local_ai_services
  quit_background_apps

  # Encourage macOS to reclaim inactive memory (no sudo).
  sync 2>/dev/null || true
  sleep 2
  after=$(memory_free_mb 2>/dev/null || echo "?")

  echo ""
  if [[ "$before" != "?" && "$after" != "?" ]]; then
    ok "Approx free RAM: ${before} MB → ${after} MB"
    osascript -e "display notification \"Free RAM ~${after} MB. Open one AI Studio shortcut.\" with title \"Free RAM for AI\"" 2>/dev/null || true
  else
    ok "Done — open one AI Studio shortcut (ComfyUI, DiffusionBee, …)"
    osascript -e 'display notification "Background apps quit. Open one AI Studio shortcut." with title "Free RAM for AI"' 2>/dev/null || true
  fi
  echo ""
  echo "Tip: on 16 GB Macs see docs/RAM_AND_MODELS.txt — one heavy app at a time."
}

main "$@"