#!/usr/bin/env python3
"""AI Studio Launcher — one window to open every installed GUI."""

import os
import subprocess
import sys
import tkinter as tk
from tkinter import messagebox

BG = "#0d1117"
BG_CARD = "#161b22"
ACCENT = "#ff6b35"
ACCENT2 = "#4ecdc4"
TEXT = "#f0f6fc"
TEXT_DIM = "#8b949e"
GREEN = "#3fb950"


def script_dir():
    return os.path.dirname(os.path.abspath(__file__))


def load_shell_env():
    env_file = os.path.join(script_dir(), "local-ai-env.sh")
    if not os.path.isfile(env_file):
        return {}
    try:
        out = subprocess.run(
            ["bash", "-c", f'source "{env_file}" && printf "%s\\n" "$LOCAL_AI_ROOT" "$COMFYUI_ROOT" "$COMFYUI_VENV"'],
            capture_output=True,
            text=True,
            timeout=10,
            check=True,
        )
        lines = [ln.strip() for ln in out.stdout.splitlines() if ln.strip()]
        keys = ["LOCAL_AI_ROOT", "COMFYUI_ROOT", "COMFYUI_VENV"]
        return {keys[i]: lines[i] for i in range(min(len(lines), len(keys)))}
    except (OSError, subprocess.SubprocessError):
        return {}


def run_helper(action):
    helper = os.path.join(script_dir(), "launch-helpers.sh")
    env_file = os.path.join(script_dir(), "local-ai-env.sh")
    if not os.path.isfile(helper) or not os.path.isfile(env_file):
        messagebox.showerror("Missing files", f"Expected:\n{helper}\n{env_file}\n\nRe-run the installer.")
        return
    subprocess.Popen(
        ["bash", "-c", f'source "{env_file}" && source "{helper}" && {action}'],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


class StudioLauncher(tk.Tk):
    def __init__(self):
        super().__init__()
        self.env = load_shell_env()
        self.title("AI Studio Launcher")
        self.configure(bg=BG)
        self.resizable(False, False)
        self._center(420, 600)

        tk.Label(
            self, text="AI Studio Launcher", font=("Helvetica", 18, "bold"),
            fg=TEXT, bg=BG,
        ).pack(pady=(16, 4))
        tier = os.environ.get("LOCAL_AI_TIER", "")
        root = self.env.get("LOCAL_AI_ROOT", "")
        sub = root if root else "Open an app below"
        if len(sub) > 52:
            sub = "…" + sub[-49:]
        tk.Label(
            self, text=sub, font=("Helvetica", 10),
            fg=TEXT_DIM, bg=BG, wraplength=380,
        ).pack(pady=(0, 12))

        card = tk.Frame(self, bg=BG_CARD, padx=16, pady=12)
        card.pack(fill=tk.BOTH, expand=True, padx=16, pady=(0, 8))

        buttons = [
            ("Free RAM for AI", "free_ram_for_ai", "#d29922", "Quit background apps — keeps Finder, then open one AI app"),
            ("Launch All", "launch_all", ACCENT, "Start everything (Ollama + apps + browsers)"),
            ("LM Studio", "open_lm_studio", ACCENT2, "Describe photos, vision chat, MLX models"),
            ("DiffusionBee", "open_diffusionbee", ACCENT2, "Quick realistic image generation"),
            ("ComfyUI", "start_comfyui", GREEN, "Photo editing — built-in viewer (localhost:8188)"),
            ("Open WebUI", "start_open_webui", GREEN, "Chat UI — built-in viewer (localhost:8080)"),
            ("Draw Things (App Store)", "open_draw_things", TEXT_DIM, "Optional native editor — Mac App Store"),
            ("Open Apps Folder", "open_apps_folder", TEXT_DIM, "Finder folder with all shortcuts"),
            ("Photo Editing Guide", "open_photo_guide", TEXT_DIM, "docs/PHOTO_EDITING.txt"),
            ("RAM & Models Guide", "open_ram_guide", TEXT_DIM, "8–64 GB: which weights to use"),
        ]
        for label, action, color, tip in buttons:
            self._btn(card, label, action, color, tip)

        tk.Label(
            self, text="Tip: use one heavy app at a time on 16GB RAM",
            font=("Helvetica", 9), fg=TEXT_DIM, bg=BG,
        ).pack(pady=(4, 14))

    def _center(self, w, h):
        self.update_idletasks()
        x = (self.winfo_screenwidth() - w) // 2
        y = (self.winfo_screenheight() - h) // 2
        self.geometry(f"{w}x{h}+{x}+{y}")

    def _btn(self, parent, label, action, color, tip):
        row = tk.Frame(parent, bg=BG_CARD)
        row.pack(fill=tk.X, pady=4)
        tk.Button(
            row, text=label, font=("Helvetica", 12, "bold"),
            fg="white", bg=color, activebackground=color,
            relief=tk.FLAT, padx=12, pady=8, cursor="hand2",
            command=lambda a=action: self._go(a),
        ).pack(fill=tk.X)
        tk.Label(
            row, text=tip, font=("Helvetica", 9),
            fg=TEXT_DIM, bg=BG_CARD, anchor="w",
        ).pack(fill=tk.X, padx=4)

    def _go(self, action):
        if action == "open_apps_folder":
            hub = os.path.join(self.env.get("LOCAL_AI_ROOT", ""), "AI Studio Apps")
            if os.path.isdir(hub):
                subprocess.run(["open", hub], check=False)
            else:
                messagebox.showwarning("Not found", f"Apps folder missing:\n{hub}")
            return
        if action == "open_photo_guide":
            guide = os.path.join(self.env.get("LOCAL_AI_ROOT", ""), "docs", "PHOTO_EDITING.txt")
            if os.path.isfile(guide):
                subprocess.run(["open", guide], check=False)
            else:
                messagebox.showwarning("Not found", guide or "LOCAL_AI_ROOT not set")
            return
        if action == "open_ram_guide":
            guide = os.path.join(self.env.get("LOCAL_AI_ROOT", ""), "docs", "RAM_AND_MODELS.txt")
            if os.path.isfile(guide):
                subprocess.run(["open", guide], check=False)
            else:
                messagebox.showwarning("Not found", guide or "LOCAL_AI_ROOT not set")
            return
        run_helper(action)


def main():
    app = StudioLauncher()
    app.mainloop()


if __name__ == "__main__":
    main()