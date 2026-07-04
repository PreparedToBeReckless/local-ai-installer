#!/usr/bin/env bash
RES="$(cd "$(dirname "$0")" && pwd)"
clear
echo "═══════════════════════════════════════════════════"
echo "  LOCAL AI STUDIO INSTALLER"
echo "  Log: /tmp/local-ai-installer*.log"
echo "═══════════════════════════════════════════════════"
echo ""
bash "$RES/install-local-ai.sh"
EXIT=$?
echo ""
if [[ $EXIT -eq 0 ]]; then
  echo "✓ Install finished successfully."
else
  echo "✗ Install ended with errors (code $EXIT). Check log above."
fi
echo ""
echo "Press any key to close this window..."
read -r -n 1 _