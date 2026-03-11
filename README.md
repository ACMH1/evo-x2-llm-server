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
| **ROCm** | `rocm-smi` installed on host for diagnostics; ROCm compute bundled inside the container image |
| **Ollama** | Runs as a Podman container (`ollama/ollama:rocm`) with GPU passthrough; bound to `0.0.0.0:11434` for LAN access; auto-starts via systemd |
| **Models** | `qwen2.5-coder:32b` (coding) |
| **Aliases** | `coder` — capped at 32 K context to avoid multi-minute prefills on large inputs |
| **Network** | Locks in current DHCP address as static IP |
| **Firewall** | Opens port `11434/tcp` |
| **Utility** | `ollama-status` command for quick server health checks |

The script is fully idempotent — safe to re-run on a partially configured machine.

## Hardware

- **CPU/APU:** AMD Ryzen AI MAX+ 395 (Strix Halo, 16 × Zen 5)
- **RAM:** 128 GB LPDDR5X
- **GPU:** Radeon 890M (integrated) — 40 CUs, **95.2 GB combined VRAM + GTT** (unified memory)
- **Storage:** 2 TB NVMe

## Strix Halo / ROCm note

Strix Halo (gfx1151) is not yet an officially listed ROCm target. The container is started with:

```
HSA_OVERRIDE_GFX_VERSION=11.0.0
```

This aliases the iGPU to gfx1100 (RX 7900-class) for ROCm compute. Remove this override once AMD adds official gfx1151 support.

## Why Podman (not native Ollama)?

Running Ollama in the `ollama/ollama:rocm` container has two advantages over the native install:

1. **Better VRAM detection** — the container sees the full 95.2 GB of unified memory (VRAM + GTT), vs ~64 GB with the native install. This allows Ollama to auto-configure a much larger default context window.
2. **Bundled ROCm** — no need to manage the ROCm host stack separately; the correct version ships inside the image.

## Configuration

Edit the variables at the top of `setup-llm-server.sh` before running:

```bash
ROOT_LV_SIZE="100G"          # Root partition size
OLLAMA_CTX="32768"           # Context window cap for model aliases (32 K default)
CONTAINER_IMAGE="docker.io/ollama/ollama:rocm"  # Bump tag for newer Ollama releases
STATIC_IP=""                 # Leave blank to use current DHCP address
MODELS_TO_PULL=(             # Add or swap models here
    "qwen2.5-coder:32b"
)
```

## Usage from LAN clients

```bash
# Via model alias (recommended)
curl http://<server-ip>:11434/api/generate \
  -d '{"model":"coder","prompt":"Write a Python web scraper","stream":false}'

# Via base model tag
curl http://<server-ip>:11434/api/generate \
  -d '{"model":"qwen2.5-coder:32b","prompt":"Write a Python web scraper","stream":false}'
```

Or use any OpenAI-compatible client pointed at `http://<server-ip>:11434/v1`.

## Post-install

```bash
ollama-status                        # GPU temp, loaded models, disk usage
podman logs -f ollama                # Live container logs
systemctl status ollama-container    # Systemd service status
```
