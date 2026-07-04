#!/usr/bin/env bash
# Build Local-AI-Studio-Installer.dmg (no code signing required for local use)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
STAGING="$ROOT/dist/dmg-staging"
APP_TERMINAL="Install Local AI Studio.app"
APP_GUI="Install Local AI Studio (GUI).app"
DMG_NAME="Local-AI-Studio-Installer.dmg"
VOLUME_NAME="Local AI Studio"

echo "═══ Building $DMG_NAME ═══"

"$ROOT/assets/build-ai-studio-web.sh"

rm -rf "$ROOT/dist"
mkdir -p "$STAGING"

cp -R "$ROOT/app/$APP_TERMINAL" "$STAGING/"
cp -R "$ROOT/app-gui/$APP_GUI" "$STAGING/"

install_app_icon() {
  local app="$1"
  [[ -f "$ROOT/assets/AppIcon.icns" ]] || return 0
  cp "$ROOT/assets/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
}

bundle_resources() {
  local res="$1"
  mkdir -p "$res/lib"
  cp "$ROOT/install-local-ai.sh" "$res/"
  cp "$ROOT/stop-install.sh" "$res/"
  cp "$ROOT/installer_gui.py" "$res/"
  cp "$ROOT/studio_launcher.py" "$res/"
  cp "$ROOT/desktop_shortcuts.py" "$res/"
  cp "$ROOT/installer_wizard.sh" "$res/"
  cp "$ROOT/installer_fallback.sh" "$res/"
  cp "$ROOT/installer_native.sh" "$res/"
  cp "$ROOT/Start Local AI Install.command" "$res/"
  cp "$ROOT/Start Local AI Install (GUI).command" "$res/"
  cp "$ROOT/lib/models-catalog.sh" "$res/lib/"
  cp "$ROOT/lib/size-estimates.sh" "$res/lib/"
  cp "$ROOT/lib/audit-install.sh" "$res/lib/"
  mkdir -p "$res/docs"
  cp "$ROOT/docs/RAM_AND_MODELS.md" "$res/docs/"
  mkdir -p "$res/scripts"
  cp "$ROOT/scripts/free-ram-for-ai.sh" "$res/scripts/"
  chmod +x "$res/scripts/free-ram-for-ai.sh"
  mkdir -p "$res/assets"
  cp -R "$ROOT/assets/AI-Studio-Web.app" "$res/assets/"
  chmod +x "$res/assets/AI-Studio-Web.app/Contents/MacOS/ai-studio-web"
  chmod +x "$res/install-local-ai.sh"
  chmod +x "$res/stop-install.sh"
  chmod +x "$res/installer_gui.py"
  chmod +x "$res/studio_launcher.py"
  chmod +x "$res/desktop_shortcuts.py"
  chmod +x "$res/installer_wizard.sh"
  chmod +x "$res/installer_fallback.sh"
  chmod +x "$res/installer_native.sh"
  chmod +x "$res/Start Local AI Install.command"
  chmod +x "$res/Start Local AI Install (GUI).command"
}

for app in "$APP_TERMINAL" "$APP_GUI"; do
  bundle_resources "$STAGING/$app/Contents/Resources"
  install_app_icon "$STAGING/$app"
  chmod +x "$STAGING/$app/Contents/MacOS/install"
done

# Keep source apps in sync
bundle_resources "$ROOT/app/$APP_TERMINAL/Contents/Resources"
install_app_icon "$ROOT/app/$APP_TERMINAL"
chmod +x "$ROOT/app/$APP_TERMINAL/Contents/MacOS/install"
bundle_resources "$ROOT/app-gui/$APP_GUI/Contents/Resources"
install_app_icon "$ROOT/app-gui/$APP_GUI"
chmod +x "$ROOT/app-gui/$APP_GUI/Contents/MacOS/install"

# Also copy launchers to DMG root for easy access
cp "$ROOT/Start Local AI Install.command" "$STAGING/"
cp "$ROOT/Start Local AI Install (GUI).command" "$STAGING/"
chmod +x "$STAGING/Start Local AI Install.command"
chmod +x "$STAGING/Start Local AI Install (GUI).command"

cat > "$STAGING/README.txt" <<'README'
LOCAL AI STUDIO — INSTALLER DMG
═══════════════════════════════

DISCLAIMER — hobby project, not a serious product.
  Upstream links/apps change without warning. Installs can break randomly.
  Dozens of separate devs' projects; nobody pays us to keep URLs current.
  Use for fun. See README.md in the GitHub repo for the full speech.

QUICK START
  1. Best: drag GUI app to Desktop. OK to run from DMG — last SSD path is remembered in ~/.local-ai-studio-installer.json
  2. Plug in external SSD, launch app, pick STANDARD ★, click INSTALL
  3. Watch green SSD line grow (e.g. "26 GB → ~110 GB target") — 2–4+ hrs
  4. OK to close window — install keeps running; re-open app to watch
  5. When done: "Launch AI Studio.command" on Desktop

TWO INSTALLERS (same backend):
  GUI:      Install Local AI Studio (GUI).app  (progress bar + live SSD GB)
  Terminal: Install Local AI Studio.app       (always shows text)

FRESH MAC (one-time):
  • Apple Command Line Tools — installer opens dialog if needed
  • Homebrew + Ollama — installed for you
  • One or two login-password prompts is normal

DURING INSTALL
  • Progress % tracks SSD size vs tier target (not stuck on one number)
  • Mac sleep prevented (caffeinate) — keep plugged in
  • Log: /tmp/local-ai-installer-*.log

RE-RUN / RESUME
  • Safe to run again — scans SSD vs catalog, fills gaps only
  • Skips Ollama models already downloaded
  • Interrupted? Keep LOCAL_AI_GEN folder, click INSTALL again

TIERS (SSD / Mac internal — measured on real install):
  STARTER ~55 GB / ~6 GB  |  STANDARD ~110 GB / ~6 GB  ★ M4 16GB
  PRO ~135 GB / ~6-8 GB   |  ULTIMATE ~150 GB / ~6-8 GB (full install ≈147 GB)

Full docs: github.com/PreparedToBeReckless/local-ai-installer
README

ln -s /Applications "$STAGING/Applications"

rm -f "$ROOT/dist/$DMG_NAME"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$ROOT/dist/$DMG_NAME"

echo ""
echo "✓ Built: $ROOT/dist/$DMG_NAME"
echo "  Terminal: $APP_TERMINAL"
echo "  GUI:      $APP_GUI"
du -sh "$ROOT/dist/$DMG_NAME"