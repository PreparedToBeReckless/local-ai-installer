#!/usr/bin/env bash
# =============================================================================
#  LOCAL AI STUDIO — Photorealistic Model Catalog
#  Curated for M4 MacBook Air 16GB. No anime. Generation + photo editing focus.
# =============================================================================

# Tier order (low → high)
readonly TIER_STARTER=1
readonly TIER_STANDARD=2
readonly TIER_PRO=3
readonly TIER_ULTIMATE=4

# macOS /bin/bash is 3.2 — no associative arrays or ${var,,} / ${var^^}
tier_tolower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

tier_toupper() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

tier_name() {
  case "$1" in
    1) echo "STARTER" ;;
    2) echo "STANDARD" ;;
    3) echo "PRO" ;;
    4) echo "ULTIMATE" ;;
    *) echo "STANDARD" ;;
  esac
}

tier_budget_gb() {
  case "$1" in
    1) echo 55 ;;
    2) echo 110 ;;
    3) echo 135 ;;
    4) echo 150 ;;
    *) echo 110 ;;
  esac
}

tier_blurb() {
  case "$1" in
    1) echo "~55 GB SSD — Fast portraits, core apps, essential Flux + SDXL" ;;
    2) echo "~110 GB SSD — Recommended for M4 16GB. Full editing starter kit" ;;
    3) echo "~135 GB SSD — Pro photo editing: inpaint, relight, face swap, SD3.5" ;;
    4) echo "~150 GB SSD — Complete photoreal catalog + room to grow" ;;
    *) echo "~110 GB SSD — Recommended for M4 16GB. Full editing starter kit" ;;
  esac
}

tier_level() {
  case "$(tier_tolower "$1")" in
    starter|1)   echo 1 ;;
    standard|2)  echo 2 ;;
    pro|3)       echo 3 ;;
    ultimate|4)  echo 4 ;;
    *)           echo 0 ;;
  esac
}

# ── Ollama: tier|model|size_mb|description ───────────────────────────────────
OLLAMA_CATALOG=(
  "starter|x/flux2-klein:4b|5000|Flux Klein 4B — fast realistic photos"
  "starter|x/z-image-turbo|12000|Z-Image Turbo — efficient photorealism"
  "starter|moondream|1800|Moondream — tiny vision helper"
  "standard|x/flux2-klein:9b|18000|Flux Klein 9B — higher quality portraits"
  "standard|llama3.2-vision:11b|7900|Llama 3.2 Vision — describe & analyze photos"
  "pro|llava:7b|4700|LLaVA 7B — image Q&A for editing prompts"
  "pro|llama3.2:3b|2000|Llama 3.2 3B — fast prompt writing assistant"
  "ultimate|gemma3:12b|8100|Gemma 3 12B — vision + reasoning for edits"
)

