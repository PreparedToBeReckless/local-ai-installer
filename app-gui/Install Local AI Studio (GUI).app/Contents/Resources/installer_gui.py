#!/usr/bin/env python3
"""
Local AI Studio — Visual Installer GUI
Tier picker + drive selector + live progress log
"""

import glob
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import sys
import time
import subprocess
import threading
import tkinter as tk
from tkinter import ttk, messagebox

# ── Theme ────────────────────────────────────────────────────────────────────
BG       = "#0d1117"
BG_CARD  = "#161b22"
BG_SEL   = "#1f2a44"
ACCENT   = "#ff6b35"
ACCENT2  = "#4ecdc4"
TEXT     = "#f0f6fc"
TEXT_DIM = "#8b949e"
GREEN    = "#3fb950"
RED      = "#f85149"
YELLOW   = "#d29922"
BORDER   = "#30363d"
FIELD_BG = "#21262d"
FIELD_BORDER = "#484f58"


TIER_TIME_EST = {
    "starter": "1–2 hours",
    "standard": "2–4 hours",
    "pro": "3–5 hours",
    "ultimate": "4–7 hours",
}

TIER_SSD_GB = {
    "starter": 55,
    "standard": 110,
    "pro": 135,
    "ultimate": 150,
}
# Recommended free space on SSD (matches lib/size-estimates.sh tier_drive_min_gb)
TIER_DRIVE_MIN_GB = {
    "starter": 70,
    "standard": 130,
    "pro": 160,
    "ultimate": 175,
}

UNFILTERED_PACK_GB = 150
UNFILTERED_PACK_DRIVE_GB = 165
MODELS_ONLY_DRIVE_BUFFER = 25
MODELS_ONLY_PACK_TIME = "3–6 hours"

STALL_ALERT_SEC = 300  # no log lines this long → may be waiting on a Mac folder-access popup
PERMISSION_NOTIFY_PHASES = ("comfyui", "gui apps", "photoreal", "folder structure")
MAC_PERMISSION_HELP = """Two different Mac windows (don't mix them up)
────────────────────────────────────────

A) ALLOW SSD ACCESS (orange button — before INSTALL)
   Normal folder picker. Select your install folder (e.g. AI_INSTALLS)
   and click Open.

B) POPUP DURING INSTALL (if you still get them)
   NOT a browser — macOS asks which drive Terminal/bash may write to.
   LEFT SIDEBAR → single-click drive ONCE → Open (don't double-click).

To STOP repeated popups during install (best fix):
  1. Click "Mac Settings Fix"
  2. Privacy & Security → Full Disk Access
  3. Add "Install Local AI Studio (GUI)" (or Python) → ON
  4. Quit this installer completely, reopen, Allow SSD Access, INSTALL again

Also try Files and Folders → Removable Volumes → ON for the same app."""

FOLDER_PICKER_HINT = (
    "Mac folder popup? Sidebar → click your SSD once (top level) → Open. "
    "Don't drill into subfolders."
)


def macos_ask_string(prompt, title="Input", default=""):
    """Native Mac text dialog — paints reliably unlike tkinter Entry in .app bundles."""
    prompt_esc = prompt.replace("\\", "\\\\").replace('"', '\\"')
    title_esc = title.replace("\\", "\\\\").replace('"', '\\"')
    default_esc = (default or "").replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")
    script = f'''
    try
        set token to text returned of (display dialog "{prompt_esc}" default answer "{default_esc}" with title "{title_esc}")
        return token
    on error
        return ""
    end try
    '''
    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True,
            text=True,
            timeout=300,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return (result.stdout or "").strip()


def macos_choose_folder(prompt="Select your external SSD or install folder", initial="/Volumes"):
    """Native Mac folder picker — tkinter filedialog breaks on /Volumes for many users."""
    if not os.path.isdir(initial):
        initial = os.path.expanduser("~")
    prompt_esc = prompt.replace('"', '\\"')
    initial_esc = initial.replace('"', '\\"')
    script = f'''
    set defaultPath to POSIX file "{initial_esc}"
    try
        set chosen to choose folder with prompt "{prompt_esc}" default location defaultPath
        return POSIX path of chosen
    on error
        return ""
    end try
    '''
    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True,
            text=True,
            timeout=180,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    path = (result.stdout or "").strip()
    if path and os.path.isdir(path):
        return path.rstrip("/")
    return None


def ssd_volume_root(path):
    """Top-level /Volumes/Drive for TCC grant — not a subfolder."""
    path = (path or "").strip().rstrip("/")
    if not path:
        return ""
    if path.startswith("/Volumes/"):
        parts = [p for p in path.split("/") if p]
        if parts:
            return f"/Volumes/{parts[0]}"
    return path


SSD_SEAL_SUBDIRS = (
    "", "Applications", "installers", "ollama-models", "open-webui",
    "lm-studio-models", "comfyui", "comfyui/ComfyUI", "comfyui/ComfyUI/custom_nodes",
    "scripts", "docs", "workflows", "AI Studio Apps",
    "comfyui-models/checkpoints", "comfyui-models/loras", "comfyui-models/vae",
    "comfyui-models/controlnet", "comfyui-models/upscale_models",
    "comfyui-models/clip", "comfyui-models/unet",
    "comfyui-models/diffusion_models", "comfyui-models/ipadapter",
    "comfyui-models/clip_vision",
)


def prepare_ssd_layout_from_gui(ssd_volume):
    """Create LOCAL_AI_GEN folders from the GUI app — same permission as install."""
    ok, result = seal_ssd_access_deep(ssd_volume)
    if not ok:
        raise OSError(result)
    return result


def seal_internal_comfyui_support(ssd_volume):
    """Pre-touch internal ComfyUI venv path from the GUI app (ExFAT SSDs use internal Python)."""
    base = os.path.expanduser("~/Library/Application Support/LocalAIStudio")
    try:
        os.makedirs(base, exist_ok=True)
        with open(os.path.join(base, ".gui-access-ok"), "w", encoding="utf-8") as fh:
            fh.write("ok\n")
        external = os.path.join(ssd_volume.rstrip("/"), "LOCAL_AI_GEN")
        digest = hashlib.sha256(external.encode("utf-8")).hexdigest()[:12]
        venv = os.path.join(base, f"comfyui-venv-{digest}")
        os.makedirs(venv, exist_ok=True)
        with open(os.path.join(venv, ".gui-access-ok"), "w", encoding="utf-8") as fh:
            fh.write("ok\n")
    except OSError:
        pass


def comfyui_ready_on_ssd(ssd_volume):
    """True when ComfyUI clone + internal venv exist — safe to skip comfy step."""
    root = os.path.join(ssd_volume.rstrip("/"), "LOCAL_AI_GEN", "comfyui", "ComfyUI")
    if not os.path.isdir(os.path.join(root, ".git")):
        return False
    if not os.path.isfile(os.path.join(root, "extra_model_paths.yaml")):
        if not os.path.isdir(os.path.join(root, "models")) and not os.path.islink(
            os.path.join(root, "models")
        ):
            return False
    base = os.path.expanduser("~/Library/Application Support/LocalAIStudio")
    external = os.path.join(ssd_volume.rstrip("/"), "LOCAL_AI_GEN")
    digest = hashlib.sha256(external.encode("utf-8")).hexdigest()[:12]
    venv_py = os.path.join(base, f"comfyui-venv-{digest}", "bin", "python")
    if os.path.isfile(venv_py):
        return True
    for match in glob.glob(os.path.join(base, "comfyui-venv-*", "bin", "python")):
        if os.path.isfile(match):
            return True
    return False


def studio_ready_on_ssd(ssd_volume):
    """True when a prior full studio install likely exists (ComfyUI on SSD)."""
    return comfyui_ready_on_ssd(ssd_volume)


def seal_ssd_access_deep(ssd_volume):
    """Create install folders + write-test each from the GUI (one permission identity)."""
    root = os.path.join(ssd_volume.rstrip("/"), "LOCAL_AI_GEN")
    errors = []
    for sub in SSD_SEAL_SUBDIRS:
        dirpath = os.path.join(root, sub) if sub else root
        try:
            os.makedirs(dirpath, exist_ok=True)
            marker = os.path.join(dirpath, ".gui-ssd-access")
            with open(marker, "w", encoding="utf-8") as fh:
                fh.write("ok\n")
        except OSError as exc:
            errors.append(f"{dirpath}: {exc}")
    if errors:
        return False, "\n".join(errors[:6])
    return True, root


def open_mac_full_disk_access_settings():
    """Full Disk Access — most reliable way to stop repeated removable-volume popups."""
    for url in (
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
    ):
        try:
            subprocess.run(["open", url], check=False, timeout=8)
            return True
        except OSError:
            continue
    return open_mac_removable_volume_settings()


def open_mac_removable_volume_settings():
    """Open System Settings → Privacy → Files and Folders (Removable Volumes)."""
    for url in (
        "x-apple.systempreferences:com.apple.preference.security?Privacy_RemovableVolume",
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_RemovableVolume",
    ):
        try:
            subprocess.run(["open", url], check=False, timeout=8)
            return True
        except OSError:
            continue
    try:
        subprocess.run(
            ["open", "/System/Applications/System Settings.app"],
            check=False, timeout=8,
        )
    except OSError:
        pass
    return False


def verify_ssd_writable(path):
    """Write-test from this app — same Mac permission identity as the GUI."""
    test_dir = os.path.join(path, "LOCAL_AI_GEN")
    test_file = os.path.join(test_dir, ".write-access-test")
    try:
        os.makedirs(test_dir, exist_ok=True)
        with open(test_file, "w", encoding="utf-8") as fh:
            fh.write("ok\n")
        os.remove(test_file)
        return True, ""
    except OSError as exc:
        return False, str(exc)


