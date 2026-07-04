#!/usr/bin/env bash
# Compile AI Studio Web — native WKWebView localhost viewer (no Chrome/Safari required).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/ai-studio-web/AIStudioWeb.swift"
APP="$ROOT/AI-Studio-Web.app"
BIN="$APP/Contents/MacOS/ai-studio-web"
FALLBACK="$APP/Contents/MacOS/ai-studio-web-fallback.sh"

mkdir -p "$(dirname "$BIN")"

if [[ ! -f "$SRC" ]]; then
  echo "✗ Missing $SRC" >&2
  exit 1
fi

if command -v swiftc &>/dev/null; then
  echo "→ Compiling AI Studio Web (WKWebView)…"
  swiftc -O \
    -target arm64-apple-macos13.0 \
    -o "$BIN" \
    "$SRC" \
    -framework Cocoa \
    -framework WebKit
  chmod +x "$BIN"
  echo "✓ Built native AI Studio Web → $BIN"
  exit 0
fi

echo "⚠ swiftc not found — using shell fallback (needs Chrome or Safari)" >&2
if [[ -f "$FALLBACK" ]]; then
  cp "$FALLBACK" "$BIN"
  chmod +x "$BIN"
  exit 0
fi

echo "✗ No swiftc and no fallback script at $FALLBACK" >&2
exit 1