# ── HuggingFace: tier|subdir|filename|repo/resolve/path|size_mb|label ────────
# subdir → folder under comfyui-models/
HF_CATALOG=(
  # ── STARTER: core photoreal checkpoints + Flux fast ──
  "starter|checkpoints|CyberRealistic_V7.safetensors|cyberdelia/CyberRealistic/resolve/main/CyberRealistic_V7.0_FP16.safetensors|6500|CyberRealistic V7 SDXL"
  "starter|checkpoints|RealVisXL_V5.0_fp16.safetensors|SG161222/RealVisXL_V5.0/resolve/main/RealVisXL_V5.0_fp16.safetensors|6940|RealVisXL V5 — flagship photoreal SDXL"
  "starter|diffusion_models|flux1-schnell-fp8-e4m3fn.safetensors|Kijai/flux-fp8/resolve/main/flux1-schnell-fp8-e4m3fn.safetensors|11300|FLUX.1 Schnell FP8 — fast realistic"
  "starter|vae|flux-vae-bf16.safetensors|Kijai/flux-fp8/resolve/main/flux-vae-bf16.safetensors|160|FLUX VAE"
  "starter|upscale_models|4x-UltraSharp.safetensors|Kim2091/UltraSharp/resolve/main/4x-UltraSharp.safetensors|64|4x-UltraSharp photo upscaler"
  "starter|upscale_models|RealESRGAN_x4.pth|ai-forever/Real-ESRGAN/resolve/main/RealESRGAN_x4.pth|64|Real-ESRGAN x4"

  # ── STANDARD: more checkpoints + editing foundations ──
  "standard|checkpoints|Juggernaut-XL_v9_RunDiffusionPhoto_v2.safetensors|RunDiffusion/Juggernaut-XL-v9/resolve/main/Juggernaut-XL_v9_RunDiffusionPhoto_v2.safetensors|6770|Juggernaut XL v9 — pro photography"
  "standard|diffusion_models|flux1-dev-fp8-e4m3fn.safetensors|Kijai/flux-fp8/resolve/main/flux1-dev-fp8-e4m3fn.safetensors|11350|FLUX.1 Dev FP8 — max quality"
  "standard|checkpoints|epicrealismXL_vx1Finalkiss.safetensors|John6666/epicrealism-xl-v8kiss-sdxl/resolve/main/epicrealismXL_vx1Finalkiss.safetensors|6620|epiCRealism XL — skin & portrait"
  "standard|ipadapter|ip-adapter-plus_sdxl_vit-h.safetensors|h94/IP-Adapter/resolve/main/sdxl_models/ip-adapter-plus_sdxl_vit-h.safetensors|808|IP-Adapter Plus SDXL — style from reference photo"
  "standard|controlnet|controlnet-depth-sdxl-1.0-fp16.safetensors|diffusers/controlnet-depth-sdxl-1.0/resolve/main/diffusion_pytorch_model.fp16.safetensors|2386|ControlNet Depth SDXL — structure-guided edits"
  "standard|controlnet|controlnet-canny-sdxl-1.0-fp16.safetensors|diffusers/controlnet-canny-sdxl-1.0/resolve/main/diffusion_pytorch_model.fp16.safetensors|2386|ControlNet Canny SDXL — edge-guided edits"

  # ── PRO: advanced editing (inpaint, relight, face, Flux IP) ──
  "pro|checkpoints|RealVisXL_V4.0.safetensors|SG161222/RealVisXL_V4.0/resolve/main/RealVisXL_V4.0.safetensors|6600|RealVisXL V4 — alternate photoreal look"
  "pro|ipadapter|flux-ip-adapter.safetensors|XLabs-AI/flux-ip-adapter/resolve/main/ip_adapter.safetensors|936|Flux IP-Adapter — reference-driven Flux edits"
  "pro|clip_vision|clip-vit-large-patch14.safetensors|h94/IP-Adapter/resolve/main/models/image_encoder/model.safetensors|2410|CLIP Vision — required for IP-Adapter face/style"
  "pro|controlnet|iclight_sd15_fc.safetensors|lllyasviel/ic-light/resolve/main/iclight_sd15_fc.safetensors|1639|IC-Light — relight existing photos"
  "pro|loras|extremely-detailed.safetensors|ntc-ai/SDXL-LoRA-slider.extremely-detailed/resolve/main/extremely%20detailed.safetensors|8|Detail Booster LoRA — sharper skin & textures"
  "pro|diffusion_models|sd3.5_medium.safetensors|stabilityai/stable-diffusion-3.5-medium/resolve/main/sd3.5_medium.safetensors|4870|SD 3.5 Medium — needs HF license accept + token"

  # ── ULTIMATE: complete photoreal + inpaint vault ──
  "ultimate|diffusion_models|flux1-dev-fp8.safetensors|Kijai/flux-fp8/resolve/main/flux1-dev-fp8.safetensors|11350|FLUX.1 Dev FP8 alt quant"
  "ultimate|diffusion_models|flux_shakker_union_pro-fp8_e4m3fn.safetensors|Kijai/flux-fp8/resolve/main/flux_shakker_labs_union_pro-fp8_e4m3fn.safetensors|3150|Flux Shakker Union Pro — unified editing"
  "ultimate|checkpoints|DreamShaperXL_Turbo_SFW.safetensors|Lykon/dreamshaper-xl-turbo/resolve/main/DreamShaperXL_Turbo_SFWdpmppSde_half_pruned.safetensors|6620|DreamShaper XL Turbo — fast realistic variety"
  "ultimate|ipadapter|ip-adapter-plus-face_sdxl_vit-h.safetensors|h94/IP-Adapter/resolve/main/sdxl_models/ip-adapter-plus-face_sdxl_vit-h.safetensors|808|IP-Adapter Face SDXL — face-consistent edits"
  "ultimate|controlnet|iclight_sd15_fbc.safetensors|lllyasviel/ic-light/resolve/main/iclight_sd15_fbc.safetensors|1639|IC-Light Background Condition — studio relight"
  "ultimate|controlnet|iclight_sd15_fcon.safetensors|lllyasviel/ic-light/resolve/main/iclight_sd15_fcon.safetensors|1639|IC-Light Foreground Condition — portrait relight"
  "ultimate|upscale_models|RealESRGAN_x2.pth|ai-forever/Real-ESRGAN/resolve/main/RealESRGAN_x2.pth|64|Real-ESRGAN x2 — gentle upscale"
  "ultimate|upscale_models|RealESRGAN_x8.pth|ai-forever/Real-ESRGAN/resolve/main/RealESRGAN_x8.pth|64|Real-ESRGAN x8 — max upscale"
)

