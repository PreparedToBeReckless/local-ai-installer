# RAM & model guide — which weights for your Mac

Apple Silicon uses **unified memory** (RAM shared by CPU, GPU, and the OS). Image models list their **file size on disk**, but a run often needs **more than that** in memory for activations, text encoders, VAE, and caches.

**Rule of thumb:** pick models whose **combined loaded weights stay under ~70% of your RAM**, and run **one heavy app at a time**.

After install, a copy of this file lives on your SSD: `LOCAL_AI_GEN/docs/RAM_AND_MODELS.txt`.

---

## Installer tier vs RAM

| Mac RAM | Recommended package | Unfiltered Pack? | Notes |
|---------|---------------------|------------------|-------|
| **8 GB** | Not recommended | No | Use DiffusionBee only; skip ComfyUI heavy workflows |
| **16 GB** | **STANDARD** ★ | Optional, one model at a time | Auto ComfyUI memory limits; Z-Image NVFP4/FP8 |
| **24 GB** | **PRO** | Yes, with patience | Flux Dev FP8 + editing workflows |
| **32 GB** | **ULTIMATE** | Yes | Z-Image BF16 viable; most tier models |
| **48 GB** | **ULTIMATE** | Yes | Qwen Image Edit pack comfortable |
| **64 GB** | **ULTIMATE** | Yes | Launch All more realistic |

---

## 8 GB RAM

**Realistic expectation:** this installer targets 16 GB+. On 8 GB, treat AI as light-weight only.

| Use | OK? | Models / apps |
|-----|-----|----------------|
| **DiffusionBee** | ✅ Best option | Built-in SDXL/Flux picks inside the app |
| **ComfyUI** | ⚠️ Avoid heavy graphs | Do not load Flux, Z-Image, or Qwen Image Edit |
| **Ollama** | ⚠️ Tiny only | `moondream` (vision helper) — skip 7B+ chat models |
| **LM Studio** | ⚠️ Small MLX only | Sub-3B models in-app |
| **Open WebUI / Docker** | ❌ Skip | Docker alone can consume multiple GB |
| **Unfiltered Pack** | ❌ Skip | Single Qwen/Flux shard exceeds headroom |

**ComfyUI flags (if you must):** `--cache-none --reserve-vram 1.5 --cpu-vae --novram`

---

## 16 GB RAM (M4 MacBook Air — installer default)

**Auto-enabled when you launch ComfyUI from AI Studio shortcuts:**

```text
--cache-none --reserve-vram 2.5 --fp8_e4m3fn-unet --fp8_e4m3fn-text-enc --disable-smart-memory
```

**Launch All** starts **ComfyUI only** (not Docker + LM Studio + ComfyUI together).

### ComfyUI — use these

| Workflow | Model files | Why |
|----------|-------------|-----|
| **Z-Image Turbo** (default blueprint) | `z_image_turbo_nvfp4.safetensors` + `qwen_3_4b_fp8_mixed.safetensors` + `ae.safetensors` | ~10 GB on disk; fits 16 GB with auto limits |
| **Fast Flux** | `flux1-schnell-fp8-e4m3fn.safetensors` + `flux-vae-bf16.safetensors` | Fast photoreal, one job at a time |
| **SDXL photoreal** | `RealVisXL_V5.0_fp16` or `CyberRealistic_V7` checkpoints | Reliable, lower RAM than Flux Dev |
| **Quick native** | **DiffusionBee** | Easiest; no ComfyUI memory spike |

### ComfyUI — avoid on 16 GB

| Model / combo | Risk |
|---------------|------|
| `z_image_turbo_bf16` + `qwen_3_4b` (BF16) | ~20 GB weights → system freeze |
| **Flux Dev FP8** + **Docker Open WebUI** + ComfyUI | Competing memory hogs |
| **Unfiltered Pack** Qwen Image Edit (20 GB shards) | One shard alone is tight; close everything else |
| **Launch All** | Starts too many apps at once |

### Ollama (16 GB)

| OK | Caution | Skip while generating |
|----|---------|------------------------|
| `moondream`, `llama3.2:3b`, `llava:7b` | `llama3.2-vision:11b`, `x/flux2-klein:4b` | `gemma3:12b`, `x/flux2-klein:9b` |

---

## 24 GB RAM

| Use | Models |
|-----|--------|
| **Primary generation** | Flux Dev FP8 (`flux1-dev-fp8-e4m3fn`), Flux Schnell, SDXL (Juggernaut, epiCRealism) |
| **Z-Image** | NVFP4/FP8 default; BF16 possible with ComfyUI limits and closed apps |
| **Editing** | IP-Adapter SDXL, ControlNet Depth/Canny, IC-Light (one workflow at a time) |
| **Chat / vision** | Ollama `llama3.2-vision:11b`, LM Studio mid-size MLX |
| **Open WebUI** | OK if ComfyUI is **not** generating |

