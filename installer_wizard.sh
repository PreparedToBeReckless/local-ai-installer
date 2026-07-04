#!/usr/bin/env bash
# Interactive installer wizard — pure bash, no AppleScript, no Automation permissions
set -euo pipefail

RES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$RES/install-local-ai.sh"
# shellcheck source=lib/size-estimates.sh
source "$RES/lib/size-estimates.sh" 2>/dev/null || true
# shellcheck source=lib/models-catalog.sh
source "$RES/lib/models-catalog.sh" 2>/dev/null || true

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'; MAGENTA=$'\033[0;35m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'

# All UI text goes to stderr so tier=$(pick_tier) doesn't swallow the menu
ui() { echo -e "$@" >&2; }

banner() {
  clear >&2
  ui "${BOLD}${CYAN}"
  ui "  ╔══════════════════════════════════════════════════════════════╗"
  ui "  ║              LOCAL AI STUDIO — TERMINAL INSTALLER              ║"
  ui "  ║        Photoreal AI  •  External SSD  •  M4 optimized        ║"
  ui "  ╚══════════════════════════════════════════════════════════════╝"
  ui "${RESET}"
  ui "${DIM}  Models & apps  →  external SSD (big)"
  ui "  Homebrew, Ollama, Docker  →  Mac internal (~6 GB typical)${RESET}"
  ui ""
}

die() {
  ui "${RED}Error: $*${RESET}"
  ui ""
  read -r -p "Press Enter to close..." _
  exit 1
}

[[ -x "$INSTALLER" ]] || die "install-local-ai.sh not found in $RES"

show_mac_space() {
  local int_free
  int_free=$(df -g / | awk 'NR==2 {print $4}')
  ui "${DIM}  Your Mac internal drive: ${int_free} GB free (installer needs ~6 GB)${RESET}"
  ui ""
}

pick_tier() {
  ui "${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  ui "${BOLD}STEP 1 of 3 — CHOOSE YOUR INSTALL PACKAGE${RESET}"
  ui "${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  ui ""
  show_mac_space

  ui "${BOLD}  1) STARTER${RESET}  ${CYAN}~80 GB on SSD${RESET}  |  ${CYAN}~6 GB on Mac${RESET}"
  ui "     ${DIM}Best for: quick setup, smaller SSD, fast portraits${RESET}"
  ui "     ${GREEN}Includes:${RESET}"
  ui "       • LM Studio, DiffusionBee, ComfyUI + Manager"
  ui "       • Ollama: Flux Klein 4B, Z-Image Turbo, Moondream"
  ui "       • Models: RealVisXL V5, CyberRealistic, Flux Schnell FP8"
  ui "       • 4x UltraSharp upscaler"
  ui ""

  ui "${BOLD}  2) STANDARD${RESET}  ${CYAN}~150 GB on SSD${RESET}  |  ${CYAN}~6 GB on Mac${RESET}  ${GREEN}★ RECOMMENDED (M4 16GB)${RESET}"
  ui "     ${DIM}Best for: your MacBook Air — full editing without bloat${RESET}"
  ui "     ${GREEN}Everything in Starter, plus:${RESET}"
  ui "       • Ollama: Flux Klein 9B, Llama 3.2 Vision"
  ui "       • Juggernaut XL v9, Flux Dev FP8, epiCRealism XL"
  ui "       • IP-Adapter (edit photos from references)"
  ui "       • ControlNet Depth + Canny (structure-guided edits)"
  ui "       • Inpainting nodes (Impact Pack)"
  ui ""

  ui "${BOLD}  3) PRO${RESET}  ${CYAN}~200 GB on SSD${RESET}  |  ${CYAN}~6-8 GB on Mac${RESET}"
  ui "     ${DIM}Best for: serious photo editing & relighting${RESET}"
  ui "     ${GREEN}Everything in Standard, plus:${RESET}"
  ui "       • IC-Light (relight existing photos)"
  ui "       • InstantID (face-consistent edits)"
  ui "       • SD 3.5 Medium, Flux IP-Adapter"
  ui "       • RealVisXL V4, detail LoRA"
  ui ""

  ui "${BOLD}  4) ULTIMATE${RESET}  ${CYAN}~280 GB on SSD${RESET}  |  ${CYAN}~6-8 GB on Mac${RESET}"
  ui "     ${DIM}Best for: max catalog — every curated photoreal model${RESET}"
  ui "     ${GREEN}Everything in Pro, plus:${RESET}"
  ui "       • DreamShaper XL, extra Flux variants, Shakker Union"
  ui "       • IP-Adapter Face, extra IC-Light variants"
  ui "       • Segment Anything 2, LayerStyle compositing"
  ui "       • Gemma 3 12B vision (Ollama)"
  ui "     ${YELLOW}Note: on 16GB RAM, run ONE heavy model at a time.${RESET}"
  ui ""

  local choice
  while true; do
    ui -n "  ${BOLD}Enter 1, 2, 3, or 4${RESET} [default ${GREEN}2 = STANDARD${RESET}]: "
    read -r choice
    choice="${choice:-2}"
    case "$choice" in
      1) ui ""; ui "${GREEN}Selected: STARTER${RESET}"; echo "starter"; return ;;
      2) ui ""; ui "${GREEN}Selected: STANDARD${RESET}"; echo "standard"; return ;;
      3) ui ""; ui "${GREEN}Selected: PRO${RESET}"; echo "pro"; return ;;
      4) ui ""; ui "${GREEN}Selected: ULTIMATE${RESET}"; echo "ultimate"; return ;;
      *) ui "${YELLOW}  Invalid — type 1, 2, 3, or 4.${RESET}" ;;
    esac
  done
}

