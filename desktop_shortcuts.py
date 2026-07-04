#!/usr/bin/env python3
"""Create Desktop shortcuts — intended to run from the installer GUI (not a bash child)."""

from __future__ import annotations

import os
import shutil
import sys

INFO_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>launcher</string>
    <key>CFBundleIdentifier</key>
    <string>com.localai.studio.launcher</string>
    <key>CFBundleName</key>
    <string>AI Studio Launcher</string>
    <key>CFBundleDisplayName</key>
    <string>AI Studio Launcher</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSArchitecturePriority</key>
    <array><string>arm64</string></array>
</dict>
</plist>
"""


def clear_path(path: str) -> None:
    if not os.path.lexists(path):
        return
    if os.path.islink(path) or os.path.isfile(path):
        os.remove(path)
    else:
        shutil.rmtree(path)


def create_desktop_shortcuts(ssd_volume: str) -> list[str]:
    """
    ssd_volume = install parent (e.g. /Volumes/MySSD or /Volumes/MySSD/AI_INSTALLS).
    Returns list of created Desktop item names.
    """
    root = os.path.join(ssd_volume, "LOCAL_AI_GEN")
    hub = os.path.join(root, "AI Studio Apps")
    scripts = os.path.join(root, "scripts")
    launch_sh = os.path.join(scripts, "launch-ai-studio.sh")
    if not os.path.isdir(root):
        raise FileNotFoundError(f"Install folder not found: {root}")

    desktop = os.path.expanduser("~/Desktop")
    os.makedirs(desktop, exist_ok=True)
    created: list[str] = []

    if os.path.isfile(launch_sh):
        cmd_path = os.path.join(desktop, "Launch AI Studio.command")
        clear_path(cmd_path)
        with open(cmd_path, "w", encoding="utf-8") as fh:
            fh.write("#!/usr/bin/env bash\n")
            fh.write(f'exec "{launch_sh}"\n')
        os.chmod(cmd_path, 0o755)
        created.append("Launch AI Studio.command")

    if os.path.isdir(hub):
        apps_link = os.path.join(desktop, "AI Studio Apps")
        clear_path(apps_link)
        os.symlink(hub, apps_link)
        created.append("AI Studio Apps")

    py = os.path.join(scripts, "studio_launcher.py")
    if os.path.isfile(py):
        app = os.path.join(desktop, "AI Studio Launcher.app")
        clear_path(app)
        macos_dir = os.path.join(app, "Contents", "MacOS")
        os.makedirs(macos_dir, exist_ok=True)
        launcher = os.path.join(macos_dir, "launcher")
        with open(launcher, "w", encoding="utf-8") as fh:
            fh.write("#!/bin/bash\n")
            fh.write(f'exec /usr/bin/python3 "{py}"\n')
        os.chmod(launcher, 0o755)
        with open(os.path.join(app, "Contents", "Info.plist"), "w", encoding="utf-8") as fh:
            fh.write(INFO_PLIST)
        created.append("AI Studio Launcher.app")

    return created


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: desktop_shortcuts.py /Volumes/YourSSD[/optional/subfolder]", file=sys.stderr)
        return 1
    try:
        items = create_desktop_shortcuts(sys.argv[1].rstrip("/"))
    except OSError as exc:
        print(f"Failed: {exc}", file=sys.stderr)
        return 1
    if not items:
        print("Nothing created — install may still be in progress.", file=sys.stderr)
        return 1
    print("Created on Desktop:", ", ".join(items))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())