**Unfiltered Pack:** install OK; run **one** Qwen Image Edit or Flux Fill workflow at a time.

---

## 32 GB RAM

| Use | Models |
|-----|--------|
| **Full tier catalog** | **ULTIMATE** package comfortable |
| **Z-Image** | `z_image_turbo_bf16` + `qwen_3_4b` viable |
| **Flux stack** | Dev FP8 + Kontext + IP-Adapter (sequential, not parallel) |
| **SD 3.5 Medium** | `sd3.5_medium.safetensors` (needs HF license) |
| **Parallel apps** | ComfyUI + Ollama chat OK; still avoid ComfyUI gen + Docker heavy container |

**Unfiltered Pack:** Qwen Image Edit 2509/2511 FP8, Flux Fill — usable with normal patience.

---

## 48 GB RAM

| Use | Models |
|-----|--------|
| **Everything in ULTIMATE + Pack** | Intended hardware class |
| **Heavy editing** | Qwen Image Edit + Flux Kontext + Fill in separate sessions |
| **Open WebUI + ComfyUI** | Fine for chat while ComfyUI is idle; pause one during large gens |
| **Launch All** | Works; still prefer one **generation** job at a time |

ComfyUI auto limits still apply at ≤18 GB detected RAM — on 48 GB Macs they are **not** applied.

---

## 64 GB RAM

| Use | Models |
|-----|--------|
| **All catalog models** | No practical restriction for solo hobby use |
| **Multiple workflows** | Keep one diffusion job running; caching (`--cache-lru`) OK for speed |
| **Launch All** | Reasonable default |
| **Unfiltered Pack + Ultimate** | Full photoreal + advanced edit stack |

Optional ComfyUI tuning for speed (not required): `--cache-lru 4` instead of `--cache-none`.

---

## Z-Image Turbo — loader cheat sheet

ComfyUI’s default **Text to Image** blueprint references BF16 names. **Change the three loader dropdowns:**

| Loader node | 16 GB | 24 GB | 32 GB+ |
|-------------|-------|-------|--------|
| **UNET** | `z_image_turbo_nvfp4.safetensors` | NVFP4 or BF16 | `z_image_turbo_bf16.safetensors` |
| **CLIP** | `qwen_3_4b_fp8_mixed.safetensors` | FP8 or BF16 | `qwen_3_4b.safetensors` |
| **VAE** | `ae.safetensors` | `ae.safetensors` | `ae.safetensors` |

---

## ComfyUI memory flags (manual override)

Default shortcuts auto-detect **≤18 GB** and apply 16 GB mode. To launch manually from Terminal:

```bash
source LOCAL_AI_GEN/scripts/local-ai-env.sh
cd "$COMFYUI_ROOT"
source "$COMFYUI_VENV/bin/activate"
python main.py --listen 127.0.0.1 --port 8188 \
  --cache-none --reserve-vram 2.5 \
  --fp8_e4m3fn-unet --fp8_e4m3fn-text-enc --disable-smart-memory
```

| Flag | Effect |
|------|--------|
| `--cache-none` | Drop models between steps (saves RAM, slower) |
| `--reserve-vram N` | Leave N GB for macOS |
| `--fp8_e4m3fn-unet` | Run diffusion weights in FP8 |
| `--fp8_e4m3fn-text-enc` | Run text encoders in FP8 |
| `--disable-smart-memory` | Aggressive offload |
| `--lowvram` / `--novram` | Extra squeeze for 8–16 GB (slower) |

---

## Quick “what should I run?”

| Goal | 16 GB | 32 GB |
|------|-------|-------|
| Fast realistic photo | DiffusionBee or Flux Schnell | Flux Dev FP8 |
| Edit existing photo | ComfyUI SDXL + ControlNet | + IP-Adapter, IC-Light |
| ComfyUI default screen | Z-Image **NVFP4/FP8** loaders | Z-Image BF16 OK |
| Chat about an image | Ollama moondream / LM Studio | + llama3.2-vision |
| Advanced mask-free edit | Skip or pack one model only | Unfiltered Qwen Image Edit |

---

## Related docs (on SSD after install)

- `docs/WHICH_APP.txt` — ComfyUI vs DiffusionBee vs Ollama
- `docs/16GB_RAM.txt` — short 16 GB checklist
- `docs/MODELS_INSTALLED.txt` — what your tier pulled down