pick_ssd() {
  local tier="$1"
  local need
  need=$(tier_drive_min_gb "$tier" 2>/dev/null || echo 180)

  ui ""
  ui "${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  ui "${BOLD}STEP 2 of 3 — PICK YOUR EXTERNAL SSD${RESET}"
  ui "${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  ui ""
  ui "  ${DIM}Everything installs to:${RESET}  ${BOLD}YourSSD/LOCAL_AI_GEN/${RESET}"
  ui "  ${DIM}Recommended free space for $(tier_toupper "$tier"):${RESET}  ${BOLD}~${need} GB+${RESET}"
  ui ""

  local -a vols=() paths=() frees=()
  local vol free

  while IFS= read -r vol; do
    case "$vol" in
      Macintosh\ HD|Macintosh\ HD\ *|Preboot|Recovery|Update|VM|Data) continue ;;
    esac
    [[ -d "/Volumes/$vol" ]] || continue
    free=$(df -g "/Volumes/$vol" 2>/dev/null | awk 'NR==2 {print $4}')
    vols+=("$vol")
    paths+=("/Volumes/$vol")
    frees+=("$free")
  done < <(ls /Volumes 2>/dev/null)

  if [[ ${#vols[@]} -eq 0 ]]; then
    ui "${YELLOW}  No external drives detected — plug in your SSD and re-run,${RESET}"
    ui "${YELLOW}  or type the full path manually below.${RESET}"
    ui ""
    ui -n "  Full path (e.g. /Volumes/MySSD): "
    read -r manual
    [[ -d "$manual" ]] || die "Path not found: $manual"
    echo "$manual"
    return
  fi

  ui "${BOLD}  Detected drives:${RESET}"
  local i okmark
  for i in "${!vols[@]}"; do
    if [[ "${frees[$i]}" -ge "$need" ]]; then
      okmark="${GREEN}✓ enough space${RESET}"
    else
      okmark="${YELLOW}⚠ tight for $(tier_toupper "$tier")${RESET}"
    fi
    ui "    ${BOLD}$((i + 1)))${RESET}  ${vols[$i]}  —  ${frees[$i]} GB free  ($okmark)"
  done
  ui ""
  ui "    ${BOLD}B)${RESET}  Type a custom folder path manually"
  ui ""

  local choice
  while true; do
    ui -n "  ${BOLD}Pick drive number (1-${#vols[@]}) or B:${RESET} "
    read -r choice
    if [[ "$(echo "$choice" | tr '[:upper:]' '[:lower:]')" == "b" ]]; then
      ui -n "  Full path: "
      read -r manual
      [[ -d "$manual" ]] || die "Path not found: $manual"
      ui "${GREEN}  Using: $manual${RESET}"
      echo "$manual"
      return
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#vols[@]} )); then
      ui "${GREEN}  Using: ${paths[$((choice - 1))]}${RESET}"
      echo "${paths[$((choice - 1))]}"
      return
    fi
    ui "${YELLOW}  Invalid — enter a number 1-${#vols[@]} or B.${RESET}"
  done
}

confirm() {
  local tier="$1" ssd="$2"
  local ext int need
  ext=$(tier_external_gb "$tier" 2>/dev/null || echo 150)
  int=$(tier_internal_typical_gb "$tier" 2>/dev/null || echo 6)
  need=$(tier_drive_min_gb "$tier" 2>/dev/null || echo 180)

  ui ""
  ui "${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  ui "${BOLD}STEP 3 of 3 — CONFIRM & INSTALL${RESET}"
  ui "${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  ui ""
  ui "  ${BOLD}Package:${RESET}        $(tier_toupper "$tier")"
  ui "  ${BOLD}Install path:${RESET}   $ssd/LOCAL_AI_GEN/"
  ui "  ${BOLD}SSD download:${RESET}   ~${ext} GB  (recommend ${need}+ GB free)"
  ui "  ${BOLD}Mac internal:${RESET}   ~${int} GB  (Homebrew + Ollama + Docker)"
  ui "  ${BOLD}Typical time:${RESET}   ~$(tier_time_estimate "$tier" 2>/dev/null || echo "2–4 hours")  (walk away OK — keep Mac plugged in)"
  ui ""
  ui "${DIM}  Fresh Mac? Command Line Tools auto-prompted. Homebrew + Ollama installed for you.${RESET}"
  ui "${DIM}  Re-run anytime — scans SSD, skips models already downloaded.${RESET}"
  ui "${DIM}  Log: /tmp/local-ai-installer-*.log${RESET}"
  ui ""
  ui "  ${BOLD}After install:${RESET}  Double-click ${GREEN}Launch AI Studio${RESET} on Desktop"
  ui "  ${BOLD}Chat GUI:${RESET}         http://localhost:8080"
  ui "  ${BOLD}ComfyUI:${RESET}          http://localhost:8188"
  ui ""
  if [[ "$tier" == "ultimate" ]]; then
    ui "${YELLOW}  16GB RAM tip: close other apps; one heavy model at a time.${RESET}"
    ui ""
  fi
  ui -n "  ${BOLD}Start install now? [Y/n]:${RESET} "
  read -r ok
  if [[ "$(echo "${ok:-y}" | tr '[:upper:]' '[:lower:]')" == "n" ]]; then
    ui "Cancelled."
    exit 0
  fi
}

ensure_clt() {
  xcode-select -p &>/dev/null && return 0
  ui ""
  ui "${YELLOW}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  ui "${YELLOW}${BOLD}ONE-TIME: Apple Command Line Tools${RESET}"
  ui "${YELLOW}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  ui ""
  ui "  Apple's installer dialog will open."
  ui "  ${BOLD}1)${RESET} Click ${BOLD}Install${RESET} (not Get Xcode)"
  ui "  ${BOLD}2)${RESET} Wait ~5–10 minutes"
  ui "  ${BOLD}3)${RESET} Run this installer again"
  ui ""
  ui "${DIM}  After this, Homebrew + Ollama + models are installed automatically.${RESET}"
  ui ""
  xcode-select --install 2>/dev/null || true
  read -r -p "  Press Enter after Apple's install finishes (or Ctrl+C to quit)… " _
  xcode-select -p &>/dev/null || die "Command Line Tools still missing — run: xcode-select --install"
  ui "${GREEN}✓  Command Line Tools ready — continuing.${RESET}"
}

main() {
  banner
  local tier ssd
  tier=$(pick_tier)
  ssd=$(pick_ssd "$tier")
  confirm "$tier" "$ssd"
  ensure_clt

  ui ""
  ui "${GREEN}${BOLD}Starting install — this takes 1-4 hours depending on tier...${RESET}"
  ui "${DIM}Log file: /tmp/local-ai-installer*.log${RESET}"
  ui ""

  exec bash "$INSTALLER" --tier "$tier" --ssd "$ssd" --no-gui
}

main "$@"