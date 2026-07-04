#!/usr/bin/env bash
# Realistic padded size estimates (catalog + apps + headroom, not worst-case fantasy)
# External = SSD. Internal = Mac boot drive (Homebrew, Ollama binary, Docker).

tier_external_gb() {
  # Padded totals (models + ComfyUI + apps). Ultimate measured ~147 GB on real install (Jul 2026).
  case "$1" in
    starter)   echo 55 ;;
    standard)  echo 110 ;;
    pro)       echo 135 ;;
    ultimate)  echo 150 ;;
    *)         echo 110 ;;
  esac
}

tier_internal_typical_gb() {
  # Homebrew ~1 GB + Ollama ~0.2 GB + Docker ~4 GB + buffer
  echo 6
}

tier_internal_min_gb() {
  # No Docker (auto-skipped when internal space low)
  echo 2
}

tier_drive_min_gb() {
  # Recommended free space on external SSD (external estimate + breathing room)
  case "$1" in
    starter)   echo 70 ;;
    standard)  echo 130 ;;
    pro)       echo 160 ;;
    ultimate)  echo 175 ;;
    *)         echo 130 ;;
  esac
}

tier_label_external() {
  echo "~$(tier_external_gb "$1") GB SSD"
}

tier_label_internal() {
  echo "~$(tier_internal_typical_gb "$1") GB Mac internal (typical)"
}

tier_time_estimate() {
  case "$1" in
    starter)   echo "1–2 hours" ;;
    standard)  echo "2–4 hours" ;;
    pro)       echo "3–5 hours" ;;
    ultimate)  echo "4–7 hours" ;;
    *)         echo "2–4 hours" ;;
  esac
}

unfiltered_pack_gb() {
  echo 150
}

unfiltered_pack_drive_min_gb() {
  echo 165
}

unfiltered_pack_time_estimate() {
  echo "3–6 hours"
}