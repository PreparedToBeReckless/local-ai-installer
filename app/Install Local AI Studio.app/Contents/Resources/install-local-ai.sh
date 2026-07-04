#!/usr/bin/env bash
# =============================================================================
#  LOCAL AI STUDIO — Tiered External SSD Installer (M4 MacBook Air 16GB)
#  Photorealistic generation + photo editing. Curated models, no anime bloat.
#
#  Tiers:  starter (~80GB SSD) | standard (~150GB) | pro (~200GB) | ultimate (~280GB)
#  Internal Mac (all tiers): ~6 GB typical, ~2 GB minimum (see lib/size-estimates.sh)
#
#  Usage:
#    ./install-local-ai.sh --tier standard
#    ./install-local-ai.sh --ssd /Volumes/MyDrive --tier pro
#    ./install-local-ai.sh --dry-run --tier ultimate
# =============================================================================

set -euo pipefail

readonly SCRIPT_NAME="Local AI Studio Installer"
readonly ROOT_FOLDER="LOCAL_AI_GEN"
readonly LOG_FILE="/tmp/local-ai-installer-$(date +%Y%m%d-%H%M%S).log"
readonly INSTALL_PID_FILE="/tmp/local-ai-installer.pid"
readonly INSTALL_EXIT_FILE="/tmp/local-ai-installer.exit"
readonly INSTALL_COMPLETE_FILE="/tmp/local-ai-installer.complete"
readonly MIN_FREE_GB=120
readonly MAX_INTERNAL_GB=10

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALL_TIER=""
DRY_RUN=false
SKIP_DOCKER=false
SKIP_COMFY=false
MODELS_ONLY=false
UNFILTERED_PACK=false
UNFILTERED_PACK_ONLY=false
SENSITIVE_MODELS_ONLY=false
NO_GUI=false
AUDIT_ONLY=false
LAUNCHERS_ONLY=false
REFRESH_HF=false
FORCED_SSD=""
EXTERNAL_AI=""
SSD_VOLUME=""
DOWNLOADED_MB=0

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'; MAGENTA=$'\033[0;35m'; CYAN=$'\033[0;36m'
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  RED="" GREEN="" YELLOW="" BLUE="" MAGENTA="" CYAN="" BOLD="" DIM="" RESET=""
fi

log()  { echo -e "${DIM}[$(date '+%H:%M:%S')]${RESET} $*" | tee -a "$LOG_FILE"; }
info() { echo -e "${CYAN}ℹ${RESET}  $*" | tee -a "$LOG_FILE"; }
ok()   { echo -e "${GREEN}✓${RESET}  $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}⚠${RESET}  $*" | tee -a "$LOG_FILE"; }
err()  { echo -e "${RED}✗${RESET}  $*" | tee -a "$LOG_FILE" >&2; }
step() { echo -e "\n${BOLD}${MAGENTA}━━━ $* ━━━${RESET}" | tee -a "$LOG_FILE"; }

banner() {
  echo -e "${BOLD}${BLUE}"
  cat <<'BANNER'
  ╔══════════════════════════════════════════════════════════════╗
  ║   📸 LOCAL AI STUDIO — Photoreal & Photo Edit Edition 📸     ║
  ║   External SSD install • M4 optimized • Tiered model packs   ║
  ║   Hobby installer — upstream links can break without notice    ║
  ╚══════════════════════════════════════════════════════════════╝
BANNER
  echo -e "${RESET}"
}

die() {
  err "$1"
  err "Log: $LOG_FILE"
  osascript -e "display alert \"Installer Error\" message \"$1\" as critical" 2>/dev/null || true
  exit 1
}

# shellcheck source=lib/models-catalog.sh
source "$SCRIPT_DIR/lib/models-catalog.sh" 2>/dev/null \
  || source "$SCRIPT_DIR/../lib/models-catalog.sh" 2>/dev/null \
  || die "Missing lib/models-catalog.sh next to installer"
source "$SCRIPT_DIR/lib/size-estimates.sh" 2>/dev/null \
  || source "$SCRIPT_DIR/../lib/size-estimates.sh" 2>/dev/null || true
# shellcheck source=lib/audit-install.sh
source "$SCRIPT_DIR/lib/audit-install.sh" 2>/dev/null \
  || source "$SCRIPT_DIR/../lib/audit-install.sh" 2>/dev/null || true

# GUI .app launches with PATH=/usr/bin:/bin only — ollama/brew/docker live elsewhere.
setup_install_path() {
  local dir extras=(
    /opt/homebrew/bin
    /opt/homebrew/sbin
    /usr/local/bin
    /usr/local/sbin
    "$HOME/.local/bin"
  )
  local joined=""
  for dir in "${extras[@]}"; do
    [[ -d "$dir" ]] && joined="${joined:+$joined:}$dir"
  done
  [[ -n "$joined" ]] && export PATH="$joined:$PATH"
  if [[ -x /opt/homebrew/bin/brew ]]; then
    # shellcheck disable=SC1091
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    # shellcheck disable=SC1091
    eval "$(/usr/local/bin/brew shellenv)"
  fi
}
setup_install_path

run() {
  log "→ $*"
  [[ "$DRY_RUN" == true ]] && { info "(dry-run) skipped"; return 0; }
  "$@"
}

on_error() {
  err "Failed at line $1 — see $LOG_FILE"
  err "PATH was: $PATH"
  exit 1
}
trap 'on_error $LINENO' ERR

# ── Args ─────────────────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tier)      INSTALL_TIER="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
      --ssd)       FORCED_SSD="$2"; shift 2 ;;
      --minimal)   INSTALL_TIER="starter"; shift ;;  # legacy alias
      --no-docker) SKIP_DOCKER=true; shift ;;
      --no-comfy)  SKIP_COMFY=true; shift ;;
      --models-only) MODELS_ONLY=true; NO_GUI=true; SKIP_COMFY=true; SKIP_DOCKER=true; shift ;;
      --unfiltered-pack) UNFILTERED_PACK=true; shift ;;
      --unfiltered-pack-only) UNFILTERED_PACK=true; UNFILTERED_PACK_ONLY=true; MODELS_ONLY=true; NO_GUI=true; SKIP_COMFY=true; SKIP_DOCKER=true; shift ;;
      --sensitive-models-only) UNFILTERED_PACK=true; SENSITIVE_MODELS_ONLY=true; MODELS_ONLY=true; NO_GUI=true; SKIP_COMFY=true; SKIP_DOCKER=true; shift ;;
      --dry-run)     DRY_RUN=true; shift ;;
      --no-gui)      NO_GUI=true; shift ;;
      --audit-only)  AUDIT_ONLY=true; NO_GUI=true; shift ;;
      --launchers-only) LAUNCHERS_ONLY=true; NO_GUI=true; shift ;;
      --refresh-hf)  REFRESH_HF=true; shift ;;
      -h|--help)
        echo "Tiers (external SSD / Mac internal typical):"
        echo "  starter   ~80 GB SSD   / ~6 GB internal"
        echo "  standard  ~150 GB SSD  / ~6 GB internal  (recommended M4 16GB)"
        echo "  pro       ~200 GB SSD  / ~6-8 GB internal"
        echo "  ultimate  ~280 GB SSD  / ~6-8 GB internal"
        echo ""
        echo "Internal = Homebrew + Ollama + Docker (on Mac, not SSD)"
        echo "Flags: --ssd PATH  --no-gui  --no-docker  --no-comfy  --dry-run"
        echo "       --audit-only (scan SSD vs catalog, no downloads)"
        echo "       --launchers-only (Desktop shortcuts only — no downloads)"
        echo "       --models-only (ComfyUI HF models only — skips ComfyUI/git/pip popups)"
        echo "       --unfiltered-pack (add ~150 GB advanced edit pack after tier models)"
        echo "       --unfiltered-pack-only (pack models only — no apps/ComfyUI setup)"
        echo "       --sensitive-models-only (3 optional HF-sensitive realism weights only)"
        echo "       --refresh-hf (re-download HF models when remote file is larger)"
        exit 0
        ;;
      *) die "Unknown: $1 (try --help)" ;;
    esac
  done
}

# ── GUI ──────────────────────────────────────────────────────────────────────
gui_alert() {
  osascript -e "display alert \"$1\" message \"$2\"" 2>/dev/null || true
}

# Works even if the installer window was closed — for SSD permission popups.
notify_user() {
  local title="$1" msg="$2" sound="${3:-Basso}"
  osascript -e "display notification \"$msg\" with title \"$title\" sound name \"$sound\"" 2>/dev/null || true
}

gui_confirm() {
  osascript -e "display alert \"$1\" message \"$2\" buttons {\"Cancel\", \"Let's Go!\"} default button \"Let's Go!\"" \
    2>/dev/null | grep -q "Let's Go!" || die "Cancelled."
}

pick_install_tier() {
  [[ -n "$INSTALL_TIER" ]] && return
  local est_s est_p est_u
  est_s=$(estimate_tier_download_gb 1)
  est_p=$(estimate_tier_download_gb 3)
  est_u=$(estimate_tier_download_gb 4)

  local choice
  choice=$(osascript <<APPLESCRIPT 2>/dev/null || true
set tierChoice to choose from list ¬
  {"STARTER — ~${est_s} GB models — Fast portraits & core apps", ¬
   "STANDARD — ~230 GB — ⭐ Recommended for M4 16GB", ¬
   "PRO — ~${est_p} GB — Full photo editing (relight, inpaint, faces)", ¬
   "ULTIMATE — ~${est_u} GB — Everything photoreal (700GB drives)"} ¬
  with title "${SCRIPT_NAME}" ¬
  with prompt "Pick your install size (all tiers include GUI apps):" ¬
  default items {"STANDARD — ~230 GB — ⭐ Recommended for M4 16GB"}
if tierChoice is false then return ""
if item 1 of tierChoice contains "STARTER" then return "starter"
if item 1 of tierChoice contains "STANDARD" then return "standard"
if item 1 of tierChoice contains "PRO" then return "pro"
if item 1 of tierChoice contains "ULTIMATE" then return "ultimate"
return ""
APPLESCRIPT
)

  [[ -n "$choice" ]] || die "No tier selected."
  INSTALL_TIER="$choice"

  if [[ "$INSTALL_TIER" == "ultimate" ]]; then
    gui_confirm "ULTIMATE Mode" \
      "This downloads ~${est_u} GB of photoreal models.\n\nYour M4 has 16GB RAM — run ONE heavy model at a time (close other apps).\n\nContinue?"
  fi
}