def create_desktop_shortcuts_for(ssd_volume):
    """Create Desktop launcher items from the GUI process (not bash child)."""
    mod_path = os.path.join(script_dir(), "desktop_shortcuts.py")
    if not os.path.isfile(mod_path):
        return False, "desktop_shortcuts.py missing from installer bundle"
    try:
        result = subprocess.run(
            [sys.executable, mod_path, ssd_volume.rstrip("/")],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return False, str(exc)
    if result.returncode == 0:
        return True, (result.stdout or "").strip()
    err = (result.stderr or result.stdout or "unknown error").strip()
    return False, err


def macos_notify(title, message, urgent=False):
    """macOS notification — works while installer GUI is open."""
    title_esc = title.replace('"', '\\"')
    msg_esc = message.replace('"', '\\"').replace("\n", " ")[:220]
    sound = "Basso" if urgent else "Submarine"
    subprocess.run(
        ["osascript", "-e",
         f'display notification "{msg_esc}" with title "{title_esc}" sound name "{sound}"'],
        check=False,
        capture_output=True,
    )
    if urgent:
        try:
            subprocess.Popen(
                ["afplay", "/System/Library/Sounds/Basso.aiff"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except OSError:
            pass


# Rough progress % when each installer step starts (parsed from log headers).
INSTALL_PHASES = [
    ("Install status", 3, "Checking SSD vs catalog"),
    ("Preflight", 4, "Checking your Mac"),
    ("Folder structure", 7, "Creating folders on SSD"),
    ("Environment", 9, "Setting up paths"),
    ("Homebrew", 12, "Homebrew (may ask password)"),
    ("Ollama (binary", 18, "Ollama setup (usually no password via Homebrew)"),
    ("Ollama photoreal", 32, "Downloading Ollama models (30–90 min)"),
    ("GUI apps", 42, "Downloading LM Studio & DiffusionBee"),
    ("Open WebUI", 50, "Open WebUI / Docker"),
    ("ComfyUI + editing", 62, "Installing ComfyUI + Python"),
    ("ComfyUI photoreal", 78, "Downloading image models (longest step)"),
    ("Writing guides", 96, "Writing guides"),
    ("Desktop launcher", 98, "Creating Desktop launcher"),
    ("Size report", 99, "Final size check"),
]

TIERS = [
    {
        "id": "starter",
        "name": "STARTER",
        "size": "~55 GB SSD",
        "internal": "~6 GB Mac",
        "emoji": "⚡",
        "tagline": "Fast and lean — quick setup, fast portraits",
        "summary": "Core apps + essential Flux/SDXL models for photoreal portraits.",
        "badge": None,
        "detail": (
            "Best for: quick setup, smaller SSD, fast portraits\n\n"
            "Apps & tools:\n"
            "  • LM Studio, DiffusionBee, ComfyUI + Manager, Open WebUI\n"
            "  • ComfyUI nodes: Manager, IP-Adapter+, ControlNet aux\n\n"
            "Models installed:\n"
            "  Ollama:\n"
            "    - Flux Klein 4B, Z-Image Turbo, Moondream\n"
            "  ComfyUI checkpoints:\n"
            "    - RealVisXL V5, CyberRealistic V7\n"
            "    - Flux Schnell FP8 + Flux VAE\n"
            "  Upscalers:\n"
            "    - 4x UltraSharp, Real-ESRGAN x4\n\n"
            "~55 GB on SSD  |  ~6 GB on Mac internal\n"
            "(Homebrew, Ollama, Docker on Mac — models/apps on SSD)"
        ),
    },
    {
        "id": "standard",
        "name": "STANDARD",
        "size": "~110 GB SSD",
        "internal": "~6 GB Mac",
        "emoji": "⭐",
        "tagline": "Recommended for M4 16GB MacBook Air",
        "summary": "Full editing starter kit — best balance for your Mac.",
        "badge": "RECOMMENDED",
        "detail": (
            "Best for: your MacBook Air — full editing without bloat\n\n"
            "Apps & tools (adds to Starter):\n"
            "  • ComfyUI nodes: Impact Pack, WAS suite, Essentials\n\n"
            "New models in this tier:\n"
            "  Ollama:\n"
            "    - Flux Klein 9B, Llama 3.2 Vision 11B\n"
            "  ComfyUI checkpoints:\n"
            "    - Juggernaut XL v9, epiCRealism XL, Flux Dev FP8\n"
            "  Editing models:\n"
            "    - IP-Adapter Plus SDXL, ControlNet Depth + Canny\n"
            "  LM Studio (MLX):\n"
            "    - Qwen2.5-VL 7B (photo captions & analysis)\n\n"
            "Also includes all Starter models (RealVisXL V5, CyberRealistic,\n"
            "Flux Schnell, Z-Image Turbo, Flux Klein 4B, upscalers, etc.)\n\n"
            "~110 GB on SSD  |  ~6 GB on Mac internal"
        ),
    },
    {
        "id": "pro",
        "name": "PRO",
        "size": "~135 GB SSD",
        "internal": "~6-8 GB Mac",
        "emoji": "🎨",
        "tagline": "Serious photo editing and relighting",
        "summary": "Relight, faceswap, inpaint, upscale — edit existing photos.",
        "badge": None,
        "detail": (
            "Best for: serious photo editing and relighting\n\n"
            "Apps & tools (adds to Standard):\n"
            "  • ComfyUI nodes: IC-Light, InstantID, KJNodes\n\n"
            "New models in this tier:\n"
            "  Ollama:\n"
            "    - LLaVA 7B, Llama 3.2 3B (prompt helper)\n"
            "  ComfyUI checkpoints:\n"
            "    - RealVisXL V4, SD 3.5 Medium\n"
            "  Editing models:\n"
            "    - Flux IP-Adapter, CLIP Vision encoder\n"
            "    - IC-Light relighting, Detail Booster LoRA\n"
            "  LM Studio (MLX):\n"
            "    - Gemma 3 12B (vision reasoning for edits)\n\n"
            "Also includes all Standard + Starter models\n\n"
            "~135 GB on SSD  |  ~6-8 GB on Mac internal"
        ),
    },
    {
        "id": "ultimate",
        "name": "ULTIMATE",
        "size": "~150 GB SSD",
        "internal": "~6-8 GB Mac",
        "emoji": "🔥",
        "tagline": "Complete photoreal catalog",
        "summary": "Every curated model + room to grow.",
        "badge": "MAX PACK",
        "detail": (
            "Best for: max catalog — every curated photoreal model\n\n"
            "Apps & tools (adds to Pro):\n"
            "  • ComfyUI nodes: Inspire Pack, LayerStyle, Segment Anything 2\n\n"
            "New models in this tier:\n"
            "  Ollama:\n"
            "    - Gemma 3 12B (vision + reasoning)\n"
            "  ComfyUI checkpoints:\n"
            "    - DreamShaper XL Turbo, Flux Shakker Union Pro\n"
            "    - Flux Dev FP8 (alt quant)\n"
            "  Editing models:\n"
            "    - IP-Adapter Face SDXL\n"
            "    - IC-Light Background + Foreground variants\n"
            "  Upscalers:\n"
            "    - Real-ESRGAN x2, Real-ESRGAN x8\n"
            "  LM Studio (MLX):\n"
            "    - Llama 3.2 Vision 11B\n\n"
            "Also includes all Pro + Standard + Starter models\n\n"
            "~150 GB on SSD  |  ~6-8 GB on Mac internal\n\n"
            "Note: on 16GB RAM, run ONE heavy model at a time."
        ),
    },
]

SKIP_VOLUMES = {
    "Macintosh HD", "Macintosh HD - Data", "Preboot", "Recovery",
    "Update", "VM", "Data", "com.apple.TimeMachine.localsnapshots",
}


def script_dir():
    return os.path.dirname(os.path.abspath(__file__))


INSTALL_PID_FILE = "/tmp/local-ai-installer.pid"
INSTALL_EXIT_FILE = "/tmp/local-ai-installer.exit"
INSTALL_COMPLETE_FILE = "/tmp/local-ai-installer.complete"
INSTALL_BUNDLE_DIR = "/tmp/local-ai-studio-install-bundle"


def _signal_pid(pid, sig):
    try:
        os.kill(pid, sig)
        return True
    except OSError:
        return False


def _signal_group(pid, sig):
    try:
        os.killpg(os.getpgid(pid), sig)
        return True
    except OSError:
        return _signal_pid(pid, sig)


def _kill_child_pids(pid, sig):
    try:
        result = subprocess.run(
            ["pgrep", "-P", str(pid)],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return
    for line in (result.stdout or "").split():
        try:
            child = int(line.strip())
        except ValueError:
            continue
        _kill_child_pids(child, sig)
        _signal_pid(child, sig)


def stop_install_processes(wrapper_pid=None):
    """Stop background install (bash + caffeinate + children). Returns stopped PIDs."""
    targets = set()
    if wrapper_pid:
        targets.add(int(wrapper_pid))
    try:
        if os.path.isfile(INSTALL_PID_FILE):
            with open(INSTALL_PID_FILE, encoding="utf-8") as fh:
                targets.add(int(fh.read().strip()))
    except (ValueError, OSError):
        pass
    for pattern in (r"install-local-ai\.sh", r"caffeinate.*install-local-ai"):
        try:
            result = subprocess.run(
                ["pgrep", "-f", pattern],
                capture_output=True,
                text=True,
                check=False,
            )
        except OSError:
            continue
        for line in (result.stdout or "").split():
            try:
                targets.add(int(line.strip()))
            except ValueError:
                continue

    stopped = []
    for pid in sorted(targets, reverse=True):
        if not _signal_pid(pid, 0):
            continue
        _kill_child_pids(pid, signal.SIGTERM)
        if _signal_group(pid, signal.SIGTERM):
            stopped.append(pid)

    time.sleep(1.5)
    for pid in list(targets):
        if not _signal_pid(pid, 0):
            continue
        _kill_child_pids(pid, signal.SIGKILL)
        _signal_group(pid, signal.SIGKILL)
        if pid not in stopped:
            stopped.append(pid)

    try:
        os.remove(INSTALL_PID_FILE)
    except OSError:
        pass
    return stopped


def launch_install_in_terminal(
    installer, workdir, tier, ssd, hf_token="", extra_flags=None,
):
    """Run install in Terminal.app — macOS folder permissions work reliably there."""
    extra_flags = extra_flags or []
    launcher = "/tmp/local-ai-studio-terminal-install.command"
    path_export = ":".join([
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"),
    ])
    hf_lines = []
    if hf_token.strip():
        hf_lines.append(f"export HF_TOKEN={shlex.quote(hf_token.strip())}")
    script = "\n".join([
        "#!/bin/bash",
        "set -o pipefail",
        f"export PATH={shlex.quote(path_export)}",
        "export LOCAL_AI_SKIP_DESKTOP=1",
        *hf_lines,
        f"cd {shlex.quote(workdir)}",
        'echo "━━━ Local AI Studio install ━━━"',
        'echo "If a Mac folder popup appears: sidebar → click SSD once → Open"',
        (
            f"{shlex.quote(installer)} --tier {shlex.quote(tier)} "
            f"--ssd {shlex.quote(ssd)} --no-gui"
            + ("".join(f" {shlex.quote(flag)}" for flag in extra_flags))
        ),
        "ec=$?",
        "echo",
        'if [[ "$ec" -eq 0 ]]; then echo "Install finished OK."; '
        'else echo "Install failed (exit $ec) — scroll up for errors."; fi',
        'echo "Press Enter to close this Terminal tab."',
        "read -r",
        "exit $ec",
        "",
    ])
    with open(launcher, "w", encoding="utf-8") as fh:
        fh.write(script)
    os.chmod(launcher, 0o755)
    run_line = f"bash {launcher}"
    try:
        subprocess.run(
            [
                "osascript",
                "-e", 'tell application "Terminal" to activate',
                "-e", f'tell application "Terminal" to do script {shlex.quote(run_line)}',
            ],
            check=True,
            timeout=30,
        )
        return True
    except (OSError, subprocess.SubprocessError):
        return False


def prepare_install_bundle():
    """Copy installer scripts off the DMG so eject works while install runs."""
    src = script_dir()
    if os.path.isdir(INSTALL_BUNDLE_DIR):
        shutil.rmtree(INSTALL_BUNDLE_DIR)
    shutil.copytree(src, INSTALL_BUNDLE_DIR, ignore=shutil.ignore_patterns("test_*"))
    installer = os.path.join(INSTALL_BUNDLE_DIR, "install-local-ai.sh")
    os.chmod(installer, 0o755)
    return installer, INSTALL_BUNDLE_DIR


def macos_make_foreground_app():
    """Python .app launches as a background process — Tk text won't paint until foreground."""
    if sys.platform != "darwin":
        return
    try:
        import ctypes
        app_services = ctypes.CDLL(
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        )

        class ProcessSerialNumber(ctypes.Structure):
            _fields_ = [
                ("highLongOfPSN", ctypes.c_uint32),
                ("lowLongOfPSN", ctypes.c_uint32),
            ]

        psn = ProcessSerialNumber()
        if app_services.GetCurrentProcess(ctypes.byref(psn)) != 0:
            return
        # kProcessTransformToForegroundApplication = 1
        app_services.TransformProcessType(ctypes.byref(psn), 1)
    except Exception:
        pass
    try:
        import ctypes
        ctypes.CDLL(None).setprogname(b"AI Installer")
    except Exception:
        pass


def macos_activate_pid():
    """Bring this process to the front after the window is ready."""
    if sys.platform != "darwin":
        return
    try:
        subprocess.run(
            [
                "osascript", "-e",
                f'tell application "System Events" to set frontmost of '
                f'(first process whose unix id is {os.getpid()}) to true',
            ],
            check=False, timeout=2, capture_output=True,
        )
    except Exception:
        pass


def flat_text(
    parent, text, *, fg, bg, font, anchor="w", justify=tk.LEFT,
    command=None, wraplength=0, readonly=False,
):
    """Use flat Buttons for text — macOS Tk 8.5 often won't paint Label/Text text in .app bundles."""
    clickable = bool(command)
    # readonly keeps NORMAL state so fg paints; disabled buttons often show blank on macOS .app Tk.
    btn = tk.Button(
        parent, text=text, fg=fg, bg=bg,
        activeforeground=fg, activebackground=bg,
        disabledforeground=fg,
        relief=tk.FLAT, bd=0, highlightthickness=0,
        font=font, anchor=anchor, justify=justify,
        wraplength=wraplength,
        cursor="hand2" if clickable else "arrow",
        command=command or (lambda: None),
        state=tk.NORMAL if (clickable or readonly) else tk.DISABLED,
        takefocus=0 if readonly else 1,
    )
    return btn


DETAIL_HEADERS = (
    "Models installed:", "New models in this tier:",
    "Apps & tools (adds to Pro):", "Apps & tools (adds to Standard):",
    "Apps & tools (adds to Starter):", "Apps & tools:",
)


def detail_line_style(line):
    """Return (font, fg color) for flat-button detail lines."""
    if not line.strip():
        return None
    if line.startswith("Note:"):
        return (("Helvetica", 11), YELLOW)
    if any(line.startswith(h) for h in DETAIL_HEADERS):
        return (("Helvetica", 11, "bold"), ACCENT2)
    if line.startswith("    -"):
        if any(marker in line for marker in GATED_MODEL_MARKERS):
            return (("Helvetica", 11), ACCENT2)
        return (("Helvetica", 11), TEXT_DIM)
    if (
        line.startswith("HuggingFace")
        or line.startswith("Install works without")
        or line.startswith("  1. Log into")
        or line.startswith("  2. Settings")
        or line.startswith("  CyberRealistic")
        or line.startswith("     → click Agree")
    ):
        return (("Helvetica", 11), YELLOW)
    if line.startswith("  ") and line.rstrip().endswith(":"):
        return (("Helvetica", 11, "bold"), "white")
    if line.startswith("~") and "GB" in line:
        return (("Helvetica", 11, "bold"), ACCENT)
    return (("Helvetica", 11), "white")


def detail_button_fg(color):
    """Map theme colors to button fg values that paint in macOS .app Tk."""
    return {
        TEXT: "white",
        TEXT_DIM: "#8b949e",
        ACCENT2: "#4ecdc4",
        ACCENT: "#ff6b35",
        YELLOW: "#d29922",
        "white": "white",
    }.get(color, "white")


DETAIL_HEIGHT_RATIO = 0.64  # ~20% shorter detail panel — room for SSD + HuggingFace token block
DETAIL_VIEW_HEIGHT_MIN = 102
DETAIL_VIEW_HEIGHT_MAX = 268
PREFS_PATH = os.path.expanduser("~/.local-ai-studio-installer.json")
DETAIL_LINE_SLOTS = 19
DETAIL_GAP_SLOTS = 4
GATED_MODEL_MARKERS = ("SD 3.5 Medium",)
HF_LICENSE_MODEL_URL = "https://huggingface.co/stabilityai/stable-diffusion-3.5-medium"
HF_SENSITIVE_SETTINGS_URL = "https://huggingface.co/settings/content-preferences"
HF_SIGNUP_URL = "https://huggingface.co/join"
HF_TOKENS_URL = "https://huggingface.co/settings/tokens"

# Optional Unfiltered Pack realism weights (need HF sensitive content + token)
SENSITIVE_MODEL_FILES = (
    "spicy-realism-v30-unet.safetensors",
    "into-realism-v30-unet.safetensors",
    "intorealism-v21-unet.safetensors",
)

HF_SENSITIVE_WIZARD_STEPS = (
    {
        "title": "When to do this",
        "body": (
            "TIMING\n"
            "──────\n"
            "• BEFORE INSTALL (now) — best chance to download all 3 on the first pass.\n"
            "• AFTER INSTALL — still fine; run LOCAL_AI_GEN/scripts/fetch-sensitive-models.sh\n\n"
            "These 3 photoreal weights are optional. The installer never blocks or fails if they skip.\n\n"
            "Click Next to walk through the manual browser steps (~2 minutes)."
        ),
        "open_label": None,
        "url": None,
    },
    {
        "title": "Step 1 of 4 — Free account",
        "body": (
            "Create a free HuggingFace account if you do not have one.\n\n"
            "• Email, Google, or GitHub sign-up works\n"
            "• No credit card\n"
            "• No API billing — this is only for downloading files\n\n"
            "Click \"Open page\" → complete sign-up in your browser → come back here → Next."
        ),
        "open_label": "Open sign-up page",
        "url": HF_SIGNUP_URL,
    },
    {
        "title": "Step 2 of 4 — Content preferences",
        "body": (
            "While logged into HuggingFace:\n\n"
            "1. Open Content preferences (button below)\n"
            "2. Enable viewing sensitive / NSFW content\n"
            "3. Save if asked\n\n"
            "Required for the 3 photoreal realism downloads. Free setting on your account."
        ),
        "open_label": "Open content preferences",
        "url": HF_SENSITIVE_SETTINGS_URL,
    },
    {
        "title": "Step 3 of 4 — Read token",
        "body": (
            "Still logged in:\n\n"
            "1. Open Access Tokens (button below)\n"
            "2. New token → name it anything (e.g. local-ai)\n"
            "3. Type: Read only (not Write)\n"
            "4. Create → Copy the token (starts with hf_)\n\n"
            "Keep the token handy for the next step."
        ),
        "open_label": "Open token settings",
        "url": HF_TOKENS_URL,
    },
    {
        "title": "Step 4 of 4 — Paste in installer",
        "body": (
            "Back in this installer window:\n\n"
            "1. Scroll to the orange HuggingFace box (step 2 on main screen)\n"
            "2. Click \"Paste Token from Clipboard\" (or Type Token…)\n"
            "3. Check Unfiltered Pack is still checked\n"
            "4. Click INSTALL LOCAL AI STUDIO\n\n"
            "If you install without a token, everything else still works — run\n"
            "LOCAL_AI_GEN/scripts/fetch-sensitive-models.sh later."
        ),
        "open_label": None,
        "url": None,
    },
)

HF_DETAIL_FOOTER = (
    "",
    "HuggingFace (optional) — only SD 3.5 Medium needs extra steps:",
    "  CyberRealistic is public (no license button — downloads automatically).",
    "  1. Log into huggingface.co → open stabilityai/stable-diffusion-3.5-medium",
    "     → click Agree and access repository",
    "  2. Settings → Access Tokens → New token (Read) → paste below → INSTALL",
    "Install works without SD 3.5 — 25 of 26 models download with no account.",
)

HF_MAIN_HINT = (
    "HuggingFace (optional) — SD 3.5 Medium needs license + Read token.\n"
    "CyberRealistic is public. For SD 3.5: Agree on stabilityai/stable-diffusion-3.5-medium, then\n"
    "Settings → Access Tokens → New token (Read) → paste below → INSTALL.\n"
    "Install works without SD 3.5 — 25 of 26 models need no account."
)

HF_MAIN_HINT_PACK = (
    "Unfiltered Pack: use Setup guide for 3 optional realism weights (content prefs + token).\n\n"
    + HF_MAIN_HINT
)


def open_hf_gated_model_pages():
    """Open the HuggingFace page where SD 3.5 license must be accepted."""
    for url in (HF_LICENSE_MODEL_URL,):
        try:
            subprocess.run(["open", url], check=False, timeout=8)
        except OSError:
            pass


def open_hf_url(url):
    """Open a HuggingFace (or other) page in the default browser."""
    if not url:
        return
    try:
        subprocess.run(["open", url], check=False, timeout=8)
    except OSError:
        pass


def open_hf_sensitive_settings():
    """Open HuggingFace content preferences (sensitive content toggle)."""
    open_hf_url(HF_SENSITIVE_SETTINGS_URL)


def count_missing_sensitive_models(ssd_root):
    """How many of the 3 optional sensitive weights are absent on SSD (0–3)."""
    if not ssd_root:
        return len(SENSITIVE_MODEL_FILES)
    models_dir = os.path.join(ssd_root, "LOCAL_AI_GEN", "comfyui-models", "diffusion_models")
    missing = 0
    for name in SENSITIVE_MODEL_FILES:
        path = os.path.join(models_dir, name)
        try:
            if os.path.isfile(path) and os.path.getsize(path) > 50_000_000:
                continue
        except OSError:
            pass
        missing += 1
    return missing


def is_usable_ssd_path(path):
    """True if path exists and is a plausible install target (not someone else's stale volume)."""
    path = (path or "").strip()
    if not path or not os.path.isdir(path):
        return False
    if path.startswith("/Volumes/"):
        parts = path.split("/")
        # /Volumes/MyDrive or /Volumes/MyDrive/subfolder
        if len(parts) < 3 or not parts[2]:
            return False
        volume_root = f"/Volumes/{parts[2]}"
        return os.path.ismount(volume_root)
    # User picked a custom folder via Browse (e.g. ~/Desktop/SSD)
    return os.access(path, os.W_OK)


def list_volumes():
    """Return [(label, path, free_gb), ...] sorted by free space desc."""
    results = []
    vol_root = "/Volumes"
    if not os.path.isdir(vol_root):
        return results
    for name in os.listdir(vol_root):
        if name in SKIP_VOLUMES or name.startswith("."):
            continue
        path = os.path.join(vol_root, name)
        if not os.path.isdir(path) or not os.path.ismount(path):
            continue
        try:
            st = os.statvfs(path)
            free_gb = (st.f_frsize * st.f_bavail) // (1024 ** 3)
            results.append((f"{name}  —  {free_gb} GB free", path, free_gb))
        except OSError:
            results.append((name, path, 0))
    results.sort(key=lambda x: -x[2])
    return results


class InstallerGUI(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("AI Installer")
        self.configure(bg=BG)
        self.minsize(820, 620)
        self._ssd_access_ok = False
        self.selected_tier = tk.StringVar(value="")
        self.unfiltered_pack = tk.BooleanVar(value=False)
        self.drive_path = tk.StringVar(value="")
        self.installing = False
        self.proc = None
        self._tier_widgets = {}
        self._tier_check_vars = {}

        self.createcommand("tk::mac::Quit", self._on_quit)
        self.protocol("WM_DELETE_WINDOW", self._on_quit)
        try:
            self.tk.call("tk", "appname", "AI Installer")
        except tk.TclError:
            pass

        self._build_ui()
        self._sync_footer_layout()
        prefs = self._load_prefs()
        if prefs.get("last_tier") in {t["id"] for t in TIERS}:
            self.selected_tier.set(prefs["last_tier"])
        elif prefs.get("last_tier") == "":
            self.selected_tier.set("")
        if prefs.get("unfiltered_pack"):
            self.unfiltered_pack.set(True)
        self._refresh_volumes()
        self.after_idle(self._apply_smart_install_defaults)
        self._sync_tier_checkboxes()
        self._update_tier_highlight()
        self.after_idle(self._sync_install_controls)
        self.after_idle(self._sync_hf_hints)
        self._center_window()
        self.after_idle(self._sync_all_scrollbars)
        self.after_idle(self._bring_to_front)
        self.after(200, self._bring_to_front)
        self.after(600, self._bring_to_front)
        self.after(800, self._check_background_install)
        self.after(5000, self._poll_background_install)

    def _sync_all_scrollbars(self):
        self._sync_body_scrollbar()
        self._sync_log_scroll()

    def _sync_log_scroll(self):
        if self.log.size() > 4:
            if not self._log_sb.winfo_ismapped():
                self._log_sb.pack(side=tk.RIGHT, fill=tk.Y)
        else:
            self._log_sb.pack_forget()

    def _bring_to_front(self):
        try:
            self.deiconify()
            self.lift()
            self.focus_force()
        except tk.TclError:
            pass
        macos_activate_pid()

    def _on_quit(self, *_):
        if self.installing:
            if not messagebox.askokcancel(
                "Quit",
                "Installation keeps running in the background.\n\n"
                "Re-open this app to watch progress, or check:\n"
                "  /tmp/local-ai-installer*.log\n\n"
                "Click INSTALL again anytime to resume if it stopped.\n\n"
                "Close this window anyway?",
            ):
                return
        try:
            self.quit()
            self.destroy()
        except Exception:
            pass
        os._exit(0)

    def _center_window(self):
        self.update_idletasks()
        sw = self.winfo_screenwidth()
        sh = self.winfo_screenheight()
        w = min(980, max(860, sw - 32))
        h = min(820, max(680, sh - 100))
        x = max(0, (sw - w) // 2)
        y = max(24, (sh - h) // 2)
        self.geometry(f"{w}x{h}+{x}+{y}")
        self.minsize(820, 640)

    def _build_ui(self):
        # ── Header ───────────────────────────────────────────────────────
        header = tk.Frame(self, bg=ACCENT, height=56)
        header.pack(fill=tk.X)
        header.pack_propagate(False)

        flat_text(
            header, text="LOCAL AI STUDIO", font=("Helvetica", 18, "bold"),
            fg="white", bg=ACCENT,
        ).pack(pady=(8, 0))
        flat_text(
            header,
            text="Select package and/or pack → pick SSD → INSTALL at the bottom",
            font=("Helvetica", 10), fg="#ffe8d6", bg=ACCENT,
        ).pack()

        # ── Footer: install button always visible ────────────────────────
        footer = tk.Frame(self, bg=BG, padx=16, pady=8)
        footer.pack(side=tk.BOTTOM, fill=tk.X)

        self._install_cta = flat_text(
            footer, text="Step 3 — click INSTALL when selections + SSD are set:",
            font=("Helvetica", 10, "bold"), fg=ACCENT2, bg=BG, anchor="w", readonly=True,
        )
        self._install_cta.pack(fill=tk.X, pady=(0, 4))

        self.install_btn = tk.Button(
            footer, text="INSTALL LOCAL AI STUDIO", font=("Helvetica", 14, "bold"),
            fg="white", bg=ACCENT, activebackground="#e85a28",
            relief=tk.FLAT, pady=8, cursor="hand2",
            command=self._start_install,
        )
        self.install_btn.pack(fill=tk.X)

        self.stop_btn = tk.Button(
            footer, text="STOP INSTALL", font=("Helvetica", 11, "bold"),
            fg="white", bg="#6e7681", activebackground="#da3633",
            disabledforeground="#c9d1d9",
            relief=tk.FLAT, pady=6, cursor="hand2",
            command=self._stop_install, state=tk.DISABLED,
        )
        self.stop_btn.pack(fill=tk.X, pady=(4, 0))

        self._footer_progress_wrap = 760
        self._progress_stack = tk.Frame(footer, bg=BG)
        self._progress_stack.bind("<Configure>", self._sync_footer_progress_wrap)

        self.progress = ttk.Progressbar(self._progress_stack, mode="determinate", maximum=100)
        self.progress.pack(fill=tk.X, pady=(0, 4))

        self.ssd_size_label = flat_text(
            self._progress_stack, text="", font=("Helvetica", 10, "bold"),
            fg=GREEN, bg=BG, anchor="w", readonly=True,
            wraplength=self._footer_progress_wrap,
        )
        self.ssd_size_label.pack(fill=tk.X, pady=(0, 2))

        self.eta_label = flat_text(
            self._progress_stack, text="", font=("Helvetica", 9),
            fg=ACCENT2, bg=BG, anchor="w", readonly=True,
            wraplength=self._footer_progress_wrap, justify=tk.LEFT,
        )
        self.eta_label.pack(fill=tk.X, pady=(0, 2))

        self._footer_hint_row = tk.Frame(self._progress_stack, bg=BG)
        self._footer_hint_row.pack(fill=tk.X, pady=(0, 2))
        flat_text(
            self._footer_hint_row,
            text="STOP keeps SSD progress — models already downloaded are kept.",
            font=("Helvetica", 9), fg=TEXT_DIM, bg=BG, anchor="w", readonly=True,
        ).pack(side=tk.LEFT, fill=tk.X, expand=True)
        tk.Button(
            self._footer_hint_row, text="Mac popup help?", font=("Helvetica", 9),
            fg=ACCENT2, bg=BG, activebackground=BG_CARD,
            relief=tk.FLAT, cursor="hand2",
            command=self._show_mac_permission_help,
        ).pack(side=tk.RIGHT)

        self.log_frame = tk.Frame(self._progress_stack, bg=BORDER, height=44)
        self.log_frame.pack_propagate(False)

        self.status_label = flat_text(
            footer, text="Ready when you are.", font=("Helvetica", 11),
            fg=TEXT_DIM, bg=BG, anchor="w", readonly=True,
            wraplength=self._footer_progress_wrap,
        )
        self.status_label.pack(fill=tk.X, pady=(4, 0))
        footer.bind("<Configure>", self._sync_footer_progress_wrap)

        self.log = tk.Listbox(
            self.log_frame, height=3, bg="#010409", fg=TEXT_DIM,
            font=("Menlo", 9), relief=tk.FLAT, highlightthickness=0,
            selectbackground=BG_SEL, activestyle="none",
        )
        self._log_sb = ttk.Scrollbar(self.log_frame, command=self.log.yview)
        self.log.configure(yscrollcommand=self._log_sb.set)
        self.log.pack(fill=tk.BOTH, expand=True, padx=3, pady=3)

        # ── Body: tiers + SSD (footer pinned below) ───
        self._body_outer = tk.Frame(self, bg=BG)
        self._body_outer.pack(fill=tk.BOTH, expand=True)

        body = tk.Frame(self._body_outer, bg=BG, padx=16, pady=6)
        body.pack(fill=tk.BOTH, expand=True)
        self._body_frame = body

        # Pin SSD/HF block to the bottom first so upper sections never overlap it.
        self._drive_section = tk.Frame(
            body, bg=BG_CARD, highlightbackground=BORDER, highlightthickness=1,
        )
        self._drive_section.pack(side=tk.BOTTOM, fill=tk.X)

        self._main_upper = tk.Frame(body, bg=BG)
        self._main_upper.pack(side=tk.TOP, fill=tk.BOTH, expand=True)

        flat_text(
            self._main_upper, text="1. CHOOSE PACKAGE (click to select, click again to clear)",
            font=("Helvetica", 12, "bold"),
            fg=ACCENT2, bg=BG, anchor="w",
        ).pack(fill=tk.X, pady=(0, 4))

        self._cards_frame = tk.Frame(self._main_upper, bg=BG)
        self._cards_frame.pack(fill=tk.X)
        self.tier_cards = {}
        for i, tier in enumerate(TIERS):
            card = self._make_tier_card(self._cards_frame, tier)
            card.grid(row=i // 2, column=i % 2, padx=3, pady=2, sticky="nsew")
            self._cards_frame.columnconfigure(i % 2, weight=1)
            self.tier_cards[tier["id"]] = card

        self._selected_tier_row = tk.Frame(self._main_upper, bg=BG_CARD, highlightbackground=BORDER, highlightthickness=1)
        self._selected_tier_row.pack(fill=tk.X, pady=(6, 0))
        sel_inner = tk.Frame(self._selected_tier_row, bg=BG_CARD, padx=10, pady=8)
        sel_inner.pack(fill=tk.X)
        self._selected_tier_summary = flat_text(
            sel_inner, text="", font=("Helvetica", 10),
            fg=TEXT, bg=BG_CARD, anchor="w", readonly=True, wraplength=720,
        )
        self._selected_tier_summary.pack(side=tk.LEFT, fill=tk.X, expand=True)
        self._extras_section = tk.Frame(self._main_upper, bg=BG)
        self._extras_section.pack(fill=tk.X, pady=(8, 0))

        self._pack_frame = tk.Frame(
            self._extras_section, bg=BG_CARD, highlightbackground=BORDER, highlightthickness=1,
        )
        self._pack_frame.pack(fill=tk.X)
        full_inner = tk.Frame(self._pack_frame, bg=BG_CARD, padx=10, pady=8)
        full_inner.pack(fill=tk.X)
        flat_text(
            full_inner, text="2. UNFILTERED MODELS PACK (optional)", font=("Helvetica", 11, "bold"),
            fg=ACCENT2, bg=BG_CARD, anchor="w",
        ).pack(fill=tk.X, pady=(0, 4))
        self._unfiltered_pack_cb = tk.Checkbutton(
            full_inner,
            text=f"Unfiltered Models Pack (+~{UNFILTERED_PACK_GB} GB)",
            variable=self.unfiltered_pack,
            font=("Helvetica", 10, "bold"),
            fg=TEXT,
            bg=BG_CARD,
            activebackground=BG_CARD,
            activeforeground=ACCENT2,
            selectcolor=BG_SEL,
            anchor="w",
            command=self._on_unfiltered_pack_toggle,
        )
        self._unfiltered_pack_cb.pack(fill=tk.X)
        flat_text(
            full_inner,
            text="Qwen Image Edit, Flux Fill/Kontext, faces, poses, MLX vision · ~3–6 extra hours",
            font=("Helvetica", 9), fg=TEXT_DIM, bg=BG_CARD, anchor="w", readonly=True,
            wraplength=720,
        ).pack(fill=tk.X, pady=(2, 0))
        flat_text(
            full_inner,
            text="3 optional realism weights need HuggingFace setup — use guide in step 4.",
            font=("Helvetica", 9), fg=TEXT_DIM, bg=BG_CARD, anchor="w", readonly=True,
            wraplength=720,
        ).pack(fill=tk.X, pady=(6, 0))

        inner = tk.Frame(self._drive_section, bg=BG_CARD, padx=10, pady=8)
        inner.pack(fill=tk.X)

        flat_text(
            inner, text="3. EXTERNAL SSD + HUGGINGFACE (optional)", font=("Helvetica", 11, "bold"),
            fg=ACCENT2, bg=BG_CARD, anchor="w",
        ).grid(row=0, column=0, columnspan=3, sticky="w", pady=(0, 4))

        self.drive_combo = ttk.Combobox(inner, state="readonly")
        self.drive_combo.grid(row=1, column=0, sticky="ew", padx=(0, 6))
        self.drive_combo.bind("<<ComboboxSelected>>", self._on_drive_selected)
        inner.columnconfigure(0, weight=1)

        tk.Button(
            inner, text="↻", font=("Helvetica", 11, "bold"),
            fg="white", bg="#1f6feb", activebackground="#388bfd",
            relief=tk.FLAT, padx=8, pady=2, cursor="hand2",
            command=self._refresh_volumes,
        ).grid(row=1, column=1, padx=(0, 3))

        tk.Button(
            inner, text="Browse…", font=("Helvetica", 10, "bold"),
            fg="white", bg="#238636", activebackground="#2ea043",
            relief=tk.FLAT, padx=8, pady=2, cursor="hand2",
            command=self._browse_drive,
        ).grid(row=1, column=2)

        access_row = tk.Frame(inner, bg=BG_CARD)
        access_row.grid(row=2, column=0, columnspan=3, sticky="ew", pady=(8, 0))

        tk.Button(
            access_row, text="Allow SSD Access (do this once)",
            font=("Helvetica", 10, "bold"), fg="white", bg=ACCENT,
            activeforeground="white", activebackground="#e85a28",
            relief=tk.FLAT, padx=8, pady=6, cursor="hand2",
            command=self._grant_ssd_access,
        ).pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 4))

        tk.Button(
            access_row, text="Stop Popups (Mac Settings)",
            font=("Helvetica", 9, "bold"), fg="white", bg="#6e7681",
            activeforeground="white", activebackground="#484f58",
            relief=tk.FLAT, padx=8, pady=6, cursor="hand2",
            command=self._open_mac_ssd_settings,
        ).pack(side=tk.RIGHT)

        self._ssd_status_wrap = 760
        status_stack = tk.Frame(inner, bg=BG_CARD)
        status_stack.grid(row=3, column=0, columnspan=3, sticky="ew", pady=(6, 2))
        self._ssd_status_stack = status_stack

        self._ssd_access_label = flat_text(
            status_stack,
            text="⚠ Click Allow SSD Access before INSTALL",
            font=("Helvetica", 9), fg=YELLOW, bg=BG_CARD, anchor="w", readonly=True,
            wraplength=self._ssd_status_wrap,
        )
        self._ssd_access_label.pack(fill=tk.X, anchor="w", pady=(0, 3))

        self.space_label = flat_text(
            status_stack, text="", font=("Helvetica", 9), fg=TEXT_DIM, bg=BG_CARD,
            anchor="w", readonly=True, wraplength=self._ssd_status_wrap,
        )
        self.space_label.pack(fill=tk.X, anchor="w", pady=(0, 3))

        self.warning_label = flat_text(
            status_stack, text="", font=("Helvetica", 9), fg=YELLOW, bg=BG_CARD,
            anchor="w", readonly=True, wraplength=self._ssd_status_wrap,
        )
        # packed only when there is a warning

        inner.bind("<Configure>", self._sync_ssd_status_wrap)

        tk.Frame(inner, bg=BORDER, height=1).grid(
            row=4, column=0, columnspan=3, sticky="ew", pady=(8, 6),
        )

        hf_header = tk.Frame(inner, bg=BG_CARD)
        hf_header.grid(row=5, column=0, columnspan=3, sticky="ew")
        self._hf_header_label = flat_text(
            hf_header, text="HuggingFace token (optional)",
            font=("Helvetica", 10, "bold"), fg=TEXT, bg=BG_CARD, anchor="w", readonly=True,
        )
        self._hf_header_label.pack(side=tk.LEFT)
        tk.Button(
            hf_header, text="Setup guide", font=("Helvetica", 9, "bold"),
            fg="white", bg="#8957e5", activebackground="#a371f7",
            relief=tk.FLAT, padx=6, pady=1, cursor="hand2",
            command=self._show_hf_sensitive_wizard,
        ).pack(side=tk.RIGHT, padx=(4, 0))
        tk.Button(
            hf_header, text="Content prefs", font=("Helvetica", 9, "bold"),
            fg="white", bg="#8957e5", activebackground="#a371f7",
            relief=tk.FLAT, padx=6, pady=1, cursor="hand2",
            command=self._open_hf_sensitive_settings,
        ).pack(side=tk.RIGHT, padx=(4, 0))
        tk.Button(
            hf_header, text="SD 3.5 license", font=("Helvetica", 9, "bold"),
            fg="white", bg="#8957e5", activebackground="#a371f7",
            relief=tk.FLAT, padx=6, pady=1, cursor="hand2",
            command=self._open_hf_license_pages,
        ).pack(side=tk.RIGHT, padx=(4, 0))
        tk.Button(
            hf_header, text="How?", font=("Helvetica", 9, "bold"),
            fg="white", bg="#1f6feb", activebackground="#388bfd",
            relief=tk.FLAT, padx=6, pady=1, cursor="hand2",
            command=self._show_hf_login_help,
        ).pack(side=tk.RIGHT)

        self._hf_token = ""
        self._hf_license_hint = flat_text(
            inner,
            text=HF_MAIN_HINT,
            font=("Helvetica", 9),
            fg="#ffe8d6",
            bg=BG_CARD,
            anchor="w",
            readonly=True,
            wraplength=self._ssd_status_wrap,
            justify=tk.LEFT,
        )
        self._hf_license_hint.grid(row=6, column=0, columnspan=3, sticky="ew", pady=(4, 0))

        hf_entry_outer = tk.Frame(inner, bg=ACCENT, padx=4, pady=4)
        hf_entry_outer.grid(row=7, column=0, columnspan=3, sticky="ew", pady=(6, 0))

        hf_btn_row = tk.Frame(hf_entry_outer, bg=ACCENT)
        hf_btn_row.pack(fill=tk.X, pady=(0, 4))

        tk.Button(
            hf_btn_row, text="Paste Token from Clipboard",
            font=("Helvetica", 11, "bold"), fg="white", bg="#238636",
            activeforeground="white", activebackground="#2ea043",
            relief=tk.FLAT, padx=10, pady=8, cursor="hand2",
            command=self._hf_paste_clipboard,
        ).pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 4))

        tk.Button(
            hf_btn_row, text="Type Token…",
            font=("Helvetica", 11, "bold"), fg="white", bg="#1f6feb",
            activeforeground="white", activebackground="#388bfd",
            relief=tk.FLAT, padx=10, pady=8, cursor="hand2",
            command=self._hf_type_manually,
        ).pack(side=tk.LEFT, padx=(0, 4))

        tk.Button(
            hf_btn_row, text="Clear", font=("Helvetica", 10, "bold"),
            fg="white", bg="#6e7681", activeforeground="white",
            activebackground="#da3633", relief=tk.FLAT, padx=10, pady=8,
            cursor="hand2", command=self._hf_clear_token,
        ).pack(side=tk.RIGHT)

        self._hf_status = flat_text(
            hf_entry_outer,
            text="No token — optional. SD 3.5 needs website license accept + token.",
            font=("Helvetica", 10), fg="#ffe8d6", bg=ACCENT, anchor="w", readonly=True,
        )
        self._hf_status.pack(fill=tk.X, pady=(2, 0))

        self._update_hf_main_hint()
        self._update_selected_tier_summary()
        self.after_idle(self._sync_ssd_status_wrap)

    def _hf_mask_token(self, token):
        token = (token or "").strip()
        if len(token) <= 10:
            return token[:4] + "••••" if token else ""
        return token[:7] + ("•" * min(12, len(token) - 7))

    def _hf_set_token(self, token):
        token = (token or "").strip()
        if not token:
            self._hf_clear_token()
            return
        if not token.startswith("hf_"):
            if not messagebox.askyesno(
                "Doesn't look like a HuggingFace token",
                f"Expected a token starting with hf_\n\nGot: {token[:40]}…\n\nUse it anyway?",
            ):
                return
        self._hf_token = token
        self._hf_update_status()

    def _sync_tier_checkboxes(self):
        selected = self.selected_tier.get()
        for tid, var in self._tier_check_vars.items():
            var.set(tid == selected)

    def _on_tier_checkbox(self, tier_id):
        var = self._tier_check_vars.get(tier_id)
        if var is None:
            return
        if var.get():
            self.selected_tier.set(tier_id)
            for tid, other in self._tier_check_vars.items():
                if tid != tier_id:
                    other.set(False)
        elif self.selected_tier.get() == tier_id:
            self.selected_tier.set("")
        self._update_tier_highlight()
        self._update_warnings()

    def _tier_selected(self):
        return self.selected_tier.get() in {t["id"] for t in TIERS}

    def _tier_for_install(self):
        tid = self.selected_tier.get()
        if tid in {t["id"] for t in TIERS}:
            return tid
        return "standard"

    def _install_targets(self):
        return self._tier_selected(), self.unfiltered_pack.get()

    def _effective_models_only(self, ssd=None):
        """Pack-only downloads skip apps; a selected package always runs the full install path."""
        tier_on, pack_on = self._install_targets()
        return bool(pack_on and not tier_on)

    def _install_button_label(self):
        tier_on, pack_on = self._install_targets()
        if tier_on:
            return "INSTALL LOCAL AI STUDIO"
        if pack_on:
            return "DOWNLOAD MODELS ONLY"
        return "INSTALL LOCAL AI STUDIO"

    def _build_install_flags(self, ssd=None):
        tier_on, pack_on = self._install_targets()
        if not tier_on and not pack_on:
            return []
        if not tier_on and pack_on:
            return ["--unfiltered-pack-only"]
        flags = []
        if pack_on:
            flags.append("--unfiltered-pack")
        return flags

    def _install_mode_label(self):
        tier_on, pack_on = self._install_targets()
        if tier_on and pack_on:
            return "Full studio + Unfiltered Pack"
        if tier_on:
            return "Full studio package"
        if pack_on:
            return "Unfiltered Pack models only"
        return "Nothing selected"

    def _selected_target_gb(self, tier=None):
        tier = tier or self._tier_for_install()
        total = 0
        tier_on, pack_on = self._install_targets()
        if tier_on:
            total += TIER_SSD_GB.get(tier, 110)
        if pack_on:
            total += UNFILTERED_PACK_GB
        return total

    def _install_time_estimate(self):
        tier = self._tier_for_install()
        tier_on, pack_on = self._install_targets()
        if tier_on and pack_on:
            return f"{TIER_TIME_EST.get(tier, '2–4 hours')} + {MODELS_ONLY_PACK_TIME} (pack)"
        if pack_on:
            return MODELS_ONLY_PACK_TIME
        if tier_on:
            return TIER_TIME_EST.get(tier, "2–4 hours")
        return "2–4 hours"

    def _install_target_label(self):
        tier_on, pack_on = self._install_targets()
        parts = []
        if tier_on:
            parts.append(self.selected_tier.get().upper())
        if pack_on:
            parts.append("Unfiltered Pack")
        return " + ".join(parts) if parts else "nothing selected"

    def _apply_smart_install_defaults(self):
        prefs = self._load_prefs()
        if prefs.get("last_tier") is not None or prefs.get("unfiltered_pack"):
            return
        ssd = self.drive_path.get().strip()
        if ssd and studio_ready_on_ssd(ssd):
            self.selected_tier.set("")
            self.unfiltered_pack.set(True)
            self._update_tier_highlight()

    def _on_unfiltered_pack_toggle(self):
        path = self.drive_path.get().strip()
        if path:
            try:
                st = os.statvfs(path)
                free = (st.f_frsize * st.f_bavail) // (1024 ** 3)
            except OSError:
                free = self._free_gb.get(self.drive_combo.get(), 0)
            self._update_space_label(path, free)
        self._update_warnings()
        self._sync_hf_hints()
        self._sync_install_controls()
        if self.unfiltered_pack.get() and not self._hf_token_value():
            prefs = self._load_prefs()
            if not prefs.get("saw_hf_sensitive_setup_intro"):
                self._save_prefs(saw_hf_sensitive_setup_intro=True)
                if messagebox.askyesno(
                    "Unfiltered Pack — HuggingFace help",
                    "This pack includes 3 optional photoreal weights on HuggingFace.\n\n"
                    "WHEN: Do the short setup before INSTALL for the best chance "
                    "to get all 3 on the first pass.\n\n"
                    "Open the step-by-step guide now? (~2 min, manual browser steps)\n\n"
                    "Install still works if you skip — you can run the guide later.",
                ):
                    self.after(150, self._show_hf_sensitive_wizard)

    def _update_hf_main_hint(self):
        if not hasattr(self, "_hf_license_hint"):
            return
        text = HF_MAIN_HINT_PACK if self.unfiltered_pack.get() else HF_MAIN_HINT
        self._hf_license_hint.configure(text=text)

    def _sync_hf_hints(self):
        pack = self.unfiltered_pack.get()
        if pack:
            self._hf_header_label.configure(
                text="HuggingFace — paste token below before INSTALL (optional realism weights + SD 3.5)",
            )
            if hasattr(self, "_hf_setup_guide_btn"):
                self._hf_setup_guide_btn.configure(bg="#8957e5")
        else:
            self._hf_header_label.configure(
                text="HuggingFace token (optional — SD 3.5 Medium)",
            )
            if hasattr(self, "_hf_setup_guide_btn"):
                self._hf_setup_guide_btn.configure(bg="#6e7681")
        self._update_hf_main_hint()
        self._hf_update_status()

    def _hf_update_status(self):
        pack = self.unfiltered_pack.get()
        if self._hf_token:
            extra = (
                "sensitive realism trio + SD 3.5 will be attempted"
                if pack
                else "if SD 3.5 skips, click License pages and Agree while logged in"
            )
            self._hf_status.configure(
                text=f"✓ Token: {self._hf_mask_token(self._hf_token)} — {extra}",
                fg="white", disabledforeground="white",
            )
        else:
            if pack:
                msg = (
                    "No token — install still completes. "
                    "Sensitive trio may skip; retry with scripts/fetch-sensitive-models.sh"
                )
            else:
                msg = "No token — optional. SD 3.5 needs website license accept + token."
            self._hf_status.configure(text=msg, fg="#ffe8d6", disabledforeground="#ffe8d6")

    def _hf_paste_clipboard(self):
        try:
            clip = self.clipboard_get().strip()
        except tk.TclError:
            messagebox.showinfo(
                "Clipboard empty",
                "Copy your hf_ token first:\n"
                "huggingface.co → Settings → Access Tokens → copy token\n\n"
                "Then click Paste Token from Clipboard again.",
            )
            return
        self._hf_set_token(clip)

    def _hf_type_manually(self):
        try:
            clip = self.clipboard_get().strip()
        except tk.TclError:
            clip = ""
        if clip and not clip.startswith("hf_"):
            clip = ""
        token = macos_ask_string(
            "Paste your HuggingFace token (starts with hf_):",
            title="HuggingFace Token",
            default=clip,
        )
        if token is None:
            return
        self._hf_set_token(token)

    def _hf_clear_token(self):
        self._hf_token = ""
        self._hf_update_status()

    def _hf_token_value(self):
        return (self._hf_token or "").strip()

    def _sync_body_scrollbar(self):
        pass

    def _sync_footer_progress_wrap(self, event=None):
        if not hasattr(self, "_progress_stack"):
            return
        try:
            width = self._progress_stack.winfo_width()
            if width < 120 and event is None:
                width = self.winfo_width() - 40
            if width < 120:
                return
            wrap = max(width - 8, 240)
            if abs(wrap - self._footer_progress_wrap) < 16 and event is not None:
                return
            self._footer_progress_wrap = wrap
            for widget in (self.ssd_size_label, self.eta_label, self.status_label):
                widget.configure(wraplength=wrap)
        except tk.TclError:
            pass

    def _show_install_log(self):
        if not self.log_frame.winfo_ismapped():
            self.log_frame.pack(fill=tk.X, pady=(2, 0))

    def _load_prefs(self):
        try:
            with open(PREFS_PATH, encoding="utf-8") as fh:
                data = json.load(fh)
                return data if isinstance(data, dict) else {}
        except (OSError, ValueError, TypeError):
            return {}

    def _save_prefs(self, **kwargs):
        prefs = self._load_prefs()
        for key, value in kwargs.items():
            if value is not None and value != "":
                prefs[key] = value
        try:
            with open(PREFS_PATH, "w", encoding="utf-8") as fh:
                json.dump(prefs, fh, indent=2)
        except OSError:
            pass

    def _clear_saved_ssd_pref(self):
        prefs = self._load_prefs()
        if "last_ssd" not in prefs:
            return
        del prefs["last_ssd"]
        try:
            with open(PREFS_PATH, "w", encoding="utf-8") as fh:
                json.dump(prefs, fh, indent=2)
        except OSError:
            pass

    def _select_drive_path(self, path, label=None, free_gb=None, remember=True):
        path = (path or "").strip()
        if not is_usable_ssd_path(path):
            return False
        if free_gb is None:
            try:
                st = os.statvfs(path)
                free_gb = (st.f_frsize * st.f_bavail) // (1024 ** 3)
            except OSError:
                free_gb = 0
        if not label:
            label = None
            for lbl, p in self._paths.items():
                if p == path:
                    label = lbl
                    break
        if not label:
            label = f"{os.path.basename(path) or path}  —  {free_gb} GB free"
        vals = list(self.drive_combo["values"])
        if label not in vals:
            self.drive_combo["values"] = [label] + list(vals)
        self._paths[label] = path
        self._free_gb[label] = free_gb
        self.drive_combo.set(label)
        self.drive_path.set(path)
        self._update_space_label(path, free_gb)
        self._update_warnings()
        self._check_ssd_access_silent()
        self._sync_install_controls()
        if remember:
            self._save_prefs(last_ssd=path)
        return True

    def _apply_saved_drive(self):
        saved = (self._load_prefs().get("last_ssd") or "").strip()
        if not saved:
            return False
        if not is_usable_ssd_path(saved):
            # Stale path (drive unplugged or another Mac) — never show as default.
            self._clear_saved_ssd_pref()
            return False
        return self._select_drive_path(saved, remember=False)

    def _make_tier_card(self, parent, tier):
        outer = tk.Frame(parent, bg=BG)

        is_rec = tier["id"] == "standard"
        card_bg = BG_SEL if is_rec else BG_CARD
        border_color = ACCENT if is_rec else BORDER

        card = tk.Frame(
            outer, bg=card_bg,
            highlightbackground=border_color, highlightthickness=2,
            cursor="hand2",
        )
        card.pack(fill=tk.BOTH, expand=True)

        def select(_=None):
            if self.selected_tier.get() == tier["id"]:
                self.selected_tier.set("")
            else:
                self.selected_tier.set(tier["id"])
            self._sync_tier_checkboxes()
            self._update_tier_highlight()
            self._update_warnings()

        def show_details(_=None):
            self._show_tier_detail_window(tier["id"])

        card.bind("<Button-1>", select)

        top = tk.Frame(card, bg=card_bg)
        top.pack(fill=tk.X, padx=10, pady=(8, 0))

        check_var = tk.BooleanVar(value=self.selected_tier.get() == tier["id"])
        self._tier_check_vars[tier["id"]] = check_var
        tier_cb = tk.Checkbutton(
            top,
            text="Select",
            variable=check_var,
            font=("Helvetica", 9, "bold"),
            fg=ACCENT2,
            bg=card_bg,
            activebackground=card_bg,
            activeforeground=ACCENT2,
            selectcolor=BG_SEL,
            anchor="w",
            command=lambda tid=tier["id"]: self._on_tier_checkbox(tid),
        )
        tier_cb.pack(side=tk.LEFT, padx=(0, 6))

        name_btn = flat_text(
            top, text=f"{tier['emoji']}  {tier['name']}", font=("Helvetica", 13, "bold"),
            fg=TEXT, bg=card_bg, command=select,
        )
        name_btn.pack(side=tk.LEFT, padx=(0, 4), fill=tk.X, expand=True)

        details_btn = tk.Button(
            top, text="Details", font=("Helvetica", 8, "bold"),
            fg="white", bg="#1f6feb", activeforeground="white",
            activebackground="#388bfd", relief=tk.FLAT, padx=6, pady=2,
            cursor="hand2", command=show_details,
        )
        details_btn.pack(side=tk.RIGHT, padx=(4, 0))

        badge_btn = None
        if tier["badge"]:
            badge_btn = tk.Button(
                top, text=f" {tier['badge']} ", font=("Helvetica", 8, "bold"),
                fg="white", bg=ACCENT, activeforeground="white", activebackground=ACCENT,
                relief=tk.FLAT, bd=0, highlightthickness=0, cursor="hand2", command=select,
            )
            badge_btn.pack(side=tk.RIGHT, padx=(4, 0))

        size_btn = flat_text(
            card, text=f"{tier['size']}  ·  {tier['internal']}",
            font=("Helvetica", 10, "bold"), fg=ACCENT, bg=card_bg, anchor="w", command=select,
        )
        size_btn.pack(fill=tk.X, padx=10, pady=(2, 0))
        flat_text(
            card, text=tier["tagline"],
            font=("Helvetica", 9), fg=TEXT_DIM, bg=card_bg, anchor="w",
            command=select, wraplength=340,
        ).pack(fill=tk.X, padx=10, pady=(2, 8))

        self._tier_widgets[tier["id"]] = {
            "card": card, "top": top, "check": tier_cb, "details": details_btn,
            "name": name_btn, "size": size_btn, "badge": badge_btn,
        }

        for w in (card, top, name_btn, size_btn):
            w.bind("<Button-1>", select)
        if badge_btn:
            badge_btn.bind("<Button-1>", select)

        return outer

    def _set_widget_bg(self, widget, bg):
        try:
            widget.configure(bg=bg)
            if isinstance(widget, tk.Button):
                widget.configure(activebackground=bg)
            elif isinstance(widget, tk.Text):
                widget.configure(bg=bg)
            elif isinstance(widget, (tk.Radiobutton, tk.Checkbutton)):
                widget.configure(activebackground=bg)
        except tk.TclError:
            pass

    def _update_tier_highlight(self):
        for tid, widgets in self._tier_widgets.items():
            selected = self.selected_tier.get() == tid
            bg = BG_SEL if selected else BG_CARD
            card = widgets["card"]
            card.configure(
                bg=bg,
                highlightbackground=ACCENT if selected else BORDER,
                highlightthickness=3 if selected else 1,
            )
            self._set_widget_bg(widgets["top"], bg)
            self._set_widget_bg(widgets["check"], bg)
            self._set_widget_bg(widgets["name"], bg)
            self._set_widget_bg(widgets["size"], bg)
            if widgets.get("badge"):
                pass
        self._sync_tier_checkboxes()
        self._update_selected_tier_summary()
        self._update_warnings()
        self._sync_install_controls()

    def _tier_body_lines(self, tier):
        """Tier-specific lines only (HF token block is pinned below the scroll area)."""
        return [tier["summary"], "", *tier["detail"].split("\n")]

    def _render_guide_lines(self, parent, lines, wraplength=560, bg=BG_CARD):
        for line in lines:
            if not line.strip():
                gap = tk.Frame(parent, bg=bg, height=8)
                gap.pack(fill=tk.X)
                gap.pack_propagate(False)
                continue
            style = detail_line_style(line)
            font = ("Helvetica", 11)
            fg = "white"
            if style:
                font, color = style
                fg = detail_button_fg(color)
            flat_text(
                parent,
                text=line,
                font=font,
                fg=fg,
                bg=bg,
                anchor="w",
                readonly=True,
                wraplength=wraplength,
            ).pack(fill=tk.X, anchor="w")
        parent.update_idletasks()

    def _render_tier_guide_body(self, parent, tier, wraplength=560):
        self._render_guide_lines(parent, self._tier_body_lines(tier), wraplength=wraplength)

    def _update_selected_tier_summary(self):
        if not hasattr(self, "_selected_tier_summary"):
            return
        if not self._tier_selected():
            self._selected_tier_summary.configure(
                text="No package selected — OK if you only want the Unfiltered Pack below.",
            )
            return
        tid = self.selected_tier.get()
        tier = next((t for t in TIERS if t["id"] == tid), TIERS[1])
        badge = f"  ·  {tier['badge']}" if tier.get("badge") else ""
        text = (
            f"Selected: {tier['emoji']} {tier['name']}{badge} — "
            f"{tier['tagline']}  ·  {tier['size']}"
        )
        self._selected_tier_summary.configure(text=text)

    def _show_tier_detail_window(self, tier_id):
        tier = next((t for t in TIERS if t["id"] == tier_id), TIERS[0])
        win = tk.Toplevel(self)
        win.title(f"{tier['name']} — package details")
        win.configure(bg=BG_CARD)
        win.transient(self)
        win.resizable(True, True)
        win.minsize(620, 480)

        header = flat_text(
            win,
            text=f"{tier['emoji']} {tier['name']} — {tier['tagline']}",
            font=("Helvetica", 13, "bold"),
            fg="#4ecdc4",
            bg=BG_CARD,
            anchor="w",
            readonly=True,
            wraplength=560,
        )
        header.pack(fill=tk.X, padx=16, pady=(14, 8))

        body = tk.Frame(win, bg=BG_CARD)
        body.pack(fill=tk.BOTH, expand=True, padx=16, pady=(0, 8))
        lines = self._tier_body_lines(tier) + list(HF_DETAIL_FOOTER)
        self._render_guide_lines(body, lines, wraplength=560, bg=BG_CARD)

        nav = tk.Frame(win, bg=BG_CARD)
        nav.pack(fill=tk.X, padx=16, pady=(4, 14))
        tk.Button(
            nav, text="Close", font=("Helvetica", 10, "bold"),
            fg="white", bg="#6e7681", activebackground="#484f58",
            relief=tk.FLAT, padx=12, pady=6, cursor="hand2",
            command=win.destroy,
        ).pack(side=tk.RIGHT)

        win.update_idletasks()
        w = max(660, win.winfo_reqwidth())
        h = min(820, max(520, win.winfo_reqheight()))
        x = self.winfo_rootx() + max(0, (self.winfo_width() - w) // 2)
        y = self.winfo_rooty() + max(0, (self.winfo_height() - h) // 2)
        win.geometry(f"{w}x{h}+{x}+{y}")

    def _volume_map(self):
        return {label: (path, free) for label, path, free in list_volumes()}

    def _refresh_volumes(self):
        vols = list_volumes()
        labels = [v[0] for v in vols]
        self._paths = {v[0]: v[1] for v in vols}
        self._free_gb = {v[0]: v[2] for v in vols}

        self.drive_combo["values"] = labels
        if labels:
            if self._apply_saved_drive():
                return
            # New users: only auto-pick when exactly one external drive is present.
            if len(labels) == 1:
                self._select_drive_path(
                    self._paths[labels[0]],
                    label=labels[0],
                    free_gb=self._free_gb[labels[0]],
                    remember=False,
                )
            else:
                self.drive_combo.set("")
                self.drive_path.set("")
                self.space_label.configure(
                    text="Select your external SSD above (Refresh or Browse…).",
                    fg=TEXT_DIM, disabledforeground=TEXT_DIM,
                )
        else:
            self.drive_combo.set("")
            self.drive_path.set("")
            self.space_label.configure(
                text="No external drives detected — plug in your SSD, then Refresh or Browse.",
                fg=YELLOW, disabledforeground=YELLOW,
            )

    def _tier_drive_need_gb(self, tier=None):
        """Free space to recommend — driven only by what is checked (package and/or pack)."""
        tier_on, pack_on = self._install_targets()
        if not tier_on and not pack_on:
            return 0
        need = 0
        if tier_on:
            tid = self.selected_tier.get()
            need = TIER_DRIVE_MIN_GB.get(tid, TIER_DRIVE_MIN_GB["standard"])
        if pack_on:
            need += UNFILTERED_PACK_DRIVE_GB
            if not tier_on:
                need += MODELS_ONLY_DRIVE_BUFFER
        return need

    def _ssd_target_gb(self, tier=None):
        tier = tier or self._tier_for_install()
        return self._selected_target_gb(tier)

    def _on_drive_selected(self, _=None):
        sel = self.drive_combo.get()
        if sel in self._paths:
            path = self._paths[sel]
            self.drive_path.set(path)
            self._update_space_label(path, self._free_gb.get(sel, 0))
            self._update_warnings()
            self._save_prefs(last_ssd=path)
            self._check_ssd_access_silent()
            self._sync_install_controls()

    def _update_space_label(self, path, free_gb):
        tier_on, pack_on = self._install_targets()
        need = self._tier_drive_need_gb()
        dest = os.path.join(path, "LOCAL_AI_GEN")
        target = self._install_target_label()
        if not tier_on and not pack_on:
            self.space_label.configure(
                text=(
                    f"Install: {dest}\n"
                    f"{free_gb} GB free  ·  select a package and/or Unfiltered Pack above"
                ),
                fg=TEXT_DIM, disabledforeground=TEXT_DIM,
            )
            return
        color = GREEN if free_gb >= need else RED
        content_gb = self._selected_target_gb()
        self.space_label.configure(
            text=(
                f"Install: {dest}\n"
                f"{free_gb} GB free  ·  need ~{need} GB free for {target} "
                f"(~{content_gb} GB download)"
            ),
            fg=color, disabledforeground=color,
        )
        self.after_idle(self._sync_ssd_status_wrap)

    def _update_warnings(self):
        tier = self.selected_tier.get()
        path = self.drive_path.get()
        msgs = []
        if self._tier_selected() and tier == "ultimate":
            msgs.append("16GB RAM: close other apps and run one heavy model at a time.")
        if path:
            free = 0
            try:
                st = os.statvfs(path)
                free = (st.f_frsize * st.f_bavail) // (1024 ** 3)
            except OSError:
                pass
            need = self._tier_drive_need_gb()
            if free < need:
                msgs.append(
                    f"Drive may be too small — need ~{need} GB free for {self._install_target_label()}."
                )
            if self.unfiltered_pack.get():
                msgs.append(
                    f"Unfiltered Pack adds ~{UNFILTERED_PACK_GB} GB (Qwen Edit, Flux Fill/Kontext, MLX)."
                )
            self._update_space_label(path, free)
        warn = "\n".join(msgs)
        if warn.strip():
            self.warning_label.configure(
                text=warn, fg=YELLOW, disabledforeground=YELLOW,
            )
            if not self.warning_label.winfo_ismapped():
                self.warning_label.pack(fill=tk.X, anchor="w")
        else:
            self.warning_label.pack_forget()

    def _browse_drive(self):
        saved = (self._load_prefs().get("last_ssd") or "").strip()
        if saved and os.path.isdir(saved):
            initialdir = saved
        elif os.path.isdir("/Volumes"):
            initialdir = "/Volumes"
        else:
            initialdir = os.path.expanduser("~")
        path = macos_choose_folder(
            prompt="Select your external SSD (or the folder where LOCAL_AI_GEN should live)",
            initial=initialdir,
        )
        if not path:
            return
        label = f"{os.path.basename(path) or path}  —  custom folder"
        self._select_drive_path(path, label=label)

    def _format_elapsed(self, seconds):
        seconds = int(max(0, seconds))
        if seconds < 60:
            return f"{seconds}s"
        if seconds < 3600:
            return f"{seconds // 60}m"
        return f"{seconds // 3600}h {seconds % 3600 // 60}m"

    def _find_latest_install_log(self):
        try:
            logs = sorted(
                glob.glob("/tmp/local-ai-installer-*.log"),
                key=os.path.getmtime,
                reverse=True,
            )
            if logs:
                self._install_log_path = logs[0]
                if not hasattr(self, "_install_log_pos"):
                    self._install_log_pos = 0
        except OSError:
            pass

    def _tail_install_log(self):
        if not self.installing:
            return
        if not getattr(self, "_install_log_path", None):
            self._find_latest_install_log()
        path = getattr(self, "_install_log_path", None)
        if not path or not os.path.isfile(path):
            return
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                fh.seek(getattr(self, "_install_log_pos", 0))
                data = fh.read()
                if not data:
                    return
                self._install_log_pos = fh.tell()
        except OSError:
            return
        for raw in data.splitlines():
            line = raw.rstrip()
            if not line:
                continue
            # Strip ANSI escape sequences from log lines.
            clean = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", line).strip()
            if not clean:
                continue
            if clean.startswith("ℹ") or clean.startswith("✓") or clean.startswith("⚠"):
                display = clean
            elif "pulling" in clean.lower() or "%" in clean or "download" in clean.lower():
                display = f"  ↳ {clean[:120]}"
            else:
                display = clean
            self.after(0, self._log_line, display)
            self.after(0, self._parse_install_line, clean)

    def _parse_install_line(self, line):
        if not self.installing:
            return
        if "━━━" in line:
            match = re.search(r"━━━\s*(.+?)\s*━━━", line)
            if match:
                header = match.group(1).strip()
                self._maybe_notify_permission_phase(header)
                for key, pct, label in INSTALL_PHASES:
                    if key.lower() in header.lower():
                        self._install_phase = label
                        # Setup steps (through ComfyUI) — phase % until models download
                        if pct <= 62:
                            self._install_progress = max(self._install_progress, pct)
                            self.progress["value"] = self._install_progress
                        self._refresh_install_eta()
                        return
        pull_match = re.search(
            r"(?:Pull|Pulled|Already have) \((\d+)/(\d+)\)", line,
        )
        if pull_match:
            n, total = int(pull_match.group(1)), int(pull_match.group(2))
            self._install_phase = f"Ollama models ({n}/{total})"
            self._apply_ssd_progress()
        if "/tmp/local-ai-installer" in line:
            match = re.search(r"(/tmp/local-ai-installer\S+\.log)", line)
            if match:
                self._install_log_path = match.group(1)
        elif "Model (" in line:
            model_match = re.search(r"Model \((\d+)\)", line)
            if model_match:
                self._install_phase = f"ComfyUI image models ({model_match.group(1)}…)"
            else:
                self._install_phase = "Downloading image models"
            self._apply_ssd_progress()
        elif "Estimated total time:" in line:
            self._install_time_hint = line.split("Estimated total time:", 1)[-1].strip()
            self._refresh_install_eta()
        elif "SSD folder size:" in line:
            match = re.search(r"SSD folder size:\s*~?([\d.]+)\s*GB", line, re.I)
            if match:
                self._ssd_gb = match.group(1)
                self._ssd_gb_at = time.time()
                if getattr(self, "_install_ssd_baseline_gb", None) is None:
                    try:
                        self._install_ssd_baseline_gb = float(match.group(1))
                    except ValueError:
                        pass
                self._apply_ssd_progress()
        elif "GUI apps on SSD:" in line:
            self._install_phase = f"Apps check — {line.lstrip('✓ℹ⚠ ').strip()}"
            self._install_progress = max(self._install_progress, 40)
            self.progress["value"] = self._install_progress
        elif "ComfyUI repo:" in line or "ComfyUI models:" in line:
            self._install_phase = f"Catalog scan — {line.lstrip('✓ℹ⚠ ').strip()}"
            self._install_progress = max(self._install_progress, 8)
            self.progress["value"] = self._install_progress
        elif "Ollama models:" in line and "present" in line:
            self._install_phase = f"Ollama check — {line.lstrip('✓ℹ⚠ ').strip()}"
            self._install_progress = max(self._install_progress, 30)
            self.progress["value"] = self._install_progress
        elif "already on SSD — skipping download" in line:
            app = line.split("already on SSD", 1)[0].replace("✓", "").strip()
            self._install_phase = f"Apps — {app} OK on SSD"
            self._install_progress = max(self._install_progress, 44)
            self.progress["value"] = self._install_progress
        elif "ComfyUI already set up" in line or "synced tier nodes" in line.lower():
            self._install_phase = "ComfyUI — verified / nodes synced"
            self._install_progress = max(self._install_progress, 62)
            self.progress["value"] = self._install_progress
        elif "Skipped:" in line and any(m in line for m in GATED_MODEL_MARKERS):
            notified = getattr(self, "_hf_license_notified", False)
            if not notified and (
                "Agree" in line or "license" in line.lower() or "HuggingFace" in line
            ):
                self._hf_license_notified = True
                self.after(
                    0,
                    lambda: messagebox.showwarning(
                        "HuggingFace license needed",
                        "A gated model was skipped.\n\n"
                        "Your token may be fine — you must also accept the license "
                        "on the HuggingFace website while logged in.\n\n"
                        "Click \"SD 3.5 license\" in step 2, click Agree on the Stability page, "
                        "then INSTALL again.",
                    ),
                )
        self._refresh_install_eta()

    # Folders that grow during install — faster to measure than the whole tree.
    _SSD_MEASURE_DIRS = (
        "ollama-models", "comfyui-models", "lm-studio-models",
        "installers", "Applications", "comfyui",
    )

    def _measure_download_gb(self, root):
        """Sum download folders in KB — much faster than du on entire LOCAL_AI_GEN."""
        total_kb = 0
        for sub in self._SSD_MEASURE_DIRS:
            path = os.path.join(root, sub)
            if not os.path.isdir(path):
                continue
            try:
                result = subprocess.run(
                    ["du", "-sk", path],
                    capture_output=True, text=True, timeout=45, check=False,
                )
                if result.returncode == 0 and result.stdout.split():
                    total_kb += int(result.stdout.split()[0])
            except (OSError, subprocess.SubprocessError, ValueError):
                continue
        if total_kb <= 0:
            return None
        return f"{total_kb / (1024 * 1024):.1f}"

    def _apply_ssd_progress(self):
        """Progress from new downloads this session — not pre-existing SSD content."""
        if not self.installing:
            return
        ssd = getattr(self, "_ssd_gb", None)
        target = self._ssd_target_gb()
        if not ssd or not target:
            return
        try:
            gb = float(ssd)
        except (TypeError, ValueError):
            return
        baseline = getattr(self, "_install_ssd_baseline_gb", None)
        if baseline is not None:
            delta = max(0.0, gb - float(baseline))
            ssd_pct = 8 + min(delta / float(target), 1.0) * 89
        else:
            ssd_pct = 8 + min(gb / float(target), 1.0) * 89
        if ssd_pct > self._install_progress:
            self._install_progress = ssd_pct
            self.progress["value"] = self._install_progress

    def _ssd_download_text(self):
        ssd = getattr(self, "_ssd_gb", None)
        if ssd:
            return f"  ·  SSD now: {ssd} GB"
        if self.installing:
            return "  ·  SSD: measuring…"
        return ""

    def _update_ssd_size_label(self):
        if not hasattr(self, "ssd_size_label"):
            return
        if not self.installing:
            self.ssd_size_label.configure(text="", fg=GREEN, disabledforeground=GREEN)
            return
        ssd = getattr(self, "_ssd_gb", None)
        target = self._ssd_target_gb()
        updated = getattr(self, "_ssd_gb_at", None)
        age = ""
        if updated:
            age_s = int(time.time() - updated)
            if age_s < 60:
                age = f"  ·  updated {age_s}s ago"
            else:
                age = f"  ·  updated {age_s // 60}m ago"
        label = self._install_target_label()
        if ssd and target:
            text = f"SSD: {ssd} GB of ~{target} GB ({label}){age}"
        elif ssd:
            text = f"SSD: {ssd} GB downloaded{age}"
        else:
            text = f"SSD: measuring… (target ~{target or '?'} GB){age}"
        self.ssd_size_label.configure(text=text, fg=GREEN, disabledforeground=GREEN)

    def _poll_ssd_size(self):
        if not self.installing:
            return
        if getattr(self, "_ssd_measure_busy", False):
            self.after(12000, self._poll_ssd_size)
            return
        root = os.path.join(self.drive_path.get().strip(), "LOCAL_AI_GEN")
        self._ssd_measure_busy = True

        def measure():
            gb = None
            try:
                if os.path.isdir(root):
                    gb = self._measure_download_gb(root)
            finally:
                def apply():
                    self._ssd_measure_busy = False
                    if not self.installing:
                        return
                    if gb is not None:
                        if getattr(self, "_install_ssd_baseline_gb", None) is None:
                            self._install_ssd_baseline_gb = gb
                        self._ssd_gb = gb
                        self._ssd_gb_at = time.time()
                        self._apply_ssd_progress()
                    self._refresh_install_eta()
                    self.after(12000, self._poll_ssd_size)

                self.after(0, apply)

        threading.Thread(target=measure, daemon=True).start()

    def _refresh_install_eta(self):
        if not self.installing:
            return
        elapsed = self._format_elapsed(time.time() - self._install_started)
        tier = self.selected_tier.get()
        hint = self._install_time_hint or TIER_TIME_EST.get(tier, "2–4 hours")
        phase = self._install_phase or "Starting…"
        pct = int(self._install_progress)
        pulse = "●" if getattr(self, "_pulse_on", True) else "○"
        idle_s = time.time() - getattr(self, "_last_log_at", self._install_started)
        if idle_s >= 120:
            activity = "still working (large download — quiet log is normal)"
        elif idle_s >= 45:
            activity = "still working…"
        else:
            activity = "active"
        self._apply_ssd_progress()
        pct = int(self._install_progress)
        ssd_txt = self._ssd_download_text()
        self.eta_label.configure(
            text=(
                f"{pulse} {pct}%  ·  {phase}\n"
                f"Elapsed {elapsed}  ·  ~{hint}  ·  {activity}{ssd_txt}"
            ),
            fg=ACCENT2, disabledforeground=ACCENT2,
        )
        self._update_ssd_size_label()
        self.after_idle(self._sync_footer_progress_wrap)

    def _check_install_stall(self):
        if not self.installing:
            return
        idle = time.time() - getattr(self, "_last_log_at", self._install_started)
        if idle < STALL_ALERT_SEC:
            return
        now = time.time()
        if now - getattr(self, "_last_stall_alert", 0) < STALL_ALERT_SEC:
            return
        self._last_stall_alert = now
        macos_notify(
            "Local AI Studio — check for a Mac popup",
            FOLDER_PICKER_HINT,
            urgent=True,
        )

    def _maybe_notify_permission_phase(self, header):
        key = header.lower()
        if not any(phase in key for phase in PERMISSION_NOTIFY_PHASES):
            return
        notified = getattr(self, "_permission_notified_phases", set())
        tag = next((p for p in PERMISSION_NOTIFY_PHASES if p in key), header[:24])
        if tag in notified:
            return
        notified.add(tag)
        self._permission_notified_phases = notified
        macos_notify(
            "SSD access — use Open, not Cancel",
            FOLDER_PICKER_HINT,
        )

    def _maybe_alert_permission_issue(self, line):
        if not self.installing:
            return
        low = line.lower()
        if not any(
            needle in low
            for needle in (
                "operation not permitted",
                "permission denied",
                "no write access",
                "cannot write to",
            )
        ):
            return
        now = time.time()
        if now - getattr(self, "_last_perm_alert", 0) < 180:
            return
        self._last_perm_alert = now
        macos_notify(
            "SSD access blocked",
            FOLDER_PICKER_HINT,
            urgent=True,
        )

    def _install_tick(self):
        if not self.installing:
            return
        self._check_install_stall()
        self._refresh_install_eta()
        self.after(10000, self._install_tick)

    def _pulse_tick(self):
        if not self.installing:
            return
        self._pulse_on = not getattr(self, "_pulse_on", True)
        marker = "●" if self._pulse_on else "○"
        tier = self.selected_tier.get()
        self.status_label.configure(
            text=f"{marker} Installing {tier.upper()} — installer is running",
            fg=ACCENT2, disabledforeground=ACCENT2,
        )
        self._refresh_install_eta()
        self.after(1000, self._pulse_tick)

    def _log_line(self, line, tag="info"):
        self._last_log_at = time.time()
        self._parse_install_line(line)
        self._maybe_alert_permission_issue(line)
        if "✓" in line or "DONE" in line.upper():
            prefix = "✓ "
        elif "✗" in line or "error" in line.lower() or "failed" in line.lower():
            prefix = "✗ "
        elif "━━━" in line:
            prefix = "▸ "
        else:
            prefix = ""
        self.log.insert(tk.END, prefix + line)
        self.log.see(tk.END)
        self._sync_log_scroll()

    def _set_status(self, text, color=TEXT_DIM):
        self.status_label.configure(text=text, fg=color, disabledforeground=color)

    def _sync_ssd_status_wrap(self, event=None):
        if not hasattr(self, "_ssd_status_stack"):
            return
        try:
            width = self._ssd_status_stack.winfo_width()
            if width < 120:
                return
            wrap = max(width - 8, 240)
            if abs(wrap - self._ssd_status_wrap) < 16:
                return
            self._ssd_status_wrap = wrap
            for widget in (
                self._ssd_access_label,
                self.space_label,
                self.warning_label,
                getattr(self, "_hf_license_hint", None),
            ):
                if widget is not None:
                    widget.configure(wraplength=wrap)
        except tk.TclError:
            pass

    def _update_ssd_access_label(self):
        if not hasattr(self, "_ssd_access_label"):
            return
        if self._ssd_access_ok:
            text = "✓ SSD access granted"
            color = GREEN
        else:
            text = "⚠ Click Allow SSD Access before INSTALL"
            color = YELLOW
        self._ssd_access_label.configure(
            text=text, fg=color, disabledforeground=color,
        )

    def _check_ssd_access_silent(self):
        path = self.drive_path.get().strip()
        if not path or not is_usable_ssd_path(path):
            self._ssd_access_ok = False
            self._update_ssd_access_label()
            return
        ok, _err = verify_ssd_writable(path)
        self._ssd_access_ok = ok
        self._update_ssd_access_label()

    def _open_mac_ssd_settings(self):
        open_mac_full_disk_access_settings()
        messagebox.showinfo(
            "Stop repeated SSD popups",
            "System Settings should be open.\n\n"
            "BEST FIX (stops popup spam):\n"
            "  Privacy & Security → Full Disk Access\n"
            "  → add \"Install Local AI Studio (GUI)\" → ON\n\n"
            "Also check Files and Folders → Removable Volumes → ON\n"
            "for the same app.\n\n"
            "Then QUIT this installer completely (Cmd+Q), reopen it,\n"
            "click Allow SSD Access, then INSTALL.",
        )

    def _grant_ssd_access_interactive(self, path=None, prior_err=""):
        path = (path or self.drive_path.get() or "").strip()
        if not path or not os.path.isdir(path):
            messagebox.showerror("No drive", "Pick your SSD in the dropdown first.")
            return False

        messagebox.showinfo(
            "Allow SSD Access",
            "A folder window will open.\n\n"
            "Select the folder where LOCAL_AI_GEN should live\n"
            "(e.g. AI_INSTALLS if that's where your 140 GB install is).\n\n"
            "Click Open when that folder is selected.\n\n"
            "If Mac keeps popping up MORE windows during install,\n"
            "use Stop Popups (Mac Settings) → Full Disk Access.",
        )

        initial = path if os.path.isdir(path) else "/Volumes"
        chosen = macos_choose_folder(
            prompt="Select install folder (e.g. AI_INSTALLS), then Open",
            initial=initial,
        )
        if not chosen:
            return False

        existing = os.path.join(path, "LOCAL_AI_GEN")
        chosen_root = os.path.join(chosen, "LOCAL_AI_GEN")
        if (
            path != chosen
            and os.path.isdir(existing)
            and not os.path.isdir(chosen_root)
        ):
            if messagebox.askyesno(
                "Keep existing install folder?",
                f"Your install data is probably here:\n{existing}\n\n"
                f"You picked:\n{chosen}\n\n"
                "Keep using the existing folder?",
            ):
                chosen = path

        self._select_drive_path(chosen, remember=True)
        sealed, detail = seal_ssd_access_deep(chosen)
        seal_internal_comfyui_support(chosen)
        if not sealed:
            messagebox.showerror(
                "SSD still blocked",
                f"macOS blocked writing to:\n{chosen}\n\n{detail}\n\n"
                "Click Stop Popups (Mac Settings) → Full Disk Access, then try again.",
            )
            return False

        ok, err = verify_ssd_writable(chosen)
        if not ok:
            detail = prior_err or err or "Permission denied"
            messagebox.showerror(
                "SSD access not granted",
                f"Write test failed:\n{detail}\n\n"
                "Try Mac Settings Fix, or click Allow SSD Access again.\n"
                "Remember: sidebar → drive → Open (not the center list).",
            )
            return False

        self._ssd_access_ok = True
        self._update_ssd_access_label()
        self._save_prefs(ssd_access_volume=ssd_volume_root(chosen))
        messagebox.showinfo(
            "SSD access granted",
            "You're all set.\n\n"
            "Click INSTALL — downloads run from this app and should NOT "
            "show that confusing folder popup again.",
        )
        return True

    def _grant_ssd_access(self):
        self._grant_ssd_access_interactive()

    def _ensure_ssd_access(self):
        path = self.drive_path.get().strip()
        if not path:
            return False
        ok, err = verify_ssd_writable(path)
        if ok:
            sealed, detail = seal_ssd_access_deep(path)
            seal_internal_comfyui_support(path)
            if sealed:
                self._ssd_access_ok = True
                self._update_ssd_access_label()
                return True
            ok, err = False, detail
        if self._grant_ssd_access_interactive(path, prior_err=err):
            return True
        return False

    def _show_mac_permission_help(self):
        messagebox.showinfo("What that Mac window wants", MAC_PERMISSION_HELP)

    def _open_hf_license_pages(self):
        open_hf_gated_model_pages()
        messagebox.showinfo(
            "SD 3.5 license on HuggingFace",
            "Opened the Stability SD 3.5 Medium page in your browser.\n\n"
            "While logged into the SAME account as your token:\n"
            "  stabilityai/stable-diffusion-3.5-medium\n"
            "  → click \"Agree and access repository\"\n\n"
            "CyberRealistic has no license button — it is public and already\n"
            "downloads without an account.\n\n"
            "Then paste your Read token here and click INSTALL again.",
        )

    def _open_hf_sensitive_settings(self):
        open_hf_sensitive_settings()
        messagebox.showinfo(
            "HuggingFace content preferences",
            "Opened huggingface.co/settings/content-preferences\n\n"
            "Enable sensitive content viewing (free account).\n\n"
            "Tip: Use Setup guide for the full walkthrough (account → sensitive → token → paste).\n\n"
            "After install if needed: LOCAL_AI_GEN/scripts/fetch-sensitive-models.sh",
        )

    def _show_hf_sensitive_wizard(self, start_step=0):
        """Step-by-step assistant for the 3 optional HuggingFace realism weights."""
        if getattr(self, "_hf_wizard_win", None) is not None:
            try:
                if self._hf_wizard_win.winfo_exists():
                    self._hf_wizard_win.lift()
                    self._hf_wizard_win.focus_force()
                    return
            except tk.TclError:
                pass

        win = tk.Toplevel(self)
        win.title("HuggingFace setup — 3 optional models")
        win.configure(bg=BG_CARD)
        win.transient(self)
        win.resizable(False, False)
        self._hf_wizard_win = win
        self._hf_wizard_step_idx = max(0, min(start_step, len(HF_SENSITIVE_WIZARD_STEPS) - 1))

        header = flat_text(
            win, text="", font=("Helvetica", 13, "bold"),
            fg=ACCENT2, bg=BG_CARD, anchor="w", readonly=True, wraplength=440,
        )
        header.pack(fill=tk.X, padx=16, pady=(14, 6))

        body = flat_text(
            win, text="", font=("Helvetica", 11),
            fg=TEXT, bg=BG_CARD, anchor="nw", justify=tk.LEFT,
            readonly=True, wraplength=440,
        )
        body.pack(fill=tk.BOTH, expand=True, padx=16, pady=(0, 8))

        open_row = tk.Frame(win, bg=BG_CARD)
        open_row.pack(fill=tk.X, padx=16, pady=(0, 8))
        open_btn = tk.Button(
            open_row, text="Open page in browser",
            font=("Helvetica", 10, "bold"), fg="white", bg="#1f6feb",
            activebackground="#388bfd", relief=tk.FLAT, padx=10, pady=6,
            cursor="hand2",
        )
        open_btn.pack(side=tk.LEFT)

        nav = tk.Frame(win, bg=BG_CARD)
        nav.pack(fill=tk.X, padx=16, pady=(4, 14))

        def render_step():
            step = HF_SENSITIVE_WIZARD_STEPS[self._hf_wizard_step_idx]
            n = len(HF_SENSITIVE_WIZARD_STEPS)
            header.configure(text=f"{step['title']}  ({self._hf_wizard_step_idx + 1}/{n})")
            body.configure(text=step["body"])
            if step.get("url") and step.get("open_label"):
                open_btn.configure(
                    text=step["open_label"], state=tk.NORMAL,
                    command=lambda u=step["url"]: open_hf_url(u),
                )
                open_btn.pack(side=tk.LEFT)
            else:
                open_btn.pack_forget()
            back_btn.configure(
                state=tk.NORMAL if self._hf_wizard_step_idx > 0 else tk.DISABLED,
            )
            if self._hf_wizard_step_idx >= n - 1:
                next_btn.configure(text="Done — paste token below")
            else:
                next_btn.configure(text="Next →")

        def go_back():
            if self._hf_wizard_step_idx > 0:
                self._hf_wizard_step_idx -= 1
                render_step()

        def go_next():
            if self._hf_wizard_step_idx < len(HF_SENSITIVE_WIZARD_STEPS) - 1:
                self._hf_wizard_step_idx += 1
                render_step()
            else:
                win.destroy()
                self._hf_wizard_win = None
                messagebox.showinfo(
                    "Paste your token",
                    "Scroll to the orange HuggingFace box on the main screen.\n\n"
                    "Paste Token from Clipboard → then click INSTALL.\n\n"
                    "No token? Install anyway — use fetch-sensitive-models.sh after.",
                )

        back_btn = tk.Button(
            nav, text="← Back", font=("Helvetica", 10, "bold"),
            fg=TEXT, bg="#30363d", activebackground="#484f58",
            relief=tk.FLAT, padx=10, pady=6, cursor="hand2", command=go_back,
        )
        back_btn.pack(side=tk.LEFT)
        tk.Button(
            nav, text="Close", font=("Helvetica", 10),
            fg=TEXT_DIM, bg=BG_CARD, activebackground=BG_SEL,
            relief=tk.FLAT, padx=8, pady=6, cursor="hand2",
            command=lambda: (win.destroy(), setattr(self, "_hf_wizard_win", None)),
        ).pack(side=tk.RIGHT)
        next_btn = tk.Button(
            nav, text="Next →", font=("Helvetica", 10, "bold"),
            fg="white", bg="#238636", activebackground="#2ea043",
            relief=tk.FLAT, padx=12, pady=6, cursor="hand2", command=go_next,
        )
        next_btn.pack(side=tk.RIGHT, padx=(0, 8))

        render_step()
        win.update_idletasks()
        w, h = win.winfo_reqwidth(), win.winfo_reqheight()
        x = self.winfo_rootx() + max(0, (self.winfo_width() - w) // 2)
        y = self.winfo_rooty() + max(0, (self.winfo_height() - h) // 2)
        win.geometry(f"+{x}+{y}")

    def _maybe_offer_hf_setup_before_install(self):
        """Return False if user cancels install from the pre-install HF prompt."""
        if not self.unfiltered_pack.get() or self._hf_token_value():
            return True
        if self._load_prefs().get("saw_hf_sensitive_setup_intro"):
            return True
        ans = messagebox.askyesnocancel(
            "Before you install — HuggingFace (optional)",
            "WHEN: Now is the best time to set up HuggingFace for the 3 optional realism weights.\n\n"
            "You have not pasted a token yet. Those 3 will likely skip.\n"
            "The rest of the pack (~140 GB) still installs normally.\n\n"
            "• Yes — open step-by-step setup guide\n"
            "• No — install anyway (retry script on SSD later)\n"
            "• Cancel — stay on this screen",
        )
        if ans is None:
            return False
        if ans:
            self._show_hf_sensitive_wizard()
        return True

    def _maybe_offer_hf_setup_after_install(self, ssd_path):
        missing = count_missing_sensitive_models(ssd_path)
        if missing <= 0 or not self.unfiltered_pack.get():
            return
        fetch = os.path.join(ssd_path, "LOCAL_AI_GEN", "scripts", "fetch-sensitive-models.sh")
        if messagebox.askyesno(
            "Optional — 3 realism models",
            f"Install finished. {missing} of 3 optional HuggingFace realism weights did not download.\n\n"
            "WHEN: Do this whenever you are ready — studio is already usable.\n\n"
            "• Open Setup guide — walk through account + content preferences + token\n"
            "• Then run fetch-sensitive-models.sh on your SSD\n\n"
            "Open the setup guide now?",
        ):
            self._show_hf_sensitive_wizard()
        else:
            messagebox.showinfo(
                "Retry later",
                f"When ready, run:\n{fetch}\n\n"
                "Or click INSTALL again with Unfiltered Pack + HF token pasted.",
            )

    def _show_hf_login_help(self):
        pack = self.unfiltered_pack.get()
        pack_block = ""
        if pack:
            pack_block = (
                "\nUNFILTERED PACK — use Setup guide button for full walkthrough:\n"
                "  WHEN (before install): account → content preferences → Read token → paste\n"
                "  WHEN (after install): scripts/fetch-sensitive-models.sh on SSD\n"
                "  Install never blocks if these 3 skip.\n"
            )
        messagebox.showinfo(
            "HuggingFace — optional steps",
            "Most models download with no account. Two optional cases:\n"
            f"{pack_block}\n"
            "SD 3.5 MEDIUM (Ultimate tier only):\n"
            "  Click SD 3.5 license → Agree on stabilityai/stable-diffusion-3.5-medium\n"
            "  + Read token pasted here\n\n"
            "TOKEN:\n"
            "  Settings → Access Tokens → New (Read) → Paste Token from Clipboard\n\n"
            "Terminal: pip3 install -U huggingface_hub && huggingface-cli login",
        )

    def _maybe_show_permission_help(self):
        prefs = self._load_prefs()
        if prefs.get("saw_mac_permission_help"):
            return
        self._save_prefs(saw_mac_permission_help=True)
        messagebox.showinfo(
            "Before you install",
            "One Mac quirk: external SSDs need a one-time \"Allow SSD Access\" click.\n\n"
            "Use the orange button in step 3 BEFORE clicking INSTALL.\n"
            "That avoids the confusing folder popup during download.\n\n"
            "See \"Mac popup help?\" if Open keeps opening folders.",
        )

    def _validate(self):
        tier_on, pack_on = self._install_targets()
        if not tier_on and not pack_on:
            messagebox.showerror(
                "Nothing selected",
                "Select a package (click a card), and/or check Unfiltered Models Pack.",
            )
            return False
        tier = self._tier_for_install()
        path = self.drive_path.get().strip()
        if not path or not os.path.isdir(path):
            messagebox.showerror("No Drive Selected", "Pick your external SSD or click Browse…")
            return False
        if not self._ensure_ssd_access():
            return False
        if not os.path.ismount(path) and not path.startswith("/Volumes/"):
            if not messagebox.askyesno(
                "Use this folder?",
                f"Install to:\n{path}\n\nThis doesn't look like a top-level volume. Continue?",
            ):
                return False
        try:
            st = os.statvfs(path)
            free = (st.f_frsize * st.f_bavail) // (1024 ** 3)
        except OSError:
            messagebox.showerror("Drive Error", f"Cannot read drive: {path}")
            return False
        need = self._tier_drive_need_gb(tier)
        if free < need - 20:
            target = self._install_target_label()
            extra = ""
            if pack_on:
                extra = f"\nIncludes Unfiltered Pack (+~{UNFILTERED_PACK_GB} GB)."
            if not messagebox.askyesno(
                "Low Space Warning",
                f"Only {free} GB free but {target} needs ~{need} GB.{extra}\n\nContinue anyway?",
            ):
                return False
        return True

    def _install_confirm_message(self, ssd):
        """Single pre-install summary — replaces separate pack/tier/models-only prompts."""
        tier_on, pack_on = self._install_targets()
        tier = self._tier_for_install()
        est = self._install_time_estimate()
        target = self._install_target_label()
        models_only = self._effective_models_only(ssd)
        notes = []
        if models_only:
            headline = f"Models-only download: {target}"
            notes.append("Skips apps, ComfyUI setup, Homebrew, and Ollama — SSD apps stay untouched")
        else:
            headline = f"Install {target}" if tier_on or pack_on else "Install"
            notes.append("Fresh Mac? Apple's Command Line Tools only (installer opens it if missing)")
            notes.append("Homebrew + Ollama are installed for you")
        if pack_on and not self._hf_token_value():
            notes.append("No HF token yet — 3 optional realism weights may skip (rest of pack still installs)")
        if tier_on and tier == "ultimate":
            notes.append("ULTIMATE ~150 GB — on 16GB RAM, run one heavy model at a time")
        common = [
            "SSD access should already be granted (orange button in step 3)",
            "Install runs from THIS app — not Terminal (fewer Mac popups)",
            "Keep Mac plugged in — sleep is prevented during install",
            "Re-run anytime — scans SSD vs catalog, fills gaps",
        ]
        if not models_only:
            common.insert(0, "Progress shows here; details in /tmp/local-ai-installer*.log")
        body = "\n".join(f"• {line}" for line in notes + common)
        return f"{headline}\nUsually takes {est}.\n\n{body}\n\nStart now?"

    def _check_command_line_tools(self):
        try:
            ok = subprocess.run(
                ["xcode-select", "-p"],
                capture_output=True, timeout=5, check=False,
            ).returncode == 0
        except (OSError, subprocess.SubprocessError):
            ok = False
        if ok:
            return True

        messagebox.showinfo(
            "One-time Apple setup",
            "Your Mac needs Apple's Command Line Tools before we can install AI apps.\n\n"
            "We'll open Apple's installer now:\n"
            "  1. Click Install (not Get Xcode)\n"
            "  2. Wait ~5–10 minutes\n"
            "  3. Come back and click INSTALL again\n\n"
            "After that, we handle Homebrew, Ollama, and all models for you.",
        )
        try:
            subprocess.run(["xcode-select", "--install"], check=False, timeout=5)
        except (OSError, subprocess.SubprocessError):
            pass
        self._set_status(
            "Waiting for Apple's Command Line Tools — click INSTALL again when done.",
            YELLOW,
        )
        self.eta_label.configure(
            text="Paused for Apple Developer Tools — not an error. Click INSTALL again after Install finishes.",
            fg=YELLOW, disabledforeground=YELLOW,
        )
        return False

    def _get_running_install_pid(self):
        try:
            if not os.path.isfile(INSTALL_PID_FILE):
                return None
            with open(INSTALL_PID_FILE, encoding="utf-8") as fh:
                pid = int(fh.read().strip())
            os.kill(pid, 0)
            return pid
        except (OSError, ValueError):
            return None

    def _sync_footer_layout(self):
        """Slim footer before install — progress stack only while installing."""
        pid = self._get_running_install_pid()
        active = self.installing or pid is not None

        if active:
            self._install_cta.configure(
                text="Installing:",
                fg=ACCENT2, disabledforeground=ACCENT2,
            )
            if not self._progress_stack.winfo_ismapped():
                self._progress_stack.pack(fill=tk.X, pady=(4, 0), before=self.status_label)
        else:
            btn = self._install_button_label()
            step3 = f"Step 3 — click {btn} when selections + SSD are set:"
            self._install_cta.configure(
                text=step3,
                fg=ACCENT2, disabledforeground=ACCENT2,
            )
            self._progress_stack.pack_forget()
            if self.log_frame.winfo_ismapped():
                self.log_frame.pack_forget()
        self.after_idle(self._sync_footer_progress_wrap)

    def _sync_install_controls(self):
        """STOP is always visible — enabled when a background install is active."""
        pid = self._get_running_install_pid()
        running = self.installing or pid is not None
        if running:
            self.stop_btn.configure(state=tk.NORMAL, bg=RED, cursor="hand2")
            if self.installing:
                self.install_btn.configure(state=tk.DISABLED, text="INSTALLING…", bg=TEXT_DIM)
            else:
                self.install_btn.configure(state=tk.NORMAL, text=self._install_button_label(), bg=ACCENT)
                if pid:
                    self._set_status(
                        f"Background install running (PID {pid}) — click STOP to cancel.",
                        YELLOW,
                    )
        else:
            self.stop_btn.configure(state=tk.DISABLED, bg="#6e7681", cursor="arrow")
            if not self.installing:
                self.install_btn.configure(state=tk.NORMAL, text=self._install_button_label(), bg=ACCENT)
        self._sync_footer_layout()

    def _poll_background_install(self):
        """Re-check for background install so STOP enables if user re-opens the app."""
        if not self.installing:
            self._sync_install_controls()
        self.after(5000, self._poll_background_install)

    def _check_background_install(self):
        pid = self._get_running_install_pid()
        if pid and not self.installing:
            self._show_install_log()
            self._find_latest_install_log()
            self._log_line(
                f"Background install detected (PID {pid}) — click STOP to cancel.",
                "warn",
            )
            self._start_log_tail()
        self._sync_install_controls()

    def _start_log_tail(self):
        def tail_log():
            if self.installing or self._get_running_install_pid():
                self._tail_install_log()
                threading.Timer(2.0, tail_log).start()
        threading.Timer(1.0, tail_log).start()

    def _stop_install(self):
        pid = self._get_running_install_pid()
        wrapper = getattr(self, "proc", None)
        wrapper_pid = wrapper.pid if wrapper and wrapper.poll() is None else None
        if not pid and not wrapper_pid and not self.installing:
            messagebox.showinfo("Nothing to stop", "No background install is running.")
            self._sync_install_controls()
            return
        if not messagebox.askyesno(
            "Stop install?",
            "Stop the background install?\n\n"
            "• Safe — models already on your SSD are kept\n"
            "• Click INSTALL again later to resume\n"
            "• Dismiss any Mac folder-permission popup (click Cancel on it)\n\n"
            "Stop now?",
        ):
            return
        self.installing = False
        stopped = stop_install_processes(wrapper_pid=wrapper_pid)
        if wrapper and wrapper.poll() is None:
            try:
                wrapper.terminate()
                wrapper.wait(timeout=3)
            except (OSError, subprocess.SubprocessError):
                try:
                    wrapper.kill()
                except OSError:
                    pass
        self._log_line(
            f"━━━ Install stopped (PIDs: {', '.join(map(str, stopped)) or 'none'}) ━━━",
            "warn",
        )
        self._sync_install_controls()
        self._set_status("Install stopped — click INSTALL to resume when ready.", YELLOW)
        self.eta_label.configure(
            text="Stopped. SSD progress saved. Dismiss any stuck Mac folder popup, then INSTALL again.",
            fg=YELLOW, disabledforeground=YELLOW,
        )
        messagebox.showinfo(
            "Install stopped",
            "Background install has been stopped.\n\n"
            "If a Mac folder-permission window is still open, click Cancel on it.\n\n"
            "Your SSD progress is saved — click INSTALL again to resume.",
        )

    def _read_install_exit_code(self, since=None):
        if not os.path.isfile(INSTALL_EXIT_FILE):
            return None
        if since is not None:
            try:
                if os.path.getmtime(INSTALL_EXIT_FILE) < since - 0.25:
                    return None
            except OSError:
                return None
        try:
            with open(INSTALL_EXIT_FILE, encoding="utf-8") as fh:
                raw = fh.read().strip()
            parts = raw.split()
            if len(parts) == 2:
                pid, code = int(parts[0]), int(parts[1])
                if code == 0 and os.path.isfile(INSTALL_COMPLETE_FILE):
                    return 0
                expected = getattr(self, "_expected_install_pid", None)
                if expected and pid != expected:
                    return None
                return code
            return int(raw)
        except (ValueError, OSError):
            return None

    def _install_really_complete(self):
        if os.path.isfile(INSTALL_COMPLETE_FILE):
            return True
        for _ in range(6):
            if self._install_log_shows_complete():
                return True
            time.sleep(0.4)
        return False

    def _launch_install_background(self, installer, workdir, tier, ssd, hf_token=""):
        """Fallback when Terminal cannot be opened."""
        env = os.environ.copy()
        env["PATH"] = ":".join([
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            env.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"),
        ])
        env["LOCAL_AI_CAFFEINATED"] = "1"
        env["LOCAL_AI_SKIP_DESKTOP"] = "1"
        env["LOCAL_AI_LAYOUT_READY"] = "1"
        if hf_token.strip():
            env["HF_TOKEN"] = hf_token.strip()
        cmd = ["/bin/bash", installer, "--tier", tier, "--ssd", ssd, "--no-gui"]
        cmd.extend(self._build_install_flags(ssd=ssd))
        self.proc = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            cwd=workdir,
            env=env,
            start_new_session=False,
            close_fds=True,
        )
        return self.proc

    def _install_log_tail(self):
        path = getattr(self, "_install_log_path", None)
        if not path:
            logs = sorted(glob.glob("/tmp/local-ai-installer-*.log"), reverse=True)
            path = logs[0] if logs else None
        if not path or not os.path.isfile(path):
            return ""
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                return fh.read()[-12000:]
        except OSError:
            return ""

    def _install_log_shows_complete(self):
        if os.path.isfile(INSTALL_COMPLETE_FILE):
            return True
        tail = self._install_log_tail()
        if not tail:
            return False
        markers = (
            "DONE —",
            "Launchers →",
            "SSD launcher hub ready",
            "photoreal studio is live",
        )
        return any(marker in tail for marker in markers)

    def _start_install(self):
        if self.installing:
            return
        if not self._validate():
            return
        if not self._check_command_line_tools():
            return
        if not self._maybe_offer_hf_setup_before_install():
            return

        running_pid = self._get_running_install_pid()
        if running_pid:
            messagebox.showwarning(
                "Install already running",
                f"A background install is still running (PID {running_pid}).\n\n"
                "Click STOP INSTALL to cancel it, or wait for it to finish.\n\n"
                "Log: /tmp/local-ai-installer*.log",
            )
            self._sync_install_controls()
            return

        tier_on, pack_on = self._install_targets()
        if tier_on:
            tier = self.selected_tier.get()
        elif pack_on:
            tier = "ultimate"
        else:
            tier = self._tier_for_install()
        ssd = self.drive_path.get().strip()
        try:
            installer, workdir = prepare_install_bundle()
        except OSError as exc:
            messagebox.showerror("Installer Error", f"Could not prepare install bundle:\n{exc}")
            return

        if not os.path.isfile(installer):
            messagebox.showerror("Missing Installer", f"Not found:\n{installer}")
            return

        self._maybe_show_permission_help()

        est = self._install_time_estimate()
        if not messagebox.askokcancel("Start install?", self._install_confirm_message(ssd)):
            return

        tier_on, pack_on = self._install_targets()
        self._save_prefs(
            last_ssd=ssd,
            last_tier=self.selected_tier.get() if tier_on else "",
            unfiltered_pack=pack_on,
        )
        self._show_install_log()
        self.installing = True
        self._install_started = time.time()
        self._install_launch_time = self._install_started
        self._last_log_at = self._install_started
        self._install_phase = "Starting…"
        self._install_progress = 2
        self._install_time_hint = est
        self._ssd_gb = None
        self._ssd_gb_at = None
        self._install_ssd_baseline_gb = None
        self._ssd_measure_busy = False
        self._pulse_on = True
        self._install_log_path = None
        self._install_log_pos = 0
        self._expected_install_pid = None
        self._last_stall_alert = 0.0
        self._last_perm_alert = 0.0
        self._permission_notified_phases = set()
        self._hf_license_notified = False
        self._sync_install_controls()
        self.progress["value"] = self._install_progress
        start_label = self._install_target_label()
        self._set_status(
            f"● Installing {start_label} — keep this window open for progress.",
            ACCENT2,
        )
        self._refresh_install_eta()
        self.after(10000, self._install_tick)
        self.after(1000, self._pulse_tick)
        self.after(3000, self._poll_ssd_size)
        flags = self._build_install_flags(ssd=ssd)
        self._log_line(f"━━━ Starting {start_label} install → {ssd} ━━━", "step")
        self._log_line(
            f"Mode: {self._install_mode_label()}  ·  tier={tier.upper()}  ·  flags={flags or '(none)'}",
            "info",
        )

        def tail_log():
            if self.installing:
                self._tail_install_log()
                threading.Timer(2.0, tail_log).start()

        def capture_install_pid():
            for _ in range(20):
                time.sleep(0.5)
                try:
                    if os.path.isfile(INSTALL_PID_FILE):
                        with open(INSTALL_PID_FILE, encoding="utf-8") as fh:
                            self._expected_install_pid = int(fh.read().strip())
                        return
                except (ValueError, OSError):
                    pass

        def run():
            try:
                for stale in (INSTALL_EXIT_FILE, INSTALL_COMPLETE_FILE, INSTALL_PID_FILE):
                    try:
                        os.remove(stale)
                    except OSError:
                        pass
                self.proc = None
                hf_token = self._hf_token_value()
                sealed, _detail = seal_ssd_access_deep(ssd)
                seal_internal_comfyui_support(ssd)
                if not sealed:
                    self.after(
                        0, self._log_line,
                        "SSD seal failed — click Allow SSD Access or Stop Popups in Mac Settings.",
                        "warn",
                    )
                self._launch_install_background(
                    installer, workdir, tier, ssd, hf_token=hf_token,
                )
                self.after(
                    0, self._log_line,
                    "Install running from this app (SSD access pre-granted).",
                    "info",
                )
                threading.Thread(target=capture_install_pid, daemon=True).start()
                saw_pid = False
                code = None
                launch_at = getattr(self, "_install_launch_time", time.time())
                while self.installing:
                    time.sleep(1.0)
                    pid = self._get_running_install_pid()
                    if pid:
                        self._expected_install_pid = pid
                        saw_pid = True
                    code = self._read_install_exit_code(since=launch_at)
                    if code is not None and not pid:
                        break
                    if self.proc is not None and self.proc.poll() is not None:
                        time.sleep(0.5)
                        code = self._read_install_exit_code(since=launch_at)
                        if code is None:
                            code = self.proc.returncode if self.proc.returncode is not None else 1
                        break
                    if saw_pid and not pid:
                        time.sleep(1.0)
                        code = self._read_install_exit_code(since=launch_at)
                        if code is None:
                            code = 0 if os.path.isfile(INSTALL_COMPLETE_FILE) else 1
                        break
                if code is None:
                    code = 130
                self.after(0, self._install_done, code)
            except Exception as e:
                self.after(0, self._install_done, 1, str(e))

        threading.Thread(target=run, daemon=True).start()
        threading.Timer(3.0, tail_log).start()

    def _measure_full_install_gb(self, root):
        """Full LOCAL_AI_GEN size (du -sg) — run when install is truly complete."""
        if not os.path.isdir(root):
            return None
        try:
            result = subprocess.run(
                ["du", "-sg", root],
                capture_output=True, text=True, timeout=180, check=False,
            )
            if result.returncode == 0 and result.stdout.split():
                return int(result.stdout.split()[0])
        except (OSError, subprocess.SubprocessError, ValueError):
            pass
        return None

    def _read_install_stats(self, root):
        path = os.path.join(root, ".install-stats.json")
        if not os.path.isfile(path):
            return {}
        try:
            with open(path, encoding="utf-8") as fh:
                data = json.load(fh)
                return data if isinstance(data, dict) else {}
        except (OSError, ValueError, TypeError):
            return {}

    def _parse_hf_counts_from_log(self, log_tail):
        match = re.search(r"Downloaded (\d+) / (\d+) models", log_tail)
        if match:
            return int(match.group(1)), int(match.group(2))
        match = re.search(r"ComfyUI models: (\d+) present, (\d+) missing", log_tail)
        if match:
            ok, missing = int(match.group(1)), int(match.group(2))
            return ok, ok + missing
        return None, None

    def _build_completion_message(self, dest, tier):
        log_tail = self._install_log_tail()
        stats = self._read_install_stats(dest)
        ssd_gb = stats.get("ssd_gb") or self._measure_full_install_gb(dest)
        if ssd_gb is None:
            try:
                ssd_gb = int(float(getattr(self, "_ssd_gb", None)))
            except (TypeError, ValueError):
                ssd_gb = None

        hf_ok = stats.get("hf_models_ok")
        hf_total = stats.get("hf_models_total")
        if hf_ok is None or hf_total is None:
            parsed_ok, parsed_total = self._parse_hf_counts_from_log(log_tail)
            if hf_ok is None:
                hf_ok = parsed_ok
            if hf_total is None:
                hf_total = parsed_total

        target = self._ssd_target_gb(tier)
        size_line = f"SSD: ~{ssd_gb} GB measured" if ssd_gb else "SSD: size measuring…"
        models_line = ""
        if hf_ok is not None and hf_total is not None:
            models_line = f"ComfyUI models: {hf_ok}/{hf_total}"
            if hf_ok < hf_total:
                models_line += (
                    "\nSome models skipped — SD 3.5 needs HF license + token, then INSTALL again."
                )
        else:
            models_line = "ComfyUI models: see install log"

        if self._effective_models_only(self.drive_path.get().strip()):
            return (
                f"Models download complete!\n\n"
                f"{size_line} in\n{dest}\n"
                f"(~{target} GB target for {self._install_target_label()})\n"
                f"{models_line}\n\n"
                f"Your existing apps were not changed.\n"
                f"Open ComfyUI or LM Studio from your Desktop launcher to use new weights.\n\n"
                f"See docs/WHICH_APP.txt on your SSD for paths and app tips."
            )

        return (
            f"Local AI Studio is installed!\n\n"
            f"{size_line} in\n{dest}\n"
            f"(~{target} GB is the {tier.upper()} estimate — measured after full install)\n"
            f"{models_line}\n\n"
            f"On your Desktop:\n"
            f"  • AI Studio Launcher.app — start here\n"
            f"  • AI Studio Apps/ — shortcuts to each app\n"
            f"  • Launch AI Studio.command — starts everything\n\n"
            f"MAKE IMAGES: DiffusionBee (easy) or ComfyUI → localhost:8188\n"
            f"CHAT / CODING: Ollama or LM Studio — not the same as image gen\n"
            f"  (Codex, Copilot CLI, etc. in Ollama = coding tools we didn't install)\n\n"
            f"See docs/WHICH_APP.txt on your SSD for the full cheat sheet.\n\n"
            f"Open WebUI → localhost:8080 (needs Docker)\n\n"
            f"You can trash the installer .app & eject the DMG if you like."
        )

    def _finish_desktop_shortcuts(self):
        ssd = self.drive_path.get().strip()
        if not ssd:
            return False, "no SSD path"
        ok, detail = create_desktop_shortcuts_for(ssd)
        if ok:
            self._log_line(f"✓ Desktop shortcuts: {detail or 'created'}", "ok")
        else:
            self._log_line(f"Desktop shortcuts need attention: {detail}", "err")
        return ok, detail

    def _install_done(self, code, err=None):
        self.installing = False
        self._sync_install_controls()

        if code == 10:
            self.progress["value"] = 0
            self._set_status(
                "Paused — install Apple's Command Line Tools, then click INSTALL again.",
                YELLOW,
            )
            self.eta_label.configure(
                text="One-time Apple setup — click Install in Apple's dialog, wait, then INSTALL again.",
                fg=YELLOW, disabledforeground=YELLOW,
            )
            messagebox.showinfo(
                "Come back in a few minutes",
                "Apple's Command Line Tools are installing.\n\n"
                "When the download finishes, click INSTALL LOCAL AI STUDIO again.\n\n"
                "This is normal on a fresh Mac — not an error.",
            )
            return

        if code == 0 and not self._install_really_complete():
            code = 1
            self._log_line(
                "Install exited cleanly but did not reach the finish step — check Terminal or log, then INSTALL again.",
                "err",
            )

        log_tail = self._install_log_tail()
        needs_desktop = (
            code == 0
            or ("Desktop launcher" in log_tail and "Launchers →" not in log_tail)
        )
        if needs_desktop:
            self._finish_desktop_shortcuts()

        if code == 0:
            self.progress["value"] = 100
            elapsed = self._format_elapsed(time.time() - getattr(self, "_install_started", time.time()))
            self.eta_label.configure(
                text=f"Finished in {elapsed}. Double-click Launch AI Studio on your Desktop.",
                fg=GREEN, disabledforeground=GREEN,
            )
            self._set_status("✓ Install complete! Double-click Launch AI Studio on your Desktop.", GREEN)
            self._log_line("━━━ INSTALL COMPLETE ━━━", "ok")
            dest = os.path.join(self.drive_path.get(), "LOCAL_AI_GEN")
            tier = self.selected_tier.get()

            def finalize_complete():
                measured = self._measure_full_install_gb(dest)
                if measured is not None:
                    self._ssd_gb = str(measured)
                    self._save_prefs(
                        last_observed_gb=measured,
                        last_observed_tier=tier,
                        **{f"observed_gb_{tier}": measured},
                    )
                    self._apply_ssd_progress()
                msg = self._build_completion_message(dest, tier)
                ssd_path = self.drive_path.get().strip()

                def show_done():
                    messagebox.showinfo("You're Done! 🎉", msg)
                    self._maybe_offer_hf_setup_after_install(ssd_path)

                self.after(0, show_done)

            threading.Thread(target=finalize_complete, daemon=True).start()
            try:
                subprocess.run(["open", dest], check=False)
            except Exception:
                pass
        elif code in (130, 143):
            self.progress["value"] = 0
            self.eta_label.configure(
                text="Install interrupted — click INSTALL again to resume from ~5 GB already downloaded.",
                fg=YELLOW, disabledforeground=YELLOW,
            )
            self._set_status("Install interrupted — not a model error. Click INSTALL to resume.", YELLOW)
            still = (
                getattr(self, "proc", None)
                and self.proc.poll() is None
            )
            messagebox.showwarning(
                "Install interrupted",
                "The install was stopped before it finished (exit 143).\n\n"
                "Your SSD progress is saved — click INSTALL again to resume.\n\n"
                "Check /tmp/local-ai-installer*.log for the last step.\n"
                "If the log still shows activity, the install may still be running.\n\n"
                "Click INSTALL again — it skips models already on your SSD."
                + ("\n\nNote: install process may still be running." if still else ""),
            )
        else:
            self.progress["value"] = 0
            self.eta_label.configure(
                text="Install stopped — see log below or /tmp/local-ai-installer*.log",
                fg=RED, disabledforeground=RED,
            )
            self._set_status(f"Install failed (code {code}). See log below.", RED)
            if err:
                self._log_line(err, "err")
            incomplete = self._install_log_shows_complete() is False
            log_tail = self._install_log_tail()
            extra = ""
            if incomplete:
                extra = (
                    "\n\nInstall did not finish (models/launchers may be incomplete). "
                    "Click INSTALL again to resume — progress on SSD is saved."
                )
            elif "Desktop launcher" in log_tail and "Launchers →" not in log_tail:
                extra = (
                    "\n\nModels likely finished — only Desktop shortcuts failed. "
                    "Click INSTALL again (fast) or run --launchers-only from Terminal."
                )
            messagebox.showerror(
                "Install Failed",
                f"Something went wrong (exit {code}).\n\nCheck the log in the installer window.\n"
                f"Full log also at /tmp/local-ai-installer*.log{extra}",
            )


def main():
    macos_make_foreground_app()
    root = InstallerGUI()
    style = ttk.Style(root)
    style.theme_use("clam")
    style.configure("TProgressbar", troughcolor=BG_CARD, background=ACCENT, thickness=8)
    style.configure("TCombobox", fieldbackground=BG_CARD, foreground=TEXT, background=BG_CARD)
    root.after(400, root._bring_to_front)
    root.after(450, root._sync_all_scrollbars)
    root.mainloop()


if __name__ == "__main__":
    main()