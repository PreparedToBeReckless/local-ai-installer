#!/usr/bin/env bash
# Double-clickable entry — opens this wizard in Terminal (no Automation permissions)
DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$DIR/installer_wizard.sh"