pick_external_ssd() {
  if [[ -n "$FORCED_SSD" ]]; then
    SSD_VOLUME="$FORCED_SSD"
    [[ -d "$SSD_VOLUME" ]] || die "Volume not found: $SSD_VOLUME"
    ok "SSD: $SSD_VOLUME"
    return
  fi

  step "Pick external SSD"
  local -a candidates=() labels=() vol free_gb

  while IFS= read -r vol; do
    [[ -z "$vol" ]] && continue
    case "$vol" in
      Macintosh\ HD|Macintosh\ HD\ *|Preboot|Recovery|Update|VM|Data) continue ;;
    esac
    [[ -d "/Volumes/$vol" ]] || continue
    free_gb=$(df -g "/Volumes/$vol" 2>/dev/null | awk 'NR==2 {print $4}')
    local need_gb
    need_gb=$(tier_drive_min_gb "$INSTALL_TIER" 2>/dev/null || echo 180)
    if [[ "${UNFILTERED_PACK:-false}" == true ]]; then
      need_gb=$((need_gb + $(unfiltered_pack_drive_min_gb 2>/dev/null || echo 165)))
    fi
    [[ "${free_gb:-0}" -ge "$need_gb" ]] || continue
    candidates+=("/Volumes/$vol")
    labels+=("$vol — ${free_gb} GB free")
  done < <(ls /Volumes 2>/dev/null)

  if [[ ${#candidates[@]} -eq 0 ]]; then
    warn "No volume with enough space for tier $(tier_toupper "$INSTALL_TIER")."
    read -rp "Type SSD path (e.g. /Volumes/MyDrive): " SSD_VOLUME
    [[ -d "$SSD_VOLUME" ]] || die "Invalid path."
    return
  fi

  if [[ ${#candidates[@]} -eq 1 ]]; then
    SSD_VOLUME="${candidates[0]}"
    ok "Auto-selected $SSD_VOLUME"
    return
  fi

  local osa_list="" i
  for i in "${!labels[@]}"; do
    osa_list+="\"${labels[$i]}\""
    [[ $i -lt $((${#labels[@]} - 1)) ]] && osa_list+=", "
  done
  local choice
  choice=$(osascript -e "choose from list {$osa_list} with title \"$SCRIPT_NAME\" with prompt \"Select external SSD:\"" 2>/dev/null || true)
  [[ -n "$choice" && "$choice" != "false" ]] || die "No drive selected."
  for i in "${!labels[@]}"; do
    [[ "${labels[$i]}" == "$choice" ]] && SSD_VOLUME="${candidates[$i]}"
  done
  ok "SSD: $SSD_VOLUME"
}

clt_pause() {
  warn "Xcode Command Line Tools not installed (Apple's dev kit — not Homebrew)"
  info "STEP 1: Apple's installer dialog should open — click Install (not Get Xcode)"
  info "STEP 2: Wait ~5–10 minutes for the download to finish"
  info "STEP 3: Run Local AI Studio installer again — Homebrew and models install automatically"
  xcode-select --install 2>/dev/null || true
  gui_alert "Install Developer Tools" \
    "One-time Apple setup:\n\n1. Click Install in Apple's dialog (not Get Xcode)\n2. Wait ~5–10 minutes\n3. Run this installer again\n\nEverything else (Homebrew, Ollama, models) we install for you."
  err "Paused — install Command Line Tools, then re-run this installer."
  exit 10
}

ensure_dev_tools() {
  step "Mac prerequisites"
  if ! xcode-select -p &>/dev/null; then
    clt_pause
  fi
  ok "Xcode Command Line Tools OK"
  command -v git &>/dev/null || die "git missing — open Terminal, run: xcode-select --install"
  command -v python3 &>/dev/null || die "python3 missing — open Terminal, run: xcode-select --install"
  if command -v brew &>/dev/null; then
    ok "Homebrew already installed"
  else
    info "Homebrew not found — this installer will install it for you (~1 GB, one password prompt)"
  fi
}

preflight() {
  step "Preflight"
  [[ "$(uname)" == "Darwin" && "$(uname -m)" == "arm64" ]] || die "Apple Silicon Mac required."

  local internal_free ram_gb
  internal_free=$(df -g / | awk 'NR==2 {print $4}')
  ram_gb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 17179869184) / 1073741824 ))

  local int_est; int_est=$(tier_internal_typical_gb "$INSTALL_TIER" 2>/dev/null || echo 6)
  ok "Internal free: ${internal_free} GB (this tier uses ~${int_est} GB on Mac if Docker installs)"
  ok "RAM: ${ram_gb} GB"
  [[ "$ram_gb" -le 18 ]] && warn "16GB RAM tip: use STANDARD tier, one model at a time for Flux Dev."

  local tier_lvl budget
  tier_lvl=$(tier_level "$INSTALL_TIER")
  budget=$(tier_budget_gb "$tier_lvl")
  ok "Tier: $(tier_toupper "$INSTALL_TIER") — $(tier_blurb "$tier_lvl") (budget ~${budget} GB)"
  ok "Log: $LOG_FILE"
  local eta; eta=$(tier_time_estimate "$INSTALL_TIER" 2>/dev/null || echo "2–4 hours")
  info "Estimated total time: ${eta} (depends on internet speed)"
  info "Safe to walk away — keep Mac plugged in. Mac sleep is prevented during install."
  info "Closing the installer window is OK — install keeps running in the background."
  info "SSD access: use Allow SSD Access in the GUI installer first — avoids Mac's confusing folder popup."
  if [[ -n "${SSD_VOLUME:-}" ]] && ssd_is_exfat; then
    warn "SSD is ExFAT ($(ssd_filesystem)) — ComfyUI Python env will live on internal Mac (models stay on SSD)."
  fi
}

print_phase_note() {
  info "$1"
}

ssd_mount_point() {
  local path="${1:-$SSD_VOLUME}"
  [[ -n "$path" && -e "$path" ]] || return 0
  df "$path" 2>/dev/null | awk 'NR==2 {print $NF}'
}

ssd_filesystem() {
  local mount=""
  mount=$(ssd_mount_point "$SSD_VOLUME")
  [[ -z "$mount" && -n "${EXTERNAL_AI:-}" ]] && mount=$(ssd_mount_point "$EXTERNAL_AI")
  [[ -z "$mount" ]] && mount="$SSD_VOLUME"
  local fs=""
  fs=$(diskutil info "$mount" 2>/dev/null \
    | awk -F': ' '/File System Personality/ {gsub(/^ +/, "", $2); print $2; exit}')
  [[ -n "$fs" ]] && { echo "$fs"; return; }
  stat -f "%T" "$mount" 2>/dev/null || true
}

ssd_is_exfat() {
  local fs; fs=$(echo "$(ssd_filesystem)" | tr '[:upper:]' '[:lower:]')
  [[ "$fs" == *exfat* || "$fs" == *fat32* || "$fs" == "msdos" ]]
}

comfyui_python() {
  local py candidates=(
    /opt/homebrew/bin/python3.12
    /usr/local/bin/python3.12
    python3.12
    /opt/homebrew/bin/python3.11
    python3.11
  )
  for py in "${candidates[@]}"; do
    command -v "$py" &>/dev/null || continue
    "$py" -c 'import sys; sys.exit(0 if sys.version_info[:2] <= (3, 12) else 1)' 2>/dev/null || continue
    echo "$py"
    return 0
  done
  return 1
}

ensure_comfyui_python() {
  setup_install_path
  local py
  if py=$(comfyui_python); then
    ok "ComfyUI Python: $py ($("$py" --version 2>&1 | head -1))"
    COMFYUI_PYTHON="$py"
    return 0
  fi
  info "Installing Python 3.12 for ComfyUI — PyTorch does not support Python 3.14 yet…"
  run brew install python@3.12
  setup_install_path
  py=$(comfyui_python) || die "python3.12 missing — run: brew install python@3.12"
  ok "ComfyUI Python: $py"
  COMFYUI_PYTHON="$py"
}

comfyui_venv_usable() {
  local v="$1"
  [[ -f "$v/bin/activate" ]] || return 1
  # shellcheck source=/dev/null
  source "$v/bin/activate" 2>/dev/null || return 1
  python -c 'import sys; import site; sys.exit(0 if sys.version_info[:2] <= (3, 12) else 1)' 2>/dev/null
}

comfyui_venv_dir() {
  if ssd_is_exfat; then
    local hash
    hash=$(printf '%s' "$EXTERNAL_AI" | shasum -a 256 | awk '{print substr($1,1,12)}')
    echo "$HOME/Library/Application Support/LocalAIStudio/comfyui-venv-${hash}"
  else
    echo "$EXTERNAL_AI/comfyui/ComfyUI/.venv"
  fi
}

# SQLite (chat history DB) fails on ExFAT — keep Open WebUI data on internal Mac.
open_webui_data_dir() {
  if ssd_is_exfat; then
    local hash
    hash=$(printf '%s' "$EXTERNAL_AI" | shasum -a 256 | awk '{print substr($1,1,12)}')
    echo "$HOME/Library/Application Support/LocalAIStudio/open-webui-data-${hash}"
  else
    echo "$EXTERNAL_AI/open-webui"
  fi
}

_heartbeat() {
  local label="$1" n=0
  while true; do
    sleep 60
    n=$((n + 1))
    info "…still working (${n} min): $label"
  done
}

_with_heartbeat() {
  local label="$1"
  shift
  [[ "$DRY_RUN" == true ]] && { run "$@"; return; }
  _heartbeat "$label" &
  local hb=$!
  run "$@" || { kill "$hb" 2>/dev/null; wait "$hb" 2>/dev/null || true; return 1; }
  kill "$hb" 2>/dev/null
  wait "$hb" 2>/dev/null || true
}

# Noisy commands go to log file only — keeps GUI stdout pipe from clogging/hanging.
run_to_log() {
  log "→ $*"
  [[ "$DRY_RUN" == true ]] && { info "(dry-run) skipped"; return 0; }
  "$@" >>"$LOG_FILE" 2>&1
}

_with_heartbeat_log() {
  local label="$1"
  shift
  [[ "$DRY_RUN" == true ]] && { info "(dry-run) $*"; return 0; }
  _heartbeat "$label" &
  local hb=$!
  run_to_log "$@" || { kill "$hb" 2>/dev/null; wait "$hb" 2>/dev/null || true; return 1; }
  kill "$hb" 2>/dev/null
  wait "$hb" 2>/dev/null || true
}

create_layout() {
  step "Folder structure on SSD"
  EXTERNAL_AI="$SSD_VOLUME/$ROOT_FOLDER"
  if [[ "${LOCAL_AI_LAYOUT_READY:-}" == "1" && -d "$EXTERNAL_AI" ]]; then
    ok "SSD layout already prepared by installer app: $EXTERNAL_AI"
    [[ "$DRY_RUN" != true ]] && echo "$$" > "$EXTERNAL_AI/.install.pid"
    return
  fi
  local dirs=(
    "$EXTERNAL_AI" "$EXTERNAL_AI/Applications" "$EXTERNAL_AI/installers"
    "$EXTERNAL_AI/ollama-models" "$EXTERNAL_AI/open-webui" "$EXTERNAL_AI/lm-studio-models"
    "$EXTERNAL_AI/comfyui" "$EXTERNAL_AI/scripts" "$EXTERNAL_AI/docs" "$EXTERNAL_AI/workflows"
    "$EXTERNAL_AI/comfyui-models/checkpoints" "$EXTERNAL_AI/comfyui-models/loras"
    "$EXTERNAL_AI/comfyui-models/vae" "$EXTERNAL_AI/comfyui-models/controlnet"
    "$EXTERNAL_AI/comfyui-models/upscale_models" "$EXTERNAL_AI/comfyui-models/clip"
    "$EXTERNAL_AI/comfyui-models/unet" "$EXTERNAL_AI/comfyui-models/diffusion_models"
    "$EXTERNAL_AI/comfyui-models/ipadapter" "$EXTERNAL_AI/comfyui-models/clip_vision"
    "$EXTERNAL_AI/comfyui-models/text_encoders" "$EXTERNAL_AI/comfyui-models/insightface"
    "$EXTERNAL_AI/comfyui-models/insightface/models" "$EXTERNAL_AI/comfyui-models/sam2"
    "$EXTERNAL_AI/comfyui-models/onnx"
  )
  for d in "${dirs[@]}"; do run mkdir -p "$d"; done
  ok "Root: $EXTERNAL_AI"
  [[ "$DRY_RUN" != true ]] && echo "$$" > "$EXTERNAL_AI/.install.pid"
}

setup_environment() {
  step "Environment"
  local env_file="$EXTERNAL_AI/scripts/local-ai-env.sh"
  cat > "$env_file" <<ENV
# Local AI Studio — $(date) — Tier: $(tier_toupper "$INSTALL_TIER")
export LOCAL_AI_ROOT="$EXTERNAL_AI"
export LOCAL_AI_TIER="${INSTALL_TIER}"
export OLLAMA_MODELS="$EXTERNAL_AI/ollama-models"
export COMFYUI_ROOT="$EXTERNAL_AI/comfyui/ComfyUI"
export COMFYUI_VENV="$(comfyui_venv_dir)"
export COMFYUI_MODELS="$EXTERNAL_AI/comfyui-models"
export OPEN_WEBUI_DATA="$(open_webui_data_dir)"
export PATH="\$LOCAL_AI_ROOT/scripts:\$PATH"
ENV
  local marker="# >>> local-ai-studio >>>" rc
  for rc in "$HOME/.zprofile" "$HOME/.zshrc"; do
    [[ -f "$rc" ]] || touch "$rc"
    grep -qF "$marker" "$rc" 2>/dev/null && continue
    run bash -c "cat >> '$rc' <<'RC'

$marker
[[ -f \"$env_file\" ]] && source \"$env_file\"
# <<< local-ai-studio <<<
RC"
  done
  # shellcheck source=/dev/null
  source "$env_file"
}

hf_get_token() {
  if [[ -n "${HF_TOKEN:-}" ]]; then
    printf '%s' "$HF_TOKEN"
    return 0
  fi
  if [[ -f "$HOME/.cache/huggingface/token" ]]; then
    tr -d '[:space:]' <"$HOME/.cache/huggingface/token"
    return 0
  fi
  return 1
}

hf_repo_page_from_url() {
  local url="$1"
  sed -E 's#(https://huggingface.co/[^/]+/[^/]+)/.*#\1#'
}

download_file() {
  local url="$1" dest="$2" label="$3"
  local token auth_header=()
  if [[ -f "$dest" && "$REFRESH_HF" != true ]]; then
    ok "Have: $(basename "$dest")"
    return 0
  fi
  if [[ -f "$dest" && "$REFRESH_HF" == true ]]; then
    local local_sz remote_sz
    local_sz=$(audit_local_bytes "$dest")
    remote_sz=$(audit_remote_bytes "$url")
    if [[ -z "$remote_sz" || "$remote_sz" -le "${local_sz:-0}" ]]; then
      ok "Have (up to date): $(basename "$dest")"
      return 0
    fi
    info "Refreshing larger upstream file: $label"
    run rm -f "$dest"
  fi
  info "↓ $label (large files may look quiet — heartbeat every 60s)"
  [[ "$DRY_RUN" == true ]] && { info "(dry-run) $url"; return 0; }
  _heartbeat "$label" &
  local hb=$!
  if token=$(hf_get_token 2>/dev/null) && [[ -n "$token" ]]; then
    auth_header=(-H "Authorization: Bearer $token")
  fi
  local http_code
  http_code=$(curl -sL "${auth_header[@]}" --retry 3 --retry-delay 5 -C - \
    -o "$dest" -w "%{http_code}" "$url" 2>/dev/null || echo "000")
  if [[ "$http_code" =~ ^2 ]]; then
    kill "$hb" 2>/dev/null
    wait "$hb" 2>/dev/null || true
    ok "Saved: $(basename "$dest")"
  else
    kill "$hb" 2>/dev/null
    wait "$hb" 2>/dev/null || true
    rm -f "$dest"
    local page; page=$(hf_repo_page_from_url "$url")
    case "$http_code" in
      401)
        warn "Skipped: $label — missing/invalid HF token (paste Read token in installer or: huggingface-cli login)"
        ;;
      403)
        if [[ "$label" == *"Realism"* || "$label" == *"realism"* || "$label" == *"Into"* ]]; then
          warn "Skipped: $label — enable HuggingFace Content preferences (settings/content-preferences), then re-run fetch-sensitive-models.sh"
        else
          warn "Skipped: $label — log into HuggingFace and click Agree to license: $page"
        fi
        ;;
      404)
        warn "Skipped: $label — file not found on HuggingFace (HTTP 404)"
        ;;
      *)
        if [[ ${#auth_header[@]} -eq 0 ]]; then
          warn "Skipped: $label — gated model needs HF token + license accept (see docs/HUGGINGFACE.txt)"
        else
          warn "Skipped: $label — HuggingFace HTTP $http_code (try license accept: $page)"
        fi
        ;;
    esac
    return 1
  fi
  audit_record_download "hf" "$dest" "$(audit_local_bytes "$dest")" "$url"
}

get_lm_studio_dmg_url() {
  local meta version build
  meta=$(curl -fsSL "https://versions-prod.lmstudio.ai/update/darwin/arm64/0.4.18" 2>/dev/null || true)
  if [[ -z "$meta" ]]; then
    echo "https://installers.lmstudio.ai/darwin/arm64/0.4.18-1/LM-Studio-0.4.18-1-arm64.dmg"
    return
  fi
  version=$(python3 -c "import json,sys; print(json.load(sys.stdin)['version'])" <<<"$meta")
  build=$(python3 -c "import json,sys; print(json.load(sys.stdin)['build'])" <<<"$meta")
  echo "https://installers.lmstudio.ai/darwin/arm64/${version}-${build}/LM-Studio-${version}-${build}-arm64.dmg"
}

install_dmg_app() {
  local dmg="$1" app_name="$2" dest="$3"
  [[ -d "$dest/$app_name.app" ]] && { ok "$app_name on SSD"; return 0; }
  local mount app_path attach_out
  log "→ hdiutil attach $dmg"
  attach_out=$(hdiutil attach "$dmg" -nobrowse 2>&1) \
    || attach_out=$(hdiutil attach "$dmg" -nobrowse 2>&1 || true)
  mount=$(printf '%s\n' "$attach_out" | grep -o '/Volumes/.*' | head -1 || true)
  [[ -n "$mount" && -d "$mount" ]] || die "Could not mount $dmg"
  info "Mounted at $mount"
  app_path=$(find "$mount" -maxdepth 3 -name "*.app" -type d 2>/dev/null | head -1 || true)
  [[ -n "$app_path" ]] || die "No .app in $dmg (mounted at $mount)"
  run cp -R "$app_path" "$dest/"
  run hdiutil detach "$mount" -quiet 2>/dev/null || true
  ok "$app_name → external SSD"
}

install_homebrew() {
  step "Homebrew (~1 GB internal, one-time)"
  setup_install_path
  if command -v brew &>/dev/null; then ok "Homebrew OK"; return; fi
  print_phase_note "Fresh Mac: Homebrew install may ask for your login password once — normal, same as App Store apps."
  local before after
  before=$(df -g / | awk 'NR==2 {print $3}')
  run NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  setup_install_path
  after=$(df -g / | awk 'NR==2 {print $3}')
  warn "Internal used by Homebrew: ~$((after - before)) GB"
}

install_ollama() {
  step "Ollama (binary internal, models on SSD)"
  setup_install_path
  if command -v ollama &>/dev/null; then
    ok "Ollama already installed"
  elif command -v brew &>/dev/null; then
    info "Installing Ollama via Homebrew (CLI only — no app popup, no password for most users)"
    run brew install ollama
  else
    print_phase_note "Ollama fallback installer may ask for your Mac login password once (adds ollama to PATH)."
    print_phase_note "If Ollama.app appears briefly, you can ignore it — the installer continues automatically."
    OLLAMA_NO_START=1 run sh -c 'curl -fsSL https://ollama.com/install.sh | sh'
  fi
  setup_install_path
  command -v ollama &>/dev/null || die "Ollama install finished but 'ollama' not on PATH. Try: export PATH=\"/opt/homebrew/bin:/usr/local/bin:\$PATH\""
  export OLLAMA_MODELS="$EXTERNAL_AI/ollama-models"
  launchctl setenv OLLAMA_MODELS "$OLLAMA_MODELS" 2>/dev/null || true
  if [[ "$DRY_RUN" != true ]]; then
    pgrep -x ollama &>/dev/null || { ollama serve &>/dev/null & disown; sleep 2; }
  fi
}

pull_ollama_models() {
  step "Ollama photoreal models (tier: $(tier_toupper "$INSTALL_TIER"))"
  print_phase_note "Downloading Ollama models — often 30–90 min for this tier. Watch SSD usage grow."
  local entry min_tier model size desc total=0 n=0
  total=$(get_models_for_tier "$INSTALL_TIER" ollama | wc -l | tr -d ' ')
  while IFS= read -r entry; do
    IFS='|' read -r min_tier model size desc <<<"$entry"
    n=$((n + 1))
    if [[ "$DRY_RUN" != true ]] && audit_ollama_has_model "$model"; then
      ok "Already have (${n}/${total}): $model — skipping"
      continue
    fi
    info "Pull (${n}/${total}): $model — $desc (~${size} MB)"
    [[ "$DRY_RUN" == true ]] && continue
    _heartbeat "ollama pull $model" &
    local hb=$!
    # Ollama progress bars can flood stdout — log only.
    if OLLAMA_MODELS="$EXTERNAL_AI/ollama-models" ollama pull "$model" >>"$LOG_FILE" 2>&1; then
      ok "Pulled (${n}/${total}): $model"
    else
      warn "Retry later: ollama pull $model"
    fi
    kill "$hb" 2>/dev/null
    wait "$hb" 2>/dev/null || true
    [[ "$DRY_RUN" != true ]] && sync 2>/dev/null || true
    sleep 2
  done < <(get_models_for_tier "$INSTALL_TIER" ollama)
}

download_hf_models() {
  step "ComfyUI photoreal + editing models"
  print_phase_note "Downloading image models — usually the longest step (1–2+ hours). Almost done after this."
  if hf_get_token &>/dev/null; then
    ok "HuggingFace token found — will try SD 3.5 Medium"
    info "SD 3.5 also needs license accept on huggingface.co (token alone is not enough):"
    info "  https://huggingface.co/stabilityai/stable-diffusion-3.5-medium → Agree to license"
    info "CyberRealistic is public — no license button (downloads without login)"
  else
    info "No HuggingFace token — SD 3.5 Medium will skip (see docs/HUGGINGFACE.txt)"
    info "Need: free account + Agree on SD 3.5 page + Read token in installer"
  fi
  local entry min_tier subdir file path size label dest url
  local count=0 ok_count=0

  while IFS= read -r entry; do
    IFS='|' read -r min_tier subdir file path size label <<<"$entry"
    dest="$EXTERNAL_AI/comfyui-models/$subdir/$file"
    url="https://huggingface.co/$path"
    count=$((count + 1))
    info "Model (${count}): $label"
    download_file "$url" "$dest" "$label" && ok_count=$((ok_count + 1))
  done < <(get_models_for_tier "$INSTALL_TIER" hf)

  ok "Downloaded $ok_count / $count models (failed = gated or offline; use ComfyUI Manager)"
}

postprocess_unfiltered_pack() {
  local zip="$EXTERNAL_AI/comfyui-models/insightface/antelopev2.zip"
  local models_dir="$EXTERNAL_AI/comfyui-models/insightface/models"
  [[ -f "$zip" ]] || return 0
  if [[ -d "$models_dir/antelopev2" ]]; then
    ok "InsightFace antelopev2 already unpacked"
    return 0
  fi
  command -v unzip &>/dev/null || { warn "unzip missing — unpack antelopev2.zip manually into insightface/models/"; return 0; }
  run mkdir -p "$models_dir"
  run unzip -oq "$zip" -d "$models_dir"
  ok "InsightFace antelopev2 unpacked"
}

download_unfiltered_mlx_models() {
  step "LM Studio MLX models (Unfiltered Pack)"
  local entry repo size_mb label dest
  local count=0 ok_count=0

  if ! command -v huggingface-cli &>/dev/null; then
    info "Installing huggingface_hub for MLX snapshots..."
    [[ "$DRY_RUN" == true ]] || pip3 install -q -U "huggingface_hub[cli]" 2>>"$LOG_FILE" || true
  fi

  while IFS= read -r entry; do
    IFS='|' read -r repo size_mb label <<<"$entry"
    dest="$EXTERNAL_AI/lm-studio-models/$repo"
    count=$((count + 1))
    if [[ -f "$dest/config.json" ]]; then
      ok "Already have (${count}): $label"
      ok_count=$((ok_count + 1))
      continue
    fi
    info "MLX (${count}): $label (~${size_mb} MB)"
    [[ "$DRY_RUN" == true ]] && continue
    _heartbeat "huggingface download $repo" &
    local hb=$!
    local dl_ok=false
    if command -v huggingface-cli &>/dev/null; then
      if huggingface-cli download "$repo" --local-dir "$dest" >>"$LOG_FILE" 2>&1; then
        dl_ok=true
      fi
    fi
    if [[ "$dl_ok" != true ]]; then
      if python3 - "$repo" "$dest" <<'PY' >>"$LOG_FILE" 2>&1; then
import sys
from huggingface_hub import snapshot_download
snapshot_download(sys.argv[1], local_dir=sys.argv[2])
PY
        dl_ok=true
      fi
    fi
    kill "$hb" 2>/dev/null
    wait "$hb" 2>/dev/null || true
    if [[ "$dl_ok" == true && -f "$dest/config.json" ]]; then
      ok "Saved MLX (${count}): $label"
      ok_count=$((ok_count + 1))
    else
      warn "MLX download failed: $label — pull in LM Studio Discover tab"
    fi
  done < <(get_unfiltered_pack_mlx_models)

  ok "MLX pack: $ok_count / $count folders"
}

write_sensitive_models_support() {
  [[ -n "${EXTERNAL_AI:-}" && -d "$EXTERNAL_AI" ]] || return 0
  local manifest="$EXTERNAL_AI/.sensitive-models.tsv"
  : > "$manifest"
  local entry subdir file path _ label
  while IFS= read -r entry; do
    IFS='|' read -r subdir file path _ label <<<"$entry"
    printf '%s\t%s\t%s\t%s\n' "$subdir" "$file" "$path" "$label" >> "$manifest"
  done < <(get_unfiltered_pack_sensitive_models)

  cat > "$EXTERNAL_AI/scripts/fetch-sensitive-models.sh" <<'SCRIPT'
#!/usr/bin/env bash
# Retry the 3 optional HuggingFace "sensitive content" photoreal weights.
# Install never blocks on these — run this after HF setup, or re-run INSTALL with pack checked.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/.sensitive-models.tsv"
[[ -f "$MANIFEST" ]] || { echo "No sensitive manifest at $MANIFEST"; exit 0; }

hf_token() {
  [[ -n "${HF_TOKEN:-}" ]] && { printf '%s' "$HF_TOKEN"; return 0; }
  [[ -f "$HOME/.cache/huggingface/token" ]] && tr -d '[:space:]' <"$HOME/.cache/huggingface/token"
}

echo "━━━ HuggingFace — 3 optional photoreal weights ━━━"
echo "WHEN: Run this after install if they skipped, or anytime you add a token later."
echo ""
echo "STEP 1 — Free account:     https://huggingface.co/join"
echo "STEP 2 — Content prefs:    https://huggingface.co/settings/content-preferences"
echo "STEP 3 — Read token:       https://huggingface.co/settings/tokens"
echo "         (export HF_TOKEN=hf_... before this script, or: huggingface-cli login)"
echo ""
echo "Full guide: $ROOT/docs/HUGGINGFACE_SENSITIVE.txt"
echo ""

token=""
token="$(hf_token 2>/dev/null || true)"
auth=()
[[ -n "$token" ]] && auth=(-H "Authorization: Bearer $token")

ok=0 miss=0
while IFS=$'\t' read -r subdir file path label; do
  [[ -n "$subdir" ]] || continue
  dest="$ROOT/comfyui-models/$subdir/$file"
  url="https://huggingface.co/$path"
  if [[ -f "$dest" ]] && [[ "$(stat -f%z "$dest" 2>/dev/null || echo 0)" -gt 50000000 ]]; then
    echo "✓ Already have: $label"
    ok=$((ok + 1))
    continue
  fi
  echo "↓ $label"
  code=$(curl -sL "${auth[@]}" --retry 3 -C - -o "$dest" -w "%{http_code}" "$url" || echo "000")
  if [[ "$code" =~ ^2 ]]; then
    echo "✓ Saved: $(basename "$dest")"
    ok=$((ok + 1))
  else
    rm -f "$dest"
    echo "⚠ Skipped ($code): $label"
    miss=$((miss + 1))
  fi
done < "$MANIFEST"

echo ""
echo "Done: $ok saved, $miss still missing."
[[ "$miss" -gt 0 ]] && echo "Fix HF sensitive content + token, then run this script again."
SCRIPT
  chmod +x "$EXTERNAL_AI/scripts/fetch-sensitive-models.sh"
}

hf_sensitive_setup_reminder() {
  [[ "${UNFILTERED_PACK:-false}" != true ]] && return 0
  hf_get_token &>/dev/null && return 0
  warn "No HuggingFace token — 3 optional realism weights will likely skip (install continues)"
  info "WHEN (before install): free account → content preferences → sensitive content ON → Read token"
  info "WHEN (after install): $EXTERNAL_AI/scripts/fetch-sensitive-models.sh"
  info "Full walkthrough: $EXTERNAL_AI/docs/HUGGINGFACE_SENSITIVE.txt (GUI: Setup guide button)"
  if [[ "$NO_GUI" == true ]] && [[ "$DRY_RUN" != true ]]; then
    osascript -e 'display alert "Optional HuggingFace setup" message "3 realism weights need a free HuggingFace account + Sensitive Content ON + Read token.\n\nInstall continues without them.\n\nSee LOCAL_AI_GEN/docs/HUGGINGFACE_SENSITIVE.txt on your SSD after install — or run fetch-sensitive-models.sh later."' 2>/dev/null || true
  fi
}

download_sensitive_pack_models() {
  step "Sensitive realism weights (optional — install continues if these skip)"
  print_phase_note "3 photoreal UNet weights — last in the pack queue, never blocks completion."
  write_sensitive_models_support
  hf_sensitive_setup_reminder
  info "HF setup (one-time, free account):"
  info "  1. huggingface.co/join — free account"
  info "  2. huggingface.co/settings/content-preferences → enable sensitive content"
  info "  3. huggingface.co/settings/tokens → New (Read) → paste in installer HF box"
  info "  4. Or after install: $EXTERNAL_AI/scripts/fetch-sensitive-models.sh"

  local entry subdir file path _ label dest url
  local count=0 ok_count=0 skipped=0
  set +e
  while IFS= read -r entry; do
    IFS='|' read -r subdir file path _ label <<<"$entry"
    dest="$EXTERNAL_AI/comfyui-models/$subdir/$file"
    url="https://huggingface.co/$path"
    count=$((count + 1))
    info "Sensitive (${count}/3): $label"
    if download_file "$url" "$dest" "$label"; then
      ok_count=$((ok_count + 1))
    else
      skipped=$((skipped + 1))
    fi
  done < <(get_unfiltered_pack_sensitive_models)
  set -e

  if [[ "$skipped" -gt 0 ]]; then
    warn "Sensitive: ${ok_count}/3 downloaded — ${skipped} skipped (studio still fully usable)"
    info "Retry later: $EXTERNAL_AI/scripts/fetch-sensitive-models.sh"
  else
    ok "Sensitive realism: all 3 downloaded"
  fi
}

download_unfiltered_pack() {
  step "Unfiltered Models Pack (~$(unfiltered_pack_gb 2>/dev/null || echo 150) GB)"
  print_phase_note "Advanced photo editing pack — Qwen Image Edit, Flux Fill/Kontext, faces, poses, MLX vision."
  write_sensitive_models_support
  local entry subdir file path size label dest url
  local count=0 ok_count=0

  while IFS= read -r entry; do
    IFS='|' read -r subdir file path size label <<<"$entry"
    dest="$EXTERNAL_AI/comfyui-models/$subdir/$file"
    url="https://huggingface.co/$path"
    count=$((count + 1))
    info "Pack (${count}): $label"
    download_file "$url" "$dest" "$label" && ok_count=$((ok_count + 1)) || true
  done < <(get_unfiltered_pack_models)

  postprocess_unfiltered_pack
  download_unfiltered_mlx_models
  download_sensitive_pack_models
  ok "Pack core: $ok_count / $count HF files (MLX + sensitive counted separately)"
  mark_comfyui_restart_needed
}

mark_comfyui_restart_needed() {
  local flag="${EXTERNAL_AI:-}/comfyui/ComfyUI/.restart-after-install"
  [[ -n "${EXTERNAL_AI:-}" && -d "$EXTERNAL_AI/comfyui/ComfyUI" ]] || return 0
  date -u '+%Y-%m-%dT%H:%M:%SZ' >"$flag"
}

install_gui_apps() {
  step "GUI apps → external SSD"
  if [[ -d "$EXTERNAL_AI/Applications/LM Studio.app" ]]; then
    ok "LM Studio already on SSD — skipping download"
  else
    local lm_dmg="$EXTERNAL_AI/installers/LM-Studio.dmg"
    download_file "$(get_lm_studio_dmg_url)" "$lm_dmg" "LM Studio"
    install_dmg_app "$lm_dmg" "LM Studio" "$EXTERNAL_AI/Applications"
  fi

  if [[ -d "$EXTERNAL_AI/Applications/DiffusionBee.app" ]]; then
    ok "DiffusionBee already on SSD — skipping download"
  else
    local db_dmg="$EXTERNAL_AI/installers/DiffusionBee.dmg"
    download_file "https://github.com/divamgupta/diffusionbee-stable-diffusion-ui/releases/download/2.5.3/DiffusionBee_MPS_arm64-2.5.3.dmg" \
      "$db_dmg" "DiffusionBee"
    install_dmg_app "$db_dmg" "DiffusionBee" "$EXTERNAL_AI/Applications"
  fi

  run bash -c "cat > \"$EXTERNAL_AI/docs/DRAW_THINGS.txt\" <<DOC
Draw Things (Mac App Store) — native photo editor
Set model folder to: $EXTERNAL_AI/comfyui-models
Grab: Juggernaut XL, RealVisXL, Flux inside the app.
DOC"
  info "Draw Things (optional): see docs/DRAW_THINGS.txt — open from AI Studio Launcher after install."
  install_ai_studio_web_app
}

install_ai_studio_web_app() {
  local src="$SCRIPT_DIR/assets/AI-Studio-Web.app"
  local dest="$EXTERNAL_AI/Applications/AI Studio Web.app"
  [[ -d "$src" ]] || { warn "AI Studio Web.app missing from installer — browser shortcuts will use Safari fallback"; return 0; }
  run rm -rf "$dest"
  run cp -R "$src" "$dest"
  chmod +x "$dest/Contents/MacOS/ai-studio-web"
  ok "AI Studio Web (built-in localhost viewer) → Applications/"
}

install_open_webui() {
  [[ "$SKIP_DOCKER" == true ]] && { warn "Skipping Open WebUI"; return; }
  step "Open WebUI (browser chat)"

  local internal_free; internal_free=$(df -g / | awk 'NR==2 {print $4}')
  if [[ "${internal_free:-0}" -lt 8 ]]; then
    warn "Low internal space — skipping Docker (saves ~4 GB). Use LM Studio for chat."
    SKIP_DOCKER=true
    return
  fi

  setup_install_path
  command -v brew &>/dev/null || die "Need Homebrew"
  if ! command -v docker &>/dev/null; then
    info "Docker Desktop (~4 GB internal)..."
    run brew install --cask docker
    gui_alert "Open Docker Desktop" "Launch Docker, wait for the whale, then the installer continues."
    open -a Docker 2>/dev/null || true
    for _ in {1..24}; do docker info &>/dev/null && break; sleep 5; done
  fi
  docker info &>/dev/null || { warn "Docker not running — skip Open WebUI"; return; }

  local webui_data; webui_data=$(open_webui_data_dir)
  run mkdir -p "$webui_data"
  if ssd_is_exfat; then
    info "Open WebUI chat DB → internal Mac (ExFAT SSD breaks SQLite)"
  fi
  if docker ps -a --format '{{.Names}}' | grep -qx open-webui; then
    run docker rm -f open-webui 2>/dev/null || true
  fi
  run docker run -d -p 8080:8080 --add-host=host.docker.internal:host-gateway \
    -v "$webui_data:/app/backend/data" \
    -e OLLAMA_BASE_URL="http://host.docker.internal:11434" \
    --name open-webui --restart unless-stopped ghcr.io/open-webui/open-webui:main
  ok "Open WebUI → http://localhost:8080"
}

setup_comfyui_models() {
  local root="$1"
  local models_cfg="$root/extra_model_paths.yaml"
  if ssd_is_exfat; then
    # Rewrite when missing or stale (older installs lacked text_encoders / pack folders)
    if [[ -f "$models_cfg" ]] \
      && grep -q 'text_encoders:' "$models_cfg" 2>/dev/null \
      && grep -q 'insightface:' "$models_cfg" 2>/dev/null \
      && grep -q 'sam2:' "$models_cfg" 2>/dev/null; then
      return 0
    fi
    cat > "$models_cfg" <<YAML
ssd_models:
  base_path: $EXTERNAL_AI/comfyui-models
  checkpoints: checkpoints
  loras: loras
  vae: vae
  controlnet: controlnet
  upscale_models: upscale_models
  clip: clip
  unet: unet
  diffusion_models: diffusion_models
  ipadapter: ipadapter
  clip_vision: clip_vision
  text_encoders: text_encoders
  insightface: insightface
  sam2: sam2
YAML
    ok "ComfyUI models → extra_model_paths.yaml (ExFAT — no symlink)"
    mark_comfyui_restart_needed
    return 0
  fi
  [[ -L "$root/models" ]] && return 0
  run ln -sfn "$EXTERNAL_AI/comfyui-models" "$root/models"
}

comfyui_setup_complete() {
  local root="$EXTERNAL_AI/comfyui/ComfyUI"
  [[ -d "$root/.git" ]] || return 1
  local venv; venv=$(comfyui_venv_dir)
  comfyui_venv_usable "$venv" || return 1
  if ssd_is_exfat; then
    [[ -f "$root/extra_model_paths.yaml" ]] || return 1
  else
    [[ -L "$root/models" || -d "$root/models" ]] || return 1
  fi
  return 0
}

sync_comfyui_tier_nodes() {
  local root="$EXTERNAL_AI/comfyui/ComfyUI"
  local venv nodes="$root/custom_nodes" entry min_tier url folder purpose added=0
  venv=$(comfyui_venv_dir)
  [[ -d "$root/.git" ]] || return 0
  comfyui_venv_usable "$venv" || return 0
  run mkdir -p "$nodes"
  while IFS= read -r entry; do
    IFS='|' read -r min_tier url folder purpose <<<"$entry"
    [[ -d "$nodes/$folder" ]] && continue
    info "Installing missing node for $(tier_toupper "$INSTALL_TIER"): $folder ($purpose)"
    run git clone --depth 1 "$url" "$nodes/$folder" 2>/dev/null || warn "Node $folder failed"
    if [[ -f "$nodes/$folder/requirements.txt" ]] && comfyui_venv_usable "$venv"; then
      # shellcheck source=/dev/null
      source "$venv/bin/activate"
      run pip install -q -r "$nodes/$folder/requirements.txt" 2>/dev/null || true
    fi
    added=$((added + 1))
  done < <(get_models_for_tier "$INSTALL_TIER" nodes)
  [[ "$added" -gt 0 ]] && ok "Added $added ComfyUI node(s) for $(tier_toupper "$INSTALL_TIER")"
  return 0
}

install_comfyui() {
  [[ "$SKIP_COMFY" == true ]] && return
  local root="$EXTERNAL_AI/comfyui/ComfyUI"
  local venv; venv=$(comfyui_venv_dir)
  # ExFAT ships with an empty models/ folder — yaml may be missing even after a full install.
  if [[ -d "$root/.git" ]] && comfyui_venv_usable "$venv"; then
    setup_comfyui_models "$root"
  fi
  if comfyui_setup_complete; then
    sync_comfyui_tier_nodes
    ok "ComfyUI already set up — verified + synced tier nodes (skipped git/pip)"
    return
  fi
  step "ComfyUI + editing nodes (tier: $(tier_toupper "$INSTALL_TIER"))"
  print_phase_note "Installing ComfyUI + Python packages — typically 20–40 min (PyTorch is large)."
  info "First ComfyUI setup touches your SSD — use Stop Popups → Full Disk Access if Mac asks repeatedly."
  ensure_comfyui_python

  local root venv ext_venv
  root="$EXTERNAL_AI/comfyui/ComfyUI"
  ext_venv="$root/.venv"
  venv=$(comfyui_venv_dir)
  info "ComfyUI venv path: $venv"
  if [[ "$venv" != "$ext_venv" && -e "$ext_venv" ]]; then
    warn "Removing ComfyUI venv on external SSD (Python env belongs on internal Mac for ExFAT)"
    run rm -rf "$ext_venv"
  fi
  if [[ ! -d "$root/.git" ]]; then
    info "Cloning ComfyUI (output in log file)…"
    _with_heartbeat_log "git clone ComfyUI" \
      git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$root"
  fi
  if ssd_is_exfat; then
    run mkdir -p "$(dirname "$venv")"
    info "Python venv on internal Mac: $venv"
  fi
  if [[ -d "$venv" ]] && ! comfyui_venv_usable "$venv"; then
    warn "Removing broken ComfyUI venv at $venv"
    run rm -rf "$venv"
  fi
  [[ -d "$venv" ]] || run "$COMFYUI_PYTHON" -m venv "$venv"
  comfyui_venv_usable "$venv" || die "ComfyUI Python env failed at $venv — see $LOG_FILE"
  # shellcheck source=/dev/null
  source "$venv/bin/activate"
  _with_heartbeat_log "pip upgrade" pip install -q --upgrade pip wheel
  _with_heartbeat_log "pip install PyTorch (large)" pip install -q torch torchvision torchaudio
  _with_heartbeat_log "pip install ComfyUI requirements" pip install -q -r "$root/requirements.txt"

  local nodes="$root/custom_nodes" entry min_tier url folder purpose
  run mkdir -p "$nodes"
  while IFS= read -r entry; do
    IFS='|' read -r min_tier url folder purpose <<<"$entry"
    [[ -d "$nodes/$folder" ]] && continue
    info "Node: $folder ($purpose)"
    run git clone --depth 1 "$url" "$nodes/$folder" 2>/dev/null || warn "Node $folder failed"
    [[ -f "$nodes/$folder/requirements.txt" ]] && \
      run pip install -q -r "$nodes/$folder/requirements.txt" 2>/dev/null || true
  done < <(get_models_for_tier "$INSTALL_TIER" nodes)

  setup_comfyui_models "$root"
  ok "ComfyUI ready"
}

write_docs() {
  step "Writing guides"
  local tier_lvl; tier_lvl=$(tier_level "$INSTALL_TIER")

  cat > "$EXTERNAL_AI/docs/PHOTO_EDITING.txt" <<DOC
PHOTO EDITING QUICK START (tier: $(tier_toupper "$INSTALL_TIER"))
═══════════════════════════════════════════════════

🖼️  EDIT EXISTING PHOTOS — use ComfyUI (http://127.0.0.1:8188)

1. INPAINT (remove/replace objects)
   ComfyUI-Impact-Pack → load RealVisXL or Juggernaut checkpoint
   Mask area → inpaint with prompt

2. RELIGHT (change lighting on a photo)
   IC-Light nodes → load iclight_sd15_fc.safetensors
   Upload photo → new lighting prompt

3. STYLE FROM REFERENCE (make photo look like another)
   IP-Adapter Plus → upload reference + your photo

4. FACE CONSISTENT EDITS (pro+)
   InstantID node → keep same face, change scene/clothes

5. UPSCALE (sharper final image)
   4x-UltraSharp or Real-ESRGAN nodes

6. FLUX EDITS (standard+)
   flux1-dev-fp8 + Flux IP-Adapter for reference-driven realism

🐝 DiffusionBee — easiest for quick realistic generations
📱 Draw Things — best native inpaint/outpaint (App Store)
DOC

  cat > "$EXTERNAL_AI/docs/HUGGINGFACE.txt" <<'DOC'
HUGGINGFACE — SD 3.5 Medium (1 optional gated model)
════════════════════════════════════════════════════

CyberRealistic V7 is PUBLIC on HuggingFace — no license button, no login needed.
Only SD 3.5 Medium needs BOTH a website license click AND a Read token.
A token alone is NOT enough for SD 3.5 (HuggingFace returns HTTP 403).

STEP 1 — Accept license (required; use browser while logged in)
  https://huggingface.co/stabilityai/stable-diffusion-3.5-medium
    → click "Agree and access repository"

STEP 2 — Access token
  https://huggingface.co/settings/tokens → New token (Read)
  Re-run installer → paste token in HuggingFace box → INSTALL

Or Terminal (saves token; browser license accept still required):
  pip3 install -U huggingface_hub
  huggingface-cli login

Re-run INSTALL after both steps — only missing files download.

Your studio works without SD 3.5 — 25/26 ComfyUI models are already installed.
DOC

  cat > "$EXTERNAL_AI/docs/WHICH_APP.txt" <<'DOC'
WHICH APP DO I USE?
═══════════════════

Confused by Ollama's browse list (Codex, Copilot CLI, Hermes, coding agents)?
Those are CHAT / CODING tools — not the same as our image-generation stack.

── MAKE PHOTOREAL IMAGES (this is what the ~140 GB install is for) ──

  ComfyUI (AI Studio Web → http://127.0.0.1:8188)
    Pro generation + editing: Flux, SDXL, inpaint, relight, upscale.
    Uses models in comfyui-models/ on your SSD.

  DiffusionBee (app → Applications/DiffusionBee.app on SSD)
    Easiest one-click realistic generations. Great to start here.

  Draw Things (optional, Mac App Store — not installed by us)
    Native inpaint/outpaint. See docs/DRAW_THINGS.txt.

── CHAT / DESCRIBE PHOTOS / PROMPT HELP (small downloads) ──

  Ollama
    Text chat + a few vision helpers. Our installer pulls 8 models
    (moondream, llava, llama3.2-vision, gemma3, etc.) — NOT the whole
    Ollama library. Browse list in the Ollama app is mostly coding LLMs.

  LM Studio (app → Applications/LM Studio.app on SSD)
    Extra chat/vision models — download inside the app's Discover tab.

  Open WebUI (browser → http://localhost:8080, needs Docker)
    Chat UI for Ollama models.

── QUICK PICK ──

  "I want a realistic photo fast"     → DiffusionBee or ComfyUI
  "I want to edit an existing photo"  → ComfyUI
  "What's in this image?" / prompts   → Ollama or LM Studio
  "I want to write code"              → Ollama/LM Studio (not our focus)

Desktop → AI Studio Launcher.app opens everything from one window.
DOC

  cat > "$EXTERNAL_AI/docs/LM_STUDIO.txt" <<DOC
LM Studio — external models: $EXTERNAL_AI/lm-studio-models
Settings → Model Storage → point here.

Recommended for photo work (download in-app Discover):
  • Qwen2.5-VL-7B — describe photos, write edit prompts
  • Gemma 3 12B — vision reasoning
  • mlx-community/* — fastest on M4
DOC

  cat > "$EXTERNAL_AI/docs/MODELS_INSTALLED.txt" <<DOC
Installed tier: $(tier_toupper "$INSTALL_TIER") (~$(tier_budget_gb "$tier_lvl") GB budget)

OLLAMA ($(get_models_for_tier "$INSTALL_TIER" ollama | wc -l | tr -d ' ') models):
$(get_models_for_tier "$INSTALL_TIER" ollama | while IFS='|' read -r _ m _ d; do echo "  • $m — $d"; done)

COMFYUI CHECKPOINTS & TOOLS:
$(get_models_for_tier "$INSTALL_TIER" hf | while IFS='|' read -r _ _ _ _ _ l; do echo "  • $l"; done)

Add more via ComfyUI Manager → filter "realistic" / "photo" on Civitai.
DOC

  if [[ "${UNFILTERED_PACK:-false}" == true ]]; then
    cat > "$EXTERNAL_AI/docs/UNFILTERED_PACK.txt" <<DOC
UNFILTERED MODELS PACK (~$(unfiltered_pack_gb 2>/dev/null || echo 150) GB add-on)
═══════════════════════════════════════════════════════════════

Installed with this run. Best on M4 16GB — run ONE heavy model at a time.

QWEN IMAGE EDIT (ComfyUI → diffusion_models + text_encoders + vae + loras)
  • qwen_image_edit_2509_fp8 + 2511_fp8mixed — mask-free photo edits
  • Lightning 4-step LoRA for faster edits
  • Relight, Anything2Real, Fusion, angles, white-to-scene LoRAs
  • qwen_image_fp8 — generation companion model

FLUX ADVANCED EDITING
  • flux1-dev-kontext_fp8_scaled — context-aware edits
  • FLUX.1-Fill-dev_fp8 — inpaint/outpaint regions
  • clip_l + t5xxl_fp8 text encoders (required for Fill/Kontext)
  • Flux IP-Adapter v2

FACE / POSE / MASK
  • InstantID ControlNet + ip-adapter + antelopev2 (insightface/)
  • SAM2 hiera large (sam2/) — AI masking
  • OpenPose XL2 + DWPose ONNX — pose-guided edits

MLX VISION (LM Studio → $EXTERNAL_AI/lm-studio-models)
  • Qwen2.5-VL, Gemma 3 12B, Llama 3.2 Vision — describe photos, write edit prompts

SENSITIVE / NSFW WEIGHTS (3 optional photoreal UNet shards — install never blocks on these)
  • spicy-realism-v30-unet, into-realism-v30-unet, intorealism-v21-unet
  • Saved to: comfyui-models/diffusion_models/
  • Pair with your SDXL checkpoints (RealVisXL, CyberRealistic, etc.) in ComfyUI

ONE-TIME HUGGINGFACE SETUP (free account, no API billing):
  1. huggingface.co/settings/content-preferences → enable sensitive content
  2. Settings → Access Tokens → New token (Read only)
  3. Paste token in installer HuggingFace box BEFORE install, OR after install run:
       $EXTERNAL_AI/scripts/fetch-sensitive-models.sh

If they skip during install, everything else still works. Re-run the script anytime.
DOC
    cat > "$EXTERNAL_AI/docs/HUGGINGFACE_SENSITIVE.txt" <<'DOC'
HUGGINGFACE — 3 OPTIONAL REALISM WEIGHTS (Unfiltered Pack)
═══════════════════════════════════════════════════════════

These are optional. Your studio works without them. Install never blocks on them.

WHAT THEY ARE
  • spicy-realism-v30-unet.safetensors
  • into-realism-v30-unet.safetensors
  • intorealism-v21-unet.safetensors
  Saved to: comfyui-models/diffusion_models/

WHEN TO DO THIS
  • BEFORE INSTALL — paste HF Read token in installer → best first-pass download
  • AFTER INSTALL — run scripts/fetch-sensitive-models.sh on your SSD

SETUP (manual browser steps, ~2 minutes, free account)
  1. Sign up:  https://huggingface.co/join
  2. Log in → Settings → Content preferences → enable sensitive content
  3. Settings → Access Tokens → New token → Read only → copy (starts with hf_)
  4. Paste token in installer GUI (orange HuggingFace box) OR in Terminal:
       export HF_TOKEN=hf_your_token_here
       bash LOCAL_AI_GEN/scripts/fetch-sensitive-models.sh

GUI INSTALLER
  • Check "Unfiltered Models Pack"
  • Click "HF setup guide (3 models)" or "Setup guide" — step-by-step assistant
  • Opens each page for you; you complete the clicks in the browser

NO API KEY. No billing. Read token is not an OpenAI-style API key.

TROUBLESHOOTING
  • HTTP 401 — add Read token (step 3)
  • HTTP 403 — enable sensitive content in Content preferences (step 2) while logged in
  • Re-run fetch script anytime — skips files you already have
DOC
    ok "Wrote docs/HUGGINGFACE_SENSITIVE.txt"
    ok "Wrote docs/UNFILTERED_PACK.txt"
  fi
}

write_launch_helpers() {
  cat > "$EXTERNAL_AI/scripts/launch-helpers.sh" <<'HELPERS'
#!/usr/bin/env bash
# Shared launch actions — sourced after local-ai-env.sh

ensure_ollama() {
  pgrep -x ollama &>/dev/null && return 0
  OLLAMA_MODELS="${LOCAL_AI_ROOT}/ollama-models" ollama serve &>/dev/null &
  sleep 2
}

open_lm_studio() {
  ensure_ollama
  open "${LOCAL_AI_ROOT}/Applications/LM Studio.app" 2>/dev/null || true
}

open_diffusionbee() {
  open "${LOCAL_AI_ROOT}/Applications/DiffusionBee.app" 2>/dev/null || true
}

# Opens localhost UIs in AI Studio Web (native WKWebView) — not the default browser.
open_local_url() {
  local url="${1:?URL required}"
  local app="${LOCAL_AI_ROOT}/Applications/AI Studio Web.app"
  if [[ -d "$app" ]]; then
    open -na "$app" --args "$url"
    return 0
  fi
  warn "AI Studio Web.app missing — falling back to Safari for $url"
  open -na "Safari" "$url"
}

comfyui_alert() {
  osascript -e "display alert \"ComfyUI\" message \"$1\"" 2>/dev/null || true
}

stop_comfyui() {
  local pid
  pid=$(lsof -ti :8188 2>/dev/null | head -1)
  [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  local i
  for i in $(seq 1 20); do
    curl -s -o /dev/null http://127.0.0.1:8188/ 2>/dev/null || return 0
    sleep 1
  done
  pid=$(lsof -ti :8188 2>/dev/null | head -1)
  [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
}

start_comfyui() {
  [[ -d "${COMFYUI_ROOT:-}" && -f "${COMFYUI_VENV:-}/bin/activate" ]] || return 0
  cd "$COMFYUI_ROOT"
  # shellcheck source=/dev/null
  source "$COMFYUI_VENV/bin/activate"
  local restart_flag="$COMFYUI_ROOT/.restart-after-install"
  if [[ -f "$restart_flag" ]]; then
    if lsof -ti :8188 &>/dev/null; then
      osascript -e 'display notification "Restarting ComfyUI to load new models…" with title "ComfyUI"' 2>/dev/null || true
      stop_comfyui
    fi
    rm -f "$restart_flag"
  fi
  if ! lsof -ti :8188 &>/dev/null; then
    osascript -e 'display notification "First launch can take 1–3 minutes…" with title "Starting ComfyUI"' 2>/dev/null || true
    python main.py --listen 127.0.0.1 --port 8188 &>/dev/null &
  fi
  local i code
  for i in $(seq 1 90); do
    code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8188/ 2>/dev/null || echo "000")
    [[ "$code" == "200" ]] && { open_local_url "http://127.0.0.1:8188"; return 0; }
    sleep 2
  done
  comfyui_alert "ComfyUI is still starting (custom nodes on ExFAT can take a few minutes). Wait, then open http://127.0.0.1:8188 or click the shortcut again."
}

webui_alert() {
  osascript -e "display alert \"Open WebUI\" message \"$1\"" 2>/dev/null || true
}

start_open_webui() {
  ensure_ollama
  if ! command -v docker &>/dev/null; then
    webui_alert "Docker is not installed. Open WebUI needs Docker Desktop (~4 GB on Mac internal). Use LM Studio for chat, or re-run the installer."
    return 0
  fi
  if ! docker info &>/dev/null; then
    open -a Docker 2>/dev/null || true
    osascript -e 'display notification "Starting Docker Desktop…" with title "Open WebUI"' 2>/dev/null || true
    for _ in {1..30}; do docker info &>/dev/null && break; sleep 2; done
  fi
  if ! docker info &>/dev/null; then
    webui_alert "Could not connect to Docker. Open Docker Desktop from Applications, wait until the whale icon shows Running in the menu bar, then try again."
    return 0
  fi
  local webui_data="${OPEN_WEBUI_DATA:-${LOCAL_AI_ROOT}/open-webui}"
  mkdir -p "$webui_data" 2>/dev/null || true
  if ! docker ps -a --format '{{.Names}}' | grep -qx open-webui; then
    docker run -d -p 8080:8080 --add-host=host.docker.internal:host-gateway \
      -v "${webui_data}:/app/backend/data" \
      -e OLLAMA_BASE_URL="http://host.docker.internal:11434" \
      --name open-webui --restart unless-stopped ghcr.io/open-webui/open-webui:main \
      || { webui_alert "Failed to start Open WebUI container. Check Docker Desktop is running and try again."; return 0; }
  else
    docker start open-webui &>/dev/null || true
  fi
  sleep 3
  open_local_url "http://127.0.0.1:8080"
}

open_draw_things() {
  open "macappstore://apps.apple.com/app/draw-things-ai-generation/id6444413020" 2>/dev/null || true
}

open_apps_folder() {
  open "${LOCAL_AI_ROOT}/AI Studio Apps" 2>/dev/null || true
}

launch_all() {
  ensure_ollama
  start_open_webui
  open_lm_studio
  open_diffusionbee
  start_comfyui
}
HELPERS
  chmod +x "$EXTERNAL_AI/scripts/launch-helpers.sh"
}

# Desktop paths can be files, folders, or broken symlinks (iCloud) — clear before writing.
clear_desktop_path() {
  local p="$1"
  [[ -e "$p" || -L "$p" ]] || return 0
  log "→ clear Desktop path: $p"
  rm -rf "$p" 2>/dev/null || true
}

ensure_desktop_writable() {
  local free_mb
  free_mb=$(df -m "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')
  free_mb=${free_mb:-0}
  if [[ "$free_mb" -lt 200 ]]; then
    warn "Low internal disk space (~${free_mb} MB free) — Desktop shortcuts may fail."
    warn "Free space on your Mac internal drive, then re-run with --launchers-only."
  fi
  mkdir -p "$HOME/Desktop" 2>/dev/null || true
}

write_hub_command() {
  local dest="$1" action="$2"
  cat > "$dest" <<CMD
#!/usr/bin/env bash
set -euo pipefail
SCRIPTS="${EXTERNAL_AI}/scripts"
source "\$SCRIPTS/local-ai-env.sh"
source "\$SCRIPTS/launch-helpers.sh"
${action}
CMD
  chmod +x "$dest"
}

create_studio_hub() {
  local hub="$EXTERNAL_AI/AI Studio Apps"
  run mkdir -p "$hub"
  rm -f "$hub/ComfyUI (browser).command" "$hub/Open WebUI (browser).command" 2>/dev/null || true

  write_hub_command "$hub/Launch All.command" "launch_all"
  write_hub_command "$hub/LM Studio.command" "open_lm_studio"
  write_hub_command "$hub/DiffusionBee.command" "open_diffusionbee"
  write_hub_command "$hub/ComfyUI (light browser).command" "start_comfyui"
  write_hub_command "$hub/Open WebUI (light browser).command" "start_open_webui"
  write_hub_command "$hub/Draw Things (App Store).command" "open_draw_things"

  cat > "$hub/README — start here.txt" <<README
AI STUDIO APPS — everything in one folder
══════════════════════════════════════════

Double-click any shortcut below (or use "AI Studio Launcher" on your Desktop).

  Launch All.command          → starts Ollama + all apps + browser tabs
  LM Studio.command           → photo analysis, vision chat
  DiffusionBee.command        → quick realistic image generation
  ComfyUI (light browser).command   → ComfyUI in AI Studio Web (localhost:8188)
  Open WebUI (light browser).command → chat in AI Studio Web (localhost:8080, needs Docker)
  AI Studio Web.app (in Applications/) → light isolated window, not your default browser
  Draw Things (App Store).command → optional native editor (install separately)

Full studio root: $EXTERNAL_AI
Photo editing guide: $EXTERNAL_AI/docs/PHOTO_EDITING.txt
Models list:         $EXTERNAL_AI/docs/MODELS_INSTALLED.txt

16GB RAM: run one heavy app at a time (don't stack Flux + Docker + ComfyUI).
README

  if [[ -f "$SCRIPT_DIR/studio_launcher.py" ]]; then
    run cp "$SCRIPT_DIR/studio_launcher.py" "$EXTERNAL_AI/scripts/studio_launcher.py"
    chmod +x "$EXTERNAL_AI/scripts/studio_launcher.py"
  fi
  ok "Apps hub on SSD: $hub"
}

create_desktop_shortcuts_bash() {
  local hub="$EXTERNAL_AI/AI Studio Apps"

  clear_desktop_path "$HOME/Desktop/Launch AI Studio.command"
  cat > "$HOME/Desktop/Launch AI Studio.command" <<CMD
#!/usr/bin/env bash
exec "$EXTERNAL_AI/scripts/launch-ai-studio.sh"
CMD
  chmod +x "$HOME/Desktop/Launch AI Studio.command"

  local desktop_hub="$HOME/Desktop/AI Studio Apps"
  clear_desktop_path "$desktop_hub"
  run ln -sfn "$hub" "$desktop_hub"
  ok "Apps folder → ~/Desktop/AI Studio Apps"

  create_launcher_app
}

create_launcher_app() {
  local app="$HOME/Desktop/AI Studio Launcher.app"
  local py="$EXTERNAL_AI/scripts/studio_launcher.py"
  [[ -f "$py" ]] || return 0

  run rm -rf "$app"
  run mkdir -p "$app/Contents/MacOS"
  cat > "$app/Contents/MacOS/launcher" <<EOF
#!/bin/bash
exec /usr/bin/python3 "$py"
EOF
  chmod +x "$app/Contents/MacOS/launcher"
  cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
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
PLIST
  ok "Launcher app → ~/Desktop/AI Studio Launcher.app"
}

_create_launchers_body() {
  write_launch_helpers

  cat > "$EXTERNAL_AI/scripts/launch-ai-studio.sh" <<'LAUNCH'
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/local-ai-env.sh"
source "$(dirname "$0")/launch-helpers.sh"
echo "🚀 Launching Local AI Studio (tier: ${LOCAL_AI_TIER:-?})..."
launch_all
echo "✨ Open WebUI: localhost:8080 | ComfyUI: localhost:8188"
LAUNCH
  chmod +x "$EXTERNAL_AI/scripts/launch-ai-studio.sh"

  create_studio_hub

  if [[ "${LOCAL_AI_SKIP_DESKTOP:-}" == "1" ]]; then
    info "Desktop shortcuts → installer app (avoids Mac folder-permission popups during download)."
  else
    create_desktop_shortcuts_bash
    ok "Launchers → Desktop: AI Studio Launcher.app, AI Studio Apps/, Launch AI Studio.command"
  fi

  cat > "$EXTERNAL_AI/README.txt" <<README
LOCAL AI STUDIO — $(tier_toupper "$INSTALL_TIER") INSTALL COMPLETE
════════════════════════════════════════════════════
Root: $EXTERNAL_AI

START HERE (Desktop):
  • AI Studio Launcher.app   — pick any app from one window
  • AI Studio Apps/          — folder with shortcuts to every GUI
  • Launch AI Studio.command — starts everything at once (same as Launch All)

TIER: $(tier_blurb "$(tier_level "$INSTALL_TIER")")

Apps:
  • LM Studio, DiffusionBee — in Applications/ on SSD
  • ComfyUI, Open WebUI — AI Studio Web (isolated window, not your default browser)

Which app for what?  docs/WHICH_APP.txt  (Ollama vs ComfyUI vs DiffusionBee)
Photoreal models:   docs/MODELS_INSTALLED.txt
Photo editing:      docs/PHOTO_EDITING.txt

16GB RAM tip: don't run Flux Dev + SDXL + Docker simultaneously.

Cleanup: installer DMGs on SSD are removed automatically at the end.
         You can trash the installer .app on Desktop and eject the DMG when done.
README
  ok "SSD launcher hub ready (scripts + AI Studio Apps on drive)"
}

create_launchers() {
  step "Desktop launcher + apps hub"
  ensure_desktop_writable
  # Launcher failures must not abort a finished model install — SSD work is already done.
  set +e
  _create_launchers_body
  local rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    warn "Desktop launcher step failed (exit $rc) — models on SSD are still installed."
    warn "Fix Desktop shortcuts: $0 --launchers-only --ssd \"${SSD_VOLUME:-$FORCED_SSD}\" --tier \"${INSTALL_TIER:-ultimate}\""
    return 0
  fi
}

write_install_stats() {
  [[ "$DRY_RUN" == true || -z "${EXTERNAL_AI:-}" || ! -d "$EXTERNAL_AI" ]] && return 0
  local used hf_ok=0 hf_total=0 hf_missing=0 entry dest
  used=$(du -sg "$EXTERNAL_AI" 2>/dev/null | awk '{print $1}')
  hf_total=$(get_models_for_tier "$INSTALL_TIER" hf | wc -l | tr -d ' ')
  while IFS= read -r entry; do
    IFS='|' read -r _ subdir file _ _ _ <<<"$entry"
    dest="$EXTERNAL_AI/comfyui-models/$subdir/$file"
    if [[ -f "$dest" ]] && [[ "$(audit_local_bytes "$dest")" -gt 50000 ]]; then
      hf_ok=$((hf_ok + 1))
    else
      hf_missing=$((hf_missing + 1))
    fi
  done < <(get_models_for_tier "$INSTALL_TIER" hf)
  local stats_file="$EXTERNAL_AI/.install-stats.json"
  cat > "$stats_file" <<JSON
{
  "tier": "${INSTALL_TIER}",
  "ssd_gb": ${used:-0},
  "hf_models_ok": ${hf_ok},
  "hf_models_total": ${hf_total},
  "hf_models_missing": ${hf_missing},
  "completed_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
JSON
  ok "Final SSD size: ~${used} GB — ComfyUI models ${hf_ok}/${hf_total}"
  if [[ "$hf_missing" -gt 0 ]]; then
    warn "${hf_missing} ComfyUI model(s) still missing — re-run INSTALL to fetch gaps"
  fi
}

report_size() {
  step "Size report"
  [[ "$DRY_RUN" == true ]] && return
  local used budget tier_lvl
  used=$(du -sg "$EXTERNAL_AI" 2>/dev/null | awk '{print $1}')
  tier_lvl=$(tier_level "$INSTALL_TIER")
  budget=$(tier_external_gb "$INSTALL_TIER" 2>/dev/null || tier_budget_gb "$tier_lvl")
  ok "SSD used: ~${used} GB (tier estimate: ~${budget} GB)"
  local internal_used; internal_used=$(df -g / | awk 'NR==2 {print $3}')
  ok "Internal total used: ~${internal_used} GB (target ≤${MAX_INTERNAL_GB} GB for new installs)"
  write_install_stats
}

cleanup_install_artifacts() {
  step "Cleanup install leftovers"
  [[ "$DRY_RUN" == true ]] && return

  local freed=0 f mb
  if [[ -d "$EXTERNAL_AI/installers" ]]; then
    for f in "$EXTERNAL_AI/installers"/*.dmg; do
      [[ -f "$f" ]] || continue
      mb=$(du -sm "$f" 2>/dev/null | awk '{print $1}')
      mb=${mb:-0}
      run rm -f "$f"
      freed=$((freed + mb))
    done
    rmdir "$EXTERNAL_AI/installers" 2>/dev/null || true
  fi
  if [[ "$freed" -gt 0 ]]; then
    ok "Removed downloaded installer DMGs (~${freed} MB) — apps are already in Applications/"
  else
    ok "No installer DMG leftovers"
  fi

  local old
  for old in /tmp/local-ai-installer-*.log; do
    [[ -f "$old" ]] || continue
    [[ "$old" == "$LOG_FILE" ]] && continue
    run rm -f "$old"
  done
  ok "Pruned old /tmp install logs (kept: $LOG_FILE)"

  info "Optional: trash 'Install Local AI Studio' .app on Desktop & eject the DMG — not done automatically."
}

finale() {
  ok "DONE — $(tier_toupper "$INSTALL_TIER") photoreal studio is live!"
  echo -e "\n${BOLD}${GREEN}╔══════════════════════════════════════════════════╗" | tee -a "$LOG_FILE"
  echo "║  🎉 DONE — $(tier_toupper "$INSTALL_TIER") photoreal studio is live!  ║" | tee -a "$LOG_FILE"
  echo -e "╚══════════════════════════════════════════════════╝${RESET}\n" | tee -a "$LOG_FILE"
  echo "  Desktop:  AI Studio Launcher.app  (or  AI Studio Apps/  folder)" | tee -a "$LOG_FILE"
  echo "  SSD:      $EXTERNAL_AI" | tee -a "$LOG_FILE"
  if [[ -f "$EXTERNAL_AI/.install-stats.json" ]]; then
    echo "  Stats:    $EXTERNAL_AI/.install-stats.json" | tee -a "$LOG_FILE"
    grep -E '"ssd_gb"|"hf_models_' "$EXTERNAL_AI/.install-stats.json" 2>/dev/null | tee -a "$LOG_FILE" || true
  fi
  echo "  Editing:  $EXTERNAL_AI/docs/PHOTO_EDITING.txt" | tee -a "$LOG_FILE"
  if [[ "${UNFILTERED_PACK:-false}" == true && -f "$EXTERNAL_AI/.sensitive-models.tsv" ]]; then
    local sens_miss=0 entry subdir file _ _ _
    while IFS= read -r entry; do
      IFS='|' read -r subdir file _ _ _ <<<"$entry"
      [[ -f "$EXTERNAL_AI/comfyui-models/$subdir/$file" ]] \
        && [[ "$(audit_local_bytes "$EXTERNAL_AI/comfyui-models/$subdir/$file")" -gt 50000000 ]] \
        && continue
      sens_miss=$((sens_miss + 1))
    done < <(get_unfiltered_pack_sensitive_models)
    if [[ "$sens_miss" -gt 0 ]]; then
      warn "Optional: $sens_miss sensitive realism weight(s) skipped — studio is complete without them" | tee -a "$LOG_FILE"
      echo "  Retry:    $EXTERNAL_AI/scripts/fetch-sensitive-models.sh" | tee -a "$LOG_FILE"
    fi
  fi
  echo "  Log:      $LOG_FILE" | tee -a "$LOG_FILE"
  if [[ "$DRY_RUN" != true ]]; then
    echo "$EXTERNAL_AI" >"$INSTALL_COMPLETE_FILE"
    [[ "$NO_GUI" != true ]] && gui_alert "Install Complete!" "Tier $(tier_toupper "$INSTALL_TIER") ready.

Open AI Studio Launcher.app on your Desktop — or open the AI Studio Apps folder for individual shortcuts."
    [[ "$NO_GUI" == true ]] || open "$EXTERNAL_AI/docs" 2>/dev/null || true
  fi
}

_installer_on_exit() {
  local ec=$?
  echo "$$ $ec" >"$INSTALL_EXIT_FILE"
  rm -f "$INSTALL_PID_FILE"
}

main() {
  parse_args "$@"
  # Prevent Mac sleep during multi-hour downloads (exit 143 = SIGTERM from sleep/quit).
  if [[ "$DRY_RUN" != true && -z "${LOCAL_AI_CAFFEINATED:-}" ]] && command -v caffeinate &>/dev/null; then
    export LOCAL_AI_CAFFEINATED=1
    exec caffeinate -dims "$0" "$@"
  fi
  if [[ "$DRY_RUN" != true ]]; then
    echo $$ >"$INSTALL_PID_FILE"
    rm -f "$INSTALL_EXIT_FILE" "$INSTALL_COMPLETE_FILE"
    trap _installer_on_exit EXIT
  fi
  banner

  if [[ "${LAUNCHERS_ONLY:-false}" == true ]]; then
    [[ -n "$FORCED_SSD" ]] || die "--ssd required with --launchers-only"
    SSD_VOLUME="$FORCED_SSD"
    create_layout
    if [[ -f "$EXTERNAL_AI/scripts/local-ai-env.sh" ]]; then
      INSTALL_TIER=$(grep '^export LOCAL_AI_TIER=' "$EXTERNAL_AI/scripts/local-ai-env.sh" 2>/dev/null \
        | sed 's/^export LOCAL_AI_TIER=//' | tr -d '"' || true)
    fi
    [[ -n "$INSTALL_TIER" ]] || die "--tier required if LOCAL_AI_GEN has no prior install"
    [[ -f "$EXTERNAL_AI/scripts/local-ai-env.sh" ]] || setup_environment
    install_ai_studio_web_app
    create_launchers
    ok "Desktop shortcuts created — run INSTALL again to continue model downloads."
    exit 0
  fi

  if [[ "${UNFILTERED_PACK_ONLY:-false}" == true && -z "$INSTALL_TIER" ]]; then
    INSTALL_TIER="ultimate"
    info "Pack-only mode — defaulting tier label to ULTIMATE for docs/audit"
  fi

  if [[ "$NO_GUI" == true ]]; then
    [[ -n "$INSTALL_TIER" ]] || die "--tier required with --no-gui"
    [[ -n "$FORCED_SSD" ]] || die "--ssd required with --no-gui"
    [[ $(tier_level "$INSTALL_TIER") -gt 0 ]] || die "Invalid tier: $INSTALL_TIER"
    SSD_VOLUME="$FORCED_SSD"
    local pack_note=""
    [[ "${UNFILTERED_PACK:-false}" == true ]] && pack_note=" + Unfiltered Pack"
    ok "Non-interactive install — tier: $(tier_toupper "$INSTALL_TIER")${pack_note}, SSD: $SSD_VOLUME"
  else
    pick_install_tier
    [[ $(tier_level "$INSTALL_TIER") -gt 0 ]] || die "Invalid tier: $INSTALL_TIER"
    local ext int
    ext=$(tier_external_gb "$INSTALL_TIER" 2>/dev/null || echo 150)
    int=$(tier_internal_typical_gb "$INSTALL_TIER" 2>/dev/null || echo 6)
    gui_confirm "$SCRIPT_NAME" \
      "Tier: $(tier_toupper "$INSTALL_TIER")\n\n~${ext} GB → external SSD\n~${int} GB → Mac internal (Homebrew, Ollama, Docker)\n\nProceed?"
    pick_external_ssd
  fi

  ensure_dev_tools
  preflight
  create_layout
  audit_install_status
  if [[ "$AUDIT_ONLY" == true ]]; then
    ok "Audit only — no changes made. Run without --audit-only to sync missing items."
    exit 0
  fi
  setup_environment
  if [[ "${MODELS_ONLY:-false}" == true ]]; then
    if [[ "${SENSITIVE_MODELS_ONLY:-false}" == true ]]; then
      info "Sensitive models only — fetching 3 optional realism weights"
      write_sensitive_models_support
      download_sensitive_pack_models
    elif [[ "${UNFILTERED_PACK_ONLY:-false}" == true ]]; then
      info "Unfiltered pack only — skipping tier/base ComfyUI models"
      download_unfiltered_pack
    else
      info "Models-only mode — skipping ComfyUI/git/pip (no SSD permission popups)"
      download_hf_models
      [[ "${UNFILTERED_PACK:-false}" == true ]] && download_unfiltered_pack
    fi
    write_docs
    report_size
    finale
    exit 0
  fi
  install_homebrew
  install_ollama
  pull_ollama_models
  install_gui_apps
  install_open_webui
  install_comfyui
  download_hf_models
  [[ "${UNFILTERED_PACK:-false}" == true ]] && download_unfiltered_pack
  write_docs
  create_launchers
  report_size
  cleanup_install_artifacts
  finale
}

main "$@"