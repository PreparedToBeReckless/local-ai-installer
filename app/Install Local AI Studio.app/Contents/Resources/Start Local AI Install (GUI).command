#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
export TK_SILENCE_DEPRECATION=1
export PYTHONNOUSERSITE=1

for PY in "/Library/Developer/CommandLineTools/usr/bin/python3" "/usr/bin/python3"; do
  [[ -x "$PY" ]] || continue
  if arch -arm64 "$PY" -c "import tkinter" 2>/dev/null; then
    exec arch -arm64 "$PY" "$DIR/installer_gui.py"
  fi
done

echo "Python with tkinter not found."
echo "Use 'Start Local AI Install.command' (Terminal version) instead."
read -r -p "Press Enter..."