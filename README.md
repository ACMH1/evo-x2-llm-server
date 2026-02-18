# GMKtec EVO-X2 LLM Server Setup

Automated setup script for a **GMKtec EVO-X2** (Ryzen AI MAX+ 395 / Strix Halo) running **Fedora 43 Server** as a LAN-accessible LLM inference server.

## Quick start

On a fresh Fedora 43 Server install, run as root:

```bash
curl -fsSL https://raw.githubusercontent.com/ACMH1/evo-x2-llm-server/main/setup-llm-server.sh \
  | sudo bash
```

## What it sets up

| Component | Detail |
|---|---|
| **Storage** | Extends root LV to 100 GB; creates a dedicated `/models` LV using the remaining ~1.8 TB |
| **ROCm** | AMD ROCm 6.3 via RHEL9-compatible repo; `HSA_OVERRIDE_GFX_VERSION=11.0.0` workaround for Strix Halo (gfx1151) |
| **Ollama** | Installed with bundled ROCm, bound to `0.0.0.0:11434` for LAN access |
| **Models** | `qwen2.5-coder:32b` (coding) and `deepseek-r1:32b` (planning) |
| **Aliases** | `coder` and `planner` — both capped at 16 K context so they coexist in ~95 GB VRAM |
| **Network** | Locks in current DHCP address as static IP |
| **Firewall** | Opens port `11434/tcp` |
| **Utility** | `ollama-status` command for quick server health checks |

The script is fully idempotent — safe to re-run on a partially configured machine.

## Hardware

- **CPU/APU:** AMD Ryzen AI MAX+ 395 (Strix Halo, 16 × Zen 5)
- **RAM:** 128 GB LPDDR5X (64 GB allocated to iGPU in BIOS, 62 GB to CPU)
- **GPU:** Radeon 890M — 40 CUs, 95.2 GB combined VRAM + GTT
- **Storage:** 2 TB NVMe

## Strix Halo / ROCm note

Strix Halo (gfx1151) is not yet an officially listed ROCm target. The script sets:

```
HSA_OVERRIDE_GFX_VERSION=11.0.0
```

This aliases the iGPU to gfx1100 (RX 7900-class) for ROCm compute. Remove this override from `/etc/systemd/system/ollama.service.d/override.conf` once AMD adds official gfx1151 support.

## Configuration

Edit the variables at the top of `setup-llm-server.sh` before running:

```bash
ROOT_LV_SIZE="100G"          # Root partition size
OLLAMA_CTX="16384"           # Context window per model
ROCM_VERSION="6.3"           # Bump when newer ROCm is released
STATIC_IP=""                 # Leave blank to use current DHCP address
MODELS_TO_PULL=(             # Add or swap models here
    "qwen2.5-coder:32b"
    "deepseek-r1:32b"
)
```

## Usage from LAN clients

```bash
# Coding task
curl http://<server-ip>:11434/api/generate \
  -d '{"model":"coder","prompt":"Write a Python web scraper","stream":false}'

# Planning task
curl http://<server-ip>:11434/api/generate \
  -d '{"model":"planner","prompt":"Plan a microservices migration","stream":false}'
```

Or use any OpenAI-compatible client pointed at `http://<server-ip>:11434`.

## Post-install

```bash
ollama-status          # GPU temp, loaded models, disk usage
journalctl -fu ollama  # Live service logs
```
