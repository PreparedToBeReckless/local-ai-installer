#!/usr/bin/env bash
# Compare SSD install vs catalog — missing items, partial files, possible HF updates.

audit_manifest_path() {
  echo "${EXTERNAL_AI:?}/.install-manifest.tsv"
}

audit_record_download() {
  local kind="$1" path="$2" size="$3" ref="$4"
  [[ -n "${EXTERNAL_AI:-}" && -d "$EXTERNAL_AI" ]] || return 0
  local manifest; manifest=$(audit_manifest_path)
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$kind" "$path" "$size" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$ref" >> "$manifest"
}

audit_remote_bytes() {
  local url="$1"
  local len
  len=$(curl -fsSIL --max-time 12 -r 0-0 "$url" 2>/dev/null \
    | awk 'tolower($1) == "content-length:" { print $2; exit }' | tr -d '\r')
  [[ -n "$len" && "$len" =~ ^[0-9]+$ ]] && echo "$len" || echo ""
}

audit_local_bytes() {
  local path="$1"
  [[ -f "$path" ]] || { echo 0; return; }
  stat -f%z "$path" 2>/dev/null || wc -c < "$path" 2>/dev/null || echo 0
}

audit_ensure_ollama_running() {
  command -v ollama &>/dev/null || return 1
  pgrep -x ollama &>/dev/null || { ollama serve &>/dev/null & disown; sleep 2; }
  return 0
}

audit_ollama_has_model() {
  local model="$1"
  audit_ensure_ollama_running || return 1
  OLLAMA_MODELS="${EXTERNAL_AI}/ollama-models" ollama list 2>/dev/null \
    | awk '{print $1}' | grep -Fxq "$model"
}

audit_install_status() {
  local tier="${INSTALL_TIER:-standard}"
  [[ -n "${EXTERNAL_AI:-}" && -d "$EXTERNAL_AI" ]] || {
    info "Fresh install — nothing on SSD yet for this catalog."
    return 0
  }

  step "Install status check ($(tier_toupper "$tier") catalog)"

  local saved_tier=""
  if [[ -f "$EXTERNAL_AI/scripts/local-ai-env.sh" ]]; then
    saved_tier=$(grep '^export LOCAL_AI_TIER=' "$EXTERNAL_AI/scripts/local-ai-env.sh" 2>/dev/null \
      | head -1 | sed 's/.*="\(.*\)".*/\1/' | tr '[:upper:]' '[:lower:]')
    if [[ -n "$saved_tier" && "$saved_tier" != "$tier" ]]; then
      warn "SSD was installed as $(tier_toupper "$saved_tier"); you selected $(tier_toupper "$tier") — will add any new tier models."
    elif [[ -n "$saved_tier" ]]; then
      ok "Previously installed tier: $(tier_toupper "$saved_tier")"
    fi
  fi

  local used hf_ok=0 hf_missing=0 hf_partial=0 hf_stale=0
  used=$(du -sg "$EXTERNAL_AI" 2>/dev/null | awk '{print $1}')
  info "SSD folder size: ~${used:-0} GB"

  local entry dest url label local_sz remote_sz
  while IFS= read -r entry; do
    IFS='|' read -r _ subdir file path _ label <<<"$entry"
    dest="$EXTERNAL_AI/comfyui-models/$subdir/$file"
    url="https://huggingface.co/$path"
    if [[ ! -f "$dest" ]]; then
      hf_missing=$((hf_missing + 1))
      info "Missing model: $label"
      continue
    fi
    local_sz=$(audit_local_bytes "$dest")
    if [[ "${local_sz:-0}" -lt 50000 ]]; then
      hf_partial=$((hf_partial + 1))
      warn "Partial download: $label (${local_sz} bytes) — will retry"
      continue
    fi
    hf_ok=$((hf_ok + 1))
    remote_sz=$(audit_remote_bytes "$url")
    if [[ -n "$remote_sz" && "$remote_sz" -gt "$local_sz" ]]; then
      hf_stale=$((hf_stale + 1))
      info "Possible update: $label (remote larger than local copy)"
    fi
  done < <(get_models_for_tier "$tier" hf)

  local ollama_ok=0 ollama_missing=0 model
  while IFS= read -r entry; do
    IFS='|' read -r _ model _ _ <<<"$entry"
    if audit_ollama_has_model "$model"; then
      ollama_ok=$((ollama_ok + 1))
    else
      ollama_missing=$((ollama_missing + 1))
      info "Missing Ollama model: $model"
    fi
  done < <(get_models_for_tier "$tier" ollama)

  local apps_ok=0 apps_missing=0 app
  for app in "LM Studio" "DiffusionBee"; do
    if [[ -d "$EXTERNAL_AI/Applications/${app}.app" ]]; then
      apps_ok=$((apps_ok + 1))
    else
      apps_missing=$((apps_missing + 1))
      info "Missing app on SSD: $app"
    fi
  done

  local comfy_ok=true
  if [[ ! -d "$EXTERNAL_AI/comfyui/ComfyUI/.git" ]]; then
    comfy_ok=false
    info "ComfyUI not cloned yet"
  fi

  echo ""
  ok "ComfyUI models: ${hf_ok} present, ${hf_missing} missing, ${hf_partial} partial"
  [[ "$hf_stale" -gt 0 ]] && warn "${hf_stale} model(s) may have upstream updates (use --refresh-hf to re-fetch larger files)"
  ok "Ollama models: ${ollama_ok} present, ${ollama_missing} missing (pull refreshes existing on install)"
  ok "GUI apps on SSD: ${apps_ok}/2 present"
  [[ "$comfy_ok" == true ]] && ok "ComfyUI repo: present" || warn "ComfyUI repo: not set up yet"

  local todo=$((hf_missing + hf_partial + ollama_missing + apps_missing))
  if [[ "$todo" -eq 0 && "$hf_stale" -eq 0 ]]; then
    ok "Catalog looks complete for $(tier_toupper "$tier") — install will verify Ollama updates via pull"
  elif [[ "$todo" -eq 0 ]]; then
    info "Nothing missing — ${hf_stale} optional HF update(s) available (--refresh-hf)"
  else
    info "Install will fetch ${todo} missing/incomplete item(s), then check Ollama for updates"
  fi
  echo ""
}