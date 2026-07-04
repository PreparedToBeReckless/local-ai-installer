#!/bin/bash
# Fallback when native WKWebView binary was not compiled — needs Chrome or Safari.
set -euo pipefail

url="${1:-http://127.0.0.1:8188}"

open_chrome_app() {
  local bin="$1"
  "$bin" \
    --app="$url" \
    --new-window \
    --no-first-run \
    --disable-features=TranslateUI \
    --disable-sync \
    &>/dev/null &
}

for bin in \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  "/Applications/Chromium.app/Contents/MacOS/Chromium" \
  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
  "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
  "/Applications/Arc.app/Contents/MacOS/Arc"; do
  if [[ -x "$bin" ]]; then
    open_chrome_app "$bin"
    exit 0
  fi
done

open -na "Safari" "$url"