# ── ComfyUI custom nodes: tier|git_url|folder_name|purpose ───────────────────
COMFY_NODES_CATALOG=(
  "starter|https://github.com/ltdrdata/ComfyUI-Manager.git|ComfyUI-Manager|Model browser GUI"
  "starter|https://github.com/cubiq/ComfyUI_IPAdapter_plus.git|ComfyUI_IPAdapter_plus|Reference photo editing"
  "starter|https://github.com/Fannovel16/comfyui_controlnet_aux.git|comfyui_controlnet_aux|ControlNet preprocessors"
  "standard|https://github.com/ltdrdata/ComfyUI-Impact-Pack.git|ComfyUI-Impact-Pack|Inpainting & face detail"
  "standard|https://github.com/WASasquatch/was-node-suite-comfyui.git|was-node-suite-comfyui|Image tools & masking"
  "standard|https://github.com/cubiq/ComfyUI_essentials.git|ComfyUI_essentials|Crop, scale, blend photos"
  "pro|https://github.com/huchenlei/ComfyUI-IC-Light.git|ComfyUI-IC-Light|Relight existing photos"
  "pro|https://github.com/cubiq/ComfyUI_InstantID.git|ComfyUI_InstantID|Face-consistent photo edits"
  "pro|https://github.com/kijai/ComfyUI-KJNodes.git|ComfyUI-KJNodes|Advanced image workflows"
  "ultimate|https://github.com/ltdrdata/ComfyUI-Inspire-Pack.git|ComfyUI-Inspire-Pack|Regional inpaint & prompts"
  "ultimate|https://github.com/chflame163/ComfyUI_LayerStyle.git|ComfyUI_LayerStyle|Photo compositing & layers"
  "ultimate|https://github.com/kijai/ComfyUI-segment-anything-2.git|ComfyUI-segment-anything-2|AI masking for edits"
)

# ── LM Studio MLX models (tier|hf_path|size_mb|label) — optional pulls ───────
LMSTUDIO_CATALOG=(
  "standard|mlx-community/Qwen2.5-VL-7B-Instruct-4bit|4500|Qwen2.5-VL — photo analysis & captions"
  "pro|mlx-community/gemma-3-12b-it-qat-4bit|7500|Gemma 3 12B — vision reasoning for edits"
  "ultimate|mlx-community/Llama-3.2-11B-Vision-Instruct-4bit|6500|Llama 3.2 Vision MLX — fast local vision"
)

# Estimated download totals per tier (models only, GB)
estimate_tier_download_gb() {
  local tier_lvl=$1
  local total_mb=0 entry min_tier size
  for entry in "${OLLAMA_CATALOG[@]}"; do
    IFS='|' read -r min_tier _ size _ <<<"$entry"
    [[ $(tier_level "$min_tier") -le $tier_lvl ]] && total_mb=$((total_mb + size))
  done
  for entry in "${HF_CATALOG[@]}"; do
    IFS='|' read -r min_tier _ _ _ size _ <<<"$entry"
    [[ $(tier_level "$min_tier") -le $tier_lvl ]] && total_mb=$((total_mb + size))
  done
  echo $(( (total_mb + 1023) / 1024 ))
}

get_models_for_tier() {
  local want=$1 kind=$2
  local tier_lvl; tier_lvl=$(tier_level "$want")
  local entry min_tier
  case "$kind" in
    ollama)
      for entry in "${OLLAMA_CATALOG[@]}"; do
        IFS='|' read -r min_tier _ _ _ <<<"$entry"
        [[ $(tier_level "$min_tier") -le $tier_lvl ]] && echo "$entry"
      done
      ;;
    hf)
      for entry in "${HF_CATALOG[@]}"; do
        IFS='|' read -r min_tier _ _ _ _ _ <<<"$entry"
        [[ $(tier_level "$min_tier") -le $tier_lvl ]] && echo "$entry"
      done
      ;;
    nodes)
      for entry in "${COMFY_NODES_CATALOG[@]}"; do
        IFS='|' read -r min_tier _ _ _ <<<"$entry"
        [[ $(tier_level "$min_tier") -le $tier_lvl ]] && echo "$entry"
      done
      ;;
  esac
}